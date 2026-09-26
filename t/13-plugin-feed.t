#!/usr/bin/perl
# Plugins::RTRFM::Plugin: registration (Radio menu, tag, display name, log category), the frozen
# hook API (init order Live -> OnDemand; feed = Live items then OnDemand items, one callback),
# and the failure handling: dying hooks, bad callback values, double callbacks.

use strict;
use warnings;

use RTRFMTest qw(:all);
use Test::More;

use Slim::Utils::Strings qw(string);

use Plugins::RTRFM::Plugin;
use Plugins::RTRFM::Live;
use Plugins::RTRFM::OnDemand;

my $origLive     = \&Plugins::RTRFM::Live::menuItems;
my $origOnDemand = \&Plugins::RTRFM::OnDemand::menuItems;

my $A = { name => 'A', type => 'audio', url => 'https://example.test/a' };
my $B = { name => 'B', type => 'audio', url => 'https://example.test/b' };
my $C = { name => 'C', type => 'link',  url => 'https://example.test/c' };

my $ERROR_TEXT = string('PLUGIN_RTRFM_ERROR');
my $ERROR_ITEM = { name => $ERROR_TEXT, type => 'text' };

# Build the top-level feed with the given hook implementations (defaults: the real hooks).
# Returns the collector that received the feed callback.
sub feed {
	my %impl = @_;

	my $live     = exists $impl{live}     ? $impl{live}     : $origLive;
	my $onDemand = exists $impl{ondemand} ? $impl{ondemand} : $origOnDemand;

	# an undef implementation removes the method, as if the module had failed to load
	no warnings 'redefine';
	local *Plugins::RTRFM::Live::menuItems;
	local *Plugins::RTRFM::OnDemand::menuItems;
	*Plugins::RTRFM::Live::menuItems     = $live     if $live;
	*Plugins::RTRFM::OnDemand::menuItems = $onDemand if $onDemand;

	my $c = collector();
	Plugins::RTRFM::Plugin::toplevel( undef, $c->cb, { params => {} } );
	return $c;
}

sub items_of {
	my $c = shift;
	my ($result) = $c->args(0);
	return ref $result eq 'HASH' ? $result->{items} : undef;
}

sub errors_logged {
	return grep { $_->{level} eq 'ERROR' && $_->{category} eq 'plugin.rtrfm' } Slim::Utils::Log->messages;
}

sub sync_hook  { my @items = @_; return sub { $_[2]->( [@items] ) } }
sub later_hook { my ( $delay, @items ) = @_; return sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + $delay, sub { $cb->( [@items] ) } ) } }

ok( defined $ERROR_TEXT && length $ERROR_TEXT, 'PLUGIN_RTRFM_ERROR has text' );

subtest 'registration' => sub {
	resetStubs();

	my @initOrder;
	{
		no warnings 'redefine';
		local *Plugins::RTRFM::Live::init     = sub { push @initOrder, $_[0] };
		local *Plugins::RTRFM::OnDemand::init = sub { push @initOrder, $_[0] };
		Plugins::RTRFM::Plugin->initPlugin();
	}

	is_deeply( \@initOrder, [qw(Plugins::RTRFM::Live Plugins::RTRFM::OnDemand)], 'init called once each, Live first, as class methods' );

	my $args = $Slim::Plugin::OPMLBased::INIT_ARGS{'Plugins::RTRFM::Plugin'};
	ok( $args, 'OPMLBased initPlugin called' );
	is( $args->{feed}, \&Plugins::RTRFM::Plugin::toplevel, 'feed is the toplevel coderef' );
	is( $args->{tag},  'rtrfm',  'tag rtrfm (CLI command ["rtrfm","items",...])' );
	is( $args->{menu}, 'radios', 'Radio menu' );
	ok( exists $args->{is_app} && !$args->{is_app}, 'is_app => 0 (not My Apps)' );
	like( $args->{weight}, qr/^\d+$/, 'has a weight' );
	is( Plugins::RTRFM::Plugin->menu, 'radios', 'menu class method' );
	is( Plugins::RTRFM::Plugin->tag,  'rtrfm',  'tag class method' );

	is( Plugins::RTRFM::Plugin->getDisplayName, 'PLUGIN_RTRFM', 'display name token' );
	is( string( Plugins::RTRFM::Plugin->getDisplayName ), 'RTRFM 92.1', 'display name text' );
	is( Plugins::RTRFM::Plugin->playerMenu, 'RADIO', 'player menu RADIO' );

	is_deeply( $Slim::Utils::Log::CATEGORIES{'plugin.rtrfm'}, { defaultLevel => 'WARN', description => 'PLUGIN_RTRFM' }, 'log category plugin.rtrfm, default WARN' );
	is( scalar errors_logged(), 0, 'no errors logged' );
};

subtest 'OnDemand->init registers the rtrfm:// scheme (real hooks via initPlugin)' => sub {
	resetStubs();
	is( Slim::Player::ProtocolHandlers->handlerForProtocol('rtrfm'), undef, 'not registered before init' );

	Plugins::RTRFM::Plugin->initPlugin();

	is( Slim::Player::ProtocolHandlers->handlerForProtocol('rtrfm'), 'Plugins::RTRFM::ProtocolHandler', 'rtrfm => Plugins::RTRFM::ProtocolHandler' );
	is( Slim::Player::ProtocolHandlers->handlerForURL('rtrfm://episode/saturdayjazz/2026-09-19'), 'Plugins::RTRFM::ProtocolHandler', 'episode URLs resolve to the handler' );
	is( scalar errors_logged(), 0, 'no errors logged' );
};

subtest 'a failing init is logged and the plugin still loads' => sub {
	resetStubs();
	%Slim::Plugin::OPMLBased::INIT_ARGS = ();

	my $onDemandInit = 0;
	{
		no warnings 'redefine';
		local *Plugins::RTRFM::Live::init     = sub { die "live init exploded\n" };
		local *Plugins::RTRFM::OnDemand::init = sub { $onDemandInit++ };
		ok( eval { Plugins::RTRFM::Plugin->initPlugin(); 1 }, 'initPlugin does not die' ) or diag $@;
	}

	is( $onDemandInit, 1, 'OnDemand->init still called' );
	ok( $Slim::Plugin::OPMLBased::INIT_ARGS{'Plugins::RTRFM::Plugin'}, 'menu still registered' );
	ok( ( grep { $_->{message} =~ /Plugins::RTRFM::Live.*live init exploded/ } errors_logged() ), 'error logged with the hook name and reason' );
};

subtest 'default feed: the "RTRFM 92.1 Live" item' => sub {
	resetStubs();
	my $c = feed();

	is( $c->count, 1, 'callback called once' );
	is_deeply(
		items_of($c),
		[ {
			name      => 'RTRFM 92.1 Live',
			type      => 'audio',
			url       => 'https://live.rtrfm.com.au/stream1',
			on_select => 'play',
			image     => 'plugins/RTRFM/html/images/icon.png',
		} ],
		'one playable live item (OnDemand contributes nothing yet)'
	);
};

subtest 'feed order: Live items then OnDemand items' => sub {
	resetStubs();
	my $c = feed( live => sync_hook( $A, $B ), ondemand => sync_hook($C) );
	is( $c->count, 1, 'callback called once' );
	is_deeply( items_of($c), [ $A, $B, $C ], 'concatenated, live first' );

	my @hookArgs;
	$c = feed(
		live     => sub { push @hookArgs, [ 'live',     @_[ 0, 1, 3 ] ]; $_[2]->([]) },
		ondemand => sub { push @hookArgs, [ 'ondemand', @_[ 0, 1, 3 ] ]; $_[2]->([]) },
	);
	is_deeply( [ map { $_->[0] } @hookArgs ], [qw(live ondemand)], 'Live->menuItems called before OnDemand->menuItems' );
	is( $hookArgs[0][1], 'Plugins::RTRFM::Live', 'called as a class method' );
	is_deeply( $hookArgs[0][3], { params => {} }, '$args passed through' );
	is_deeply( items_of($c), [], 'empty hooks give an empty menu' );
};

subtest 'asynchronous hooks: one callback after both have answered, order kept' => sub {
	resetStubs();
	setTime(1_790_000_000);

	my $c = feed( live => later_hook( 2, $A ), ondemand => sync_hook($C) );
	is( $c->count, 0, 'no callback while Live is still loading' );
	advanceTime(1);
	is( $c->count, 0, 'still waiting' );
	advanceTime(1);
	is( $c->count, 1, 'callback once Live answers' );
	is_deeply( items_of($c), [ $A, $C ], 'live first even though it answered last' );

	$c = feed( live => sync_hook($A), ondemand => later_hook( 5, $B, $C ) );
	is( $c->count, 0, 'waiting for OnDemand' );
	advanceTime(5);
	is( $c->count, 1, 'callback once OnDemand answers' );
	is_deeply( items_of($c), [ $A, $B, $C ], 'order kept' );

	clearTime();
};

subtest 'a dying hook becomes one error item; the feed still returns' => sub {
	resetStubs();
	my $c = feed( live => sub { die "live broke\n" }, ondemand => sync_hook($C) );
	is( $c->count, 1, 'Live dies: callback once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'Live dies: error item, then OnDemand items' );
	ok( ( grep { $_->{message} =~ /Plugins::RTRFM::Live.*live broke/ } errors_logged() ), 'error logged' );

	$c = feed( live => sync_hook( $A, $B ), ondemand => sub { die "ondemand broke\n" } );
	is( $c->count, 1, 'OnDemand dies: callback once' );
	is_deeply( items_of($c), [ $A, $B, $ERROR_ITEM ], 'OnDemand dies: live items, then error item' );

	$c = feed( live => sub { die "x\n" }, ondemand => sub { die "y\n" } );
	is( $c->count, 1, 'both die: callback once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $ERROR_ITEM ], 'both die: one error item each' );

	$c = feed( live => undef );    # e.g. Live.pm failed to compile: no menuItems method
	is( $c->count, 1, 'missing hook method: callback once' );
	is_deeply( items_of($c), [$ERROR_ITEM], 'missing hook method: error item' );
};

subtest 'a hook calling back with undef or a non-array becomes an error item' => sub {
	for my $bad ( [ 'undef', undef ], [ 'hash ref', { items => [$A] } ], [ 'string', 'oops' ], [ 'item hash', $A ] ) {
		resetStubs();
		my ( $label, $value ) = @$bad;

		my $c = feed( live => sub { $_[2]->($value) }, ondemand => sync_hook($C) );
		is( $c->count, 1, "Live calls back with $label: callback once" );
		is_deeply( items_of($c), [ $ERROR_ITEM, $C ], "Live calls back with $label: error item" );
		ok( scalar errors_logged(), "Live calls back with $label: error logged" );

		$c = feed( live => sync_hook($A), ondemand => sub { $_[2]->($value) } );
		is_deeply( items_of($c), [ $A, $ERROR_ITEM ], "OnDemand calls back with $label: error item" );
	}

	resetStubs();
	my $c = feed( live => sub { $_[2]->() } );
	is_deeply( items_of($c), [$ERROR_ITEM], 'callback with no arguments: error item' );
};

subtest 'double callbacks are ignored' => sub {
	resetStubs();
	my $c = feed( live => sub { $_[2]->( [$A] ); $_[2]->( [$B] ) }, ondemand => sync_hook($C) );
	is( $c->count, 1, 'synchronous double call: callback once' );
	is_deeply( items_of($c), [ $A, $C ], 'first answer wins' );
	ok( ( grep { $_->{level} eq 'WARN' && $_->{message} =~ /more than once/ } Slim::Utils::Log->messages ), 'warning logged' );

	resetStubs();
	setTime(1_790_000_000);
	$c = feed(
		live     => sub { my $cb = $_[2]; $cb->( [$A] ); Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->( [$B] ) } ) },
		ondemand => sync_hook($C),
	);
	is( $c->count, 1, 'feed answered' );
	advanceTime(2);
	is( $c->count, 1, 'late second call after the feed answered: still one callback' );
	is_deeply( items_of($c), [ $A, $C ], 'items unchanged' );

	$c = feed( live => sub { $_[2]->( [$A] ); die "after callback\n" }, ondemand => sync_hook($C) );
	is( $c->count, 1, 'hook calls back then dies: callback once' );
	is_deeply( items_of($c), [ $A, $C ], 'hook calls back then dies: its items are kept' );

	$c = feed(
		live     => sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + 1, sub { $cb->( [$B] ) } ); die "died after scheduling\n" },
		ondemand => sync_hook($C),
	);
	is( $c->count, 1, 'hook dies with a callback pending: feed answers at once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'error item for the dead hook' );
	advanceTime(2);
	is( $c->count, 1, 'the late callback from the dead hook is ignored' );

	clearTime();
};

done_testing();
