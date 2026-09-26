#!/usr/bin/perl
# Plugins::RTRFM::OnDemand menus: the top-level "Programs" link (no network), the program list,
# episode items (rtrfm:// URLs, labels, keys), episode-metadata cache writes, empty and error
# items, exactly one callback per builder, caching across re-opens, and F1's init registration.
# Uses the Airnet fixtures in t/data/ondemand/ (see t/32-airnet.t) and the fake clock.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use JSON::PP ();
use Time::Local qw(timegm);

use Slim::Utils::Strings qw(string);

use Plugins::RTRFM::OnDemand;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $BASE = Plugins::RTRFM::Util::AIRNET_BASE;
my $ICON = Plugins::RTRFM::Util::ICON;

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $NOW = timegm( 0, 40, 3, 26, 8, 2026 );

# 2026-09-25 16:00:00 UTC = Perth midnight (the 26th begins).
my $MIDNIGHT = timegm( 0, 0, 16, 25, 8, 2026 );

my $ENDASH = "\x{2013}";
my $MIDDOT = "\x{B7}";

my $NO_EPISODES = { name => 'No episodes available in the last 28 days', type => 'text' };
my $LOAD_FAILED = { name => "Couldn't load from RTRFM $ENDASH please try again later", type => 'text' };

my $SATURDAY_JAZZ = { slug => 'saturdayjazz', name => 'Saturday Jazz', image => undef };
my $DRIVETIME     = { slug => 'drivetime',    name => 'Drivetime',     image => undef };

# rzz answers the availability check that _episodesFeed makes since O6 (see
# t/39-episode-window.t). Here the audio exists only for the dates Airnet lists, so the dates O6
# synthesises (e.g. today's Saturday Jazz, Drivetime before 11 Sep) are hidden and the lists
# are Airnet's.
my %AIRNET_DATES;
for my $slug (qw(saturdayjazz drivetime uplate herstory)) {
	$AIRNET_DATES{$slug}{ substr( $_->{start}, 0, 10 ) } = 1 for @{ JSON::PP->new->utf8->decode( fixture("ondemand/episodes-$slug.json") ) };
}

sub routeAll {
	route( "$BASE/programs", file => 'ondemand/programs.json' );
	route( "$BASE/programs/$_/episodes", file => "ondemand/episodes-$_.json" ) for qw(saturdayjazz drivetime uplate herstory);
	route( "$BASE/programs/understorey/episodes", content => '[]' );
	Slim::Networking::SimpleAsyncHTTP->addRoute(
		qr{^https://restreams\.rtrfm\.com\.au/rzz\?},
		sub {
			my ( $slug, $date ) = $_[0] =~ /n=([^&]+)&d=(.+)$/;
			my $ext = $AIRNET_DATES{$slug}{$date} ? 'mp3' : 'mp4';
			return { code => 200, content => qq({"u":"https://restreams.rtrfm.com.au/shows/${slug}_$date.$ext?st=abc&e=1790391804"}) };
		}
	);
}

# HTTP requests other than rzz availability checks
sub requestCount { scalar grep { $_->{url} !~ m{/rzz\?} } requests() }

# Run a feed builder the way XMLBrowser does: ($client, $callback, \%args, @passthrough).
# Returns the collector.
sub open_feed {
	my ( $feed, @passthrough ) = @_;
	my $c = collector();
	$feed->( undef, $c->cb, { params => {}, isControl => 1 }, @passthrough );
	return $c;
}

# The items from a collector that was called back exactly once with { items => [...] }.
sub items_of {
	my ( $c, $name ) = @_;
	is( $c->count, 1, "$name: exactly one callback" );
	my ($result) = $c->args(0);
	is( ref $result, 'HASH', "$name: called back with a hash" );
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

sub reset_all {
	resetStubs();
	@META_WRITES = ();
	routeAll();
}

ok( string('PLUGIN_RTRFM_LOAD_FAILED'), 'PLUGIN_RTRFM_LOAD_FAILED is defined' );

subtest 'init: F1 registration of the rtrfm scheme is unchanged' => sub {
	resetStubs();
	Plugins::RTRFM::OnDemand->init();
	is( Slim::Player::ProtocolHandlers->handlerForProtocol('rtrfm'), 'Plugins::RTRFM::ProtocolHandler', 'rtrfm => Plugins::RTRFM::ProtocolHandler' );
};

subtest 'menuItems: one "Programs" link, synchronous, no network' => sub {
	reset_all();

	my $c = collector();
	Plugins::RTRFM::OnDemand->menuItems( undef, $c->cb, { params => {} } );

	is( $c->count, 1, 'called back once, synchronously' );
	is_deeply(
		( $c->args(0) )[0],
		[ { name => 'Programs', type => 'link', url => \&Plugins::RTRFM::OnDemand::_programsFeed, image => $ICON } ],
		'one Programs link to _programsFeed with the station icon'
	);
	is( requestCount(), 0, 'zero HTTP requests' );
	is( scalar @META_WRITES, 0, 'no metadata writes' );
};

# No rtrfm.com.au line-up route here, so _programsFeed falls back to the Airnet list (O5's merge
# is tested in t/38-program-merge.t).
subtest '_programsFeed / _programItem: the program list' => sub {
	reset_all();

	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_programsFeed ), 'programs' );
	is( scalar @$items, 57, '57 program items' );

	is_deeply(
		$items->[0],
		{
			name        => 'All City',
			line1       => 'All City',
			type        => 'link',
			url         => \&Plugins::RTRFM::OnDemand::_programMenu,
			passthrough => [ { slug => 'allcity', name => 'All City', image => undef } ],
			image       => $ICON,
		},
		'first item: exact keys, link to _programMenu, program hash {slug, name, image} passed through, station icon'
	);

	is_deeply( [ grep { join( ',', sort keys %$_ ) ne 'image,line1,name,passthrough,type,url' } @$items ], [], 'every program item has exactly name/line1/type/url/passthrough/image' );
	is_deeply( [ map { lc $_->{name} } @$items ], [ sort map { lc $_->{name} } @$items ], 'alphabetical' );

	my %names = map { $_->{name} => 1 } @$items;
	ok( $names{$_}, "includes $_" ) for ( 'Saturday Jazz', 'Drivetime', 'Black & Blue' );
	ok( !$names{$_}, "no $_" ) for ( 'Add Show Name Here', 'Your Program', 'Demo Playlists' );

	is_deeply(
		Plugins::RTRFM::OnDemand::_programItem( undef, { slug => 'saturdayjazz', name => 'Saturday Jazz', image => 'https://example.test/sj.jpg', extra => 1 } ),
		{
			name        => 'Saturday Jazz',
			line1       => 'Saturday Jazz',
			type        => 'link',
			url         => \&Plugins::RTRFM::OnDemand::_programMenu,
			passthrough => [ { slug => 'saturdayjazz', name => 'Saturday Jazz', image => 'https://example.test/sj.jpg', extra => 1 } ],
			image       => 'https://example.test/sj.jpg',
		},
		'a program image wins over the station icon; extra keys pass through untouched'
	);

	my $airnetRequests = sub { scalar grep { index( $_->{url}, $BASE ) == 0 } requests() };
	is( $airnetRequests->(), 1, 'one Airnet request' );
	open_feed( \&Plugins::RTRFM::OnDemand::_programsFeed );
	is( $airnetRequests->(), 1, 're-opening within the TTL makes no Airnet request' );
};

subtest '_episodesFeed / _episodeItem: Saturday Jazz at 2026-09-26 11:40 Perth' => sub {
	reset_all();
	setTime($NOW);

	# open it the way XMLBrowser does, from the program item
	my ($jazzItem) = grep { $_->{name} eq 'Saturday Jazz' } @{ items_of( open_feed( \&Plugins::RTRFM::OnDemand::_programsFeed ), 'programs' ) };
	my $items = items_of( open_feed( $jazzItem->{url}, @{ $jazzItem->{passthrough} } ), 'Saturday Jazz' );

	is( scalar @$items, 4, '4 episodes in the window' );
	is_deeply(
		[ map { $_->{name} } @$items ],
		[
			"Sat 19 Sep $ENDASH Saturday Jazz with Laura Igglesden",
			"Sat 12 Sep $ENDASH Saturday Jazz",
			"Sat 5 Sep $ENDASH Saturday Jazz",
			"Sat 29 Aug $ENDASH Saturday Jazz",
		],
		'names carry the date and the title or show name, newest first'
	);

	# episode rows are links to the episode submenu that also play (see t/35-episode-submenu.t)
	my $program = $jazzItem->{passthrough}->[0];

	is_deeply(
		$items->[0],
		{
			name        => "Sat 19 Sep $ENDASH Saturday Jazz with Laura Igglesden",
			line1       => 'Saturday Jazz with Laura Igglesden',
			line2       => "Sat 19 Sep $MIDDOT 09:00${ENDASH}11:00",
			type        => 'link',
			url         => \&Plugins::RTRFM::OnDemand::_episodeMenu,
			passthrough => [
				$program,
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
			],
			play        => 'rtrfm://episode/saturdayjazz/2026-09-19/0900',
			duration    => 7200,
			image       => $ICON,
		},
		'first item: exact keys, rtrfm:// URL in play'
	);

	is_deeply(
		$items->[1],
		{
			name        => "Sat 12 Sep $ENDASH Saturday Jazz",
			line1       => 'Saturday Jazz',
			line2       => "Sat 12 Sep $MIDDOT 09:00${ENDASH}11:00",
			type        => 'link',
			url         => \&Plugins::RTRFM::OnDemand::_episodeMenu,
			passthrough => [
				$program,
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
			],
			play        => 'rtrfm://episode/saturdayjazz/2026-09-12/0900',
			duration    => 7200,
			image       => $ICON,
		},
		'second item: null title falls back to the show name; plain-text description passed through'
	);

	is_deeply(
		[ map { $_->{play} } @$items ],
		[ map { "rtrfm://episode/saturdayjazz/$_/0900" } qw(2026-09-19 2026-09-12 2026-09-05 2026-08-29) ],
		'URLs from Util::episodeUrl(slug, date, hhmm)'
	);

	clearTime();
};

subtest 'episode metadata cache: one write per listed episode' => sub {
	reset_all();
	setTime($NOW);

	items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $SATURDAY_JAZZ ), 'Saturday Jazz' );

	is( scalar @META_WRITES, 4, 'four setEpisodeMeta calls for four listed episodes' );
	is_deeply( [ map { $_->{date} } @META_WRITES ], [qw(2026-09-19 2026-09-12 2026-09-05 2026-08-29)], 'only the listed episodes (not 08-22 or older)' );

	is_deeply(
		$META_WRITES[0],
		{
			slug        => 'saturdayjazz',
			date        => '2026-09-19',
			start       => '2026-09-19 09:00:00',
			duration    => 7200,
			title       => 'Saturday Jazz with Laura Igglesden',
			show        => 'Saturday Jazz',
			image       => undef,
			description => undef,
		},
		'Airnet title used when present'
	);

	is_deeply(
		Plugins::RTRFM::Util::getEpisodeMeta( 'saturdayjazz', '2026-09-12' ),
		{
			slug        => 'saturdayjazz',
			date        => '2026-09-12',
			start       => '2026-09-12 09:00:00',
			duration    => 7200,
			title       => "Saturday Jazz $ENDASH Sat 12 Sep",
			show        => 'Saturday Jazz',
			image       => undef,
			description => 'Presented by Ben Bartholomew. Featuring tracks from the debut album by local ensemble the Kirsten Sym Undectet.',
		},
		'fallback title "<Show> – <friendly date>", readable through Util::getEpisodeMeta'
	);
	is( Plugins::RTRFM::Util::getEpisodeMeta( 'saturdayjazz', '2026-08-22' ), undef, 'nothing cached for an episode outside the window' );

	@META_WRITES = ();
	my $withImage = { %$SATURDAY_JAZZ, image => 'https://example.test/sj.jpg' };
	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $withImage ), 'with image' );
	is( $items->[0]->{image}, 'https://example.test/sj.jpg', 'program image used for episode items' );
	is( $META_WRITES[0]->{image}, 'https://example.test/sj.jpg', 'and for the cached metadata' );
	is( scalar @META_WRITES, 4, 're-opening writes the metadata again' );

	clearTime();
};

subtest 'Drivetime and Up Late items' => sub {
	reset_all();
	setTime($NOW);

	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $DRIVETIME ), 'Drivetime' );
	is( scalar @$items, 11, 'Drivetime: 11 items' );
	is( $items->[0]->{play}, 'rtrfm://episode/drivetime/2026-09-25/1700', 'first URL is the latest weekday at 1700' );
	is( $items->[0]->{name}, "Fri 25 Sep $ENDASH Drivetime", 'first name' );
	is( $items->[0]->{line2}, "Fri 25 Sep $MIDDOT 17:00${ENDASH}19:00", 'first line2' );
	ok( !( grep { $_->{play} =~ m{/2026-09-26/} } @$items ), 'nothing dated today' );

	$items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, { slug => 'uplate', name => 'Up Late', image => undef } ), 'Up Late' );
	is( $items->[0]->{play},  'rtrfm://episode/uplate/2026-09-25/0100', 'Up Late dated by its Perth start date' );
	is( $items->[0]->{line2}, "Fri 25 Sep $MIDDOT 01:00${ENDASH}04:00", 'Up Late line2' );

	clearTime();
};

subtest 'empty window: one NO_EPISODES text item' => sub {
	reset_all();
	setTime($NOW);

	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, { slug => 'herstory', name => 'Herstory', image => undef } ), 'Herstory' );
	is_deeply( $items, [$NO_EPISODES], 'Herstory (episodes only from 2023): NO_EPISODES item' );

	$items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, { slug => 'understorey', name => 'Understorey', image => undef } ), 'Understorey' );
	is_deeply( $items, [$NO_EPISODES], 'Understorey (Airnet returns []): NO_EPISODES item' );

	is( scalar @META_WRITES, 0, 'no metadata writes' );
	clearTime();
};

subtest 'upstream failures: one LOAD_FAILED text item, never cached' => sub {
	for my $case (
		[ 'HTTP 500 (unknown slug)', { code => 500, content => '' } ],
		[ 'bad JSON',                { code => 200, content => '<html>oops</html>' } ],
		[ 'transport error',         { error => 'Timed out waiting for data' } ],
	) {
		my ( $name, $response ) = @$case;

		resetStubs();
		@META_WRITES = ();
		route( "$BASE/programs/nosuch/episodes", %$response );
		my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, { slug => 'nosuch', name => 'No Such', image => undef } ), "episodes, $name" );
		is_deeply( $items, [$LOAD_FAILED], "episodes, $name: LOAD_FAILED item" );
		is( scalar @META_WRITES, 0, "episodes, $name: no metadata writes" );

		resetStubs();
		route( "$BASE/programs", %$response );
		$items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_programsFeed ), "programs, $name" );
		is_deeply( $items, [$LOAD_FAILED], "programs, $name: LOAD_FAILED item" );
	}

	# not cached: the next open fetches again and succeeds
	resetStubs();
	route( "$BASE/programs/drivetime/episodes", code => 500 );
	open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $DRIVETIME );
	Slim::Networking::SimpleAsyncHTTP->reset;
	routeAll();
	setTime($NOW);
	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $DRIVETIME ), 'after a failure' );
	is( scalar @$items, 11, 'after a failure, re-opening fetches again and lists the episodes' );
	is( requestCount(), 1, 'one new request' );
	clearTime();
};

subtest 'a builder that dies while building items still calls back once' => sub {
	reset_all();
	setTime($NOW);

	no warnings 'redefine';
	local *Plugins::RTRFM::OnDemand::_episodeItem = sub { die "item builder broke\n" };
	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $SATURDAY_JAZZ ), 'dying _episodeItem' );
	is_deeply( $items, [$LOAD_FAILED], 'LOAD_FAILED item' );
	ok( ( grep { $_->{level} eq 'ERROR' && $_->{message} =~ /item builder broke/ } Slim::Utils::Log->messages ), 'error logged' );

	local *Plugins::RTRFM::OnDemand::_programItem = sub { die "program builder broke\n" };
	$items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_programsFeed ), 'dying _programItem' );
	is_deeply( $items, [$LOAD_FAILED], 'LOAD_FAILED item' );

	clearTime();
};

subtest 're-opening within the TTL: no HTTP request, window recomputed at Perth midnight' => sub {
	reset_all();

	# since O6 the window includes today, and the window edges are tested in t/39-episode-window.t
	setTime( $MIDNIGHT - 600 );    # Perth 23:50 on Friday the 25th
	my $items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $DRIVETIME ), 'Drivetime before midnight' );
	is( scalar @$items, 11, 'before Perth midnight: 11 (09-25 is today, and has ended)' );
	is( requestCount(), 1, 'one request' );

	advanceTime(900);    # Perth 00:05 on the 26th, well inside the 30 min TTL
	$items = items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $DRIVETIME ), 'Drivetime after midnight' );
	is( requestCount(), 1, 're-opening within the TTL makes no HTTP request' );
	is( scalar @$items, 11, 'after Perth midnight the cached list gives the new window: 11' );
	is( $items->[0]->{play}, 'rtrfm://episode/drivetime/2026-09-25/1700', '09-25 listed first' );

	clearTime();
};

done_testing();
