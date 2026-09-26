#!/usr/bin/perl
# Plugins::RTRFM::NowPlaying: parse (every fixture and the API edge cases), showLabel, the cache
# lifetime and its freshness boundary, one upstream request for concurrent fetches, the 20 s
# negative cache, requests through HTTP.pm, exactly one callback per fetch, and logging.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use JSON::PP ();
use POSIX ();

use Slim::Utils::Log;

use Plugins::RTRFM::NowPlaying;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

# plugin.rtrfm at DEBUG, so HTTP.pm logs its request line (as after ["debug","plugin.rtrfm","DEBUG"])
Slim::Utils::Log->addLogCategory( { category => 'plugin.rtrfm', defaultLevel => 'DEBUG', description => 'PLUGIN_RTRFM' } );

my $NP      = 'Plugins::RTRFM::NowPlaying';
my $URL     = 'https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show';
my $STREAM1 = 'https://live.rtrfm.com.au/stream1';
my $NOW     = 1_790_393_400;    # 2026-09-26 11:30 AWST
my $NEXT_START = 1_790_398_800; # 13:00 AWST, also current.end

my $CURRENT = {
	name        => 'Global Rhythm Pot',
	slug        => 'globalrhythmpot',
	start       => 1_790_391_600,
	end         => 1_790_398_800,
	timeText    => '11.00am - 1.00pm',
	image       => 'https://rtrfm.com.au/wp-content/uploads/2012/12/GlobalRhythmPot.jpg',
	description => 'A sonic journey around the world, offering stopovers in funk, beats and folk traditions.',
	link        => 'https://rtrfm.com.au/shows/globalrhythmpot/',
};

my $NEXT = {
	name        => 'Homegrown',
	slug        => 'homegrown',
	start       => 1_790_398_800,
	end         => 1_790_406_000,
	timeText    => '1.00pm - 3.00pm',
	image       => 'https://rtrfm.com.au/wp-content/uploads/2012/12/homegrown-1.jpg',
	description => 'Your local music love-in with live performances and interviews.',
	link        => 'https://rtrfm.com.au/shows/homegrown/',
};

# decoded top-level JSON value of t/data/live/<name> (the body-zero fixture decodes to 0)
sub decoded { JSON::PP->new->utf8->allow_nonref->decode( fixture("live/$_[0]") ) }

# parse the normal fixture after $edit->($data) changed it
sub variant {
	my ( $edit, $now ) = @_;
	my $decoded = decoded('now-next-normal.json');
	$edit->( $decoded->{data} );
	return $NP->parse( $decoded, defined $now ? $now : $NOW );
}

sub fresh_start {
	resetStubs();
	Plugins::RTRFM::NowPlaying::_reset();
	setTime( shift || $NOW );
}

sub serve { route( $URL, @_ ) }

sub own_messages {
	my $level = shift;
	return grep { $_->{message} =~ m{^Now/next show info} } Slim::Utils::Log->messages( level => $level, category => 'plugin.rtrfm' );
}

sub request_lines {
	return grep { $_->{message} =~ /get_current_and_next_show/ } Slim::Utils::Log->messages( level => 'DEBUG' );
}

# every recorded request: exactly the endpoint URL, GET, through HTTP.pm (non-libwww UA), uncached
sub requests_ok {
	my $name = shift;
	my @requests = requests();
	ok( scalar @requests, "$name: requests were made" );
	for my $req (@requests) {
		my $ua = $req->{headers}->header('User-Agent');
		ok( $req->{method} eq 'GET' && $req->{url} eq $URL, "$name: GET $URL" ) or diag "$req->{method} $req->{url}";
		ok( defined $ua && length $ua && $ua !~ /libwww/i, "$name: User-Agent set by HTTP.pm, not libwww" ) or diag $ua;
		ok( !$req->{params}->{cache}, "$name: SimpleAsyncHTTP cache not used" );
	}
}

# ---------------------------------------------------------------------------
# parse
# ---------------------------------------------------------------------------

subtest 'parse: the normal fixture' => sub {
	my $info = $NP->parse( decoded('now-next-normal.json'), $NOW );
	is_deeply(
		$info,
		{ current => $CURRENT, next => $NEXT, streamUrl => $STREAM1, fetched => $NOW, expires => $NOW + 900 },
		'exactly the expected $info'
	);

	is_deeply( Plugins::RTRFM::NowPlaying::parse( decoded('now-next-normal.json'), $NOW ), $info, 'same result when called as a function' );

	setTime($NOW);
	is( $NP->parse( decoded('now-next-normal.json') )->{fetched}, $NOW, 'now defaults to the current time' );
	clearTime();
};

subtest 'parse: failures give undef' => sub {
	is( $NP->parse( decoded('now-next-success-false.json'), $NOW ), undef, 'success:false' );
	is( decoded('now-next-body-zero.json'), 0, 'body-zero fixture decodes to 0' );
	is( $NP->parse( decoded('now-next-body-zero.json'), $NOW ), undef, 'body 0' );
	is( $NP->parse( -1, $NOW ), undef, 'body -1' );
	is( $NP->parse( [ { success => 1 } ], $NOW ), undef, 'JSON array' );
	is( $NP->parse( undef, $NOW ), undef, 'undef' );
	is( $NP->parse( 'oops', $NOW ), undef, 'string' );
	is( $NP->parse( { success => JSON::PP::true() }, $NOW ), undef, 'data missing' );
	is( $NP->parse( { success => JSON::PP::true(), data => undef }, $NOW ), undef, 'data null' );
	is( $NP->parse( { success => JSON::PP::true(), data => [] }, $NOW ), undef, 'data an array' );
	is( $NP->parse( { data => decoded('now-next-normal.json')->{data} }, $NOW ), undef, 'success missing' );
};

subtest 'parse: missing current or next' => sub {
	my $info = $NP->parse( decoded('now-next-no-current.json'), $NOW );
	is( $info->{current}, undef, 'no-current: current => undef' );
	is_deeply( $info->{next}, $NEXT, 'no-current: next parsed' );
	is( $info->{expires} - $info->{fetched}, 900, 'no-current: lifetime from next.start (clamped)' );

	$info = $NP->parse( decoded('now-next-no-next.json'), $NOW );
	is( $info->{next}, undef, 'no-next: next => undef' );
	is( $info->{current}{end}, $NEXT_START, 'no-next: current.end from current_show.end_time' );
	is_deeply( $info->{current}, $CURRENT, 'no-next: current otherwise complete' );
	is( $NP->parse( decoded('now-next-no-next.json'), $NEXT_START - 120 )->{expires}, $NEXT_START, 'no-next: lifetime runs to current.end' );

	$info = variant( sub { delete @{ $_[0] }{qw(current current_show next next_show)} } );
	ok( $info && !$info->{current} && !$info->{next}, 'both missing: current and next undef' );
	is( $info->{expires} - $info->{fetched}, 300, 'both missing: lifetime 300 s' );
	is( $info->{streamUrl}, $STREAM1, 'both missing: streamUrl still parsed' );

	$info = variant( sub { $_[0]{current} = undef; $_[0]{current_show} = undef } );
	is( $info->{current}, undef, 'current null: current => undef' );

	$info = variant( sub { $_[0]{current}{name} = ''; $_[0]{current_show}{name} = ' ' } );
	is( $info->{current}, undef, 'current without a name: current => undef' );
};

subtest 'parse: current_show missing or for another show' => sub {
	my $info = variant( sub { delete $_[0]{current_show} } );
	is_deeply(
		$info->{current},
		{ %$CURRENT, description => undef },
		'current_show missing: current.* fields, slug from the link, end = next.start'
	);

	$info = variant( sub { $_[0]{current_show} = { %{ $_[0]{current_show} }, name => 'Saturday Jazz', slug => 'saturdayjazz', start_time => '2026-09-26T09:00:00+08:00', end_time => '2026-09-26T11:00:00+08:00', short_description => 'Jazz.', url => 'https://rtrfm.com.au/shows/saturdayjazz/' } } );
	is_deeply( $info->{current}, { %$CURRENT, description => undef }, 'current_show.start_time differs: current_show ignored completely' );

	$info = variant( sub { $_[0]{current_show}{start_time} = '2026-09-26T03:00:00Z' } );
	is_deeply( $info->{current}, $CURRENT, 'same instant written differently: current_show kept' );

	$info = variant( sub { delete $_[0]{current_show}; $_[0]{current}{startTime} = 'soon' } );
	is( $info->{current}{start}, undef, 'startTime that cannot be parsed: start => undef' );
	is( $info->{current}{name}, 'Global Rhythm Pot', 'startTime that cannot be parsed: rest still parsed' );

	$info = variant( sub { delete $_[0]{next_show} } );
	is( $info->{next}{end}, undef, 'next_show missing: next.end undef' );
	is( $info->{next}{slug}, 'homegrown', 'next_show missing: slug from next.link' );
};

subtest 'parse: strings, entities, images, slugs' => sub {
	my $info = $NP->parse( decoded('now-next-entities.json'), $NOW );
	is( $info->{current}{name}, 'Black & Blue', '&amp; decoded' );
	is( $info->{next}{name}, "Rock\x{2019}n\x{2019}Roll Rumble", '&#8217; decoded to U+2019' );
	is( $info->{current}{description}, 'Blues & roots, old and new. Every Saturday.', 'tags stripped, &#038; decoded, whitespace collapsed' );
	is( $info->{next}{description}, 'Rock & roll, rockabilly & more.', 'next description decoded' );

	$info = variant( sub {
		$_[0]{current}{name}      = "  Global Rhythm Pot \n";
		$_[0]{current}{time}      = '';
		$_[0]{current}{thumbnail} = '';
		$_[0]{next}{time}         = ' ';
		$_[0]{next_show}{friendly_times} = '';
		$_[0]{next}{thumbnail}    = '/wp-content/uploads/2012/12/homegrown-1.jpg';
		$_[0]{next_show}{short_description} = '   ';
	} );
	is( $info->{current}{name},     'Global Rhythm Pot', 'name trimmed' );
	is( $info->{current}{timeText}, '11.00am - 1.00pm',  'empty current.time: falls back to friendly_times' );
	is( $info->{current}{image},    undef, 'empty thumbnail: image undef' );
	is( $info->{next}{timeText},    undef, 'no time text: undef' );
	is( $info->{next}{image},       undef, 'relative thumbnail: image undef' );
	is( $info->{next}{description}, undef, 'blank description: undef' );

	$info = variant( sub { $_[0]{current}{thumbnail} = 'ftp://rtrfm.com.au/x.jpg'; $_[0]{current_show}{slug} = 'Global Rhythm Pot' } );
	is( $info->{current}{image}, undef, 'non-http(s) thumbnail: image undef' );
	is( $info->{current}{slug},  undef, 'invalid slug: undef' );

	$info = variant( sub { delete $_[0]{current_show}; $_[0]{current}{link} = 'https://rtrfm.com.au/about/' } );
	is( $info->{current}{slug}, undef, 'no slug in the link: undef' );
};

subtest 'parse: stream_url validation' => sub {
	is( $NP->parse( decoded('now-next-stream-url-changed.json'), $NOW )->{streamUrl}, 'https://live.rtrfm.com.au/stream1-hq', 'changed URL on live.rtrfm.com.au accepted' );
	is( $NP->parse( decoded('now-next-foreign-stream-url.json'), $NOW )->{streamUrl}, undef, 'foreign host rejected' );

	my %cases = (
		'http://live.rtrfm.com.au/stream1'               => 'http://live.rtrfm.com.au/stream1',
		''                                               => undef,
		'https://live.rtrfm.com.au/stream1 '             => undef,
		"https://live.rtrfm.com.au/stream1\n"            => undef,
		'https://live.rtrfm.com.au/stream 1'             => undef,
		'https://live.rtrfm.com.au/'                     => undef,
		'https://live.rtrfm.com.au.evil.example/stream1' => undef,
		'https://evil.example.com/?u=https://live.rtrfm.com.au/stream1' => undef,
	);
	for my $url ( sort keys %cases ) {
		is( variant( sub { $_[0]{stream_url} = $url } )->{streamUrl}, $cases{$url}, "stream_url '$url'" );
	}
	is( variant( sub { delete $_[0]{stream_url} } )->{streamUrl}, undef, 'stream_url missing' );
};

subtest 'parse: independent of the server time zone' => sub {
	local $ENV{TZ} = 'America/New_York';
	POSIX::tzset();
	my $info = $NP->parse( decoded('now-next-normal.json'), $NOW );
	is( $info->{current}{start}, 1_790_391_600, 'current.start under TZ=America/New_York' );
	is( $info->{next}{end},      1_790_406_000, 'next.end under TZ=America/New_York' );
};
POSIX::tzset();

# ---------------------------------------------------------------------------
# showLabel
# ---------------------------------------------------------------------------

subtest 'showLabel' => sub {
	is( $NP->showLabel($CURRENT), "Global Rhythm Pot \x{B7} 11.00am - 1.00pm", 'name · time' );
	is( Plugins::RTRFM::NowPlaying::showLabel($NEXT), "Homegrown \x{B7} 1.00pm - 3.00pm", 'as a function' );
	is( $NP->showLabel( { name => 'Homegrown', timeText => undef } ), 'Homegrown', 'no time text: name only' );
	is( $NP->showLabel( { name => 'Homegrown', timeText => '' } ),    'Homegrown', 'empty time text: name only' );
	is( $NP->showLabel( { name => undef, timeText => '1.00pm - 3.00pm' } ), undef, 'no name: undef' );
	is( $NP->showLabel(undef), undef, 'no show: undef' );
};

# ---------------------------------------------------------------------------
# fetch and the cache
# ---------------------------------------------------------------------------

subtest 'fetch: success, then answered from the cache without a request' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', headers => { 'Content-Type' => 'application/json; charset=UTF-8' } );

	is( $NP->cached, undef, 'nothing cached yet' );
	is( $NP->lastGood, undef, 'no last good data yet' );

	my $c = collector();
	$NP->fetch( $c->cb );
	is( $c->count, 1, 'one callback' );
	my ($info) = $c->args(0);
	is_deeply( $info, { current => $CURRENT, next => $NEXT, streamUrl => $STREAM1, fetched => $NOW, expires => $NOW + 900 }, 'callback gets the parsed $info' );
	is( scalar requests(), 1, 'one request' );

	advanceTime(899);
	my $c2 = collector();
	Plugins::RTRFM::NowPlaying::fetch( $c2->cb );
	is( $c2->count, 1, 'second fetch inside the lifetime: answered synchronously' );
	is( ( $c2->args(0) )[0], $info, 'with the cached $info' );
	is( scalar requests(), 1, 'second fetch inside the lifetime: no new request' );
	is( $NP->cached, $info, 'cached() returns it' );
	is( $NP->lastGood, $info, 'lastGood() returns it' );

	requests_ok('success');
	clearTime();
};

subtest 'cache lifetime: clamp(next.start - now, 60, 900), expired at exactly expires' => sub {
	for my $case ( [ 30, 60 ], [ 600, 600 ], [ 7200, 900 ], [ -300, 60 ] ) {
		my ( $away, $ttl ) = @$case;
		fresh_start( $NEXT_START - $away );
		serve( file => 'live/now-next-normal.json' );

		$NP->fetch( sub { } );
		my $info = $NP->cached;
		is( $info && $info->{expires} - $info->{fetched}, $ttl, "next.start ${away} s away: lifetime $ttl s" );

		advanceTime( $ttl - 1 );
		ok( $NP->cached, "fresh 1 s before expiry (${away} s case)" );
		$NP->fetch( sub { } );
		is( scalar requests(), 1, "no request 1 s before expiry (${away} s case)" );

		advanceTime(1);
		is( $NP->cached, undef, "expired at exactly expires (${away} s case)" );
		is( $NP->lastGood, $info, "lastGood kept after expiry (${away} s case)" );
		$NP->fetch( sub { } );
		is( scalar requests(), 2, "fetch at expires sends a new request (${away} s case)" );
	}

	fresh_start( $NEXT_START - 120 );
	serve( file => 'live/now-next-no-next.json' );
	$NP->fetch( sub { } );
	is( $NP->cached->{expires}, $NEXT_START, 'no next: lifetime runs to current.end' );

	clearTime();
};

subtest 'coalescing: three fetches while a request is in flight share it' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );

	my @c = map { collector() } 1 .. 3;
	$NP->fetch( $_->cb ) for @c;

	is( scalar requests(), 1, 'one request' );
	is( scalar( grep { $_->count } @c ), 0, 'no callback while in flight' );

	is( Slim::Networking::SimpleAsyncHTTP->completeDeferred, 1, 'response arrives' );
	is_deeply( [ map { $_->count } @c ], [ 1, 1, 1 ], 'each of the three callbacks called exactly once' );
	ok( ( grep { ref( ( $_->args(0) )[0] ) eq 'HASH' } @c ) == 3, 'each got the $info' );
	is( scalar requests(), 1, 'still one request' );

	# a waiting callback that dies doesn't stop the others
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	my $after = collector();
	$NP->fetch( sub { die "consumer broke\n" } );
	$NP->fetch( $after->cb );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $after->count, 1, 'callback after a dying one still called' );
	ok( ( grep { $_->{message} =~ /consumer broke/ } Slim::Utils::Log->messages( level => 'ERROR' ) ), 'the dying callback is logged' );

	requests_ok('coalescing');
	clearTime();
};

subtest 'negative cache: no request for 20 s after a failure' => sub {
	fresh_start();
	serve( code => 500, content => 'oops' );

	my $c = collector();
	$NP->fetch( $c->cb );
	is( $c->count, 1, 'failure: one callback' );
	my ( $info, $message ) = $c->args(0);
	is( $info, undef, 'failure: no $info' );
	like( $message, qr/500 Internal Server Error/, 'failure: readable message' );
	is( scalar requests(), 1, 'one request' );

	advanceTime(19);
	my $c2 = collector();
	$NP->fetch( $c2->cb );
	is( scalar requests(), 1, '+19 s: no request' );
	is( $c2->count, 1, '+19 s: one callback' );
	is_deeply( [ $c2->args(0) ], [ undef, $message ], '+19 s: the failure again' );

	advanceTime(2);
	my $c3 = collector();
	$NP->fetch( $c3->cb );
	is( scalar requests(), 2, '+21 s: new request' );
	is( $c3->count, 1, '+21 s: one callback' );

	requests_ok('negative cache');
	clearTime();
};

subtest 'every failure kind: exactly one error callback, last good data kept' => sub {
	my @kinds = (
		[ 'HTTP 403',      { code => 403, content => 'Forbidden' } ],
		[ 'HTTP 500',      { code => 500, content => 'oops' } ],
		[ 'timeout',       { error => 'Timed out waiting for data' } ],
		[ 'HTML body',     { code => 200, content => '<html><body>Error</body></html>', headers => { 'Content-Type' => 'text/html' } } ],
		[ 'body 0',        { code => 200, file => 'live/now-next-body-zero.json' } ],
		[ 'body -1',       { code => 200, content => '-1' } ],
		[ 'success:false', { code => 200, file => 'live/now-next-success-false.json' } ],
		[ 'empty body',    { code => 200, content => '' } ],
	);

	for my $kind (@kinds) {
		my ( $label, $response ) = @$kind;

		fresh_start();
		serve( file => 'live/now-next-normal.json' );
		$NP->fetch( sub { } );
		my $good = $NP->lastGood;

		advanceTime(900);    # cache expired
		Slim::Networking::SimpleAsyncHTTP->reset;
		serve(%$response);

		my $c = collector();
		$NP->fetch( $c->cb );
		is( $c->count, 1, "$label: exactly one callback" );
		my ( $info, $message ) = $c->args(0);
		ok( !defined $info && defined $message && length $message, "$label: (undef, message)" ) or diag explain [ $c->args(0) ];
		is( $NP->cached,   undef, "$label: nothing fresh" );
		is( $NP->lastGood, $good, "$label: lastGood kept" );
	}

	clearTime();
};

subtest 'logging: one DEBUG request line per request; WARN once per run of failures' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );

	$NP->fetch( sub { } ) for 1 .. 3;
	is( scalar requests(), 1, 'three fetches, one request' );
	is( scalar request_lines(), 1, 'exactly one DEBUG line containing get_current_and_next_show' );
	is( scalar Slim::Utils::Log->messages( level => 'WARN' ), 0, 'no warnings on success' );

	# a run of consecutive failures (success:false: only NowPlaying logs these)
	fresh_start();
	serve( file => 'live/now-next-success-false.json' );
	for ( 1 .. 3 ) {
		$NP->fetch( sub { } );
		advanceTime(21);
	}
	is( scalar requests(), 3, 'three failed requests' );
	is( scalar request_lines(), 3, 'one DEBUG request line per request' );
	is( scalar Slim::Utils::Log->messages( level => 'WARN', category => 'plugin.rtrfm' ), 1, 'success:false run: one WARN in total' );
	is( scalar own_messages('DEBUG'), 2, 'the rest of the run at DEBUG' );

	# recovery ends the run; the next failure warns again
	Slim::Networking::SimpleAsyncHTTP->reset;
	serve( file => 'live/now-next-normal.json' );
	$NP->fetch( sub { } );
	ok( $NP->cached, 'recovered' );
	advanceTime(900);
	Slim::Networking::SimpleAsyncHTTP->reset;
	serve( file => 'live/now-next-success-false.json' );
	$NP->fetch( sub { } );
	is( scalar own_messages('WARN'), 2, 'a new run after a success warns again' );

	# HTTP errors: HTTP.pm logs each failed request itself; NowPlaying adds one WARN per run
	fresh_start();
	serve( code => 500, content => 'oops' );
	for ( 1 .. 3 ) {
		$NP->fetch( sub { } );
		advanceTime(21);
	}
	is( scalar own_messages('WARN'),  1, 'HTTP 500 run: NowPlaying warns once' );
	is( scalar own_messages('DEBUG'), 2, 'HTTP 500 run: then DEBUG' );
	is( scalar request_lines(), 3, 'HTTP 500 run: one DEBUG request line per request' );
	ok( !( grep { $_->{message} =~ /get_current_and_next_show/ } own_messages('WARN'), own_messages('DEBUG') ), "NowPlaying's own lines don't repeat the endpoint" );

	requests_ok('logging');
	clearTime();
};

done_testing();
