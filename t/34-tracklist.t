#!/usr/bin/perl
# Plugins::RTRFM::Tracklist: the Airnet playlist request URL, normalisation (approximateTime
# offsets, never the 12-hour 'time'; clamping; unknown times; text clean-up; stable order),
# offset and row formatting, error mapping (400/404/[] -> [], other failures -> error) and the
# cache TTLs under the fake clock.
#
# Fixtures in t/data/ondemand/playlist-*.json were recorded from the live Airnet playlists
# endpoint on 2026-09-26 (about 05:05 UTC). Each keeps every entry of the response, trimmed to
# the fields type, id, artist, title, release, time, approximateTime and contentDescriptors.
# playlist-400.json is the body Airnet sends with HTTP 400 for an unknown episode
# (saturdayjazz 2026-09-19 10:00).

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use JSON::PP ();
use Time::Local qw(timegm);

use Plugins::RTRFM::Tracklist;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $BASE = Plugins::RTRFM::Util::AIRNET_BASE;

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $NOW = timegm( 0, 40, 3, 26, 8, 2026 );

my $ENDASH = "\x{2013}";
my $MIDDOT = "\x{B7}";

my $HOUR = 3600;
my $DAY  = 86400;

# Airnet playlist URL for <slug> and a 'YYYY-MM-DD HH:MM:SS' start
sub playlistUrl {
	my ( $slug, $start ) = @_;
	my ( $date, $h, $m, $s ) = $start =~ /^(\S+) (\d\d):(\d\d):(\d\d)$/ or die "bad start $start";
	return "$BASE/programs/$slug/episodes/$date+$h%3A$m%3A$s/playlists";
}

my %EPISODE = (
	saturdayjazz => [ 'saturdayjazz', '2026-09-19 09:00:00', 'ondemand/playlist-saturdayjazz-2026-09-19.json' ],
	drivetime    => [ 'drivetime',    '2026-09-25 17:00:00', 'ondemand/playlist-drivetime-2026-09-25.json' ],
	allcity      => [ 'allcity',      '2026-09-25 23:00:00', 'ondemand/playlist-allcity-2026-09-25.json' ],
);

sub routeFixtures {
	route( playlistUrl( $_->[0], $_->[1] ), file => $_->[2] ) for values %EPISODE;
}

sub requestCount { scalar( () = requests() ) }

# Tracklist::fetch; returns the collector
sub fetchTracks {
	my ( $slug, $start ) = @_;
	my $c = collector();
	Plugins::RTRFM::Tracklist::fetch( $slug, $start, $c->cb );
	return $c;
}

# The tracks from a collector that was called back exactly once with (\@tracks)
sub tracks_of {
	my ( $c, $name ) = @_;
	is( $c->count, 1, "$name: exactly one callback" );
	my ( $tracks, $error ) = $c->args(0);
	is( ref $tracks, 'ARRAY', "$name: called back with a list" ) or diag( 'error: ' . ( defined $error ? $error : 'undef' ) );
	return $tracks || [];
}

sub fetched {
	my $key = shift;
	return tracks_of( fetchTracks( @{ $EPISODE{$key} }[ 0, 1 ] ), $key );
}

sub rows { [ map { Plugins::RTRFM::Tracklist::formatRow($_) } @{ $_[0] } ] }

sub reset_all {
	resetStubs();
	routeFixtures();
	setTime($NOW);
}

subtest 'fetch: request URL and success' => sub {
	reset_all();

	my $tracks = fetched('saturdayjazz');

	my @requests = requests();
	is( scalar @requests, 1, 'one HTTP request' );
	is( $requests[0]->{method}, 'GET', 'GET' );
	is(
		$requests[0]->{url},
		'https://airnet.org.au/rest/stations/6RTR/programs/saturdayjazz/episodes/2026-09-19+09%3A00%3A00/playlists',
		'request URL for (saturdayjazz, 2026-09-19 09:00:00)'
	);
	unlike( $requests[0]->{headers}->header('User-Agent') || '', qr/libwww-perl/, 'sent through HTTP.pm (no libwww-perl User-Agent)' );
	ok( $requests[0]->{headers}->header('User-Agent'), 'explicit User-Agent' );

	is( scalar @$tracks, 20, '20 tracks' );

	resetStubs();
	route( qr{/playlists$}, content => '[]' );
	fetchTracks( 'saturdayjazz', '2026-09-19 09:00' );
	is( ( requests() )[0]->{url}, playlistUrl( 'saturdayjazz', '2026-09-19 09:00:00' ), 'a start without seconds requests :00' );

	resetStubs();
	route( qr{/playlists$}, content => '[]' );
	fetchTracks( 'drivetime', '2026-09-25 17:00:30' );
	is( ( requests() )[0]->{url}, "$BASE/programs/drivetime/episodes/2026-09-25+17%3A00%3A30/playlists", 'the seconds in the URL come from the start' );

	clearTime();
};

subtest 'Saturday Jazz 2026-09-19: offsets and rows' => sub {
	reset_all();

	my $tracks = fetched('saturdayjazz');
	my $rows   = rows($tracks);

	is( $rows->[0],  "3:00 $MIDDOT Chris Foster $ENDASH Looking Sideways (In Motion)",                         'row 1' );
	is( $rows->[4],  "23:00 $MIDDOT Ella Fitzgerald & Louis Armstrong $ENDASH Isn't This a Lovely Day",         'row 5: trailing space trimmed, no release' );
	is( $rows->[6],  "33:00 $MIDDOT Imogen Thomson & Austin Salisbury $ENDASH Float (Mejadra)",                 'row 7: release trimmed' );
	is( $rows->[10], "1:00:00 $MIDDOT Katie Noonan $ENDASH The Long and Winding Road (Blackbird)",              'row 11: one hour in' );
	is( $rows->[19], "1:55:00 $MIDDOT Matt Smith $ENDASH Forest (Driftwood)",                                   'row 20' );

	is_deeply(
		$tracks->[0],
		{ offset => 180, artist => 'Chris Foster', title => 'Looking Sideways', release => 'In Motion', isLocal => 1 },
		'track 1: exact keys (no offsetUnknown), isLocal from contentDescriptors'
	);
	is_deeply(
		$tracks->[4],
		{ offset => 1380, artist => 'Ella Fitzgerald & Louis Armstrong', title => "Isn't This a Lovely Day", release => undef, isLocal => 0 },
		'track 5: null release is undef, not local'
	);

	is_deeply( [ map { $_->{offset} } @$tracks ], [ sort { $a <=> $b } map { $_->{offset} } @$tracks ], 'sorted by offset' );
	ok( !( grep { $_->{offsetUnknown} } @$tracks ), 'every offset known' );

	clearTime();
};

subtest 'Drivetime 2026-09-25: approximateTime, never the 12-hour time' => sub {
	reset_all();

	my $tracks = fetched('drivetime');
	my $rows   = rows($tracks);

	is( scalar @$tracks, 29, '29 tracks' );
	is( $tracks->[0]->{offset}, 60, 'row 1 offset 60 (17:01, whose time is "05:01:00")' );
	is( $rows->[0],  "1:00 $MIDDOT POND $ENDASH Two Hands",       'row 1' );
	is( $rows->[4],  "22:00 $MIDDOT Sweeping Promises $ENDASH Accent", 'row 5: artist trimmed' );
	is( $rows->[13], "1:01:00 $MIDDOT FKA Twigs $ENDASH Slushy",   'row 14: artist trimmed, past one hour' );
	is( $rows->[23], "1:41:03 $MIDDOT Clare Perrot $ENDASH How Can I Tell You", 'row 24: seconds precision (18:41:03)' );
	is( $rows->[28], "1:59:00 $MIDDOT your best friend jippy $ENDASH The Law of the Vital Few", 'row 29' );
	ok( !( grep { $_->{offset} == 0 } @$tracks ), 'no offset clamped to 0 (which the 12-hour time would give)' );

	clearTime();
};

subtest 'All City 2026-09-25: crosses midnight' => sub {
	reset_all();

	my $tracks = fetched('allcity');
	my $rows   = rows($tracks);

	is( scalar @$tracks, 27, '27 tracks' );

	my ($lif) = grep { $_->{artist} eq 'Mr. Lif' } @$tracks;
	is( $lif->{offset}, 3758, 'Mr. Lif - Earthcrusher (2026-09-26 00:02:38) has offset 3758' );
	is( Plugins::RTRFM::Tracklist::formatRow($lif), "1:02:38 $MIDDOT Mr. Lif $ENDASH Earthcrusher", 'formatted 1:02:38' );

	my ($rubik) = grep { $_->{artist} eq 'COMPLETE' } @$tracks;
	is( $rubik->{title}, "Rubik\x{2019}s Cube", 'UTF-8 punctuation kept (Rubik\x{2019}s Cube)' );
	is( $rubik->{isLocal}, 1, 'isLocal' );

	is( $rows->[0],  "3:12 $MIDDOT Artifacts $ENDASH Dynamite Soul", 'first row' );
	is( $rows->[26], "1:57:12 $MIDDOT Jurassic 5 $ENDASH Twelve",    'last row (00:57:12 the next day)' );

	clearTime();
};

subtest 'normalise: edge cases' => sub {
	my $start = '2026-09-19 09:00:00';
	my $t     = sub {
		my ( $time, %fields ) = @_;
		return { type => 'track', approximateTime => $time, artist => 'A', title => 'T', release => undef, %fields };
	};

	my $got = Plugins::RTRFM::Tracklist::normalise(
		[
			$t->( '2026-09-19 09:03:00', artist => 'Talk', type => 'talk' ),
			$t->( '2026-09-19 09:04:00', type => undef ),
			'not a hash',
			$t->( '2026-09-19 09:05:00', artist => 'Last', title => 'Before' ),
			{ artist => 'No type', title => 'X', approximateTime => '2026-09-19 09:06:00' },
		],
		$start
	);
	is_deeply( [ map { $_->{artist} } @$got ], ['Last'], 'non-track types, entries without a type and non-hashes are dropped' );

	$got = Plugins::RTRFM::Tracklist::normalise( [ $t->('2026-09-19 08:58:00') ], $start );
	is( $got->[0]->{offset}, 0, 'a time before the start (presenter error) is clamped to 0' );
	ok( !exists $got->[0]->{offsetUnknown}, 'a clamped offset is still known' );

	$got = Plugins::RTRFM::Tracklist::normalise( [ $t->('2026-09-19 11:30:00') ], $start );
	is( $got->[0]->{offset}, 9000, 'an offset past the end of a 2-hour episode is kept' );

	$got = Plugins::RTRFM::Tracklist::normalise( [ $t->( '2026-09-19 17:01:00', time => '05:01:00' ) ], '2026-09-19 17:00:00' );
	is( $got->[0]->{offset}, 60, 'time "05:01:00" is ignored, approximateTime used' );

	$got = Plugins::RTRFM::Tracklist::normalise(
		[
			$t->( undef,                 title => 'First, no time' ),
			$t->( '2026-09-19 09:10:00', title => 'Known' ),
			$t->( '05:15:00',            title => 'Unparseable' ),
			{ type => 'track', artist => 'A', title => 'Missing key' },
			$t->( '2026-09-19 09:20:00', title => 'Known again' ),
		],
		$start
	);
	is_deeply(
		[ map { [ $_->{title}, $_->{offset}, $_->{offsetUnknown} ] } @$got ],
		[
			[ 'First, no time', 0,    1 ],
			[ 'Known',          600,  undef ],
			[ 'Unparseable',    600,  1 ],
			[ 'Missing key',    600,  1 ],
			[ 'Known again',    1200, undef ],
		],
		'missing or unparseable approximateTime: previous offset (0 when first), flagged offsetUnknown'
	);
	is_deeply(
		rows($got),
		[
			"A $ENDASH First, no time",
			"10:00 $MIDDOT A $ENDASH Known",
			"A $ENDASH Unparseable",
			"A $ENDASH Missing key",
			"20:00 $MIDDOT A $ENDASH Known again",
		],
		'offsetUnknown rows have no offset'
	);

	$got = Plugins::RTRFM::Tracklist::normalise(
		[
			$t->( '2026-09-19 09:01:00', artist => '  Simon &amp; Garfunkel ', title => "Rock &#8217;n&#8217; Roll\n", release => '  ' ),
			$t->( '2026-09-19 09:02:00', artist => '', title => 'Only a title', release => '' ),
			$t->( '2026-09-19 09:03:00', artist => undef, title => '  ', release => 'Nothing else' ),
			$t->( '2026-09-19 09:04:00', artist => 'Only an artist', title => undef ),
			$t->( '2026-09-19 09:05:00', artist => { odd => 1 }, title => 'Artist not a string' ),
		],
		$start
	);
	is_deeply(
		[ map { [ $_->{artist}, $_->{title}, $_->{release} ] } @$got ],
		[
			[ 'Simon & Garfunkel', "Rock \x{2019}n\x{2019} Roll", undef ],
			[ undef,               'Only a title',                undef ],
			[ 'Only an artist',    undef,                         undef ],
			[ undef,               'Artist not a string',         undef ],
		],
		'text is entity-decoded and trimmed; empty values become undef; no artist and no title -> dropped'
	);
	is_deeply(
		rows($got),
		[
			"1:00 $MIDDOT Simon & Garfunkel $ENDASH Rock \x{2019}n\x{2019} Roll",
			"2:00 $MIDDOT Only a title",
			"4:00 $MIDDOT Only an artist",
			"5:00 $MIDDOT Artist not a string",
		],
		'rows: a missing artist gives "m:ss · Title"'
	);

	$got = Plugins::RTRFM::Tracklist::normalise(
		[
			$t->( '2026-09-19 09:10:00', title => 'Third' ),
			$t->( '2026-09-19 09:05:00', title => 'First' ),
			$t->( '2026-09-19 09:05:00', title => 'Second' ),
			$t->( '2026-09-19 09:10:00', title => 'Third' ),
			$t->( '2026-09-19 09:10:00', title => 'Fourth' ),
		],
		$start
	);
	is_deeply( [ map { $_->{title} } @$got ], [qw(First Second Third Third Fourth)], 'stable sort: duplicates and equal offsets keep their list order' );

	$got = Plugins::RTRFM::Tracklist::normalise(
		[
			$t->( '2026-09-19 09:01:00', contentDescriptors => { isLocal => JSON::PP::true() } ),
			$t->( '2026-09-19 09:02:00', contentDescriptors => { isLocal => JSON::PP::false() } ),
			$t->( '2026-09-19 09:03:00', contentDescriptors => undef ),
		],
		$start
	);
	is_deeply( [ map { $_->{isLocal} } @$got ], [ 1, 0, 0 ], 'isLocal from contentDescriptors.isLocal (missing -> 0)' );

	is_deeply( Plugins::RTRFM::Tracklist::normalise( [], $start ), [], 'empty list' );
	is_deeply( Plugins::RTRFM::Tracklist::normalise( undef, $start ), [], 'undef -> empty list' );
};

subtest 'formatOffset' => sub {
	my %cases = (
		0     => '0:00',
		59    => '0:59',
		180   => '3:00',
		1380  => '23:00',
		3599  => '59:59',
		3600  => '1:00:00',
		3758  => '1:02:38',
		6900  => '1:55:00',
		36061 => '10:01:01',
	);
	is( Plugins::RTRFM::Tracklist::formatOffset($_), $cases{$_}, "$_ s -> $cases{$_}" ) for sort { $a <=> $b } keys %cases;
	is( Plugins::RTRFM::Tracklist::formatOffset(-5),    '0:00', 'negative -> 0:00' );
	is( Plugins::RTRFM::Tracklist::formatOffset(undef), '0:00', 'undef -> 0:00' );
};

subtest 'formatRow' => sub {
	my %full = ( offset => 180, artist => 'Chris Foster', title => 'Looking Sideways', release => 'In Motion', isLocal => 1 );

	is( Plugins::RTRFM::Tracklist::formatRow( {%full} ), "3:00 $MIDDOT Chris Foster $ENDASH Looking Sideways (In Motion)", 'offset · Artist – Title (Release)' );
	is( Plugins::RTRFM::Tracklist::formatRow( { %full, release => undef } ), "3:00 $MIDDOT Chris Foster $ENDASH Looking Sideways", 'no release: no parentheses' );
	is( Plugins::RTRFM::Tracklist::formatRow( { %full, artist => undef } ), "3:00 $MIDDOT Looking Sideways (In Motion)", 'no artist: no "Artist – "' );
	is( Plugins::RTRFM::Tracklist::formatRow( { %full, offsetUnknown => 1 } ), "Chris Foster $ENDASH Looking Sideways (In Motion)", 'offsetUnknown: no "offset · "' );
	is( Plugins::RTRFM::Tracklist::formatRow( { %full, offset => 3758, artist => undef, release => undef } ), "1:02:38 $MIDDOT Looking Sideways", 'h:mm:ss, title only' );
	is( Plugins::RTRFM::Tracklist::formatRow( { %full, title => undef, release => undef } ), "3:00 $MIDDOT Chris Foster", 'artist only' );
};

subtest 'errors: 400/404/[] give [], other failures give an error' => sub {
	my $start = '2026-09-19 10:00:00';
	my $url   = playlistUrl( 'saturdayjazz', $start );

	for my $case (
		[ 'HTTP 400 {"message":"No such episode"}', { code => 400, file => 'ondemand/playlist-400.json', headers => { 'Content-Type' => 'application/json' } } ],
		[ 'HTTP 404',                               { code => 404, content => 'Not Found' } ],
		[ 'empty list []',                          { file => 'ondemand/playlist-empty.json' } ],
	) {
		my ( $name, $response ) = @$case;
		reset_all();
		route( $url, %$response );

		my $c = fetchTracks( 'saturdayjazz', $start );
		is( $c->count, 1, "$name: exactly one callback" );
		is_deeply( [ $c->args(0) ], [ [] ], "$name: \$cb->([])" );
	}

	for my $case (
		[ 'HTTP 500',              { code => 500, content => '' } ],
		[ 'HTTP 503',              { code => 503, content => '<html>down</html>' } ],
		[ 'bad JSON',              { code => 200, content => '<html>oops</html>' } ],
		[ 'not a list',            { code => 200, content => '{"message":"odd"}' } ],
		[ 'timeout',               { error => 'Timed out waiting for data' } ],
	) {
		my ( $name, $response ) = @$case;
		reset_all();
		route( $url, %$response );

		my $c = fetchTracks( 'saturdayjazz', $start );
		is( $c->count, 1, "$name: exactly one callback" );
		my ( $tracks, $error ) = $c->args(0);
		is( $tracks, undef, "$name: no tracks" );
		ok( defined $error && length $error, "$name: error message" ) and note $error;
	}

	for my $case (
		[ 'invalid slug',  'Saturday Jazz', '2026-09-19 09:00:00' ],
		[ 'undef slug',    undef,           '2026-09-19 09:00:00' ],
		[ 'invalid start', 'saturdayjazz',  '2026-09-19' ],
		[ 'bad date',      'saturdayjazz',  '2026-02-30 09:00:00' ],
		[ 'undef start',   'saturdayjazz',  undef ],
	) {
		my ( $name, $slug, $bad ) = @$case;
		reset_all();

		my $c = fetchTracks( $slug, $bad );
		is( $c->count, 1, "$name: exactly one callback" );
		my ( $tracks, $error ) = $c->args(0);
		ok( !defined $tracks && defined $error, "$name: error" );
		is( requestCount(), 0, "$name: no request" );
	}

	clearTime();
};

subtest 'cache TTLs under the fake clock' => sub {
	# resetStubs() drops the cache instances, so look the namespace up each time
	my $cached = sub { Slim::Utils::Cache->new('rtrfm')->get(shift) };

	# Saturday Jazz 2026-09-19 started 7 days before $NOW: 24 hours
	reset_all();
	fetched('saturdayjazz');
	is( requestCount(), 1, 'old episode: one request' );
	is( scalar @{ $cached->('tracklist:saturdayjazz:2026-09-19 09:00:00') || [] }, 20, 'cached in the rtrfm namespace under tracklist:<slug>:<start>' );
	advanceTime( 24 * $HOUR - 60 );
	is( scalar @{ fetched('saturdayjazz') }, 20, 'old episode, 23:59 later: tracks from the cache' );
	is( requestCount(), 1, 'old episode, 23:59 later: no new request' );
	advanceTime(120);
	fetched('saturdayjazz');
	is( requestCount(), 2, 'old episode, 24:01 later: fetched again' );

	# Drivetime 2026-09-25 17:00 started 18h40m before $NOW: 1 hour
	reset_all();
	fetched('drivetime');
	advanceTime( $HOUR - 60 );
	fetched('drivetime');
	is( requestCount(), 1, 'episode from the last 2 days, 59 min later: no new request' );
	advanceTime(120);
	fetched('drivetime');
	is( requestCount(), 2, 'episode from the last 2 days, 61 min later: fetched again' );

	# the 2-day boundary, measured from the episode start
	my $sjStart = Plugins::RTRFM::Util::parsePerthDateTime('2026-09-19 09:00:00');
	for my $case ( [ '47 h', 47 * $HOUR, 1 ], [ '49 h', 49 * $HOUR, 0 ] ) {
		my ( $age, $offset, $short ) = @$case;
		resetStubs();
		routeFixtures();
		setTime( $sjStart + $offset );
		fetched('saturdayjazz');
		advanceTime( 2 * $HOUR );
		fetched('saturdayjazz');
		is( requestCount(), $short ? 2 : 1, "fetched $age after the start: " . ( $short ? '1 hour' : '24 hours' ) );
	}

	# empty list and 400: 1 hour, even for an old episode
	for my $case ( [ 'empty list', { file => 'ondemand/playlist-empty.json' } ], [ 'HTTP 400', { code => 400, file => 'ondemand/playlist-400.json' } ] ) {
		my ( $name, $response ) = @$case;
		resetStubs();
		setTime($NOW);
		route( playlistUrl( 'saturdayjazz', '2026-09-12 09:00:00' ), %$response );
		fetchTracks( 'saturdayjazz', '2026-09-12 09:00:00' );
		advanceTime( $HOUR - 60 );
		my $c = fetchTracks( 'saturdayjazz', '2026-09-12 09:00:00' );
		is_deeply( [ $c->args(0) ], [ [] ], "$name, 59 min later: [] from the cache" );
		is( requestCount(), 1, "$name, 59 min later: no new request" );
		advanceTime(120);
		fetchTracks( 'saturdayjazz', '2026-09-12 09:00:00' );
		is( requestCount(), 2, "$name, 61 min later: fetched again" );
	}

	# failures are never cached
	for my $case ( [ 'HTTP 500', { code => 500 } ], [ 'bad JSON', { content => 'nope' } ], [ 'timeout', { error => 'Timed out waiting for data' } ] ) {
		my ( $name, $response ) = @$case;
		resetStubs();
		setTime($NOW);
		route( playlistUrl( 'saturdayjazz', '2026-09-19 09:00:00' ), %$response );
		fetchTracks( 'saturdayjazz', '2026-09-19 09:00:00' );
		is( $cached->('tracklist:saturdayjazz:2026-09-19 09:00:00'), undef, "$name: nothing cached" );
		Slim::Networking::SimpleAsyncHTTP->reset;
		routeFixtures();
		is( scalar @{ fetched('saturdayjazz') }, 20, "$name: the next fetch requests again and succeeds" );
		is( requestCount(), 1, "$name: one new request" );
	}

	clearTime();
};

done_testing();
