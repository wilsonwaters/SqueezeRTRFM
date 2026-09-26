package Plugins::RTRFM::Airnet;

# Data layer for RTRFM's program and episode lists from Airnet
# (https://airnet.org.au/rest/stations/6RTR). No menu code: Plugins::RTRFM::OnDemand builds the
# menus from what these functions return. All requests go through Plugins::RTRFM::HTTP.
#
# Contract (the ondemand stream relies on it; change only with care):
#
#   programs($cb)
#       GET <AIRNET_BASE>/programs. Calls back exactly once:
#         $cb->(\@programs)          @programs = ( { slug, name }, ... )
#         $cb->(undef, $error)       $error = readable message
#       Keeps an entry only if its slug matches [a-z0-9_-]+, it is not archived and it is not a
#       junk/placeholder entry (slug 'training'; empty or placeholder name; placeholder
#       broadcasters). Names are entity-decoded, trimmed and whitespace-collapsed. The first
#       entry per slug wins; the list is sorted case-insensitively by name. Two slugs may share
#       a name. Cached for 6 hours (rtrfm cache namespace, key 'airnet:programs').
#
#   episodes($slug, $cb)
#       GET <AIRNET_BASE>/programs/<slug>/episodes. Calls back exactly once:
#         $cb->(\@episodes)          newest first, ALL episodes Airnet lists (not window-filtered)
#         $cb->(undef, $error)       HTTP error (Airnet answers 500 for an unknown slug), bad
#                                    JSON, timeout, not a list, or an invalid slug (no request)
#       Each episode:
#         { slug        => 'saturdayjazz',
#           date        => '2026-09-19',             # Perth calendar date of the start
#           hhmm        => '0900',                   # Perth start time
#           start       => '2026-09-19 09:00:00',    # Perth time
#           end         => '2026-09-19 11:00:00',    # Perth time, or undef
#           duration    => 7200,                     # seconds: Airnet duration, else end - start, else undef
#           title       => 'Saturday Jazz with ...', # trimmed Airnet title, undef if null/blank
#           description => 'Plain text ...' }        # htmlToText of the Airnet HTML, or undef
#       Entries without a parseable start are skipped. One episode per Perth date: the earliest
#       start wins, the others are logged at info level. Cached for 30 minutes (key
#       'airnet:episodes:<slug>'). An empty list ([]) is a successful result.
#
#   filterWindow(\@episodes[, $now])
#       Pure. Returns a new array ref with the episodes whose date is in
#       [Perth today - 28 days, Perth today), in the input order. $now defaults to time().
#       Airnet never lists today's episodes and RTRFM keeps audio for about 29 days, so the
#       whole window is playable. Apply it when building a menu, never before caching.
#
#   htmlToText($html)
#       HTML fragment -> plain text: tags stripped, <p>/<div> become paragraphs (blank line),
#       <br> a line break, entities decoded, spaces collapsed. undef or empty result -> undef.
#
# Failures are never cached. The cache keys never clash with Util's episode metadata keys.

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::RTRFM::HTTP;
use Plugins::RTRFM::Util;

use constant PROGRAMS_TTL => 6 * 3600;    # seconds
use constant EPISODES_TTL => 30 * 60;     # seconds
use constant WINDOW_DAYS  => 28;

my $log = logger('plugin.rtrfm');

my $JUNK_NAME        = qr/^(?:add show name here|your program|test page)$/i;
my $JUNK_BROADCASTER = qr/^(?:add presenter name here|your broadcaster)$/i;

# ---------------------------------------------------------------------------
# Programs
# ---------------------------------------------------------------------------

sub programs {
	my $cb = shift;

	my $cache  = _cache();
	my $cached = $cache->get('airnet:programs');
	return $cb->($cached) if ref $cached eq 'ARRAY';

	_fetchList(
		Plugins::RTRFM::Util::AIRNET_BASE . '/programs',
		\&_normalisePrograms,
		sub {
			my ( $programs, $error ) = @_;
			$cache->set( 'airnet:programs', $programs, PROGRAMS_TTL ) if $programs;
			$cb->( $programs, $error );
		},
	);
}

sub _normalisePrograms {
	my $entries = shift;

	my ( @programs, %seen );

	for my $entry (@$entries) {
		next unless ref $entry eq 'HASH';

		my $slug = $entry->{slug};
		next unless _isValidSlug($slug);
		next if $entry->{archived};
		next if $slug eq 'training';

		my $name = _cleanText( $entry->{name} );
		next unless defined $name && length $name;
		next if $name =~ $JUNK_NAME;

		my $broadcasters = _cleanText( $entry->{broadcasters} );
		next if defined $broadcasters && $broadcasters =~ $JUNK_BROADCASTER;

		next if $seen{$slug}++;

		push @programs, { slug => $slug, name => $name };
	}

	return [ sort { lc $a->{name} cmp lc $b->{name} || $a->{slug} cmp $b->{slug} } @programs ];
}

# ---------------------------------------------------------------------------
# Episodes
# ---------------------------------------------------------------------------

sub episodes {
	my ( $slug, $cb ) = @_;

	if ( !_isValidSlug($slug) ) {
		my $error = 'Invalid program slug: ' . ( defined $slug ? "'$slug'" : 'undef' );
		$log->warn($error);
		return $cb->( undef, $error );
	}

	my $key    = "airnet:episodes:$slug";
	my $cache  = _cache();
	my $cached = $cache->get($key);
	return $cb->($cached) if ref $cached eq 'ARRAY';

	_fetchList(
		Plugins::RTRFM::Util::AIRNET_BASE . "/programs/$slug/episodes",
		sub { _normaliseEpisodes( $slug, @_ ) },
		sub {
			my ( $episodes, $error ) = @_;
			$cache->set( $key, $episodes, EPISODES_TTL ) if $episodes;
			$cb->( $episodes, $error );
		},
	);
}

sub _normaliseEpisodes {
	my ( $slug, $entries ) = @_;

	my @episodes;

	for my $entry (@$entries) {
		next unless ref $entry eq 'HASH';

		my $start = Plugins::RTRFM::Util::parsePerthDateTime( $entry->{start} );
		if ( !defined $start ) {
			main::INFOLOG && $log->is_info && $log->info( "Skipping $slug episode without a valid start: " . ( defined $entry->{start} ? "'$entry->{start}'" : 'undef' ) );
			next;
		}

		my $end = Plugins::RTRFM::Util::parsePerthDateTime( $entry->{end} );

		my $duration = $entry->{duration};
		if ( defined $duration && !ref $duration && $duration =~ /^\d+(?:\.\d+)?$/ && $duration > 0 ) {
			$duration = int $duration;
		}
		elsif ( defined $end && $end > $start ) {
			$duration = $end - $start;
		}
		else {
			$duration = undef;
		}

		( my $hhmm = Plugins::RTRFM::Util::perthTime($start) ) =~ s/://;

		my $title = _cleanText( $entry->{title} );

		push @episodes, {
			slug        => $slug,
			date        => Plugins::RTRFM::Util::perthDate($start),
			hhmm        => $hhmm,
			start       => _perthDateTime($start),
			end         => defined $end ? _perthDateTime($end) : undef,
			duration    => $duration,
			title       => defined $title && length $title ? $title : undef,
			description => htmlToText( $entry->{description} ),
		};
	}

	# one episode per Perth date: the earliest start (OQ3)
	my ( @kept, %byDate );
	for my $episode ( sort { $a->{start} cmp $b->{start} } @episodes ) {
		if ( my $first = $byDate{ $episode->{date} } ) {
			main::INFOLOG && $log->is_info && $log->info("Ignoring second $slug episode on $episode->{date}: $episode->{start} (keeping $first->{start})");
			next;
		}
		$byDate{ $episode->{date} } = $episode;
		push @kept, $episode;
	}

	return [ reverse @kept ];
}

# ---------------------------------------------------------------------------
# 28-day window
# ---------------------------------------------------------------------------

sub filterWindow {
	my ( $episodes, $now ) = @_;
	$now = time() unless defined $now;

	my $today = Plugins::RTRFM::Util::perthDate($now);

	# Perth has no daylight saving, so every day is 86400 s; noon keeps clear of the day edges
	my $first = Plugins::RTRFM::Util::perthDate( Plugins::RTRFM::Util::parsePerthDateTime("$today 12:00:00") - WINDOW_DAYS * 86400 );

	return [ grep { defined $_->{date} && $_->{date} ge $first && $_->{date} lt $today } @{ $episodes || [] } ];
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub htmlToText {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text =~ s/\r\n?/\n/g;

	if ( $text =~ m{<[a-zA-Z/!]} ) {
		$text =~ s/<!--.*?-->//gs;
		$text =~ s/\s+/ /g;    # in HTML, source line breaks are just spaces
		$text =~ s{<br\s*/?>}{\n}gi;
		$text =~ s{</?(?:p|div)\b[^>]*>}{\n\n}gi;
		$text =~ s/<[^>]*>//g;
	}

	$text = Plugins::RTRFM::Util::decodeEntities($text);

	$text =~ s/[^\S\n]+/ /g;     # collapse spaces (not line breaks)
	$text =~ s/ ?\n ?/\n/g;      # trim each line
	$text =~ s/\n{3,}/\n\n/g;    # at most one blank line
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;

	return length $text ? $text : undef;
}

# GET a JSON list, normalise it and call $cb->(\@list) or $cb->(undef, $error), exactly once.
sub _fetchList {
	my ( $url, $normalise, $cb ) = @_;

	Plugins::RTRFM::HTTP::getJSON(
		$url,
		sub {
			my $data = shift;

			if ( ref $data ne 'ARRAY' ) {
				my $error = "Unexpected response from Airnet (not a list) ($url)";
				$log->warn($error);
				return $cb->( undef, $error );
			}

			my $list = eval { $normalise->($data) };
			if ( !$list ) {
				my $error = "Couldn't read the Airnet response ($url): " . ( $@ || 'unknown error' );
				$log->error($error);
				return $cb->( undef, $error );
			}

			$cb->($list);
		},
		sub { $cb->( undef, $_[0] ) },
	);
}

# Entity-decode, trim and collapse whitespace; undef stays undef.
sub _cleanText {
	my $text = shift;
	return undef unless defined $text && !ref $text;

	$text = Plugins::RTRFM::Util::decodeEntities($text);
	$text =~ s/\s+/ /g;
	$text =~ s/^ //;
	$text =~ s/ $//;

	return $text;
}

sub _isValidSlug { defined $_[0] && !ref $_[0] && $_[0] =~ /\A[a-z0-9_-]+\z/ }

# epoch -> 'YYYY-MM-DD HH:MM:SS' in Perth time
sub _perthDateTime {
	my @t = gmtime( $_[0] + Plugins::RTRFM::Util::PERTH_OFFSET );
	return sprintf( '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
}

sub _cache { Slim::Utils::Cache->new( Plugins::RTRFM::Util::CACHE_NAMESPACE ) }

1;
