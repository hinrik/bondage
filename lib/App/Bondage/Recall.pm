package App::Bondage::Recall;

use strict;
use warnings;
use Carp;
use File::Temp qw(tempfile);
use POE::Component::IRC::Common qw( parse_user );
use POE::Component::IRC::Plugin qw( :ALL );
use POE::Component::IRC::Plugin::BotTraffic;
use POE::Filter::IRCD;
#use Tie::File;

our $VERSION = '1.2';

sub new {
    my ($package, %self) = @_;
    if (!$self{Mode} || $self{Mode} !~ /(missed|all|none)/) {
        $self{Mode} = 'missed';
    }
    return bless \%self, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;
    
    if (!$irc->isa('POE::Component::IRC::State')) {
        croak __PACKAGE__ . ' requires PoCo::IRC::State or a subclass thereof';
    }
    
    if (!grep { $_->isa('POE::Component::IRC::Plugin::BotTraffic') } @{ $irc->pipeline->{PIPELINE} }) {
        $irc->plugin_add('BotTraffic', POE::Component::IRC::Plugin::BotTraffic->new());
    }
    
    $self->{irc} = $irc;
    $self->{filter} = POE::Filter::IRCD->new();
    $self->{clients} = 0;
    $self->{recall} = [ ];
    #tie @{ $self->{recall} }, 'Tie::File', scalar tempfile() if $self->{Mode} =~ /(all|missed)/;
    $irc->raw_events(1);
  
    $irc->plugin_register($self, 'SERVER', qw(bot_ctcp_action bot_public connected ctcp_action msg part proxy_authed proxy_close raw));
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;
    delete $self->{irc};
    return 1;
}

sub S_bot_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;
    my $recipients = join (',', @{ ${ $_[0] } });
    my $msg = ${ $_[1] };
    
    if ($self->{Mode} =~ /(all|missed)/) {
        my $line = ':' . $irc->nick_long_form($irc->nick_name()) . " PRIVMSG $recipients :\x01ACTION $msg\x01";
        push @{ $self->{recall} }, $line;
    }
    
    return PCI_EAT_NONE;
}

sub S_bot_public {
    my ($self, $irc) = splice @_, 0, 2;
    my $recipients = join (',', @{ ${ $_[0] } });
    my $msg = ${ $_[1] };

    if ($self->{Mode} =~ /(all|missed)/) {
        my $line = ':' . $irc->nick_long_form($irc->nick_name()) . " PRIVMSG $recipients :$msg";
        push @{ $self->{recall} }, $line;
    }
    
    return PCI_EAT_NONE;
}

sub S_connected {
    my ($self, $irc) = splice @_, 0, 2;
    $self->{stash} = [ ];
    $self->{stashing} = 1;
    return PCI_EAT_NONE;
}

sub S_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;
    my $sender = ${ $_[0] };
    my $recipients = ${ $_[1] };
    my $msg = ${ $_[2] };
    return PCI_EAT_NONE if $self->{clients};
    
    for my $recipient (@{ $recipients }) {
        if ($recipient eq $irc->nick_name()) {
            my $line = ":$sender PRIVMSG " . $irc->nick_name() . " :\x01ACTION$msg\x01";
            push @{ $self->{recall} }, $line;
        }
    }
    return PCI_EAT_NONE;
}

sub S_msg {
    my ($self, $irc) = splice @_, 0, 2;
    my $sender = ${ $_[0] }->[0];
    my $msg = ${ $_[2] };
    
    if (!$self->{clients}) {
        my $line = ":$sender PRIVMSG " . $irc->nick_name() . " :$msg";
        push @{ $self->{recall} }, $line;
    }
    
    return PCI_EAT_NONE;
}

sub S_part {
    my ($self, $irc) = splice @_, 0, 2;
    my $chan = ${ $_[1] };

    if (my $cycle = grep { $_->isa('POE::Component::IRC::Plugin::CycleEmpty') } @{ $irc->pipeline->{PIPELINE} } ) {
        return PCI_EAT_NONE if $cycle->cycling($chan);
    }

    if ($self->{Mode} eq 'all') {
        # remove all messages related to this channel
        my $input = $self->{filter}->get( $self->{recall} );
        for my $line (0..$#{ $self->{recall} }) {
            if (lc $input->[$line]->{params}->[0] eq lc $chan) {
                delete $self->{recall}->[$line];
            }
            elsif ($input->[$line]->{command} =~ /(332|333|366)/ && lc $input->[$line]->{params}->[1] eq lc $chan) {
                delete $self->{recall}->[$line];
            }
            elsif ($input->[$line]->{command} eq '353' && lc $input->[$line]->{params}->[2] eq lc $chan) {
                delete $self->{recall}->[$line];
            }
        }
    }
    
    return PCI_EAT_NONE;
}

sub S_proxy_authed {
    my ($self, $irc) = splice @_, 0, 2;
    $self->{clients}++;
    return PCI_EAT_NONE;
}

sub S_proxy_close {
    my ($self, $irc) = splice @_, 0, 2;
    $self->{clients}--;
    
    if ($self->{Mode} eq 'missed' && !$self->{clients}) {
        $self->{recall} = [ ];
        push @{ $self->{recall} }, $self->_get_chaninfo();
    }
    
    return PCI_EAT_NONE;
}

sub S_raw {
    my ($self, $irc) = splice @_, 0, 2;
    my $raw_line = ${ $_[0] };
    my $input = $self->{filter}->get( [ $raw_line ] )->[0];
    
    if ($self->{stashing}) {
        # capture all numeric commands until we've got the MOTD
        if ($input->{command} =~ /\d\d\d/) {
            push @{ $self->{stash} }, $raw_line;
        }
        # RPL_ENDOFMOTD / ERR_NOMOTD
        if ($input->{command} =~ /(376|422)/) {
            $self->{stashing} = 0;
        }
    }
    
    if ($self->{Mode} =~ /(all|missed)/) {
        if ($input->{command} eq 'PRIVMSG' && $input->{params}->[0] =~ /^[#&+!]/) {
            # channel messages
            push @{ $self->{recall} }, $raw_line;
        }
        elsif ($input->{command} eq 'MODE' && $input->{params}->[0] =~ /^[#&+!]/) {
            # channel mode changes
            push @{ $self->{recall} }, $raw_line;
        }
        elsif ($input->{command} =~ /(JOIN|KICK|PART|QUIT|NICK|353|366)/) {
            # other channel-related things
            push @{ $self->{recall} }, $raw_line;
        }
        elsif ($input->{command} =~ /(332|333)/) {
            # only log topic stuff if we were just joining the channel
            push @{ $self->{recall} }, $raw_line if !$irc->channel_list($input->{params}->[0]);
        }
    }
        
    return PCI_EAT_NONE;
}

sub _get_chaninfo {
    my $self = shift;
    my $irc = $self->{irc};
    my $me = $irc->nick_name();
    my $server = $irc->server_name();

    my @info;
    for my $chan (keys %{ $irc->channels() }) {
        push @info, ':' . $irc->nick_long_form($me) . " JOIN :$chan";        

        if (keys %{ $irc->channel_topic($chan) }) {
            my $topic_info = $irc->channel_topic($chan);
            push @info, ":$server 332 $me $chan " . ':' . $topic_info->{Value};
            push @info, ":$server 333 $me $chan " . $topic_info->{SetBy} . ' ' . $topic_info->{SetAt};
        }
        
        my $modes = $irc->channel_modes($chan);
        my $type = '=';
        $type = '@' if $irc->is_channel_mode_set($chan, 's');
        $type = '*' if $irc->is_channel_mode_set($chan, 'p');
        my $length = length($server) + 3 + length($chan) + length($me) + 7;
        my $buffer = '';
        
        my @nicks = map { 
            my $nick = $_;
            my $prefix = '';
            $prefix = '@' if $irc->is_channel_operator($chan, $nick);
            $prefix = '%' if $irc->is_channel_halfop($chan, $nick) and !$prefix;
            $prefix = '+' if $irc->has_channel_voice($chan, $nick) and !$prefix;
            $prefix . $nick;
        } $irc->channel_list($chan);
        
        for my $nick (sort @nicks) {
            if (length(join ' ', $buffer, $nick) + $length > 510) {
                push @info, ":$server 353 $me $type $chan :$buffer";
                $buffer = $nick;
                next;
            }
            if ($buffer) {
                $buffer = join ' ', $buffer, $nick;
            }
            else {
                $buffer = $nick;
            }
        }
        push @info, ":$server 353 $me $type $chan $buffer";
        push @info, ":$server 366 $me $chan :End of /NAMES list.";
    }

    return @info;
}

sub recall {
    my $self = shift;
    my @lines = ();
    
    my $me = $self->{irc}->nick_name();
    for my $line (@{ $self->{stash} }) {
        $line =~ s/(\S+\s+\S+) +\S+ +(.*)/$1 $me $2/;
        push @lines, $line;
    }
    push @lines, @{ $self->{recall} };

    if ($self->{Mode} eq 'all') {
        # remove the old PMs, since we've seen 'em now
        for my $line (0..$#{ $self->{recall} }) {
            my $in = shift @{ $self->{filter}->get( $self->{recall} ) };
            if ($in->{command} eq 'PRIVMSG' && $in->{params}->[0] !~ /^[#&+!]/) {
                delete $self->{recall}->[$line];
            }
        }

    }
    elsif ($self->{Mode} eq 'missed') {
        $self->{recall} = [ ];
        push @{ $self->{recall} }, $self->_get_chaninfo();
    }
    elsif ($self->{Mode} eq 'none') {
        $self->{recall} = [ ];
        push @lines, $self->_get_chaninfo();
    }
    
    return @lines;
}

1;

=head1 NAME

App::Bondage::Recall - A PoCo-IRC plugin which can greet proxy clients
with the messages they missed while they were away, among other things.

=head1 SYNOPSIS

 use App::Bondage::Recall;

 $irc->plugin_add('Recall', App::Bondage::Recall->new( Mode => 'missed' ));

=head1 DESCRIPTION

App::Bondage::Recall is a L<POE::Component::IRC|POE::Component::IRC> plugin.
It uses on Log::Log4perl to log messages and CTCP ACTIONs to either #some_channel.log or
some_nickname.log in the supplied path.

This plugin requires the IRC component to be L<POE::Component::IRC::State|POE::Component::IRC::State>
or a subclass thereof. It also requires a L<POE::Component::IRC::Plugin::BotTraffic|POE::Component::IRC::Plugin::BotTraffic>
to be in the plugin pipeline. It will be added automatically if it is not present.

=head1 METHODS

=over

=item new

One optional argument:

'Mode', which public messages you want it to recall. 'missed', the default, makes it only recall
public messages that were received while no proxy client was attached. 'all' will recall
public messages from all channels since they were joined. 'none' will recall none. The plugin
will always recall missed private messages, regardless of this option.

Returns a plugin object suitable for feeding to L<POE::Component::IRC|POE::Component::IRC>'s
plugin_add() method.

=back

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
