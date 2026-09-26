#!/usr/bin/perl
# Plugins::RTRFM::Airnet: program list filtering and normalisation, episode normalisation (Perth
# dates, hhmm, durations, titles, plain-text descriptions), one episode per Perth date, the pure
# 28-day window (edges at Perth midnight, any server time zone), HTML to text, caching and error
# callbacks.
#
# Fixtures in t/data/ondemand/ were recorded from the live Airnet endpoints on 2026-09-26 (about
# 04:25 UTC) with an LMS User-Agent. programs.json and episodes-{saturdayjazz,drivetime,uplate}.json
# are the complete responses; episodes-{allcity,herstory}.json keep a few of the recorded entries.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use POSIX ();
use Time::Local qw(timegm);

use Plugins::RTRFM::Airnet;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $BASE     = Plugins::RTRFM::Util::AIRNET_BASE;
my $PROGRAMS = "$BASE/programs";

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $NOW = timegm( 0, 40, 3, 26, 8, 2026 );

# 2026-09-25 15:59:59 UTC = 23:59:59 on the 25th in Perth; one second later it is the 26th.
my $BEFORE_MIDNIGHT = timegm( 59, 59, 15, 25, 8, 2026 );
my $MIDNIGHT        = $BEFORE_MIDNIGHT + 1;

sub episodesUrl { "$BASE/programs/$_[0]/episodes" }

sub routeEpisodes {
	my ( $slug, %response ) = @_;
	route( episodesUrl($slug), %response );
}

sub routeAll {
	route( $PROGRAMS, file => 'ondemand/programs.json', headers => { 'Content-Type' => 'application/json;charset=utf-8' } );
	routeEpisodes( $_, file => "ondemand/episodes-$_.json" ) for qw(saturdayjazz drivetime uplate allcity herstory);
}

# Call Airnet::programs / Airnet::episodes; return the collector.
sub getPrograms {
	my $c = collector();
	Plugins::RTRFM::Airnet::programs( $c->cb );
	return $c;
}

sub getEpisodes {
	my $slug = shift;
	my $c    = collector();
	Plugins::RTRFM::Airnet::episodes( $slug, $c->cb );
	return $c;
}

sub requestCount { scalar( () = requests() ) }

sub dates { [ map { $_->{date} } @{ $_[0] } ] }

# The episode list for $slug from the fixture routes (asserts one successful callback).
sub episodesFor {
	my $slug = shift;
	my $c    = getEpisodes($slug);
	is( $c->count, 1, "$slug: one callback" );
	my ( $eps, $error ) = $c->args(0);
	ok( ref $eps eq 'ARRAY', "$slug: got an episode list" ) or diag $error;
	return $eps || [];
}

my @EXPECTED_SLUGS = qw(
	allcity allthingsqueer ambientzone artbeat australianmelodrama basscheck behindthemirror blackandblue
	breakfast burntheairwaves cloudwaves criticalmass difficultlistening drastic drivetime elritmo
	fullcircle fullfrequency giantsteps globalrhythmpot goldenapples getupmorning herstory homegrown
	indymedia jamdown looneychoons middleofnowhere midnightspecial moorditjmag nostalgia ontherecord
	thursday otl peer2peer pluckedstrings posted revolver rhythmtrippin rockrattle roots saturdayjazz
	siamesedream snoozebutton soulsides spoonful subterranea sundaymorning talkthetalk therounds
	theswing trainwreck undergroundsolution understorey uplate woodstock youshouldbesleeping
);

subtest 'programs: the recorded 86 entries reduce to 57, normalised and sorted' => sub {
	resetStubs();
	routeAll();

	my $c = getPrograms();
	is( $c->count, 1, 'one callback' );
	my ( $programs, $error ) = $c->args(0);
	is( $error, undef, 'no error' );
	is( ref $programs, 'ARRAY', 'an array of programs' ) or return;

	is( scalar @$programs, 57, '57 programs' );
	is_deeply( [ map { $_->{slug} } @$programs ], \@EXPECTED_SLUGS, 'exactly the expected slugs, sorted by name' );
	is_deeply( [ map { lc $_->{name} } @$programs ], [ sort map { lc $_->{name} } @$programs ], 'sorted case-insensitively by name' );
	is_deeply( [ grep { join( ',', sort keys %$_ ) ne 'name,slug' } @$programs ], [], 'every program is exactly {slug, name}' );
	is_deeply( [ grep { $_->{slug} !~ /\A[a-z0-9_-]+\z/ } @$programs ], [], 'every slug matches [a-z0-9_-]+' );

	my %byslug = map { $_->{slug} => $_->{name} } @$programs;
	is( $byslug{blackandblue},    'Black & Blue',    'HTML entities decoded (Black &amp; Blue)' );
	is( $byslug{basscheck},       'Bass Check',      'trailing space trimmed (Bass Check )' );
	is( $byslug{fullcircle},      'Full Circle',     'trailing spaces trimmed (Full Circle  )' );
	is( $byslug{getupmorning},    'GRP',             'GRP trimmed' );
	is( $byslug{drastic},         'Drastic on Plastic', 'Drastic on Plastic trimmed' );
	is( $byslug{saturdayjazz},    'Saturday Jazz',   'Saturday Jazz kept' );
	is( $byslug{drivetime},       'Drivetime',       'Drivetime kept' );
	is( $byslug{ontherecord},     'On The Record',   'ontherecord kept' );
	is( $byslug{thursday},        'On The Record',   'thursday kept too (same display name, different slug)' );

	ok( !exists $byslug{training},               'training (Demo Playlists) dropped' );
	ok( !exists $byslug{'artifical-intelligence'}, 'artifical-intelligence ("Your Program") dropped' );
	ok( !exists $byslug{$_}, "archived $_ dropped" ) for qw(artificialintelligence bordak bpm youngblood goodtimes);
	ok( !( grep { $_->{name} =~ /^(?:Add Show Name Here|Your Program|Test page|Demo Playlists)$/i } @$programs ), 'no junk names' );

	my @requests = requests();
	is( scalar @requests, 1, 'one HTTP request' );
	is( $requests[0]->{url}, $PROGRAMS, 'GET <Airnet base>/programs' );
	unlike( $requests[0]->{headers}->header('User-Agent'), qr/libwww/i, 'through HTTP.pm (non-libwww User-Agent)' );
};

subtest 'programs: filter rules on synthetic entries (slug, archived, junk, dedupe)' => sub {
	resetStubs();
	route( $PROGRAMS, content => <<'JSON' );
[
 {"slug":"zulu","name":"  Zulu   Time  ","broadcasters":"Z","archived":false},
 {"slug":"alpha","name":"alpha","broadcasters":"A","archived":false},
 {"slug":"alpha","name":"Alpha Duplicate","broadcasters":"A","archived":false},
 {"slug":"Bad-Case","name":"Upper case slug","broadcasters":"","archived":false},
 {"slug":"drivetime/monday","name":"Full slug","broadcasters":"","archived":false},
 {"slug":"with space","name":"Space","broadcasters":"","archived":false},
 {"slug":null,"name":"Null slug","broadcasters":"","archived":false},
 {"slug":"","name":"Empty slug","broadcasters":"","archived":false},
 {"slug":"old","name":"Old Show","broadcasters":"","archived":true},
 {"slug":"training","name":"Demo Playlists ","broadcasters":"","archived":false},
 {"slug":"blank","name":"   ","broadcasters":"","archived":false},
 {"slug":"addname","name":"ADD SHOW NAME HERE","broadcasters":"","archived":false},
 {"slug":"testpage","name":" Test Page ","broadcasters":"","archived":false},
 {"slug":"yourbroadcaster","name":"Real Name","broadcasters":"Your Broadcaster ","archived":false},
 {"slug":"addpresenter","name":"Another Name","broadcasters":"add presenter name here","archived":false},
 {"slug":"mid_dle-9","name":"Caf&eacute; &#8211; Middle","broadcasters":"","archived":false},
 "not a hash"
]
JSON

	my ($programs) = getPrograms()->args(0);
	is_deeply(
		$programs,
		[
			{ slug => 'alpha',     name => 'alpha' },
			{ slug => 'mid_dle-9', name => "Café \x{2013} Middle" },
			{ slug => 'zulu',      name => 'Zulu Time' },
		],
		'invalid slugs, archived, junk and non-hash entries dropped; first entry per slug kept; names trimmed, collapsed and decoded; case-insensitive sort'
	);
};

subtest 'programs: cached for 6 hours; failures are not cached' => sub {
	resetStubs();
	setTime($NOW);
	routeAll();

	getPrograms();
	is( requestCount(), 1, 'first call fetches' );

	my $c = getPrograms();
	is( $c->count, 1, 'cached call: one callback' );
	is( scalar @{ ( $c->args(0) )[0] }, 57, 'cached call: same list' );
	is( requestCount(), 1, 'cached call: no HTTP request' );

	my $cached = Slim::Utils::Cache->new('rtrfm')->get('airnet:programs');
	is( ref $cached, 'ARRAY', 'stored under rtrfm / airnet:programs' );

	advanceTime( 6 * 3600 - 1 );
	getPrograms();
	is( requestCount(), 1, 'still cached just before 6 h' );

	advanceTime(2);
	getPrograms();
	is( requestCount(), 2, 'fetched again after 6 h' );

	resetStubs();
	route( $PROGRAMS, code => 500, content => '' );
	$c = getPrograms();
	is( $c->count, 1, 'HTTP 500: one callback' );
	my ( $programs, $error ) = $c->args(0);
	is( $programs, undef, 'HTTP 500: no list' );
	like( $error, qr/500/, 'HTTP 500: error message' );

	Slim::Networking::SimpleAsyncHTTP->reset;
	routeAll();
	( $programs, $error ) = getPrograms()->args(0);
	is( requestCount(), 1, 'after a failure the next call fetches again (failure not cached)' );
	is( scalar @$programs, 57, 'and succeeds' );

	clearTime();
};

subtest 'programs: error callbacks' => sub {
	for my $case (
		[ 'HTTP 500',        { code => 500, content => 'oops' },                   qr/500/ ],
		[ 'HTTP 403',        { code => 403, content => '<html>blocked</html>' },   qr/403/ ],
		[ 'bad JSON',        { code => 200, content => '<html>not json</html>' },  qr/JSON/ ],
		[ 'timeout',         { error => 'Timed out waiting for data' },            qr/Timed out/ ],
		[ 'object, not list', { code => 200, content => '{"message":"nope"}' },    qr/unexpected/i ],
	) {
		my ( $name, $response, $expected ) = @$case;
		resetStubs();
		route( $PROGRAMS, %$response );

		my $c = getPrograms();
		is( $c->count, 1, "$name: exactly one callback" );
		my ( $programs, $error ) = $c->args(0);
		is( $programs, undef, "$name: no list" );
		like( $error, $expected, "$name: error message" );
		is( Slim::Utils::Cache->new('rtrfm')->get('airnet:programs'), undef, "$name: nothing cached" );
	}
};

subtest 'episodes: normalisation (Saturday Jazz)' => sub {
	resetStubs();
	routeAll();

	my $eps = episodesFor('saturdayjazz');
	is( ( requests() )[0]->{url}, episodesUrl('saturdayjazz'), 'GET <base>/programs/saturdayjazz/episodes' );

	is( scalar @$eps, 11, 'all 11 episodes returned (unfiltered)' );
	is_deeply(
		dates($eps),
		[qw(2026-09-19 2026-09-12 2026-09-05 2026-08-29 2026-08-22 2026-08-15 2026-08-08 2026-08-01 2026-07-25 2026-07-18 2026-07-11)],
		'newest first (Airnet sends oldest first)'
	);

	is_deeply(
		$eps->[0],
		{
			slug        => 'saturdayjazz',
			date        => '2026-09-19',
			hhmm        => '0900',
			start       => '2026-09-19 09:00:00',
			end         => '2026-09-19 11:00:00',
			duration    => 7200,
			title       => 'Saturday Jazz with Laura Igglesden',
			description => undef,
		},
		'2026-09-19: title kept, null description is undef'
	);

	is_deeply(
		$eps->[1],
		{
			slug        => 'saturdayjazz',
			date        => '2026-09-12',
			hhmm        => '0900',
			start       => '2026-09-12 09:00:00',
			end         => '2026-09-12 11:00:00',
			duration    => 7200,
			title       => undef,
			description => 'Presented by Ben Bartholomew. Featuring tracks from the debut album by local ensemble the Kirsten Sym Undectet.',
		},
		'2026-09-12: null title is undef, description is plain text'
	) or diag explain $eps->[1];

	my ($aug15) = grep { $_->{date} eq '2026-08-15' } @$eps;
	is( $aug15->{title}, 'Saturday Jazz', 'a title equal to the show name is kept' );

	is_deeply( [ grep { join( ',', sort keys %$_ ) ne 'date,description,duration,end,hhmm,slug,start,title' } @$eps ], [], 'every episode has exactly the documented keys' );
	is_deeply( [ grep { defined $_->{description} && $_->{description} =~ /[<>]|&amp;/ } @$eps ], [], 'no HTML left in any description' );
};

subtest 'episodes: Drivetime, Up Late (after midnight), All City (Friday 23:00), UTF-8' => sub {
	resetStubs();
	routeAll();

	my $drive = episodesFor('drivetime');
	is( scalar @$drive, 11, 'Drivetime: 11 episodes' );
	is( $drive->[0]->{date}, '2026-09-25', 'Drivetime: newest is Friday 25th' );
	is( $drive->[0]->{hhmm}, '1700', 'Drivetime: hhmm 1700' );
	is_deeply( [ grep { $_->{hhmm} ne '1700' } @$drive ], [], 'Drivetime: all at 17:00' );

	my ($sep16) = grep { $_->{date} eq '2026-09-16' } @$drive;
	is(
		$sep16->{description},
		"Em & Tim adventure into shoegaze and post-punk on their\n\nD R E A M D R I V E special\n\nJoin us for shimmering, reverbed splendour",
		'paragraphs become blank-line separated, &amp; decoded, spaces trimmed'
	);

	my $up = episodesFor('uplate');
	is( $up->[0]->{date},  '2026-09-25',          'Up Late 2026-09-25 01:00 is dated the 25th (Perth start date)' );
	is( $up->[0]->{hhmm},  '0100',                'Up Late hhmm 0100' );
	is( $up->[0]->{start}, '2026-09-25 01:00:00', 'Up Late start' );
	is( $up->[0]->{end},   '2026-09-25 04:00:00', 'Up Late end' );
	is( $up->[0]->{duration}, 10800, 'Up Late duration 3 h' );

	my $city = episodesFor('allcity');
	is( $city->[0]->{date}, '2026-09-25', 'All City Fri 23:00-01:00 is dated Friday the 25th' );
	is( $city->[0]->{hhmm}, '2300',       'All City hhmm 2300' );
	is( $city->[0]->{end},  '2026-09-26 01:00:00', 'All City ends on the 26th' );
	is( $city->[0]->{title}, 'All City with DJ Dusty D', 'All City title' );

	my ($sep04) = grep { $_->{date} eq '2026-09-04' } @$city;
	like( $sep04->{description}, qr/across Perth\x{2019}s hip-hop scene/, 'UTF-8 (right single quote) survives as a character' );
	like( $sep04->{description}, qr/^J\.O\.E\. is joined in the studio/, 'inline <span style> wrappers stripped' );
	like( $sep04->{description}, qr/local music community\.\n\nIn the second hour, J\.O\.E\. takes over/, '<div> blocks become paragraphs; empty &nbsp; blocks dropped' );

	my ($sep18) = grep { $_->{date} eq '2026-09-18' } @$city;
	is(
		$sep18->{description},
		"with Dave Clark\n\nTonight's show is a slow ramp up from chilled beats with nice jazzy vibes, to tunes of some intensity\n\nShout outs to Jippy & MALi JO\$E for that local heat",
		'links reduced to their text'
	);

	my ($jul24) = grep { $_->{date} eq '2026-07-24' } @$city;
	is(
		$jul24->{description},
		"Connor and Emma FINALLY REUINITE!\n\nGenuinelly....\n\nNew raps, classics, you know, the standard.",
		'<br> become line breaks, source newlines are whitespace, empty paragraphs dropped'
	);
};

subtest 'episodes: edge cases (synthetic entries)' => sub {
	resetStubs();
	local $Slim::Utils::Log::CATEGORIES{'plugin.rtrfm'} = { defaultLevel => 'INFO', description => 'PLUGIN_RTRFM' };
	routeEpisodes( 'edge', content => <<'JSON' );
[
 {"start":"2026-09-20 10:00:00","end":"2026-09-20 11:30:00","duration":null,"title":"  Padded  Title ","description":"plain text\nsecond line"},
 {"start":"2026-09-21 10:00:00","end":null,"duration":null,"title":"","description":""},
 {"start":"2026-09-22 10:00:00","end":"2026-09-22 12:00:00","title":"   ","description":"<p>&nbsp;</p>\n\n<p> </p>"},
 {"start":"2026-09-23 18:00:00","end":"2026-09-23 19:00:00","duration":3600,"multipleEpsOnDay":true,"title":"Second on the day","description":null},
 {"start":"2026-09-23 06:00:00","end":"2026-09-23 07:00:00","duration":3600,"multipleEpsOnDay":true,"title":"First on the day","description":null},
 {"start":"not a date","end":"2026-09-24 12:00:00","duration":3600,"title":"No start","description":null},
 {"start":null,"duration":3600,"title":"Null start","description":null},
 {"start":"2026-09-19 22:00:00","end":"2026-09-19 23:00:00","duration":"3600","title":"Tom &amp; Jerry","description":"<p>A &lt;b&gt; tag</p>"},
 42
]
JSON

	my $eps = episodesFor('edge');
	is_deeply( dates($eps), [qw(2026-09-23 2026-09-22 2026-09-21 2026-09-20 2026-09-19)], 'unparseable starts skipped; one per date; newest first' );

	my %e = map { $_->{date} => $_ } @$eps;
	is( $e{'2026-09-20'}->{duration}, 5400, 'no duration: end - start' );
	is( $e{'2026-09-20'}->{title}, 'Padded Title', 'title trimmed and whitespace collapsed' );
	is( $e{'2026-09-20'}->{description}, "plain text\nsecond line", 'plain-text description keeps its line break' );
	ok( exists $e{'2026-09-21'}->{duration} && !defined $e{'2026-09-21'}->{duration}, 'no duration and no end: duration undef' );
	is( $e{'2026-09-21'}->{end}, undef, 'no end: end undef' );
	is( $e{'2026-09-21'}->{title}, undef, 'empty title: undef' );
	is( $e{'2026-09-21'}->{description}, undef, 'empty description: undef' );
	is( $e{'2026-09-22'}->{title}, undef, 'whitespace title: undef' );
	is( $e{'2026-09-22'}->{description}, undef, 'description with only empty paragraphs: undef' );
	is( $e{'2026-09-22'}->{duration}, 7200, 'missing duration key: end - start' );
	is( $e{'2026-09-23'}->{title}, 'First on the day', 'two episodes on one Perth date: the earliest start is kept' );
	is( $e{'2026-09-23'}->{hhmm}, '0600', 'kept episode is the 06:00 one' );
	is( $e{'2026-09-19'}->{duration}, 3600, 'numeric-string duration accepted' );
	is( $e{'2026-09-19'}->{title}, 'Tom & Jerry', 'entities in titles decoded' );
	is( $e{'2026-09-19'}->{description}, 'A <b> tag', 'escaped markup in a description stays as text' );

	ok(
		( grep { $_->{level} eq 'INFO' && $_->{message} =~ /edge.*2026-09-23 18:00:00/ } Slim::Utils::Log->messages ),
		'the dropped same-date episode is logged at info level'
	);
};

subtest 'episodes: cached for 30 minutes, unfiltered; failures not cached' => sub {
	resetStubs();
	setTime($NOW);
	routeAll();

	episodesFor('saturdayjazz');
	is( requestCount(), 1, 'first call fetches' );

	my $cached = Slim::Utils::Cache->new('rtrfm')->get('airnet:episodes:saturdayjazz');
	is( ref $cached, 'ARRAY', 'stored under rtrfm / airnet:episodes:saturdayjazz' );
	is( scalar @$cached, 11, 'the cache holds the unfiltered list (11, not the 4 in the window)' );

	my $eps = episodesFor('saturdayjazz');
	is( scalar @$eps, 11, 'cached call: 11 episodes' );
	is( requestCount(), 1, 'cached call: no HTTP request' );

	advanceTime( 30 * 60 - 1 );
	episodesFor('saturdayjazz');
	is( requestCount(), 1, 'still cached just before 30 min' );
	advanceTime(2);
	episodesFor('saturdayjazz');
	is( requestCount(), 2, 'fetched again after 30 min' );

	episodesFor('drivetime');
	is( requestCount(), 3, 'each slug has its own cache entry' );

	resetStubs();
	routeEpisodes( 'understorey', content => '[]' );
	$eps = episodesFor('understorey');
	is_deeply( $eps, [], 'an empty list ([]) is a successful, empty result' );
	episodesFor('understorey');
	is( requestCount(), 1, 'the empty list is cached too' );

	clearTime();
};

subtest 'episodes: errors' => sub {
	for my $case (
		[ 'unknown slug (HTTP 500)', { code => 500, content => '' },                   qr/500/ ],
		[ 'bad JSON',                { code => 200, content => 'Internal error' },     qr/JSON/ ],
		[ 'transport error',         { error => 'Connect timed out' },                 qr/Connect timed out/ ],
		[ 'object, not list',        { code => 200, content => '{"message":"x"}' },    qr/unexpected/i ],
	) {
		my ( $name, $response, $expected ) = @$case;
		resetStubs();
		routeEpisodes( 'nosuch', %$response );

		my $c = getEpisodes('nosuch');
		is( $c->count, 1, "$name: exactly one callback" );
		my ( $eps, $error ) = $c->args(0);
		is( $eps, undef, "$name: no list" );
		like( $error, $expected, "$name: error message" );
		is( Slim::Utils::Cache->new('rtrfm')->get('airnet:episodes:nosuch'), undef, "$name: nothing cached" );
	}

	resetStubs();
	routeEpisodes( 'nosuch', code => 500 );
	getEpisodes('nosuch');
	Slim::Networking::SimpleAsyncHTTP->reset;
	routeEpisodes( 'nosuch', content => '[]' );
	my ($eps) = getEpisodes('nosuch')->args(0);
	is( requestCount(), 1, 'after a failure the next call fetches again' );
	is_deeply( $eps, [], 'and succeeds' );

	for my $bad ( undef, '', 'Bad-Slug', 'drivetime/monday', "x\n" ) {
		resetStubs();
		my $c = getEpisodes($bad);
		is( $c->count, 1, 'invalid slug ' . ( defined $bad ? "'$bad'" : 'undef' ) . ': one callback' );
		my ( $list, $error ) = $c->args(0);
		ok( !defined $list && defined $error, 'invalid slug: error' );
		is( requestCount(), 0, 'invalid slug: no HTTP request' );
	}
};

subtest 'filterWindow: [Perth today - 28 days, Perth today) at 2026-09-26 11:40 Perth' => sub {
	resetStubs();
	routeAll();
	my $jazz  = episodesFor('saturdayjazz');
	my $drive = episodesFor('drivetime');

	my $window = Plugins::RTRFM::Airnet::filterWindow( $jazz, $NOW );
	is_deeply( dates($window), [qw(2026-09-19 2026-09-12 2026-09-05 2026-08-29)], 'Saturday Jazz: 4 episodes, 08-22 excluded, newest first' );
	is( $window->[0], $jazz->[0], 'the episode hashes themselves are returned' );
	is( scalar @$jazz, 11, 'the input list is not modified' );

	is( scalar @{ Plugins::RTRFM::Airnet::filterWindow( $drive, $NOW ) }, 11, 'Drivetime: 11 episodes' );

	setTime($NOW);
	is_deeply( Plugins::RTRFM::Airnet::filterWindow($jazz), $window, '$now defaults to time()' );
	clearTime();

	my @synthetic = map { { date => $_ } } qw(2026-09-26 2026-09-25 2026-08-29 2026-08-28);
	is_deeply( dates( Plugins::RTRFM::Airnet::filterWindow( \@synthetic, $NOW ) ), [qw(2026-09-25 2026-08-29)], 'today excluded, today-1 and today-28 included, today-29 excluded' );
	is_deeply( Plugins::RTRFM::Airnet::filterWindow( [], $NOW ), [], 'empty list: empty window' );
};

subtest 'filterWindow: Perth midnight is 16:00 UTC' => sub {
	resetStubs();
	routeAll();
	my $drive = episodesFor('drivetime');

	my $before = Plugins::RTRFM::Airnet::filterWindow( $drive, $BEFORE_MIDNIGHT );
	is( scalar @$before, 10, 'at 15:59:59 UTC (Perth 23:59:59 on the 25th): 10, because 09-25 is "today"' );
	ok( !( grep { $_->{date} eq '2026-09-25' } @$before ), '09-25 not listed' );

	my $after = Plugins::RTRFM::Airnet::filterWindow( $drive, $MIDNIGHT );
	is( scalar @$after, 11, 'at 16:00:00 UTC (Perth midnight): 11' );
	is( $after->[0]->{date}, '2026-09-25', '09-25 listed first' );
};

subtest 'server time zone does not matter' => sub {
	my %results;

	for my $tz ( 'UTC', 'America/New_York', 'Australia/Perth' ) {
		local $ENV{TZ} = $tz;
		POSIX::tzset();

		resetStubs();
		routeAll();

		my %got;
		for my $slug (qw(saturdayjazz drivetime uplate allcity)) {
			my ($eps) = getEpisodes($slug)->args(0);
			$got{$slug} = {
				episodes => $eps,
				now      => Plugins::RTRFM::Airnet::filterWindow( $eps, $NOW ),
				before   => Plugins::RTRFM::Airnet::filterWindow( $eps, $BEFORE_MIDNIGHT ),
				after    => Plugins::RTRFM::Airnet::filterWindow( $eps, $MIDNIGHT ),
			};
		}
		$results{$tz} = \%got;
	}
	POSIX::tzset();

	is_deeply( $results{'America/New_York'}, $results{UTC}, 'TZ=America/New_York gives the same episodes and windows as TZ=UTC' );
	is_deeply( $results{'Australia/Perth'},  $results{UTC}, 'TZ=Australia/Perth gives the same results too' );
	is( scalar @{ $results{'America/New_York'}->{saturdayjazz}->{now} }, 4, 'sanity: 4 Saturday Jazz episodes under New York time' );
	is( $results{'America/New_York'}->{uplate}->{episodes}->[0]->{date}, '2026-09-25', 'sanity: Up Late dated the 25th under New York time' );
};

subtest 'htmlToText' => sub {
	my $t = \&Plugins::RTRFM::Airnet::htmlToText;

	is( $t->(undef), undef, 'undef' );
	is( $t->(''),    undef, 'empty string' );
	is( $t->("<p> </p>\n\n<p><br>\n&nbsp;</p>"), undef, 'only empty markup' );
	is( $t->("<p>Presented by Austin Salisbury</p>\n"), 'Presented by Austin Salisbury', 'single paragraph' );
	is( $t->("<p>One</p>\n\n<p>Two</p>"), "One\n\nTwo", 'paragraphs separated by a blank line' );
	is( $t->('line one<br>line two<br/>line three<BR />'), "line one\nline two\nline three", '<br> variants' );
	is( $t->('<p>Kaya Wandjoo.  First   Nations</p>'), 'Kaya Wandjoo. First Nations', 'runs of spaces collapsed' );
	is( $t->('<p>Fish &amp; Chips &#8211; &quot;hot&quot; &#x27;n&#x27; tasty&nbsp;now</p>'), "Fish & Chips \x{2013} \"hot\" 'n' tasty now", 'entities decoded' );
	is( $t->('<p>See <a href="https://example.test/?a=1&amp;b=2" target="_blank">this link</a>.</p>'), 'See this link.', 'links reduced to text' );
	is( $t->('<p><span style="font-size:14px"><strong>Bold</strong> text</span></p>'), 'Bold text', 'nested inline tags stripped' );
	is( $t->("<!-- comment --><p>After comment</p>"), 'After comment', 'comments removed' );
	is( $t->("Café\x{2019}s music"), "Café\x{2019}s music", 'non-ASCII characters kept' );
	is( $t->("  plain\n\n\n\ntext  "), "plain\n\ntext", 'plain text: trimmed, at most one blank line' );
};

done_testing();
