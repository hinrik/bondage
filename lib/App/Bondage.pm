package App::Bondage;

use strict;
use warnings;
use Config;
use App::Bondage::Away;
use App::Bondage::Client;
use App::Bondage::Common;
use App::Bondage::Cycle;
use App::Bondage::Recall;
use Digest::MD5 qw(md5_hex);
use POE qw(Filter::Line Filter::Stackable Wheel::ReadWrite Wheel::SocketFactory);
use POE::Filter::IRCD;
use POE::Component::Client::DNS;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::CTCP;
use POE::Component::IRC::Plugin::Logger;
use POE::Component::IRC::Plugin::NickReclaim;
use POE::Component::IRC::Plugin::NickServID;
use Socket qw(inet_ntoa);
use YAML::Syck qw(LoadFile);

sub new {
    my ($package, %params) = @_;
    my $self = bless \%params, $package;
    $self->_load_config();
    POE::Session->create(
        object_states => [
            $self => [ qw(_start _client_error _client_input _listener_accept _listener_failed _sig_hup) ],
        ],
    );
    return $self;
}

sub _start {
    my $self = $_[OBJECT];
    $self->{filter} = POE::Filter::Stackable->new( Filters => [ POE::Filter::Line->new(), POE::Filter::IRCD->new() ] );
    $self->{resolver} = POE::Component::Client::DNS->spawn();
    
    while (my ($network_name, $network) = each %{ $self->{config}->{networks} }) {
        my $irc = $network->{irc} = POE::Component::IRC::State->spawn(
            LocalAddr => $network->{bind_host},
            Server    => $network->{server_host},
            Port      => $network->{server_port},
            Password  => $network->{server_pass},
            UseSSL    => $network->{use_ssl},
            Useipv6   => $network->{use_ipv6},
            Nick      => $network->{nickname},
            Username  => $network->{username},
            Ircname   => $network->{realname},
            Resolver  => $self->{resolver},
            Debug     => $self->{Debug},
            Raw       => 1,
        );
        $self->{ircs}->{$network_name} = $irc;
        
        $irc->plugin_add('CTCP',        POE::Component::IRC::Plugin::CTCP->new( Version => "$APP_NAME $VERSION running on $Config{osname} $Config{osvers} -- $HOMEPAGE" ));
        $irc->plugin_add('NickReclaim', POE::Component::IRC::Plugin::NickReclaim->new());
        $irc->plugin_add('Connector',   POE::Component::IRC::Plugin::Connector->new( Delay => 120 ));
        $irc->plugin_add('AutoJoin',    POE::Component::IRC::Plugin::AutoJoin->new(
                                            Channels => $network->{channels},
                                            RejoinOnKick => $network->{kick_rejoin} ));
        if (exists $network->{nickserv_pass}) {
            $irc->plugin_add('NickServID', POE::Component::IRC::Plugin::NickServID->new(
                                               Password => $network->{nickserv_pass}, ));
        }
        if ($network->{log_public} || $network->{log_private}) {
            my $log_dir = $self->{Work_dir} . '/logs';
            if (! -d $log_dir) {
                mkdir $log_dir, oct 700 or die "Cannot create directory $log_dir $!; aborted";
            }
            $irc->plugin_add('Logger', POE::Component::IRC::Plugin::Logger->new(
                                           Path => "$log_dir/$network_name",
                                           Private => $network->{log_private},
                                           Public => $network->{log_public}, ));
        }

        $irc->plugin_add('Away',   App::Bondage::Away->new( Message => $network->{away_msg}));
        $irc->plugin_add('Cycle',  App::Bondage::Cycle->new()) if $network->{auto_cycle};
        $irc->plugin_add('Recall', App::Bondage::Recall->new( Mode => $network->{recall_mode} ));

        $irc->yield(register => 'all');
        $irc->yield('connect');
    }
    
    $self->_spawn_listener();
    $poe_kernel->sig('HUP', '_sig_hup');
}

sub _client_error {
    my ($self, $id) = @_[OBJECT, ARG3];
    delete $self->{wheels}->{$id};
}

sub _client_input {
    my ($self, $input, $id) = @_[OBJECT, ARG0, ARG1];
    
    if ($input->{command} =~ /(PASS)/) {
        $self->{wheels}->{$id}->{lc $1} = $input->{params}->[0];
    }
    elsif ($input->{command} =~ /(NICK|USER)/) {
        $self->{wheels}->{$id}->{lc $1} = $input->{params}->[0];
        $self->{wheels}->{$id}->{registered}++;
    }
    
    if ($self->{wheels}->{$id}->{registered} == 2) {
        AUTH: {
            last AUTH if !defined $self->{wheels}->{$id}->{pass};
            $self->{wheels}->{$id}->{pass} = md5_hex($self->{wheels}->{$id}->{pass}, $CRYPT_SALT) if length $self->{config}->{password} == 32;
            last AUTH unless $self->{wheels}->{$id}->{pass} eq $self->{config}->{password};
            my $irc = $self->{ircs}->{$self->{wheels}->{$id}->{nick}};
            last AUTH unless $irc;
            
            $self->{wheels}->{$id}->{wheel}->put($self->{wheels}->{$id}->{nick} . ' NICK :' . $irc->nick_name());
            $irc->plugin_add("Client_$id", App::Bondage::Client->new( Socket => $self->{wheels}->{$id}->{socket} ));
            $irc->_send_event('irc_proxy_authed' => $id);
            delete $self->{wheels}->{$id};
            return;
        }
        
        # wrong password or nick (network), dump the client
        $self->{wheels}->{$id}->{wheel}->put('ERROR :Closing Link: * [' . ( $self->{wheels}->{$id}->{user} || 'unknown' ) . '@' . $self->{wheels}->{$id}->{ip} . '] (Unauthorised connection)' );
        delete $self->{wheels}->{$id};
    }
}

sub _listener_accept {
    my ($self, $socket, $peer_addr) = @_[OBJECT, ARG0, ARG1];
    my $wheel = POE::Wheel::ReadWrite->new(
        Handle       => $socket,
        InputFilter  => $self->{filter},
        OutputFilter => POE::Filter::Line->new(),
        InputEvent   => '_client_input',
        ErrorEvent   => '_client_error',
    );

    my $id = $wheel->ID();
    $self->{wheels}->{$id}->{wheel} = $wheel;
    $self->{wheels}->{$id}->{ip} = inet_ntoa($peer_addr);
    $self->{wheels}->{$id}->{registered} = 0;
    $self->{wheels}->{$id}->{socket} = $socket;
}

sub _listener_failed {
    my ($self, $wheel) = @_[OBJECT, ARG3];
    $self->_spawn_listener();
}

sub _spawn_listener {
    my $self = shift;
    $self->{listener} = POE::Wheel::SocketFactory->new(
        BindAddress  => $self->{config}->{listen_host},
        BindPort     => $self->{config}->{listen_port},
        SuccessEvent => '_listener_accept',
        FailureEvent => '_listener_failed',
        Reuse        => 'yes',
    ) or die "Failed to spawn listener: $!; aborted";
    
    if ($self->{config}->{listen_ssl}) {
        require POE::Component::SSLify;
        POE::Component::SSLify->import(qw(Server_SSLify SSLify_Options));
        eval { SSLify_Options("$APP_NAME.key", "$APP_NAME.crt") };
        die 'Unable to load SSL key (' . $self->{Work_dir} . "/$APP_NAME.key) or certificate (" . $self->{Work_dir} . "/$APP_NAME.crt): $!; aborted" if $!;
        eval { $self->{listener} = Server_SSLify($self->{listener}) };
        die "Unable to SSLify the listener: $!; aborted" if $!;
    }
}

sub _load_config {
    my $self = shift;
    $YAML::Syck::ImplicitTyping = 1;
    $self->{config} = LoadFile($self->{Work_dir} . '/config.yml');
    for my $opt (qw(listen_port password)) {
        if (!defined $self->{config}->{$opt}) {
            die "Config option '$opt' must be defined; aborted";
        }
    }
}

# reload the config file
sub _sig_hup {
    my $self = shift;
    my $old_config = $self->{config};
    $self->_load_config();
    
    # TODO: check for new/removed networks
    
    $poe_kernel->sig_handled();
}

1;
