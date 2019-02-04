package GRNOC::Simp::Poller::Worker;

use strict;
use Try::Tiny;
use Data::Dumper;
use Moo;
use AnyEvent;
use AnyEvent::SNMP;
use Net::SNMP::XS; # Faster than non-XS
use Redis;

# Raised from 64, Default value
$AnyEvent::SNMP::MAX_RECVQUEUE = 128;

### Required Attributes ###
=head1 public attributes

=over 12

=item group_name

=item instance

=item config

=item logger

=item hosts

=item oids

=item poll_interval

=item var_hosts

=back

=cut

has group_name => (
    is => 'ro',
    required => 1
);

has instance => (
    is => 'ro',
    required => 1
);

has config => (
    is => 'ro',
    required => 1
);

has logger => (
    is => 'rwp',
    required => 1
);

has hosts => (
    is => 'ro',
    required => 1
);

has oids => (
    is => 'ro',
    required => 1
);

has poll_interval => (
    is => 'ro',
    required => 1
);

has var_hosts => ( 
    is => 'ro',
    required => 1
);

### Internal Attributes ###
=head1 private attributes

=over 12

=item worker_name

=item is_running

=item need_restart

=item redis

=item retention

=item max_reps

=item snmp_timeout

=item main_cv

=back

=cut

has worker_name => (
    is => 'rwp',
    required => 0,
    default => 'unknown'
);

has is_running => (
    is => 'rwp',
    default => 0
);

has need_restart => (
    is => 'rwp',
    default => 0 
);

has redis => (
    is => 'rwp'
);

has retention => (
    is => 'rwp',
    default => 5
);

has max_reps => (
    is => 'rwp',
    default => 1
);

has snmp_timeout => (
    is => 'rwp',
    default => 5
);

has main_cv => (
    is => 'rwp'
);

### Public Methods ###

=head1 methods

=over 12

=cut

=item start

=cut

sub start {

    my ( $self ) = @_;

    $self->_set_worker_name($self->group_name . $self->instance);

    my $logger = GRNOC::Log->get_logger($self->worker_name);
    $self->_set_logger($logger);

    my $worker_name = $self->worker_name;
    $self->logger->error( $self->worker_name." Starting." );

    # Flag that we're running
    $self->_set_is_running( 1 );

    # Change our process name
    $0 = "simp($worker_name)";

    # Setup signal handlers
    $SIG{'TERM'} = sub {
        $self->logger->info($self->worker_name. " Received SIG TERM." );
        $self->stop();
    };

    $SIG{'HUP'} = sub {
        $self->logger->info($self->worker_name. " Received SIG HUP." );
    };

    # Connect to redis
    my $redis_host = $self->config->get( '/config/redis/@host' )->[0];
    my $redis_port = $self->config->get( '/config/redis/@port' )->[0];

    $self->logger->debug($self->worker_name." Connecting to Redis $redis_host:$redis_port." );

    my $redis;

    try {
    # Try to connect twice per second for 30 seconds, 60 attempts every 500ms.
        $redis = Redis->new(
            server    => "$redis_host:$redis_port",
            reconnect => 60,
            every     => 500,
            read_timeout => 2,
            write_timeout => 3,
        );

    } catch {
        $self->logger->error($self->worker_name." Error connecting to Redis: $_" );
    };

    $self->_set_redis( $redis );

    $self->_set_need_restart(0);

    $self->logger->debug( $self->worker_name . ' Starting SNMP Poll loop.' );

    $self->_connect_to_snmp();
    if (! $self->var_hosts ) {
        $self->logger->debug("No hosts found for $self->worker_name");
    } else {
        $self->logger->debug($self->worker_name . ' var_hosts: "' . (join '", "', (keys %{$self->var_hosts})) . '"');
    }

    # Start AnyEvent::SNMP's max outstanding requests window equal to the total
    # number of requests this process will be making. AnyEvent::SNMP will scale from there
    # as it observes bottlenecks
    AnyEvent::SNMP::set_max_outstanding(@{$self->hosts()} * @{$self->oids()});

    $self->{'collector_timer'} = AnyEvent->timer(
        after => 10,
        interval => $self->poll_interval,
        cb => sub {
            $self->_collect_data();
            AnyEvent->now_update;
        }
    );

    # Let the magic happen
    my $cv = AnyEvent->condvar;
    $self->_set_main_cv($cv);
    $cv->recv;
    $self->logger->error("Exiting");
}


=item stop

=back

=cut

sub stop {
    my $self = shift;
    $self->logger->error("Stop was called");
    $self->main_cv->send();
}


sub _poll_cb {

    my $self = shift;
    my %params = @_;

    # Set params
    my $session     = $params{'session'};
    my $host        = $params{'host'};
    my $req_time    = $params{'timestamp'};
    my $reqstr      = $params{'reqstr'};
    my $main_oid    = $params{'oid'};
    my $context_id  = $params{'context_id'};

    my $redis       = $self->redis;
    my $id          = $self->group_name;
    my $data        = $session->var_bind_list();
    my $timestamp   = $req_time;

    my $ip          = $host->{'ip'};
    my $node_name   = $host->{'node_name'};
    my $poll_id     = $host->{'poll_id'};
    
    $self->logger->debug("_poll_cb running for: $main_oid");
    if ( defined($context_id) ) {
        delete $host->{'pending_replies'}->{$main_oid . "," . $context_id};
    } else {
        delete $host->{'pending_replies'}->{$main_oid};

    }

    my @values;
    # It's possible we didn't get anything back from this OID for some reason, but we still need
    # to advance the "pending_replies" since we did complete the action
    if ( !defined $data ) {

        # OID with no data added to hash of failed OIDs
        $host->{'failed_oids'}{$main_oid} = {
            error       => "OID_DATA_ERR: No data was returned for $main_oid",
            poll_id     => $host->{'poll_id'},
            location    => $self->config->{'config_file'},
            group       => $self->group_name,
            timestamp   => time()
        };

        my $error = $session->error();
        $self->logger->error("Host/Context ID: $host->{'node_name'} " . (defined($context_id) ? $context_id : '[no context ID]'));
        $self->logger->error("Group \"$id\" failed: $reqstr");
        $self->logger->error("Error: $error");

    } else {
        for my $oid ( keys %$data ) {
            push(@values, "$oid," .  $data->{$oid});
        }   
    }

    my $expires = $timestamp + $self->retention;

    my $group_poll_interval = $self->group_name . "," . $self->poll_interval;

    try {

        $redis->select(0);

        my $key = $node_name . "," . $self->worker_name . ",$timestamp";

        $redis->sadd($key, @values) if (@values);

        if ( scalar(keys %{$host->{'pending_replies'}}) < 1 ) {

            #$self->logger->error("Received all responses!");
            $redis->expireat($key, $expires);

            # Our poll_id to time lookup
            $redis->select(1);

            my $node_base_key       = $node_name . "," . $self->group_name;
            my $ip_base_key         = $ip . "," . $self->group_name;
            my $poll_timestamp_val  = $poll_id . "," . $timestamp;
            my $node_name_key       = $node_base_key . "," . $poll_id;
            my $ip_key              = $ip_base_key . "," . $poll_id;

            $redis->set($node_name_key, $key);
            $redis->set($ip_key, $key);

            # ...and expire
            $redis->expireat($node_name_key, $expires);
            $redis->expireat($ip_key, $expires);

            $redis->select(0);
            #$self->logger->error(Dumper($host->{'group'}{$self->group_name}));

            if ( $self->var_hosts()->{$node_name} && defined($host->{'host_variable'}) ) {

                $self->logger->debug("Adding host variables for $node_name");

                my %add_values = %{$host->{'host_variable'}};

                foreach my $name ( keys %add_values ) {

                    my $sanitized_name = $name;
                    $sanitized_name =~ s/,//g; # We don't allow commas in variable names

                    my $str = 'vars.' . $sanitized_name . "," . $add_values{$name}->{'value'};

                    $redis->select(0);
                    $redis->sadd($key, $str);
                }

                $redis->select(3);
                $redis->hset($node_name, "vars", $group_poll_interval);
                $redis->hset($ip, "vars", $group_poll_interval);
            }

            # ...and the current poll_id lookup
            $redis->select(2);
            $redis->set($node_base_key , $poll_timestamp_val);
            $redis->set($ip_base_key, $poll_timestamp_val);

            # ...and expire
            $redis->expireat($node_base_key, $expires);
            $redis->expireat($ip_base_key, $expires);

            # Increment the actual reference instead of local var
            $host->{'poll_id'}++;
        }


        $redis->select(3);
        $redis->hset($node_name, $main_oid, $group_poll_interval);
        $redis->hset($ip, $main_oid, $group_poll_interval);

        # Change back to the primary db...
        $redis->select(0);
        # Complete the transaction

    } catch {
        $redis->select(0);
        $self->logger->error($self->worker_name. " $id Error in hset for data: $_" );
    };

    AnyEvent->now_update;
}


sub _connect_to_snmp {
    my $self = shift;
    my $hosts = $self->hosts;

    # Build the SNMP object for each host of interest
    foreach my $host(@$hosts) {

        my ($snmp,$error);

        # SNMP V2C
        if ( !defined($host->{'snmp_version'}) || $host->{'snmp_version'} eq '2c' ) {
            ($snmp, $error) = Net::SNMP->session(
                -hostname         => $host->{'ip'},
                -community        => $host->{'community'},
                -version          => 'snmpv2c',
                -timeout          => $self->snmp_timeout,
                -maxmsgsize       => 65535,
                -translate        => [-octetstring => 0],
                -nonblocking      => 1,
                -retries          => 5
            );

            if ( !defined($snmp) ) {
                $self->logger->error("Error creating SNMP Session: " . $error);
            }

            $self->{'snmp'}{$host->{'node_name'}} = $snmp;

        # SNMP V3
        } elsif ( $host->{'snmp_version'} eq '3' ) {

            if ( !defined($host->{'group'}{$self->group_name}{'context_id'}) ) {

                ($snmp, $error) = Net::SNMP->session(
                    -hostname         => $host->{'ip'},
                    -version          => '3',
                    -timeout          => $self->snmp_timeout,
                    -maxmsgsize       => 65535,
                    -translate        => [-octetstring => 0],
                    -username         => $host->{'username'},
                    -nonblocking      => 1,
                    -retries          => 5
                );

                if ( !defined($snmp) ) {
                    $self->logger->error("Error creating SNMP Session: " . $error);
                }

                $self->{'snmp'}{$host->{'node_name'}} = $snmp;

            } else {

                foreach my $ctxEngine ( @{$host->{'group'}{$self->group_name}{'context_id'}} ) {

                    ($snmp, $error) = Net::SNMP->session(
                        -hostname         => $host->{'ip'},
                        -version          => '3',
                        -timeout          => $self->snmp_timeout,
                        -maxmsgsize       => 65535,
                        -translate        => [-octetstring => 0],
                        -username         => $host->{'username'},
                        -nonblocking      => 1,
                        -retries          => 5
                    );

                    if( !defined($snmp) ) {
                        $self->logger->error("Error creating SNMP Session: " . $error);
                    }

                    $self->{'snmp'}{$host->{'node_name'}}{$ctxEngine} = $snmp;
                }
            }

        # SNMP Invalid
        } else {
            $self->logger->error("Invalid SNMP Version for SIMP");
        }

        my $host_poll_id;

        try {

            $self->redis->select(2);
            $host_poll_id = $self->redis->get($host->{'node_name'} . ",main_oid");
            $self->redis->select(0);

            if( !defined($host_poll_id) ) {
                $host_poll_id = 0;
            }

        } catch {
            $self->redis->select(0);
            $host_poll_id = 0;
            $self->logger->error("Error fetching the current poll cycle id from redis: $_");
        };

        $host->{'poll_id'} = $host_poll_id;
        $host->{'pending_replies'} = {};
        $host->{'failed_oids'} = {};

        $self->logger->debug($self->worker_name . " assigned host " . $host->{'node_name'});
    }
}


sub _collect_data {

    my $self = shift;

    my $hosts         = $self->hosts;
    my $oids          = $self->oids;
    my $timestamp     = time;

    $self->logger->debug("----  START OF POLLING CYCLE FOR: \"" . $self->worker_name . "\"  ----" );

    $self->logger->debug($self->worker_name . " " . $self->group_name . " with " . scalar(@$hosts) . " hosts and " . scalar(@$oids) . " oids per hosts, max outstanding scaled to " . $AnyEvent::SNMP::MAX_OUTSTANDING, " queue is " . $AnyEvent::SNMP::MIN_RECVQUEUE . " to " . $AnyEvent::SNMP::MAX_RECVQUEUE);

    for my $host (@$hosts) {

        # Used to stagger each request to a specific host, spread load.
        # This does mean you can't collect more OID bases than your interval
        my $delay = 0;

        my $node_name = $host->{'node_name'};
        # Log error and skip collections for the host if it has an OID key in pending response with a val of 1
        if ( scalar(keys %{$host->{'pending_replies'}}) > 0 ) {
            $self->logger->error("Unable to query device " . $host->{'ip'} . ":" . $node_name . " in poll cycle for group: " . $self->group_name . " remaining oids = " . Dumper($host->{'pending_replies'}));
            next;
        }

        my $snmp_session  = $self->{'snmp'}{$node_name};
        my $snmp_contexts = $host->{'group'}{$self->group_name}{'context_id'};

        if ( !defined($snmp_session) ) {
            $self->logger->error("No SNMP session defined for $node_name");
            next;
        }
        
        for my $oid (@$oids) {
            

            # Skip over an OID if it is failing
            if ( exists $host->{'failed_oids'}->{$oid} ) {

                # Log the error, skip the rest of this loop iteration
                $self->logger->error($host->{'failed_oids'}->{$oid}->{'error'});
                next;
            }

            my $reqstr = " $oid -> $host->{'ip'} ($host->{'node_name'})";
            #$self->logger->debug($self->worker_name ." requesting ". $reqstr); 

            # Iterate through the the provided set of base OIDs to collect
            my $res;
            my $res_err = "Unable to issue get_table for group \"" . $self->group_name . "\"";

            # V3 without Context and V2C (They work the same way)
            if ( $host->{'snmp_version'} eq '2c' || ! defined($snmp_contexts) ) {
                $self->logger->debug($self->worker_name . " requesting " . $reqstr);
                $res = $snmp_session->get_table(
                    -baseoid         => $oid,
                    -maxrepetitions  => $self->max_reps,
                    -delay           => $delay++,
                    -callback        => sub {
                        my $session = shift;
                        $self->_poll_cb( 
                            host        => $host,
                            timestamp   => $timestamp,
                            reqstr      => $reqstr,
                            oid         => $oid,
                            session     => $session
                        );
                    }
                );

                if ( ! $res ) {
                    # Add oid and info to failed_oids if it failed during request
                    $host->{'failed_oids'}{$oid} = {
                        error       => "OID_REQUEST_ERR: Request for $oid failed!",
                        poll_id     => $host->{'poll_id'},
                        location    => $self->config->{'config_file'},
                        group       => $self->group_name,
                        timestamp   => time()
                    };
                    
                    $self->logger->error("$res_err: " . $snmp_session->error());

                } else {
                    # Add to pending replies if request is successful
                    $host->{'pending_replies'}->{$oid} = 1;
                }

            # V3 with Context
            } elsif ( defined $snmp_contexts ) {
                # For each context engine specified for the group, also use the context
                # specific snmp_session established in _connect_to_snmp
                foreach my $ctxEngine (@$snmp_contexts) {
                    $host->{'pending_replies'}->{$oid . "," . $ctxEngine} = 1;
                    $res = $snmp_session->{$ctxEngine}->get_table(
                        -baseoid            => $oid,
                        -maxrepetitions     => $self->max_reps,
                        -contextengineid    => $ctxEngine,
                        -delay              => $delay++,
                        -callback           => sub {
                            my $session = shift;
                            $self->_poll_cb( 
                                host        => $host,
                                timestamp   => $timestamp,
                                reqstr      => $reqstr,
                                oid         => $oid,
                                context_id  => $ctxEngine,
                                session     => $session
                            );
                            $self->logger->debug("Created _poll_cb for $oid");
                        }
                    );

                    if (! $res) {
                        # Add oid and info to failed_oids if it failed during request
                        $host->{'failed_oids'}{$oid} = {
                            error       => "OID_REQUEST_ERR: Request for $oid with context $ctxEngine failed!",
                            poll_id     => $host->{'poll_id'},
                            location    => $self->config->{'config_file'},
                            group       => $self->group_name,
                            timestamp   => time()
                        };

                        $self->logger->error("$res_err with context $ctxEngine: " . $snmp_session->{$ctxEngine}->error());

                    } else {
                        # Add to pending replies if request is successful
                        $host->{'pending_replies'}->{$oid . "," . $ctxEngine} = 1;
                    } 

                }

            # Shouldn't get here, this could be misconfig?
            } else {
                $self->logger->error("Error collecting data - unsupported configuration for $node_name " . $self->group_name);
            }

        }
        
        $self->logger->debug(Dumper($host));
    }
    $self->logger->debug("----  END OF POLLING CYCLE FOR: \"" . $self->worker_name . "\"  ----" );
}

1;
