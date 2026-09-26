#!/usr/bin/perl
# Plugins::RTRFM::EpisodeWindow and the episode list built from it (O6): weekly slots inferred
# from Airnet's episode starts (weekly, Mon-Fri, after-midnight, irregular shows), the 28-day
# window of Airnet and synthesised episodes (edges, today and the end + 10 min rule, Airnet wins
# on a date, the synthesised hash shape), the rzz availability check (hide / keep / flag, at most
# 4 in flight, cache TTLs, the time budget, shared checks, the candidate cap, an open's state is
# freed once it has called back, an open's own checks go before leftover background checks), and
# OnDemand::_episodesFeed on top of it (items from _episodeItem, metadata writes, empty and
# error items, exactly one callback).
#
# Fixtures: t/data/ondemand/episodes-{drivetime,saturdayjazz,uplate,allcity}.json (Airnet,
# recorded 2026-09-26, see t/32-airnet.t) and episodes-irregular.json (synthetic: seven
# episodes, no weekday/time seen twice).

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use POSIX ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;
use Slim::Utils::Timers;

use Plugins::RTRFM::Airnet;
use Plugins::RTRFM::EpisodeWindow;
use Plugins::RTRFM::OnDemand;
use Plugins::RTRFM::Restream;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $BASE = Plugins::RTRFM::Util::AIRNET_BASE;
my $ICON = Plugins::RTRFM::Util::ICON;

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $NOW = timegm( 0, 40, 3, 26, 8, 2026 );

my $ENDASH = "\x{2013}";
my $MIDDOT = "\x{B7}";

my $NO_EPISODES = { name => 'No episodes available in the last 28 days', type => 'text' };
my $LOAD_FAILED = { name => "Couldn't load from RTRFM $ENDASH please try again later", type => 'text' };
my $UNKNOWN     = " $MIDDOT Availability unknown";

my $DRIVETIME     = { slug => 'drivetime',    name => 'Drivetime',     image => undef };
my $SATURDAY_JAZZ = { slug => 'saturdayjazz', name => 'Saturday Jazz', image => undef };
my $UP_LATE       = { slug => 'uplate',       name => 'Up Late',       image => undef };

my $MP3 = { url => 'https://restreams.rtrfm.com.au/shows/x_2026-09-19.mp3?st=abc&e=1790391804' };

my $FEED = \&Plugins::RTRFM::OnDemand::_episodesFeed;

# Perth date/time -> epoch
sub perth { Plugins::RTRFM::Util::parsePerthDateTime(shift) }

sub routeAirnet {
	route( "$BASE/programs/$_/episodes", file => "ondemand/episodes-$_.json" ) for qw(drivetime saturdayjazz uplate allcity irregular);
	route( "$BASE/programs/understorey/episodes", content => '[]' );
	route( "$BASE/programs/nosuch/episodes", code => 500 );
}

# Airnet::episodes for $slug from the fixture routes.
sub airnet {
	my $slug = shift;
	my $c    = collector();
	Plugins::RTRFM::Airnet::episodes( $slug, $c->cb );
	my ($episodes) = $c->args(0);
	die "no Airnet episodes for $slug" unless ref $episodes eq 'ARRAY';
	return $episodes;
}

sub slotsOf { Plugins::RTRFM::EpisodeWindow::inferSlots( airnet(shift) ) }

# Candidates for $slug at $now; $filter drops Airnet episodes (as if not listed yet) after the
# slots were inferred from all of them.
sub candidatesAt {
	my ( $slug, $now, $filter ) = @_;
	my $episodes = airnet($slug);
	my $slots    = Plugins::RTRFM::EpisodeWindow::inferSlots($episodes);
	$episodes = [ grep { $filter->($_) } @$episodes ] if $filter;
	return Plugins::RTRFM::EpisodeWindow::candidates( $episodes, $slots, $now );
}

sub dates      { [ map { $_->{date} } @{ $_[0] } ] }
sub synthDates { [ map { $_->{date} } grep { $_->{synthetic} } @{ $_[0] } ] }

# Dates newest first
sub ymd { [ map { sprintf( '2026-%s', $_ ) } @_ ] }

# ---- Restream::resolve stub ----
#
# stubResolve($outcome): $outcome->($slug, $date) returns the result hash for the callback,
# or 'defer' to keep the request pending until answerDeferred(). Records every call in
# @RESOLVES ("slug:date") and the most resolves in flight at once in $MAX_IN_FLIGHT.

our ( @RESOLVES, @DEFERRED, $IN_FLIGHT, $MAX_IN_FLIGHT );

sub stubResolve {
	my $outcome = shift;
	@RESOLVES = @DEFERRED = ();
	$IN_FLIGHT = $MAX_IN_FLIGHT = 0;

	no warnings 'redefine';
	*Plugins::RTRFM::Restream::resolve = sub {
		my ( $slug, $date, $cb ) = @_;
		push @RESOLVES, "$slug:$date";
		$MAX_IN_FLIGHT = $IN_FLIGHT if ++$IN_FLIGHT > $MAX_IN_FLIGHT;

		my $answer = sub { $IN_FLIGHT--; $cb->(@_) };
		my $result = $outcome->( $slug, $date );

		return push @DEFERRED, [ "$slug:$date", $answer ] if !ref $result && $result eq 'defer';
		$answer->($result);
		return;
	};
}

# Answer the oldest deferred resolve with $result (default: available); returns its key.
sub answerDeferred {
	my $result = shift || $MP3;
	my $next   = shift @DEFERRED or return;
	$next->[1]->($result);
	return $next->[0];
}

my $REAL_RESOLVE = \&Plugins::RTRFM::Restream::resolve;

sub restoreResolve {
	no warnings 'redefine';
	*Plugins::RTRFM::Restream::resolve = $REAL_RESOLVE;
}

# ---- leak detection ----
#
# guardedCb($collector, \$freed): a checkAvailability callback that forwards to $collector and
# holds an object that sets $freed when it is destroyed, i.e. once nothing references the
# callback (and so the state of the open that holds it) any more.

{
	package RTRFMTest::DestroyGuard;
	sub new     { my ( $class, $flag ) = @_; return bless { flag => $flag }, $class }
	sub DESTROY { ${ $_[0]->{flag} } = 1 }
}

sub guardedCb {
	my ( $c, $freed ) = @_;
	my $guard   = RTRFMTest::DestroyGuard->new($freed);
	my $forward = $c->cb;
	return sub { my $keep = $guard; $forward->(@_) };
}

# ---- feeds ----

sub open_feed {
	my ( $feed, @passthrough ) = @_;
	my $c = collector();
	$feed->( undef, $c->cb, { params => {}, isControl => 1 }, @passthrough );
	return $c;
}

sub items_of {
	my ( $c, $name ) = @_;
	is( $c->count, 1, "$name: exactly one callback" );
	my ($result) = $c->args(0);
	is( ref( $result && $result->{items} ), 'ARRAY', "$name: { items => [...] }" );
	return ( $result && $result->{items} ) || [];
}

# Record Util::setEpisodeMeta calls (the real function still runs).
my @META_WRITES;
{
	no warnings 'redefine';
	my $orig = \&Plugins::RTRFM::Util::setEpisodeMeta;
	*Plugins::RTRFM::Util::setEpisodeMeta = sub { push @META_WRITES, { %{ $_[0] } }; $orig->(@_) };
}

sub availCache { Slim::Utils::Cache->new('rtrfm')->get("avail:$_[0]") }

# Forget cached availability (and Airnet lists, which come back from the fixture routes).
sub clearCache { Slim::Utils::Cache->new('rtrfm')->clear }

sub reset_all {
	resetStubs();
	restoreResolve();
	@META_WRITES = ();
	routeAirnet();
	setTime( shift || $NOW );
}

# ===========================================================================
# Slot inference
# ===========================================================================

subtest 'inferSlots: the recorded shows' => sub {
	reset_all();

	is_deeply( slotsOf('drivetime'), [ map { { weekday => $_, hhmm => '1700', duration => 7200 } } 1 .. 5 ], 'Drivetime: Mon-Fri 17:00, 7200 s' );
	is_deeply( slotsOf('saturdayjazz'), [ { weekday => 6, hhmm => '0900', duration => 7200 } ], 'Saturday Jazz: Sat 09:00 (observations older than the window count too)' );
	is_deeply( slotsOf('allcity'), [ { weekday => 5, hhmm => '2300', duration => 7200 } ], 'All City: Fri 23:00, dated Friday although it ends on Saturday' );
	is_deeply(
		slotsOf('uplate'),
		[ map { { weekday => $_, hhmm => '0100', duration => 10800 } } 0, 1, 3, 4 ],
		'Up Late: Sun, Mon, Wed, Thu 01:00 only (keyed by the Perth start day; Tue and Fri were seen once)'
	);
	is_deeply( slotsOf('irregular'), [], 'irregular show: no weekday/time seen twice, no slots' );
	is_deeply( Plugins::RTRFM::EpisodeWindow::inferSlots( [] ), [], 'no episodes: no slots' );
};

subtest 'inferSlots: median duration, at least 2 observations, bad input' => sub {
	my $ep = sub { my ( $start, $duration ) = @_; return { slug => 'x', start => $start, duration => $duration } };

	is_deeply(
		Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', 3600 ), $ep->( '2026-09-14 10:00:00', 7200 ), $ep->( '2026-09-21 10:00:00', 5400 ) ] ),
		[ { weekday => 1, hhmm => '1000', duration => 5400 } ],
		'three observations: the median (3600, 5400, 7200 -> 5400)'
	);
	is_deeply(
		Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', 3600 ), $ep->( '2026-09-14 10:00:00', 7200 ), $ep->( '2026-09-21 10:00:00', 3600 ), $ep->( '2026-08-31 10:00:00', 3600 ) ] ),
		[ { weekday => 1, hhmm => '1000', duration => 3600 } ],
		'a one-off longer episode does not change the median'
	);
	is_deeply(
		Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', 3600 ), $ep->( '2026-09-14 10:00:00', 7200 ) ] ),
		[ { weekday => 1, hhmm => '1000', duration => 5400 } ],
		'two observations: the mean of the middle two'
	);
	is_deeply( Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', 3600 ) ] ), [], 'one observation: no slot' );
	is_deeply(
		Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', 3600 ), $ep->( '2026-09-14 10:30:00', 3600 ) ] ),
		[], 'same weekday, different start time: two groups of one, no slot'
	);
	is_deeply(
		Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', undef ), $ep->( '2026-09-14 10:00:00', undef ) ] ),
		[], 'no known duration: no slot (its end would be unknown)'
	);
	is_deeply(
		Plugins::RTRFM::EpisodeWindow::inferSlots( [ $ep->( '2026-09-07 10:00:00', 3600 ), $ep->( '2026-09-14 10:00:00', undef ), undef, 'x', $ep->( 'soon', 3600 ) ] ),
		[ { weekday => 1, hhmm => '1000', duration => 3600 } ],
		'an observation without a duration still counts; junk entries are skipped'
	);
};

# ===========================================================================
# Candidates
# ===========================================================================

subtest 'candidates: Drivetime at 11:40 Perth on Sat 26 Sep' => sub {
	reset_all();

	my $c = candidatesAt( 'drivetime', $NOW );
	is( scalar @$c, 20, '20 candidates' );
	is_deeply(
		dates($c),
		ymd(qw(09-25 09-24 09-23 09-22 09-21 09-18 09-17 09-16 09-15 09-14 09-11 09-10 09-09 09-08 09-07 09-04 09-03 09-02 09-01 08-31)),
		'every weekday from 2026-08-31 to 2026-09-25, newest first, no duplicates'
	);
	is_deeply( synthDates($c), ymd(qw(09-10 09-09 09-08 09-07 09-04 09-03 09-02 09-01 08-31)), '9 synthesised (before Airnet\'s list starts)' );
	is( scalar( grep { !$_->{synthetic} } @$c ), 11, '11 from Airnet' );
	ok( !( grep { $_->{date} lt '2026-08-29' } @$c ), 'none before 2026-08-29' );
	ok( !( grep { $_->{date} eq '2026-09-26' } @$c ), 'none today (no Saturday slot)' );

	is_deeply(
		$c->[-1],
		{
			slug        => 'drivetime',
			date        => '2026-08-31',
			hhmm        => '1700',
			start       => '2026-08-31 17:00:00',
			end         => '2026-08-31 19:00:00',
			duration    => 7200,
			title       => undef,
			description => undef,
			synthetic   => 1,
		},
		'a synthesised episode has exactly the documented shape'
	);
	is_deeply( [ sort keys %{ $c->[0] } ], [qw(date description duration end hhmm slug start title)], 'Airnet episodes are passed on untouched (no synthetic key)' );
};

subtest 'candidates: Up Late, Saturday Jazz, All City, irregular' => sub {
	reset_all();

	my $c = candidatesAt( 'uplate', $NOW );
	is( scalar @$c, 18, 'Up Late: 18 candidates' );
	is_deeply(
		[ map { $_->{date} } grep { $_->{synthetic} || $_->{date} =~ /^2026-09-2[25]$/ } @$c ],
		ymd(qw(09-25 09-22 09-10 09-07 09-06 09-03 09-02 08-31 08-30)),
		'Up Late: Airnet\'s Tue 22 and Fri 25 Sep plus synthesised Sun/Mon/Wed/Thu dates'
	);
	is( scalar( grep { my $w = Plugins::RTRFM::Util::perthWeekday( perth("$_->{date} 12:00") ); $w == 0 || $w == 1 || $w == 3 || $w == 4 } @$c ), 16, 'Up Late: 16 slot dates' );
	is_deeply( [ map { $_->{hhmm} } grep { $_->{synthetic} } @$c ], [ ('0100') x 7 ], 'Up Late: synthesised at 01:00 on their Perth start date' );

	$c = candidatesAt( 'saturdayjazz', $NOW );
	is_deeply( dates($c), ymd(qw(09-26 09-19 09-12 09-05 08-29)), 'Saturday Jazz at 11:40: 5, including today (ended 11:00, 10 min have passed)' );
	is( $c->[0]->{synthetic}, 1, 'today\'s is synthesised' );
	is( $c->[-1]->{date}, '2026-08-29', 'today - 28 days is included' );

	is( scalar @{ candidatesAt( 'saturdayjazz', timegm( 0, 5, 3, 26, 8, 2026 ) ) }, 4, 'Saturday Jazz at 11:05: 4 (the file is not there yet)' );
	is( scalar @{ candidatesAt( 'saturdayjazz', perth('2026-09-26 11:09:59') ) }, 4, 'at 11:09:59: 4' );
	is( scalar @{ candidatesAt( 'saturdayjazz', perth('2026-09-26 11:10:00') ) }, 5, 'at 11:10:00 (end + 10 min): 5' );

	$c = candidatesAt( 'allcity', $NOW );
	is_deeply( dates($c), ymd(qw(09-25 09-18 09-11 09-04)), 'All City: 09-04, 09-11, 09-18, 09-25' );
	is_deeply( synthDates($c), ymd(qw(09-11)), 'All City: 09-11 synthesised' );

	$c = candidatesAt( 'irregular', $NOW );
	is_deeply( dates($c), ymd(qw(09-22 09-17 09-12 09-06)), 'irregular: only Airnet\'s own episodes in the window' );
	is_deeply( synthDates($c), [], 'irregular: nothing synthesised' );
};

subtest 'candidates: a show still on air is not synthesised yet' => sub {
	reset_all();

	my $noFri25 = sub { $_[0]->{date} ne '2026-09-25' };

	# 2026-09-25 16:30 UTC = Sat 26 Sep 00:30 Perth: All City (Fri 23:00-01:00) is on air
	my $onAir = timegm( 0, 30, 16, 25, 8, 2026 );
	my $c = candidatesAt( 'allcity', $onAir );
	ok( !( grep { $_->{date} eq '2026-09-25' && $_->{synthetic} } @$c ), 'All City at Sat 00:30: no synthesised 09-25 episode' );
	is_deeply( dates( candidatesAt( 'allcity', $onAir, $noFri25 ) ), ymd(qw(09-18 09-11 09-04)), 'without Airnet\'s 09-25 entry: no 09-25 at all' );
	is_deeply( synthDates( candidatesAt( 'allcity', perth('2026-09-26 01:09:59'), $noFri25 ) ), ymd(qw(09-11)), 'at 01:09:59: still none' );
	is_deeply( synthDates( candidatesAt( 'allcity', perth('2026-09-26 01:10:00'), $noFri25 ) ), ymd(qw(09-25 09-11)), 'at 01:10: synthesised 09-25, dated Friday' );

	is_deeply( dates( candidatesAt( 'allcity', $onAir ) ), ymd(qw(09-25 09-18 09-11 09-04)), 'when a date has both, the Airnet episode wins' );
	is( candidatesAt( 'allcity', $onAir )->[0]->{title}, 'All City with DJ Dusty D', 'Airnet\'s 09-25 hash, title and all' );

	# Up Late (01:00-04:00) on Thu 24 Sep at 03:00, and at 04:10
	my $noThu24 = sub { $_[0]->{date} ne '2026-09-24' };
	ok( !( grep { $_->{date} eq '2026-09-24' } @{ candidatesAt( 'uplate', perth('2026-09-24 03:00:00'), $noThu24 ) } ), 'Up Late at 03:00: today\'s not synthesised while on air' );
	is( candidatesAt( 'uplate', perth('2026-09-24 04:10:00'), $noThu24 )->[0]->{date}, '2026-09-24', 'Up Late at 04:10: today\'s listed first' );
};

subtest 'candidates: an Airnet episode dated today skips the end + 10 min rule' => sub {
	reset_all();

	my $episodes = airnet('saturdayjazz');
	my $slots    = Plugins::RTRFM::EpisodeWindow::inferSlots($episodes);
	my $today    = { slug => 'saturdayjazz', date => '2026-09-26', hhmm => '0900', start => '2026-09-26 09:00:00', end => '2026-09-26 11:00:00', duration => 7200, title => 'Saturday Jazz today', description => undef };
	my $at       = perth('2026-09-26 11:05:00');

	is_deeply( dates( Plugins::RTRFM::EpisodeWindow::candidates( $episodes, $slots, $at ) ), ymd(qw(09-19 09-12 09-05 08-29)), 'at 11:05 without an Airnet entry for today: not synthesised yet' );

	my $c = Plugins::RTRFM::EpisodeWindow::candidates( [ @$episodes, $today ], $slots, $at );
	is_deeply( dates($c), ymd(qw(09-26 09-19 09-12 09-05 08-29)), 'at 11:05 with Airnet\'s own 09-26 entry: listed (the rule is for synthesised episodes only)' );
	is( $c->[0], $today, 'as Airnet\'s hash, untouched' );
};

subtest 'candidates: Airnet wins, one per date, window edges, cap' => sub {
	my $ep = sub { my ( $date, $hhmm, %extra ) = @_; my ( $h, $m ) = $hhmm =~ /(..)(..)/; return { slug => 'daily', date => $date, hhmm => $hhmm, start => "$date $h:$m:00", end => undef, duration => 10800, title => "Airnet $date", description => undef, %extra } };

	# a daily 06:00-09:00 show seen twice on each weekday
	my @airnet = map { $ep->( $_, '0600' ) } map { Plugins::RTRFM::Util::perthDate( perth('2026-09-25 12:00') - $_ * 86400 ) } 0 .. 13;
	my $slots = Plugins::RTRFM::EpisodeWindow::inferSlots( \@airnet );
	is( scalar @$slots, 7, 'daily show: 7 slots' );

	my $c = Plugins::RTRFM::EpisodeWindow::candidates( \@airnet, $slots, $NOW );
	is( scalar @$c, 29, 'daily show: 29 candidates (today - 28 .. today), within the cap' );
	is( $c->[0]->{date},  '2026-09-26', 'today (ended 09:00) first' );
	is( $c->[-1]->{date}, '2026-08-29', 'today - 28 last' );
	ok( !( grep { $_->{date} eq '2026-08-28' } @$c ), 'today - 29 is outside' );
	is( scalar( grep { !$_->{synthetic} } @$c ), 14, 'Airnet\'s 14 episodes kept' );
	is_deeply( [ map { $_->{title} } grep { !$_->{synthetic} } @$c ], [ map { $_->{title} } @airnet ], 'as Airnet\'s hashes' );

	# a slot that moved: both slots are inferred, one episode per date (Airnet's, else the earliest)
	my @moved = ( map( { $ep->( $_, '1700' ) } '2026-08-03', '2026-08-10' ), map( { $ep->( $_, '1800' ) } '2026-09-14', '2026-09-21' ) );
	$slots = Plugins::RTRFM::EpisodeWindow::inferSlots( \@moved );
	is_deeply( [ map { "$_->{weekday} $_->{hhmm}" } @$slots ], [ '1 1700', '1 1800' ], 'moved slot: both inferred' );
	$c = Plugins::RTRFM::EpisodeWindow::candidates( \@moved, $slots, $NOW );
	is_deeply( dates($c), ymd(qw(09-21 09-14 09-07 08-31)), 'one episode per date' );
	is_deeply( [ map { $_->{hhmm} } @$c ], [qw(1800 1800 1700 1700)], 'Airnet\'s own time on its dates, the earliest slot elsewhere' );

	is_deeply( Plugins::RTRFM::EpisodeWindow::candidates( [], [], $NOW ), [], 'no Airnet episodes: no candidates' );

	# the cap: one episode per date keeps real shows at 29, so check it on a longer list
	no warnings 'redefine';
	local *Plugins::RTRFM::Airnet::filterWindow = sub { [ map { $ep->( Plugins::RTRFM::Util::perthDate( perth('2026-08-09 12:00') - $_ * 86400 ), '0600' ) } 0 .. 39 ] };
	$c = Plugins::RTRFM::EpisodeWindow::candidates( [], [], $NOW );
	is( scalar @$c, 35, '40 episodes: never more than 35 candidates' );
	is( $c->[0]->{date},  '2026-08-09', 'the newest kept' );
	is( $c->[-1]->{date}, '2026-07-06', 'the oldest 5 dropped' );
};

subtest 'candidates: the same under TZ=UTC and TZ=America/New_York' => sub {
	reset_all();

	for my $tz (qw(UTC America/New_York)) {
		local $ENV{TZ} = $tz;
		POSIX::tzset();
		is( scalar @{ candidatesAt( 'drivetime', $NOW ) }, 20, "TZ=$tz: Drivetime 20" );
		is_deeply( dates( candidatesAt( 'saturdayjazz', $NOW ) ), ymd(qw(09-26 09-19 09-12 09-05 08-29)), "TZ=$tz: Saturday Jazz" );
		is( candidatesAt( 'uplate', $NOW )->[-1]->{date}, '2026-08-30', "TZ=$tz: Up Late oldest Sun 30 Aug" );
	}
	POSIX::tzset();
};

# ===========================================================================
# Availability
# ===========================================================================

subtest 'availability: hidden, kept, flagged' => sub {
	reset_all();
	stubResolve( sub {
		my ( $slug, $date ) = @_;
		return { unavailable => 1 } if $date eq '2026-08-31' || $date eq '2026-09-15';
		return { error => 'HTTP request failed: 502 Bad Gateway' } if $date eq '2026-09-01';
		return $MP3;
	} );

	my $items = items_of( open_feed( $FEED, $DRIVETIME ), 'Drivetime' );
	is( scalar @$items, 18, '20 candidates - 2 unavailable = 18 items' );
	ok( !( grep { $_->{play} =~ m{/2026-(?:08-31|09-15)/} } @$items ), '{unavailable}: hidden' );

	my ($flagged) = grep { $_->{play} =~ m{/2026-09-01/} } @$items;
	is( $flagged->{line2}, "Tue 1 Sep $MIDDOT 17:00${ENDASH}19:00$UNKNOWN", '{error}: kept, line2 suffixed with "· Availability unknown"' );
	is( scalar( grep { $_->{line2} =~ /Availability unknown/ } @$items ), 1, 'only that one is flagged' );
	is( $items->[0]->{line2}, "Fri 25 Sep $MIDDOT 17:00${ENDASH}19:00", '{url}: kept as is' );
	is( $items->[-1]->{name}, "Tue 1 Sep $ENDASH Drivetime", 'oldest listed: Tue 1 Sep (31 Aug has no audio)' );

	is( scalar @RESOLVES, 20, 'every candidate checked once' );
	is_deeply( [ sort @RESOLVES ], [ sort map { "drivetime:$_" } @{ dates( candidatesAt( 'drivetime', $NOW ) ) } ], 'with its slug and date' );

	is( availCache('drivetime:2026-09-25'), 1, 'cache avail:drivetime:2026-09-25 = 1 (namespace rtrfm)' );
	is( availCache('drivetime:2026-08-31'), 0, 'cache avail:drivetime:2026-08-31 = 0' );
	is( availCache('drivetime:2026-09-01'), undef, 'errors are not cached' );
};

subtest 'availability: never more than 4 resolves in flight' => sub {
	reset_all();
	stubResolve( sub { 'defer' } );

	my $c = open_feed( $FEED, $DRIVETIME );
	is( scalar @DEFERRED, 4, '4 checks started' );
	is( $c->count, 0, 'no callback yet' );

	my $answered = 0;
	while ( answerDeferred() ) {
		$answered++;
		ok( scalar @DEFERRED <= 4, "after $answered answers: at most 4 in flight" ) if $answered % 5 == 0;
	}
	is( $answered, 20, 'all 20 checked, one after another' );
	is( $MAX_IN_FLIGHT, 4, 'never more than 4 in flight' );
	is( scalar( @{ items_of( $c, 'Drivetime' ) } ), 20, 'then one callback with 20 items' );
};

subtest 'availability: checks are shared between opens, and the limit is global' => sub {
	reset_all();
	stubResolve( sub { 'defer' } );

	my $a = open_feed( $FEED, $DRIVETIME );
	my $b = open_feed( $FEED, $DRIVETIME );
	my $u = open_feed( $FEED, $UP_LATE );
	is( scalar @DEFERRED, 4, 'three opens at once: still 4 in flight' );

	1 while answerDeferred();
	is( $MAX_IN_FLIGHT, 4, 'never more than 4 in flight' );
	is( scalar( grep { /^drivetime:/ } @RESOLVES ), 20, 'Drivetime opened twice: 20 resolves, one per date' );
	is( scalar( grep { /^uplate:/ } @RESOLVES ), 18, 'Up Late: 18' );
	is( scalar( @{ items_of( $a, 'first Drivetime open' ) } ),  20, 'first open: 20 items' );
	is( scalar( @{ items_of( $b, 'second Drivetime open' ) } ), 20, 'second open: 20 items' );
	is( scalar( @{ items_of( $u, 'Up Late' ) } ), 18, 'Up Late: 18 items' );
};

subtest 'availability: cache TTLs (available 24 h, unavailable 1 h, errors never)' => sub {
	reset_all();
	stubResolve( sub {
		my ( $slug, $date ) = @_;
		return { unavailable => 1 } if $date eq '2026-08-31';
		return { error => 'timed out' } if $date eq '2026-09-01';
		return $MP3;
	} );

	my $t0 = $NOW;
	my $reopen = sub {
		my ( $offset, $name ) = @_;
		setTime( $t0 + $offset );
		@RESOLVES = ();
		items_of( open_feed( $FEED, $DRIVETIME ), $name );
		return [ sort @RESOLVES ];
	};

	is( scalar @{ $reopen->( 0, 'cold' ) }, 20, 'cold: 20 resolves' );
	is_deeply( $reopen->( 60,    '+1 min' ), ['drivetime:2026-09-01'], '+1 min: only the error is checked again' );
	is_deeply( $reopen->( 3599,  '+59:59' ), ['drivetime:2026-09-01'], '+59:59: unavailable still cached' );
	is_deeply( $reopen->( 3601,  '+1:00:01' ), [ 'drivetime:2026-08-31', 'drivetime:2026-09-01' ], '+1 h: unavailable checked again' );
	is_deeply( $reopen->( 86399, '+23:59:59' ), [ 'drivetime:2026-08-31', 'drivetime:2026-09-01' ], '+23:59:59: available still cached' );
	is_deeply(
		$reopen->( 86401, '+24:00:01' ),
		[ sort grep { $_ ne 'drivetime:2026-08-31' } map { "drivetime:$_" } @{ dates( candidatesAt( 'drivetime', $NOW ) ) } ],
		'+24 h: the available ones are checked again (the same 20 dates on Sunday; 08-31 was re-checked 2 s ago)'
	);
};

subtest 'availability: a second open within the TTL makes zero resolves' => sub {
	reset_all();
	stubResolve( sub { $_[1] eq '2026-09-15' ? { unavailable => 1 } : $MP3 } );

	my $first = items_of( open_feed( $FEED, $DRIVETIME ), 'first open' );
	is( scalar @RESOLVES, 20, 'first open: 20 resolves' );

	@RESOLVES = ();
	advanceTime(1800);
	my $second = items_of( open_feed( $FEED, $DRIVETIME ), 'second open' );
	is( scalar @RESOLVES, 0, 'second open, 30 min later: zero resolves' );
	is_deeply( [ map { $_->{play} } @$second ], [ map { $_->{play} } @$first ], 'same 19 episodes' );
};

subtest 'availability: the time budget' => sub {
	reset_all();
	stubResolve( sub { 'defer' } );

	my $c = open_feed( $FEED, $DRIVETIME );
	advanceTime(7.9);
	is( $c->count, 0, 'rzz hangs: no callback after 7.9 s' );

	advanceTime(0.2);
	my $items = items_of( $c, 'after 8 s' );
	is( scalar @$items, 20, 'after 8 s: all 20 episodes' );
	is( scalar( grep { $_->{line2} =~ /\Q$UNKNOWN\E\z/ } @$items ), 20, 'all flagged "Availability unknown"' );
	ok( ( grep { $_->{level} eq 'WARN' && $_->{message} =~ /longer than 8 s/ } Slim::Utils::Log->messages ), 'a warning is logged' );

	# the checks carry on in the background (still at most 4 in flight) and cache their answers
	is( scalar @RESOLVES, 4, 'still 4 in flight' );
	1 while answerDeferred();
	is( $c->count, 1, 'late answers: no second callback' );
	is( scalar @RESOLVES, 20, 'the other 16 are checked afterwards, once each' );
	is( $MAX_IN_FLIGHT, 4, 'never more than 4 in flight' );
	is( scalar( grep { defined availCache("drivetime:$_") } @{ dates( candidatesAt( 'drivetime', $NOW ) ) } ), 20, 'and cached' );
	is( scalar( () = Slim::Utils::Timers->pending ), 0, 'no timer left' );

	@RESOLVES = ();
	$items = items_of( open_feed( $FEED, $DRIVETIME ), 're-open' );
	is( scalar @RESOLVES, 0, 're-opening: zero resolves' );
	is( scalar( grep { $_->{line2} =~ /Availability unknown/ } @$items ), 0, 'and nothing flagged' );

	# all answered in time: the budget timer is cancelled
	reset_all();
	stubResolve( sub { $MP3 } );
	items_of( open_feed( $FEED, $DRIVETIME ), 'fast rzz' );
	is( scalar( () = Slim::Utils::Timers->pending ), 0, 'fast rzz: the budget timer is cancelled' );
};

subtest 'availability: no more than 35 candidates are checked' => sub {
	reset_all();
	stubResolve( sub { $MP3 } );

	my @episodes = map { { slug => 'x', date => Plugins::RTRFM::Util::perthDate( perth('2026-09-25 12:00') - $_ * 86400 ) } } 0 .. 39;
	my $c = collector();
	Plugins::RTRFM::EpisodeWindow::checkAvailability( \@episodes, $c->cb );

	is( scalar @RESOLVES, 35, '40 episodes: 35 resolves' );
	is( $c->count, 1, 'one callback' );
	my ($results) = $c->args(0);
	is( scalar @$results, 35, 'with 35 results' );
	is_deeply( [ map { $_->{episode} } @$results ], [ @episodes[ 0 .. 34 ] ], 'the first 35, in order' );
	is_deeply( [ map { $_->{status} } @$results ], [ ('available') x 35 ], 'status available' );

	$c = collector();
	Plugins::RTRFM::EpisodeWindow::checkAvailability( [], $c->cb );
	is_deeply( [ $c->args(0) ], [ [] ], 'no episodes: called back at once with []' );
};

subtest 'availability: an open\'s callback and state are freed once it has called back' => sub {
	reset_all();
	stubResolve( sub { 'defer' } );

	my @episodes = map { { slug => 'leak', date => "2026-09-0$_" } } 1 .. 6;

	# every check answered within the budget (the budget timer is cancelled)
	my $freed = 0;
	my $c     = collector();
	Plugins::RTRFM::EpisodeWindow::checkAvailability( [ @episodes[ 0 .. 2 ] ], guardedCb( $c, \$freed ) );
	ok( !$freed, 'while its checks run: the callback is held' );
	1 while answerDeferred();
	is( $c->count, 1, 'answered in time: one callback' );
	ok( $freed, 'answered in time: the callback, and the state it is held by, is freed' );

	# the budget runs out while checks are still running and queued
	clearCache();
	$freed = 0;
	$c     = collector();
	Plugins::RTRFM::EpisodeWindow::checkAvailability( \@episodes, guardedCb( $c, \$freed ) );
	advanceTime(8.1);
	is( $c->count, 1, 'budget expired: one callback' );
	is( scalar @DEFERRED, 4, 'with 4 checks still running (and 2 queued)' );
	ok( $freed, 'budget expired: the callback and state are freed at once' );

	1 while answerDeferred();
	is( $c->count, 1, 'late answers: no second callback' );
	is( scalar @RESOLVES, 3 + 6, 'the background checks still finish' );
	is( scalar( grep { defined availCache("leak:$_->{date}") } @episodes ), 6, 'and cache their outcome' );
	is( scalar( () = Slim::Utils::Timers->pending ), 0, 'no timer left' );
};

subtest 'availability: an open\'s own checks go before checks left over from an expired budget' => sub {
	reset_all();
	stubResolve( sub { 'defer' } );

	# rzz is slow: the first open's budget runs out with 4 checks running and 6 queued
	my @first = map { { slug => 'first', date => "2026-09-1$_" } } 0 .. 9;
	my $a = collector();
	Plugins::RTRFM::EpisodeWindow::checkAvailability( \@first, $a->cb );
	advanceTime(8.1);
	is( $a->count, 1, 'first open: called back when its budget ran out' );
	is_deeply( [@RESOLVES], [ map { "first:$_->{date}" } @first[ 0 .. 3 ] ], 'first open: 4 checks running, 6 left over in the queue' );

	# a later open: two checks of its own, and one it shares with a leftover (the last queued)
	my @second = ( { slug => 'second', date => '2026-09-21' }, { slug => 'second', date => '2026-09-22' }, $first[9] );
	my $b = collector();
	Plugins::RTRFM::EpisodeWindow::checkAvailability( \@second, $b->cb );
	is( scalar @DEFERRED, 4, 'second open: still 4 in flight' );

	answerDeferred() for 1 .. 4;
	is_deeply(
		[ @RESOLVES[ 4 .. 7 ] ],
		[ 'first:2026-09-19', 'second:2026-09-21', 'second:2026-09-22', 'first:2026-09-14' ],
		'as slots free up, the second open\'s 3 checks start first (in queue order), then the leftovers'
	);

	answerDeferred() for 1 .. 3;
	is( $b->count, 1, 'second open: called back once its own checks are answered, leftovers still pending' );
	is_deeply( [ map { $_->{status} } @{ ( $b->args(0) )[0] || [] } ], [ ('available') x 3 ], 'with every status known' );

	1 while answerDeferred();
	is_deeply( [ @RESOLVES[ 8 .. $#RESOLVES ] ], [ map { "first:2026-09-1$_" } 5 .. 8 ], 'then the other leftovers, oldest first' );
	is( scalar @RESOLVES, 12, 'each checked once' );
	is( $MAX_IN_FLIGHT, 4, 'never more than 4 in flight' );
	is( scalar( grep { defined availCache("first:$_->{date}") } @first ), 10, 'the leftovers\' outcomes are cached' );
	is( $a->count, 1, 'first open: no second callback' );
};

subtest 'availability: the real Restream::resolve over HTTP' => sub {
	reset_all();

	# rzz answers .mp3 for every Drivetime date except 2026-08-27 and before (.mp4, 404)
	Slim::Networking::SimpleAsyncHTTP->addRoute(
		qr{^https://restreams\.rtrfm\.com\.au/rzz\?},
		sub {
			my ($url) = @_;
			my ( $slug, $date ) = $url =~ /n=([^&]+)&d=(.+)$/;
			my $ext = $date le '2026-08-27' ? 'mp4' : 'mp3';
			return { code => 200, content => qq({"u":"https://restreams.rtrfm.com.au/shows/${slug}_$date.$ext?st=abc&e=1790391804"}), headers => { 'Content-Type' => 'application/javascript' } };
		}
	);
	my $rzzRequests = sub { scalar grep { $_->{url} =~ m{/rzz\?} } requests() };

	my $items = items_of( open_feed( $FEED, $DRIVETIME ), 'Drivetime' );
	is( scalar @$items, 20, '20 episodes' );
	is( $rzzRequests->(), 20, '20 rzz requests' );
	is( $items->[-1]->{name}, "Mon 31 Aug $ENDASH Drivetime", 'the oldest is "Mon 31 Aug – Drivetime"' );
	is( $items->[-1]->{play}, 'rtrfm://episode/drivetime/2026-08-31/1700', 'playing rtrfm://episode/drivetime/2026-08-31/1700' );
	is( scalar( grep { $_->{line2} =~ /Availability unknown/ } @$items ), 0, 'nothing flagged while rzz is healthy' );
	is( scalar( grep { $_->{level} =~ /WARN|ERROR/ } Slim::Utils::Log->messages ), 0, 'no warnings or errors logged' );

	my $cached = Slim::Utils::Cache->new('rtrfm')->get('avail:drivetime:2026-08-31');
	is( $cached, 1, 'only the boolean is cached' );

	items_of( open_feed( $FEED, $DRIVETIME ), 're-open' );
	is( $rzzRequests->(), 20, 're-opening: no new rzz request' );

	# a date rzz has no MP3 for (.mp4) is hidden
	setTime( perth('2026-09-24 12:00:00') );    # window from 2026-08-27
	$items = items_of( open_feed( $FEED, $DRIVETIME ), 'Drivetime on Thu 24 Sep' );
	ok( !( grep { $_->{play} =~ m{/2026-08-27/} } @$items ), '2026-08-27 (.mp4): hidden' );
	is( $items->[-1]->{play}, 'rtrfm://episode/drivetime/2026-08-28/1700', '2026-08-28 (.mp3): the oldest' );
};

# ===========================================================================
# _episodesFeed
# ===========================================================================

subtest '_episodesFeed: items from _episodeItem, synthetic flag, metadata' => sub {
	reset_all();
	stubResolve( sub { $_[1] eq '2026-09-01' ? { error => 'timed out' } : $MP3 } );

	my $candidates = candidatesAt( 'drivetime', $NOW );
	my $items      = items_of( open_feed( $FEED, $DRIVETIME ), 'Drivetime' );

	my @expected = map {
		my $item = Plugins::RTRFM::OnDemand::_episodeItem( undef, $DRIVETIME, $_ );
		$item->{line2} .= $UNKNOWN if $_->{date} eq '2026-09-01';
		$item;
	} @$candidates;
	is_deeply( $items, \@expected, 'every item is _episodeItem($client, $program, $episode) (plus the flag for the failed check)' );

	is( scalar( grep { $_->{passthrough}->[1]->{synthetic} } @$items ), 9, 'the 9 synthesised episodes carry synthetic => 1' );
	is( $items->[-1]->{passthrough}->[1]->{synthetic}, 1, 'e.g. Mon 31 Aug' );
	is( $items->[-1]->{name}, "Mon 31 Aug $ENDASH Drivetime", 'named "Mon 31 Aug – Drivetime"' );
	is( $items->[-1]->{line2}, "Mon 31 Aug $MIDDOT 17:00${ENDASH}19:00", 'with the slot times' );

	is( scalar @META_WRITES, 20, 'setEpisodeMeta for every listed episode' );
	my ($meta) = grep { $_->{date} eq '2026-08-31' } @META_WRITES;
	is_deeply(
		$meta,
		{ slug => 'drivetime', date => '2026-08-31', start => '2026-08-31 17:00:00', duration => 7200, title => "Drivetime $ENDASH Mon 31 Aug", show => 'Drivetime', image => undef, description => undef },
		'synthesised: title "Drivetime – Mon 31 Aug", start and duration from the slot'
	);
	is( Plugins::RTRFM::Util::getEpisodeMeta( 'drivetime', '2026-08-31' )->{start}, '2026-08-31 17:00:00', 'readable through getEpisodeMeta' );

	# the episode submenu of a synthesised episode without a track list: "not yet available"
	route( qr{/playlists$}, code => 400, content => '{"message":"No such episode"}' );
	my $submenu = items_of( open_feed( $items->[-1]->{url}, @{ $items->[-1]->{passthrough} } ), 'Mon 31 Aug submenu' );
	is_deeply( $submenu->[-1], { name => 'Track list not yet available', type => 'text' }, 'its submenu says "Track list not yet available"' );
};

subtest '_episodesFeed: just aired today, hidden episodes write no metadata' => sub {
	reset_all();
	stubResolve( sub { $_[1] eq '2026-09-12' ? { unavailable => 1 } : $MP3 } );

	my $program = { %$SATURDAY_JAZZ, image => 'https://example.test/sj.jpg' };
	my $items   = items_of( open_feed( $FEED, $program ), 'Saturday Jazz' );

	is_deeply( [ map { $_->{name} } @$items ], [ "Sat 26 Sep $ENDASH Saturday Jazz", "Sat 19 Sep $ENDASH Saturday Jazz with Laura Igglesden", "Sat 5 Sep $ENDASH Saturday Jazz", "Sat 29 Aug $ENDASH Saturday Jazz" ], 'starts with today\'s episode; 12 Sep (no audio) hidden' );
	is( $items->[0]->{play}, 'rtrfm://episode/saturdayjazz/2026-09-26/0900', 'today\'s plays rtrfm://episode/saturdayjazz/2026-09-26/0900' );
	is( $items->[0]->{image}, 'https://example.test/sj.jpg', 'with the program image' );
	is_deeply( [ map { $_->{date} } @META_WRITES ], ymd(qw(09-26 09-19 09-05 08-29)), 'metadata written for the listed episodes only' );
	is( $META_WRITES[0]->{title}, "Saturday Jazz $ENDASH Sat 26 Sep", 'today\'s title: "Saturday Jazz – Sat 26 Sep"' );
	is( $META_WRITES[0]->{image}, 'https://example.test/sj.jpg', 'and image' );
};

subtest '_episodesFeed: empty and error items, exactly one callback' => sub {
	reset_all();
	stubResolve( sub { $MP3 } );

	is_deeply( items_of( open_feed( $FEED, { slug => 'nosuch', name => 'No Such', image => undef } ), 'Airnet 500' ), [$LOAD_FAILED], 'Airnet fails: LOAD_FAILED' );
	is_deeply( items_of( open_feed( $FEED, { slug => 'understorey', name => 'Understorey', image => undef } ), 'Airnet []' ), [$NO_EPISODES], 'Airnet returns []: NO_EPISODES' );
	is( scalar @RESOLVES, 0, 'no resolves for either' );

	stubResolve( sub { { unavailable => 1 } } );
	is_deeply( items_of( open_feed( $FEED, $SATURDAY_JAZZ ), 'nothing has audio' ), [$NO_EPISODES], 'every candidate unavailable: NO_EPISODES' );
	is( scalar @META_WRITES, 0, 'no metadata writes' );

	clearCache();
	stubResolve( sub { { error => 'down' } } );
	my $items = items_of( open_feed( $FEED, $SATURDAY_JAZZ ), 'rzz outage' );
	is( scalar @$items, 5, 'rzz fails for all: all 5 shown' );
	is( scalar( grep { $_->{line2} =~ /\Q$UNKNOWN\E\z/ } @$items ), 5, 'all flagged' );

	{
		no warnings 'redefine';
		local *Plugins::RTRFM::EpisodeWindow::candidates = sub { die "window broke\n" };
		is_deeply( items_of( open_feed( $FEED, $DRIVETIME ), 'dying candidates' ), [$LOAD_FAILED], 'computing the window dies: LOAD_FAILED' );
		ok( ( grep { $_->{level} eq 'ERROR' && $_->{message} =~ /window broke/ } Slim::Utils::Log->messages ), 'error logged' );
	}
	{
		no warnings 'redefine';
		local *Plugins::RTRFM::OnDemand::_episodeItem = sub { die "item broke\n" };
		stubResolve( sub { $MP3 } );
		is_deeply( items_of( open_feed( $FEED, $DRIVETIME ), 'dying _episodeItem' ), [$LOAD_FAILED], 'building an item dies: LOAD_FAILED' );
	}
	{
		no warnings 'redefine';
		clearCache();
		local *Plugins::RTRFM::Restream::resolve = sub { die "resolve broke\n" };
		my $items = items_of( open_feed( $FEED, $SATURDAY_JAZZ ), 'dying resolve' );
		is( scalar( grep { $_->{line2} =~ /\Q$UNKNOWN\E\z/ } @$items ), 5, 'resolve dies: kept and flagged' );
	}
};

subtest '_episodesFeed: a cached Airnet list gives the new window after Perth midnight' => sub {
	reset_all( perth('2026-09-25 23:50:00') );
	stubResolve( sub { $MP3 } );
	my $airnetRequests = sub { scalar grep { index( $_->{url}, $BASE ) == 0 } requests() };

	my $items = items_of( open_feed( $FEED, $DRIVETIME ), 'Fri 23:50' );
	is( scalar @$items, 21, 'Fri 25 Sep 23:50: 21 (window from Fri 28 Aug; 25 Sep ended at 19:00)' );
	is( $items->[-1]->{name}, "Fri 28 Aug $ENDASH Drivetime", 'oldest Fri 28 Aug' );

	advanceTime(900);    # Sat 26 Sep 00:05, inside Airnet's 30 min cache
	$items = items_of( open_feed( $FEED, $DRIVETIME ), 'Sat 00:05' );
	is( $airnetRequests->(), 1, 'no new Airnet request' );
	is( scalar @$items, 20, 'after Perth midnight: 20' );
	is( $items->[-1]->{name}, "Mon 31 Aug $ENDASH Drivetime", 'oldest Mon 31 Aug' );
};

done_testing();
