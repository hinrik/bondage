package App::Bondage::Away;

use strict;
use warnings;
use Carp;
use POE::Component::IRC::Plugin qw( :ALL );

our $VERSION = '1.0';

sub new {
    my ($package, %self) = @_;
    return bless \%self, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;
    
    if (!$irc->isa('POE::Component::IRC::State')) {
        croak __PACKAGE__ . ' requires PoCo::IRC::State or a subclass thereof';
    }
    
    $self->{Message} = 'No clients attached' unless defined $self->{Message};
    $self->{clients} = 0;
    $self->{away} = $irc->is_away($irc->nick_name());
    $irc->plugin_register($self, 'SERVER', qw(001 proxy_authed proxy_close));
    return 1;
}

sub PCI_unregister {
    return 1;
}

sub S_001 {
    my ($self, $irc) = splice @_, 0, 2;
    if (!$self->{clients}) {
        $irc->yield(away => $self->{Message});
        $self->{away} = 1;
    }
    return PCI_EAT_NONE;
}

sub S_proxy_authed {
    my ($self, $irc) = splice @_, 0, 2;
    my $client = ${ $_[0] };
    $self->{clients}++;
    if ($self->{away}) {
        $irc->yield('away');
        $self->{away} = 0;
    }
    return PCI_EAT_NONE;
}

sub S_proxy_close {
    my ($self, $irc) = splice @_, 0, 2;
    my $client = ${ $_[0] };
    $self->{clients}--;
    if (!$self->{clients}) {
        $irc->yield(away => $self->{Message});
        $self->{away} = 1;
    }
    return PCI_EAT_NONE;
}

sub message {
    my ($self, $value) = @_;
    return $self->{Message} unless defined($value);
    $self->{Message} = $value;
}

1;
__END__

=head1 NAME

App::Bondage::Away - A PoCo-IRC plugin which changes the away status
based on the presence of proxy clients, by listening for
C<irc_proxy_authed> and C<irc_proxy_close> events.

=head1 SYNOPSIS

 use App::Bondage::Away;

 $irc->plugin_add( 'Away', App::Bondage::Away->new( Message => "I'm out to lunch" ));

=head1 DESCRIPTION

App::Bondage::Away is a L<POE::Component::IRC|POE::Component::IRC> plugin.
When the last proxy client detaches, it changes the status to away, with the supplied away message.

This plugin requires the IRC component to be L<POE::Component::IRC::State|POE::Component::IRC::State>
or a subclass thereof.

=head1 CONSTRUCTOR

=over

=item C<new>

One optional argument:

'Message', the away message you want to use. Defaults to 'No clients attached'

Returns a plugin object suitable for feeding to L<POE::Component::IRC|POE::Component::IRC>'s
C<plugin_add()> method.

=back

=head1 METHODS

=over

=item message

One optional argument:

An away message

Changes the away message when called with an argument, returns the current away message otherwise.

=back

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
