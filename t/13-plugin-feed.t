#!/usr/bin/perl
# Plugins::RTRFM::Plugin: registration (Radio menu, tag, display name, log category), the frozen
# hook API (init order Live -> OnDemand; feed = Live items then OnDemand items, one callback),
# and the failure handling: dying hooks, bad callback values, double callbacks, hooks that never
# call back (timeout), and errors in the feed callback itself.

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
# Returns the collector that received the feed callback (unless cb => \&code replaces it).
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
	Plugins::RTRFM::Plugin::toplevel( undef, $impl{cb} || $c->cb, { params => {} } );
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

sub warnings_logged {
	return grep { $_->{level} eq 'WARN' && $_->{category} eq 'plugin.rtrfm' } Slim::Utils::Log->messages;
}

sub sync_hook  { my @items = @_; return sub { $_[2]->( [@items] ) } }
sub never_hook { return sub { } }
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

subtest 'default feed: the live items come first' => sub {
	resetStubs();
	my $c = feed();

	is( $c->count, 1, 'callback called once' );

	# the live items in detail: t/21-live-menu.t
	my @live = @{ items_of($c) || [] }[ 0, 1 ];
	is_deeply(
		[ map { $_ && { name => $_->{name}, type => $_->{type}, url => $_->{url} } } @live ],
		[
			{ name => 'RTRFM 92.1 Live',    type => 'audio', url => 'https://live.rtrfm.com.au/stream1' },
			{ name => 'RTRFM Infinite Mix', type => 'audio', url => 'https://live.rtrfm.com.au/stream2' },
		],
		'"RTRFM 92.1 Live" then "RTRFM Infinite Mix"'
	);

	# then the OnDemand items: the "Programs" link
	is_deeply(
		( items_of($c) || [] )->[2],
		{
			name  => 'Programs',
			type  => 'link',
			url   => \&Plugins::RTRFM::OnDemand::_programsFeed,
			image => 'plugins/RTRFM/html/images/icon.png',
		},
		'then the OnDemand "Programs" link'
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

	$c = feed( live => undef, ondemand => sync_hook() );    # e.g. Live.pm failed to compile: no menuItems method
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
	my $c = feed( live => sub { $_[2]->() }, ondemand => sync_hook() );
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

my $T0      = 1_790_000_000;
my $TIMEOUT = Plugins::RTRFM::Plugin::HOOK_TIMEOUT();

subtest 'a hook that never calls back: error item after HOOK_TIMEOUT, the feed still returns' => sub {
	is( $TIMEOUT, 25, 'HOOK_TIMEOUT is 25 s' );
	cmp_ok( $TIMEOUT, '<', 35, 'below the 35 s XMLBrowser feed timeout' );

	resetStubs();
	setTime($T0);
	my $c = feed( live => never_hook(), ondemand => sync_hook($C) );
	is( $c->count, 0, 'Live silent: no callback yet' );
	is_deeply( [ map { $_->when } Slim::Utils::Timers->pending ], [ $T0 + $TIMEOUT ], 'one timeout timer, HOOK_TIMEOUT from now' );
	advanceTime( $TIMEOUT - 1 );
	is( $c->count, 0, 'Live silent: still waiting 1 s before the timeout' );
	advanceTime(1);
	is( $c->count, 1, 'Live silent: callback once the timer fires' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'Live silent: error item, then OnDemand items' );
	ok( ( grep { $_->{message} =~ /Plugins::RTRFM::Live->menuItems did not call back within 25 s/ } errors_logged() ), 'timeout logged with the hook name' );
	is( scalar Slim::Utils::Timers->pending, 0, 'no timers left' );

	resetStubs();
	$c = feed( live => sync_hook( $A, $B ), ondemand => never_hook() );
	advanceTime($TIMEOUT);
	is( $c->count, 1, 'OnDemand silent: callback once' );
	is_deeply( items_of($c), [ $A, $B, $ERROR_ITEM ], 'OnDemand silent: live items, then error item' );

	resetStubs();
	$c = feed( live => never_hook(), ondemand => never_hook() );
	advanceTime($TIMEOUT);
	is( $c->count, 1, 'both silent: callback once' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $ERROR_ITEM ], 'both silent: one error item each' );
	is( scalar errors_logged(), 2, 'both silent: one error per hook' );

	resetStubs();
	$c = feed( live => later_hook( 3, $A ), ondemand => never_hook() );
	advanceTime(3);
	is( $c->count, 0, 'Live answered, OnDemand silent: still waiting' );
	advanceTime( $TIMEOUT - 3 );
	is( $c->count, 1, 'Live answered, OnDemand silent: callback at the timeout' );
	is_deeply( items_of($c), [ $A, $ERROR_ITEM ], 'Live answered, OnDemand silent: order kept' );

	clearTime();
};

subtest 'an answer after the timeout is ignored' => sub {
	resetStubs();
	setTime($T0);

	my $c = feed( live => later_hook( $TIMEOUT + 5, $A ), ondemand => sync_hook($C) );
	advanceTime($TIMEOUT);
	is( $c->count, 1, 'feed answered at the timeout' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'error item for the slow hook' );

	advanceTime(5);
	is( $c->count, 1, 'late answer: still one callback' );
	is_deeply( items_of($c), [ $ERROR_ITEM, $C ], 'late answer: items unchanged' );
	ok( ( grep { $_->{message} =~ /Plugins::RTRFM::Live->menuItems called back after the 25 s timeout/ } warnings_logged() ), 'late answer: warning logged' );

	resetStubs();
	$c = feed( live => sync_hook($A), ondemand => sub { my $cb = $_[2]; Slim::Utils::Timers::setTimer( undef, time() + $TIMEOUT + 1, sub { $cb->( [$B] ); $cb->( [$C] ) } ) } );
	advanceTime( $TIMEOUT + 1 );
	is( $c->count, 1, 'late answer given twice: still one callback' );
	is_deeply( items_of($c), [ $A, $ERROR_ITEM ], 'late answer given twice: items unchanged' );

	clearTime();
};

subtest 'the timeout timer is cleared when every hook answers in time' => sub {
	resetStubs();
	setTime($T0);

	my $c = feed( live => sync_hook($A), ondemand => sync_hook($C) );
	is( $c->count, 1, 'synchronous answers: callback at once' );
	is( scalar Slim::Utils::Timers->pending, 0, 'synchronous answers: no timer set' );

	$c = feed( live => later_hook( 2, $A ), ondemand => later_hook( 3, $C ) );
	is( scalar( grep { $_->when == $T0 + $TIMEOUT } Slim::Utils::Timers->pending ), 1, 'asynchronous answers: timeout timer pending' );
	advanceTime(3);
	is( $c->count, 1, 'asynchronous answers: callback once both answered' );
	is_deeply( items_of($c), [ $A, $C ], 'asynchronous answers: order kept' );
	is( scalar Slim::Utils::Timers->pending, 0, 'asynchronous answers: timeout timer killed' );

	advanceTime( $TIMEOUT * 2 );
	is( $c->count, 1, 'nothing fires later' );
	is( scalar errors_logged(), 0, 'no errors logged' );

	clearTime();
};

subtest 'an error in the feed callback is not blamed on a hook' => sub {
	resetStubs();

	my $calls = 0;
	my $dyingCb = sub { $calls++; die "feed callback broke\n" };

	ok( !eval { feed( live => sync_hook($A), ondemand => sync_hook($C), cb => $dyingCb ); 1 }, 'synchronous hooks: the error reaches the caller' );
	like( $@, qr/feed callback broke/, 'synchronous hooks: with its message' );
	is( $calls, 1, 'synchronous hooks: callback called once' );
	is( scalar errors_logged(), 0, 'synchronous hooks: no hook failure logged' );

	resetStubs();
	setTime($T0);
	$calls = 0;
	feed( live => later_hook( 1, $A ), ondemand => sync_hook($C), cb => $dyingCb );
	ok( !eval { advanceTime(1); 1 }, 'asynchronous hook: the error reaches the caller of the hook callback' );
	like( $@, qr/feed callback broke/, 'asynchronous hook: with its message' );
	is( $calls, 1, 'asynchronous hook: callback called once' );
	is( scalar errors_logged(), 0, 'asynchronous hook: no hook failure logged' );
	is( scalar Slim::Utils::Timers->pending, 0, 'asynchronous hook: timeout timer killed' );

	clearTime();
};

done_testing();
