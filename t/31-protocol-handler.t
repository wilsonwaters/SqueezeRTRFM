#!/usr/bin/perl
# Plugins::RTRFM::ProtocolHandler (rtrfm://episode/...): scanUrl resolves the signed MP3 through
# rzz at play time, lets the core remote scanner scan it, then points $song->streamUrl at the
# MP3 and restores the track URL to the exact rtrfm URL; unavailable/failed/invalid episodes
# call back with the right error token without scanning. new() streams $song->streamUrl unless
# redirected. getMetadataFor/getIcon never do network I/O.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use Slim::Utils::Strings;

use Plugins::RTRFM::ProtocolHandler;
use Plugins::RTRFM::Util qw(ICON setEpisodeMeta friendlyDate);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $PH  = 'Plugins::RTRFM::ProtocolHandler';
my $RZZ = 'https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-09-19';
my $MP3 = 'https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=MrBRQ5-P-Cch0feNMG1gzg&e=1790396793';
my %JS  = ( headers => { 'Content-Type' => 'application/javascript' } );

my $FALLBACK_TITLE = "saturdayjazz \x{2013} " . friendlyDate('2026-09-19');

my %META = (
	slug        => 'saturdayjazz',
	date        => '2026-09-19',
	start       => '2026-09-19 09:00:00',
	duration    => 7200,
	title       => 'Saturday Jazz with Laura Igglesden',
	show        => 'Saturday Jazz',
	image       => 'https://example.org/sj.jpg',
	description => 'x',
);

# A scanner that "scans" successfully: the scanned track is a new object for the scanned URL
# (or for $redirectTo, as after an HTTP redirect).
sub scanner_ok {
	my $redirectTo = shift;
	$Slim::Utils::Scanner::Remote::HANDLER = sub {
		my ( $url, $args ) = @_;
		my $track = FakeTrack->new( url => $redirectTo || $url, title => $args->{song}->track->title );
		return $args->{cb}->( $track, undef );
	};
}

sub scans { @Slim::Utils::Scanner::Remote::SCANS }

# Run scanUrl for $url with a fresh fake song; returns (collector, song).
sub scan {
	my $url  = shift;
	my $song = FakeSong->new($url);
	my $c    = collector();
	$PH->scanUrl( $url, { client => $song->master, song => $song, cb => $c->cb } );
	return ( $c, $song );
}

subtest 'scanUrl success, with and without /HHMM' => sub {
	for my $url ( 'rtrfm://episode/saturdayjazz/2026-09-19/0900', 'rtrfm://episode/saturdayjazz/2026-09-19' ) {
		resetStubs();
		setTime(1790396800.25);
		route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );
		scanner_ok();

		my ( $c, $song ) = scan($url);

		my @requests = requests();
		is( scalar @requests, 1, "$url: one rzz request" );
		is( $requests[0]->{url}, $RZZ, "$url: HHMM is not sent to rzz" );

		my @scans = scans();
		is( scalar @scans, 1, "$url: scanned once" );
		is( $scans[0]->{url}, $MP3, "$url: the scanner gets the signed MP3 URL" );

		is( $c->count, 1, "$url: one callback" );
		my ( $track, $error ) = $c->args(0);
		ok( $track, "$url: callback gets the scanned track" ) or next;
		is( $error, undef, "$url: no error" );
		is( $song->streamUrl, $MP3, "$url: \$song->streamUrl is the signed MP3" );
		is( $track->url, $url, "$url: track URL restored to the exact rtrfm URL" );
		is( $track->title, $FALLBACK_TITLE, "$url: track title from getMetadataFor (URL fallback)" );
		is( $song->master->currentPlaylistUpdateTime, 1790396800.25, "$url: playlist update time bumped" );
	}
	clearTime();
};

subtest 'scanUrl success: track title comes from the metadata cache when primed' => sub {
	resetStubs();
	setEpisodeMeta( {%META} );
	route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );
	scanner_ok();

	my ($c) = scan('rtrfm://episode/saturdayjazz/2026-09-19/0900');
	my ($track) = $c->args(0);
	is( $track && $track->title, 'Saturday Jazz with Laura Igglesden', 'cached episode title' );
};

subtest 'scanUrl success after an HTTP redirect during the scan' => sub {
	resetStubs();
	route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );
	my $redirected = 'https://cdn.example.org/saturdayjazz_2026-09-19.mp3';
	scanner_ok($redirected);

	my $url = 'rtrfm://episode/saturdayjazz/2026-09-19/0900';
	my ( $c, $song ) = scan($url);
	my ($track) = $c->args(0);
	is( $song->streamUrl, $redirected, 'streamUrl is the final (redirected) MP3 URL' );
	is( $track && $track->url, $url, 'track URL is still the rtrfm URL' );
};

subtest 'scanUrl: the MP3 scan fails after a successful resolve' => sub {
	resetStubs();
	route( $RZZ, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );
	$Slim::Utils::Scanner::Remote::HANDLER = sub { $_[1]->{cb}->( undef, '404 Not Found' ) };

	my $url = 'rtrfm://episode/saturdayjazz/2026-09-19/0900';
	my ( $c, $song ) = scan($url);
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, '404 Not Found' ], "the scanner's error is passed on" );
	is( $song->streamUrl, $url, 'streamUrl untouched' );
	is( scalar( scans() ), 1, 'scanned once, no retry' );
	is( scalar( requests() ), 1, 'resolved once, no retry' );
};

subtest 'scanUrl: unavailable episode -> PLUGIN_RTRFM_EPISODE_UNAVAILABLE, no scan' => sub {
	resetStubs();
	route( 'https://restreams.rtrfm.com.au/rzz?n=saturdayjazz&d=2026-08-22', file => 'ondemand/rzz-saturdayjazz-2026-08-22.json', %JS );
	scanner_ok();

	my $url = 'rtrfm://episode/saturdayjazz/2026-08-22';
	my ( $c, $song ) = scan($url);
	is( $c->count, 1, 'one callback' );
	is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_RTRFM_EPISODE_UNAVAILABLE' ], 'cb->(undef, EPISODE_UNAVAILABLE)' );
	is( scalar( scans() ), 0, 'scanner not called' );
	is( $song->streamUrl, $url, 'streamUrl untouched' );
};

subtest 'scanUrl: resolve error -> PLUGIN_RTRFM_RESOLVE_FAILED, no scan' => sub {
	my @cases = (
		[ 'HTTP 500',        { code => 500, content => 'oops' } ],
		[ 'timeout',         { error => 'Timed out waiting for data' } ],
		[ 'foreign host',    { file => 'ondemand/rzz-foreign-host.json', %JS } ],
		[ 'Cloudflare page', { file => 'ondemand/rzz-cloudflare.html', headers => { 'Content-Type' => 'text/html' } } ],
	);
	for my $case (@cases) {
		my ( $name, $response ) = @$case;
		resetStubs();
		route( $RZZ, %$response );
		scanner_ok();

		my ($c) = scan('rtrfm://episode/saturdayjazz/2026-09-19/0900');
		is( $c->count, 1, "$name: one callback" );
		is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_RTRFM_RESOLVE_FAILED' ], "$name: cb->(undef, RESOLVE_FAILED)" );
		is( scalar( scans() ), 0, "$name: scanner not called" );
	}
};

subtest 'scanUrl: invalid URLs -> PLUGIN_RTRFM_EPISODE_UNAVAILABLE, no request, no scan' => sub {
	my @urls = (
		'rtrfm://episode/',
		'rtrfm://episode/SaturdayJazz/2026-09-19',
		'rtrfm://episode/saturdayjazz/2026-02-30',
		'rtrfm://episode/saturdayjazz/2026-09-19/2460',
		'rtrfm://episode/saturdayjazz/2026-09-19/0900/extra',
		'rtrfm://live',
		'https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3',
	);
	for my $url (@urls) {
		resetStubs();
		route( qr/./, file => 'ondemand/rzz-saturdayjazz-2026-09-19.json', %JS );
		scanner_ok();

		my ($c) = scan($url);
		is( $c->count, 1, "$url: one callback" );
		is_deeply( [ $c->args(0) ], [ undef, 'PLUGIN_RTRFM_EPISODE_UNAVAILABLE' ], "$url: cb->(undef, EPISODE_UNAVAILABLE)" );
		is( scalar( requests() ), 0, "$url: no HTTP request" );
		is( scalar( scans() ), 0, "$url: scanner not called" );
	}
};

subtest 'error tokens are defined strings with the agreed text' => sub {
	like( Slim::Utils::Strings::string('PLUGIN_RTRFM_EPISODE_UNAVAILABLE'), qr/no longer available/, 'EPISODE_UNAVAILABLE says "no longer available"' );
	ok( Slim::Utils::Strings::stringExists('PLUGIN_RTRFM_RESOLVE_FAILED'), 'RESOLVE_FAILED exists' );
};

subtest 'new(): streams $song->streamUrl unless redirected' => sub {
	my $song = FakeSong->new('rtrfm://episode/saturdayjazz/2026-09-19/0900');
	$song->streamUrl($MP3);

	my $sock = $PH->new( { url => 'rtrfm://episode/saturdayjazz/2026-09-19/0900', song => $song, client => $song->master } );
	is( $sock && $sock->{url}, $MP3, 'opens the signed MP3 URL' );
	is( $sock && $sock->{song}, $song, 'song passed on' );

	my $redirected = 'https://cdn.example.org/saturdayjazz_2026-09-19.mp3';
	$sock = $PH->new( { url => $redirected, redir => $MP3, song => $song, client => $song->master } );
	is( $sock && $sock->{url}, $redirected, 'after a redirect: keeps the redirected URL (no loop)' );
};

subtest 'getMetadataFor: primed cache entry' => sub {
	resetStubs();
	ok( setEpisodeMeta( {%META} ), 'primed the cache' );

	for my $url ( 'rtrfm://episode/saturdayjazz/2026-09-19/0900', 'rtrfm://episode/saturdayjazz/2026-09-19' ) {
		my $meta = $PH->getMetadataFor( undef, $url );
		is( $meta->{title},    'Saturday Jazz with Laura Igglesden', "$url: title" );
		is( $meta->{artist},   'Saturday Jazz',                      "$url: artist = show" );
		is( $meta->{album},    'RTRFM 92.1',                         "$url: album" );
		is( $meta->{cover},    'https://example.org/sj.jpg',         "$url: cover = image" );
		is( $meta->{icon},     'https://example.org/sj.jpg',         "$url: icon = image" );
		is( $meta->{duration}, 7200,                                 "$url: duration" );
	}
	is( scalar( requests() ), 0, 'no HTTP requests' );
};

subtest 'getMetadataFor: partial cache entry is filled per field from the fallback' => sub {
	resetStubs();
	setEpisodeMeta( { slug => 'saturdayjazz', date => '2026-09-19', title => 'Jazz – Laura’s pick', image => '' } );

	my $meta = $PH->getMetadataFor( undef, 'rtrfm://episode/saturdayjazz/2026-09-19/0900' );
	is( $meta->{title},  'Jazz – Laura’s pick', 'UTF-8 title from the cache' );
	is( $meta->{artist}, 'RTRFM 92.1',          'no show: artist falls back to the station' );
	is( $meta->{album},  'RTRFM 92.1',          'album' );
	is( $meta->{cover},  ICON,                  'no image: station icon' );
	is( $meta->{icon},   ICON,                  'no image: station icon as icon' );
	ok( !defined $meta->{duration}, 'no duration: none reported' );

	resetStubs();
	setEpisodeMeta( { slug => 'saturdayjazz', date => '2026-09-19', show => 'Saturday Jazz', duration => 7200 } );
	$meta = $PH->getMetadataFor( undef, 'rtrfm://episode/saturdayjazz/2026-09-19' );
	is( $meta->{title},    $FALLBACK_TITLE, 'no title: URL fallback title' );
	is( $meta->{artist},   'Saturday Jazz', 'show kept' );
	is( $meta->{duration}, 7200,            'duration kept' );
};

subtest 'getMetadataFor: no cache entry -> URL fallback' => sub {
	resetStubs();

	my $meta = $PH->getMetadataFor( undef, 'rtrfm://episode/saturdayjazz/2026-09-19' );
	is( $meta->{title}, 'saturdayjazz – Sat 19 Sep', 'title "<slug> – <friendly date>" with an en dash' );
	is( $meta->{title}, $FALLBACK_TITLE, 'friendly date from Util' );
	is( $meta->{artist}, 'RTRFM 92.1', 'artist' );
	is( $meta->{album},  'RTRFM 92.1', 'album' );
	is( $meta->{cover},  ICON,         'cover = station icon' );
	ok( !defined $meta->{duration}, 'no duration' );

	my $client = FakeMaster->new;
	$meta = $PH->getMetadataFor( $client, 'rtrfm://episode/drivetime/2026-09-01', 1 );
	is( $meta->{title}, 'drivetime – ' . friendlyDate('2026-09-01'), 'with a client and forceCurrent' );

	is( scalar( requests() ), 0, 'no HTTP requests' );
};

subtest 'getMetadataFor: garbage and non-episode URLs -> {}' => sub {
	resetStubs();
	for my $url ( undef, '', 'garbage', 'rtrfm://live', 'rtrfm://episode/', 'rtrfm://episode/saturdayjazz/2026-02-30', $MP3 ) {
		my $meta = $PH->getMetadataFor( undef, $url );
		is_deeply( $meta, {}, 'returns {} for ' . ( defined $url ? "'$url'" : 'undef' ) );
	}
	is( scalar( requests() ), 0, 'no HTTP requests' );
};

subtest 'getIcon: station icon' => sub {
	is( $PH->getIcon('rtrfm://episode/saturdayjazz/2026-09-19'), ICON, 'episode URL' );
	is( $PH->getIcon(undef), ICON, 'no URL' );
};

done_testing();

# ---- fakes for Slim::Schema::RemoteTrack, Slim::Player::Song and the (master) client ----

package FakeTrack;

sub new { my ( $class, %args ) = @_; return bless {%args}, $class }

sub url   { my $self = shift; $self->{url}   = shift if @_; return $self->{url} }
sub title { my $self = shift; $self->{title} = shift if @_; return $self->{title} }

package FakeMaster;

sub new { return bless {}, shift }
sub id  { '00:00:00:00:00:01' }

sub currentPlaylistUpdateTime {
	my $self = shift;
	$self->{updateTime} = shift if @_;
	return $self->{updateTime};
}

package FakeSong;

# Like Slim::Player::Song: streamUrl starts as the playlist track's URL.
sub new {
	my ( $class, $url ) = @_;
	return bless { track => FakeTrack->new( url => $url, title => $url ), streamUrl => $url, master => FakeMaster->new }, $class;
}

sub track  { $_[0]->{track} }
sub master { $_[0]->{master} }

sub streamUrl {
	my $self = shift;
	$self->{streamUrl} = shift if @_;
	return $self->{streamUrl};
}
