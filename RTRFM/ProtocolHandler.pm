package Plugins::RTRFM::ProtocolHandler;

# Protocol handler for on-demand episode URLs: rtrfm://episode/<slug>/<YYYY-MM-DD>[/<HHMM>]
# (the contract is Plugins::RTRFM::Util::episodeUrl / parseEpisodeUrl; the handler is
# registered by Plugins::RTRFM::OnDemand->init).
#
# A "thin" protocol handler modelled on core Slim::Plugin::Podcast::ProtocolHandler (see
# DEVELOPERS.txt, "Thin Protocol Handler"):
#   - scanUrl resolves the episode's short-lived signed MP3 URL through rzz
#     (Plugins::RTRFM::Restream) at play time, then lets the core remote scanner
#     (Slim::Utils::Scanner::Remote) scan that MP3, which gives LMS the bitrate and, from
#     Content-Length, the duration. In the scan callback the signed URL goes into
#     $song->streamUrl and the track URL is set back to the exact rtrfm:// URL, so signed URLs
#     never end up in menus, playlists or favourites; the scanned title and embedded cover art
#     are dropped in favour of getMetadataFor;
#   - new() opens $song->streamUrl for LMS-proxied streaming; direct streaming uses
#     $song->streamUrl through the inherited canDirectStreamSong;
#   - seeking uses the inherited canSeek/getSeekData (byte offset from bitrate and duration);
#   - getMetadataFor/getIcon never block and never do network I/O: episode metadata comes from
#     the episode metadata cache (Util::getEpisodeMeta, written by the menus) or the URL.
#
# The current track during episode playback (position-based metadata):
#   - The episode's track list is kept on the song ($song->pluginData) for the whole stream:
#     the cached copy can expire mid-episode (1 hour for an episode that aired less than 2 days
#     ago, counted from the first fetch, which may have been a menu browse). onStream (every
#     stream start, including each seek, which re-opens the stream) puts it there from the
#     cache, or starts the song's one Tracklist::fetch. The episode start comes from the
#     metadata cache, else from the URL's date and HHMM; without either there is no track data.
#     onStream arms the boundary timer only for the song the player is playing (not when LMS
#     starts streaming the next playlist item early), from the position the stream starts at
#     ($song->seekdata): it runs before the player restarts, while songTime is still the old
#     stream's.
#   - getMetadataFor, for the episode the player is playing and once its track list is known
#     (the song's, else the cache's), returns the track at the audible position
#     (Slim::Player::Source::songTime) from Tracklist::trackAt: title and artist of the track,
#     album "<Show> – <date>", the episode cover and the *episode* duration. Otherwise (no
#     client, a queued episode, no track list, before the first track) it returns the episode
#     metadata. While playing it also (re)arms the boundary timer, and if neither the song nor
#     the cache has the list it starts the song's one fetch (never more than one per song,
#     onStream's included, whatever the outcome). It stays cheap: never blocks, no cache read
#     once the song has the list, and it keeps the pending timer when the due time is
#     unchanged or the timer is about to fire (it may be the one for the boundary just passed).
#   - One boundary timer per master player (sync slaves use their master's) fires 0.5 s after
#     the next track starts: if the current track changed since the timer was armed it bumps
#     currentPlaylistUpdateTime and sends 'newmetadata' so the web UI and other controllers
#     refresh, then it arms itself for the following track. It stops when the player stops or
#     moves to another URL, re-checks every 5 s while paused, and isn't set after the last
#     track. onStop kills it.
#   - getCurrentTitle gives LMS's current title (status current_title, player displays) the
#     same title as getMetadataFor, per player. Without it LMS would show whatever title it
#     cached for the URL before the scan: empty, or the name of the menu item that started
#     playback, e.g. "Play episode".
#   - Never $song->duration(...), $song->startOffset(...) or setCurrentTitle with a client:
#     seeking and the progress bar depend on the first two, and the last fires 'newsong'.
#   - Song info: trackInfoMenu (registered by initTrackInfo, called from OnDemand->init) adds
#     the episode notes and the track list for rtrfm:// episode URLs.
#
# Signed-URL expiry and seeking (OQ1):
#   rzz signs each URL with "st" (nginx secure_link) and "e", roughly the request time + 10 s.
#   RTRFM does not enforce "e" today: an "expired" URL still streams minutes later. A URL is
#   resolved once per play (scanUrl runs once for each Slim::Player::Song) and kept in
#   $song->streamUrl for the life of that song. Seeks do not scan again:
#   StreamingController::_JumpToTime -> _Stream -> Song::open(seekdata) reuses
#   $song->streamUrl with a byte Range, whether LMS proxies the stream or the player fetches
#   it directly. So a seek reuses the original signed URL.
#   LMS has a cheap re-resolve hook: _Stream calls $handler->updateOnStream($song, $successCb,
#   $failCb), if the handler has one, before every stream start, including seeks. We
#   deliberately don't implement it while the expiry isn't enforced. If RTRFM starts
#   enforcing it, a seek made more than ~10 s after the URL was resolved would get HTTP 403:
#   LMS logs "Invalid response code (403) from remote stream" (player.streaming.remote or
#   player.streaming.direct), shows its standard "problem connecting" message and stops (or
#   moves on to the next playlist item). Nothing crashes, and LMS doesn't retry streams that
#   have a duration. The fix would then be an updateOnStream that calls Restream::resolve
#   again and updates $song->streamUrl.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Scalar::Util qw(blessed refaddr);
use Time::HiRes;

use Slim::Control::Request;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::RTRFM::Restream;
use Plugins::RTRFM::Tracklist;
use Plugins::RTRFM::Util;

use constant BOUNDARY_DELAY => 0.5;     # seconds after a track starts that its timer fires
use constant PAUSE_RECHECK  => 5;       # seconds between checks while paused
use constant KEEP_TIMER     => 0.5;     # a pending timer due within this of the new time is kept
use constant LOST_TIMER     => 5;       # a pending timer overdue by this much is taken as lost

# $song->pluginData keys (not namespaced by LMS, hence the prefix)
use constant SONG_TRACKS  => 'rtrfmTracks';         # the episode's track list, for the whole stream
use constant SONG_FETCHED => 'rtrfmTracksFetched';  # the song's one track-list fetch was started

use constant ENDASH => "\x{2013}";

my $log = logger('plugin.rtrfm');

sub scanUrl {
	my ( $class, $url, $args ) = @_;

	my $cb = $args->{cb} || sub { };

	my $episode = Plugins::RTRFM::Util::parseEpisodeUrl($url);

	if ( !$episode ) {
		$log->warn( 'Not a valid RTRFM episode URL: ' . ( defined $url ? $url : '' ) );
		return $cb->( undef, 'PLUGIN_RTRFM_EPISODE_UNAVAILABLE' );
	}

	Plugins::RTRFM::Restream::resolve( $episode->{slug}, $episode->{date}, sub {
		my $result = shift;

		if ( $result->{unavailable} ) {
			main::INFOLOG && $log->is_info && $log->info("Episode no longer available: $url");
			return $cb->( undef, 'PLUGIN_RTRFM_EPISODE_UNAVAILABLE' );
		}

		if ( !$result->{url} ) {
			$log->warn( "Couldn't resolve $url: " . ( $result->{error} || 'unknown error' ) );
			return $cb->( undef, 'PLUGIN_RTRFM_RESOLVE_FAILED' );
		}

		my $mp3Url = $result->{url};
		my $song   = $args->{song};

		main::INFOLOG && $log->is_info && $log->info("Resolved $url, scanning the MP3");

		# the wrapped callback is stored in $args, so it must not capture $args itself: that
		# would be a reference cycle, leaking the args hash, the callback and the song every play
		$args->{cb} = sub {
			my $track = shift;

			if ($track) {
				# the scanned track's URL is the streamable (signed, maybe redirected) MP3 URL
				$song->streamUrl( $track->url );

				# the stored title is the episode's, never a current track's (no client)
				$track->title( $class->getMetadataFor( undef, $url )->{title} );

				# ignore cover art embedded in the MP3's tags so the episode artwork from
				# getMetadataFor is shown (as core Podcast does)
				$track->cover(0);

				# from now on the track is the rtrfm:// URL, byte for byte, so playlist and
				# favourites matching keep working
				$track->url($url);

				# the web UI only refreshes the playlist when this changes
				$song->master->currentPlaylistUpdateTime( Time::HiRes::time() );
			}

			$cb->( $track, @_ );
		};

		$class->SUPER::scanUrl( $mp3Url, $args );
	} );

	return;
}

sub new {
	my ( $class, $args ) = @_;

	# stream the resolved MP3; after a redirect, keep the redirected URL to avoid a loop
	$args->{url} = $args->{song}->streamUrl if $args->{song} && !$args->{redir};

	return $class->SUPER::new($args);
}

sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;

	my $episode = Plugins::RTRFM::Util::parseEpisodeUrl($url) or return {};
	my $cached  = Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} );
	my $meta    = _episodeMeta( $episode, $cached );

	# the current track: only for the episode this player is playing, once its track list is known
	my ( $master, $song ) = _playingSong( $client, $url ) or return $meta;
	my $playing = $master->isPlaying;
	my $tracks  = _songTracks( $master, $song, $url, $episode, $cached, $playing ) or return $meta;

	my $pos = _position($master);
	my ( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( $tracks, $pos );

	# while paused or stopped the pending timer is left alone: it re-checks every few seconds
	# while paused, and ends itself once stopped
	_arm( $master, $url, $current, $next, $pos ) if $playing;

	return $meta unless $current;

	my $show = _showName( $episode, $cached );

	return {
		%$meta,
		title  => _hasValue( $current->{title} )  ? $current->{title}  : $meta->{title},
		artist => _hasValue( $current->{artist} ) ? $current->{artist} : $show,
		album  => $show . ' ' . ENDASH . ' ' . Plugins::RTRFM::Util::friendlyDate( $episode->{date} ),
	};
}

# The episode metadata: from the metadata cache, else from the URL.
sub _episodeMeta {
	my ( $episode, $cached ) = @_;

	my $station = Plugins::RTRFM::Util::STATION_NAME;
	my $icon    = Plugins::RTRFM::Util::ICON;

	my %meta = (
		title  => $episode->{slug} . ' ' . ENDASH . ' ' . Plugins::RTRFM::Util::friendlyDate( $episode->{date} ),
		artist => $station,
		album  => $station,
		cover  => $icon,
		icon   => $icon,
	);

	if ($cached) {
		$meta{title}  = $cached->{title} if _hasValue( $cached->{title} );
		$meta{artist} = $cached->{show}  if _hasValue( $cached->{show} );
		$meta{cover}  = $meta{icon} = $cached->{image} if _hasValue( $cached->{image} );
		$meta{duration} = $cached->{duration} if _hasValue( $cached->{duration} );
	}

	return \%meta;
}

# LMS asks this before its own title cache (Slim::Music::Info::getCurrentTitle, which status
# uses for current_title): the title getMetadataFor gives this player, so the current track or
# the episode. undef for URLs that aren't episodes, so LMS uses its default.
sub getCurrentTitle {
	my ( $class, $client, $url ) = @_;
	return $class->getMetadataFor( $client, $url )->{title};
}

# Called by the streaming controller for each player of the sync group whenever the song starts
# streaming, including after a seek.
sub onStream {
	my ( $class, $client, $song ) = @_;

	return unless $client && $song;

	# once per sync group: the master's call does the work
	my $master = $client->master;
	return unless $master && $master == $client;

	my $url     = $song->currentTrack->url;
	my $episode = Plugins::RTRFM::Util::parseEpisodeUrl($url) or return;
	my $cached  = Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} );

	if ( !defined _episodeStart( $episode, $cached ) ) {
		main::INFOLOG && $log->is_info && $log->info("No start time for $url, so no current track");
		return;
	}

	# the song's list, else the cached one, else the song's one fetch (which arms the timer when
	# it completes)
	my $tracks = _songTracks( $master, $song, $url, $episode, $cached, 1 ) or return;

	# LMS starts streaming the next playlist item while the current one is still playing: the
	# timer stays the playing song's (getMetadataFor arms the next one's once it plays)
	return unless _isSong( $master->playingSong, $song );

	# the player hasn't restarted yet, so songTime is still the old stream's (0 on direct
	# streams after a seek: Song::open resets startOffset); the stream starts at the seek target
	my $seek = $song->seekdata;
	_armFor( $master, $url, $tracks, ref $seek && $seek->{timeOffset} ? $seek->{timeOffset} : 0 );

	return;
}

sub onStop {
	my ( $class, $song ) = @_;

	my $master = $song && $song->master or return;
	_disarm($master);

	return;
}

# ---------------------------------------------------------------------------
# Boundary timer
# ---------------------------------------------------------------------------

# Arm the timer for the next track boundary after position $pos.
sub _armFor {
	my ( $master, $url, $tracks, $pos ) = @_;

	my ( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( $tracks, $pos );

	_arm( $master, $url, $current, $next, $pos );
}

# Arm (or keep) the one timer of $master for the start of track $next, $next->{offset} - $pos
# seconds from now; $current is the track at $pos. No next track: no timer.
sub _arm {
	my ( $master, $url, $current, $next, $pos ) = @_;

	my $now   = Time::HiRes::time();
	my $armed = $master->pluginData('boundary');
	$armed = undef unless ref $armed && $armed->{url} eq $url;

	# keep a pending timer that is about to fire: it may be the one for the boundary that was
	# just passed, which it has yet to announce (a status poll can land in between); it re-arms
	# itself when it fires
	return if $armed && $armed->{due} - $now <= BOUNDARY_DELAY && $now - $armed->{due} < LOST_TIMER;

	return _disarm($master) unless $next;

	my $due = $now + ( $next->{offset} - $pos ) + BOUNDARY_DELAY;

	# keep the pending timer when it's due at (almost) the same time: getMetadataFor runs on
	# every status poll
	return if $armed && abs( $armed->{due} - $due ) < KEEP_TIMER;

	_setTimer( $master, $url, $due, _trackKey($current) );
}

# $from: _trackKey of the track that was current when the timer was armed
sub _setTimer {
	my ( $master, $url, $due, $from ) = @_;

	Slim::Utils::Timers::killTimers( $master, \&_onBoundary );
	Slim::Utils::Timers::setTimer( $master, $due, \&_onBoundary, $url );

	$master->pluginData( boundary => { url => $url, due => $due, from => $from } );
}

sub _disarm {
	my $master = shift;

	Slim::Utils::Timers::killTimers( $master, \&_onBoundary );
	$master->pluginData( boundary => 0 );

	return;
}

sub _onBoundary {
	my ( $master, $url ) = @_;

	my $armed = $master->pluginData('boundary');
	my $from  = ref $armed ? $armed->{from} : undef;
	$master->pluginData( boundary => 0 );

	# the player stopped or moved on (another episode, another stream): done
	return if $master->isStopped || ( Slim::Player::Playlist::url($master) || '' ) ne $url;

	if ( $master->isPaused ) {
		return _setTimer( $master, $url, Time::HiRes::time() + PAUSE_RECHECK, $from );
	}

	my ( undef, $song ) = _playingSong( $master, $url ) or return;
	my $episode = Plugins::RTRFM::Util::parseEpisodeUrl($url) or return;
	my $cached  = Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} );
	my $tracks  = _songTracks( $master, $song, $url, $episode, $cached, 1 ) or return;

	my $pos = _position($master);
	my ( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( $tracks, $pos );

	# only when the track changed: not when the timer fired early (the player was behind) or
	# re-checked after a pause with the same track still playing. The web UI refreshes on
	# currentPlaylistUpdateTime, other controllers on newmetadata; both then ask getMetadataFor
	# for the new track
	if ( !defined $from || $from ne _trackKey($current) ) {
		$master->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );
	}

	_arm( $master, $url, $current, $next, $pos );
}

# ---------------------------------------------------------------------------
# The song's track list
# ---------------------------------------------------------------------------

# The track list of $song, the episode $episode at $url that $master is playing: the one kept
# on the song, else the cached one (then kept on the song). Else, with $fetch, the song's one
# fetch is started (_fetchTracks). undef while there is none.
sub _songTracks {
	my ( $master, $song, $url, $episode, $cached, $fetch ) = @_;

	my $tracks = $song->pluginData(SONG_TRACKS);
	return $tracks if ref $tracks eq 'ARRAY';

	my $start = _episodeStart( $episode, $cached );
	return undef unless defined $start;

	if ( $tracks = Plugins::RTRFM::Tracklist::cached( $episode->{slug}, $start ) ) {
		$song->pluginData( SONG_TRACKS, $tracks );
		return $tracks;
	}

	_fetchTracks( $master, $song, $url, $episode, $start ) if $fetch;

	return undef;
}

# At most one Tracklist::fetch per song, whatever the outcome (a failure isn't retried for that
# song). The list is kept on the song; if the player is still playing it, controllers are told
# and the timer is armed.
sub _fetchTracks {
	my ( $master, $song, $url, $episode, $start ) = @_;

	return if $song->pluginData(SONG_FETCHED);
	$song->pluginData( SONG_FETCHED, 1 );

	Plugins::RTRFM::Tracklist::fetch( $episode->{slug}, $start, sub {
		my ( $tracks, $error ) = @_;

		if ( !$tracks ) {
			main::INFOLOG && $log->is_info && $log->info( "No track list for $url: " . ( $error || 'unknown error' ) );
			return;
		}

		$song->pluginData( SONG_TRACKS, $tracks );

		# only if the player is still playing this song
		return if $master->isStopped
			|| ( Slim::Player::Playlist::url($master) || '' ) ne $url
			|| !_isSong( $master->playingSong, $song );

		$master->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

		_armFor( $master, $url, $tracks, _position($master) );
	} );

	return;
}

# ---------------------------------------------------------------------------
# Song info
# ---------------------------------------------------------------------------

sub initTrackInfo {
	require Slim::Menu::TrackInfo;
	Slim::Menu::TrackInfo->registerInfoProvider( rtrfmepisode => (
		after => 'top',
		func  => \&trackInfoMenu,
	) );
}

# TrackInfo provider ($client, $url, $track, $remoteMeta, $tags): for an rtrfm:// episode URL
# the episode notes (when there are any) and "Track list (N)" (when the list is cached; if it
# isn't, one fetch is started so it's there next time). Nothing for any other URL.
sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta ) = @_;

	my $episode = Plugins::RTRFM::Util::parseEpisodeUrl($url) or return;
	my $cached  = Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} );

	my @items;

	# shaped like the core COMMENT item: a bare text item shows as an empty row on some UIs
	if ( $cached && _hasValue( $cached->{description} ) ) {
		push @items, {
			name   => cstring( $client, 'PLUGIN_RTRFM_EPISODE_NOTES' ),
			items  => [ { type => 'text', wrap => 1, name => $cached->{description} } ],
			unfold => 1,
		};
	}

	my $start = _episodeStart( $episode, $cached );

	if ( defined $start ) {
		my $tracks = Plugins::RTRFM::Tracklist::cached( $episode->{slug}, $start );

		if ( !$tracks ) {
			Plugins::RTRFM::Tracklist::fetch( $episode->{slug}, $start, sub { } );
		}
		elsif (@$tracks) {
			push @items, {
				name  => cstring( $client, 'PLUGIN_RTRFM_TRACKLIST' ) . ' (' . scalar(@$tracks) . ')',
				type  => 'link',
				items => [ map { +{ name => Plugins::RTRFM::Tracklist::formatRow($_), type => 'text' } } @$tracks ],
			};
		}
	}

	return @items ? \@items : undef;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ($master, $song): the master of $client's sync group and its playing song, if that is $url;
# else ().
sub _playingSong {
	my ( $client, $url ) = @_;

	return () unless blessed($client) && $client->can('master');

	my $master = $client->master     or return ();
	my $song   = $master->playingSong or return ();
	my $track  = $song->currentTrack or return ();

	return $track->url eq $url ? ( $master, $song ) : ();
}

# Whether $x and $y are the same song object.
sub _isSong {
	my ( $x, $y ) = @_;
	return ref $x && ref $y && refaddr($x) == refaddr($y);
}

# Identifies the current track for the "has it changed" check: its offset ('' for none).
sub _trackKey { defined $_[0] ? $_[0]->{offset} : '' }

# Audible position in the episode (seconds); undefined or negative -> 0.
sub _position {
	my $pos = Slim::Player::Source::songTime(shift);
	return defined $pos && $pos > 0 ? $pos : 0;
}

# Episode start 'YYYY-MM-DD HH:MM:SS' (Perth): from the metadata cache, else the URL's date and
# HHMM; undef if neither is known.
sub _episodeStart {
	my ( $episode, $cached ) = @_;

	my $start = $cached && $cached->{start};
	return $start if _hasValue($start) && defined Plugins::RTRFM::Util::parsePerthDateTime($start);

	return undef unless defined $episode->{hhmm};
	return sprintf( '%s %s:%s:00', $episode->{date}, substr( $episode->{hhmm}, 0, 2 ), substr( $episode->{hhmm}, 2, 2 ) );
}

# The show name for the album line: from the metadata cache, else the slug.
sub _showName {
	my ( $episode, $cached ) = @_;
	return $cached && _hasValue( $cached->{show} ) ? $cached->{show} : $episode->{slug};
}

sub getIcon { Plugins::RTRFM::Util::ICON }

sub _hasValue { defined $_[0] && !ref $_[0] && length $_[0] }

1;
