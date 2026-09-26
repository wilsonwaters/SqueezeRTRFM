package Plugins::RTRFM::NowPlaying;

# The show on air now and the next show, from RTRFM's "current and next show" endpoint: fetch,
# parse and cache. Used by the live menu (Live.pm) and the live now-playing metadata.
#
#   fetch($cb)              $cb->($info) on success, $cb->(undef, $message) on failure; exactly
#                           one call per fetch. Answers synchronously while the cache is fresh,
#                           and for NEGATIVE_TTL seconds after a failure. Calls made while a
#                           request is in flight wait for it: one upstream request for all.
#   cached()                the fresh $info, or undef
#   lastGood()              the most recent successfully parsed $info, whatever its age, or undef
#   parse($decoded[, $now]) pure: the decoded JSON body -> $info, or undef if it isn't a
#                           successful response
#   showLabel($show)        pure: "<name> · <timeText>", "<name>", or undef without a name
#
# Each can be called as a function or as a class method (Plugins::RTRFM::NowPlaying->cached).
#
# $info = {
#   current   => { name, slug, start, end, timeText, image, description, link } | undef,
#   next      => { name, slug, start, end, timeText, image, description, link } | undef,
#   streamUrl => data.stream_url if it is a live.rtrfm.com.au URL, else undef,
#   fetched   => epoch,
#   expires   => epoch; fresh while time() < expires,
# }
# start and end are epochs. The cache lifetime is next.start - now, clamped to MIN_TTL..MAX_TTL;
# current.end stands in when there is no next.start, and DEFAULT_TTL applies when neither is known.
#
# Logging: HTTP.pm logs one DEBUG line per request (it contains the endpoint URL, which no other
# line here does). A failed update is logged at WARN once per run of consecutive failures, the
# rest of the run at DEBUG; requests are made with HTTP.pm's quiet option, so HTTP.pm logs their
# failures at DEBUG rather than adding a WARN of its own for each one.

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::RTRFM::HTTP;
use Plugins::RTRFM::Util qw(parseISO8601 decodeEntities);

use constant URL          => 'https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show';
use constant MIN_TTL      => 60;
use constant MAX_TTL      => 900;
use constant DEFAULT_TTL  => 300;
use constant NEGATIVE_TTL => 20;

my $log = logger('plugin.rtrfm');

my $lastGood;              # most recent successfully parsed $info (the cache while fresh)
my @waiting;               # callbacks waiting for the request in flight
my $inFlight    = 0;
my $failedUntil = 0;       # negative cache: no request before this time
my $lastError;
my $failures    = 0;       # consecutive failed updates

sub fetch {
	shift if _isClass( $_[0] );
	my $cb = shift;

	if ( my $info = cached() ) {
		$cb->($info);
		return;
	}

	if ( time() < $failedUntil ) {
		$cb->( undef, $lastError );
		return;
	}

	push @waiting, $cb;
	return if $inFlight;
	$inFlight = 1;

	eval {
		Plugins::RTRFM::HTTP::getJSON(
			URL,
			sub {
				my $info = eval { parse( $_[0] ) };
				$info ? _succeeded($info) : _failed('Unexpected response (no show data)');
			},
			sub { _failed( $_[0] ) },
			{ quiet => 1 },
		);
		1;
	} or do {
		my $error = $@ || 'unknown error';
		_failed("Request failed: $error") if $inFlight;
	};

	return;
}

sub cached { return $lastGood && time() < $lastGood->{expires} ? $lastGood : undef }

sub lastGood { return $lastGood }

sub parse {
	shift if _isClass( $_[0] );
	my ( $decoded, $now ) = @_;
	$now = time() unless defined $now;

	return undef unless ref $decoded eq 'HASH' && $decoded->{success} && ref $decoded->{data} eq 'HASH';
	my $data = $decoded->{data};

	my $next    = _show( $data->{next}, $data->{next_show} );
	my $current = _show( $data->{current}, $data->{current_show}, $next ? $next->{start} : undef );

	my ($boundary) = grep { defined } ( $next ? $next->{start} : undef ), ( $current ? $current->{end} : undef );
	my $ttl = defined $boundary ? _clamp( $boundary - $now, MIN_TTL, MAX_TTL ) : DEFAULT_TTL;

	my $streamUrl = $data->{stream_url};
	$streamUrl = undef unless defined $streamUrl && !ref $streamUrl && $streamUrl =~ m{\Ahttps?://live\.rtrfm\.com\.au/\S+\z};

	return {
		current   => $current,
		next      => $next,
		streamUrl => $streamUrl,
		fetched   => $now,
		expires   => $now + $ttl,
	};
}

sub showLabel {
	shift if _isClass( $_[0] );
	my $show = shift;

	return undef unless ref $show eq 'HASH' && defined $show->{name} && length $show->{name};
	return $show->{name} unless defined $show->{timeText} && length $show->{timeText};
	return "$show->{name} \x{B7} $show->{timeText}";
}

# Forget everything (for tests).
sub _reset {
	undef $lastGood;
	undef $lastError;
	@waiting     = ();
	$inFlight    = 0;
	$failedUntil = 0;
	$failures    = 0;
	return;
}

sub _succeeded {
	my $info = shift;

	$lastGood    = $info;
	$failures    = 0;
	$failedUntil = 0;
	undef $lastError;

	main::DEBUGLOG && $log->is_debug && $log->debug( sprintf(
		'Now/next show info: on air %s, next %s; fresh for %d s',
		map( { defined $_ ? "'$_'" : 'none' } showLabel( $info->{current} ), showLabel( $info->{next} ) ),
		$info->{expires} - $info->{fetched},
	) );

	_notify($info);
}

sub _failed {
	my $message = shift || 'unknown error';

	$lastError   = $message;
	$failedUntil = time() + NEGATIVE_TTL;

	# HTTP.pm's messages end with the URL, which its own request line already logged
	my $url = URL;
	( my $reason = $message ) =~ s/\s*\(\Q$url\E\)//;

	if ( $failures++ ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Now/next show info still unavailable: $reason");
	}
	else {
		$log->warn("Now/next show info unavailable: $reason");
	}

	_notify( undef, $message );
}

# Call every waiting callback once. One that dies is logged and doesn't stop the others.
sub _notify {
	my @args      = @_;
	my @callbacks = @waiting;

	@waiting  = ();
	$inFlight = 0;

	for my $cb (@callbacks) {
		eval { $cb->(@args); 1 } or $log->error( 'Now/next show info callback failed: ' . ( $@ || 'unknown error' ) );
	}

	return;
}

# One show from its summary (data.current / data.next) and its details (data.current_show /
# data.next_show). $fallbackEnd is used when the details have no end time.
sub _show {
	my ( $summary, $details, $fallbackEnd ) = @_;

	$summary = undef unless ref $summary eq 'HASH';
	$details = undef unless ref $details eq 'HASH';
	return undef unless $summary || $details;

	# Never mix fields from two different shows: ignore the details if the start times differ.
	if ( $summary && $details ) {
		my ( $s1, $s2 ) = ( _text( $summary->{startTime} ), _text( $details->{start_time} ) );
		if ( defined $s1 && defined $s2 ) {
			my ( $e1, $e2 ) = ( parseISO8601($s1), parseISO8601($s2) );
			undef $details unless defined $e1 && defined $e2 ? $e1 == $e2 : $s1 eq $s2;
		}
	}

	$summary ||= {};
	$details ||= {};

	my $name = _first( map { _text( decodeEntities( _text($_) ) ) } $summary->{name}, $details->{name} );
	return undef unless defined $name;

	my $slug = _first( _text( $details->{slug} ), _slugFromLink( $summary->{link} ) );
	$slug = undef if defined $slug && $slug !~ /\A[a-z0-9_-]+\z/;

	my $end = parseISO8601( _text( $details->{end_time} ) );
	$end = $fallbackEnd unless defined $end;

	my $image = _text( $summary->{thumbnail} );
	$image = undef if defined $image && $image !~ m{\Ahttps?://\S+\z}i;

	return {
		name        => $name,
		slug        => $slug,
		start       => _first( map { parseISO8601( _text($_) ) } $details->{start_time}, $summary->{startTime} ),
		end         => $end,
		timeText    => _first( _text( $summary->{time} ), _text( $details->{friendly_times} ) ),
		image       => $image,
		description => _description( $details->{short_description} ),
		link        => _first( _text( $details->{url} ), _text( $summary->{link} ) ),
	};
}

sub _slugFromLink {
	my $link = _text(shift);
	return undef unless defined $link;
	my ($slug) = $link =~ m{/shows/([^/?#]+)};
	return $slug;
}

# Decoded plain text: tags stripped, entities decoded, whitespace collapsed, trimmed.
sub _description {
	my $text = _text(shift);
	return undef unless defined $text;

	$text =~ s{<\s*/?\s*(?:br|p|div|li)\b[^>]*>}{ }gi;
	$text =~ s{<[^>]*>}{}g;
	$text = decodeEntities($text);
	$text =~ s/\s+/ /g;

	return _text($text);
}

# A trimmed, non-empty string, or undef.
sub _text {
	my $value = shift;
	return undef unless defined $value && !ref $value;

	$value =~ s/^\s+//;
	$value =~ s/\s+$//;

	return length $value ? $value : undef;
}

sub _first {
	for (@_) { return $_ if defined }
	return undef;
}

sub _clamp {
	my ( $value, $min, $max ) = @_;
	return $value < $min ? $min : $value > $max ? $max : $value;
}

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

1;
