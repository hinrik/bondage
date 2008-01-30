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
        
        $irc->plugin_add('CTCP',        POE::Component::IRC::Plugin::CTCP->new( Version => "Bondage $VERSION running on $Config{osname} $Config{osvers} -- $HOMEPAGE" ));
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
                                           Path       => "$log_dir/$network_name",
                                           Private    => $network->{log_private},
                                           Public     => $network->{log_public},
                                           SortByDate => $network->{log_rotate},
            ));
        }

        $irc->plugin_add('Away',   App::Bondage::Away->new( Message => $network->{away_msg}));
        $irc->plugin_add('Cycle',  App::Bondage::Cycle->new()) if $network->{auto_cycle};
        $irc->plugin_add('Recall', App::Bondage::Recall->new( Mode => $network->{recall_mode} ));

        $irc->yield(register => 'all');
        $irc->yield('connect');
    }
    
    $self->_spawn_listener();
    $poe_kernel->sig(HUP => '_sig_hup');
    #$poe_kernel->sig(INT => '_sig_int');
}

sub _client_error {
    my ($self, $id) = @_[OBJECT, ARG3];
    delete $self->{wheels}->{$id};
}

sub _client_input {
    my ($self, $kernel, $input, $id) = @_[OBJECT, KERNEL, ARG0, ARG1];
    
    if ($input->{command} =~ /(PASS)/) {
        $self->{wheels}->{$id}->{lc $1} = $input->{params}->[0];
    }
    elsif ($input->{command} =~ /(NICK|USER)/) {
        $self->{wheels}->{$id}->{lc $1} = $input->{params}->[0];
        $self->{wheels}->{$id}->{registered}++;
    }
    
    if ($self->{wheels}->{$id}->{registered} == 2) {
        my $info = $self->{wheels}->{$id};
        AUTH: {
            last AUTH if !defined $info->{pass};
            $info->{pass} = md5_hex($info->{pass}, $CRYPT_SALT) if length $self->{config}->{password} == 32;
            last AUTH unless $info->{pass} eq $self->{config}->{password};
            last AUTH unless my $irc = $self->{ircs}->{$info->{nick}};
            
            $info->{wheel}->put($info->{nick} . ' NICK :' . $irc->nick_name());
            $irc->plugin_add("Client_$id" => App::Bondage::Client->new( Socket => $info->{socket} ));
            $irc->_send_event('irc_proxy_authed' => $id);
            delete $self->{wheels}->{$id};
            return;
        }
        
        # wrong password or nick (network), dump the client
        $info->{wheel}->put('ERROR :Closing Link: * [' . ( $info->{user} || 'unknown' ) . '@' . $info->{ip} . '] (Unauthorised connection)' );
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
        eval { SSLify_Options("bondage.key", "bondage.crt") };
        die 'Unable to load SSL key (' . $self->{Work_dir} . '/bondage.key) or certificate (' . $self->{Work_dir} . "/bondage.crt): $!; aborted" if $!;
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

# die gracefully
#sub _sig_int {
#    my $self = shift;
#    delete $self->{listener};
#    for my $irc (values %{ $self->{ircs} }) {
#        $irc->yield(shutdown => 'Killed by user');
#    }
#    $poe_kernel->sig_handled();
#}

1;

=head1 NAME

App::Bondage - A featureful easy-to-use IRC bouncer

=head1 SYNOPSIS

 my $bouncer = App::Bondage->new(
     Debug    => $debug,
     Work_dir => $work_dir,
 );

=head1 DESCRIPTION

Bondage is an IRC bouncer. It acts as a proxy between multiple
IRC servers and multiple IRC clients. It makes it easy to stay
permanently connected to IRC. It is mostly made up of reusable
components. Very little is made from scratch here. If it is,
it will be made modular and reusable, probably as a 
L<POE::Component::IRC|POE::Component::IRC> plugin. This keeps
the code short and (hopefully) well tested by others.

=head2 RATIONALE

I wrote Bondage because no other IRC bouncer out there fit my needs.
Either they were missing essential features, or they were implemented
in an undesirable (if not buggy) way. I've tried to make B<bondage>
stay out of your way and be as transparent as possible.
It's supposed to be a proxy, after all.

=head2 FEATURES

=over

=item Easy setup

Bondage is easy to get up and running. In the configuration file,
you just have to specify the port it will listen on, the password,
and some IRC server(s) you want Bondage to connect to. Everything
else has sensible defaults, though you might want to use a custom
nickname and pick some channels to join on connect.

=item Logging

Bondage can log both public and private messages for you.
All log files are in UTF-8.

=item Stays connected

Bondage will reconnect to IRC when it gets disconnected or
the IRC server stops responding.

=item Recall messages

Bondage can send you all the messages you missed since you detached,
or it can send you all messages received since it connected to
the IRC server, or neither. This feature is based on similar features
found in miau, dircproxy, and ctrlproxy.

=item Auto-away

Bondage will set your status to away when no clients are attached.

=item Reclaim nickname

Bondage will periodically try to change to your preferred nickname
if it is taken.

=item Flood protection

Bondage utilizes POE::Component::IRC's flood protection to ensure
that you never flood yourself off the IRC server.

=item NickServ support

Bondage can identify with NickServ for you when needed.

=item Rejoin channel if kicked

Bondage can try to rejoin a channel if you get kicked from it.

=item Encrypted passwords

Bondage supports encrypted passwords in its configuration file
for added security.

=item SSL support

You can connect to SSL-enabled IRC servers, and make B<bondage> require
SSL for client connections.

=item IPv6 support

Bondage can connect to IPv6 IRC servers, and also listen for client
connections via IPv6.

=item Cycle empty channels

Bondage can cycle (part and rejoin) channels for you when they
become empty in order to gain ops.

=item CTCP replies

Bondage will reply to CTCP VERSION requests when you are offline.

=back

=head1 CONFIGURATION

The following options are recognized in the configuration file
which should (by default) be C<~/.bondage/config.yml>

B<Note>: You may not use tabs for indentation.

=over

=item listen_host

(optional, default: "0.0.0.0")

The host that Bondage> listens on and accepts connections from.
This is the host you use to connect to Bondage.

=item listen_port

(required, no default)

The port Bondage binds to.

=item listen_ssl

(optional, default: false)

Set this to true if you want bondage to require the use of SSL
for client connections.
More information:
http://www.akadia.com/services/ssh_test_certificate.html

=item password

(required, no default)

The password you use to connect to Bondage. If it is 32 letters,
it is assumed to be encrypted (see C<bondage -c>);

=back

B<Note:> The rest of the options are specific to the B<network>
block they appear in.

=over

=item bind_host

(optional, default: "0.0.0.0")

The host that Bondage binds to and connects to IRC from.
Useful if you have multiple IPs and want to choose which one
to IRC from.

=item server_host

(required, no default)

The IRC server you want Bondage to connect to.

=item server_port

(optional, default: 6667)

The port on the IRC server you want to use.

=item server_pass

(optional, no default)

The IRC server password, if there is one.

=item use_ssl

(optional, default: false)

Set this to true if you want to use SSL to communicate with
the IRC server.

=item nickserv_pass

(optional, no default)

Your NickServ password on the IRC network, if you have one.
Bondage will identify with NickServ with this password on connect,
and whenever you switch to your original nickname.

=item nickname

(optional, default: your UNIX user name)

Your IRC nick name.

=item username

(optional, default: your UNIX user name)

Your IRC user name.

=item realname

(optional, default: your UNIX real name, if any)

Your IRC real name, or email, or whatever.

=item channels

(optional, no default)

A list of all your channels, with the optional password after each colon.
Every line must include a colon. E.g.:

 channels:
   "chan1" : ""
   "chan2" : "password"
   "chan3" : ""

=item recall_mode

(optional, default: "new")

How many channel messages you want Bondage to remember, and then send
to you when you attach.

"new": Bondage will only recall the channel messages you missed since
the last time you detached from Bondage.

"none": Bondage will not recall any channel messages.

"all": Bondage will recall all channel messages, and will
only discard them when you leave the channel (wilfully).

B<Note>: Bondage will always recall private messages that you missed
while you were away, regardless of this option.

=item log_public

(optional, default: false)

Set to true if you want Bondage to log all your public messages.
They will be saved as C<~/.bondage/logs/some_network/#some_channel.log>
unless you set log_rotate to true.

=item log_private

(optional, default: false)

Set to true if you want Bondage to log all private messages.
They will be saved as C<~/.bondage/logs/some_network/some_nickname.log>
unless you set log_rotate to true.

=item log_rotate

(optional, default: false)

Set to true if you want Bondage to rotate your logs.
E.g. a channel log file might look like C<~/.bondage/logs/some_network/#channel/2008-01-30.log>

=item auto_cycle

(optional, default: false)

Set to true if you want Bondage to cycle (part and rejoin)
opless channels if they become empty.

=item kick_rejoin

(optional, default: false)

Set to true if you want Bondage to try to rejoin a channel (once)
if you get kicked from it.

=back

=head1 DEPENDENCIES

The following CPAN distributions are required:

 POE
 POE-Component-Client-DNS
 POE-Component-Daemon
 POE-Component-IRC
 POE-Component-SSLify (only if you need SSL support)
 POE-Filter-IRCD
 Socket6 (only if you need ipv6 support)
 YAML-Syck

=head1 BUGS

Report all bugs, feature requests, etc, here:
http://code.google.com/p/bondage/issues

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2008 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

Other useful IRC bouncers:

 http://miau.sourceforge.net
 http://znc.sourceforge.net
 http://dircproxy.securiweb.net
 http://ctrlproxy.vernstok.nl
 http://www.psybnc.at
 http://irssi.org/documentation/proxy
 http://bip.t1r.net

