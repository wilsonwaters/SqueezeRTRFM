#!/usr/bin/perl
# Plugins::RTRFM::Shows: the rtrfm.com.au line-up (WordPress filter_shows pages: tease parsing,
# srcset choice, hosts and genres, entity decoding, paging stop conditions, training dropped,
# duplicates), show pages (description, og:image), caching and no-caching of failures, and
# defensive parsing of unexpected markup.
#
# Fixtures in t/data/ondemand/ were recorded from rtrfm.com.au on 2026-09-26 (about 09:30 UTC):
# filter-shows-page{1..5}.json are the admin-ajax filter_shows responses for pages 1-5, with the
# decorative <svg> arrows and indentation removed; show-saturdayjazz.html is /shows/saturdayjazz/
# trimmed to its <head> meta tags and the show header section. filter-shows-nosrcset.json and
# show-minimal.html are synthetic edge cases.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use JSON::PP ();
use Time::Local qw(timegm);
use URI::Escape qw(uri_unescape);

use Slim::Utils::Cache;

use Plugins::RTRFM::Shows;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $AJAX    = 'https://rtrfm.com.au/wp-admin/admin-ajax.php';
my $UPLOADS = 'https://rtrfm.com.au/wp-content/uploads';
my $NOW     = timegm( 0, 30, 9, 26, 8, 2026 );

my %PAGE = map { $_ => fixture("ondemand/filter-shows-page$_.json") } 1 .. 5;

sub cache { Slim::Utils::Cache->new('rtrfm') }

# The items HTML of a filter_shows fixture.
sub itemsOf { JSON::PP->new->utf8->decode( $_[0] )->{data}->{items} }

# A filter_shows response (UTF-8 JSON bytes) around an items HTML string.
sub response { JSON::PP->new->utf8->canonical->encode( { success => JSON::PP::true, data => { items => $_[0], postsPerPage => 12 } } ) }

# Parse the page number out of a filter_shows form body.
sub pageOf {
	my $body = shift // '';
	return $body =~ /(?:^|&)page=(\d+)/ ? $1 : undef;
}

# Route admin-ajax POSTs by page number: $pages->{N} is a response hash, or JSON content.
# Unlisted pages fail like a network error.
sub routeLineup {
	my $pages = shift;
	Slim::Networking::SimpleAsyncHTTP->addRoute(
		$AJAX,
		sub {
			my ( $url, $method, $body ) = @_;
			my $page = $pages->{ pageOf($body) // '' };
			return undef unless defined $page;
			return ref $page ? $page : { code => 200, content => $page, headers => { 'Content-Type' => 'application/json; charset=UTF-8' } };
		}
	);
}

sub lineupRequests { grep { $_->{url} eq $AJAX } requests() }
sub requestedPages { map { pageOf( $_->{body} ) } lineupRequests() }

sub getLineup {
	my $c = collector();
	Plugins::RTRFM::Shows::lineup( $c->cb );
	return $c;
}

sub getShowPage {
	my $slug = shift;
	my $c    = collector();
	Plugins::RTRFM::Shows::showPage( $slug, $c->cb );
	return $c;
}

sub bySlug { my %h = map { $_->{slug} => $_ } @{ $_[0] }; return \%h }

sub reset_all {
	resetStubs();
	setTime($NOW);
}

# ---------------------------------------------------------------------------
# Tease parsing
# ---------------------------------------------------------------------------

subtest 'parseLineupPage: page 1 (12 teases, total 47)' => sub {
	my $page = Plugins::RTRFM::Shows::parseLineupPage( itemsOf( $PAGE{1} ) );

	is( $page->{total}, 47, 'data-total-posts = 47' );
	is( scalar @{ $page->{shows} }, 12, '12 shows' );

	is_deeply(
		$page->{shows}->[0],
		{
			slug     => 'allcity',
			name     => 'All City',
			schedule => 'Fridays 11.00pm - 1.00am',
			image    => "$UPLOADS/2012/12/all-city-banner-1-edit_-768x432.jpg",
			hosts    => [ 'Connor Kiss', 'Emma Archer', 'Lucan Lono (Rhys Prka)', 'Dr. J', '+4 more' ],
			genres   => [ 'Beats', 'Hip Hop' ],
		},
		'first show: slug, name, schedule (whitespace collapsed), 768w image, hosts with "+4 more", genres'
	);

	my $shows = bySlug( $page->{shows} );
	is( $shows->{blackandblue}->{name}, 'Black & Blue', '"Black &#038; Blue" is decoded' );
	is( $shows->{breakfast}->{name}, 'Breakfast with Pam', 'Breakfast with Pam' );
	is( $shows->{breakfast}->{schedule}, 'Weekdays 6.00am - 9.00am', 'Weekdays schedule' );
	is_deeply( $shows->{breakfast}->{hosts}, ['Pamela Boland'], 'a single host, no "+N more"' );
	is_deeply( $shows->{allthingsqueer}->{hosts}, [ 'Harriet Kenny', 'Lee', 'Bobby Fletcher', 'Kendall Buckley' ], 'exactly four hosts' );
	is_deeply( $shows->{ambientzone}->{genres}, [ 'Ambient', 'Electronic', '+1' ], 'genre chips as shown, including the "+1" overflow chip' );
	is( $shows->{cloudwaves}->{name}, 'Cloud Waves', 'WordPress name "Cloud Waves"' );
	is( scalar( grep { $_->{image} =~ m{\A\Q$UPLOADS\E/.+-768x\d+\.(?:jpg|png)\z} } @{ $page->{shows} } ), 12, 'every image is the 768w candidate' );
	is( $shows->{basscheck}->{image}, "$UPLOADS/2012/12/BassCheck1-1-768x432.png", 'a PNG' );
};

subtest 'parseLineupPage: names, schedules and multi-byte text on pages 2-4' => sub {
	my %shows = map { %{ bySlug( Plugins::RTRFM::Shows::parseLineupPage( itemsOf( $PAGE{$_} ) )->{shows} ) } } 2 .. 4;

	is( $shows{rhythmtrippin}->{name}, "Rhythm Trippin\x{2019}", '"Rhythm Trippin&#8217;" becomes "Rhythm Trippin’"' );
	is( $shows{rockrattle}->{name},    'Rock, Rattle & Roll',    '"Rock, Rattle &#038; Roll"' );
	is( $shows{roots}->{name},         "Rockin\x{2019} The Roots", '"Rockin&#8217; The Roots"' );
	is( $shows{getupmorning}->{name},  'Get Up Morning',         'getupmorning is "Get Up Morning"' );

	is( $shows{drivetime}->{schedule},   'Weekdays 5.00pm - 7.00pm',             'Weekdays' );
	is( $shows{ontherecord}->{schedule}, 'Mondays - Thursdays 9.00am - 11.00am', 'day range' );
	is( $shows{snoozebutton}->{schedule}, 'Saturdays - Fridays 4.00am - 6.00am', 'wrapping day range' );
	is( $shows{revolver}->{schedule},    'Tuesdays 11.00am-12.00pm',             'no spaces around the dash' );
	is( $shows{training}->{schedule},    'No times 6-8pm',                       'training parses (lineup drops it)' );

	is_deeply( $shows{snoozebutton}->{hosts}, [ 'Orana', 'Shaz Sims', 'Kyle Springer', 'Phil Arnell', '+30 more' ], '"+ 30" becomes "+30 more"' );
	is( $shows{indymedia}->{hosts}->[3], "Zo\x{eb} Theiadore", 'JSON \\u escapes decoded (Zoë)' );
	is( $shows{spoonful}->{hosts}->[1], "Simon Johnson (Rhymin\x{2019} Simon)", 'curly quote in a host name' );
	is_deeply( $shows{saturdayjazz},
		{
			slug     => 'saturdayjazz',
			name     => 'Saturday Jazz',
			schedule => 'Saturdays 9.00am - 11.00am',
			image    => "$UPLOADS/2012/12/SaturdayJazz-768x432.jpg",
			hosts    => [ 'Dan Garner', 'Ben Bartholomew', "Wayne G'Froerer", 'Alf Micallef', '+2 more' ],
			genres   => ['Jazz'],
		},
		'Saturday Jazz'
	);

	is( $shows{woodstock}->{image}, "$UPLOADS/2012/12/Woodstock-Rock.png", 'Woodstock Rock has no 768w: the 720w original (smallest of at least 600w, not the 300w)' );
	is( $shows{jamdown}->{image}, "$UPLOADS/2012/12/JamdownVershun-768x432.webp", 'a WebP 768w' );

	is( scalar @{ Plugins::RTRFM::Shows::parseLineupPage( itemsOf( $PAGE{4} ) )->{shows} }, 11, 'page 4: 11 teases' );
	is_deeply( Plugins::RTRFM::Shows::parseLineupPage( itemsOf( $PAGE{5} ) ), { shows => [], total => undef }, 'page 5 ("Sorry, no results found"): no shows, no total' );
};

subtest 'parseLineupPage: srcset choice and odd teases (synthetic)' => sub {
	my $page  = Plugins::RTRFM::Shows::parseLineupPage( itemsOf( fixture('ondemand/filter-shows-nosrcset.json') ) );
	my $shows = bySlug( $page->{shows} );

	is( $page->{total}, undef, 'no data-total-posts' );
	is_deeply( [ map { $_->{slug} } @{ $page->{shows} } ], [qw(noartwork no768 smallonly srconly no768 drivetime)], 'teases without a link, a name or a valid slug are skipped; duplicates are kept here' );

	is_deeply(
		$page->{shows}->[0],
		{ slug => 'noartwork', name => 'No Artwork & Friends', schedule => 'Sundays 3.00am - 4.00am', image => undef, hosts => [], genres => [] },
		'a tease without a srcset (or src) gives image undef; the "Show" label before the name is not a genre'
	);
	is( $page->{shows}->[1]->{image}, "$UPLOADS/2020/01/no768-640x360.jpg", 'no 768w: the smallest candidate of at least 600w' );
	is( $shows->{smallonly}->{image}, "$UPLOADS/2020/01/small-300x169.jpg", 'all below 600w: the largest (comma without a space)' );
	is( $shows->{srconly}->{image}, "$UPLOADS/2020/01/odd%20name(1).jpg?x=1&y=2", 'no srcset: src, entity-decoded, odd characters passed through (data-srcset ignored)' );
	is( $shows->{drivetime}->{image}, "$UPLOADS/2020/01/drive-768x432.jpg", 'two 768w candidates: the first' );
	is( $shows->{drivetime}->{name}, 'Drivetime (Monday)', 'multi-day show' );
	is( $shows->{smallonly}->{name}, "Small \x{2018}Only\x{2019}", 'single-quoted attributes, curly quotes' );

	is( $page->{shows}->[1]->{schedule}, 'Mondays 1.00pm - 2.00pm', 'the font-mono schedule span is not a host' );
	is_deeply( $page->{shows}->[1]->{hosts}, [ 'Solo Host', '+12 more' ], 'hosts' );
	is_deeply( $page->{shows}->[1]->{genres}, ['Jazz'], 'genres' );
	is_deeply( $shows->{srconly}->{hosts}, [], '"Hosted by" with no hosts' );
	is( $shows->{srconly}->{schedule}, undef, 'no schedule span: undef (the "Hosted by:" label is not a schedule)' );
	ok( !$shows->{notatease}, 'class "tease-showcase" is not a tease' );
};

# ---------------------------------------------------------------------------
# lineup(): paging, filtering, caching
# ---------------------------------------------------------------------------

subtest 'lineup: pages 1-4, stops at the total of 47, drops training' => sub {
	reset_all();
	routeLineup( \%PAGE );

	my $c = getLineup();
	is( $c->count, 1, 'one callback' );
	my ( $shows, $error ) = $c->args(0);

	is( $error, undef, 'no error' );
	is( ref $shows, 'ARRAY', 'a list' );
	is( scalar @$shows, 46, '47 teases minus training = 46 shows' );
	ok( !( grep { $_->{slug} eq 'training' } @$shows ), 'training dropped' );
	is_deeply( [ requestedPages() ], [ 1, 2, 3, 4 ], 'four requests (pages 1-4 together): page 5 is never fetched because 47 were collected' );
	is( $shows->[0]->{slug}, 'allcity', 'site order' );
	is( scalar( grep { $_->{image} } @$shows ), 46, 'every show has an image' );

	my ($req) = lineupRequests();
	is( $req->{method}, 'POST', 'POST' );
	is( $req->{headers}->header('Content-Type'), 'application/x-www-form-urlencoded', 'form-encoded' );
	like( $req->{headers}->header('User-Agent'), qr/\S/, 'explicit User-Agent (HTTP.pm)' );
	unlike( $req->{headers}->header('User-Agent'), qr/libwww-perl/, 'not a libwww-perl User-Agent' );
	my %form;
	for ( split /&/, $req->{body} ) {
		my ( $k, $v ) = map { uri_unescape($_) } split /=/, $_, 2;
		push @{ $form{$k} }, $v;
	}
	is_deeply( \%form, { action => ['filter_shows'], search => [''], 'postTypes[]' => ['show'], page => ['1'] }, 'form fields action, search (empty), postTypes[]=show, page' );
};

subtest 'lineup: cached for 24 hours, then fetched again' => sub {
	reset_all();
	routeLineup( \%PAGE );

	getLineup();
	is( scalar( lineupRequests() ), 4, 'first call: 4 requests' );
	ok( ref cache()->get('shows:lineup') eq 'ARRAY', "cached under 'shows:lineup' in the rtrfm namespace" );

	advanceTime( 23 * 3600 );
	my $c = getLineup();
	is( scalar( lineupRequests() ), 4, 'within 24 hours: no new request' );
	is( scalar @{ ( $c->args(0) )[0] }, 46, 'cached list: 46 shows' );

	advanceTime( 3600 + 1 );
	getLineup();
	is( scalar( lineupRequests() ), 8, 'after 24 hours: fetched again' );
};

subtest 'lineup: without data-total-posts, stops at the empty page 5' => sub {
	reset_all();
	( my $page1 = $PAGE{1} ) =~ s/ data-total-posts=\\"47\\"//;
	isnt( $page1, $PAGE{1}, 'total removed from page 1' );
	routeLineup( { %PAGE, 1 => $page1 } );

	my ($shows) = getLineup()->args(0);
	is( scalar @$shows, 46, '46 shows' );
	is_deeply( [ requestedPages() ], [ 1, 2, 3, 4, 5 ], 'five requests: pages 1-4 together, then page 5 on its own, which is empty' );
};

subtest 'lineup: a too-large total still stops at the first empty page' => sub {
	reset_all();
	( my $page1 = $PAGE{1} ) =~ s/data-total-posts=\\"47\\"/data-total-posts=\\"99\\"/;
	routeLineup( { %PAGE, 1 => $page1, map { $_ => $PAGE{5} } 6 .. 10 } );

	my ($shows) = getLineup()->args(0);
	is( scalar @$shows, 46, 'still 46 shows' );
	is_deeply( [ requestedPages() ], [ 1 .. 9 ], 'pages 1-4, then pages 5-9 (enough for 99 shows) together; pages after the first empty one are ignored' );
};

subtest 'lineup: pages after the end of the line-up are ignored, even failed ones' => sub {
	reset_all();
	( my $page1 = $PAGE{1} ) =~ s/data-total-posts=\\"47\\"/data-total-posts=\\"12\\"/;
	routeLineup( { 1 => $page1, 2 => { code => 500 }, 3 => { error => 'Timed out' }, 4 => $PAGE{4} } );
	my ( $shows, $error ) = getLineup()->args(0);
	is( $error, undef, 'total 12 reached on page 1: failed pages 2 and 3 do not matter' );
	is( scalar @$shows, 12, '12 shows' );
	is_deeply( [ requestedPages() ], [ 1, 2, 3, 4 ], 'the first four pages were requested together' );

	reset_all();
	routeLineup( { %PAGE, 2 => $PAGE{5}, 4 => { code => 500 } } );
	( $shows, $error ) = getLineup()->args(0);
	is( $error, undef, 'empty page 2: pages 3 and 4 (failed) are ignored' );
	is( scalar @$shows, 12, 'page 1 only: 12 shows' );
	ok( ref cache()->get('shows:lineup') eq 'ARRAY', 'a line-up that ends at an empty page is complete, so it is cached' );
};

subtest 'lineup: safety cap of 10 pages' => sub {
	reset_all();
	my $items = itemsOf( $PAGE{1} );
	$items =~ s/ data-total-posts="47"//;
	my %pages;
	for my $n ( 1 .. 12 ) {
		( my $copy = $items ) =~ s{/shows/([a-z0-9_-]+)/}{/shows/$1-p$n/}g;
		$pages{$n} = response($copy);
	}
	routeLineup( \%pages );

	my ($shows) = getLineup()->args(0);
	is_deeply( [ requestedPages() ], [ 1 .. 10 ], 'pages 1-10, never page 11' );
	is( scalar @$shows, 120, '120 shows from 10 full pages' );
};

subtest 'lineup: duplicate slugs across pages keep the first' => sub {
	reset_all();
	my $items = itemsOf( $PAGE{1} );
	$items =~ s/ data-total-posts="47"//;
	( my $dup = $items ) =~ s{<h5([^>]*)>\s*All City\s*</h5>}{<h5$1>All City (again)</h5>};
	isnt( $dup, $items, 'renamed the copy' );
	routeLineup( { 1 => response($items), 2 => response($dup), 3 => $PAGE{4}, 4 => $PAGE{5} } );

	my ($shows) = getLineup()->args(0);
	is_deeply( [ requestedPages() ], [ 1, 2, 3, 4 ], 'four requests' );
	is( scalar @$shows, 22, '12 + 11 - training = 22 unique shows' );
	is( bySlug($shows)->{allcity}->{name}, 'All City', 'the first occurrence wins' );
};

subtest 'lineup: any failed page is an error and nothing is cached' => sub {
	for my $case (
		[ 'page 1 HTTP 500',            { 1 => { code => 500 } } ],
		[ 'page 3 times out',           { 3 => { error => 'Timed out waiting for data' } } ],
		[ 'page 2 success:false',       { 2 => '{"success":false,"data":null}' } ],
		[ 'page 1 not JSON',            { 1 => '<html>Cloudflare</html>' } ],
		[ 'page 1 without data.items',  { 1 => '{"success":true,"data":{"postsPerPage":12}}' } ],
		[ 'page 4 items not a string',  { 4 => '{"success":true,"data":{"items":["x"]}}' } ],
		[ 'page 1 is empty (no shows)', { 1 => $PAGE{5} } ],
	) {
		my ( $name, $override ) = @$case;
		reset_all();
		routeLineup( { %PAGE, %$override } );

		my $c = getLineup();
		is( $c->count, 1, "$name: one callback" );
		my ( $shows, $error ) = $c->args(0);
		is( $shows, undef, "$name: no list" );
		like( $error, qr/\S/, "$name: an error message" );
		is( cache()->get('shows:lineup'), undef, "$name: nothing cached" );
	}

	# not cached: the next call fetches again and succeeds
	reset_all();
	routeLineup( { %PAGE, 3 => { code => 503 } } );
	getLineup();
	Slim::Networking::SimpleAsyncHTTP->reset;
	routeLineup( \%PAGE );
	my ($shows) = getLineup()->args(0);
	is( scalar @$shows, 46, 'after a failure the next call fetches again: 46' );
	is_deeply( [ requestedPages() ], [ 1, 2, 3, 4 ], 'all four pages requested again' );
};

# ---------------------------------------------------------------------------
# showPage()
# ---------------------------------------------------------------------------

subtest 'showPage: Saturday Jazz description and og:image' => sub {
	reset_all();
	route( 'https://rtrfm.com.au/shows/saturdayjazz/', file => 'ondemand/show-saturdayjazz.html', headers => { 'Content-Type' => 'text/html; charset=UTF-8' } );

	my $c = getShowPage('saturdayjazz');
	is( $c->count, 1, 'one callback' );
	my ( $page, $error ) = $c->args(0);
	is( $error, undef, 'no error' );

	is( $page->{image}, "$UPLOADS/2012/12/SaturdayJazz.jpg", 'og:image (not og:image:width)' );
	like( $page->{description}, qr/\AThe best of Jazz from earliest recordings to present-day sounds\.\n\nThe most rounded program/, 'description starts with the first paragraph, then a blank line' );
	my @paragraphs = split /\n\n/, $page->{description};
	is( scalar @paragraphs, 3, 'three paragraphs' );
	like( $paragraphs[1], qr/on Perth\x{2019}s airwaves/, 'UTF-8 text decoded (Perth’s)' );
	like( $paragraphs[2], qr/So, get your jazz fix here every Saturday Morning of the year\.\z/, 'last paragraph complete' );
	unlike( $page->{description}, qr/Read more|Jazz\s*\z|</, 'nothing after the description block, no tags' );
	is_deeply( [ sort keys %$page ], [qw(description image)], 'keys: description, image' );

	my @req = requests();
	is( scalar @req, 1, 'one request' );
	is( $req[0]->{method}, 'GET', 'GET' );
	unlike( $req[0]->{headers}->header('User-Agent') // '', qr/libwww-perl/, 'HTTP.pm User-Agent' );

	advanceTime( 23 * 3600 );
	is_deeply( ( getShowPage('saturdayjazz')->args(0) )[0], $page, 'within 24 hours: same result from the cache' );
	is( scalar( () = requests() ), 1, 'no new request' );

	advanceTime( 3600 + 1 );
	getShowPage('saturdayjazz');
	is( scalar( () = requests() ), 2, 'after 24 hours: fetched again' );
};

subtest 'parseShowPage: synthetic markup' => sub {
	my $page = Plugins::RTRFM::Shows::parseShowPage( fixture('ondemand/show-minimal.html') );

	is( $page->{image}, "$UPLOADS/2020/01/Minimal%20Show.png?v=1&w=2", 'first og:image; content before property, single quotes, entities decoded' );
	is(
		$page->{description},
		"First line & more.\nSecond line\n\nNested paragraph with \x{2018}quotes\x{2019} and caf\x{e9}.\n\nLast paragraph.",
		'class token match (not post-description-wrapper), nested div, <br>, entities, &nbsp;; scripts and comments ignored'
	);

	is_deeply( Plugins::RTRFM::Shows::parseShowPage('<html><head><title>x</title></head><body><p>Nothing here</p></body></html>'), { description => undef, image => undef }, 'no description or og:image: both undef' );
	is_deeply( Plugins::RTRFM::Shows::parseShowPage('<div class="post-description">   </div>'), { description => undef, image => undef }, 'empty description: undef' );
	is( Plugins::RTRFM::Shows::parseShowPage('<div class="post-description"><p>Unclosed')->{description}, 'Unclosed', 'unclosed description block: the rest of the page' );
	my $long = Plugins::RTRFM::Shows::parseShowPage( '<div class="post-description"><p>' . ( 'word <b>bold</b> ' x 20_000 ) )->{description};
	ok( length $long > 1000 && length $long <= 64 * 1024 && $long !~ /</, 'a huge unclosed block is cut at 64 KB of markup, without a half tag' );
	is( Plugins::RTRFM::Shows::parseShowPage('<div class="post-description"> </div><div class="post-description"><p>Second</p></div>')->{description}, undef, 'only the first description block counts' );
};

subtest 'showPage: errors are reported and not cached' => sub {
	reset_all();
	route( 'https://rtrfm.com.au/shows/gone/', code => 404, content => '<html>Not found</html>' );
	my $c = getShowPage('gone');
	is( $c->count, 1, '404: one callback' );
	my ( $page, $error ) = $c->args(0);
	is( $page, undef, '404: no result' );
	like( $error, qr/404/, '404: error message' );
	is( cache()->get('shows:page:gone'), undef, '404: not cached' );

	route( 'https://rtrfm.com.au/shows/empty/', content => '<html><body>Just a moment...</body></html>' );
	($page) = getShowPage('empty')->args(0);
	is_deeply( $page, { description => undef, image => undef }, 'a page without description or image: empty result' );
	is( cache()->get('shows:page:empty'), undef, 'an empty result is not cached' );

	for my $slug ( undef, '', 'drivetime/monday', '../etc', "sj\n", 'Saturday Jazz' ) {
		resetStubs();
		my $c = getShowPage($slug);
		my ( $page, $error ) = $c->args(0);
		my $label = defined $slug ? "'" . ( $slug =~ s/\n/\\n/gr ) . "'" : 'undef';
		ok( $c->count == 1 && !defined $page && $error, "invalid slug $label: one error callback" );
		is( scalar( () = requests() ), 0, "invalid slug $label: no request" );
	}
};

# ---------------------------------------------------------------------------
# Defensive parsing
# ---------------------------------------------------------------------------

subtest 'garbage never dies, and big pages parse quickly' => sub {
	my $big = fixture('ondemand/show-saturdayjazz.html');
	$big =~ s{</body>}{ ( '<div class="x"><span>filler &amp; text</span><img src="a.jpg"></div>' x 6000 ) . '</body>' }e;
	ok( length $big > 400_000, 'a padded show page over 400 KB' );

	my @garbage = (
		undef, '', 0, ' ', "\0\x{FFFD}\xff\xfe", [], {},
		'<', '<<<<', '>>>>', '<div', '<div class="tease-show"', '<div class="tease-show"><a href=', '<h5>',
		'<div class="tease-show"><a href="/shows/x/"><h5>' . ( 'x' x 1000 ),
		'<div class="tease-show"><a href="https://rtrfm.com.au/shows/ok/"><img srcset="a 1w, , ,b, 768w"><h5>OK</h5><span>',
		'<div class="post-description">' . ( '<div>' x 5000 ),
		'<meta property="og:image">', '<meta property="og:image" content=>', '<!-- never closed <div class="tease-show">',
		'<script>' . ( '<div class="tease-show">' x 10 ),
		( '<div class="tease-show"><a href="/shows/a/"><h5>' x 20_000 ),
		( '<span ' x 50_000 ),
		( '<a "' x 50_000 ),
		( '<!--' x 50_000 ),
		( '<div class="post-description">' x 20_000 ),
		( '&#' x 100_000 ),
		$big,
	);

	my $start = time;
	for my $i ( 0 .. $#garbage ) {
		my $input = $garbage[$i];
		my ( $lineup, $show );
		my $ok = eval {
			local $SIG{ALRM} = sub { die "timeout\n" };
			alarm 20;
			$lineup = Plugins::RTRFM::Shows::parseLineupPage($input);
			$show   = Plugins::RTRFM::Shows::parseShowPage($input);
			alarm 0;
			1;
		};
		alarm 0;
		ok( $ok, "input $i: no exception" ) or diag $@;
		ok( ref $lineup eq 'HASH' && ref $lineup->{shows} eq 'ARRAY', "input $i: parseLineupPage returns { shows => [...] }" );
		ok( ref $show eq 'HASH', "input $i: parseShowPage returns a hash" );
	}

	my $page = Plugins::RTRFM::Shows::parseShowPage($big);
	like( $page->{description}, qr/\AThe best of Jazz/, 'the padded page still gives the description' );
	is( $page->{image}, "$UPLOADS/2012/12/SaturdayJazz.jpg", 'and the og:image' );
	cmp_ok( time - $start, '<', 20, 'all inputs parsed in well under the HTTP timeout' );
};

subtest 'lineup: a failure inside the parser is an error callback, not an exception' => sub {
	reset_all();
	routeLineup( \%PAGE );
	no warnings 'redefine';
	local *Plugins::RTRFM::Shows::parseLineupPage = sub { die "parser broke\n" };

	my $c = eval { getLineup() };
	ok( $c, 'no exception' );
	is( $c && $c->count, 1, 'one callback' );
	my ( $shows, $error ) = $c ? $c->args(0) : ();
	is( $shows, undef, 'no list' );
	like( $error, qr/parser broke/, 'error mentions the failure' );
	is( cache()->get('shows:lineup'), undef, 'nothing cached' );
};

clearTime();
done_testing();
