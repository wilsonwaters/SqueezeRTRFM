package Plugins::RTRFM::OnDemand;

# On-demand menus: RTRFM 92.1 -> Programs -> <program> -> episodes (hook API: see Plugin.pm).
# init registers the rtrfm:// protocol handler used by episode URLs
# (Plugins::RTRFM::Util::episodeUrl); the handler itself lives in Plugins::RTRFM::ProtocolHandler.
#
# Data comes from Plugins::RTRFM::Airnet. The menus are built by four small, data-driven
# builders. Their contract (other ondemand tasks extend them and rely on it):
#
#   Feed builders are XMLBrowser coderef feeds, called as ($client, $cb, $args, @passthrough),
#   and call $cb->({ items => \@items }) exactly once: on success, on an empty result and on
#   error (then @items is one 'text' item). $client may be undef (CLI without a player).
#
#     _programsFeed($client, $cb, $args)             items = map _programItem, programs
#     _episodesFeed($client, $cb, $args, $program)   items = map _episodeItem, episodes in the
#                                                    28-day window; writes the episode metadata
#                                                    cache (Util::setEpisodeMeta) for each
#
#   Item builders return one item hash:
#
#     _programItem($client, $program)
#     _episodeItem($client, $program, $episode)
#
#   Hash shapes:
#     $program = { slug, name, image }   image is undef until artwork is available; other keys
#                                        may be added. Builders pass the hash on untouched.
#     $episode = as returned by Plugins::RTRFM::Airnet::episodes
#                { slug, date, hhmm, start, end, duration, title, description }
#
# Ownership of the builders after O2 (streams.md rule 6): O3 _episodeItem (+ episode submenu),
# O5 _programsFeed/_programItem (+ program header), O6 _episodesFeed.

use strict;
use warnings;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::RTRFM::Airnet;
use Plugins::RTRFM::ProtocolHandler;
use Plugins::RTRFM::Util;

use constant ENDASH => "\x{2013}";
use constant MIDDOT => "\x{B7}";

my $log = logger('plugin.rtrfm');

sub init {
	Slim::Player::ProtocolHandlers->registerHandler( rtrfm => 'Plugins::RTRFM::ProtocolHandler' );
}

# Top level: one "Programs" link. No network access here.
sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name  => cstring( $client, 'PLUGIN_RTRFM_PROGRAMS' ),
		type  => 'link',
		url   => \&_programsFeed,
		image => Plugins::RTRFM::Util::ICON,
	} ] );
}

sub _programsFeed {
	my ( $client, $cb, $args ) = @_;

	Plugins::RTRFM::Airnet::programs( sub {
		my ( $programs, $error ) = @_;

		return _textFeed( $client, $cb, 'PLUGIN_RTRFM_LOAD_FAILED' ) unless $programs;

		_respond( $client, $cb, sub {
			return [ map { _programItem( $client, { image => undef, %$_ } ) } @$programs ];
		} );
	} );
}

sub _programItem {
	my ( $client, $program ) = @_;

	return {
		name        => $program->{name},
		type        => 'link',
		url         => \&_episodesFeed,
		passthrough => [$program],
		image       => $program->{image} || Plugins::RTRFM::Util::ICON,
	};
}

sub _episodesFeed {
	my ( $client, $cb, $args, $program ) = @_;

	Plugins::RTRFM::Airnet::episodes( $program->{slug}, sub {
		my ( $episodes, $error ) = @_;

		return _textFeed( $client, $cb, 'PLUGIN_RTRFM_LOAD_FAILED' ) unless $episodes;

		# filter at build time, so a list cached before Perth midnight still gives today's window
		my $listed = Plugins::RTRFM::Airnet::filterWindow($episodes);

		return _textFeed( $client, $cb, 'PLUGIN_RTRFM_NO_EPISODES' ) unless @$listed;

		_respond( $client, $cb, sub {
			my @items;

			for my $episode (@$listed) {
				Plugins::RTRFM::Util::setEpisodeMeta( {
					slug        => $episode->{slug},
					date        => $episode->{date},
					start       => $episode->{start},
					duration    => $episode->{duration},
					title       => defined $episode->{title} ? $episode->{title} : $program->{name} . ' ' . ENDASH . ' ' . Plugins::RTRFM::Util::friendlyDate( $episode->{date} ),
					show        => $program->{name},
					image       => $program->{image},
					description => $episode->{description},
				} );

				push @items, _episodeItem( $client, $program, $episode );
			}

			return \@items;
		} );
	} );
}

sub _episodeItem {
	my ( $client, $program, $episode ) = @_;

	my $date  = Plugins::RTRFM::Util::friendlyDate( $episode->{date} );
	my $label = defined $episode->{title} ? $episode->{title} : $program->{name};
	my $url   = Plugins::RTRFM::Util::episodeUrl( $episode->{slug}, $episode->{date}, $episode->{hhmm} );

	# Perth start-end time, e.g. 09:00-11:00 (end from Airnet's end, else start + duration)
	my $start = Plugins::RTRFM::Util::parsePerthDateTime( $episode->{start} );
	my $end   = Plugins::RTRFM::Util::parsePerthDateTime( $episode->{end} );
	$end = $start + $episode->{duration} if !defined $end && defined $start && $episode->{duration};
	my $time = Plugins::RTRFM::Util::perthTime($start);
	$time .= ENDASH . Plugins::RTRFM::Util::perthTime($end) if defined $end;

	my $item = {
		# the Default web skin shows only the name, so it carries the date
		name      => $date . ' ' . ENDASH . ' ' . $label,
		line1     => $label,
		line2     => $date . ' ' . MIDDOT . ' ' . $time,
		type      => 'audio',
		url       => $url,
		play      => $url,
		on_select => 'play',
		image     => $program->{image} || Plugins::RTRFM::Util::ICON,
	};

	$item->{duration}    = $episode->{duration}    if defined $episode->{duration};
	$item->{description} = $episode->{description} if defined $episode->{description} && length $episode->{description};

	return $item;
}

# Call back once with the items $build returns, or with the LOAD_FAILED item if it dies.
sub _respond {
	my ( $client, $cb, $build ) = @_;

	my $items = eval { $build->() };

	if ( ref $items ne 'ARRAY' ) {
		$log->error( 'Building the RTRFM on-demand menu failed: ' . ( $@ || 'unknown error' ) );
		return _textFeed( $client, $cb, 'PLUGIN_RTRFM_LOAD_FAILED' );
	}

	$cb->( { items => $items } );
}

sub _textFeed {
	my ( $client, $cb, $token ) = @_;

	$cb->( { items => [ { name => cstring( $client, $token ), type => 'text' } ] } );
}

1;
