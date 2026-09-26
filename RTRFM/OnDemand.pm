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
use Plugins::RTRFM::Shows;
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
