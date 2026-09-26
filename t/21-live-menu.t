#!/usr/bin/perl
# Plugins::RTRFM::Live->menuItems: the two live items (exact keys and values), the callback
# called exactly once on every path (fresh cache, fetch success, 3 s deadline with a late
# response, fetch errors with a still-valid or expired lastGood, a dying item builder, no
# player), stream URL selection, and no network access or timer at init.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use Slim::Utils::Log;

use Plugins::RTRFM::Live;
use Plugins::RTRFM::NowPlaying;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $NP      = 'Plugins::RTRFM::NowPlaying';
my $URL     = 'https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show';
my $STREAM1 = 'https://live.rtrfm.com.au/stream1';
my $STREAM2 = 'https://live.rtrfm.com.au/stream2';
my $ICON    = 'plugins/RTRFM/html/images/icon.png';
my $NOW     = 1_790_393_400;    # 2026-09-26 11:30 AWST
my $CURRENT_END = 1_790_398_800;

my $ON_AIR    = "On air: Global Rhythm Pot \x{B7} 11.00am - 1.00pm";
my $NEXT_LINE = "Next: Homegrown \x{B7} 1.00pm - 3.00pm";
my $SHOW_DESC = 'A sonic journey around the world, offering stopovers in funk, beats and folk traditions.';
my $MIX_DESC  = "Non-stop mixes on RTRFM's second stream";

sub live_item {
	my ( $url, %extra ) = @_;
	return {
		name            => 'RTRFM 92.1 Live',
		line1           => 'RTRFM 92.1 Live',
		favorites_title => 'RTRFM 92.1 Live',
		type            => 'audio',
		on_select       => 'play',
		url             => $url,
		favorites_url   => $url,
		image           => $ICON,
		favorites_icon  => $ICON,
		%extra,
	};
}

my $LIVE        = live_item( $STREAM1, line2 => $ON_AIR, description => "$ON_AIR\n$SHOW_DESC\n$NEXT_LINE" );
my $STATIC_LIVE = live_item($STREAM1);
my $MIX = {
	name            => 'RTRFM Infinite Mix',
	line1           => 'RTRFM Infinite Mix',
	favorites_title => 'RTRFM Infinite Mix',
	line2           => $MIX_DESC,
	description     => $MIX_DESC,
	type            => 'audio',
	on_select       => 'play',
	url             => $STREAM2,
	favorites_url   => $STREAM2,
	image           => $ICON,
	favorites_icon  => $ICON,
};

my $CLIENT = RTRFMTest::MenuClient->new('00:00:00:00:00:01');

sub fresh_start {
	resetStubs();
	Plugins::RTRFM::NowPlaying::_reset();
	setTime( shift || $NOW );
}

sub serve { route( $URL, @_ ) }

# fill the NowPlaying cache (and lastGood) from a fixture, then forget the request and routes
sub prime {
	my $fixture = shift || 'now-next-normal.json';
	serve( file => "live/$fixture" );
	$NP->fetch( sub { } );
	Slim::Networking::SimpleAsyncHTTP->reset;
	return $NP->lastGood;
}

sub menu {
	my $client = @_ ? shift : $CLIENT;
	my $c = collector();
	Plugins::RTRFM::Live->menuItems( $client, $c->cb, { params => {} } );
	return $c;
}

sub items_of { ( $_[0]->args(0) )[0] }

sub errors_logged { grep { $_->{category} eq 'plugin.rtrfm' } Slim::Utils::Log->messages( level => 'ERROR' ) }

# after everything else has happened: still exactly one callback, no timers left behind
sub once_ok {
	my ( $c, $name ) = @_;
	advanceTime(30);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, "$name: callback called exactly once" );
	is( scalar Slim::Utils::Timers->pending, 0, "$name: no timers left" );
}

subtest 'strings' => sub {
	is( Slim::Utils::Strings::string( 'PLUGIN_RTRFM_ON_AIR', 'X' ), 'On air: X', 'PLUGIN_RTRFM_ON_AIR' );
	is( Slim::Utils::Strings::string( 'PLUGIN_RTRFM_NEXT', 'Y' ),   'Next: Y',   'PLUGIN_RTRFM_NEXT' );
	is( Slim::Utils::Strings::string('PLUGIN_RTRFM_INFINITE_MIX_DESC'), $MIX_DESC, 'PLUGIN_RTRFM_INFINITE_MIX_DESC' );
};

subtest 'init: no network, no timer' => sub {
	fresh_start();
	Plugins::RTRFM::Live->init();
	is( scalar requests(), 0, 'no request' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timer' );
	clearTime();
};

subtest 'fresh cache: Live then Infinite Mix, exact keys and values, no request' => sub {
	fresh_start();
	prime();

	my $c = menu();
	is( $c->count, 1, 'answered synchronously' );
	is_deeply( items_of($c), [ $LIVE, $MIX ], 'exactly the two items' );
	is( scalar requests(), 0, 'no request' );
	once_ok( $c, 'fresh cache' );
	clearTime();
};

subtest 'fetch succeeds' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json' );

	my $c = menu();
	is( $c->count, 1, 'immediate response: answered at once' );
	is_deeply( items_of($c), [ $LIVE, $MIX ], 'immediate response: items with the on-air line' );
	is( scalar requests(), 1, 'one request' );
	once_ok( $c, 'immediate response' );

	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );
	$c = menu();
	is( $c->count, 0, 'slow response: waiting' );
	is_deeply( [ map { $_->when } Slim::Utils::Timers->pending ], [ $NOW + 3 ], 'slow response: 3 s deadline timer' );
	advanceTime(2);
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is( $c->count, 1, 'slow response inside 3 s: answered' );
	is_deeply( items_of($c), [ $LIVE, $MIX ], 'slow response inside 3 s: items with the on-air line' );
	is( scalar Slim::Utils::Timers->pending, 0, 'slow response inside 3 s: deadline timer killed' );
	once_ok( $c, 'slow response inside 3 s' );
	clearTime();
};

subtest 'fetch deferred past 3 s: static items at the deadline, late response fills the cache' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );

	my $c = menu();
	advanceTime(2.9);
	is( $c->count, 0, 'nothing at 2.9 s' );
	advanceTime(0.1);
	is( $c->count, 1, 'answered at 3 s' );
	is_deeply( items_of($c), [ $STATIC_LIVE, $MIX ], 'static items (no line2, no description on Live)' );

	is( Slim::Networking::SimpleAsyncHTTP->completeDeferred, 1, 'the response arrives late' );
	is( $c->count, 1, 'no second callback' );
	ok( $NP->cached, 'the late response filled the cache' );
	is( $NP->cached->{current}{name}, 'Global Rhythm Pot', 'with the parsed data' );
	once_ok( $c, 'deadline' );

	my $c2 = menu();
	is_deeply( items_of($c2), [ $LIVE, $MIX ], 'the next menu request uses it' );
	is( scalar requests(), 1, 'without a new request' );
	clearTime();
};

subtest 'fetch error with a still-valid lastGood: on-air line kept' => sub {
	fresh_start();
	prime();
	advanceTime(900);    # cache expired, show still on air until 13:00
	serve( code => 500, content => 'oops' );

	my $c = menu();
	is( $c->count, 1, 'answered' );
	is_deeply( items_of($c), [ $LIVE, $MIX ], 'items from lastGood' );
	is( scalar requests(), 1, 'one request' );
	once_ok( $c, 'error with valid lastGood' );

	fresh_start();
	prime();
	advanceTime(900);
	serve( file => 'live/now-next-normal.json', defer => 1 );
	$c = menu();
	advanceTime(3);
	is_deeply( items_of($c), [ $LIVE, $MIX ], 'deadline with a still-valid lastGood: items from lastGood' );
	once_ok( $c, 'deadline with valid lastGood' );
	clearTime();
};

subtest 'fetch error with an expired lastGood: static items' => sub {
	fresh_start();
	prime();
	setTime($CURRENT_END);    # the show in lastGood ended now
	serve( code => 500, content => 'oops' );

	my $c = menu();
	is( $c->count, 1, 'answered' );
	is_deeply( items_of($c), [ $STATIC_LIVE, $MIX ], 'static items' );
	once_ok( $c, 'error with expired lastGood' );

	fresh_start();
	serve( error => 'Timed out waiting for data' );
	$c = menu();
	is_deeply( items_of($c), [ $STATIC_LIVE, $MIX ], 'no lastGood at all: static items' );

	# negative cache: the next request within 20 s answers at once without a request
	advanceTime(10);
	my $c2 = menu();
	is( scalar requests(), 1, 'within 20 s of the failure: no new request' );
	is( $c2->count, 1, 'within 20 s of the failure: answered at once' );
	is_deeply( items_of($c2), [ $STATIC_LIVE, $MIX ], 'within 20 s of the failure: static items' );
	once_ok( $c,  'error without lastGood' );
	once_ok( $c2, 'negative cache' );
	clearTime();
};

subtest 'the item builder dies: static items, error logged' => sub {
	fresh_start();
	prime();

	my $c;
	{
		no warnings 'redefine';
		local *Plugins::RTRFM::NowPlaying::showLabel = sub { die "label broke\n" };
		$c = menu();
	}
	is( $c->count, 1, 'answered' );
	is_deeply( items_of($c), [ $STATIC_LIVE, $MIX ], 'static items' );
	ok( ( grep { $_->{message} =~ /label broke/ } errors_logged() ), 'error logged' );
	once_ok( $c, 'builder dies' );

	fresh_start();
	{
		no warnings 'redefine';
		local *Plugins::RTRFM::NowPlaying::fetch = sub { die "fetch broke\n" };
		$c = menu();
	}
	is( $c->count, 1, 'fetch dies: answered' );
	is_deeply( items_of($c), [ $STATIC_LIVE, $MIX ], 'fetch dies: static items' );
	ok( ( grep { $_->{message} =~ /fetch broke/ } errors_logged() ), 'fetch dies: error logged' );
	once_ok( $c, 'fetch dies' );
	clearTime();
};

subtest '$client undef' => sub {
	fresh_start();
	prime();
	my $c = menu(undef);
	is_deeply( items_of($c), [ $LIVE, $MIX ], 'fresh cache: full items' );
	once_ok( $c, 'undef client, fresh cache' );

	fresh_start();
	serve( code => 403, content => 'Forbidden' );
	$c = menu(undef);
	is_deeply( items_of($c), [ $STATIC_LIVE, $MIX ], 'failure: static items' );
	once_ok( $c, 'undef client, failure' );
	clearTime();
};

subtest 'stream URLs' => sub {
	fresh_start();
	prime('now-next-stream-url-changed.json');
	my $items = items_of( menu() );
	is( $items->[0]{url},           'https://live.rtrfm.com.au/stream1-hq', 'changed stream_url: Live url' );
	is( $items->[0]{favorites_url}, 'https://live.rtrfm.com.au/stream1-hq', 'changed stream_url: favourites url' );
	is( $items->[1]{url},           $STREAM2, 'changed stream_url: Infinite Mix url' );

	fresh_start();
	prime('now-next-foreign-stream-url.json');
	$items = items_of( menu() );
	is( $items->[0]{url},           $STREAM1, 'foreign stream_url: Live url is STREAM1_URL' );
	is( $items->[0]{favorites_url}, $STREAM1, 'foreign stream_url: favourites url' );
	is( $items->[0]{line2},         $ON_AIR,  'foreign stream_url: show data still used' );
	is( $items->[1]{url},           $STREAM2, 'foreign stream_url: Infinite Mix url' );

	fresh_start();
	serve( code => 500, content => 'oops' );
	$items = items_of( menu() );
	is( $items->[0]{url}, $STREAM1, 'failure: Live url is STREAM1_URL' );
	is( $items->[1]{url}, $STREAM2, 'failure: Infinite Mix url' );
	clearTime();
};

subtest 'missing current or next show' => sub {
	fresh_start();
	prime('now-next-no-current.json');
	my $items = items_of( menu() );
	is_deeply( $items->[0], live_item( $STREAM1, description => $NEXT_LINE ), 'no current show: no line2, description is the Next line' );

	fresh_start();
	prime('now-next-no-next.json');
	$items = items_of( menu() );
	is_deeply( $items->[0], live_item( $STREAM1, line2 => $ON_AIR, description => "$ON_AIR\n$SHOW_DESC" ), 'no next show: no Next line' );
	is_deeply( $items->[1], $MIX, 'Infinite Mix unchanged' );
	clearTime();
};

subtest 'several menu requests while one fetch is in flight' => sub {
	fresh_start();
	serve( file => 'live/now-next-normal.json', defer => 1 );

	my @c = map { menu( RTRFMTest::MenuClient->new("player$_") ) } 1 .. 3;
	is( scalar requests(), 1, 'one request' );
	Slim::Networking::SimpleAsyncHTTP->completeDeferred;
	is_deeply( [ map { $_->count } @c ], [ 1, 1, 1 ], 'each menu answered once' );
	is_deeply( items_of($_), [ $LIVE, $MIX ], 'with the on-air line' ) for @c;
	once_ok( $_, 'in flight' ) for @c;
	clearTime();
};

done_testing();

# A player whose string() works like LMS's Slim::Player::Client::string.
package RTRFMTest::MenuClient;

sub new { bless { id => $_[1] }, $_[0] }
sub id  { $_[0]->{id} }

sub string {
	my $self = shift;
	return Slim::Utils::Strings::string(@_);
}
