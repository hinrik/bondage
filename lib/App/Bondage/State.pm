package App::Bondage::State;

use strict;
use warnings;
use POE::Component::IRC::Common qw(parse_user u_irc);
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);

require Exporter;
use base qw( Exporter );
our @EXPORT_OK = qw(topic_reply names_reply who_reply mode_reply);
our %EXPORT_TAGS = ( ALL => [@EXPORT_OK] );

our $VERSION = '1.0';

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;
    $self->{irc} = $irc;
    $irc->plugin_register($self, SERVER => qw(001 join chan_sync nick_sync));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    return 1;
}

sub S_001 {
    my ($self, $irc) = splice @_, 0, 2;
    $self->{syncing}    = { };
    $self->{queue} = { };
    return PCI_EAT_NONE;
}

sub S_join {
    my ($self, $irc) = splice @_, 0, 2;
    my $mapping = $irc->isupport('CASEMAPPING');
    my $unick = u_irc((parse_user(${ $_[0] }))[0], $mapping);
    my $uchan = u_irc(${ $_[1] }, $mapping);
    
    if ($unick eq u_irc($irc->nick_name(), $mapping)) {
        $self->{syncing}->{$uchan} = 1;
    }
    else {
        $self->{syncing}->{$unick} = 1;
    }

    return PCI_EAT_NONE;
}

sub S_chan_sync {
    my ($self, $irc) = splice @_, 0, 2;
    my $mapping = $irc->isupport('CASEMAPPING');
    my $uchan = u_irc(${ $_[0] }, $mapping);
    delete $self->{syncing}->{$uchan};
    $self->_flush_queue($uchan);
    return PCI_EAT_NONE;
}

sub S_nick_sync {
    my ($self, $irc) = splice @_, 0, 2;
    my $mapping = $irc->isupport('CASEMAPPING');
    my $unick = u_irc(${ $_[0] }, $mapping);
    delete $self->{syncing}->{$unick};
    $self->_flush_queue($unick);
    return PCI_EAT_NONE;
}

sub _flush_queue {
    my ($self, $what) = @_;
    return if !$self->{queue}->{$what};

    for my $request (@{ $self->{queue}->{$what} }) {
        my ($client, $reply, $args) = @{ $request };
        $self->$reply($client, $what, @{ $args });
    }
    delete $self->{queue}->{$what};
}

sub _syncing {
    my ($self, $what) = @_;
    my $mapping = $self->{irc}->isupport('CASEMAPPING');
    my $uwhat = u_irc($what, $mapping);

    return 1 if $self->{syncing}->{$uwhat};
    return;
}

sub enqueue {
    my ($self, $client, $reply, $what, @args) = @_;
    my $mapping = $self->{irc}->isupport('CASEMAPPING');

    if ($self->_syncing($what)) {
        push @{ $self->{queue}->{u_irc($what, $mapping)} }, [$client, $reply, \@args];
    }
    else {
        $client->put( $self->$reply($what) );
    }
}

# handles /^TOPIC (\S+)$/ where $1 is a channel that we're on
sub topic_reply {
    my ($self, $chan) = @_;
    my $irc     = $self->{irc};
    my $me      = $irc->nick_name();
    my $server  = $irc->server_name();
    my @results;
    
    if (!keys %{ $irc->channel_topic($chan) }) {
        push @results, ":$server 331 $me $chan :No topic is set";
    }
    else {
        my $topic_info = $irc->channel_topic($chan);
        push @results, ":$server 332 $me $chan :" . $topic_info->{Value};
        push @results, ":$server 333 $me $chan " . join(' ', @{$topic_info}{qw(SetBy SetAt)});
    }

    return @results;

}

# handles /^NAMES (\S+)$/ where $1 is a channel that we're on
sub names_reply {
    my ($self, $chan) = @_;
    my $irc       = $self->{irc};
    my $me        = $irc->nick_name();
    my $server    = $irc->server_name(); 
    my $chan_type = '=';
    $chan_type    = '@' if $irc->is_channel_mode_set($chan, 's');
    $chan_type    = '*' if $irc->is_channel_mode_set($chan, 'p');
    
    my @nicks = sort map { 
        my $nick = $_;
        my $prefix = '';
        $prefix = '+' if $irc->has_channel_voice($chan, $nick);
        $prefix = '%' if $irc->is_channel_halfop($chan, $nick);
        $prefix = '@' if $irc->is_channel_operator($chan, $nick);
        $prefix . $nick;
    } $irc->channel_list($chan);
    
    my $length = length($server) + bytes::length($chan) + bytes::length($me) + 11;
    my @results;
    my $nick_list = shift @nicks;
    
    for my $nick (@nicks) {
        if (bytes::length("$nick_list $nick") + $length <= 510) {
            $nick_list .= " $nick";
        }
        else {
            push @results, ":$server 353 $me $chan_type $chan :$nick_list";
            $nick_list = $nick;
        }
    }
    
    push @results, ":$server 353 $me $chan_type $chan :$nick_list";
    push @results, ":$server 366 $me $chan :End of NAMES list";

    return @results;
}

# handles /^WHO (\S+)$/ where $1 is a channel or a nickname, NOT a mask
sub who_reply {
    my ($self, $who) = @_;
    my $irc     = $self->{irc};
    my $me      = $irc->nick_name();
    my $server  = $irc->server_name();
    my $prefix  = $who =~ /^[#&+!]/ ? $who : '*';

    my @members;
    @members = $irc->channel_list($who) if $irc->is_channel_member($who, $me);
    @members = ($who) if $irc->_nick_exists($who);

    my @results;
    for my $member (@members) {
        my ($nick, $user, $host) = parse_user($irc->nick_long_form($member));
            
        my $status = $irc->is_away($nick) ? 'G' : 'H';
        $status .= '*' if $irc->is_operator($nick);
        $status .= '@' if $irc->is_channel_operator($who, $nick);
        $status .= '%' if $irc->is_channel_halfop($who, $nick);
        $status .= '+' if $irc->has_channel_voice($who, $nick) && !$irc->is_channel_operator($who, $nick);
            
        my ($real, $user_server, $hops) = @{ $irc->nick_info($nick) }{qw(Real Server Hops)};
        push @results, ":$server 352 $me $prefix $user $host $user_server $nick $status :$hops $real";
    }

    push @results, ":$server 315 $me $who :End of WHO list";
    return @results;
}   

# handles /^MODE #chan( [Ieb])?$/ and /^MODE our_nick$/
sub mode_reply {
    my ($self, $chan, $type) = @_;
    my $irc     = $self->{irc};
    my $mapping = $irc->isupport('CASEMAPPING');
    my $me      = $irc->nick_name();
    my $server  = $irc->server_name();
    my @results;
    
    if (u_irc($chan, $mapping) eq u_irc($me, $mapping)) {
        return ":$server 221 $me :+" . $irc->umode();
    }
    elsif (!defined $type) {
        my $modes = $irc->channel_modes($chan);
        
        my $mode_string = '';
        while (my ($mode, $arg) = each %{ $modes }) {
            if (!length $arg) {
                $mode_string .= $mode;
                delete $modes->{$mode};
            }
        }
        
        my @args;
        while (my ($mode, $arg) = each %{ $modes }) {
            $mode_string .= $mode;
            push @args, $arg;
        }
        
        $mode_string .= ' ' . join ' ', @args if @args;        
        push @results, ":$server 324 $me $chan +$mode_string";
        
        if ($irc->channel_creation_time($chan)) {
            my $time = $irc->channel_creation_time($chan);
            push @results, ":$server 329 $me $chan $time";
        }
    }
    elsif ($type eq 'I') {
        while (my ($mask, $info) = each %{ $irc->channel_invex_list($chan) }) {
            push @results, ":$server 346 $me $chan $mask " . join (' ', @{$info}{qw(SetBy SetAt)});
        }
        push @results, ":$server 347 $me $chan :End of Channel Invite List";
    }
    elsif ($type eq 'e') {
        while (my ($mask, $info) = each %{ $irc->channel_except_list($chan) }) {
            push @results, ":$server 348 $me $chan $mask " . join (' ', @{$info}{qw(SetBy SetAt)});
        }
        push @results, ":$server 349 $me $chan :End of Channel Exception List";
    }
    elsif ($type eq 'b') {
        while (my ($mask, $info) = each %{ $irc->channel_ban_list($chan) }) {
            push @results, ":$server 367 $me $chan $mask " . join (' ', @{$info}{qw(SetBy SetAt)});
        }
        push @results, ":$server 368 $me $chan :End of Channel Ban List";
    }
    
    return @results;
}

1;
__END__

=head1 NAME

App::Bondage::State - Generates IRC server replies based on information
provided by L<POE::Component::IRC::State|POE::Component::IRC::State>.

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
