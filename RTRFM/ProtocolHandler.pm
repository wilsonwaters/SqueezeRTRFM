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
#   - onStream (every stream start, including each seek, which re-opens the stream) makes sure
#     the episode's track list is cached (at most one Tracklist::fetch; none when cached) and
#     (re)arms the boundary timer. The episode start comes from the metadata cache, else from
#     the URL's date and HHMM; without either there is no track data.
#   - getMetadataFor, for the episode the player is playing and with a cached track list,
#     returns the track at the audible position (Slim::Player::Source::songTime) from
#     Tracklist::trackAt: title and artist of the track, album "<Show> – <date>", the episode
#     cover and the *episode* duration. Otherwise (no client, a queued episode, no track list,
#     before the first track) it returns the episode metadata. While playing it also (re)arms
#     the boundary timer. It stays cheap: no network, one track-list cache read, and it keeps
#     the pending timer when the due time is unchanged.
#   - One boundary timer per master player (sync slaves use their master's) fires 0.5 s after
#     the next track starts: it bumps currentPlaylistUpdateTime and sends 'newmetadata' so
#     the web UI and other controllers refresh, then arms itself for the following track. It
#     stops when the player stops or moves to another URL, re-checks every 5 s while paused,
#     and isn't set after the last track. onStop kills it.
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

use Scalar::Util qw(blessed);
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

	# the current track: only for the episode this player is playing, with a cached track list
	my $master = _playingMaster( $client, $url ) or return $meta;
	my $tracks = _cachedTracks( $episode, $cached ) or return $meta;

	my $pos = _position($master);
	my ( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( $tracks, $pos );

	# while paused or stopped the pending timer is left alone: it re-checks every few seconds
	# while paused, and ends itself once stopped
	_arm( $master, $url, $next, $pos ) if $master->isPlaying;

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
	my $start   = _episodeStart( $episode, $cached );

	if ( !defined $start ) {
		main::INFOLOG && $log->is_info && $log->info("No start time for $url, so no current track");
		return;
	}

	if ( my $tracks = Plugins::RTRFM::Tracklist::cached( $episode->{slug}, $start ) ) {
		return _armFor( $master, $url, $tracks );
	}

	Plugins::RTRFM::Tracklist::fetch( $episode->{slug}, $start, sub {
		my ( $tracks, $error ) = @_;

		if ( !$tracks ) {
			main::INFOLOG && $log->is_info && $log->info( "No track list for $url: " . ( $error || 'unknown error' ) );
			return;
		}

		# only if the player is still on this episode
		return if $master->isStopped || ( Slim::Player::Playlist::url($master) || '' ) ne $url;

		$master->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

		_armFor( $master, $url, $tracks );
	} );

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

# Arm the timer for the next track boundary after the current position.
sub _armFor {
	my ( $master, $url, $tracks ) = @_;

	my $pos = _position($master);
	my ( undef, $next ) = Plugins::RTRFM::Tracklist::trackAt( $tracks, $pos );

	_arm( $master, $url, $next, $pos );
}

# Arm (or keep) the one timer of $master for the start of track $next, $next->{offset} - $pos
# seconds from now. No next track: no timer.
sub _arm {
	my ( $master, $url, $next, $pos ) = @_;

	return _disarm($master) unless $next;

	my $due = Time::HiRes::time() + ( $next->{offset} - $pos ) + BOUNDARY_DELAY;

	# keep the pending timer when it's due at (almost) the same time: getMetadataFor runs on
	# every status poll
	my $armed = $master->pluginData('boundary');
	return if ref $armed && $armed->{url} eq $url && abs( $armed->{due} - $due ) < KEEP_TIMER;

	_setTimer( $master, $url, $due );
}

sub _setTimer {
	my ( $master, $url, $due ) = @_;

	Slim::Utils::Timers::killTimers( $master, \&_onBoundary );
	Slim::Utils::Timers::setTimer( $master, $due, \&_onBoundary, $url );

	$master->pluginData( boundary => { url => $url, due => $due } );
}

sub _disarm {
	my $master = shift;

	Slim::Utils::Timers::killTimers( $master, \&_onBoundary );
	$master->pluginData( boundary => 0 );

	return;
}

sub _onBoundary {
	my ( $master, $url ) = @_;

	$master->pluginData( boundary => 0 );

	# the player stopped or moved on (another episode, another stream): done
	return if $master->isStopped || ( Slim::Player::Playlist::url($master) || '' ) ne $url;

	if ( $master->isPaused ) {
		return _setTimer( $master, $url, Time::HiRes::time() + PAUSE_RECHECK );
	}

	# the web UI refreshes on currentPlaylistUpdateTime, other controllers on newmetadata;
	# both then ask getMetadataFor for the new track
	$master->currentPlaylistUpdateTime( Time::HiRes::time() );
	Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

	my $episode = Plugins::RTRFM::Util::parseEpisodeUrl($url) or return;
	my $tracks  = _cachedTracks( $episode, Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} ) ) or return;

	_armFor( $master, $url, $tracks );
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

# The master of $client's sync group if it is playing $url, else undef.
sub _playingMaster {
	my ( $client, $url ) = @_;

	return undef unless blessed($client) && $client->can('master');

	my $master = $client->master     or return undef;
	my $song   = $master->playingSong or return undef;
	my $track  = $song->currentTrack or return undef;

	return $track->url eq $url ? $master : undef;
}

# Audible position in the episode (seconds); undefined or negative -> 0.
sub _position {
	my $pos = Slim::Player::Source::songTime(shift);
	return defined $pos && $pos > 0 ? $pos : 0;
}

# The episode's cached track list, or undef (no start time, or nothing cached).
sub _cachedTracks {
	my ( $episode, $cached ) = @_;

	my $start = _episodeStart( $episode, $cached );
	return defined $start ? Plugins::RTRFM::Tracklist::cached( $episode->{slug}, $start ) : undef;
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
