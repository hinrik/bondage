package App::Bondage::Client;

use strict;
use warnings;
use Carp;
use POE qw(Filter::Line Filter::Stackable);
use POE::Component::IRC::Plugin qw( :ALL );
use POE::Filter::IRCD;

our $VERSION = '1.0';

sub new {
    my ($package, %self) = @_;
    if (!$self{Socket}) {
        croak "$package requires a Socket";
    }
    return bless \%self, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;
    
    if (!$irc->isa('POE::Component::IRC::State')) {
        croak __PACKAGE__ . ' requires PoCo::IRC::State or a subclass thereof';
    }
    
    if (!grep { $_->isa('App::Bondage::Recall') } @{ $irc->pipeline->{PIPELINE} }) {
        croak __PACKAGE__ . ' requires App::Bondage::Recall';
    }
    
    $self->{filter} = POE::Filter::Stackable->new( Filters => [ POE::Filter::Line->new(), POE::Filter::IRCD->new() ] );
    $self->{irc} = $irc;
    $irc->raw_events(1);
    $irc->plugin_register($self, 'SERVER', qw(raw));
    
    POE::Session->create(
        object_states => [
            $self => [ qw(_start _client_error _client_input) ],
        ],
    );
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    $self->_close_wheel();
    return 1;
}

sub _start {
    my $self = $_[OBJECT];
    
    $self->{wheel} = POE::Wheel::ReadWrite->new(
        Handle       => $self->{Socket},
        InputFilter  => $self->{filter},
        OutputFilter => POE::Filter::Line->new(),
        InputEvent   => '_client_input',
        ErrorEvent   => '_client_error',
    );

    # send the user modes
    if ($self->{irc}->umode()) {
        $self->{wheel}->put(':' . $self->{irc}->server_name() . ' MODE ' . $self->{irc}->nick_name() . ' :+' . $self->{irc}->umode());
    }
    
    my ($recall) = grep { $_->isa('App::Bondage::Recall') } @{ $self->{irc}->pipeline->{PIPELINE} };
    $self->{wheel}->put($recall->recall());
}

sub _client_error {
    my ($self, $id) = @_[OBJECT, ARG3];
    #$self->{irc}->plugin_del($self) if defined $self->{wheel};
}

sub _client_input {
    my ($self, $input) = @_[OBJECT, ARG0];
    
    if ($input->{command} eq 'QUIT') {
        $self->{irc}->plugin_del($self);
        return;
    }
    elsif ($input->{command} eq 'PING') {
        $self->{wheel}->put('PONG ' . $input->{params}->[0] || '');
        return;
    }
    elsif ($input->{command} eq 'PRIVMSG') {
        my ($recipient, $msg) = @{ $input->{params} }[0..1];
        if ($recipient =~ /^[#&+!]/) {
            # recreate channel messages from this client for
            # other clients to see
            my $line = ':' . $self->{irc}->nick_long_form($self->{irc}->nick_name()) . " PRIVMSG $recipient :$msg";
            
            for my $client (grep { $_->isa('App::Bondage::Client') } @{ $self->{irc}->pipeline->{PIPELINE} } ) {
                if ($client != $self) {
                    $client->put($line);
                }
            }
        }
    }
    $self->{irc}->yield(lc($input->{command}) => @{ $input->{params} });
}

sub _close_wheel {
    my $self = shift;
    $self->{irc}->send_event('irc_proxy_close' => $self->{wheel}->ID());
    delete $self->{wheel};
}

sub S_raw {
    my ($self, $irc) = splice @_, 0, 2;
    my $raw_line = ${ $_[0] };
    $self->{wheel}->put($raw_line);
    return PCI_EAT_NONE;
}

sub put {
    my ($self, $raw_line) = @_;
    $self->{wheel}->put($raw_line);
}

1;
__END__

=head1 NAME

App::Bondage::Client - A PoCo-IRC plugin which
handles a proxy client.

=head1 SYNOPSIS

 use App::Bondage::Client;

 $irc->plugin_add('Client_1', App::Bondage::Client->new( Socket => $socket ));

=head1 DESCRIPTION

App::Bondage::Client is a L<POE::Component::IRC|POE::Component::IRC> plugin.
It handles a input/output and disconnects from a proxy client.

This plugin requires the IRC component to be L<POE::Component::IRC::State|POE::Component::IRC::State>
or a subclass thereof.

=head1 CONSTRUCTOR

=over

=item C<new>

One argument:

'Socket', the socket of the proxy client.

Returns a plugin object suitable for feeding to L<POE::Component::IRC|POE::Component::IRC>'s
C<plugin_add()> method.

=back

=head1 METHODS

=over

=item C<put>

One argument:

An IRC protocol line

Sends an IRC protocol line to the client

=back

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
