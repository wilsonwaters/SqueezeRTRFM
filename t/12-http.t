#!/usr/bin/perl
# Plugins::RTRFM::HTTP: explicit non-libwww User-Agent on every request, 15 s default timeout,
# cache options passed through, JSON decoded whatever the Content-Type, form encoding, and
# exactly one callback per request on every path.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use Encode ();
use JSON::PP ();

use Plugins::RTRFM::HTTP;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $RZZ = 'https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-09-19';

# Run one request; return (success collector, error collector, recorded request).
sub run_request {
	my ( $call, $leading, $opts ) = @_;
	my $ok  = collector();
	my $err = collector();
	my $before = () = requests();

	no strict 'refs';
	&{"Plugins::RTRFM::HTTP::$call"}( @$leading, $ok->cb, $err->cb, $opts );

	my @requests = requests();
	return ( $ok, $err, @requests > $before ? $requests[-1] : undef );
}

sub exactly_one {
	my ( $ok, $err, $which, $name ) = @_;
	is( $ok->count + $err->count, 1, "$name: exactly one callback" );
	is( ( $which eq 'ok' ? $ok : $err )->count, 1, "$name: the " . ( $which eq 'ok' ? 'success' : 'error' ) . ' callback' );
}

subtest 'getJSON: success with application/javascript, headers, default timeout' => sub {
	resetStubs();
	route( $RZZ, file => 'foundation/rzz.json', headers => { 'Content-Type' => 'application/javascript' } );

	my ( $ok, $err, $req ) = run_request( getJSON => [$RZZ], undef );
	exactly_one( $ok, $err, 'ok', 'rzz' );

	my ( $data, $http ) = $ok->args(0);
	is( ref $data, 'HASH', 'decoded to a hash' );
	like( $data->{u}, qr{^https://restreams\.rtrfm\.com\.au/shows/saturdayjazz_2026-09-19\.mp3\?st=}, 'decoded the signed URL' );
	ok( $http && $http->can('headers'), 'second argument is the HTTP object' );

	is( $req->{method}, 'GET', 'GET request' );
	my $ua = $req->{headers}->header('User-Agent');
	ok( defined $ua && length $ua, 'User-Agent header is set explicitly' );
	is( $ua, Slim::Utils::Misc::userAgentString(), "User-Agent is LMS's user agent string" );
	unlike( $ua, qr/libwww/i, 'User-Agent is not libwww-perl' );
	is( $req->{params}->{timeout}, 15, 'default timeout is 15 s' );
	ok( !exists $req->{params}->{cache}, 'no caching unless asked' );
};

subtest 'options: timeout, cache and expires are passed through' => sub {
	resetStubs();
	route( $RZZ, file => 'foundation/rzz.json' );

	my ( $ok, $err, $req ) = run_request( getJSON => [$RZZ], { timeout => 5, cache => 1, expires => 3600 } );
	exactly_one( $ok, $err, 'ok', 'with options' );
	is( $req->{params}->{timeout}, 5,    'custom timeout' );
	is( $req->{params}->{cache},   1,    'cache passed through' );
	is( $req->{params}->{expires}, 3600, 'expires passed through' );
};

subtest 'getJSON: JSON with a byte-order mark and whitespace' => sub {
	resetStubs();
	route( 'https://example.test/bom', file => 'foundation/bom-whitespace.json', headers => { 'Content-Type' => 'text/html' } );

	my ( $ok, $err ) = run_request( getJSON => ['https://example.test/bom'], undef );
	exactly_one( $ok, $err, 'ok', 'BOM' );
	is_deeply( ( $ok->args(0) )[0], { success => JSON::PP::true(), data => { name => 'Saturday Jazz', slug => 'saturdayjazz' } }, 'decoded despite BOM, CRLF and whitespace' );
};

subtest 'getJSON: top-level array with UTF-8 text, no Content-Type' => sub {
	resetStubs();
	route( 'https://example.test/programs', file => 'foundation/programs-sample.json', headers => {} );

	my ( $ok, $err ) = run_request( getJSON => ['https://example.test/programs'], undef );
	exactly_one( $ok, $err, 'ok', 'array' );
	my ($data) = $ok->args(0);
	is( ref $data, 'ARRAY', 'decoded to an array' );
	is( $data->[1]->{name}, 'El Ritmo – Música', 'UTF-8 decoded to characters' );
};

subtest 'getJSON: error paths call only the error callback, with a readable message' => sub {
	my @cases = (
		[ 'HTTP 403',      { code => 403, file => 'foundation/error-page.html', headers => { 'Content-Type' => 'text/html' } }, qr/403 Forbidden/ ],
		[ 'HTTP 500',      { code => 500, content => 'oops' },                     qr/500 Internal Server Error/ ],
		[ 'timeout',       { error => 'Timed out waiting for data' },              qr/Timed out waiting for data/ ],
		[ 'empty body',    { code => 200, content => '' },                         qr/Empty response/ ],
		[ 'blank body',    { code => 200, content => " \r\n " },                   qr/Empty response/ ],
		[ 'HTML page',     { code => 200, file => 'foundation/error-page.html', headers => { 'Content-Type' => 'text/html' } }, qr/Invalid JSON/ ],
		[ 'truncated',     { code => 200, content => '{"u":"https://rest' },       qr/Invalid JSON/ ],
		[ 'JSON scalar',   { code => 200, content => '"just a string"' },          qr/not an object or array/ ],
	);

	for my $case (@cases) {
		my ( $name, $response, $expected ) = @$case;
		resetStubs();
		route( $RZZ, %$response );

		my ( $ok, $err, $req ) = run_request( getJSON => [$RZZ], undef );
		exactly_one( $ok, $err, 'err', $name );

		my ($message) = $err->args(0);
		like( $message, $expected, "$name: message says what went wrong" );
		like( $message, qr/\Q$RZZ\E/, "$name: message names the URL" );
		unlike( $message, qr/ at \S+ line \d+/, "$name: no Perl file/line noise" );
		ok( defined $req->{headers}->header('User-Agent'), "$name: User-Agent sent" );
		ok( ( grep { $_->{level} eq 'WARN' && $_->{category} eq 'plugin.rtrfm' } Slim::Utils::Log->messages ), "$name: logged a warning" );
	}
};

subtest 'quiet => 1: failures logged at DEBUG instead of WARN, same callbacks and messages' => sub {
	# plugin.rtrfm at DEBUG for this subtest, so DEBUG lines are logged
	local $Slim::Utils::Log::CATEGORIES{'plugin.rtrfm'} = { defaultLevel => 'DEBUG', description => 'PLUGIN_RTRFM' };

	my $url = 'https://rtrfm.com.au/shows/saturdayjazz/';
	my @cases = (
		[ 'getJSON HTTP 500',     getJSON      => [$RZZ],             { code => 500, content => 'oops' },            qr/500 Internal Server Error/ ],
		[ 'getJSON timeout',      getJSON      => [$RZZ],             { error => 'Timed out waiting for data' },     qr/Timed out waiting for data/ ],
		[ 'getJSON invalid JSON', getJSON      => [$RZZ],             { code => 200, content => '<html></html>' },   qr/Invalid JSON/ ],
		[ 'getJSON empty body',   getJSON      => [$RZZ],             { code => 200, content => '' },                qr/Empty response/ ],
		[ 'postFormJSON 403',     postFormJSON => [ $RZZ, { a => 1 } ], { code => 403, content => 'Forbidden' },       qr/403 Forbidden/ ],
		[ 'get 404',              get          => [$url],             { code => 404 },                               qr/404 Not Found/ ],
	);

	for my $case (@cases) {
		my ( $name, $call, $leading, $response, $expected ) = @$case;
		my $target = $leading->[0];

		resetStubs();
		route( $target, %$response );
		my ( $ok, $err, $req ) = run_request( $call => $leading, { quiet => 1 } );
		exactly_one( $ok, $err, 'err', "quiet $name" );
		my ($message) = $err->args(0);
		like( $message, $expected, "quiet $name: same readable message" );
		like( $message, qr/\Q$target\E/, "quiet $name: message names the URL" );
		is( scalar Slim::Utils::Log->messages( level => 'WARN', category => 'plugin.rtrfm' ), 0, "quiet $name: no WARN" );
		ok( ( grep { $_->{message} eq $message } Slim::Utils::Log->messages( level => 'DEBUG', category => 'plugin.rtrfm' ) ), "quiet $name: logged at DEBUG" );
		ok( !exists $req->{params}->{quiet}, "quiet $name: not passed to SimpleAsyncHTTP" );

		# the default is unchanged: the same failure without quiet logs a WARN
		resetStubs();
		route( $target, %$response );
		( $ok, $err ) = run_request( $call => $leading, { quiet => 0 } );
		exactly_one( $ok, $err, 'err', "not quiet $name" );
		is( scalar Slim::Utils::Log->messages( level => 'WARN', category => 'plugin.rtrfm' ), 1, "quiet => 0 $name: one WARN" );
	}

	resetStubs();
	route( $RZZ, file => 'foundation/rzz.json' );
	my ( $ok, $err ) = run_request( getJSON => [$RZZ], { quiet => 1 } );
	exactly_one( $ok, $err, 'ok', 'quiet success' );
	is( ref( ( $ok->args(0) )[0] ), 'HASH', 'quiet success: decoded as usual' );
};

subtest 'getJSON: no route (network failure) still calls back once' => sub {
	resetStubs();
	my ( $ok, $err ) = run_request( getJSON => ['https://nowhere.test/'], undef );
	exactly_one( $ok, $err, 'err', 'no route' );
};

subtest 'getJSON: an exception in the success callback does not also call the error callback' => sub {
	resetStubs();
	route( $RZZ, file => 'foundation/rzz.json' );

	my $err = collector();
	my $died = !eval { Plugins::RTRFM::HTTP::getJSON( $RZZ, sub { die "callback bug\n" }, $err->cb ); 1 };
	ok( $died, 'the exception propagates' );
	is( $err->count, 0, 'error callback not called' );
};

subtest 'postFormJSON: form encoding, headers and JSON decoding' => sub {
	resetStubs();
	my $url = 'https://rtrfm.com.au/wp-admin/admin-ajax.php';
	# response bodies are bytes, as on the wire
	route( $url, content => Encode::encode_utf8('{"success":true,"data":{"items":"<div>…</div>"}}'), headers => { 'Content-Type' => 'application/json; charset=UTF-8' } );

	my ( $ok, $err, $req ) = run_request(
		postFormJSON => [ $url, { action => 'filter_shows', search => '', 'postTypes[]' => ['show'], page => 2, q => 'Café & Co' } ],
		undef
	);
	exactly_one( $ok, $err, 'ok', 'POST' );

	is( $req->{method}, 'POST', 'POST request' );
	is( $req->{body}, 'action=filter_shows&page=2&postTypes%5B%5D=show&q=Caf%C3%A9%20%26%20Co&search=', 'fields URL-encoded (UTF-8), sorted by name' );
	is( $req->{headers}->header('Content-Type'), 'application/x-www-form-urlencoded', 'form Content-Type' );
	my $ua = $req->{headers}->header('User-Agent');
	ok( defined $ua && $ua !~ /libwww/i, 'non-libwww User-Agent on POST' );
	is( $req->{params}->{timeout}, 15, 'default timeout on POST' );
	is( ( $ok->args(0) )[0]->{data}->{items}, '<div>…</div>', 'response decoded' );

	resetStubs();
	route( $url, content => '', headers => {} );
	( $ok, $err, $req ) = run_request( postFormJSON => [ $url, { 'a[]' => [ 1, 2 ] } ], undef );
	is( $req->{body}, 'a%5B%5D=1&a%5B%5D=2', 'array values repeat the field' );
	exactly_one( $ok, $err, 'err', 'POST with empty response' );
};

subtest 'get: raw body' => sub {
	resetStubs();
	my $url = 'https://rtrfm.com.au/shows/saturdayjazz/';
	route( $url, file => 'foundation/error-page.html', headers => { 'Content-Type' => 'text/html' } );

	my ( $ok, $err, $req ) = run_request( get => [$url], undef );
	exactly_one( $ok, $err, 'ok', 'raw get' );
	like( ( $ok->args(0) )[0], qr{<h1>Sorry, you have been blocked</h1>}, 'body returned as a string' );
	is( $req->{headers}->header('User-Agent'), Slim::Utils::Misc::userAgentString(), 'User-Agent on raw get' );
	is( $req->{params}->{timeout}, 15, 'default timeout on raw get' );

	resetStubs();
	route( $url, code => 404 );
	( $ok, $err ) = run_request( get => [$url], undef );
	exactly_one( $ok, $err, 'err', 'raw get 404' );
	like( ( $err->args(0) )[0], qr/404 Not Found/, 'raw get error message' );
};

done_testing();
