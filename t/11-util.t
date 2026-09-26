#!/usr/bin/perl
# Plugins::RTRFM::Util: constants, Perth time helpers (fixed UTC+8, whatever the server time
# zone), decodeEntities, the episode URL contract and the episode metadata cache contract.

use strict;
use warnings;
use utf8;

use RTRFMTest qw(:all);
use Test::More;

use POSIX ();
use Time::Local qw(timegm);

use Plugins::RTRFM::Util qw(:all);

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

subtest 'constants' => sub {
	is( STATION_NAME, 'RTRFM 92.1',                                   'station name' );
	is( STREAM1_URL,  'https://live.rtrfm.com.au/stream1',            'stream1 URL' );
	is( STREAM2_URL,  'https://live.rtrfm.com.au/stream2',            'stream2 URL' );
	is( SITE_BASE,    'https://rtrfm.com.au',                         'rtrfm.com.au base' );
	is( AIRNET_BASE,  'https://airnet.org.au/rest/stations/6RTR',     'Airnet base' );
	is( RZZ_BASE,     'https://restreams.rtrfm.com.au/rzz',           'rzz base' );
	is( ICON,         'plugins/RTRFM/html/images/icon.png',           'icon path' );
	ok( -f 'RTRFM/HTML/EN/' . ICON, 'icon path points at the shipped icon file' );
};

# 2026-09-19 15:59:59 UTC is 23:59:59 on Saturday the 19th in Perth; one second later it is
# Sunday the 20th in Perth.
my $lastSecondSat = timegm( 59, 59, 15, 19, 8, 2026 );
my $firstSecondSun = $lastSecondSat + 1;

for my $tz ( 'UTC', 'America/New_York' ) {
	local $ENV{TZ} = $tz;
	POSIX::tzset();

	subtest "Perth time helpers with server TZ=$tz" => sub {
		is( parsePerthDateTime('2026-09-19 23:59:59'), $lastSecondSat,  'parse Perth 23:59:59 on the 19th' );
		is( parsePerthDateTime('2026-09-20 00:00:00'), $firstSecondSun, 'parse Perth midnight on the 20th' );
		is( parsePerthDateTime('2026-09-19 09:00'),    timegm( 0, 0, 1, 19, 8, 2026 ), 'seconds are optional' );

		is( perthDate($lastSecondSat),  '2026-09-19', 'last second of Saturday is the 19th in Perth' );
		is( perthDate($firstSecondSun), '2026-09-20', 'one second later it is the 20th in Perth' );
		is( perthTime($lastSecondSat),  '23:59',      'Perth clock time before midnight' );
		is( perthTime($firstSecondSun), '00:00',      'Perth clock time at midnight' );
		is( perthWeekday($lastSecondSat),  6, 'Saturday = 6' );
		is( perthWeekday($firstSecondSun), 0, 'Sunday = 0' );
		is( friendlyDate($lastSecondSat),  'Sat 19 Sep', 'friendly date before midnight' );
		is( friendlyDate($firstSecondSun), 'Sun 20 Sep', 'friendly date after midnight' );

		setTime($lastSecondSat);
		is( perthToday(), '2026-09-19', 'perthToday just before Perth midnight' );
		setTime($firstSecondSun);
		is( perthToday(), '2026-09-20', 'perthToday at Perth midnight' );
		clearTime();

		is( parseISO8601('2026-09-26T09:00:00+08:00'), timegm( 0, 0, 1, 26, 8, 2026 ), 'ISO-8601 with +08:00' );
		is( parsePerthDateTime( perthDate($lastSecondSat) . ' ' . perthTime($lastSecondSat) . ':59' ), $lastSecondSat, 'epoch -> Perth -> epoch round trip' );
	};
}

subtest 'ISO-8601 variants' => sub {
	my $nineAmPerth = timegm( 0, 0, 1, 26, 8, 2026 );
	is( parseISO8601('2026-09-26T01:00:00Z'),          $nineAmPerth, 'UTC "Z"' );
	is( parseISO8601('2026-09-25T20:00:00-05:00'),     $nineAmPerth, 'negative offset' );
	is( parseISO8601('2026-09-26T09:00:00+0800'),      $nineAmPerth, 'offset without colon' );
	is( parseISO8601('2026-09-26T09:00:00.000+08:00'), $nineAmPerth, 'fractional seconds' );
	is( parseISO8601('2026-09-26T09:00+08:00'),        $nineAmPerth, 'no seconds' );
	is( parseISO8601('2026-09-26T09:00:00'),           $nineAmPerth, 'no offset = Perth time' );
};

subtest 'invalid date/time input' => sub {
	is( parsePerthDateTime($_), undef, 'parsePerthDateTime(' . ( defined $_ ? "'$_'" : 'undef' ) . ') is undef' )
		for ( undef, '', 'garbage', '2026-02-30 10:00:00', '2026-09-19 24:00:00', '2026-09-19 10:60:00', '19/09/2026 10:00' );
	is( parseISO8601($_), undef, 'parseISO8601(' . ( defined $_ ? "'$_'" : 'undef' ) . ') is undef' )
		for ( undef, 'garbage', '2026-02-30T09:00:00+08:00', '2026-09-26 09:00:00+08:00', '2026-09-26T09:00:00+25:00' );
	is( perthDate(undef),       undef, 'perthDate(undef)' );
	is( perthDate('yesterday'), undef, 'perthDate(non-number)' );
};

subtest 'friendlyDate from a date string' => sub {
	is( friendlyDate('2026-09-19'), 'Sat 19 Sep', 'Saturday 19 September' );
	is( friendlyDate('2026-09-05'), 'Sat 5 Sep',  'no leading zero on the day' );
	is( friendlyDate('2026-02-30'), undef,        'invalid date' );
};

subtest 'decodeEntities' => sub {
	my @cases = (
		[ '&amp;',                     '&',              '&amp;' ],
		[ 'Black &amp; Blue',          'Black & Blue',   'named entity in text' ],
		[ 'Rock&#8217;n&#8217;Roll',   "Rock\x{2019}n\x{2019}Roll", 'decimal entity' ],
		[ 'It&#x27;s',                 "It's",           'hex entity' ],
		[ 'Up&nbsp;Late',              'Up Late',        '&nbsp; becomes a plain space' ],
		[ 'Caf&eacute; &lt;b&gt;',     'Café <b>',       'accented letter, &lt; &gt;' ],
		[ '&quot;Hi&quot; &ndash; x',  "\"Hi\" \x{2013} x", 'quotes and en dash' ],
		[ '&amp;amp;',                 '&amp;',          'decodes only once' ],
		[ 'no entities',               'no entities',    'plain text unchanged' ],
	);

	# LMS bundles HTML::Entities; plain Perl may not have it. Test the built-in decoder always and
	# HTML::Entities when it is installed (CI installs it).
	my @paths = ( [ 'built-in decoder', 0 ] );
	push @paths, [ 'HTML::Entities', 1 ] if $Plugins::RTRFM::Util::HAS_HTML_ENTITIES;
	diag('HTML::Entities not installed: only the built-in decoder is tested') unless $Plugins::RTRFM::Util::HAS_HTML_ENTITIES;

	for my $path (@paths) {
		my ( $label, $useHTMLEntities ) = @$path;
		local $Plugins::RTRFM::Util::HAS_HTML_ENTITIES = $useHTMLEntities;
		for my $case (@cases) {
			my ( $in, $out, $name ) = @$case;
			is( decodeEntities($in), $out, "$label: $name" );
		}
	}

	is( decodeEntities('&bogus; &#0;'), '&bogus; &#0;', 'unknown and invalid entities are left alone' );
	is( decodeEntities(undef), undef, 'undef stays undef' );
	is( decodeEntities('Up&nbsp;Late'), 'Up Late', 'decodeEntities turns &nbsp; into a space' );
};

subtest 'episode URL contract' => sub {
	is( episodeUrl( 'saturdayjazz', '2026-09-19' ),         'rtrfm://episode/saturdayjazz/2026-09-19',      'URL without time' );
	is( episodeUrl( 'saturdayjazz', '2026-09-19', '0900' ), 'rtrfm://episode/saturdayjazz/2026-09-19/0900', 'URL with time' );

	is_deeply( parseEpisodeUrl('rtrfm://episode/saturdayjazz/2026-09-19'),
		{ slug => 'saturdayjazz', date => '2026-09-19', hhmm => undef }, 'parse URL without time' );
	is_deeply( parseEpisodeUrl('rtrfm://episode/up-late_2/2026-09-25/0100'),
		{ slug => 'up-late_2', date => '2026-09-25', hhmm => '0100' }, 'parse URL with time; slug may contain - and _' );

	for my $args ( [ 'drivetime', '2026-09-25', '1700' ], [ 'otl', '2024-02-29' ], [ 'x', '2000-02-29', '2359' ] ) {
		my $url = episodeUrl(@$args);
		is_deeply( parseEpisodeUrl($url), { slug => $args->[0], date => $args->[1], hhmm => $args->[2] }, "round trip $url" );
	}

	my @invalidUrls = (
		[ undef,                                             'undef' ],
		[ '',                                                'empty' ],
		[ 'https://episode/saturdayjazz/2026-09-19',         'wrong scheme' ],
		[ 'rtrfm://live/saturdayjazz/2026-09-19',            'wrong kind' ],
		[ 'rtrfm://episode/saturdayjazz',                    'missing date' ],
		[ 'rtrfm://episode/saturdayjazz/2026-02-30',         'impossible date' ],
		[ 'rtrfm://episode/saturdayjazz/2026-02-29',         'not a leap year' ],
		[ 'rtrfm://episode/saturdayjazz/2100-02-29',         'century is not a leap year' ],
		[ 'rtrfm://episode/SaturdayJazz/2026-09-19',         'uppercase slug' ],
		[ 'rtrfm://episode/drivetime/monday/2026-09-19',     'slug with /' ],
		[ 'rtrfm://episode/../2026-09-19',                   'slug ..' ],
		[ 'rtrfm://episode/saturdayjazz/2026-09-19/',        'trailing slash' ],
		[ 'rtrfm://episode/saturdayjazz/2026-09-19/0900/x',  'extra path segment' ],
		[ 'rtrfm://episode/saturdayjazz/2026-09-19/2460',    'hhmm 2460' ],
		[ 'rtrfm://episode/saturdayjazz/2026-09-19/1260',    'minute 60' ],
		[ 'rtrfm://episode/saturdayjazz/2026-09-19/900',     'three-digit hhmm' ],
		[ 'rtrfm://episode/saturdayjazz/26-09-19',           'two-digit year' ],
	);
	is( parseEpisodeUrl( $_->[0] ), undef, "invalid URL: $_->[1]" ) for @invalidUrls;

	is( episodeUrl( 'Saturday Jazz', '2026-09-19' ),         undef, 'episodeUrl rejects an invalid slug' );
	is( episodeUrl( 'saturdayjazz',  '2026-13-01' ),         undef, 'episodeUrl rejects an invalid date' );
	is( episodeUrl( 'saturdayjazz',  '2026-09-19', '2460' ), undef, 'episodeUrl rejects an invalid time' );
	is( episodeUrl( 'saturdayjazz',  undef ),                undef, 'episodeUrl needs a date' );
};

subtest 'episode metadata cache contract' => sub {
	resetStubs();
	setTime( timegm( 0, 0, 4, 20, 8, 2026 ) );

	my %meta = (
		slug        => 'saturdayjazz',
		date        => '2026-09-19',
		start       => '2026-09-19 09:00:00',
		duration    => 7200,
		title       => 'Saturday Jazz with Laura Igglesden',
		show        => 'Saturday Jazz',
		image       => 'https://rtrfm.com.au/wp-content/uploads/2012/12/SaturdayJazz.jpg',
		description => 'Hosted by Laura Igglesden',
	);

	is( getEpisodeMeta( 'saturdayjazz', '2026-09-19' ), undef, 'miss before anything is stored' );
	ok( setEpisodeMeta( { %meta, extra => 'dropped' } ), 'setEpisodeMeta stores valid metadata' );
	is_deeply( getEpisodeMeta( 'saturdayjazz', '2026-09-19' ), \%meta, 'get returns the documented shape; unknown keys are dropped' );

	is( getEpisodeMeta( 'saturdayjazz', '2026-09-12' ), undef, 'miss for another date' );
	is( getEpisodeMeta( 'breakfast',    '2026-09-19' ), undef, 'miss for another show' );
	is( getEpisodeMeta( '../x',         '2026-09-19' ), undef, 'invalid slug is a miss' );

	ok( !setEpisodeMeta( { %meta, slug => 'Bad Slug' } ), 'invalid slug is not stored' );
	ok( !setEpisodeMeta( { %meta, date => '2026-02-30' } ), 'invalid date is not stored' );
	ok( !setEpisodeMeta(undef), 'undef is not stored' );

	my $stored = getEpisodeMeta( 'saturdayjazz', '2026-09-19' );
	$stored->{title} = 'changed by the caller';
	is( getEpisodeMeta( 'saturdayjazz', '2026-09-19' )->{title}, $meta{title}, 'callers get a copy' );

	ok( defined Slim::Utils::Cache->new('rtrfm')->get('episode-meta:saturdayjazz:2026-09-19'), 'stored in the "rtrfm" cache namespace' );

	advanceTime( 6 * 86400 );
	ok( getEpisodeMeta( 'saturdayjazz', '2026-09-19' ), 'still cached after 6 days' );
	advanceTime( 86400 + 1 );
	is( getEpisodeMeta( 'saturdayjazz', '2026-09-19' ), undef, 'expired after 7 days' );

	clearTime();
};

done_testing();
