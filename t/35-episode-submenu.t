#!/usr/bin/perl
# Plugins::RTRFM::OnDemand episode rows and the episode submenu: the row is a link that also
# plays (and is favourited as audio), building episode lists makes no playlist requests, and
# opening an episode gives "Play episode", the description and "Track list (N)" (or the
# no-track-list / pending item), with the start-time fallbacks and exactly one callback.
# Uses the Airnet fixtures in t/data/ondemand/ (see t/32-airnet.t and t/34-tracklist.t).

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use Time::Local qw(timegm);

use Plugins::RTRFM::OnDemand;
use Plugins::RTRFM::Util;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

my $BASE = Plugins::RTRFM::Util::AIRNET_BASE;
my $ICON = Plugins::RTRFM::Util::ICON;

# 2026-09-26 03:40 UTC = 11:40 on Saturday 26 September in Perth.
my $NOW = timegm( 0, 40, 3, 26, 8, 2026 );

my $ENDASH = "\x{2013}";
my $MIDDOT = "\x{B7}";

my $SJ_URL = 'rtrfm://episode/saturdayjazz/2026-09-19/0900';

my $SATURDAY_JAZZ = { slug => 'saturdayjazz', name => 'Saturday Jazz', image => undef };

my $NO_TRACKLIST = { name => 'No track list available',      type => 'text' };
my $PENDING      = { name => 'Track list not yet available', type => 'text' };

sub playlistUrl {
	my ( $slug, $date, $hhmm ) = @_;
	my ( $h, $m ) = $hhmm =~ /^(\d\d)(\d\d)$/;
	return "$BASE/programs/$slug/episodes/$date+$h%3A$m%3A00/playlists";
}

sub routeAll {
	route( "$BASE/programs/saturdayjazz/episodes", file => 'ondemand/episodes-saturdayjazz.json' );
	route( playlistUrl( 'saturdayjazz', '2026-09-19', '0900' ), file => 'ondemand/playlist-saturdayjazz-2026-09-19.json' );
}

sub playlistRequests { grep { $_->{url} =~ m{/playlists$} } requests() }

# Run a feed the way XMLBrowser does: ($client, $callback, \%args, @passthrough). Returns the collector.
sub open_feed {
	my ( $feed, @passthrough ) = @_;
	my $c = collector();
	$feed->( undef, $c->cb, { params => {}, isControl => 1 }, @passthrough );
	return $c;
}

# Open an item's coderef url with its passthrough, like XMLBrowser.
sub open_item {
	my $item = shift;
	return open_feed( $item->{url}, @{ $item->{passthrough} || [] } );
}

sub items_of {
	my ( $c, $name ) = @_;
	is( $c->count, 1, "$name: exactly one callback" );
	my ($result) = $c->args(0);
	is( ref( $result && $result->{items} ), 'ARRAY', "$name: { items => [...] }" );
	return ( $result && $result->{items} ) || [];
}

# The Saturday Jazz episode items at $NOW (4 episodes, newest first).
sub jazzEpisodes {
	return items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodesFeed, $SATURDAY_JAZZ ), 'Saturday Jazz episodes' );
}

# An episode hash like Airnet::episodes returns, for Saturday Jazz 2026-09-19.
sub episode {
	return {
		slug        => 'saturdayjazz',
		date        => '2026-09-19',
		hhmm        => '0900',
		start       => '2026-09-19 09:00:00',
		end         => '2026-09-19 11:00:00',
		duration    => 7200,
		title       => 'Saturday Jazz with Laura Igglesden',
		description => undef,
		@_,
	};
}

sub openEpisode {
	my ( $name, $episode, $program ) = @_;
	return items_of( open_feed( \&Plugins::RTRFM::OnDemand::_episodeMenu, $program || $SATURDAY_JAZZ, $episode ), $name );
}

sub playItem {
	my ( $url, %extra ) = @_;
	return { name => 'Play episode', type => 'audio', url => $url, play => $url, on_select => 'play', duration => 7200, image => $ICON, %extra };
}

# Copies of LMS 9.1.1 Slim::Control::XMLBrowser::hasAudio (l.1743) and _favoritesParams
# (l.1925), trimmed to what applies to these items: what "isaudio" and "Add to favourites" use.
sub lmsHasAudio {
	my $item = shift;
	return $item->{play} if $item->{play};
	return $item->{url} if $item->{type} && $item->{type} =~ /^(?:audio|playlist)$/;
	return undef;
}

sub lmsFavoritesParams {
	my $item  = shift;
	my $url   = $item->{favorites_url} || $item->{play} || $item->{url};
	my $title = $item->{favorites_title} || $item->{title} || $item->{name};
	return undef unless $url && !ref $url && $title;
	return { favorites_url => $url, favorites_title => $title, favorites_type => $item->{favorites_type} || ( $item->{play} ? 'audio' : ( $item->{type} || 'audio' ) ) };
}

sub reset_all {
	resetStubs();
	routeAll();
	setTime($NOW);
}

subtest 'episode row: a link that also plays, no on_select' => sub {
	reset_all();

	my $items = jazzEpisodes();
	my $item  = $items->[0];

	is( $item->{type}, 'link', 'type link' );
	is( $item->{play}, $SJ_URL, "play = $SJ_URL" );
	is( ref $item->{url}, 'CODE', 'url is a coderef' );
	is( $item->{url}, \&Plugins::RTRFM::OnDemand::_episodeMenu, 'url is _episodeMenu' );
	ok( !exists $item->{on_select}, 'no on_select (touch skins open it instead of playing)' );

	is_deeply(
		$item,
		{
			name        => "Sat 19 Sep $ENDASH Saturday Jazz with Laura Igglesden",
			line1       => 'Saturday Jazz with Laura Igglesden',
			line2       => "Sat 19 Sep $MIDDOT 09:00${ENDASH}11:00",
			type        => 'link',
			url         => \&Plugins::RTRFM::OnDemand::_episodeMenu,
			passthrough => [ $SATURDAY_JAZZ, episode() ],
			play        => $SJ_URL,
			duration    => 7200,
			image       => $ICON,
		},
		"exact keys: O2's name/line1/line2/image/duration, play, url + passthrough [program, episode]"
	);

	is( $items->[1]->{play}, 'rtrfm://episode/saturdayjazz/2026-09-12/0900', 'second row plays its own URL' );
	is( $items->[1]->{passthrough}->[1]->{description}, 'Presented by Ben Bartholomew. Featuring tracks from the debut album by local ensemble the Kirsten Sym Undectet.', 'the episode hash passes through with its description' );

	is( lmsHasAudio($item), $SJ_URL, 'LMS hasAudio: playable (isaudio 1)' );
	is_deeply(
		lmsFavoritesParams($item),
		{ favorites_url => $SJ_URL, favorites_title => "Sat 19 Sep $ENDASH Saturday Jazz with Laura Igglesden", favorites_type => 'audio' },
		'LMS _favoritesParams: favourites save the rtrfm URL as type audio, not the coderef'
	);

	is( scalar( () = playlistRequests() ), 0, 'building the episode list makes zero /playlists requests' );

	clearTime();
};

subtest 'opening Sat 19 Sep: Play episode, Track list (20)' => sub {
	reset_all();

	my ($row) = @{ jazzEpisodes() };
	my $items = items_of( open_item($row), 'Sat 19 Sep' );

	is( scalar @$items, 2, 'two items (Airnet has no notes for this episode, so no description)' );
	is_deeply( $items->[0], playItem($SJ_URL), 'Play episode: audio, url and play = rtrfm URL, on_select play, duration, image' );

	my $list = $items->[1];
	is( $list->{name}, 'Track list (20)', '"Track list (20)"' );
	is( $list->{type}, 'link', 'a link' );
	is( scalar @{ $list->{items} }, 20, 'with 20 rows' );
	is_deeply( [ grep { join( ',', sort keys %$_ ) ne 'name,type' || $_->{type} ne 'text' } @{ $list->{items} } ], [], 'every row is { name, type => text }' );
	is( $list->{items}->[0]->{name},  "3:00 $MIDDOT Chris Foster $ENDASH Looking Sideways (In Motion)", 'first row' );
	is( $list->{items}->[4]->{name},  "23:00 $MIDDOT Ella Fitzgerald & Louis Armstrong $ENDASH Isn't This a Lovely Day", 'row 5' );
	is( $list->{items}->[19]->{name}, "1:55:00 $MIDDOT Matt Smith $ENDASH Forest (Driftwood)", 'last row' );
	is_deeply( [ sort keys %$list ], [qw(items name type)], 'the track list link has inline items only' );

	my @requests = playlistRequests();
	is( scalar @requests, 1, 'opening the episode makes one /playlists request' );
	is( $requests[0]->{url}, playlistUrl( 'saturdayjazz', '2026-09-19', '0900' ), 'for this episode' );

	items_of( open_item($row), 'Sat 19 Sep again' );
	is( scalar( () = playlistRequests() ), 1, 're-opening uses the cached track list' );

	clearTime();
};

subtest 'opening Sat 12 Sep: the description textarea comes second' => sub {
	reset_all();
	route( playlistUrl( 'saturdayjazz', '2026-09-12', '0900' ), file => 'ondemand/playlist-saturdayjazz-2026-09-19.json' );

	my $row   = jazzEpisodes()->[1];
	my $items = items_of( open_item($row), 'Sat 12 Sep' );

	is( scalar @$items, 3, 'three items' );
	is_deeply( $items->[0], playItem('rtrfm://episode/saturdayjazz/2026-09-12/0900'), 'Play episode first' );
	is_deeply(
		$items->[1],
		{ name => 'Presented by Ben Bartholomew. Featuring tracks from the debut album by local ensemble the Kirsten Sym Undectet.', type => 'textarea', wrap => 1 },
		'then the description: textarea, wrap'
	);
	is( $items->[2]->{name}, 'Track list (20)', 'then the track list' );

	$items = openEpisode( 'empty description', episode( description => '' ) );
	is_deeply( [ map { $_->{type} } @$items ], [qw(audio link)], 'an empty description gives no textarea' );

	clearTime();
};

subtest 'no track list: NO_TRACKLIST, or TRACKLIST_PENDING for synthetic episodes' => sub {
	my $url = playlistUrl( 'saturdayjazz', '2026-09-19', '0900' );

	for my $case (
		[ 'empty list', { file => 'ondemand/playlist-empty.json' } ],
		[ 'HTTP 400',   { code => 400, file => 'ondemand/playlist-400.json' } ],
		[ 'HTTP 404',   { code => 404 } ],
		[ 'HTTP 500',   { code => 500 } ],
		[ 'bad JSON',   { content => '<html>' } ],
		[ 'timeout',    { error => 'Timed out waiting for data' } ],
	) {
		my ( $name, $response ) = @$case;

		resetStubs();
		setTime($NOW);
		route( $url, %$response );
		my $items = openEpisode( $name, episode() );
		is_deeply( $items, [ playItem($SJ_URL), $NO_TRACKLIST ], "$name: Play episode + NO_TRACKLIST (the episode stays playable)" );

		resetStubs();
		route( $url, %$response );
		$items = openEpisode( "$name, synthetic", episode( synthetic => 1 ) );
		is_deeply( $items, [ playItem($SJ_URL), $PENDING ], "$name, synthetic => 1: Play episode + TRACKLIST_PENDING" );
	}

	reset_all();
	my $items = openEpisode( 'synthetic with tracks', episode( synthetic => 1 ) );
	is( $items->[1]->{name}, 'Track list (20)', 'synthetic with a track list: the track list' );

	clearTime();
};

subtest 'start time fallbacks: episode, then metadata cache, then URL HHMM' => sub {
	setTime($NOW);

	# open the episode on a fresh cache, holding episode metadata with start $cachedStart if
	# that argument is given; returns the /playlists request URL (undef if none) and the items
	my $openWith = sub {
		my ( $name, $episode, $cachedStart ) = @_;
		resetStubs();
		route( qr{/playlists$}, content => '[]' );
		Plugins::RTRFM::Util::setEpisodeMeta( { slug => 'saturdayjazz', date => '2026-09-19', start => $cachedStart } ) if @_ >= 3;
		my $items = openEpisode( $name, $episode );
		my @requests = playlistRequests();
		ok( @requests <= 1, "$name: at most one request" );
		return ( @requests ? $requests[0]->{url} : undef, $items );
	};

	my ($url) = $openWith->( 'episode start', episode( hhmm => '1000' ), '2026-09-19 09:30:00' );
	is( $url, playlistUrl( 'saturdayjazz', '2026-09-19', '0900' ), "1. the episode's start wins over the cache and the URL" );

	($url) = $openWith->( 'cache start', episode( start => undef, hhmm => '1000' ), '2026-09-19 09:30:00' );
	is( $url, playlistUrl( 'saturdayjazz', '2026-09-19', '0930' ), '2. no episode start: the metadata cache start' );

	($url) = $openWith->( 'unparseable episode start', episode( start => 'soon', hhmm => '1000' ), '2026-09-19 09:30:00' );
	is( $url, playlistUrl( 'saturdayjazz', '2026-09-19', '0930' ), '   an unparseable episode start also falls back to the cache' );

	($url) = $openWith->( 'URL HHMM', episode( start => undef, hhmm => '1000' ) );
	is( $url, playlistUrl( 'saturdayjazz', '2026-09-19', '1000' ), "3. no episode start and nothing cached: the URL's date + HHMM" );

	($url) = $openWith->( 'cache without a start', episode( start => undef, hhmm => '1000' ), undef );
	is( $url, playlistUrl( 'saturdayjazz', '2026-09-19', '1000' ), '   (also when the cached metadata has no start)' );

	my $items;
	( $url, $items ) = $openWith->( 'no start at all', episode( start => undef, hhmm => undef ) );
	is( $url, undef, 'no start and no HHMM: no request' );
	is_deeply( $items, [ playItem('rtrfm://episode/saturdayjazz/2026-09-19'), $NO_TRACKLIST ], 'and the NO_TRACKLIST item' );

	( $url, $items ) = $openWith->( 'no start at all, synthetic', episode( start => undef, hhmm => undef, synthetic => 1 ) );
	is( $items->[1]->{name}, 'Track list not yet available', 'or TRACKLIST_PENDING when synthetic' );

	clearTime();
};

subtest 'the callback fires exactly once' => sub {
	reset_all();

	my $calls = 0;
	my $c     = collector();
	Plugins::RTRFM::OnDemand::_episodeMenu( undef, sub { $calls++; $c->cb->(@_) }, { params => {} }, $SATURDAY_JAZZ, episode() );
	is( $calls, 1, 'success: once' );

	resetStubs();
	route( qr{/playlists$}, error => 'Timed out waiting for data' );
	$calls = 0;
	Plugins::RTRFM::OnDemand::_episodeMenu( undef, sub { $calls++ }, { params => {} }, $SATURDAY_JAZZ, episode() );
	is( $calls, 1, 'failure: once' );

	reset_all();
	no warnings 'redefine';
	local *Plugins::RTRFM::Tracklist::formatRow = sub { die "formatRow broke\n" };
	my $items = openEpisode( 'dying row formatter', episode() );
	is_deeply( $items, [ { name => "Couldn't load from RTRFM $ENDASH please try again later", type => 'text' } ], 'a builder that dies: one LOAD_FAILED item' );

	clearTime();
};

done_testing();
