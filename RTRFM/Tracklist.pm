package Plugins::RTRFM::Tracklist;

# Episode track lists from Airnet playlists:
#   GET <AIRNET_BASE>/programs/<slug>/episodes/<YYYY-MM-DD>+<HH>%3A<MM>%3A<SS>/playlists
# No menu code: the episode submenu (Plugins::RTRFM::OnDemand) builds its rows from these
# functions, and the current-track display during episode playback reuses them too, so keep
# the contract stable:
#
#   fetch($slug, $start, $cb)
#       $slug  = Airnet program slug, e.g. 'saturdayjazz'
#       $start = episode start 'YYYY-MM-DD HH:MM:SS', Perth time (':SS' may be left out)
#       One request through Plugins::RTRFM::HTTP. Calls back exactly once:
#         $cb->(\@tracks)       success, as normalise() returns it (possibly empty). HTTP 400
#                               (Airnet's {"message":"No such episode"}: today's episodes,
#                               which Airnet doesn't list yet, or a wrong start time) and
#                               HTTP 404 also give an empty list.
#         $cb->(undef, $error)  any other failure: another HTTP error (5xx), a timeout, bad
#                               JSON, a response that isn't a list, or an invalid slug or start
#                               (then nothing is requested).
#       Logging: the request is made with HTTP.pm's quiet option, so an expected 400/404 is
#       logged at DEBUG/INFO only; any other failure is logged once, at WARN.
#       Cached in the rtrfm cache namespace under 'tracklist:<slug>:<YYYY-MM-DD HH:MM:SS>':
#         a non-empty list for 24 hours, or 1 hour if the episode started less than 2 days
#         ago (presenters still edit their playlists); an empty list, 400 or 404 for 1 hour;
#         failures never.
#
#   normalise(\@items, $start)
#       Pure. Airnet playlist entries -> [ { offset, artist, title, release, isLocal,
#       offsetUnknown? }, ... ], sorted by offset (stable: equal offsets keep their order).
#         - Only entries with type 'track' are kept.
#         - offset = approximateTime - $start in seconds (both Perth time); negative -> 0.
#           Never Airnet's 'time', which is 12-hour without am/pm (17:01 is "05:01:00").
#           Missing or unparseable approximateTime: the previous entry's offset (0 for the
#           first) and offsetUnknown => 1. Without a valid $start every offset is unknown.
#         - artist, title, release: entity-decoded, whitespace trimmed and collapsed; empty ->
#           undef. Entries with neither artist nor title are dropped.
#         - isLocal: 1 if contentDescriptors.isLocal is true, else 0 (the site's "WA" badge).
#
#   formatOffset($seconds)
#       Pure. 'm:ss' below one hour ('3:00', '23:00'), 'h:mm:ss' from one hour ('1:02:38').
#
#   formatRow($track)
#       Pure. '<offset> · <Artist> – <Title> (<Release>)', e.g.
#       '3:00 · Chris Foster – Looking Sideways (In Motion)'. ' (<Release>)' is left out
#       without a release, '<Artist> – ' without an artist, '<offset> · ' when offsetUnknown.
#
#   cached($slug, $start)
#       Synchronous cache read: the list fetch() cached for this episode (an arrayref, possibly
#       empty), or undef when nothing is cached or $slug/$start is invalid. Never makes a
#       request. $start as for fetch().
#
#   trackAt(\@tracks, $pos)
#       Pure. ($current, $next) at playback position $pos (seconds from the episode start;
#       undef or negative counts as 0): $current is the last track whose offset is <= $pos
#       (of tracks with the same offset, the later one in the list), $next the first track
#       whose offset is > $pos; either may be undef, and an empty list gives (undef, undef).
#       Tracks flagged offsetUnknown are ignored. The list needn't be sorted (a sorted copy is
#       used; the input is never modified).

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::RTRFM::HTTP;
use Plugins::RTRFM::Util;

use constant TTL        => 24 * 3600;    # seconds: a track list of an older episode
use constant SHORT_TTL  => 3600;         # seconds: recent episodes, empty lists, 400/404
use constant RECENT_AGE => 2 * 86400;    # seconds since the episode start

use constant ENDASH => "\x{2013}";
use constant MIDDOT => "\x{B7}";

my $log = logger('plugin.rtrfm');

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

sub fetch {
	my ( $slug, $start, $cb ) = @_;

	my @start = _splitStart($start);

	if ( !_isValidSlug($slug) || !@start ) {
		my $error = sprintf( "Can't fetch a track list for slug %s, start %s", map { defined $_ && !ref $_ ? "'$_'" : 'undef' } $slug, $start );
		$log->warn($error);
		return $cb->( undef, $error );
	}

	my ( $date, $h, $m, $s ) = @start;
	$start = "$date $h:$m:$s";

	my $key    = _cacheKey( $slug, $start );
	my $cache  = _cache();
	my $cached = $cache->get($key);
	return $cb->($cached) if ref $cached eq 'ARRAY';

	my $url = Plugins::RTRFM::Util::AIRNET_BASE . "/programs/$slug/episodes/$date+$h%3A$m%3A$s/playlists";

	my $found = sub {
		my $tracks = shift;
		$cache->set( $key, $tracks, _ttl( $tracks, $start ) );
		$cb->($tracks);
	};

	Plugins::RTRFM::HTTP::getJSON(
		$url,
		sub {
			my $data = shift;

			if ( ref $data ne 'ARRAY' ) {
				my $error = "Unexpected track list from Airnet (not a list) ($url)";
				$log->warn($error);
				return $cb->( undef, $error );
			}

			my $tracks = eval { normalise( $data, $start ) };
			if ( !$tracks ) {
				my $error = "Couldn't read the Airnet track list ($url): " . ( $@ || 'unknown error' );
				$log->error($error);
				return $cb->( undef, $error );
			}

			$found->($tracks);
		},
		sub {
			my $error = shift;

			# no such episode: no track list (HTTP.pm messages start "HTTP request failed: <code> ...")
			if ( defined $error && $error =~ /^HTTP request failed: (?:400|404)\b/ ) {
				main::INFOLOG && $log->is_info && $log->info("No Airnet track list for $slug $start");
				return $found->( [] );
			}

			# HTTP.pm logged it at DEBUG only (quiet), so a real failure is warned about here
			$log->warn( defined $error ? $error : "Airnet track list request failed ($url)" );
			$cb->( undef, $error );
		},
		# quiet: the 400 for an episode Airnet hasn't published yet (today's, or a just-aired one)
		# is expected, so HTTP.pm logs failures at DEBUG and only real failures are warned about
		{ quiet => 1 },
	);
}

sub cached {
	my ( $slug, $start ) = @_;

	return undef unless _isValidSlug($slug);
	my ( $date, $h, $m, $s ) = _splitStart($start) or return undef;

	my $tracks = _cache()->get( _cacheKey( $slug, "$date $h:$m:$s" ) );
	return ref $tracks eq 'ARRAY' ? $tracks : undef;
}

# $start: normalised 'YYYY-MM-DD HH:MM:SS'
sub _cacheKey { "tracklist:$_[0]:$_[1]" }

# 1 hour for an empty list or an episode that started less than 2 days ago, else 24 hours
sub _ttl {
	my ( $tracks, $start ) = @_;

	return SHORT_TTL unless @$tracks;

	my $epoch = Plugins::RTRFM::Util::parsePerthDateTime($start);
	return defined $epoch && time() - $epoch < RECENT_AGE ? SHORT_TTL : TTL;
}

# 'YYYY-MM-DD HH:MM[:SS]' -> (date, HH, MM, SS), or () if it isn't a valid date and time
sub _splitStart {
	my $start = shift;
	return () unless defined $start && !ref $start && defined Plugins::RTRFM::Util::parsePerthDateTime($start);

	my ( $date, $h, $m, $s ) = $start =~ /\A\s*([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?\s*\z/
		or return ();

	return ( $date, $h, $m, defined $s ? $s : '00' );
}

# ---------------------------------------------------------------------------
# Normalising and formatting
# ---------------------------------------------------------------------------

sub normalise {
	my ( $items, $start ) = @_;

	my $startEpoch = Plugins::RTRFM::Util::parsePerthDateTime($start);

	my ( @tracks, $previous );

	for my $item ( ref $items eq 'ARRAY' ? @$items : () ) {
		next unless ref $item eq 'HASH' && defined $item->{type} && !ref $item->{type} && $item->{type} eq 'track';

		my %track = map { $_ => _cleanText( $item->{$_} ) } qw(artist title release);
		next unless defined $track{artist} || defined $track{title};

		my $time = Plugins::RTRFM::Util::parsePerthDateTime( $item->{approximateTime} );

		if ( defined $time && defined $startEpoch ) {
			$track{offset} = $time > $startEpoch ? $time - $startEpoch : 0;
		}
		else {
			$track{offset}        = defined $previous ? $previous : 0;
			$track{offsetUnknown} = 1;
		}
		$previous = $track{offset};

		my $descriptors = $item->{contentDescriptors};
		$track{isLocal} = ref $descriptors eq 'HASH' && $descriptors->{isLocal} ? 1 : 0;

		push @tracks, \%track;
	}

	return [ _sortByOffset(@tracks) ];
}

# Stable sort by offset: ties keep their list order.
sub _sortByOffset {
	my $i = 0;
	return
		map  { $_->[1] }
		sort { $a->[1]->{offset} <=> $b->[1]->{offset} || $a->[0] <=> $b->[0] }
		map  { [ $i++, $_ ] } @_;
}

sub trackAt {
	my ( $tracks, $pos ) = @_;

	$pos = 0 unless defined $pos && !ref $pos && $pos =~ /\A[0-9]+(?:\.[0-9]+)?\z/;

	my @known = grep { ref $_ eq 'HASH' && !$_->{offsetUnknown} && defined $_->{offset} } ref $tracks eq 'ARRAY' ? @$tracks : ();

	my ( $current, $next );
	for my $track ( _sortByOffset(@known) ) {
		if ( $track->{offset} <= $pos ) {
			$current = $track;
		}
		else {
			$next = $track;
			last;
		}
	}

	return ( $current, $next );
}

sub formatOffset {
	my $seconds = shift;
	$seconds = defined $seconds && $seconds =~ /\A[0-9]+(?:\.[0-9]+)?\z/ ? int $seconds : 0;

	return sprintf( '%d:%02d', int( $seconds / 60 ), $seconds % 60 ) if $seconds < 3600;
	return sprintf( '%d:%02d:%02d', int( $seconds / 3600 ), int( $seconds % 3600 / 60 ), $seconds % 60 );
}

sub formatRow {
	my $track = shift;

	my $row = join( ' ' . ENDASH . ' ', grep { defined $_ && length $_ } $track->{artist}, $track->{title} );
	$row .= " ($track->{release})" if defined $track->{release} && length $track->{release};

	return $row if $track->{offsetUnknown};
	return formatOffset( $track->{offset} ) . ' ' . MIDDOT . ' ' . $row;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Entity-decode, trim and collapse whitespace; undef (or a non-string) and empty -> undef.
sub _cleanText {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = Plugins::RTRFM::Util::decodeEntities($text);
	$text =~ s/\s+/ /g;
	$text =~ s/^ //;
	$text =~ s/ $//;

	return length $text ? $text : undef;
}

sub _isValidSlug { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[a-z0-9_-]+\z/ }

sub _cache { Slim::Utils::Cache->new( Plugins::RTRFM::Util::CACHE_NAMESPACE ) }

1;
