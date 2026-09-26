#!/usr/bin/perl
# Plugins::RTRFM::Restream::resolve: turns (slug, Perth date) into RTRFM's signed MP3 URL via rzz.
# One uncached GET per call with a non-libwww User-Agent; {url} for a restreams .mp3,
# {unavailable} for any other restreams URL (today: .mp4 -> 404), {error} for everything else;
# invalid input fails without a request; exactly one callback on every path.

use strict;
use warnings;

use RTRFMTest qw(:all);
use Test::More;

use Plugins::RTRFM::Restream;

my $RZZ    = 'https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-09-19';
my $MP3    = 'https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=MrBRQ5-P-Cch0feNMG1gzg&e=1790396793';
my %JS     = ( headers => { 'Content-Type' => 'application/javascript' } );

# Resolve once; return (collector, requests made by this call).
sub run_resolve {
	my ( $slug, $date ) = @_;
	my $c      = collector();
	my $before = () = requests();

	Plugins::RTRFM::Restream::resolve( $slug, $date, $c->cb );

	my @requests = requests();
	return ( $c, @requests[ $before .. $#requests ] );
}

# The single callback's result hash (and checks that there was exactly one callback with a hash).
sub result_of {
	my ( $c, $name ) = @_;
	is( $c->count, 1, "$name: exactly one callback" );
	my ($result) = $c->args(0);
	is( ref $result, 'HASH', "$name: callback gets a hash" );
	return $result || {};
}

sub is_error {
	my ( $c, $name ) = @_;
	my $result = result_of( $c, $name );
	ok( defined $result->{error} && !ref $result->{error} && length $result->{error}, "$name: {error} with a message" );
	ok( !exists $result->{url} && !exists $result->{unavailable}, "$name: nothing but the error" );
	return $result;
}

subtest 'available episode (.mp3): {url}, one uncached rzz GET with a non-libwww User-Agent' => sub {
	resetStubs();
	route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );

	my ( $c, @requests ) = run_resolve( 'saturdayjazz', '2026-09-19' );
	my $result = result_of( $c, 'mp3' );
	is_deeply( $result, { url => $MP3 }, '{url} is the signed MP3 URL from rzz' );

	is( scalar @requests, 1, 'exactly one HTTP request' );
	my $req = $requests[0];
	is( $req->{method}, 'GET', 'GET' );
	is( $req->{url}, $RZZ, 'request URL is exactly the rzz URL for the slug and date' );
	my $ua = $req->{headers}->header('User-Agent');
	ok( defined $ua && length $ua, 'User-Agent is set' );
	unlike( $ua, qr/libwww/i, 'User-Agent is not libwww' );
	ok( !exists $req->{params}->{cache} && !exists $req->{params}->{expires}, 'no caching options: signed URLs are never reused' );
};

subtest 'every call hits rzz (no caching)' => sub {
	resetStubs();
	route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );

	my ( $c1, @r1 ) = run_resolve( 'saturdayjazz', '2026-09-19' );
	my ( $c2, @r2 ) = run_resolve( 'saturdayjazz', '2026-09-19' );
	is( scalar(@r1) + scalar(@r2), 2, 'two resolves make two requests' );
	is_deeply( ( $c2->args(0) )[0], { url => $MP3 }, 'second resolve also gets {url}' );
};

subtest 'deleted episode (.mp4): {unavailable}' => sub {
	resetStubs();
	my $url = 'https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-08-22';
	route( $url, file => 'ondemand/rzz-saturdayjazz-2026-08-22.json', %JS );

	my ( $c, @requests ) = run_resolve( 'saturdayjazz', '2026-08-22' );
	is_deeply( result_of( $c, 'mp4' ), { unavailable => 1 }, '{unavailable => 1}' );
	is( $requests[0]->{url}, $url, 'asked rzz for that date' );
};

subtest 'unknown show: rzz answers 200 with an .mp4 URL -> {unavailable}' => sub {
	resetStubs();
	my $url = 'https://restreams.rtrfm.com.au/rzz?n=nosuchshow&d=2026-09-19';
	route( $url, content => '{"u":"https://restreams.rtrfm.com.au/shows/nosuchshow_2026-09-19.mp4?st=vL9QVEaeVh3sNOJO3j4TxQ&e=1790396796"}', %JS );

	my ($c) = run_resolve( 'nosuchshow', '2026-09-19' );
	is_deeply( result_of( $c, 'nosuchshow' ), { unavailable => 1 }, '{unavailable => 1}' );
};

subtest 'mp3 detection: ".mp3" followed by "?" or the end of the URL' => sub {
	my @cases = (
		[ 'no query string',      'https://restreams.rtrfm.com.au/shows/a_2026-09-19.mp3', { url => 'https://restreams.rtrfm.com.au/shows/a_2026-09-19.mp3' } ],
		[ '.mp3 inside the path', 'https://restreams.rtrfm.com.au/shows/a.mp3x?st=1&e=2',   { unavailable => 1 } ],
		[ 'other audio type',     'https://restreams.rtrfm.com.au/shows/a.aac?st=1&e=2',    { unavailable => 1 } ],
	);
	for my $case (@cases) {
		my ( $name, $u, $expected ) = @$case;
		resetStubs();
		route( $RZZ, content => qq({"u":"$u"}), %JS );
		my ($c) = run_resolve( 'saturdayjazz', '2026-09-19' );
		is_deeply( result_of( $c, $name ), $expected, "$name: " . join( ',', keys %$expected ) );
	}
};

subtest 'JSON with a byte-order mark and whitespace is still decoded' => sub {
	resetStubs();
	route( $RZZ, content => "\xEF\xBB\xBF \r\n" . fixture('ondemand/rzz-saturdayjazz-2026-09-19.json') . "\r\n ", %JS );

	my ($c) = run_resolve( 'saturdayjazz', '2026-09-19' );
	is_deeply( result_of( $c, 'BOM' ), { url => $MP3 }, '{url}' );
};

subtest 'errors: bad rzz answers give {error} (one callback, one request)' => sub {
	my @cases = (
		[ 'foreign host u',     { file => 'ondemand/rzz-foreign-host.json', %JS } ],
		[ 'missing u',          { file => 'ondemand/rzz-no-u.json', %JS } ],
		[ 'empty object',       { content => '{}', %JS } ],
		[ 'empty array',        { content => '[]', %JS } ],
		[ 'JSON null',          { content => 'null', %JS } ],
		[ 'u null',             { content => '{"u":null}', %JS } ],
		[ 'u empty',            { content => '{"u":""}', %JS } ],
		[ 'u not a string',     { content => '{"u":{"href":"https://restreams.rtrfm.com.au/shows/a.mp3"}}', %JS } ],
		[ 'u a number',         { content => '{"u":42}', %JS } ],
		[ 'http:// restreams',  { content => '{"u":"http://restreams.rtrfm.com.au/shows/a.mp3?st=1&e=2"}', %JS } ],
		[ 'look-alike host',    { content => '{"u":"https://restreams.rtrfm.com.au.example.net/shows/a.mp3?st=1&e=2"}', %JS } ],
		[ 'Cloudflare HTML',    { code => 200, file => 'ondemand/rzz-cloudflare.html', headers => { 'Content-Type' => 'text/html' } } ],
		[ 'HTTP 403',           { code => 403, file => 'ondemand/rzz-cloudflare.html', headers => { 'Content-Type' => 'text/html' } } ],
		[ 'HTTP 500',           { code => 500, content => 'Internal Server Error' } ],
		[ 'transport error',    { error => 'Timed out waiting for data' } ],
	);

	for my $case (@cases) {
		my ( $name, $response ) = @$case;
		resetStubs();
		route( $RZZ, %$response );

		my ( $c, @requests ) = run_resolve( 'saturdayjazz', '2026-09-19' );
		is_error( $c, $name );
		is( scalar @requests, 1, "$name: one request" );
	}
};

subtest 'invalid input: {error} and no HTTP request at all' => sub {
	my @cases = (
		[ 'uppercase slug',     'SaturdayJazz', '2026-09-19' ],
		[ 'slug with a space',  'saturday jazz', '2026-09-19' ],
		[ 'slug with a slash',  'drivetime/monday', '2026-09-19' ],
		[ 'slug with &',        'a&d=2026-01-01', '2026-09-19' ],
		[ 'empty slug',         '', '2026-09-19' ],
		[ 'undef slug',         undef, '2026-09-19' ],
		[ 'slug with newline',  "saturdayjazz\n", '2026-09-19' ],
		[ 'impossible date',    'saturdayjazz', '2026-02-30' ],
		[ 'short date',         'saturdayjazz', '2026-9-19' ],
		[ 'day-first date',     'saturdayjazz', '19-09-2026' ],
		[ 'date with time',     'saturdayjazz', '2026-09-19 09:00' ],
		[ 'undef date',         'saturdayjazz', undef ],
	);

	for my $case (@cases) {
		my ( $name, $slug, $date ) = @$case;
		resetStubs();
		route( qr/./, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );

		my ( $c, @requests ) = run_resolve( $slug, $date );
		is_error( $c, $name );
		is( scalar @requests, 0, "$name: zero HTTP requests" );
	}
};

subtest 'class-method call style works too' => sub {
	resetStubs();
	route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );

	my $c = collector();
	Plugins::RTRFM::Restream->resolve( 'saturdayjazz', '2026-09-19', $c->cb );
	is_deeply( result_of( $c, 'class method' ), { url => $MP3 }, '{url}' );
};

done_testing();
