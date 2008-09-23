package App::Bondage;

use strict;
use warnings;
use Carp;
use Config;
use Config::Any;
use App::Bondage::Away;
use App::Bondage::Client;
use App::Bondage::Recall;
use Digest::MD5 qw(md5_hex);
use POE qw(Filter::Line Filter::Stackable Wheel::ReadWrite Wheel::SocketFactory);
use POE::Filter::IRCD;
use POE::Component::Client::DNS;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::CTCP;
use POE::Component::IRC::Plugin::CycleEmpty;
use POE::Component::IRC::Plugin::Logger;
use POE::Component::IRC::Plugin::NickReclaim;
use POE::Component::IRC::Plugin::NickServID;
use Socket qw(inet_ntoa);

our $VERSION    = '0.2.6';
our $HOMEPAGE   = 'http://search.cpan.org/perldoc?App::Bondage';
our $CRYPT_SALT = 'erxpnUyerCerugbaNgfhW';

sub new {
    my ($package, %params) = @_;
    my $self = bless \%params, $package;
    $self->_load_config();
    
    POE::Session->create(
        object_states => [
            $self => [ qw(_start _client_error _client_input _listener_accept _listener_failed _exit) ],
        ],
    );
    return $self;
}

sub _start {
    my $self = $_[OBJECT];
    
    $self->{resolver} = POE::Component::Client::DNS->spawn();
    $self->{filter} = POE::Filter::Stackable->new(
        Filters => [
            POE::Filter::Line->new(),
            POE::Filter::IRCD->new()
        ]
    );
    
    while (my ($network_name, $network) = each %{ $self->{config}->{networks} }) {
        my $irc = $self->{ircs}->{$network_name} = POE::Component::IRC::State->spawn(
            LocalAddr    => $network->{bind_host},
            Server       => $network->{server_host},
            Port         => $network->{server_port},
            Password     => $network->{server_pass},
            UseSSL       => $network->{use_ssl},
            Useipv6      => $network->{use_ipv6},
            Nick         => $network->{nickname},
            Username     => $network->{username},
            Ircname      => $network->{realname},
            Resolver     => $self->{resolver},
            Debug        => $self->{Debug},
            plugin_debug => $self->{Debug},
            Raw          => 1,
        );
        
        $irc->plugin_add('CTCP',        POE::Component::IRC::Plugin::CTCP->new( Version => "Bondage $VERSION running on $Config{osname} $Config{osvers} -- $HOMEPAGE" ));
        $irc->plugin_add('Cycle',       POE::Component::IRC::Plugin::CycleEmpty->new()) if $network->{cycle_empty};
        $irc->plugin_add('NickReclaim', POE::Component::IRC::Plugin::NickReclaim->new());
        $irc->plugin_add('Connector',   POE::Component::IRC::Plugin::Connector->new( Delay => 120 ));
        $irc->plugin_add('AutoJoin',    POE::Component::IRC::Plugin::AutoJoin->new(
                                            Channels => $network->{channels},
                                            RejoinOnKick => $network->{kick_rejoin} ));
        
        if (defined $network->{nickserv_pass}) {
            $irc->plugin_add('NickServID', POE::Component::IRC::Plugin::NickServID->new(
                                            Password => $network->{nickserv_pass}, ));
        }
        
        if ($network->{log_public} || $network->{log_private}) {
            $irc->plugin_add('Logger', POE::Component::IRC::Plugin::Logger->new(
                                           Path         => "$self->{Work_dir}/logs/$network_name",
                                           Private      => $network->{log_private},
                                           Public       => $network->{log_public},
                                           Sort_by_date => $network->{log_sortbydate},
                                           Restricted   => $network->{log_restricted},
            ));
        }

        $irc->plugin_add('Away',   App::Bondage::Away->new( Message => $network->{away_msg}));
        $irc->plugin_add('Recall', App::Bondage::Recall->new( Mode => $network->{recall_mode} ));

        $irc->yield(connect => { });
    }
    
    $self->_spawn_listener();
    $poe_kernel->sig(INT  => '_exit');
#    $poe_kernel->sig(HUP  => '_reload');

    return;
}

sub _client_error {
    my ($self, $id) = @_[OBJECT, ARG3];
    delete $self->{wheels}->{$id};
    return;
}

sub _client_input {
    my ($self, $input, $id) = @_[OBJECT, ARG0, ARG1];
    my $info = $self->{wheels}->{$id};
    
    if ($input->{command} =~ /(PASS)/) {
        $info->{lc $1} = $input->{params}->[0];
    }
    elsif ($input->{command} =~ /(NICK|USER)/) {
        $info->{lc $1} = $input->{params}->[0];
        $info->{registered}++;
    }
    
    if ($info->{registered} == 2) {
        AUTH: {
            last AUTH if !defined $info->{pass};
            $info->{pass} = md5_hex($info->{pass}, $CRYPT_SALT) if length $self->{config}->{password} == 32;
            last AUTH unless $info->{pass} eq $self->{config}->{password};
            last AUTH unless my $irc = $self->{ircs}->{ $info->{nick} };
            $info->{wheel}->put("$info->{nick} NICK :$irc->nick_name");
            $irc->plugin_add("Client_$id" => App::Bondage::Client->new( Socket => $info->{socket} ));
            $irc->_send_event(irc_proxy_authed => $id);
            delete $self->{wheels}->{$id};
            return;
        }
        
        # wrong password or nick (network), dump the client
        $info->{wheel}->put('ERROR :Closing Link: * [' . ( $info->{user} || 'unknown' ) . '@' . $info->{ip} . '] (Unauthorised connection)' );
        delete $self->{wheels}->{$id};
    }
    
    return;
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
    
    return;
}

sub _listener_failed {
    my ($self, $error) = @_[OBJECT, ARG2];
    die "Failed to spawn listener: $error; aborted\n";
}

sub _spawn_listener {
    my ($self) = @_;
    $self->{listener} = POE::Wheel::SocketFactory->new(
        BindAddress  => $self->{config}->{listen_host},
        BindPort     => $self->{config}->{listen_port},
        SuccessEvent => '_listener_accept',
        FailureEvent => '_listener_failed',
        Reuse        => 'yes',
    );
    
    if ($self->{config}->{listen_ssl}) {
        require POE::Component::SSLify;
        POE::Component::SSLify->import(qw(Server_SSLify SSLify_Options));
        eval { SSLify_Options('bondage.key', 'bondage.crt') };
        croak "Unable to load SSL key ($self->{Work_dir}/bondage.key) or certificate ($self->{Work_dir}/bondage.crt): $!; aborted" if $@;
        eval { $self->{listener} = Server_SSLify($self->{listener}) };
        croak "Unable to SSLify the listener: $@; aborted" if $@;
    }
    return;
}

sub _load_config {
    my $self = shift;

    my $cfg = Config::Any->load_files( {
        use_ext => 1,
        files   => [ glob("$self->{Work_dir}/config.*") ],
    } );
    $self->{config} = ((values %{$cfg->[0]})[0]);

    for my $opt (qw(listen_port password)) {
        if (!defined $self->{config}->{$opt}) {
            die "Config option '$opt' must be defined; aborted\n";
        }
    }
    
    return;
}

# reload the config file
#sub _reload {
#    my $self = shift;
#    my $old_config = $self->{config};
#    $self->_load_config();
#    
#    # TODO: check for new/removed networks
#    
#    $poe_kernel->sig_handled();
#}

# die gracefully
sub _exit {
    my ($kernel, $self) = @_[KERNEL, OBJECT];
    if (defined $self->{listener}) {
        delete $self->{wheels};
        delete $self->{listener};
        $self->{resolver}->shutdown();
        $kernel->signal($kernel, 'POCOIRC_SHUTDOWN', 'Killed by user');
    }

    $kernel->sig_handled();
    return;
}

1;
__END__

=head1 NAME

App::Bondage - A featureful IRC bouncer based on POE::Component::IRC

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

=head2 Rationale

I wrote Bondage because no other IRC bouncer out there fit my needs.
Either they were missing essential features, or they were implemented
in an undesirable (if not buggy) way. I've tried to make Bondage
stay out of your way and be as transparent as possible.
It's supposed to be a proxy, after all.

=head1 FEATURES

=head2 Easy setup

Bondage is easy to get up and running. In the configuration file,
you just have to specify the port it will listen on, the password,
and some IRC server(s) you want Bondage to connect to. Everything
else has sensible defaults, though you might want to use a custom
nickname and pick some channels to join on connect.

=head2 Logging

Bondage can log both public and private messages for you.
All log files are in UTF-8.

=head2 Stays connected

Bondage will reconnect to IRC when it gets disconnected or
the IRC server stops responding.

=head2 Recall messages

Bondage can send you all the messages you missed since you detached,
or it can send you all messages received since it connected to
the IRC server, or neither. This feature is based on similar features
found in miau, dircproxy, and ctrlproxy.

=head2 Auto-away

Bondage will set your status to away when no clients are attached.

=head2 Reclaim nickname

Bondage will periodically try to change to your preferred nickname
if it is taken.

=head2 Flood protection

Bondage utilizes POE::Component::IRC's flood protection to ensure
that you never flood yourself off the IRC server.

=head2 NickServ support

Bondage can identify with NickServ for you when needed.

=head2 Rejoins channels if kicked

Bondage can try to rejoin a channel if you get kicked from it.

=head2 Encrypted passwords

Bondage supports encrypted passwords in its configuration file
for added security.

=head2 SSL support

You can connect to SSL-enabled IRC servers, and make Bondage require
SSL for client connections.

=head2 IPv6 support

Bondage can connect to IPv6 IRC servers, and also listen for client
connections via IPv6.

=head2 Cycles empty channels

Bondage can cycle (part and rejoin) channels for you when they
become empty in order to gain ops.

=head2 CTCP replies

Bondage will reply to CTCP VERSION requests when you are offline.

=head1 CONFIGURATION

The following options are recognized in the configuration file which
can be called F<~/.bondage/config.EXT> where EXT is an extension
recognized by L<Config::Any|Config::Any>.

=head2 C<listen_host>

(optional, default: "0.0.0.0")

The host that Bondage accepts connections from. This is the host you
use to connect to Bondage.

=head2 C<listen_port>

(required, no default)

The port Bondage binds to.

=head2 C<listen_ssl>

(optional, default: false)

Set this to true if you want Bondage to require the use of SSL
for client connections.
More information:
http://www.akadia.com/services/ssh_test_certificate.html

=head2 C<password>

(required, no default)

The password you use to connect to Bondage. If it is 32 characters,
it is assumed to be encrypted (see L<C<bondage -c>|bondage/"SYNOPSIS">);

B<Note:> The rest of the options are specific to the B<network>
block they appear in.

=head2 C<bind_host>

(optional, default: "0.0.0.0")

The host that Bondage binds to and connects to IRC from.
Useful if you have multiple IPs and want to choose which one
to IRC from.

=head2 C<server_host>

(required, no default)

The IRC server you want Bondage to connect to.

=head2 C<server_port>

(optional, default: 6667)

The port on the IRC server you want to use.

=head2 C<server_pass>

(optional, no default)

The IRC server password, if there is one.

=head2 C<use_ssl>

(optional, default: false)

Set this to true if you want to use SSL to communicate with
the IRC server.

=head2 C<nickserv_pass>

(optional, no default)

Your NickServ password on the IRC network, if you have one.
Bondage will identify with NickServ with this password on connect,
and whenever you switch to your original nickname.

=head2 C<nickname>

(optional, default: your UNIX user name)

Your IRC nick name.

=head2 C<username>

(optional, default: your UNIX user name)

Your IRC user name.

=head2 C<realname>

(optional, default: your UNIX real name, if any)

Your IRC real name, or email, or whatever.

=head2 C<channels>

(optional, no default)

A list of all your channels and their passwords.
Here's an example in L<YAML|YAML> format:

 channels:
   "chan1" : ""
   "chan2" : "password"
   "chan3" : ""

=head2 C<recall_mode>

(optional, default: "missed")

How many channel messages you want Bondage to remember, and then send
to you when you attach.

"missed": Bondage will only recall the channel messages you missed since
the last time you detached from Bondage.

"none": Bondage will not recall any channel messages.

"all": Bondage will recall all channel messages.

B<Note>: Bondage will always recall private messages that you missed
while you were away, regardless of this option.

=head2 C<log_public>

(optional, default: false)

Set to true if you want Bondage to log all your public messages.
They will be saved as F<~/.bondage/logs/some_network/#some_channel.log>
unless you set log_sortbydate to true.

=head2 C<log_private>

(optional, default: false)

Set to true if you want Bondage to log all private messages.
They will be saved as F<~/.bondage/logs/some_network/some_nickname.log>
unless you set log_sortbydate to true.

=head2 C<log_sortbydate>

(optional, default: false)

Set to true if you want Bondage to rotate your logs.
E.g. a channel log file might look like
F<~/.bondage/logs/some_network/#channel/2008-01-30.log>

=head2 C<log_restricted>

(optional, default: false)

Set this to true if you want Bondage to restrict the read permissions
on created log files/directories so other users won't be able to access them.

=head2 C<cycle_empty>

(optional, default: false)

Set to true if you want Bondage to cycle (part and rejoin)
opless channels if they become empty.

=head2 C<kick_rejoin>

(optional, default: false)

Set to true if you want Bondage to try to rejoin a channel (once)
if you get kicked from it.

=head1 METHODS

=head2 C<new>

Arguments:

'Work_dir', the working directory for the bouncer. Should include the config
file. This option is required.

'Debug', set to 1 to enable debugging. Default is 0.

=head1 DEPENDENCIES

The following CPAN distributions are required:

=over 

=item L<Config-Any|Config::Any>

=item L<POE|POE>

=item L<POE-Component-Client-DNS|POE::Component::Client::DNS>

=item L<POE-Component-Daemon|POE::Component::Daemon>

=item L<POE-Component-IRC|POE::Component::IRC>

=item L<POE-Component-SSLify|POE::Component::IRC> (only if you need SSL support)

=item L<POE-Filter-IRCD|POE::Filter::IRCD>

=item L<Socket6|Socket6> (only if you need ipv6 support)

=back

=head1 BUGS

Report all bugs, feature requests, etc, here:
http://rt.cpan.org/Public/Dist/Display.html?Name=App%3A%3ABondage

=head1 TODO

Exit cleanly when clients are attached.

DCC send forwarding support.

Answer common client requests like WHO/MODE without asking the server,
so other clients won't be bothered with unnecessary traffic. Look into
irssi's command redirection feature.

Reload the configuration file upon being sent a SIGHUP.

Add proper tests.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2008 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

Other useful IRC bouncers:

=over

=item L<http://miau.sourceforge.net>

=item L<http://znc.sourceforge.net>

=item L<http://dircproxy.securiweb.net>

=item L<http://ctrlproxy.vernstok.nl>

=item L<http://www.psybnc.at>

=item L<http://irssi.org/documentation/proxy>

=item L<http://bip.t1r.net>

=back

=cut
