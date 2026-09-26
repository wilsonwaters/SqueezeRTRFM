package Plugins::RTRFM::EpisodeWindow;

# The full 28-day episode window. Airnet lists only a show's latest 11 episodes (about two
# weeks of a weekday show) and never today's, while RTRFM keeps the audio for about 29 days
# and publishes it about 6 minutes after a show ends. This module fills the gap from the show's
# weekly slots and checks with rzz which episodes still have audio. No menu code:
# Plugins::RTRFM::OnDemand::_episodesFeed builds the items.
#
#   inferSlots(\@airnetEpisodes) -> \@slots
#       Pure. Groups the episodes (as returned by Plugins::RTRFM::Airnet::episodes, all of them,
#       also those older than the window) by the Perth weekday and HH:MM of their start. A group
#       with at least 2 observations is a slot { weekday, hhmm, duration }: weekday 0 (Sunday) ..
#       6 (Saturday) of the Perth start date (Up Late at 01:00 on a Monday is a Monday slot),
#       hhmm e.g. '1700', duration the median of the observed durations in seconds (a group
#       without any known duration is not a slot). Sorted by weekday, then hhmm.
#
#   candidates(\@airnetEpisodes, \@slots[, $now]) -> \@episodes
#       Pure. The episodes to offer for dates in [Perth today - 28 days, Perth today]:
#         - Airnet's episodes with a date in that range;
#         - one synthesised episode per slot date in that range, once now >= end + 10 minutes
#           (the MP3 appears about 6 minutes after the end; also keeps a show that is still on
#           air out, e.g. All City, Fri 23:00-01:00, at 00:30 on Saturday):
#             { slug, date, hhmm, start => 'YYYY-MM-DD HH:MM:00', end => 'YYYY-MM-DD HH:MM:SS',
#               duration, title => undef, description => undef, synthetic => 1 }
#       One episode per date: Airnet's wins, else the earliest slot of the day. Newest first, at
#       most MAX_CANDIDATES. Airnet's hashes are passed on untouched. $now defaults to time().
#
#   checkAvailability(\@episodes, $cb)
#       Checks the first MAX_CANDIDATES episodes with Plugins::RTRFM::Restream::resolve and
#       calls back exactly once with
#         $cb->([ { episode => $episode, status => 'available' | 'unavailable' | 'unknown' }, ... ])
#       in the input order ('unknown': the check failed or did not finish in time).
#         - The outcome is cached per (slug, date) in the rtrfm cache namespace, key
#           'avail:<slug>:<date>': 1 for 24 hours (available), 0 for 1 hour (unavailable).
#           Failures are not cached, and neither is the signed URL.
#         - At most MAX_IN_FLIGHT resolves are in flight, for all callers together, and at most
#           one per (slug, date): a check that is already queued or running is shared.
#         - Time budget: CHECK_BUDGET seconds after the call, the episodes that are still
#           unchecked are reported as 'unknown' (queued checks nobody waits for are dropped;
#           running ones still cache their outcome). Restream::resolve has no timeout option and
#           HTTP.pm waits up to 15 s, so this is what keeps a cold menu load (Airnet plus about
#           20 checks, usually 1-3 s) under 10 s even when rzz hangs, far inside XMLBrowser's
#           35 s.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::RTRFM::Airnet;
use Plugins::RTRFM::Restream;
use Plugins::RTRFM::Util;

use constant WINDOW_DAYS     => 28;
use constant MIN_SLOT_OBS    => 2;
use constant PUBLISH_DELAY   => 10 * 60;    # seconds after the end before a synthesised episode is offered
use constant MAX_CANDIDATES  => 35;
use constant MAX_IN_FLIGHT   => 4;
use constant AVAILABLE_TTL   => 24 * 3600;  # seconds
use constant UNAVAILABLE_TTL => 3600;       # seconds
use constant CHECK_BUDGET    => 6;          # seconds

my $log = logger('plugin.rtrfm');

# ---------------------------------------------------------------------------
# Slots
# ---------------------------------------------------------------------------

sub inferSlots {
	my $episodes = shift;

	my %groups;

	for my $episode ( @{ $episodes || [] } ) {
		next unless ref $episode eq 'HASH';

		my $start = Plugins::RTRFM::Util::parsePerthDateTime( $episode->{start} );
		next unless defined $start;

		( my $hhmm = Plugins::RTRFM::Util::perthTime($start) ) =~ s/://;
		my $weekday = Plugins::RTRFM::Util::perthWeekday($start);

		my $group = $groups{"$weekday $hhmm"} ||= { weekday => $weekday, hhmm => $hhmm, count => 0, durations => [] };
		$group->{count}++;
		push @{ $group->{durations} }, $episode->{duration} if _isDuration( $episode->{duration} );
	}

	my @slots;

	for my $group ( values %groups ) {
		next if $group->{count} < MIN_SLOT_OBS || !@{ $group->{durations} };
		push @slots, { weekday => $group->{weekday}, hhmm => $group->{hhmm}, duration => _median( $group->{durations} ) };
	}

	return [ sort { $a->{weekday} <=> $b->{weekday} || $a->{hhmm} cmp $b->{hhmm} } @slots ];
}

sub _isDuration { defined $_[0] && !ref $_[0] && $_[0] =~ /\A\d+\z/ && $_[0] > 0 }

sub _median {
	my @sorted = sort { $a <=> $b } @{ $_[0] };
	my $mid    = int( @sorted / 2 );
	return @sorted % 2 ? $sorted[$mid] : int( ( $sorted[ $mid - 1 ] + $sorted[$mid] ) / 2 );
}

# ---------------------------------------------------------------------------
# Candidates
# ---------------------------------------------------------------------------

sub candidates {
	my ( $episodes, $slots, $now ) = @_;
	$episodes ||= [];
	$now = time() unless defined $now;

	my $today = Plugins::RTRFM::Util::perthDate($now);

	# Perth has no daylight saving, so every day is 86400 s; noon keeps clear of the day edges
	my $todayNoon = Plugins::RTRFM::Util::parsePerthDateTime("$today 12:00:00");

	# Airnet's episodes: filterWindow gives [today - 28, today); Airnet rarely lists today's
	my %byDate;
	for my $episode ( @{ Plugins::RTRFM::Airnet::filterWindow( $episodes, $now ) }, grep { ref $_ eq 'HASH' && defined $_->{date} && $_->{date} eq $today } @$episodes ) {
		$byDate{ $episode->{date} } ||= $episode;
	}

	# one synthesised episode per slot date, earliest slot of the day first
	my $slug = _slug($episodes);
	my @slots = sort { $a->{hhmm} cmp $b->{hhmm} } grep { ref $_ eq 'HASH' && _isDuration( $_->{duration} ) } @{ $slots || [] };

	for my $daysAgo ( defined $slug ? ( 0 .. WINDOW_DAYS ) : () ) {
		my $noon    = $todayNoon - $daysAgo * 86400;
		my $date    = Plugins::RTRFM::Util::perthDate($noon);
		my $weekday = Plugins::RTRFM::Util::perthWeekday($noon);

		next if $byDate{$date};

		for my $slot ( grep { $_->{weekday} == $weekday } @slots ) {
			my $episode = _synthesise( $slug, $date, $slot ) or next;
			next if $now < Plugins::RTRFM::Util::parsePerthDateTime( $episode->{end} ) + PUBLISH_DELAY;

			$byDate{$date} = $episode;
			last;
		}
	}

	my @candidates = map { $byDate{$_} } sort { $b cmp $a } keys %byDate;
	splice( @candidates, MAX_CANDIDATES ) if @candidates > MAX_CANDIDATES;

	return \@candidates;
}

# The show's slug, from its Airnet episodes (all of one show).
sub _slug {
	my ($episode) = grep { ref $_ eq 'HASH' && defined $_->{slug} } @{ $_[0] };
	return $episode ? $episode->{slug} : undef;
}

sub _synthesise {
	my ( $slug, $date, $slot ) = @_;

	my ( $hh, $mm ) = ( $slot->{hhmm} || '' ) =~ /\A([0-9]{2})([0-9]{2})\z/ or return undef;
	my $start = "$date $hh:$mm:00";

	my $epoch = Plugins::RTRFM::Util::parsePerthDateTime($start);
	return undef unless defined $epoch;

	return {
		slug        => $slug,
		date        => $date,
		hhmm        => "$hh$mm",
		start       => $start,
		end         => _perthDateTime( $epoch + $slot->{duration} ),
		duration    => $slot->{duration},
		title       => undef,
		description => undef,
		synthetic   => 1,
	};
}

# epoch -> 'YYYY-MM-DD HH:MM:SS' in Perth time
sub _perthDateTime {
	my @t = gmtime( $_[0] + Plugins::RTRFM::Util::PERTH_OFFSET );
	return sprintf( '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
}

# ---------------------------------------------------------------------------
# Availability
# ---------------------------------------------------------------------------

my @queue;           # keys of checks waiting for a free slot, oldest first
my %checks;          # key => { slug, date, waiters => [ coderef, ... ] }, queued or running
my $inFlight = 0;

sub checkAvailability {
	my ( $episodes, $cb ) = @_;

	my @episodes = grep { ref $_ eq 'HASH' } @{ $episodes || [] };
	splice( @episodes, MAX_CANDIDATES ) if @episodes > MAX_CANDIDATES;

	my $cache = _cache();
	my ( %status, %waiter, $done, $timer );

	my $finish = sub {
		return if $done++;

		Slim::Utils::Timers::killSpecific($timer) if $timer;

		# stop waiting for the checks that are still queued or running
		for my $key ( keys %waiter ) {
			my $check = $checks{$key} or next;
			$check->{waiters} = [ grep { $_ != $waiter{$key} } @{ $check->{waiters} } ];
		}

		$cb->( [ map { { episode => $_, status => $status{ _key($_) } || 'unknown' } } @episodes ] );
	};

	for my $episode (@episodes) {
		my $key = _key($episode);
		next if exists $status{$key} || $waiter{$key};

		my $cached = $cache->get("avail:$key");
		if ( defined $cached ) {
			$status{$key} = $cached ? 'available' : 'unavailable';
			next;
		}

		$waiter{$key} = sub {
			$status{$key} = shift;
			delete $waiter{$key};
			$finish->() unless %waiter;
		};

		_enqueue( $key, $episode, $waiter{$key} );
	}

	return $finish->() unless %waiter;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + CHECK_BUDGET, sub {
		return if $done;
		$log->warn( sprintf( 'rzz availability checks took longer than %d s: %d episode(s) shown as "availability unknown"', CHECK_BUDGET, scalar keys %waiter ) );
		$finish->();
	} );

	_pump();

	return;
}

sub _key { ( defined $_[0]->{slug} ? $_[0]->{slug} : '' ) . ':' . ( defined $_[0]->{date} ? $_[0]->{date} : '' ) }

sub _enqueue {
	my ( $key, $episode, $waiter ) = @_;

	if ( my $check = $checks{$key} ) {
		push @{ $check->{waiters} }, $waiter;
		return;
	}

	$checks{$key} = { slug => $episode->{slug}, date => $episode->{date}, waiters => [$waiter] };
	push @queue, $key;
}

# Start queued checks while fewer than MAX_IN_FLIGHT are running.
sub _pump {
	while ( $inFlight < MAX_IN_FLIGHT && @queue ) {
		my $key   = shift @queue;
		my $check = $checks{$key} or next;

		if ( !@{ $check->{waiters} } ) {
			delete $checks{$key};
			next;
		}

		$inFlight++;

		my $answered;
		my $onResult = sub {
			return if $answered++;
			_finishCheck( $key, $check, shift );
		};

		eval { Plugins::RTRFM::Restream::resolve( $check->{slug}, $check->{date}, $onResult ); 1 }
			or $onResult->( { error => 'rzz check failed: ' . ( $@ || 'unknown error' ) } );
	}
}

sub _finishCheck {
	my ( $key, $check, $result ) = @_;

	$inFlight--;
	delete $checks{$key} if $checks{$key} && $checks{$key} == $check;

	my $status = ref $result ne 'HASH' ? 'unknown'
		: $result->{url}         ? 'available'
		: $result->{unavailable} ? 'unavailable'
		:                          'unknown';

	if ( $status eq 'available' ) {
		_cache()->set( "avail:$key", 1, AVAILABLE_TTL );
	}
	elsif ( $status eq 'unavailable' ) {
		_cache()->set( "avail:$key", 0, UNAVAILABLE_TTL );
	}

	for my $waiter ( @{ $check->{waiters} } ) {
		eval { $waiter->($status); 1 } or $log->error( "Handling the rzz check of $key failed: " . ( $@ || 'unknown error' ) );
	}

	_pump();
}

sub _cache { Slim::Utils::Cache->new( Plugins::RTRFM::Util::CACHE_NAMESPACE ) }

1;
