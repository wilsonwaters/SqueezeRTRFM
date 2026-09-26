#!/usr/bin/perl
# The current track during episode playback: Tracklist::trackAt/cached, and the protocol
# handler's position-based metadata (getMetadataFor/getCurrentTitle), the one-per-player
# boundary timer (arm, fire, pause re-check, stop/URL change, sync master, polls between a
# boundary and its timer, notifying only on a track change), the track list kept on the song
# for the whole stream (fetched at most once per song), onStream (stream start position,
# next playlist item, sync slaves), onStop, and the song-info (TrackInfo) provider.
# Uses F1's fake clock and timers, fake players/songs (below) and the Saturday Jazz
# 2026-09-19 playlist fixture (see t/34-tracklist.t): tracks start at 09:03 (offset 180),
# track 5 at 09:23 (1380), track 6 at 09:29 (1740), track 7 at 09:33 (1980), track 20 at
# 10:55 (6900).

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use JSON::PP ();
use Time::Local qw(timegm);

use Slim::Control::Request;
use Slim::Menu::TrackInfo;
use Slim::Music::Info;
use Slim::Player::Playlist;
use Slim::Utils::Timers;

use Plugins::RTRFM::OnDemand;
use Plugins::RTRFM::ProtocolHandler;
use Plugins::RTRFM::Tracklist;
use Plugins::RTRFM::Util qw(ICON setEpisodeMeta friendlyDate);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $PH = 'Plugins::RTRFM::ProtocolHandler';

my $URL      = 'rtrfm://episode/saturdayjazz/2026-09-19/0900';
my $LIVE     = 'https://live.rtrfm.com.au/stream1';
my $START    = '2026-09-19 09:00:00';
my $PLAYLIST = Plugins::RTRFM::Util::AIRNET_BASE . '/programs/saturdayjazz/episodes/2026-09-19+09%3A00%3A00/playlists';

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $T0 = timegm( 0, 40, 3, 26, 8, 2026 );

my $ENDASH = "\x{2013}";
my $ALBUM  = "Saturday Jazz $ENDASH " . friendlyDate('2026-09-19');

my %META = (
	slug        => 'saturdayjazz',
	date        => '2026-09-19',
	start       => $START,
	duration    => 7200,
	title       => 'Saturday Jazz with Laura Igglesden',
	show        => 'Saturday Jazz',
	image       => 'https://example.org/sj.jpg',
	description => 'Laura plays new Australian jazz.',
);

my $TRACKS = Plugins::RTRFM::Tracklist::normalise( JSON::PP->new->decode( fixture('ondemand/playlist-saturdayjazz-2026-09-19.json') ), $START );

# ---- helpers ----

sub playlistRequests { scalar grep { $_->{url} eq $PLAYLIST } requests() }
sub notifications    { @Slim::Control::Request::NOTIFICATIONS }
sub newmetadata      { grep { $_->{request}->[0] eq 'newmetadata' } notifications() }
sub timers           { Slim::Utils::Timers->pending }
sub boundaryTimers   { grep { $_->{code} == \&Plugins::RTRFM::ProtocolHandler::_onBoundary } timers() }

# A fresh test: stubs reset, clock at $T0 (or time => ...), the episode metadata cache primed
# (unless meta => 0) and the track list cached (unless tracks => 0).
sub fresh {
	my %opts = ( meta => 1, tracks => 1, time => $T0, @_ );
	resetStubs();
	setTime( $opts{time} );
	setEpisodeMeta( {%META} ) if $opts{meta};
	route( $PLAYLIST, file => 'ondemand/playlist-saturdayjazz-2026-09-19.json' );
	if ( $opts{tracks} ) {
		Plugins::RTRFM::Tracklist::fetch( 'saturdayjazz', $START, sub { } );
		Slim::Networking::SimpleAsyncHTTP->reset;
		route( $PLAYLIST, file => 'ondemand/playlist-saturdayjazz-2026-09-19.json' );
	}
	return;
}

# A master player playing $url from position $pos (seconds): returns (player, song). A stream
# started at $pos > 0 was a seek, so the song's seekdata has it (as Slim::Player::Song).
sub playing {
	my ( $url, $pos, %opts ) = @_;
	my $player = FakePlayer->new(%opts);
	my $song   = FakeSong->new( $url, $player );
	$song->{seekdata} = { timeOffset => $pos } if $pos;
	$player->play( $song, $pos );
	$Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$url];
	return ( $player, $song );
}

sub o1Meta { $PH->getMetadataFor( undef, $_[0] || $URL ) }

# A seek of $player (playing $song) to $pos as StreamingController::_JumpToTime/_Stream do it:
# the song's seekdata gets the target, then onStream runs *before* the player restarts, while
# songTime is still not the new position (0 on direct streams: Song::open resets
# startOffset); then the player plays from $pos.
sub seekStream {
	my ( $player, $song, $pos ) = @_;
	$song->{seekdata} = { timeOffset => $pos };
	$player->{elapsed} = 0;
	$PH->onStream( $player, $song );
	delete $player->{elapsed};
	$player->seek($pos);
}

# The next fetch of the track list waits for completeDeferred (or never completes).
sub deferFetch {
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( $PLAYLIST, file => 'ondemand/playlist-saturdayjazz-2026-09-19.json', defer => 1 );
}

# ---------------------------------------------------------------------------
# Tracklist::trackAt
# ---------------------------------------------------------------------------

subtest 'trackAt on the Saturday Jazz 2026-09-19 fixture' => sub {
	is( scalar @$TRACKS, 20, '20 tracks' );

	# [ pos, current track number or undef, next track number or undef ]
	my @cases = ( [ 0, undef, 1 ], [ 180, 1, 2 ], [ 1390, 5, 6 ], [ 1739, 5, 6 ], [ 1740, 6, 7 ], [ 7000, 20, undef ] );

	for my $list ( [ 'sorted', $TRACKS ], [ 'unsorted copy', [ reverse @$TRACKS[ 10 .. 19 ], @$TRACKS[ 0 .. 9 ] ] ] ) {
		my ( $name, $tracks ) = @$list;
		for my $case (@cases) {
			my ( $pos, $cur, $next ) = @$case;
			my ( $current, $upcoming ) = Plugins::RTRFM::Tracklist::trackAt( $tracks, $pos );
			is( $current,  defined $cur  ? $TRACKS->[ $cur - 1 ]  : undef, "$name, pos $pos: current is " . ( $cur  || 'undef' ) );
			is( $upcoming, defined $next ? $TRACKS->[ $next - 1 ] : undef, "$name, pos $pos: next is " .    ( $next || 'undef' ) );
		}
	}

	my ( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( $TRACKS, 1390 );
	is( $current->{title}, "Isn't This a Lovely Day", 'pos 1390: track 5 title' );
	is( $current->{artist}, 'Ella Fitzgerald & Louis Armstrong', 'pos 1390: track 5 artist' );
	is( $next->{offset}, 1740, 'pos 1390: next at offset 1740' );
	is( ( Plugins::RTRFM::Tracklist::trackAt( $TRACKS, 1740 ) )[0]->{title}, 'Look to the Sky', 'pos 1740: track 6' );
	is( $TRACKS->[0]->{offset}, 180, 'first track at 180' );
	is( $TRACKS->[19]->{offset}, 6900, 'last track at 6900' );

	is_deeply( [ Plugins::RTRFM::Tracklist::trackAt( [], 100 ) ], [ undef, undef ], 'empty list: (undef, undef)' );
	is_deeply( [ Plugins::RTRFM::Tracklist::trackAt( undef, 100 ) ], [ undef, undef ], 'undef list: (undef, undef)' );
};

subtest 'trackAt: unknown offsets ignored, equal offsets, bad positions' => sub {
	my @tracks = (
		{ offset => 0,   title => 'A' },
		{ offset => 300, title => 'B' },
		{ offset => 300, title => 'C' },
		{ offset => 300, title => 'D', offsetUnknown => 1 },
		{ offset => 600, title => 'E' },
	);
	my ( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( \@tracks, 400 );
	is( $current->{title}, 'C', 'same offset: the later one in the list wins; offsetUnknown ignored' );
	is( $next->{title},    'E', 'next' );

	( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( [ { offset => 100, title => 'X', offsetUnknown => 1 } ], 500 );
	is_deeply( [ $current, $next ], [ undef, undef ], 'only unknown offsets: (undef, undef)' );

	for my $pos ( undef, -5, 'garbage' ) {
		( $current, $next ) = Plugins::RTRFM::Tracklist::trackAt( \@tracks, $pos );
		is( $current->{title}, 'A', 'pos ' . ( defined $pos ? "'$pos'" : 'undef' ) . ' counts as 0: current' );
		is( $next->{title},    'B', 'pos ' . ( defined $pos ? "'$pos'" : 'undef' ) . ' counts as 0: next' );
	}

	my @copy = map { {%$_} } @tracks;
	Plugins::RTRFM::Tracklist::trackAt( [ reverse @tracks ], 400 );
	is_deeply( \@tracks, \@copy, 'input list untouched' );
};

# ---------------------------------------------------------------------------
# Tracklist::cached
# ---------------------------------------------------------------------------

subtest 'cached: synchronous cache read, never a request' => sub {
	fresh( tracks => 0 );
	is( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', $START ), undef, 'nothing cached: undef' );
	is( playlistRequests(), 0, 'no request' );

	Plugins::RTRFM::Tracklist::fetch( 'saturdayjazz', $START, sub { } );
	Slim::Networking::SimpleAsyncHTTP->reset;

	is_deeply( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', $START ), $TRACKS, 'after fetch: the normalised list' );
	is_deeply( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', '2026-09-19 09:00' ), $TRACKS, 'start without seconds' );
	is( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', '2026-09-19 10:00:00' ), undef, 'other start: undef' );
	is( Plugins::RTRFM::Tracklist::cached( 'Bad Slug', $START ), undef, 'invalid slug: undef' );
	is( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', 'garbage' ), undef, 'invalid start: undef' );
	is( scalar( requests() ), 0, 'cached() made no requests' );
};

# ---------------------------------------------------------------------------
# getMetadataFor and the boundary timer
# ---------------------------------------------------------------------------

subtest 'getMetadataFor while playing at 1390: track 5, one timer at +350.5 s' => sub {
	fresh();
	my ( $player, $song ) = playing( $URL, 1390 );

	my $meta = $PH->getMetadataFor( $player, $URL );
	is( $meta->{title},    "Isn't This a Lovely Day",           'title = track 5' );
	is( $meta->{artist},   'Ella Fitzgerald & Louis Armstrong', 'artist = track 5 artist' );
	is( $meta->{album},    $ALBUM,                              'album "Saturday Jazz – <friendly date>"' );
	is( $meta->{duration}, 7200,                                'duration = the episode duration' );
	is( $meta->{cover},    'https://example.org/sj.jpg',        'cover = episode image' );

	my @timers = boundaryTimers();
	is( scalar( timers() ), 1, 'exactly one timer' );
	is( scalar @timers, 1, 'it is the boundary timer' );
	is( $timers[0] && $timers[0]->{when}, $T0 + 350.5, 'due at +350.5 s (track 6 at 1740, plus 0.5 s)' );
	is( $timers[0] && $timers[0]->{obj}, $player, 'keyed by the player' );
	is_deeply( $timers[0] && $timers[0]->{args}, [$URL], 'with the episode URL' );
	is( scalar( requests() ), 0, 'no network' );
	is( scalar( notifications() ), 0, 'no notification yet' );
	is_deeply( [ $song->setterCalls ], [], 'no $song->duration/startOffset setter calls' );
};

subtest 'boundary timer fires while playing: one newmetadata, update time, re-armed for track 7' => sub {
	fresh();
	my ( $player, $song ) = playing( $URL, 1390 );
	$PH->getMetadataFor( $player, $URL );

	is( advanceTime(350), 0, 'nothing fires before the boundary' );
	is( advanceTime(0.5), 1, 'the timer fires at +350.5 s' );

	my @notes = notifications();
	is( scalar @notes, 1, 'exactly one notification' );
	is( $notes[0] && $notes[0]->{client}, $player, 'for the player' );
	is_deeply( $notes[0] && $notes[0]->{request}, ['newmetadata'], 'newmetadata' );
	is( $player->currentPlaylistUpdateTime, $T0 + 350.5, 'currentPlaylistUpdateTime bumped' );

	my @timers = boundaryTimers();
	is( scalar( timers() ), 1, 'one timer again' );
	# pos is now 1740.5: track 7 at 1980 -> due in 1980 - 1740.5 + 0.5 = 240 s
	is( $timers[0] && $timers[0]->{when}, $T0 + 350.5 + 240, 're-armed for track 7 (offset 1980)' );

	is( $PH->getMetadataFor( $player, $URL )->{title}, 'Look to the Sky', 'metadata now track 6' );
	is( scalar( timers() ), 1, 'still one timer after another metadata call' );
	is_deeply( [ $song->setterCalls ], [], 'no $song->duration/startOffset setter calls' );
};

subtest 'boundary timer while paused: no notification, re-check in 5 s; resume then notifies' => sub {
	fresh();
	my ( $player, $song ) = playing( $URL, 1735 );
	$PH->getMetadataFor( $player, $URL );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 5.5, 'due at +5.5 s (1740 - 1735 + 0.5)' );

	$player->pause;
	is( advanceTime(5.5), 1, 'timer fired' );
	is( scalar( notifications() ), 0, 'paused: no notification' );
	my @timers = boundaryTimers();
	is( scalar( timers() ), 1, 'one timer' );
	is( $timers[0] && $timers[0]->{when}, $T0 + 10.5, 're-check in 5 s' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, "Isn't This a Lovely Day", 'paused before the boundary: still track 5' );
	@timers = boundaryTimers();
	is( scalar( timers() ), 1, 'metadata while paused: one timer' );
	is( $timers[0] && $timers[0]->{when}, $T0 + 10.5, 'and the re-check is left alone' );

	advanceTime(10);
	is( scalar( notifications() ), 0, 'still paused 10 s later: no notification' );
	is( scalar( timers() ), 1, 'one timer' );

	$player->resume;
	is( $PH->getMetadataFor( $player, $URL )->{title}, "Isn't This a Lovely Day", 'resumed at 1735: track 5' );
	advanceTime(6);
	is( scalar( newmetadata() ), 1, 'newmetadata once the boundary is reached after resuming' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, 'Look to the Sky', 'then track 6' );
	is( scalar( timers() ), 1, 'one timer' );
};

subtest 'boundary timer after stop or a URL change: nothing sent, no re-arm, no timers left' => sub {
	for my $case (qw(stopped url-changed empty-playlist)) {
		fresh();
		my ( $player, $song ) = playing( $URL, 1390 );
		$PH->getMetadataFor( $player, $URL );

		if    ( $case eq 'stopped' )     { $player->stop }
		elsif ( $case eq 'url-changed' ) { $Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$LIVE] }
		else                             { $Slim::Player::Playlist::PLAYLISTS{ $player->id } = [] }

		is( advanceTime(350.5), 1, "$case: timer fired" );
		is( scalar( notifications() ), 0, "$case: no notification" );
		is( scalar( timers() ), 0, "$case: no timers left" );
		is( $player->currentPlaylistUpdateTime, undef, "$case: update time untouched" );
	}
};

subtest 'after the last track no timer is set' => sub {
	fresh();
	my ($player) = playing( $URL, 7000 );
	is( $PH->getMetadataFor( $player, $URL )->{title}, 'Forest', 'track 20' );
	is( scalar( timers() ), 0, 'no timer after the last track' );

	fresh();
	($player) = playing( $URL, 6890 );
	$PH->getMetadataFor( $player, $URL );
	is( scalar( timers() ), 1, 'timer for the last boundary' );
	advanceTime(10.5);
	is( scalar( newmetadata() ), 1, 'notified at the last boundary' );
	is( scalar( timers() ), 0, 'and not re-armed' );
};

subtest 'repeated calls keep one timer per player; a sync slave uses its master; players are independent' => sub {
	fresh();
	my ($player) = playing( $URL, 1390 );

	for my $i ( 1 .. 5 ) {
		$PH->getMetadataFor( $player, $URL );
		advanceTime(2);
	}
	is( scalar( timers() ), 1, 'five calls over 10 s: one timer' );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 350.5, 'same due time' );

	my $slave = FakePlayer->new( master => $player );
	my $meta  = $PH->getMetadataFor( $slave, $URL );
	is( $meta->{title}, "Isn't This a Lovely Day", 'slave: current track from the master' );
	my @timers = timers();
	is( scalar @timers, 1, 'slave: still one timer' );
	is( $timers[0]->{obj}, $player, 'keyed by the master' );

	$player->seek(1700);
	$PH->getMetadataFor( $slave, $URL );
	@timers = timers();
	is( scalar @timers, 1, 'after a seek: one timer' );
	is( $timers[0]->{when}, $T0 + 10 + 40.5, 're-armed for the new position (1740 - 1700 + 0.5)' );

	my ($other) = playing( $URL, 1100 );
	is( $PH->getMetadataFor( $other, $URL )->{title}, 'Spring', 'second player at 1100: track 4' );
	is( scalar( timers() ), 2, 'two players: two timers' );
	is( scalar( grep { $_->{obj} == $other } timers() ), 1, 'one for each player' );
};

subtest 'a status poll between a boundary and its timer does not cancel the notification' => sub {
	fresh();
	my ($player) = playing( $URL, 1390 );
	$PH->getMetadataFor( $player, $URL );

	advanceTime(350.2);    # pos 1740.2: track 6 has started, its timer is due in 0.3 s
	is( $PH->getMetadataFor( $player, $URL )->{title}, 'Look to the Sky', 'poll right after the boundary: track 6' );
	advanceTime(5);
	is( scalar( newmetadata() ), 1, 'exactly one newmetadata for the boundary' );
	ok( ( $player->currentPlaylistUpdateTime || 0 ) >= $T0 + 350.5, 'currentPlaylistUpdateTime set' );
	my @timers = boundaryTimers();
	is( scalar( timers() ), 1, 'one timer' );
	is( $timers[0] && $timers[0]->{when}, $T0 + 355.2 + ( 1980 - 1745.2 ) + 0.5, 'then armed for track 7' );

	# the last boundary: the poll finds no next track, the pending timer must survive that too
	fresh();
	($player) = playing( $URL, 6890 );
	$PH->getMetadataFor( $player, $URL );
	advanceTime(10.2);
	is( $PH->getMetadataFor( $player, $URL )->{title}, 'Forest', 'poll right after the last boundary: track 20' );
	advanceTime(5);
	is( scalar( newmetadata() ), 1, 'the last boundary is announced' );
	is( scalar( timers() ), 0, 'and no timer after it' );
};

subtest 'boundary timer notifies only when the track changed (early fire, re-check after a pause)' => sub {
	# the player falls 2 s behind (a stall) after the timer was armed: the timer fires before
	# the boundary is audible
	fresh();
	my ($player) = playing( $URL, 1390 );
	$PH->getMetadataFor( $player, $URL );
	advanceTime(100);
	$player->pause;
	advanceTime(2);
	$player->resume;
	is( advanceTime(248.5), 1, 'timer fired at +350.5 s, pos 1738.5' );
	is( scalar( newmetadata() ), 0, 'still track 5: no newmetadata' );
	is( $player->currentPlaylistUpdateTime, undef, 'update time untouched' );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 352.5, 're-armed for the boundary, 2 s later' );
	advanceTime(2);
	is( scalar( newmetadata() ), 1, 'then one newmetadata at the boundary' );

	# paused at 1735, resumed without a poll: the 5 s re-check fires before the boundary
	fresh();
	($player) = playing( $URL, 1735 );
	$PH->getMetadataFor( $player, $URL );
	$player->pause;
	advanceTime(5.5);    # fires paused: re-check at +10.5
	advanceTime(3);
	$player->resume;
	is( advanceTime(2), 1, 're-check fired while playing, pos 1737' );
	is( scalar( newmetadata() ), 0, 'still track 5: no newmetadata' );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 14, 'armed for the boundary (1740)' );
	advanceTime(3.5);
	is( scalar( newmetadata() ), 1, 'then one newmetadata at the boundary' );
};

subtest 'the track list is kept for the whole stream: the cached copy expiring mid-episode changes nothing' => sub {
	# a day after the episode aired (2026-09-20 09:00 in Perth) the list is cached for 1 hour only
	my $T1 = timegm( 0, 0, 1, 20, 8, 2026 );
	fresh( time => $T1 );
	my ( $player, $song ) = playing( $URL, 0 );
	$PH->onStream( $player, $song );
	is( ( boundaryTimers() )[0]->{when}, $T1 + 180.5, 'armed for the first track' );

	# play on to pos 3700, status polls every 9.25 s
	for ( 1 .. 400 ) {
		advanceTime(9.25);
		$PH->getMetadataFor( $player, $URL );
	}
	is( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', $START ), undef, 'the cached copy has expired' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, 'The Long and Winding Road', 'pos 3700: still the current track (track 11)' );
	my @timers = boundaryTimers();
	is( scalar( timers() ), 1, 'a timer is armed' );
	is( $timers[0] && $timers[0]->{when}, $T1 + 3700 + ( 4020 - 3700 ) + 0.5, 'for track 12 (4020)' );
	is( scalar( newmetadata() ), 11, 'every boundary so far announced' );
	is( playlistRequests(), 0, 'no fetch' );
	advanceTime(330);
	is( scalar( newmetadata() ), 12, 'and the next one' );
};

subtest 'O1 episode metadata: before the first track, no track list, not playing, no client' => sub {
	fresh();
	my ( $player, $song ) = playing( $URL, 60 );
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'before the first track (pos 60): O1 metadata' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, 'Saturday Jazz with Laura Igglesden', 'episode title' );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 120.5, 'timer armed for the first track (180)' );

	fresh( tracks => 0 );
	deferFetch();
	($player) = playing( $URL, 1390 );
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'no track list on the song or cached: O1 metadata' );
	is( scalar( timers() ), 0, 'no timer' );
	is( playlistRequests(), 1, 'while playing: the song\'s one fetch' );
	$PH->getMetadataFor( $player, $URL );
	is( playlistRequests(), 1, 'not repeated by the next poll' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( newmetadata() ), 1, 'fetched: newmetadata' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, "Isn't This a Lovely Day", 'then track 5' );
	is( scalar( timers() ), 1, 'and a timer' );

	fresh( tracks => 0 );
	deferFetch();
	($player) = playing( $URL, 1390 );
	$player->pause;
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'paused, no track list: O1 metadata' );
	is( scalar( requests() ), 0, 'and no fetch while not playing' );

	fresh();
	($player) = playing( 'rtrfm://episode/saturdayjazz/2026-09-12/0900', 1390 );
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'queued URL (another episode playing): O1 metadata' );
	($player) = playing( $LIVE, 1390 );
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'live stream playing: O1 metadata' );
	$player = FakePlayer->new;
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'nothing playing: O1 metadata' );
	is( scalar( timers() ), 0, 'no timers' );

	fresh();
	is_deeply( $PH->getMetadataFor( undef, $URL ), o1Meta(), 'no client: O1 metadata' );
	is( o1Meta()->{album}, 'RTRFM 92.1', 'O1 album is the station' );

	is_deeply( $PH->getMetadataFor( $player, $LIVE ), {}, 'live URL: {} (not ours)' );
};

subtest 'getMetadataFor fallbacks: no cache entry (URL HHMM), missing artist, bad songTime' => sub {
	fresh( meta => 0 );
	my ($player) = playing( $URL, 1390 );
	my $meta = $PH->getMetadataFor( $player, $URL );
	is( $meta->{title}, "Isn't This a Lovely Day", 'start from the URL HHMM: track 5' );
	is( $meta->{album}, "saturdayjazz $ENDASH " . friendlyDate('2026-09-19'), 'album falls back to the slug' );
	is( $meta->{cover}, ICON, 'cover falls back to the station icon' );
	ok( !defined $meta->{duration}, 'no duration without a cache entry (as O1)' );

	fresh( meta => 0 );
	($player) = playing( 'rtrfm://episode/saturdayjazz/2026-09-19', 1390 );
	is_deeply( $PH->getMetadataFor( $player, 'rtrfm://episode/saturdayjazz/2026-09-19' ), o1Meta('rtrfm://episode/saturdayjazz/2026-09-19'), 'no start known (no cache, no HHMM): O1 metadata' );
	is( scalar( timers() ), 0, 'no timer' );

	fresh();
	my @tracks = map { {%$_} } @$TRACKS;
	delete $tracks[4]->{artist};
	Slim::Utils::Cache->new('rtrfm')->set( "tracklist:saturdayjazz:$START", \@tracks, 3600 );
	($player) = playing( $URL, 1390 );
	is( $PH->getMetadataFor( $player, $URL )->{artist}, 'Saturday Jazz', 'track without artist: the show name' );

	for my $pos ( undef, -3 ) {
		fresh();
		($player) = playing( $URL, 0 );
		$player->{elapsed} = $pos;
		is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'songTime ' . ( defined $pos ? $pos : 'undef' ) . ' counts as 0: O1 metadata' );
		is( ( boundaryTimers() )[0]->{when}, $T0 + 180.5, 'timer for the first track' );
	}
};

subtest 'getCurrentTitle: follows the current track, else the episode title (stale title cache ignored)' => sub {
	fresh();
	$Slim::Music::Info::CURRENT_TITLE{$URL} = 'Play episode';
	my ($player) = playing( $URL, 1390 );
	is( $PH->getCurrentTitle( $player, $URL ), "Isn't This a Lovely Day", 'playing at 1390: track 5' );
	$player->seek(60);
	is( $PH->getCurrentTitle( $player, $URL ), 'Saturday Jazz with Laura Igglesden', 'before the first track: episode title' );

	fresh( tracks => 0 );
	deferFetch();
	($player) = playing( $URL, 1390 );
	is( $PH->getCurrentTitle( $player, $URL ), 'Saturday Jazz with Laura Igglesden', 'no track list: episode title' );

	fresh( meta => 0, tracks => 0 );
	is( $PH->getCurrentTitle( $player, $URL ), "saturdayjazz $ENDASH " . friendlyDate('2026-09-19'), 'no cache entry: URL fallback title' );
	is( $PH->getCurrentTitle( $player, $LIVE ), undef, 'not an episode URL: undef (LMS default)' );
};

# ---------------------------------------------------------------------------
# onStream / onStop
# ---------------------------------------------------------------------------

subtest 'onStream: one fetch when not cached, none when cached; always (re)arms' => sub {
	fresh( tracks => 0 );
	my ( $player, $song ) = playing( $URL, 1390 );

	$PH->onStream( $player, $song );
	is( playlistRequests(), 1, 'not cached: one track list fetch' );
	is( scalar( newmetadata() ), 1, 'fetched while still playing: newmetadata' );
	is( $player->currentPlaylistUpdateTime, $T0, 'currentPlaylistUpdateTime bumped' );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 350.5, 'timer armed' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, "Isn't This a Lovely Day", 'metadata now has the track' );

	advanceTime(100);
	seekStream( $player, $song, 1700 );    # a seek re-opens the stream; songTime is 0 during onStream
	is( playlistRequests(), 1, 'known: no second fetch' );
	my @timers = timers();
	is( scalar @timers, 1, 'one timer' );
	is( $timers[0]->{when}, $T0 + 100 + 40.5, 're-armed for the seek target (seekdata), not songTime' );
	is( scalar( newmetadata() ), 1, 'no extra notification from onStream with the list known' );
	$PH->getMetadataFor( $player, $URL );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 100 + 40.5, 'playing from 1700: the same timer' );

	my $slave = FakePlayer->new( master => $player );
	$PH->onStream( $slave, $song );
	is( playlistRequests(), 1, 'slave onStream: no fetch' );
	is( scalar( timers() ), 1, 'slave onStream: still one timer' );
	is_deeply( [ $song->setterCalls ], [], 'no $song->duration/startOffset setter calls' );
};

subtest 'onStream: slow fetch completing after the player moved on, failures, no start, other URLs' => sub {
	fresh( tracks => 0 );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( $PLAYLIST, file => 'ondemand/playlist-saturdayjazz-2026-09-19.json', defer => 1 );
	my ( $player, $song ) = playing( $URL, 1390 );
	$PH->onStream( $player, $song );
	is( playlistRequests(), 1, 'fetch started' );
	$Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$LIVE];
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( notifications() ), 0, 'finished after the URL changed: no notification' );
	is( scalar( timers() ), 0, 'no timer' );
	is( ref Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', $START ), 'ARRAY', 'but the list is cached' );

	fresh( tracks => 0 );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( $PLAYLIST, file => 'ondemand/playlist-saturdayjazz-2026-09-19.json', defer => 1 );
	( $player, $song ) = playing( $URL, 1390 );
	$PH->onStream( $player, $song );
	$player->stop;
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( notifications() ), 0, 'finished after stop: no notification' );

	fresh( tracks => 0 );
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( $PLAYLIST, code => 500, content => 'oops' );
	( $player, $song ) = playing( $URL, 1390 );
	$PH->onStream( $player, $song );
	is( playlistRequests(), 1, 'failing fetch: one request' );
	is( scalar( notifications() ), 0, 'no notification' );
	is( scalar( timers() ), 0, 'no timer, no retry' );
	is_deeply( $PH->getMetadataFor( $player, $URL ), o1Meta(), 'O1 metadata' );
	is( playlistRequests(), 1, 'getMetadataFor does not fetch again for the song' );

	fresh( meta => 0, tracks => 0 );
	( $player, $song ) = playing( 'rtrfm://episode/saturdayjazz/2026-09-19', 1390 );
	$PH->onStream( $player, $song );
	is( scalar( requests() ), 0, 'no start (no cache, no HHMM): nothing fetched' );
	is( scalar( timers() ), 0, 'no timer' );

	fresh( tracks => 0 );
	( $player, $song ) = playing( $LIVE, 10 );
	$PH->onStream( $player, $song );
	is( scalar( requests() ), 0, 'not an episode URL: nothing fetched' );
};

subtest 'onStream for the next playlist item (streamed early) leaves the playing episode timer alone' => sub {
	my $NEXT = 'rtrfm://episode/saturdayjazz/2026-09-12/0900';
	fresh();
	Slim::Utils::Cache->new('rtrfm')->set( 'tracklist:saturdayjazz:2026-09-12 09:00:00', [ { offset => 100, title => 'Next one' }, { offset => 5000, title => 'Next two' } ], 3600 );
	my ( $player, $song ) = playing( $URL, 1390 );
	$PH->onStream( $player, $song );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 350.5, 'armed for track 6' );

	# LMS streams the next item while this one plays: playingSong is still this one, songTime
	# its position
	advanceTime(10);
	my $nextSong = FakeSong->new( $NEXT, $player );
	$PH->onStream( $player, $nextSong );
	my @timers = boundaryTimers();
	is( scalar( timers() ), 1, 'one timer' );
	is( $timers[0] && $timers[0]->{when}, $T0 + 350.5, "still the playing episode's" );
	is_deeply( $timers[0] && $timers[0]->{args}, [$URL], 'for its URL' );
	is( scalar( requests() ), 0, 'no request' );
	advanceTime(340.5);
	is( scalar( newmetadata() ), 1, "the playing episode's boundary is announced" );

	# once the next item plays, its list is known
	advanceTime(10);
	$player->play( $nextSong, 200 );
	$Slim::Player::Playlist::PLAYLISTS{ $player->id } = [$NEXT];
	is( $PH->getMetadataFor( $player, $NEXT )->{title}, 'Next one', 'next item playing: its track' );
	is( ( boundaryTimers() )[0]->{when}, $T0 + 360.5 + 4800.5, 'and its timer' );
};

subtest 'onStream from a sync slave does nothing: only the master fetches' => sub {
	fresh( tracks => 0 );
	deferFetch();
	my ( $player, $song ) = playing( $URL, 1390 );
	my $slave = FakePlayer->new( master => $player );
	$PH->onStream( $slave, $song );
	is( playlistRequests(), 0, 'slave, list not cached: no fetch' );
	is( scalar( timers() ), 0, 'and no timer' );
	$PH->onStream( $player, $song );
	is( playlistRequests(), 1, "the master's: one fetch" );
	$PH->onStream( $slave, $song );
	is( playlistRequests(), 1, 'slave again, still not cached: no second fetch' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar( newmetadata() ), 1, 'fetched: one newmetadata' );
	is( scalar( timers() ), 1, 'one timer' );
};

subtest 'onStop kills the player timer' => sub {
	fresh();
	my ( $player, $song ) = playing( $URL, 1390 );
	$PH->onStream( $player, $song );
	is( scalar( timers() ), 1, 'armed' );
	$player->stop;
	$PH->onStop($song);
	is( scalar( timers() ), 0, 'onStop: no timers left' );
	is( $PH->getMetadataFor( $player, $URL )->{title}, "Isn't This a Lovely Day", 'stopped: metadata still answered' );
	is( scalar( timers() ), 0, 'but no timer armed while stopped' );

	$player->play( $song, 1390 );
	$PH->getMetadataFor( $player, $URL );
	is( scalar( timers() ), 1, 'playing again: armed again' );
};

# ---------------------------------------------------------------------------
# Song info (TrackInfo provider)
# ---------------------------------------------------------------------------

subtest 'OnDemand->init registers the song-info provider' => sub {
	resetStubs();
	Plugins::RTRFM::OnDemand->init();
	my $provider = $Slim::Menu::TrackInfo::PROVIDERS{rtrfmepisode};
	ok( $provider, 'provider rtrfmepisode registered' );
	is( $provider && $provider->{after}, 'top', 'after => top' );
	is( $provider && $provider->{func}, \&Plugins::RTRFM::ProtocolHandler::trackInfoMenu, 'func => trackInfoMenu' );
};

subtest 'trackInfoMenu: episode notes and "Track list (20)" for the episode; nothing for other URLs' => sub {
	fresh();
	my ($player) = playing( $URL, 1390 );
	my $items = Plugins::RTRFM::ProtocolHandler::trackInfoMenu( $player, $URL, undef, {} );

	is( ref $items, 'ARRAY', 'a list of items' );
	is( scalar @{ $items || [] }, 2, 'two items' );
	is_deeply(
		$items->[0],
		{ name => 'Episode notes', unfold => 1, items => [ { type => 'text', wrap => 1, name => $META{description} } ] },
		'the description as a wrapped text item under "Episode notes"'
	);
	is( $items->[1]->{name}, 'Track list (20)', 'Track list (20)' );
	is( $items->[1]->{type}, 'link', 'a link' );
	is_deeply(
		$items->[1]->{items},
		[ map { { name => Plugins::RTRFM::Tracklist::formatRow($_), type => 'text' } } @$TRACKS ],
		"rows from O3's formatRow"
	);
	is( $items->[1]->{items}->[4]->{name}, "23:00 \x{B7} Ella Fitzgerald & Louis Armstrong $ENDASH Isn't This a Lovely Day", 'row 5' );

	is( scalar( requests() ), 0, 'cached: no request' );

	is_deeply( Plugins::RTRFM::ProtocolHandler::trackInfoMenu( undef, $URL, undef, {} ), $items, 'not playing / no client: same items' );

	for my $url ( $LIVE, 'https://live.rtrfm.com.au/stream2', 'https://ice1.somafm.com/groovesalad-128-mp3', undef ) {
		my $result = Plugins::RTRFM::ProtocolHandler::trackInfoMenu( $player, $url, undef, {} );
		ok( !$result || ( ref $result eq 'ARRAY' && !@$result ), ( defined $url ? $url : 'undef' ) . ': nothing' );
	}
};

subtest 'trackInfoMenu: not cached -> description only and a fetch; no description; empty list' => sub {
	fresh( tracks => 0 );
	my $items = Plugins::RTRFM::ProtocolHandler::trackInfoMenu( undef, $URL, undef, {} );
	is( scalar @{ $items || [] }, 1, 'not cached: one item' );
	is( $items->[0]->{name}, 'Episode notes', 'the description' );
	is( playlistRequests(), 1, 'and a fetch was triggered' );
	is( Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', $START ) && scalar @{ Plugins::RTRFM::Tracklist::cached( 'saturdayjazz', $START ) }, 20, 'which cached the list' );
	$items = Plugins::RTRFM::ProtocolHandler::trackInfoMenu( undef, $URL, undef, {} );
	is( $items->[1] && $items->[1]->{name}, 'Track list (20)', 'next time: the track list' );

	fresh( meta => 0 );
	$items = Plugins::RTRFM::ProtocolHandler::trackInfoMenu( undef, $URL, undef, {} );
	is( scalar @{ $items || [] }, 1, 'no cache entry (start from the URL): one item' );
	is( $items->[0]->{name}, 'Track list (20)', 'the track list only' );

	fresh( tracks => 0 );
	Slim::Utils::Cache->new('rtrfm')->set( "tracklist:saturdayjazz:$START", [], 3600 );
	$items = Plugins::RTRFM::ProtocolHandler::trackInfoMenu( undef, $URL, undef, {} );
	is( scalar @{ $items || [] }, 1, 'empty list cached: description only' );
	is( playlistRequests(), 0, 'and no fetch' );
};

subtest 'strings' => sub {
	is( Slim::Utils::Strings::string('PLUGIN_RTRFM_EPISODE_NOTES'), 'Episode notes', 'PLUGIN_RTRFM_EPISODE_NOTES' );
	is( Slim::Utils::Strings::string('PLUGIN_RTRFM_TRACKLIST'),     'Track list',    "O3's PLUGIN_RTRFM_TRACKLIST reused" );
};

clearTime();
done_testing();

# ---- fakes for players (Slim::Player::Client + its StreamingController) and songs ----

package FakePlayer;

my $count = 0;

# A player; with master => $other it is a sync-group slave of $other.
sub new {
	my ( $class, %args ) = @_;
	return bless {
		id       => sprintf( '00:00:00:00:10:%02d', ++$count ),
		master   => $args{master},
		state    => 'stop',
		pos      => 0,
		since    => 0,
		song     => undef,
		data     => {},
	}, $class;
}

sub id         { $_[0]->{id} }
sub master     { $_[0]->{master} || $_[0] }
sub controller { $_[0]->master }    # Slim::Player::Source::songTime -> controller->playingSongElapsed

sub playingSong { $_[0]->master->{song} }
sub isPlaying   { $_[0]->master->{state} eq 'play' }
sub isPaused    { $_[0]->master->{state} eq 'pause' }
sub isStopped   { $_[0]->master->{state} eq 'stop' }

# audible position: advances with the (fake) clock while playing; 'elapsed' overrides it
sub playingSongElapsed {
	my $self = shift->master;
	return $self->{elapsed} if exists $self->{elapsed};
	return $self->{state} eq 'play' ? $self->{pos} + ( Time::HiRes::time() - $self->{since} ) : $self->{pos};
}

sub play {
	my ( $self, $song, $pos ) = @_;
	@$self{qw(song state pos since)} = ( $song, 'play', $pos || 0, Time::HiRes::time() );
}

sub seek   { my ( $self, $pos ) = @_; @$self{qw(pos since)} = ( $pos, Time::HiRes::time() ) }
sub pause  { my $self = shift; $self->{pos} = $self->playingSongElapsed; $self->{state} = 'pause' }
sub resume { my $self = shift; @$self{qw(state since)} = ( 'play', Time::HiRes::time() ) }
sub stop   { $_[0]->{state} = 'stop' }

sub currentPlaylistUpdateTime {
	my $self = shift;
	$self->{updateTime} = shift if @_;
	return $self->{updateTime};
}

# like Slim::Player::Client::pluginData (set with a defined value, get by key)
sub pluginData {
	my ( $self, $key, $value ) = @_;
	$self->{data}->{$key} = $value if defined $value;
	return $self->{data}->{$key};
}

package FakeTrack;

sub new { my ( $class, $url ) = @_; return bless { url => $url }, $class }
sub url { $_[0]->{url} }

package FakeSong;

# Like Slim::Player::Song; duration/startOffset record any setter call.
sub new {
	my ( $class, $url, $master ) = @_;
	return bless { track => FakeTrack->new($url), master => $master, setters => [], data => {} }, $class;
}

sub currentTrack { $_[0]->{track} }
sub master       { $_[0]->{master} }
sub seekdata     { $_[0]->{seekdata} }

# like Slim::Player::Song::pluginData (set with a defined value, get by key; not namespaced)
sub pluginData {
	my ( $self, $key, $value ) = @_;
	$self->{data}->{$key} = $value if defined $value;
	return $self->{data}->{$key};
}

sub duration    { my $self = shift; push @{ $self->{setters} }, [ duration    => @_ ] if @_; return 7200 }
sub startOffset { my $self = shift; push @{ $self->{setters} }, [ startOffset => @_ ] if @_; return 0 }

sub setterCalls { @{ $_[0]->{setters} } }
