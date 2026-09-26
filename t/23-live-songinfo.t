#!/usr/bin/perl
# Plugins::RTRFM::LiveMetadata::trackInfo, the "Show info" song info entry registered with
# Slim::Menu::TrackInfo: undef for stream2, episodes, other URLs and without show data; for
# stream1 one item with the on-air show, its description and the next show.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use RTRFMTest::FakeClient;
use Test::More;

use Slim::Menu::TrackInfo;

use Plugins::RTRFM::Live;
use Plugins::RTRFM::LiveMetadata;
use Plugins::RTRFM::NowPlaying;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $URL        = 'https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show';
my $STREAM1    = 'https://live.rtrfm.com.au/stream1';
my $STREAM2    = 'https://live.rtrfm.com.au/stream2';
my $NOW        = 1_790_393_400;    # 2026-09-26 11:30 AWST
my $NEXT_START = 1_790_398_800;    # 13:00
my $NEXT_END   = 1_790_406_000;    # 15:00
my $DOT        = " \x{B7} ";

my $GRP_DESC       = 'A sonic journey around the world, offering stopovers in funk, beats and folk traditions.';
my $HOMEGROWN_DESC = 'Your local music love-in with live performances and interviews.';

my $CLIENT = RTRFMTest::FakeClient->new('00:00:00:00:00:01');

sub fresh_start {
	resetStubs();
	Plugins::RTRFM::NowPlaying::_reset();
	Plugins::RTRFM::LiveMetadata::_reset();
	setTime( shift || $NOW );
	Plugins::RTRFM::Live->init();
}

# fill NowPlaying's cache from a fixture
sub prime {
	route( $URL, file => 'live/' . shift );
	Plugins::RTRFM::NowPlaying->fetch( sub { } );
	Slim::Networking::SimpleAsyncHTTP->reset;
}

# call the registered TrackInfo provider as Slim::Menu::TrackInfo does
sub info_for {
	my $url  = shift;
	my $func = $Slim::Menu::TrackInfo::PROVIDERS{rtrfm_live_show}{func} or return 'not registered';
	return $func->( $CLIENT, $url, undef, {}, {}, undef );
}

subtest 'undef for stream2, episodes, other URLs and without show data' => sub {
	fresh_start();
	is( info_for($STREAM1), undef, 'stream1 with nothing cached: undef' );

	prime('now-next-normal.json');
	is( info_for($STREAM2), undef, 'stream2: undef' );
	is( info_for('rtrfm://episode/saturdayjazz/2026-09-19'), undef, 'episode: undef' );
	is( info_for('https://ice1.somafm.com/groovesalad-128-mp3'), undef, 'another station: undef' );
	is( info_for('https://live.rtrfm.com.au/stream3'), undef, 'another live path: undef' );
	is( scalar requests(), 0, 'no request' );
	clearTime();
};

subtest 'stream1: one "Show info" item with the on-air show, its description and the next show' => sub {
	fresh_start();
	prime('now-next-normal.json');

	my $expected = {
		name  => 'Show info',
		items => [
			{ type => 'text',     name => "On air: Global Rhythm Pot${DOT}11.00am - 1.00pm" },
			{ type => 'textarea', wrap => 1, name => $GRP_DESC },
			{ type => 'text',     name => "Next: Homegrown${DOT}1.00pm - 3.00pm" },
		],
	};
	is_deeply( info_for($STREAM1), $expected, 'exactly the expected item' );
	is_deeply( Plugins::RTRFM::LiveMetadata::trackInfo( $CLIENT, 'http://live.rtrfm.com.au:8000/stream1', undef, {}, {} ), $expected, 'http/:8000 variant: the same' );

	# last good data after the cache expired, while the show is on air
	setTime( $NEXT_START - 60 );
	ok( !Plugins::RTRFM::NowPlaying->cached, 'cache expired' );
	is_deeply( info_for($STREAM1), $expected, 'last good data: the same item' );

	# the same show picks as buildMeta: next promoted at the boundary, then nothing
	setTime( $NEXT_START + 10 );
	is_deeply(
		info_for($STREAM1),
		{ name => 'Show info', items => [ { type => 'text', name => "On air: Homegrown${DOT}1.00pm - 3.00pm" }, { type => 'textarea', wrap => 1, name => $HOMEGROWN_DESC } ] },
		'after next.start: the next show, no Next line'
	);
	setTime($NEXT_END);
	is( info_for($STREAM1), undef, 'no show on air any more: undef' );
	clearTime();
};

subtest 'stream1 without a next show or a description' => sub {
	fresh_start();
	prime('now-next-no-next.json');
	is_deeply(
		info_for($STREAM1),
		{ name => 'Show info', items => [ { type => 'text', name => "On air: Global Rhythm Pot${DOT}11.00am - 1.00pm" }, { type => 'textarea', wrap => 1, name => $GRP_DESC } ] },
		'no next show: no Next line'
	);

	fresh_start();
	prime('now-next-normal.json');
	my $info = Plugins::RTRFM::NowPlaying->lastGood;
	local $info->{current}{description} = undef;
	is_deeply(
		info_for($STREAM1),
		{ name => 'Show info', items => [ { type => 'text', name => "On air: Global Rhythm Pot${DOT}11.00am - 1.00pm" }, { type => 'text', name => "Next: Homegrown${DOT}1.00pm - 3.00pm" } ] },
		'no description: no textarea'
	);
	clearTime();
};

done_testing();
