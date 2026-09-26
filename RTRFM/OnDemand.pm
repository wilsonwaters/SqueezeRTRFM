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
#                                                    28-day window that still have audio (see
#                                                    Plugins::RTRFM::EpisodeWindow); writes the
#                                                    episode metadata cache (Util::setEpisodeMeta)
#                                                    for each
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
#                { slug, date, hhmm, start, end, duration, title, description }, or synthesised
#                by Plugins::RTRFM::EpisodeWindow (same keys, title undef, plus synthetic => 1)
#
# Ownership of the builders after O2 (streams.md rule 6): O3 _episodeItem (+ episode submenu),
# O5 _programsFeed/_programItem (+ program header), O6 _episodesFeed.

use strict;
use warnings;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::RTRFM::Airnet;
use Plugins::RTRFM::EpisodeWindow;
use Plugins::RTRFM::ProtocolHandler;
use Plugins::RTRFM::Shows;
use Plugins::RTRFM::Util;
use Plugins::RTRFM::Tracklist;

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

# Program list: the rtrfm.com.au line-up (Plugins::RTRFM::Shows) merged with Airnet's programs,
# both fetched at once (see _mergePrograms). Program hashes from the line-up are
# { slug, name, image, schedule, hosts, genres }; from Airnet { slug, name, image => undef }.
sub _programsFeed {
	my ( $client, $cb, $args ) = @_;

	my ( $airnet, $lineup, $lineupError, $haveAirnet, $haveLineup );

	my $done = sub {
		return unless $haveAirnet && $haveLineup;

		my $programs = _mergePrograms( $airnet, $lineup, $lineupError );

		return _textFeed( $client, $cb, 'PLUGIN_RTRFM_LOAD_FAILED' ) unless $programs;

		_respond( $client, $cb, sub {
			return [ map { _programItem( $client, $_ ) } @$programs ];
		} );
	};

	Plugins::RTRFM::Airnet::programs( sub {
		return if $haveAirnet++;
		$airnet = shift;
		$done->();
	} );

	Plugins::RTRFM::Shows::lineup( sub {
		return if $haveLineup++;
		( $lineup, $lineupError ) = @_;
		$done->();
	} );
}

# ($airnetPrograms, $lineupShows, $lineupError) -> program hashes, or undef if both failed:
#   - line-up OK: its shows whose slug Airnet knows, with the WordPress name, image, schedule,
#     hosts and genres, sorted by name; WordPress-only shows are logged at info level;
#   - line-up failed or empty (or no slug in common): Airnet's list as before, logged as a warning;
#   - Airnet failed (or empty), line-up OK: the whole line-up.
sub _mergePrograms {
	my ( $airnet, $lineup, $lineupError ) = @_;

	my $airnetList = $airnet ? [ map { +{ image => undef, %$_ } } @$airnet ] : undef;

	if ( !$lineup || !@$lineup ) {
		$log->warn( 'Listing the Airnet programs: the rtrfm.com.au line-up is unavailable (' . ( $lineupError || 'no shows' ) . ')' ) if $airnetList;
		return $airnetList;
	}

	my @shows = map {
		+{
			slug     => $_->{slug},
			name     => $_->{name},
			image    => $_->{image},
			schedule => $_->{schedule},
			hosts    => [ @{ $_->{hosts}  || [] } ],
			genres   => [ @{ $_->{genres} || [] } ],
		}
	} @$lineup;

	if ( !$airnet || !@$airnet ) {
		main::INFOLOG && $log->is_info && $log->info('Airnet program list unavailable: listing the whole rtrfm.com.au line-up');
		return _sortPrograms( \@shows );
	}

	my %known = map { $_->{slug} => 1 } @$airnet;

	if ( my @unknown = grep { !$known{ $_->{slug} } } @shows ) {
		main::INFOLOG && $log->is_info && $log->info( 'Not listing shows that Airnet does not know yet: ' . join( ', ', map { $_->{slug} } @unknown ) );
	}

	my @programs = grep { $known{ $_->{slug} } } @shows;

	if ( !@programs ) {
		$log->warn('Listing the Airnet programs: no show in the rtrfm.com.au line-up is known to Airnet');
		return $airnetList;
	}

	return _sortPrograms( \@programs );
}

sub _sortPrograms {
	return [ sort { lc $a->{name} cmp lc $b->{name} || $a->{slug} cmp $b->{slug} } @{ $_[0] } ];
}

sub _programItem {
	my ( $client, $program ) = @_;

	my $item = {
		name        => $program->{name},
		line1       => $program->{name},
		type        => 'link',
		url         => \&_programMenu,
		passthrough => [$program],
		image       => $program->{image} || Plugins::RTRFM::Util::ICON,
	};

	# shown by Material, Jive and the CLI menu mode; the Default web skin shows only the name
	$item->{line2} = $program->{schedule} if defined $program->{schedule} && length $program->{schedule};

	return $item;
}

# One program: the header items (_programHeader) followed by all of _episodesFeed's items.
# The show page (Plugins::RTRFM::Shows::showPage) and the episodes are fetched at once, except
# when the program has no image: then the show page comes first, so that the episode items and
# the episode metadata cache get its og:image. Calls back exactly once.
sub _programMenu {
	my ( $client, $cb, $args, $program ) = @_;
	$program = {} unless ref $program eq 'HASH';

	my $called;
	my $once = sub { $cb->(@_) unless $called++ };

	if ( !$program->{image} ) {
		my $havePage;

		return Plugins::RTRFM::Shows::showPage( $program->{slug}, sub {
			return if $havePage++;
			my $page = shift;

			# a copy: the passthrough hash stays untouched
			my $withImage = $page && $page->{image} ? { %$program, image => $page->{image} } : $program;

			_episodesFeed( $client, sub { _programMenuRespond( $client, $once, $withImage, $page, shift ) }, $args, $withImage );
		} );
	}

	my ( $page, $feed, $havePage, $haveFeed );

	my $done = sub {
		_programMenuRespond( $client, $once, $program, $page, $feed ) if $havePage && $haveFeed;
	};

	Plugins::RTRFM::Shows::showPage( $program->{slug}, sub {
		return if $havePage++;
		$page = shift;
		$done->();
	} );

	_episodesFeed( $client, sub {
		return if $haveFeed++;
		$feed = shift;
		$done->();
	}, $args, $program );
}

# Call back with the header items in front of the episode feed's items (other keys of the
# episode feed's result are kept).
sub _programMenuRespond {
	my ( $client, $cb, $program, $page, $feed ) = @_;

	my @header = eval { _programHeader( $client, $program, $page ) };
	$log->error( 'Building the RTRFM program header failed: ' . $@ ) if $@;

	my %result = ref $feed eq 'HASH' ? %$feed : ();
	my $items  = ref $feed eq 'HASH' ? $feed->{items} : $feed;

	$result{items} = [ @header, ref $items eq 'ARRAY' ? @$items : () ];

	$cb->( \%result );
}

# Header items, each only if present: the description (show page) as a textarea, the schedule,
# and "Hosted by: A, B, C, D +4 more" (line-up).
sub _programHeader {
	my ( $client, $program, $page ) = @_;

	my @items;

	my $description = ref $page eq 'HASH' ? $page->{description} : undef;
	push @items, { name => $description, type => 'textarea', wrap => 1 } if defined $description && length $description;

	push @items, { name => $program->{schedule}, type => 'text' } if defined $program->{schedule} && length $program->{schedule};

	my @hosts = grep { defined $_ && length $_ } @{ ref $program->{hosts} eq 'ARRAY' ? $program->{hosts} : [] };

	if (@hosts) {
		my @more  = grep { /\A\+\d+ more\z/ } @hosts;
		my @names = grep { !/\A\+\d+ more\z/ } @hosts;

		push @items, {
			name => cstring( $client, 'PLUGIN_RTRFM_HOSTED_BY' ) . ': ' . join( ' ', grep { length } join( ', ', @names ), @more ),
			type => 'text',
		};
	}

	return @items;
}

# The episodes of a program (O6): Airnet's episodes plus the dates synthesised from the show's
# weekly slots, over [Perth today - 28 days, Perth today], each checked with rzz
# (Plugins::RTRFM::EpisodeWindow). Episodes without audio are hidden; when the check fails the
# episode stays, with "· Availability unknown" after line2. Synthesised episodes carry
# synthetic => 1 (their submenu then shows "Track list not yet available" when Airnet has no
# track list yet). Calls back exactly once.
sub _episodesFeed {
	my ( $client, $cb, $args, $program ) = @_;

	my $called;
	my $once = sub { $cb->(@_) unless $called++ };

	Plugins::RTRFM::Airnet::episodes( $program->{slug}, sub {
		my ( $episodes, $error ) = @_;

		return _textFeed( $client, $once, 'PLUGIN_RTRFM_LOAD_FAILED' ) unless $episodes;

		# the window is computed at build time, so a list cached before Perth midnight still
		# gives today's window
		my $ok = eval {
			my $candidates = Plugins::RTRFM::EpisodeWindow::candidates( $episodes, Plugins::RTRFM::EpisodeWindow::inferSlots($episodes) );

			Plugins::RTRFM::EpisodeWindow::checkAvailability( $candidates, sub {
				my $checked = shift;
				_respond( $client, $once, sub { _episodeItems( $client, $program, $checked ) } );
			} );

			1;
		};

		if ( !$ok ) {
			$log->error( 'Building the RTRFM episode list failed: ' . ( $@ || 'unknown error' ) );
			_textFeed( $client, $once, 'PLUGIN_RTRFM_LOAD_FAILED' );
		}
	} );
}

# Items for the checked episodes (EpisodeWindow::checkAvailability results), writing the episode
# metadata cache for each listed episode; one NO_EPISODES text item when none is listed.
sub _episodeItems {
	my ( $client, $program, $checked ) = @_;

	my @items;

	for my $result (@$checked) {
		next if $result->{status} eq 'unavailable';

		my $episode = $result->{episode};

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

		my $item = _episodeItem( $client, $program, $episode );
		$item->{line2} .= ' ' . MIDDOT . ' ' . cstring( $client, 'PLUGIN_RTRFM_AVAILABILITY_UNKNOWN' ) if $result->{status} eq 'unknown';

		push @items, $item;
	}

	return [ { name => cstring( $client, 'PLUGIN_RTRFM_NO_EPISODES' ), type => 'text' } ] unless @items;

	return \@items;
}

# An episode row: a link that opens the episode submenu (_episodeMenu) and, through 'play', also
# plays the episode. XMLBrowser uses 'play' for playback and for favourites, which save the
# rtrfm:// URL as type 'audio' and never the coderef. No on_select: touch skins would play the
# episode instead of opening it.
sub _episodeItem {
	my ( $client, $program, $episode ) = @_;

	my $date  = Plugins::RTRFM::Util::friendlyDate( $episode->{date} );
	my $label = _episodeLabel( $program, $episode );
	my $url   = Plugins::RTRFM::Util::episodeUrl( $episode->{slug}, $episode->{date}, $episode->{hhmm} );

	# Perth start-end time, e.g. 09:00-11:00 (end from Airnet's end, else start + duration)
	my $start = Plugins::RTRFM::Util::parsePerthDateTime( $episode->{start} );
	my $end   = Plugins::RTRFM::Util::parsePerthDateTime( $episode->{end} );
	$end = $start + $episode->{duration} if !defined $end && defined $start && $episode->{duration};
	my $time = Plugins::RTRFM::Util::perthTime($start);
	$time .= ENDASH . Plugins::RTRFM::Util::perthTime($end) if defined $end;

	my $item = {
		# the Default web skin shows only the name, so it carries the date
		name        => _episodeName( $program, $episode ),
		line1       => $label,
		line2       => $date . ' ' . MIDDOT . ' ' . $time,
		type        => 'link',
		url         => \&_episodeMenu,
		passthrough => [ $program, $episode ],
		play        => $url,
		image       => $program->{image} || Plugins::RTRFM::Util::ICON,
	};

	$item->{duration} = $episode->{duration} if defined $episode->{duration};

	return $item;
}

# Episode title, or the show name when Airnet has none
sub _episodeLabel {
	my ( $program, $episode ) = @_;
	return defined $episode->{title} ? $episode->{title} : $program->{name};
}

# The episode row name, e.g. "Sat 19 Sep – Saturday Jazz with Laura Igglesden"; also the
# favourite title for "Play episode", so a favourite saved there isn't called "Play episode"
sub _episodeName {
	my ( $program, $episode ) = @_;
	return Plugins::RTRFM::Util::friendlyDate( $episode->{date} ) . ' ' . ENDASH . ' ' . _episodeLabel( $program, $episode );
}

# The episode submenu (XMLBrowser coderef feed, passthrough [$program, $episode]):
#   "Play episode" (audio), the description (textarea, only when there is one), then
#   "Track list (N)" (a link to one text row per track), or a text item when there are no
#   tracks: "No track list available", or "Track list not yet available" for an episode
#   flagged synthetic (synthesised or just aired; the flag is set by the episode list builder).
# The track list is fetched here, and only here: building episode lists makes no playlist
# requests. Calls $cb->({ items => [...] }) exactly once.
sub _episodeMenu {
	my ( $client, $cb, $args, $program, $episode ) = @_;

	my $url   = Plugins::RTRFM::Util::episodeUrl( $episode->{slug}, $episode->{date}, $episode->{hhmm} );
	my $start = _episodeStart( $episode, $url );

	my $respond = sub {
		my $tracks = shift;
		_respond( $client, $cb, sub { _episodeMenuItems( $client, $program, $episode, $url, $tracks ) } );
	};

	if ( !defined $start ) {
		main::INFOLOG && $log->is_info && $log->info( 'No start time for ' . ( $url || 'this episode' ) . ', so no track list' );
		return $respond->(undef);
	}

	# $tracks is undef when the fetch failed: shown like an empty list
	Plugins::RTRFM::Tracklist::fetch( $episode->{slug}, $start, sub { $respond->( $_[0] ) } );
}

# Start of the episode for its track list, 'YYYY-MM-DD HH:MM:SS' (Perth): the episode's start,
# else the start in the episode metadata cache, else the episode URL's date and HHMM; undef if
# none is known.
sub _episodeStart {
	my ( $episode, $url ) = @_;

	return $episode->{start} if _isDateTime( $episode->{start} );

	my $meta = Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} );
	return $meta->{start} if $meta && _isDateTime( $meta->{start} );

	my $parsed = Plugins::RTRFM::Util::parseEpisodeUrl($url);
	return undef unless $parsed && defined $parsed->{hhmm};

	return sprintf( '%s %s:%s:00', $parsed->{date}, substr( $parsed->{hhmm}, 0, 2 ), substr( $parsed->{hhmm}, 2, 2 ) );
}

sub _isDateTime { defined $_[0] && !ref $_[0] && defined Plugins::RTRFM::Util::parsePerthDateTime( $_[0] ) }

sub _episodeMenuItems {
	my ( $client, $program, $episode, $url, $tracks ) = @_;

	my $play = {
		name            => cstring( $client, 'PLUGIN_RTRFM_PLAY_EPISODE' ),
		type            => 'audio',
		url             => $url,
		play            => $url,
		on_select       => 'play',
		image           => $program->{image} || Plugins::RTRFM::Util::ICON,
		favorites_title => _episodeName( $program, $episode ),
	};
	$play->{duration} = $episode->{duration} if defined $episode->{duration};

	my @items = ($play);

	if ( defined $episode->{description} && length $episode->{description} ) {
		push @items, { name => $episode->{description}, type => 'textarea', wrap => 1 };
	}

	if ( $tracks && @$tracks ) {
		push @items, {
			name  => cstring( $client, 'PLUGIN_RTRFM_TRACKLIST' ) . ' (' . scalar(@$tracks) . ')',
			type  => 'link',
			items => [ map { +{ name => Plugins::RTRFM::Tracklist::formatRow($_), type => 'text' } } @$tracks ],
		};
	}
	else {
		push @items, {
			name => cstring( $client, $episode->{synthetic} ? 'PLUGIN_RTRFM_TRACKLIST_PENDING' : 'PLUGIN_RTRFM_NO_TRACKLIST' ),
			type => 'text',
		};
	}

	return \@items;
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
