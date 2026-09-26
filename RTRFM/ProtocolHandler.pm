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

use Time::HiRes;

use Slim::Utils::Log;

use Plugins::RTRFM::Restream;
use Plugins::RTRFM::Util;

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
		my $client = $args->{client};

		main::INFOLOG && $log->is_info && $log->info("Resolved $url, scanning the MP3");

		# the wrapped callback is stored in $args, so it must not capture $args itself: that
		# would be a reference cycle, leaking the args hash, the callback and the song every play
		$args->{cb} = sub {
			my $track = shift;

			if ($track) {
				# the scanned track's URL is the streamable (signed, maybe redirected) MP3 URL
				$song->streamUrl( $track->url );
				$track->title( $class->getMetadataFor( $client, $url )->{title} );

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

	my $station = Plugins::RTRFM::Util::STATION_NAME;
	my $icon    = Plugins::RTRFM::Util::ICON;

	my %meta = (
		title  => $episode->{slug} . " \x{2013} " . Plugins::RTRFM::Util::friendlyDate( $episode->{date} ),
		artist => $station,
		album  => $station,
		cover  => $icon,
		icon   => $icon,
	);

	if ( my $cached = Plugins::RTRFM::Util::getEpisodeMeta( $episode->{slug}, $episode->{date} ) ) {
		$meta{title}  = $cached->{title} if _hasValue( $cached->{title} );
		$meta{artist} = $cached->{show}  if _hasValue( $cached->{show} );
		$meta{cover}  = $meta{icon} = $cached->{image} if _hasValue( $cached->{image} );
		$meta{duration} = $cached->{duration} if _hasValue( $cached->{duration} );
	}

	return \%meta;
}

sub getIcon { Plugins::RTRFM::Util::ICON }

sub _hasValue { defined $_[0] && !ref $_[0] && length $_[0] }

1;
