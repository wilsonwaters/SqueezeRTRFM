#!/usr/bin/perl
# Plugins::RTRFM::LiveMetadata: registration from Live->init, LIVE_RE, the parser, stream2's
# static metadata, buildMeta (mapping and show boundary), the stream1 provider (first call,
# push order, show metadata), poll scheduling (clamps, error and missing-data delays), show
# changes, stop conditions, sharing (sync slaves, many calls, several masters, no client),
# outages and the WARN rate, no progress-bar data, the stream title never blank, a provider
# that never dies, no churn with stream2 queued after stream1, and poll state that never gets
# stuck (an update that dies, timers forgotten by LMS, a reconnected player).

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use RTRFMTest::FakeClient;
use Test::More;

use B ();

use Slim::Control::Request;
use Slim::Formats::RemoteMetadata;
use Slim::Menu::TrackInfo;
use Slim::Music::Info;
use Slim::Player::Playlist;
use Slim::Utils::Log;

use Plugins::RTRFM::Live;
use Plugins::RTRFM::LiveMetadata;
use Plugins::RTRFM::NowPlaying;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

# plugin.rtrfm at DEBUG (as after ["debug","plugin.rtrfm","DEBUG"])
Slim::Utils::Log->addLogCategory( { category => 'plugin.rtrfm', defaultLevel => 'DEBUG', description => 'PLUGIN_RTRFM' } );

my $LM         = 'Plugins::RTRFM::LiveMetadata';
my $URL        = 'https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show';
my $STREAM1    = 'https://live.rtrfm.com.au/stream1';
my $STREAM2    = 'https://live.rtrfm.com.au/stream2';
my $OTHER      = 'https://ice1.somafm.com/groovesalad-128-mp3';
my $ICON       = 'plugins/RTRFM/html/images/icon.png';
my $NOW        = 1_790_393_400;    # 2026-09-26 11:30 AWST
my $NEXT_START = 1_790_398_800;    # 13:00, also current.end
my $NEXT_END   = 1_790_406_000;    # 15:00
my $DOT        = " \x{B7} ";

my $DEFAULT = { title => 'RTRFM 92.1 Live', artist => 'RTRFM 92.1', cover => $ICON };
my $MIX     = { title => 'RTRFM Infinite Mix', artist => 'RTRFM 92.1', cover => $ICON };
my $GRP     = {
	title  => 'Global Rhythm Pot',
	artist => 'RTRFM 92.1',
	album  => "11.00am - 1.00pm${DOT}Next: Homegrown${DOT}1.00pm - 3.00pm",
	cover  => 'https://rtrfm.com.au/wp-content/uploads/2012/12/GlobalRhythmPot.jpg',
};
my $HOMEGROWN_AT_BOUNDARY = {
	title  => 'Homegrown',
	artist => 'RTRFM 92.1',
	album  => '1.00pm - 3.00pm',
	cover  => 'https://rtrfm.com.au/wp-content/uploads/2012/12/homegrown-1.jpg',
};
my $HOMEGROWN = { %$HOMEGROWN_AT_BOUNDARY, album => "1.00pm - 3.00pm${DOT}Next: Test Pattern Tunes${DOT}3.00pm - 5.00pm" };

# Record setCurrentTitle and notifyFromArray calls in the same event list as the fake player
# and song, so the push order can be checked.
{
	no warnings 'redefine';
	my $setCurrentTitle = \&Slim::Music::Info::setCurrentTitle;
	*Slim::Music::Info::setCurrentTitle = sub { push @RTRFMTest::FakeClient::EVENTS, [ setCurrentTitle => @_ ]; goto &$setCurrentTitle };
	my $notifyFromArray = \&Slim::Control::Request::notifyFromArray;
	*Slim::Control::Request::notifyFromArray = sub { push @RTRFMTest::FakeClient::EVENTS, [ notifyFromArray => @_ ]; goto &$notifyFromArray };
}

sub fresh_start {
	resetStubs();
	Plugins::RTRFM::NowPlaying::_reset();
	Plugins::RTRFM::LiveMetadata::_reset();
	RTRFMTest::FakeClient->resetEvents;
	setTime( shift || $NOW );
	Plugins::RTRFM::Live->init();
}

sub serve { route( $URL, @_ ) }

# replace the response (keeps the recorded requests)
sub reserve {
	@Slim::Networking::SimpleAsyncHTTP::ROUTES = ();
	serve(@_);
}

# a player whose playlist plays $url
sub player {
	my ( $id, $url, %args ) = @_;
	my $player = RTRFMTest::FakeClient->new( $id, %args );
	play_url( $player, $url ) if defined $url;
	return $player;
}

sub play_url { $Slim::Player::Playlist::PLAYLISTS{ $_[0]->id } = [ $_[1] ] }

# call the registered provider, as Slim::Player::Protocols::HTTP::getMetadataFor does
sub provide {
	my ( $client, $url ) = @_;
	my $provider = Slim::Formats::RemoteMetadata->getProviderFor($url) or return 'no provider';
	return $provider->( $client, $url );
}

sub lm_timers {
	return grep { B::svref_2object( $_->{code} )->STASH->NAME eq $LM } Slim::Utils::Timers->pending;
}

sub delay_of { my @t = lm_timers(); return @t == 1 ? $t[0]->when - Time::HiRes::time() : undef }

sub newmetadata {
	my $client = shift;
	return grep { $_->{request}[0] eq 'newmetadata' && ( !$client || $_->{client} == $client ) } @Slim::Control::Request::NOTIFICATIONS;
}

sub current_title { Slim::Music::Info::getCurrentTitle( undef, shift ) }

sub debug_logged {
	my $re = shift;
	return grep { $_->{message} =~ $re } Slim::Utils::Log->messages( level => 'DEBUG', category => 'plugin.rtrfm' );
}

sub warnings_logged { Slim::Utils::Log->messages( level => 'WARN', category => 'plugin.rtrfm' ) }

sub errors_logged { Slim::Utils::Log->messages( level => 'ERROR', category => 'plugin.rtrfm' ) }

sub decoded_fixture {
	require JSON::PP;
	return JSON::PP->new->utf8->decode( fixture("live/$_[0]") );
}

sub info_from { Plugins::RTRFM::NowPlaying->parse( decoded_fixture( $_[0] ), $_[1] || $NOW ) }

# ---------------------------------------------------------------------------

subtest 'registration: Live->init registers one provider, one parser, one TrackInfo provider' => sub {
	fresh_start();
	my $re = Plugins::RTRFM::LiveMetadata::LIVE_RE();

	is( ref $re, 'Regexp', 'LIVE_RE is a regex' );
	is( scalar @Slim::Formats::RemoteMetadata::PROVIDERS, 1, 'one metadata provider' );
	is( "$Slim::Formats::RemoteMetadata::PROVIDERS[0][0]", "$re", 'provider registered with LIVE_RE' );
	is( $Slim::Formats::RemoteMetadata::PROVIDERS[0][1], \&Plugins::RTRFM::LiveMetadata::provider, 'provider func' );
	is( scalar @Slim::Formats::RemoteMetadata::PARSERS, 1, 'one metadata parser' );
	is( "$Slim::Formats::RemoteMetadata::PARSERS[0][0]", "$re", 'parser registered with LIVE_RE' );
	is( $Slim::Formats::RemoteMetadata::PARSERS[0][1], \&Plugins::RTRFM::LiveMetadata::parser, 'parser func' );

	is_deeply( [ keys %Slim::Menu::TrackInfo::PROVIDERS ], ['rtrfm_live_show'], 'one TrackInfo provider: rtrfm_live_show' );
	my $ti = $Slim::Menu::TrackInfo::PROVIDERS{rtrfm_live_show};
	is( $ti->{after}, 'top', "TrackInfo provider after => 'top'" );
	is( $ti->{func}, \&Plugins::RTRFM::LiveMetadata::trackInfo, 'TrackInfo provider func' );

	is( scalar keys %Slim::Music::Info::TITLE_CALLBACKS, 1, 'one current-title change callback (stream title never blank)' );
	is( scalar requests(), 0, 'init: no request' );
	is( scalar Slim::Utils::Timers->pending, 0, 'init: no timer' );
	clearTime();
};

subtest 'LIVE_RE: the must-match and must-not-match lists' => sub {
	fresh_start();
	my $re = Plugins::RTRFM::LiveMetadata::LIVE_RE();

	for my $url (
		'https://live.rtrfm.com.au/stream1',
		'http://live.rtrfm.com.au/stream1',
		'https://live.rtrfm.com.au/stream2',
		'http://live.rtrfm.com.au:8000/stream1',
		'https://live.rtrfm.com.au/stream1?x=1',
	) {
		like( $url, $re, "matches $url" );
		ok( Slim::Formats::RemoteMetadata->getProviderFor($url), "provider found for $url" );
	}

	for my $url (
		'https://live.rtrfm.com.au/stream3',
		'https://live.rtrfm.com.au/stream10',
		'https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=abc&e=1',
		'rtrfm://episode/saturdayjazz/2026-09-19',
		'https://example.com/?u=https://live.rtrfm.com.au/stream1',
		'https://live.rtrfm.com.au.evil.example/stream1',
	) {
		unlike( $url, $re, "does not match $url" );
		is( Slim::Formats::RemoteMetadata->getProviderFor($url), undef, "no provider for $url" );
	}

	is( Plugins::RTRFM::LiveMetadata::streamOf('http://live.rtrfm.com.au:8000/stream1'), 1, 'streamOf: stream1 variant' );
	is( Plugins::RTRFM::LiveMetadata::streamOf('https://live.rtrfm.com.au/stream2'),     2, 'streamOf: stream2' );
	is( Plugins::RTRFM::LiveMetadata::streamOf($OTHER), undef, 'streamOf: other URL' );
	is( Plugins::RTRFM::LiveMetadata::streamOf(undef),  undef, 'streamOf: undef' );
	clearTime();
};

subtest 'parser: returns 1 for both streams (ICY data swallowed), no side effects' => sub {
	fresh_start();
	my $p = player( 'p1', $STREAM1 );
	for my $url ( $STREAM1, $STREAM2, 'http://live.rtrfm.com.au:8000/stream1' ) {
		my $parser = Slim::Formats::RemoteMetadata->getParserFor($url);
		is( $parser->( $p, $url, "StreamTitle='';" ), 1, "parser returns 1 for $url" );
	}
	is( scalar @Slim::Music::Info::TITLE_CALLS, 0, 'no title set' );
	is( scalar requests(), 0, 'no request' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer' );
	clearTime();
};

subtest 'stream2: static metadata, no request, no timer' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );

	is_deeply( provide( undef, $STREAM2 ), $MIX, 'no client: exactly {title, artist, cover}' );
	my $p = player( 'p1', $STREAM2 );
	is_deeply( provide( $p, $STREAM2 ), $MIX, 'playing client: exactly {title, artist, cover}' );
	is_deeply( provide( $p, 'http://live.rtrfm.com.au:8000/stream2' ), $MIX, 'http/:8000 variant: same' );
	is( scalar requests(), 0, 'no request' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer' );
	clearTime();
};

subtest 'stream1 first call: default at once, one request, push in order, then the show' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	my $p = player( 'p1', $STREAM1 );

	is_deeply( provide( $p, $STREAM1 ), $DEFAULT, 'first call returns the default metadata' );
	is( scalar requests(), 1, 'exactly one request' );
	is( requests() && ( requests() )[0]{url}, $URL, 'to the now/next endpoint' );

	RTRFMTest::FakeClient->resetEvents;
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;

	my @events = @RTRFMTest::FakeClient::EVENTS;
	is( scalar @events, 4, 'four push steps' ) or diag explain [ map { $_->[0] } @events ];
	is_deeply( [ map { $_->[0] } @events ], [qw(setCurrentTitle pluginData currentPlaylistUpdateTime notifyFromArray)], 'in order: title, wmaMeta, update time, notify' );
	is_deeply( [ @{ $events[0] }[ 1 .. $#{ $events[0] } ] ], [ $STREAM1, 'Global Rhythm Pot' ], 'setCurrentTitle(url, "Global Rhythm Pot") without a client' );
	is( $events[1][1], $p->playingSong, 'wmaMeta set on the playing song' );
	is( $events[1][2], 'wmaMeta', 'pluginData key wmaMeta' );
	is_deeply( $events[1][3], $GRP, 'wmaMeta = { title, artist, album, cover }' );
	is( $events[2][1], $p, 'currentPlaylistUpdateTime on the master' );
	is( $events[2][2], $NOW, 'with the current time' );
	is( $events[3][1], $p, 'newmetadata sent for the master' );
	is_deeply( $events[3][2], ['newmetadata'], "notifyFromArray(master, ['newmetadata'])" );

	is_deeply( provide( $p, $STREAM1 ), $GRP, 'next call returns the show metadata' );
	is( current_title($STREAM1), 'Global Rhythm Pot', 'current title = show name' );
	is( scalar requests(), 1, 'still one request' );
	is( scalar lm_timers(), 1, 'one poll timer' );
	clearTime();
};

subtest 'no progress bar: no duration/secs, no duration/startOffset calls' => sub {
	fresh_start( $NEXT_START - 600 );
	serve( file => 'live/now-next-normal.json' );
	my $p = player( 'p1', $STREAM1 );

	my @results = ( provide( $p, $STREAM1 ), provide( undef, $STREAM1 ), provide( $p, $STREAM2 ) );
	reserve( file => 'live/now-next-after-change.json' );
	provide( $p, $STREAM1 );
	advanceTime(610);    # boundary
	push @results, provide( $p, $STREAM1 );
	advanceTime(60);     # poll after the change
	push @results, provide( $p, $STREAM1 ), Plugins::RTRFM::LiveMetadata::buildMeta( undef, $NOW );

	ok( !( grep { exists $_->{duration} || exists $_->{secs} } @results ), 'no provider result has duration or secs' );
	is( scalar $p->playingSong->calls('duration'),    0, 'no $song->duration calls' );
	is( scalar $p->playingSong->calls('startOffset'), 0, 'no $song->startOffset calls' );
	is( scalar newmetadata($p), 2, 'pushes happened (first poll, show change); the stream2 call while stream1 plays kept the poll' );
	clearTime();
};

subtest 'buildMeta: field mapping and the show boundary (pure)' => sub {
	my $normal = info_from('now-next-normal.json');

	is_deeply( $LM->buildMeta( $normal, $NOW ), $GRP, 'normal: current show, album "<time> · Next: <show> · <time>"' );
	is_deeply( Plugins::RTRFM::LiveMetadata::buildMeta( $normal, $NEXT_START - 1 ), $GRP, 'as a function; 1 s before the boundary' );
	is_deeply( $LM->buildMeta( $normal, 1_790_398_810 ), $HOMEGROWN_AT_BOUNDARY, 'next.start + 10 s: Homegrown, album = its time slot only' );
	is_deeply( $LM->buildMeta( $normal, $NEXT_END ), $DEFAULT, 'after next.end: default' );

	my $noNext = info_from('now-next-no-next.json');
	is_deeply( $LM->buildMeta( $noNext, $NOW ), { %$GRP, album => '11.00am - 1.00pm' }, 'no next: album = time slot only' );
	is_deeply( $LM->buildMeta( $noNext, $NEXT_START + 10 ), $DEFAULT, 'no next, 10 s after current.end: default' );

	my $noCurrent = info_from('now-next-no-current.json');
	is_deeply( $LM->buildMeta( $noCurrent, $NOW ), $DEFAULT, 'no current, before next.start: default' );
	is_deeply( $LM->buildMeta( $noCurrent, $NEXT_START ), $HOMEGROWN_AT_BOUNDARY, 'no current, at next.start: next promoted' );

	my %edited = %$normal;
	$edited{current} = { %{ $normal->{current} }, image => undef, timeText => undef };
	$edited{next}    = { %{ $normal->{next} }, timeText => undef };
	is_deeply( $LM->buildMeta( \%edited, $NOW ), { %$GRP, cover => $ICON, album => 'Next: Homegrown' }, 'no thumbnail: icon; no time texts: album "Next: <show>"' );

	$edited{next} = undef;
	is_deeply( $LM->buildMeta( \%edited, $NOW ), { title => 'Global Rhythm Pot', artist => 'RTRFM 92.1', cover => $ICON }, 'no time text and no next: no album key' );

	$edited{current} = { %{ $normal->{current} }, end => undef };
	is_deeply( $LM->buildMeta( \%edited, $NEXT_END + 3600 ), { %$GRP, album => '11.00am - 1.00pm' }, 'current without an end: kept' );

	is_deeply( $LM->buildMeta( undef, $NOW ), $DEFAULT, 'no info: default' );
	is_deeply( $LM->buildMeta( { current => 'junk', next => [] }, $NOW ), $DEFAULT, 'junk info: default' );
	is_deeply( $LM->buildMeta( info_from('now-next-entities.json'), $NOW )->{title}, 'Black & Blue', 'entity-decoded name (from parse)' );
};

subtest 'scheduling: clamp(next.start + 60 - now, 60, 900); 30 s after errors; 300 s without current/next' => sub {
	my $first_delay = sub {
		my ( $start, @response ) = @_;
		fresh_start($start);
		serve(@response);
		provide( player( 'p1', $STREAM1 ), $STREAM1 );
		is( scalar lm_timers(), 1, 'one timer' );
		return delay_of();
	};

	is( $first_delay->( $NEXT_START - 600, file => 'live/now-next-normal.json' ), 660, 'next.start 600 s away: poll at next.start + 60' );
	is( $first_delay->( $NEXT_START - 839, file => 'live/now-next-normal.json' ), 899, 'next.start 839 s away: next.start + 60' );
	is( $first_delay->( $NEXT_START - 30,  file => 'live/now-next-normal.json' ), 90,  'next.start 30 s away: next.start + 60' );
	is( $first_delay->( $NEXT_START - 7200, file => 'live/now-next-normal.json' ), 900, 'next.start 2 h away: capped at +900 s' );
	is( $first_delay->( $NEXT_START + 300, file => 'live/now-next-normal.json' ), 60, 'next.start in the past (stale API data): +60 s floor' );
	is( $first_delay->( $NOW, code => 500, content => 'oops' ), 30, 'HTTP 500: +30 s' );
	is( $first_delay->( $NOW, file => 'live/now-next-success-false.json' ), 30, 'success:false: +30 s' );
	is( $first_delay->( $NOW, file => 'live/now-next-body-zero.json' ), 30, 'body 0: +30 s' );
	is( $first_delay->( $NOW, error => 'Timed out waiting for data' ), 30, 'timeout: +30 s' );
	is( $first_delay->( $NOW, file => 'live/now-next-no-next.json' ), 300, 'no next: +300 s' );
	is( $first_delay->( $NOW, file => 'live/now-next-no-current.json' ), 300, 'no current: +300 s' );

	# stale data: one request per minute, no hot loop
	fresh_start( $NEXT_START + 300 );
	serve( file => 'live/now-next-normal.json' );
	provide( player( 'p1', $STREAM1 ), $STREAM1 );
	advanceTime(10) for 1 .. 60;
	is( scalar requests(), 11, 'stale data for 10 min: 11 requests (one a minute)' );
	clearTime();
};

subtest 'show change: one request, the new show, one more newmetadata; unchanged data: no push' => sub {
	fresh_start( $NEXT_START - 600 );
	serve( file => 'live/now-next-normal.json' );
	my $p = player( 'p1', $STREAM1 );

	is_deeply( provide( $p, $STREAM1 ), $GRP, 'on air: Global Rhythm Pot' );
	is( scalar requests(), 1, 'one request' );
	is( scalar newmetadata($p), 1, 'one newmetadata' );

	reserve( file => 'live/now-next-after-change.json' );
	advanceTime(659);
	is( scalar requests(), 1, '1 s before the scheduled poll: no new request' );

	advanceTime(1);
	is( scalar requests(), 2, 'at the scheduled poll: exactly one new request' );
	is_deeply( provide( $p, $STREAM1 ), $HOMEGROWN, 'title Homegrown' );
	is( current_title($STREAM1), 'Homegrown', 'current title Homegrown' );
	is( scalar newmetadata($p), 2, 'exactly one more newmetadata' );
	is_deeply( $p->playingSong->pluginData('wmaMeta'), $HOMEGROWN, 'wmaMeta updated' );
	is( delay_of(), 900, 'next poll capped at +900 s' );

	advanceTime(900);
	is( scalar requests(), 3, 'next poll: one request' );
	is( scalar newmetadata($p), 2, 'unchanged data: no newmetadata' );
	is( scalar lm_timers(), 1, 'still one timer' );
	clearTime();
};

subtest 'stop conditions: at poll time no request and no new timer' => sub {
	my @cases = (
		[ 'player stopped',                sub { $_[0]->mode('stop') } ],
		[ 'playlist URL is another station', sub { play_url( $_[0], $OTHER ) } ],
		[ 'playlist URL is stream2',       sub { play_url( $_[0], $STREAM2 ) } ],
	);

	for my $case (@cases) {
		my ( $name, $change ) = @$case;
		fresh_start();
		serve( file => 'live/now-next-normal.json' );
		my $p = player( 'p1', $STREAM1 );
		provide( $p, $STREAM1 );
		is( scalar lm_timers(), 1, "$name: polling" );

		$change->($p);
		advanceTime(900);
		is( scalar requests(), 1, "$name: no request at the poll" );
		is( scalar lm_timers(), 0, "$name: no LiveMetadata timers left" );
		ok( ( grep { $_->{level} eq 'DEBUG' && $_->{message} =~ /stop/i } Slim::Utils::Log->messages ), "$name: stop logged at DEBUG" );
	}

	# a stream2 provider call kills the master's stream1 timer
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	my $p = player( 'p1', $STREAM1 );
	provide( $p, $STREAM1 );
	is( scalar lm_timers(), 1, 'stream1: polling' );
	play_url( $p, $STREAM2 );
	is_deeply( provide( $p, $STREAM2 ), $MIX, 'stream2 metadata' );
	is( scalar lm_timers(), 0, 'stream2 provider call: stream1 timer killed' );
	advanceTime(3600);
	is( scalar requests(), 1, 'no further requests' );

	# the player moves on while a fetch is in flight: no push, no timer
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	$p = player( 'p1', $STREAM1 );
	provide( $p, $STREAM1 );
	play_url( $p, $OTHER );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( scalar newmetadata(), 0, 'in flight, then another station: no newmetadata' );
	is( $p->playingSong->pluginData('wmaMeta'), undef, 'no wmaMeta on the other station' );
	is( scalar lm_timers(), 0, 'no timer' );

	# paused: polling continues
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	$p = player( 'p1', $STREAM1, mode => 'pause' );
	provide( $p, $STREAM1 );
	is( scalar lm_timers(), 1, 'paused player: polling starts' );
	advanceTime(900);
	is( scalar requests(), 2, 'paused: the poll fetches' );
	is( scalar lm_timers(), 1, 'paused: next poll scheduled' );

	# stream1 -> stream2 -> stream1: never more than one timer
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	$p = player( 'p1', $STREAM1 );
	my $max = 0;
	for my $url ( $STREAM1, $STREAM2, $STREAM1, $STREAM2, $STREAM1 ) {
		play_url( $p, $url );
		provide( $p, $url ) for 1 .. 3;
		advanceTime(60);
		$max = scalar lm_timers() if lm_timers() > $max;
	}
	is( $max, 1, 'switching streams: at most one timer at a time' );
	is( scalar requests(), 1, 'switching streams within the cache lifetime: one request' );
	clearTime();
};

subtest 'sharing: sync slaves, many calls, several masters, no client, not the playing URL' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	my $master = player( 'm1', $STREAM1 );
	my $slave  = $master->makeSlave('s1');

	is_deeply( provide( $slave, $STREAM1 ), $GRP, 'slave gets the show metadata' );
	my @t = lm_timers();
	is( scalar @t, 1, 'sync slave: one timer' );
	is( $t[0]{obj}, $master, 'keyed on the master' );
	is( scalar newmetadata($master), 1, 'newmetadata sent for the master' );
	provide( $master, $STREAM1 );
	is( scalar lm_timers(), 1, 'master call afterwards: still one timer' );

	# ten calls, one timer, one request
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	my $p = player( 'p1', $STREAM1 );
	provide( $p, $STREAM1 ) for 1 .. 10;
	is( scalar requests(), 1, 'ten calls while in flight: one request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	provide( $p, $STREAM1 ) for 1 .. 10;
	is( scalar lm_timers(), 1, 'ten more calls: one timer' );
	is( scalar requests(), 1, 'still one request' );

	# two masters: two timers, one upstream request per refresh
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	my ( $pa, $pb ) = ( player( 'a', $STREAM1 ), player( 'b', $STREAM1 ) );
	provide( $_, $STREAM1 ) for $pa, $pb;
	is( scalar lm_timers(), 2, 'two masters: two timers' );
	is_deeply( [ sort map { $_->{obj}->id } lm_timers() ], [qw(a b)], 'one per master' );
	is( scalar requests(), 1, 'first refresh: one request' );
	advanceTime(900);
	is( scalar requests(), 2, 'second refresh: one more request' );
	advanceTime(900);
	is( scalar requests(), 3, 'third refresh: one more request' );
	is( scalar lm_timers(), 2, 'still two timers' );
	is( scalar newmetadata($pa) + scalar newmetadata($pb), 2, 'each master pushed once (data unchanged)' );

	# no client
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	is_deeply( provide( undef, $STREAM1 ), $DEFAULT, 'no client: default metadata' );
	is( scalar lm_timers(), 0, 'no client: no timer' );
	is( scalar requests(), 0, 'no client: no request' );

	# stream1 queued but not current (or a favourites info view): metadata, no polling
	$p = player( 'p1', $OTHER );
	is_deeply( provide( $p, $STREAM1 ), $DEFAULT, 'not the playing URL: metadata' );
	is( scalar lm_timers(), 0, 'not the playing URL: no timer' );
	$p->mode('stop');
	play_url( $p, $STREAM1 );
	provide( $p, $STREAM1 );
	is( scalar lm_timers(), 0, 'stopped player: no timer' );
	is( scalar requests(), 0, 'no request' );

	# after an LMS restart (module state empty), the first call starts polling again
	Plugins::RTRFM::LiveMetadata::_reset();
	$p->mode('play');
	provide( $p, $STREAM1 );
	is( scalar lm_timers(), 1, 'first call after a restart: polling' );
	clearTime();
};

subtest 'outage: the last good show until its end, then default; one WARN per run' => sub {
	fresh_start( $NEXT_START - 3600 );
	serve( file => 'live/now-next-no-next.json' );
	my $p = player( 'p1', $STREAM1 );
	my $onAir = { %$GRP, album => '11.00am - 1.00pm' };

	is_deeply( provide( $p, $STREAM1 ), $onAir, 'good fetch: on air' );
	is( delay_of(), 300, 'no next: poll in 300 s' );

	reserve( code => 500, content => 'oops' );
	my ( $before, $after ) = ( 0, 0 );
	my $bad = 0;
	while ( time() < $NEXT_START + 120 ) {
		advanceTime(10);
		my $meta = provide( $p, $STREAM1 );
		if ( time() < $NEXT_START ) { $before++; $bad++ unless _same( $meta, $onAir ) }
		else                        { $after++;  $bad++ unless _same( $meta, $DEFAULT ) }
	}
	is( $bad, 0, "last good show while on air ($before calls), then default ($after calls)" );
	# cache fresh until 12:15 (polls at 12:05 and 12:10 answered from it), then a failed request
	# every 30 s from 12:15:00 to 13:02:00
	is( scalar requests(), 1 + 95, 'polling every 30 s during the outage' );
	is( delay_of(), 30, 'still retrying every 30 s' );
	is( scalar newmetadata($p), 1, 'no push while failing' );
	is( scalar warnings_logged(), 1, 'the whole run of failures: one WARN' );
	is( scalar errors_logged(), 0, 'no errors' );
	is( current_title($STREAM1), 'RTRFM 92.1 Live', 'stream title back to the default' );

	# recovery ends the run; the next run warns once again
	reserve( file => 'live/now-next-after-change.json' );
	advanceTime(30);
	is_deeply( provide( $p, $STREAM1 ), $HOMEGROWN, 'recovered' );
	is( scalar newmetadata($p), 2, 'recovery pushed' );
	reserve( file => 'live/now-next-success-false.json' );
	advanceTime(30) for 1 .. 120;
	is( scalar warnings_logged(), 2, 'second run: one more WARN' );

	# the normal fixture as last good data: its next show is promoted at the boundary
	fresh_start( $NEXT_START - 60 );
	serve( file => 'live/now-next-normal.json' );
	$p = player( 'p1', $STREAM1 );
	is_deeply( provide( $p, $STREAM1 ), $GRP, 'normal data: on air' );
	reserve( error => 'Timed out waiting for data' );
	advanceTime(30) for 1 .. 4;
	is_deeply( provide( $p, $STREAM1 ), $HOMEGROWN_AT_BOUNDARY, 'outage across the boundary: next show from the last good data' );
	advanceTime(30) while time() < $NEXT_END - 30;
	is_deeply( provide( $p, $STREAM1 ), $HOMEGROWN_AT_BOUNDARY, 'until its end' );
	advanceTime(30);
	is_deeply( provide( $p, $STREAM1 ), $DEFAULT, 'after its end: default' );
	is( scalar warnings_logged(), 1, 'one WARN' );
	clearTime();
};

subtest 'push without a playing song: title, update time and notify still happen' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	my $p = player( 'p1', $STREAM1, song => undef );

	provide( $p, $STREAM1 );
	RTRFMTest::FakeClient->resetEvents;
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { $_->[0] } @RTRFMTest::FakeClient::EVENTS ], [qw(setCurrentTitle currentPlaylistUpdateTime notifyFromArray)], 'no wmaMeta step, the rest in order' );
	is( current_title($STREAM1), 'Global Rhythm Pot', 'title set' );
	is( scalar newmetadata($p), 1, 'newmetadata sent' );
	clearTime();
};

subtest 'stream title: never blank, the show (stream1) or Infinite Mix (stream2)' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );

	# the stream's headers arrive before anything else: LMS stores the empty icy-name as " "
	Slim::Music::Info::setCurrentTitle( $STREAM1, ' ' );
	is( current_title($STREAM1), 'RTRFM 92.1 Live', 'blank header title before any data: default title' );

	my $p = player( 'p1', $STREAM1 );
	provide( $p, $STREAM1 );
	is( current_title($STREAM1), 'RTRFM 92.1 Live', 'right after playback starts: default title' );
	Slim::Music::Info::setCurrentTitle( $STREAM1, ' ' );
	is( current_title($STREAM1), 'RTRFM 92.1 Live', 'blank header title while fetching: default title' );

	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( current_title($STREAM1), 'Global Rhythm Pot', 'after the fetch: the show' );

	for my $title ( ' ', '', undef, 'RTRFM 92.1 Live' ) {
		Slim::Music::Info::setCurrentTitle( $STREAM1, $title );
		is( current_title($STREAM1), 'Global Rhythm Pot', 'LMS sets ' . ( defined $title ? "'$title'" : 'undef' ) . ': still the show' );
	}
	Slim::Music::Info::setCurrentTitle( 'http://live.rtrfm.com.au:8000/stream1', ' ' );
	is( current_title('http://live.rtrfm.com.au:8000/stream1'), 'Global Rhythm Pot', 'http/:8000 variant: the show' );

	Slim::Music::Info::setCurrentTitle( $STREAM2, ' ' );
	is( current_title($STREAM2), 'RTRFM Infinite Mix', 'stream2 blank header title: RTRFM Infinite Mix' );
	play_url( $p, $STREAM2 );
	provide( $p, $STREAM2 );
	is( current_title($STREAM2), 'RTRFM Infinite Mix', 'stream2 after a provider call: RTRFM Infinite Mix' );

	Slim::Music::Info::setCurrentTitle( $OTHER, ' ' );
	is( current_title($OTHER), ' ', 'other stations untouched' );
	Slim::Music::Info::setCurrentTitle( 'https://live.rtrfm.com.au/stream3', 'x' );
	is( current_title('https://live.rtrfm.com.au/stream3'), 'x', 'non-matching live URL untouched' );

	# at the show boundary the provider updates the title without waiting for the poll
	setTime( $NEXT_START + 10 );
	play_url( $p, $STREAM1 );
	provide( $p, $STREAM1 );
	is( current_title($STREAM1), 'Homegrown', 'boundary: the provider sets the new show' );

	# a failing title lookup never breaks LMS's setCurrentTitle
	{
		no warnings 'redefine';
		local *Plugins::RTRFM::NowPlaying::cached = sub { die "cache exploded\n" };
		ok( eval { Slim::Music::Info::setCurrentTitle( $STREAM1, ' ' ); 1 }, 'title callback never dies' ) or diag $@;
		is( current_title($STREAM1), 'RTRFM 92.1 Live', 'falls back to the default title' );
	}
	clearTime();
};

subtest 'the provider never dies' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	my $p = player( 'p1', $STREAM1 );

	no warnings 'redefine';
	local *Plugins::RTRFM::NowPlaying::cached = sub { die "cache exploded\n" };
	my @results = ( scalar eval { provide( $p, $STREAM1 ) } );
	my $errors = scalar errors_logged();
	push @results, scalar eval { provide( $p, $STREAM1 ) } for 1 .. 5;
	is( scalar( grep { ref $_ eq 'HASH' } @results ), 6, 'six calls, six results, no exception' );
	is_deeply( $results[$_], $DEFAULT, "call $_: default metadata" ) for 0, 5;
	ok( $errors >= 1, 'the error is logged' );
	is( scalar errors_logged(), $errors, 'but not again on every call' );
	ok( !( grep { $_->{message} =~ /cache exploded/ } Slim::Utils::Log->messages( level => 'WARN' ) ), 'no WARNs for it either' );

	# the poll that failed is retried, not stuck
	is( scalar lm_timers(), 1, 'failed poll: retry scheduled' );
	clearTime();
};

subtest 'churn: stream1 playing, stream2 queued, alternating provider calls: one poll, no repeated push' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	my $p = player('p1');
	$Slim::Player::Playlist::PLAYLISTS{p1} = [ $STREAM1, $STREAM2 ];    # stream1 plays, stream2 queued

	# Jivelite's "status 0 2 subscribe:600" asks for both entries every ~1.3 s
	my ( $max, $bad ) = ( 0, 0 );
	for ( 1 .. 20 ) {
		$bad++ unless _same( provide( $p, $STREAM1 ), $GRP ) && _same( provide( $p, $STREAM2 ), $MIX );
		$max = scalar lm_timers() if lm_timers() > $max;
		advanceTime(1.3);
	}
	is( $bad, 0, 'every call: the show for stream1, Infinite Mix for stream2' );
	is( scalar requests(), 1, '20 status calls: one upstream request' );
	is( scalar newmetadata($p), 1, 'one newmetadata (the first poll)' );
	is( scalar $p->updateTimes, 1, 'currentPlaylistUpdateTime set once' );
	is( scalar lm_timers(), 1, 'the poll timer survives the stream2 calls' );
	is( $max, 1, 'never more than one timer' );
	is( scalar debug_logged(qr/start polling/), 1, 'polling started once' );
	is( scalar debug_logged(qr/stop polling/),  0, 'and never stopped' );

	# stream2 plays: the poll stops; back to stream1 with the same show: no push again
	$Slim::Player::Playlist::INDEX{p1} = 1;
	provide( $p, $STREAM2 );
	is( scalar lm_timers(), 0, 'stream2 plays: poll stopped' );
	$Slim::Player::Playlist::INDEX{p1} = 0;
	provide( $p, $STREAM1 ) for 1 .. 3;
	is( scalar lm_timers(), 1, 'back on stream1: polling again' );
	is( scalar newmetadata($p), 1, 'metadata unchanged since the last push: no newmetadata' );
	is( scalar $p->updateTimes, 1, 'no currentPlaylistUpdateTime bump' );

	# the show changes while stream2 plays: the restart pushes the new show
	$Slim::Player::Playlist::INDEX{p1} = 1;
	provide( $p, $STREAM2 );
	reserve( file => 'live/now-next-after-change.json' );
	advanceTime( $NEXT_START + 120 - time() );
	$Slim::Player::Playlist::INDEX{p1} = 0;
	is_deeply( provide( $p, $STREAM1 ), $HOMEGROWN, 'back on stream1 after the show change: the new show' );
	is( scalar newmetadata($p), 2, 'changed metadata: one more newmetadata' );
	is( scalar requests(), 2, 'one more request' );
	clearTime();
};

subtest 'stuck state: an update that dies after an asynchronous fetch is retried after 30 s' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	my $p = player( 'p1', $STREAM1 );

	provide( $p, $STREAM1 ) for 1 .. 4;
	is( scalar debug_logged(qr/start polling/), 1, 'fetch in flight: the poll is live, not restarted' );

	{
		no warnings 'redefine';
		my $dies = 1;
		my $currentPlaylistUpdateTime = \&RTRFMTest::FakeClient::currentPlaylistUpdateTime;
		local *RTRFMTest::FakeClient::currentPlaylistUpdateTime = sub {
			if ( $dies && @_ > 1 ) { $dies = 0; die "push exploded\n" }
			goto &$currentPlaylistUpdateTime;
		};
		Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	}

	is( scalar( grep { $_->{message} =~ /push exploded/ } errors_logged() ), 1, 'the failure is logged at ERROR' );
	ok( !( grep { $_->{message} =~ /callback failed/ } Slim::Utils::Log->messages ), 'caught by LiveMetadata, not left to NowPlaying' );
	is( scalar newmetadata($p), 0, 'no newmetadata yet' );
	is( delay_of(), 30, 'retry scheduled in 30 s' );

	provide( $p, $STREAM1 ) for 1 .. 3;
	is( scalar lm_timers(), 1, 'provider calls meanwhile: still one timer' );
	advanceTime(29);
	is( scalar newmetadata($p), 0, '29 s later: no push yet' );
	advanceTime(1);
	is( scalar newmetadata($p), 1, 'the retry pushed' );
	is_deeply( $p->playingSong->pluginData('wmaMeta'), $GRP, 'wmaMeta set' );
	is( scalar requests(), 1, 'answered from the cache: still one request' );
	is( delay_of(), 900, 'back on the normal schedule' );
	clearTime();
};

subtest 'stuck state: timers forgotten by LMS, a reconnected player: the next provider call restarts polling' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );
	my $p = player( 'p1', $STREAM1 );

	provide( $p, $STREAM1 );
	is( scalar lm_timers(), 1, 'polling' );

	Slim::Utils::Timers::forgetTimer($p);    # as Slim::Player::Client::forgetClient does
	is( scalar lm_timers(), 0, 'forgetTimer: no timer left' );
	provide( $p, $STREAM1 );
	is( scalar lm_timers(), 1, 'next provider call: polling again' );
	is( scalar debug_logged(qr/stale poll state/), 1, 'the stale poll state is logged at DEBUG' );
	is( scalar newmetadata($p), 1, 'unchanged metadata: no second push' );
	advanceTime(900);
	is( scalar requests(), 2, 'the restarted poll fetches' );

	# the player reconnects: a new client object with the same id
	Slim::Utils::Timers::forgetTimer($p);
	my $p2 = player( 'p1', $STREAM1 );
	provide( $p2, $STREAM1 );
	my @t = lm_timers();
	is( scalar @t, 1, 'reconnected player: one timer' );
	is( $t[0] && $t[0]{obj}, $p2, 'keyed on the new client object' );
	is( scalar newmetadata($p2), 1, 'the new client object gets its push' );

	# ... even while the old object's timer is still pending
	my $p3 = player( 'p1', $STREAM1 );
	provide( $p3, $STREAM1 );
	@t = lm_timers();
	is( scalar @t, 1, 'old timer killed: one timer' );
	is( $t[0] && $t[0]{obj}, $p3, 'keyed on the newest client object' );
	clearTime();
};

done_testing();

sub _same {
	my ( $x, $y ) = @_;
	return 0 unless ref $x eq 'HASH' && keys %$x == keys %$y;
	for ( keys %$y ) { return 0 unless defined $x->{$_} && $x->{$_} eq $y->{$_} }
	return 1;
}
