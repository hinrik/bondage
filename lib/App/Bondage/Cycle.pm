package App::Bondage::Cycle;

use strict;
use warnings;
use Carp;
use POE::Component::IRC::Plugin qw( :ALL );
use POE::Component::IRC::Common qw( parse_user );

our $VERSION = '1.2';

sub new {
    my ($package, %self) = @_;
    return bless \%self, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;
    
    if (!$irc->isa('POE::Component::IRC::State')) {
        croak __PACKAGE__ . ' requires PoCo::IRC::State or a subclass thereof';
    }
    
    $self->{cycling} = { };
    $self->{irc} = $irc;
    $irc->plugin_register($self, 'SERVER', qw(join kick part quit));
    return 1;
}

sub PCI_unregister {
    return 1;
}

sub S_join {
    my ($self, $irc) = splice @_, 0, 2;
    my $chan = ${ $_[1] };
    delete $self->{cycling}->{$chan};
    return PCI_EAT_NONE;
}

sub S_kick {
    my ($self, $irc) = splice @_, 0, 2;
    my $chan = ${ $_[1] };
    my $victim = ${ $_[2] };
    $self->_cycle($chan) if $victim ne $irc->nick_name();
    return PCI_EAT_NONE;
}

sub S_part {
    my ($self, $irc) = splice @_, 0, 2;
    my $parter = parse_user(${ $_[0] });
    my $chan = ${ $_[1] };
    $self->_cycle($chan) if $parter ne $irc->nick_name();
    return PCI_EAT_NONE;
}

sub S_quit {
    my ($self, $irc) = splice @_, 0, 2;
    my $quitter = parse_user(${ $_[0] });
    my $channels = @{ $_[2] }[0];
    if ($quitter ne $irc->nick_name()) {
        for my $chan (@{ $channels }) {
            $self->_cycle($chan);
        }
    }
    return PCI_EAT_NONE;
}

sub _cycle {
    my ($self, $chan) = @_;
    my $irc = $self->{irc};
    if ($irc->channel_list($chan) == 1) {
        if (!$irc->is_channel_operator($chan, $irc->nick_name)) {
            $self->{cycling}->{$chan} = 1;
            my $topic = $irc->channel_topic($chan);
            $irc->yield(part => $chan);
            $irc->yield(join => $chan => $irc->channel_key($chan));
            $irc->yield(topic => $chan => $topic->{Value}) if defined $topic->{Value};
        }
    }
}

sub cycling {
    my ($self, $value) = @_;
    $self->{cycling}->{$value} ? return 1 : return 0;
}

1;

=head1 NAME

App::Bondage::Cycle - A PoCo-IRC plugin which cycles (parts and rejoins)
channels if they become empty and opless, in order to gain ops.

=head1 SYNOPSIS

 use App::Bondage::Cycle;

 $irc->plugin_add( 'Cycle', App::Bondage::Cycle->new();

=head1 DESCRIPTION

App::Bondage::Cycle is a L<POE::Component::IRC|POE::Component::IRC> plugin.
When someone quits, gets kicked, or parts a channel, the plugin will cycle the channel
if the IRC component is alone on that channel and is not a channel operator.
If there was a topic set on the channel, it will be restored afterwards.

This plugin requires the IRC component to be L<POE::Component::IRC::State|POE::Component::IRC::State>
or a subclass thereof.

=head1 METHODS

=over

=item new

Returns a plugin object suitable for feeding to L<POE::Component::IRC|POE::Component::IRC>'s
plugin_add() method.

=item cycling

One argument:

A channel name

Returns 1 if the plugin is currently cycling that channel, 0 otherwise.

=back

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
