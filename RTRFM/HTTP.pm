package Plugins::RTRFM::HTTP;

# Non-blocking HTTP helpers for talking to RTRFM's web services, on top of
# Slim::Networking::SimpleAsyncHTTP.
#
#   getJSON($url, $cb, $ecb, \%opts)                 GET, decode the body as JSON
#   postFormJSON($url, \%form, $cb, $ecb, \%opts)    POST form-encoded fields, decode JSON
#   get($url, $cb, $ecb, \%opts)                     GET, raw body string (e.g. HTML)
#
# Contract (every function):
#   - Every request sends an explicit User-Agent: LMS's own user agent string. Cloudflare in
#     front of rtrfm.com.au and airnet.org.au answers 403 to "libwww-perl/..." agents.
#   - Timeout defaults to 15 seconds (opts: timeout). opts cache/expires are passed through to
#     SimpleAsyncHTTP (cache => 1, expires => seconds or '1h').
#   - JSON is decoded whatever the Content-Type (the restream service answers
#     application/javascript); a UTF-8 byte-order mark and surrounding whitespace are ignored.
#     The decoded value must be an object or an array.
#   - Exactly one callback is called per request:
#       $cb->($data, $http)     $data = decoded JSON (getJSON/postFormJSON) or body string (get)
#       $ecb->($message, $http) $message is readable, e.g. "HTTP request failed: 403 Forbidden (<url>)"
#     If $cb itself dies, the exception propagates; $ecb is not called as well.
#
# Owned by the foundation stream: other streams may only append to it (and must say so in their PR).

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Misc;

use constant DEFAULT_TIMEOUT => 15;

my $log = logger('plugin.rtrfm');

sub getJSON {
	my ( $url, $cb, $ecb, $opts ) = @_;

	_request( GET => $url, [], undef, _jsonHandler( $url, $cb, $ecb ), $ecb, $opts );
}

sub postFormJSON {
	my ( $url, $form, $cb, $ecb, $opts ) = @_;

	_request(
		POST => $url,
		[ 'Content-Type' => 'application/x-www-form-urlencoded' ],
		_encodeForm($form),
		_jsonHandler( $url, $cb, $ecb ),
		$ecb, $opts
	);
}

sub get {
	my ( $url, $cb, $ecb, $opts ) = @_;

	_request( GET => $url, [], undef, sub { $cb->( $_[0]->content, $_[0] ) }, $ecb, $opts );
}

sub _request {
	my ( $method, $url, $headers, $body, $onSuccess, $ecb, $opts ) = @_;
	$opts ||= {};

	my $onError = sub {
		my ( $http, $error ) = @_;
		_fail( $ecb, sprintf( 'HTTP request failed: %s (%s)', $error || 'unknown error', $url ), $http );
	};

	my %params = ( timeout => $opts->{timeout} || DEFAULT_TIMEOUT );
	for my $key (qw(cache expires)) {
		$params{$key} = $opts->{$key} if defined $opts->{$key};
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new( $onSuccess, $onError, \%params );

	my @args = ( 'User-Agent' => Slim::Utils::Misc::userAgentString(), @$headers );
	push @args, $body if defined $body;

	main::DEBUGLOG && $log->is_debug && $log->debug("$method $url");

	if ( $method eq 'POST' ) {
		$http->post( $url, @args );
	}
	else {
		$http->get( $url, @args );
	}

	return;
}

# Success callback for JSON requests: decode, then call exactly one of $cb / $ecb.
sub _jsonHandler {
	my ( $url, $cb, $ecb ) = @_;

	return sub {
		my $http = shift;
		my ( $data, $error ) = _decodeJSON( $http->content );

		if ( defined $error ) {
			return _fail( $ecb, "$error ($url)", $http );
		}

		$cb->( $data, $http );
	};
}

sub _decodeJSON {
	my $content = shift;
	$content = '' unless defined $content;

	$content =~ s/^(?:\xEF\xBB\xBF|\x{FEFF})//;
	$content =~ s/^\s+//;
	$content =~ s/\s+$//;

	return ( undef, 'Empty response' ) unless length $content;

	my $data = eval { from_json($content) };

	if ($@) {
		( my $error = $@ ) =~ s/\s+at \S+ line \d+.*//s;
		return ( undef, "Invalid JSON response: $error" );
	}

	if ( !ref $data || ( ref $data ne 'HASH' && ref $data ne 'ARRAY' ) ) {
		return ( undef, 'Unexpected JSON response (not an object or array)' );
	}

	return ($data);
}

sub _fail {
	my ( $ecb, $message, $http ) = @_;

	$log->warn($message);
	$ecb->( $message, $http ) if $ecb;

	return;
}

sub _encodeForm {
	my $form = shift || {};

	my @pairs;
	for my $key ( sort keys %$form ) {
		my $value = $form->{$key};
		for my $v ( ref $value eq 'ARRAY' ? @$value : ($value) ) {
			push @pairs, uri_escape_utf8($key) . '=' . uri_escape_utf8( defined $v ? $v : '' );
		}
	}

	return join( '&', @pairs );
}

1;
