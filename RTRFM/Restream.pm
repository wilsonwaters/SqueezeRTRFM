package Plugins::RTRFM::Restream;

# Resolves an RTRFM on-demand episode to its audio file through RTRFM's "rzz" service.
#
# Public API (used by the rtrfm:// protocol handler at play time, and for availability checks):
#
#   Plugins::RTRFM::Restream::resolve($slug, $date, $cb)
#   (Plugins::RTRFM::Restream->resolve($slug, $date, $cb) works too)
#
#   $slug  Airnet/restream slug, [a-z0-9_-]+ (e.g. 'saturdayjazz')
#   $date  Perth calendar date of the episode start, 'YYYY-MM-DD'
#   $cb    called exactly once, with one hashref:
#            { url => $signedMp3Url }  the episode's audio exists; the URL is signed and
#                                      short-lived, so use it straight away and never store it
#            { unavailable => 1 }      rzz points at something other than an MP3 (today an
#                                      .mp4 URL that answers 404): the audio has been deleted
#                                      (RTRFM keeps about 28 days) or the show/date is unknown
#            { error => $message }     invalid input, HTTP error or timeout, a body that isn't
#                                      JSON, a missing/empty/non-string "u", or a URL on any
#                                      host other than https://restreams.rtrfm.com.au/
#          Invalid input calls $cb straight away without any HTTP request; otherwise $cb is
#          called when the request completes. Callers must not rely on either timing.
#
# rzz: GET https://restreams.rtrfm.com.au/rzz?n=<slug>&d=<date> answers 200 with a JSON body
# (served as application/javascript), e.g.
#   {"u":"https://restreams.rtrfm.com.au/shows/saturdayjazz_2026-09-19.mp3?st=...&e=..."}
# even for unknown slugs. Every call hits rzz: signed URLs must not be cached or reused.

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::RTRFM::HTTP;
use Plugins::RTRFM::Util;

use constant RESTREAMS_PREFIX => 'https://restreams.rtrfm.com.au/';

my $log = logger('plugin.rtrfm');

sub resolve {
	shift if @_ && defined $_[0] && $_[0] eq __PACKAGE__;
	my ( $slug, $date, $cb ) = @_;

	if ( ref $cb ne 'CODE' ) {
		$log->error('Restream::resolve called without a callback');
		return;
	}

	# episodeUrl validates the slug and the date exactly as the episode URL contract does
	if ( !defined Plugins::RTRFM::Util::episodeUrl( $slug, $date ) ) {
		my $message = sprintf( 'Invalid episode for rzz: slug "%s", date "%s"',
			map { defined $_ ? $_ : '' } $slug, $date );
		$log->warn($message);
		return $cb->( { error => $message } );
	}

	my $rzzUrl = Plugins::RTRFM::Util::RZZ_BASE . "?n=$slug&d=$date";

	Plugins::RTRFM::HTTP::getJSON(
		$rzzUrl,
		sub {
			my $data = shift;
			my $u = ref $data eq 'HASH' ? $data->{u} : undef;

			if ( !defined $u || ref $u || !length $u ) {
				my $message = "rzz returned no audio URL ($rzzUrl)";
				$log->warn($message);
				return $cb->( { error => $message } );
			}

			if ( index( $u, RESTREAMS_PREFIX ) != 0 ) {
				my $message = "rzz returned an audio URL on an unexpected host: $u ($rzzUrl)";
				$log->warn($message);
				return $cb->( { error => $message } );
			}

			# ".mp3" followed by the query string (the signature) or the end of the URL
			if ( $u !~ /\.mp3(?:\?|\z)/ ) {
				main::INFOLOG && $log->is_info && $log->info("No audio for $slug $date: rzz returned $u");
				return $cb->( { unavailable => 1 } );
			}

			main::DEBUGLOG && $log->is_debug && $log->debug("Resolved $slug $date to $u");
			return $cb->( { url => $u } );
		},
		sub {
			my $message = shift;
			# HTTP.pm has already logged it
			return $cb->( { error => defined $message && length $message ? $message : "rzz request failed ($rzzUrl)" } );
		},
	);

	return;
}

1;
