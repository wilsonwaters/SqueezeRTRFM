package Plugins::RTRFM::Util;

# Shared constants and pure helper functions for the RTRFM plugin:
#   - station constants (names, stream URLs, API bases, icon);
#   - Perth time helpers: RTRFM data is in Perth local time, which is always UTC+8 (no daylight
#     saving), so these use a fixed offset and never the server's time zone;
#   - decodeEntities;
#   - the episode URL contract: rtrfm://episode/<slug>/<YYYY-MM-DD>[/<HHMM>];
#   - the episode metadata cache contract: setEpisodeMeta / getEpisodeMeta.
#
# Owned by the foundation stream: other streams may only append to it (and must say so in their PR).

use strict;
use warnings;

use Time::Local qw(timegm);

use Slim::Utils::Cache;

use Exporter qw(import);
our @EXPORT_OK = qw(
	STATION_NAME STREAM1_URL STREAM2_URL SITE_BASE AIRNET_BASE RZZ_BASE ICON
	PERTH_OFFSET CACHE_NAMESPACE EPISODE_META_TTL
	parsePerthDateTime parseISO8601 perthDate perthTime perthWeekday perthToday friendlyDate
	decodeEntities
	episodeUrl parseEpisodeUrl
	setEpisodeMeta getEpisodeMeta
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use constant STATION_NAME => 'RTRFM 92.1';
use constant STREAM1_URL  => 'https://live.rtrfm.com.au/stream1';    # FM simulcast
use constant STREAM2_URL  => 'https://live.rtrfm.com.au/stream2';    # Infinite Mix
use constant SITE_BASE    => 'https://rtrfm.com.au';
use constant AIRNET_BASE  => 'https://airnet.org.au/rest/stations/6RTR';
use constant RZZ_BASE     => 'https://restreams.rtrfm.com.au/rzz';
use constant ICON         => 'plugins/RTRFM/html/images/icon.png';

use constant PERTH_OFFSET     => 8 * 3600;       # Australia/Perth = UTC+8, no DST
use constant CACHE_NAMESPACE  => 'rtrfm';        # Slim::Utils::Cache namespace (create it without a version)
use constant EPISODE_META_TTL => 7 * 86400;      # seconds

my @DAY_NAMES   = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MONTH_NAMES = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# ---------------------------------------------------------------------------
# Perth time
# ---------------------------------------------------------------------------

# 'YYYY-MM-DD HH:MM:SS' (or 'HH:MM', or with a 'T' separator) in Perth local time -> epoch.
# Returns undef for anything that isn't a valid date and time (years 1970..2100 only).
sub parsePerthDateTime {
	my $string = shift;
	return undef unless defined $string;

	my ( $y, $mo, $d, $h, $mi, $s ) = $string =~ /\A\s*([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?\s*\z/
		or return undef;

	my $epoch = _timegm( $y, $mo, $d, $h, $mi, $s || 0 );
	return defined $epoch ? $epoch - PERTH_OFFSET : undef;
}

# ISO-8601 date-time with a UTC offset, e.g. '2026-09-26T09:00:00+08:00' or '...Z' -> epoch.
# Without an offset the time is taken as Perth local time. Returns undef if invalid (years
# 1970..2100 only).
sub parseISO8601 {
	my $string = shift;
	return undef unless defined $string;

	my ( $y, $mo, $d, $h, $mi, $s, $tz ) = $string =~ /\A\s*([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?\s*\z/i
		or return undef;

	my $epoch = _timegm( $y, $mo, $d, $h, $mi, $s || 0 );
	return undef unless defined $epoch;

	my $offset = PERTH_OFFSET;
	if ( defined $tz ) {
		if ( uc $tz eq 'Z' ) {
			$offset = 0;
		}
		else {
			my ( $sign, $oh, $om ) = $tz =~ /^([+-])(\d\d):?(\d\d)$/;
			return undef if $oh > 23 || $om > 59;
			$offset = ( $oh * 3600 + $om * 60 ) * ( $sign eq '-' ? -1 : 1 );
		}
	}

	return $epoch - $offset;
}

# epoch -> Perth calendar date 'YYYY-MM-DD'
sub perthDate {
	my @t = _perthTime(shift) or return undef;
	return sprintf( '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] );
}

# epoch -> Perth clock time 'HH:MM' (24 hour)
sub perthTime {
	my @t = _perthTime(shift) or return undef;
	return sprintf( '%02d:%02d', $t[2], $t[1] );
}

# epoch -> Perth day of the week, 0 (Sunday) .. 6 (Saturday)
sub perthWeekday {
	my @t = _perthTime(shift) or return undef;
	return $t[6];
}

# Today's Perth date, 'YYYY-MM-DD'.
sub perthToday { perthDate( time() ) }

# Epoch or 'YYYY-MM-DD' -> 'Sat 19 Sep' (Perth date).
sub friendlyDate {
	my $value = shift;
	return undef unless defined $value;

	my $epoch = $value =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/ ? parsePerthDateTime("$value 12:00:00") : $value;

	my @t = _perthTime($epoch) or return undef;
	return sprintf( '%s %d %s', $DAY_NAMES[ $t[6] ], $t[3], $MONTH_NAMES[ $t[4] ] );
}

sub _perthTime {
	my $epoch = shift;
	return () unless defined $epoch && $epoch =~ /^-?\d+(?:\.\d+)?$/;
	return gmtime( int($epoch) + PERTH_OFFSET );
}

sub _timegm {
	my ( $y, $mo, $d, $h, $mi, $s ) = @_;
	return undef unless _isValidDate( $y, $mo, $d ) && $h <= 23 && $mi <= 59 && $s <= 59;
	return eval { timegm( $s, $mi, $h, $d, $mo - 1, $y ) };
}

# Dates are only valid in the years 1970..2100. This also stops Time::Local reading a year
# such as '0026' as 2026.
sub _isValidDate {
	my ( $y, $m, $d ) = @_;
	return 0 if $y < 1970 || $y > 2100 || $m < 1 || $m > 12 || $d < 1;

	my $leap = ( $y % 4 == 0 && $y % 100 != 0 ) || $y % 400 == 0;
	my @days = ( 31, $leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );

	return $d <= $days[ $m - 1 ];
}

# ---------------------------------------------------------------------------
# HTML entities
# ---------------------------------------------------------------------------

# LMS bundles HTML::Entities; plain Perl may not have it, so there is a built-in fallback that
# covers numeric entities and the common named ones.
our $HAS_HTML_ENTITIES = eval { require HTML::Entities; 1 } ? 1 : 0;

my %ENTITIES = (
	amp => '&', lt => '<', gt => '>', quot => '"', apos => "'", nbsp => "\x{A0}",
	ndash => "\x{2013}", mdash => "\x{2014}", lsquo => "\x{2018}", rsquo => "\x{2019}", sbquo => "\x{201A}",
	ldquo => "\x{201C}", rdquo => "\x{201D}", bdquo => "\x{201E}", bull => "\x{2022}", hellip => "\x{2026}",
	prime => "\x{2032}", euro => "\x{20AC}", trade => "\x{2122}", laquo => "\x{AB}", raquo => "\x{BB}",
	copy => "\x{A9}", reg => "\x{AE}", deg => "\x{B0}", middot => "\x{B7}", times => "\x{D7}", divide => "\x{F7}",
	iexcl => "\x{A1}", cent => "\x{A2}", pound => "\x{A3}", yen => "\x{A5}", sect => "\x{A7}", para => "\x{B6}",
	plusmn => "\x{B1}", frac14 => "\x{BC}", frac12 => "\x{BD}", frac34 => "\x{BE}", iquest => "\x{BF}",
	szlig => "\x{DF}",
);

# Latin-1 letters: &Agrave; (U+00C0) .. &yuml; (U+00FF), skipping times/divide/szlig.
{
	my @names = qw(
		Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml
		ETH Ntilde Ograve Oacute Ocirc Otilde Ouml - Oslash Ugrave Uacute Ucirc Uuml Yacute THORN -
		agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml
		eth ntilde ograve oacute ocirc otilde ouml - oslash ugrave uacute ucirc uuml yacute thorn yuml
	);
	for my $i ( 0 .. $#names ) {
		$ENTITIES{ $names[$i] } = chr( 0xC0 + $i ) unless $names[$i] eq '-';
	}
}

# Decode HTML entities (&amp; &#8217; &#x27; &nbsp; ...) into characters. Non-breaking spaces
# become plain spaces. Unknown entities are left alone. undef stays undef.
sub decodeEntities {
	my $string = shift;
	return undef unless defined $string;

	if ($HAS_HTML_ENTITIES) {
		$string = HTML::Entities::decode_entities($string);
	}
	else {
		$string = _decodeEntitiesPP($string);
	}

	$string =~ s/\x{A0}/ /g;
	return $string;
}

sub _decodeEntitiesPP {
	my $string = shift;

	$string =~ s{&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|([A-Za-z][A-Za-z0-9]*));}{
		defined $1 ? _chr($1, "&#$1;")
		: defined $2 ? _chr(hex $2, "&#x$2;")
		: exists $ENTITIES{$3} ? $ENTITIES{$3} : "&$3;"
	}ge;

	return $string;
}

sub _chr {
	my ( $code, $original ) = @_;
	return ( $code > 0 && $code <= 0x10FFFF ) ? chr($code) : $original;
}

# ---------------------------------------------------------------------------
# Episode URL contract
# ---------------------------------------------------------------------------

# episodeUrl($slug, $date[, $hhmm]) -> 'rtrfm://episode/<slug>/<YYYY-MM-DD>[/<HHMM>]'
#   $slug: Airnet/restream slug, [a-z0-9_-]+ (e.g. 'drivetime', never 'drivetime/monday')
#   $date: Perth calendar date of the episode start, 'YYYY-MM-DD' (years 1970..2100)
#   $hhmm: optional Perth start time, e.g. '0900'
# Only ASCII characters are accepted and nothing may follow a part (not even a newline).
# Returns undef if any part is invalid.
sub episodeUrl {
	my ( $slug, $date, $hhmm ) = @_;

	return undef unless _isValidSlug($slug) && _isValidDateString($date);
	return undef if defined $hhmm && !_isValidHHMM($hhmm);

	return "rtrfm://episode/$slug/$date" . ( defined $hhmm ? "/$hhmm" : '' );
}

# parseEpisodeUrl($url) -> { slug, date, hhmm } (hhmm undef if absent), or undef if the URL
# isn't a valid episode URL.
sub parseEpisodeUrl {
	my $url = shift;
	return undef unless defined $url;

	my ( $slug, $date, $hhmm ) = $url =~ m{\Artrfm://episode/([a-z0-9_-]+)/([0-9]{4}-[0-9]{2}-[0-9]{2})(?:/([0-9]{4}))?\z}
		or return undef;

	return undef unless _isValidDateString($date);
	return undef if defined $hhmm && !_isValidHHMM($hhmm);

	return { slug => $slug, date => $date, hhmm => $hhmm };
}

sub _isValidSlug { defined $_[0] && $_[0] =~ /\A[a-z0-9_-]+\z/ }

sub _isValidDateString {
	my $date = shift;
	return 0 unless defined $date;
	my ( $y, $m, $d ) = $date =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/ or return 0;
	return _isValidDate( $y, $m, $d );
}

sub _isValidHHMM {
	my $hhmm = shift;
	return 0 unless defined $hhmm;
	my ( $h, $m ) = $hhmm =~ /\A([0-9]{2})([0-9]{2})\z/ or return 0;
	return $h <= 23 && $m <= 59;
}

# ---------------------------------------------------------------------------
# Episode metadata cache contract
# ---------------------------------------------------------------------------

my @META_FIELDS = qw(slug date start duration title show image description);

# setEpisodeMeta(\%meta): cache one episode's metadata for EPISODE_META_TTL, keyed by slug + date.
# Shape: { slug, date ('YYYY-MM-DD', Perth), start ('YYYY-MM-DD HH:MM:SS', Perth),
#          duration (seconds), title, show, image, description }. Other keys are dropped.
# Returns 1 when stored, 0 if slug or date is invalid.
sub setEpisodeMeta {
	my $meta = shift;
	return 0 unless ref $meta eq 'HASH' && _isValidSlug( $meta->{slug} ) && _isValidDateString( $meta->{date} );

	my %entry = map { $_ => $meta->{$_} } @META_FIELDS;
	_cache()->set( _metaKey( $meta->{slug}, $meta->{date} ), \%entry, EPISODE_META_TTL );

	return 1;
}

# getEpisodeMeta($slug, $date) -> metadata hashref as stored by setEpisodeMeta, or undef.
sub getEpisodeMeta {
	my ( $slug, $date ) = @_;
	return undef unless _isValidSlug($slug) && _isValidDateString($date);

	my $meta = _cache()->get( _metaKey( $slug, $date ) );
	return ref $meta eq 'HASH' ? $meta : undef;
}

sub _metaKey { "episode-meta:$_[0]:$_[1]" }

sub _cache { Slim::Utils::Cache->new(CACHE_NAMESPACE) }

1;
