#!/usr/bin/perl
# Plugins::RTRFM::OnDemand program list and program header (O5): the rtrfm.com.au line-up merged
# with Airnet's programs (WordPress names, artwork and schedules; Airnet-only and WordPress-only
# shows dropped), the fallbacks when either source fails, the program item shape, and
# _programMenu: header items (description, schedule, hosts) before the episodes, og:image when
# a show has no artwork, the image passed on to episode items and the episode metadata cache,
# and exactly one callback.
#
# Fixtures: t/data/ondemand/programs.json and episodes-saturdayjazz.json (Airnet, see
# t/32-airnet.t), filter-shows-page{1..5}.json and show-saturdayjazz.html (rtrfm.com.au, see
# t/37-shows.t).

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use JSON::PP ();
use Time::Local qw(timegm);

use Slim::Utils::Cache;

use Plugins::RTRFM::OnDemand;
use Plugins::RTRFM::Shows;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $BASE    = Plugins::RTRFM::Util::AIRNET_BASE;
my $ICON    = Plugins::RTRFM::Util::ICON;
my $AJAX    = 'https://rtrfm.com.au/wp-admin/admin-ajax.php';
my $SJ_PAGE = 'https://rtrfm.com.au/shows/saturdayjazz/';
my $UPLOADS = 'https://rtrfm.com.au/wp-content/uploads';

my $SJ_TEASE_IMAGE = "$UPLOADS/2012/12/SaturdayJazz-768x432.jpg";
my $SJ_OG_IMAGE    = "$UPLOADS/2012/12/SaturdayJazz.jpg";
my $SJ_SCHEDULE    = 'Saturdays 9.00am - 11.00am';
my $SJ_HOSTED_BY   = "Hosted by: Dan Garner, Ben Bartholomew, Wayne G'Froerer, Alf Micallef +2 more";

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $NOW = timegm( 0, 40, 3, 26, 8, 2026 );

my $ENDASH      = "\x{2013}";
my $LOAD_FAILED = { name => "Couldn't load from RTRFM $ENDASH please try again later", type => 'text' };

my %PAGE = map { $_ => fixture("ondemand/filter-shows-page$_.json") } 1 .. 5;

my $PROGRAM_MENU  = \&Plugins::RTRFM::OnDemand::_programMenu;
my $PROGRAMS_FEED = \&Plugins::RTRFM::OnDemand::_programsFeed;

# Route admin-ajax POSTs by page number: $pages->{N} is a response hash or JSON content.
sub routeLineup {
	my $pages = shift;
	Slim::Networking::SimpleAsyncHTTP->addRoute(
		$AJAX,
		sub {
			my ( $url, $method, $body ) = @_;
			my ($n) = ( $body // '' ) =~ /(?:^|&)page=(\d+)/;
			my $page = $pages->{ $n // '' };
			return undef unless defined $page;
			return ref $page ? $page : { code => 200, content => $page };
		}
	);
}

sub routeAirnet {
	route( "$BASE/programs", file => 'ondemand/programs.json' );
	route( "$BASE/programs/saturdayjazz/episodes", file => 'ondemand/episodes-saturdayjazz.json' );
}

sub routeShowPage { route( $SJ_PAGE, file => 'ondemand/show-saturdayjazz.html' ) }

sub routeAll {
	routeAirnet();
	routeLineup( \%PAGE );
	routeShowPage();
}

# The Airnet program list as Airnet::programs returns it (57 programs).
sub airnetPrograms {
	my $c = collector();
	Plugins::RTRFM::Airnet::programs( $c->cb );
	return ( $c->args(0) )[0];
}

# Run a feed builder the way XMLBrowser does; return the collector.
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

sub slugs { [ map { $_->{passthrough}->[0]->{slug} } @{ $_[0] } ] }

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
	setTime($NOW);
}

sub warnings_logged { grep { $_->{level} eq 'WARN' && $_->{category} eq 'plugin.rtrfm' } Slim::Utils::Log->messages }

# The program item _programsFeed builds for an Airnet program when the line-up is unavailable.
sub airnetItem {
	my $p = shift;
	return {
		name        => $p->{name},
		line1       => $p->{name},
		type        => 'link',
		url         => $PROGRAM_MENU,
		passthrough => [ { slug => $p->{slug}, name => $p->{name}, image => undef } ],
		image       => $ICON,
	};
}

# ---------------------------------------------------------------------------
# The merged program list
# ---------------------------------------------------------------------------

subtest 'merge: the line-up with WordPress names, artwork and schedules' => sub {
	reset_all();
	routeAll();

	my $items = items_of( open_feed($PROGRAMS_FEED), 'programs' );
	is( scalar @$items, 46, '46 programs (47 teases minus training; all 46 slugs are known to Airnet)' );

	my %bySlug = map { $_->{passthrough}->[0]->{slug} => $_ } @$items;

	is_deeply(
		$bySlug{saturdayjazz},
		{
			name        => 'Saturday Jazz',
			line1       => 'Saturday Jazz',
			line2       => $SJ_SCHEDULE,
			type        => 'link',
			url         => $PROGRAM_MENU,
			image       => $SJ_TEASE_IMAGE,
			passthrough => [
				{
					slug     => 'saturdayjazz',
					name     => 'Saturday Jazz',
					image    => $SJ_TEASE_IMAGE,
					schedule => $SJ_SCHEDULE,
					hosts    => [ 'Dan Garner', 'Ben Bartholomew', "Wayne G'Froerer", 'Alf Micallef', '+2 more' ],
					genres   => ['Jazz'],
				}
			],
		},
		'Saturday Jazz item: name, line1, line2 = schedule, WordPress image, link to _programMenu with {slug, name, image, schedule, hosts, genres}'
	);

	is( $bySlug{getupmorning}->{name}, 'Get Up Morning', 'getupmorning: WordPress name "Get Up Morning" (Airnet says "GRP")' );
	is( $bySlug{getupmorning}->{line2}, 'Saturdays 6.00am - 9.00am', 'getupmorning: schedule in line2' );
	is( $bySlug{getupmorning}->{image}, "$UPLOADS/2017/03/GetUpMorning-768x432.jpg", 'getupmorning: WordPress image' );
	is( $bySlug{cloudwaves}->{name}, 'Cloud Waves', 'cloudwaves: "Cloud Waves" (Airnet says "Cloudwaves")' );
	is( $bySlug{blackandblue}->{name}, 'Black & Blue', 'Black & Blue' );
	is( $bySlug{breakfast}->{name}, 'Breakfast with Pam', 'Breakfast with Pam' );

	ok( !$bySlug{$_}, "Airnet-only slug $_ dropped" ) for qw(herstory understorey thursday midnightspecial training);
	my %names = map { $_->{name} => 1 } @$items;
	ok( !$names{$_}, "no \"$_\"" ) for ( 'GRP', 'Herstory', 'Understorey', 'Demo Playlists', 'Training', 'Cloudwaves' );

	is( scalar( grep { $_->{image} && $_->{image} ne $ICON } @$items ), 46, 'every item has a WordPress image' );
	is( scalar( grep { defined $_->{line2} && length $_->{line2} } @$items ), 46, 'every item has a schedule line2' );
	is( scalar( grep { $_->{line1} eq $_->{name} } @$items ), 46, 'line1 = name' );
	is_deeply( [ map { lc $_->{name} } @$items ], [ sort map { lc $_->{name} } @$items ], 'sorted by name' );
	is( scalar( warnings_logged() ), 0, 'no warnings' );

	my $requests = scalar( () = requests() );
	open_feed($PROGRAMS_FEED);
	is( scalar( () = requests() ), $requests, 're-opening within the TTLs makes no HTTP request' );
};

subtest 'merge: WordPress-only shows are dropped and logged at info' => sub {
	reset_all();
	local $Slim::Utils::Log::CATEGORIES{'plugin.rtrfm'} = { defaultLevel => 'INFO', description => 'PLUGIN_RTRFM' };
	routeAll();

	# Airnet without allcity and saturdayjazz
	my $airnet = JSON::PP->new->utf8->decode( fixture('ondemand/programs.json') );
	$airnet = [ grep { ( $_->{slug} // '' ) !~ /\A(?:allcity|saturdayjazz)\z/ } @$airnet ];
	Slim::Networking::SimpleAsyncHTTP->reset;
	route( "$BASE/programs", content => JSON::PP->new->utf8->encode($airnet) );
	routeLineup( \%PAGE );

	my $items = items_of( open_feed($PROGRAMS_FEED), 'programs' );
	is( scalar @$items, 44, '46 - 2 = 44' );
	ok( !( grep { $_->{passthrough}->[0]->{slug} =~ /\A(?:allcity|saturdayjazz)\z/ } @$items ), 'allcity and saturdayjazz dropped' );
	ok( ( grep { $_->{level} eq 'INFO' && $_->{message} =~ /allcity/ && $_->{message} =~ /saturdayjazz/ } Slim::Utils::Log->messages ), 'logged at info level' );
	is( scalar( warnings_logged() ), 0, 'no warnings' );
};

subtest 'fallback: a failed or empty line-up gives exactly the Airnet list' => sub {
	for my $case (
		[ 'page 1 HTTP 500',           { 1 => { code => 500 } } ],
		[ 'page 3 times out',          { %PAGE, 3 => { error => 'Timed out waiting for data' } } ],
		[ 'success:false',             { 1 => '{"success":false}' } ],
		[ 'no data.items',             { 1 => '{"success":true,"data":{}}' } ],
		[ 'not JSON',                  { 1 => '<!DOCTYPE html><title>Just a moment...</title>' } ],
		[ 'empty line-up',             { 1 => $PAGE{5} } ],
	) {
		my ( $name, $pages ) = @$case;

		reset_all();
		routeAirnet();
		routeLineup($pages);

		my $items    = items_of( open_feed($PROGRAMS_FEED), $name );
		my $programs = airnetPrograms();

		is( scalar @$items, 57, "$name: 57 Airnet programs" );
		is_deeply( $items, [ map { airnetItem($_) } @$programs ], "$name: exactly O2's list (Airnet names and order, {slug, name, image => undef}, station icon, no line2)" );
		is( $items->[0]->{name}, 'All City', "$name: first All City" );
		ok( ( grep { $_->{name} eq 'GRP' } @$items ), "$name: Airnet name GRP" );
		ok( ( grep { $_->{message} =~ /line-up/i } warnings_logged() ), "$name: logged as a warning" );
		is( Slim::Utils::Cache->new('rtrfm')->get('shows:lineup'), undef, "$name: no line-up cached" );
	}
};

subtest 'fallback: Airnet failed, line-up OK gives the line-up list' => sub {
	reset_all();
	route( "$BASE/programs", code => 500 );
	routeLineup( \%PAGE );

	my $items = items_of( open_feed($PROGRAMS_FEED), 'programs' );
	is( scalar @$items, 46, '46 line-up programs' );
	is_deeply( [ map { lc $_->{name} } @$items ], [ sort map { lc $_->{name} } @$items ], 'sorted by name' );
	my ($sj) = grep { $_->{name} eq 'Saturday Jazz' } @$items;
	is( $sj->{line2}, $SJ_SCHEDULE, 'with schedules' );
	is( $sj->{image}, $SJ_TEASE_IMAGE, 'and artwork' );
	ok( ( grep { $_->{name} eq 'Get Up Morning' } @$items ), 'WordPress names' );
};

subtest 'fallback: both failed gives LOAD_FAILED; no overlap gives the Airnet list' => sub {
	reset_all();
	route( "$BASE/programs", error => 'Connect timed out' );
	routeLineup( { 1 => { code => 503 } } );
	is_deeply( items_of( open_feed($PROGRAMS_FEED), 'both failed' ), [$LOAD_FAILED], 'both failed: one LOAD_FAILED item' );

	reset_all();
	routeAirnet();
	my $items = itemsOverlapless();
	is( scalar @$items, 57, 'no line-up slug known to Airnet: the 57 Airnet programs' );
	ok( ( grep { $_->{message} =~ /Airnet/ } warnings_logged() ), 'logged as a warning' );
};

sub itemsOverlapless {
	my $items = JSON::PP->new->utf8->decode( $PAGE{1} )->{data}->{items};
	$items =~ s{/shows/([a-z0-9_-]+)/}{/shows/$1-new/}g;
	$items =~ s/data-total-posts="47"/data-total-posts="12"/;
	routeLineup( { 1 => JSON::PP->new->utf8->encode( { success => JSON::PP::true, data => { items => $items } } ) } );
	return items_of( open_feed($PROGRAMS_FEED), 'no overlap' );
}

subtest '_programItem: shape' => sub {
	is_deeply(
		Plugins::RTRFM::OnDemand::_programItem( undef, { slug => 'x', name => 'X Show', image => undef } ),
		{ name => 'X Show', line1 => 'X Show', type => 'link', url => $PROGRAM_MENU, passthrough => [ { slug => 'x', name => 'X Show', image => undef } ], image => $ICON },
		'no image: station icon; no schedule: no line2'
	);

	my $program = { slug => 'x', name => 'X Show', image => 'https://example.test/x.jpg', schedule => 'Mondays 1.00pm - 2.00pm', hosts => ['A'], genres => [], extra => 1 };
	is_deeply(
		Plugins::RTRFM::OnDemand::_programItem( undef, $program ),
		{ name => 'X Show', line1 => 'X Show', line2 => 'Mondays 1.00pm - 2.00pm', type => 'link', url => $PROGRAM_MENU, passthrough => [$program], image => 'https://example.test/x.jpg' },
		'image and schedule used; the program hash is passed through untouched'
	);
};

# ---------------------------------------------------------------------------
# _programMenu: header + episodes
# ---------------------------------------------------------------------------

sub saturdayJazzFromList {
	my ($item) = grep { $_->{name} eq 'Saturday Jazz' } @{ items_of( open_feed($PROGRAMS_FEED), 'programs' ) };
	return $item;
}

subtest '_programMenu: header items, then the episodes' => sub {
	reset_all();
	routeAll();

	# open it the way XMLBrowser does, from the program item
	my $item  = saturdayJazzFromList();
	my $c     = open_feed( $item->{url}, @{ $item->{passthrough} } );
	my $items = items_of( $c, 'Saturday Jazz' );

	is( scalar @$items, 3 + 4, '3 header items + 4 episodes' );

	is( $items->[0]->{type}, 'textarea', '1: textarea' );
	is( $items->[0]->{wrap}, 1, '1: wrap' );
	like( $items->[0]->{name}, qr/\AThe best of Jazz from earliest recordings to present-day sounds\.\n\n/, '1: the show description' );
	is_deeply( [ sort keys %{ $items->[0] } ], [qw(name type wrap)], '1: keys name, type, wrap' );

	is_deeply( $items->[1], { name => $SJ_SCHEDULE, type => 'text' }, '2: the schedule' );
	is_deeply( $items->[2], { name => $SJ_HOSTED_BY, type => 'text' }, '3: "Hosted by: A, B, C, D +2 more"' );

	is_deeply(
		[ map { $_->{play} } @$items[ 3 .. 6 ] ],
		[ map { "rtrfm://episode/saturdayjazz/$_/0900" } qw(2026-09-19 2026-09-12 2026-09-05 2026-08-29) ],
		'then the episodes, newest first'
	);
	is( scalar( grep { $_->{image} eq $SJ_TEASE_IMAGE } @$items[ 3 .. 6 ] ), 4, 'episode items use the show artwork' );
	is( scalar @META_WRITES, 4, 'four metadata writes' );
	is( scalar( grep { $_->{image} eq $SJ_TEASE_IMAGE && $_->{show} eq 'Saturday Jazz' } @META_WRITES ), 4, 'the metadata cache gets the show artwork' );
	is( Plugins::RTRFM::Util::getEpisodeMeta( 'saturdayjazz', '2026-09-19' )->{image}, $SJ_TEASE_IMAGE, 'readable through getEpisodeMeta' );
	is( scalar( grep { $_->{url} eq $SJ_PAGE } requests() ), 1, 'one show page request' );

	my $before = scalar( () = requests() );
	items_of( open_feed( $item->{url}, @{ $item->{passthrough} } ), 're-open' );
	is( scalar( grep { $_->{url} eq $SJ_PAGE } requests() ), 1, 're-opening: the show page comes from the cache' );
	is( scalar( () = requests() ), $before, 're-opening: no HTTP request at all' );
};

subtest '_sortPrograms: case-insensitive by name, then slug' => sub {
	my $sorted = Plugins::RTRFM::OnDemand::_sortPrograms(
		[ { name => 'zed', slug => 'z' }, { name => 'Black & Blue', slug => 'blackandblue' }, { name => 'alpha', slug => 'a2' }, { name => 'Alpha', slug => 'a1' } ]
	);
	is_deeply( [ map { $_->{slug} } @$sorted ], [qw(a1 a2 blackandblue z)], 'unsorted line-up comes out in name order' );
};

subtest '_programMenu: the show page fails' => sub {
	reset_all();
	routeAirnet();
	routeLineup( \%PAGE );
	route( $SJ_PAGE, code => 404 );

	my $item  = saturdayJazzFromList();
	my $items = items_of( open_feed( $item->{url}, @{ $item->{passthrough} } ), 'Saturday Jazz' );

	is( scalar @$items, 2 + 4, 'no description: 2 header items + 4 episodes' );
	is_deeply( [ @$items[ 0, 1 ] ], [ { name => $SJ_SCHEDULE, type => 'text' }, { name => $SJ_HOSTED_BY, type => 'text' } ], 'schedule and hosts from the line-up' );
	is( $items->[2]->{play}, 'rtrfm://episode/saturdayjazz/2026-09-19/0900', 'then the episodes' );
	is( $items->[2]->{image}, $SJ_TEASE_IMAGE, 'with the tease artwork' );
};

subtest '_programMenu: no tease image, so og:image is awaited and passed on' => sub {
	reset_all();
	routeAirnet();
	routeShowPage();

	# a program from the Airnet fallback list: no image, schedule or hosts
	my $program = { slug => 'saturdayjazz', name => 'Saturday Jazz', image => undef };
	my $items   = items_of( open_feed( $PROGRAM_MENU, $program ), 'Saturday Jazz (Airnet)' );

	is( scalar @$items, 1 + 4, 'description + 4 episodes (no schedule or hosts to show)' );
	is( $items->[0]->{type}, 'textarea', 'description first' );
	is( scalar( grep { $_->{image} eq $SJ_OG_IMAGE } @$items[ 1 .. 4 ] ), 4, 'episode items use the og:image' );
	is( scalar( grep { $_->{image} eq $SJ_OG_IMAGE } @META_WRITES ), 4, 'setEpisodeMeta gets the og:image' );
	is( Plugins::RTRFM::Util::getEpisodeMeta( 'saturdayjazz', '2026-09-12' )->{image}, $SJ_OG_IMAGE, 'readable through getEpisodeMeta' );
	is( $program->{image}, undef, 'the passthrough program hash is not modified' );

	my @urls = map { $_->{url} } requests();
	is_deeply( \@urls, [ $SJ_PAGE, "$BASE/programs/saturdayjazz/episodes" ], 'the show page is fetched before the episodes' );

	# and when that show page fails too: station icon, no header
	reset_all();
	routeAirnet();
	route( $SJ_PAGE, error => 'Timed out waiting for data' );
	$items = items_of( open_feed( $PROGRAM_MENU, $program ), 'Saturday Jazz (Airnet), no show page' );
	is( scalar @$items, 4, 'just the 4 episodes' );
	is( scalar( grep { $_->{image} eq $ICON } @$items ), 4, 'with the station icon' );
};

subtest '_programMenu: episode errors keep the header; exactly one callback' => sub {
	reset_all();
	routeLineup( \%PAGE );
	routeShowPage();
	route( "$BASE/programs", file => 'ondemand/programs.json' );
	route( "$BASE/programs/saturdayjazz/episodes", code => 500 );

	my $item  = saturdayJazzFromList();
	my $items = items_of( open_feed( $item->{url}, @{ $item->{passthrough} } ), 'episodes fail' );
	is( scalar @$items, 4, 'header (3) + LOAD_FAILED' );
	is_deeply( $items->[3], $LOAD_FAILED, 'the episode feed\'s error item follows the header' );

	# a misbehaving episode feed that calls back twice, late
	reset_all();
	routeShowPage();
	my @pending;
	no warnings 'redefine';
	local *Plugins::RTRFM::OnDemand::_episodesFeed = sub {
		my ( $client, $cb ) = @_;
		push @pending, $cb;
	};
	my $c = open_feed( $PROGRAM_MENU, $item->{passthrough}->[0] );
	is( $c->count, 0, 'no callback before the episodes arrive' );
	is( scalar @pending, 1, '_episodesFeed was called once' );
	$pending[0]->( { items => [ { name => 'E1', type => 'audio' } ] } );
	is( $c->count, 1, 'called back when the episodes arrive' );
	$pending[0]->( { items => [ { name => 'E2', type => 'audio' } ] } );
	is( $c->count, 1, 'a second episode callback is ignored' );
	is_deeply( [ map { $_->{name} } @{ ( $c->args(0) )[0]->{items} } ], [ ( ( $c->args(0) )[0]->{items}->[0]->{name} ), $SJ_SCHEDULE, $SJ_HOSTED_BY, 'E1' ], 'header, then the first episode list' );

	# a show page that answers after the episodes
	reset_all();
	my @showPage;
	local *Plugins::RTRFM::Shows::showPage = sub { push @showPage, $_[1] };
	local *Plugins::RTRFM::OnDemand::_episodesFeed = sub { $_[1]->( { items => [ { name => 'E1', type => 'audio' } ], extra => 'kept' } ) };
	$c = open_feed( $PROGRAM_MENU, $item->{passthrough}->[0] );
	is( $c->count, 0, 'episodes first: waits for the show page' );
	$showPage[0]->( { description => 'About the show.', image => undef } );
	is( $c->count, 1, 'then calls back once' );
	is_deeply(
		( $c->args(0) )[0],
		{ items => [ { name => 'About the show.', type => 'textarea', wrap => 1 }, { name => $SJ_SCHEDULE, type => 'text' }, { name => $SJ_HOSTED_BY, type => 'text' }, { name => 'E1', type => 'audio' } ], extra => 'kept' },
		'header + episodes; other keys of the episode feed result are kept'
	);
	$showPage[0]->( { description => 'Again.' } );
	is( $c->count, 1, 'a second show page callback is ignored' );
};

subtest '_programMenu: hosts line variants' => sub {
	reset_all();
	no warnings 'redefine';
	local *Plugins::RTRFM::Shows::showPage = sub { $_[1]->( undef, 'down' ) };
	local *Plugins::RTRFM::OnDemand::_episodesFeed = sub { $_[1]->( { items => [] } ) };

	my %cases = (
		'one host'            => [ ['Pamela Boland'],                    'Hosted by: Pamela Boland' ],
		'four hosts'          => [ [ 'A', 'B', 'C', 'D' ],                'Hosted by: A, B, C, D' ],
		'more hosts'          => [ [ 'A', 'B', 'C', 'D', '+4 more' ],    'Hosted by: A, B, C, D +4 more' ],
	);
	for my $name ( sort keys %cases ) {
		my ( $hosts, $line ) = @{ $cases{$name} };
		my $items = items_of( open_feed( $PROGRAM_MENU, { slug => 'x', name => 'X', image => 'i.jpg', hosts => $hosts } ), $name );
		is_deeply( $items, [ { name => $line, type => 'text' } ], "$name: $line" );
	}

	my $items = items_of( open_feed( $PROGRAM_MENU, { slug => 'x', name => 'X', image => 'i.jpg', hosts => [], schedule => '' } ), 'no hosts' );
	is_deeply( $items, [], 'no hosts, empty schedule, no description: no header items' );
};

clearTime();
done_testing();
