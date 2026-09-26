package Slim::Music::Info;

# Test stub for LMS Slim::Music::Info: the remote-stream metadata helpers.
# Real API:
#   setCurrentTitle($url, $title, $client)   getCurrentTitle($client, $url)
#   setRemoteMetadata($url, \%meta)          (ignored for non-remote URLs)
#   setDelayedCallback($client, $cb, $outputDelayOnly)  (runs $cb after the player's buffer delay)
#   isRemoteURL($url)
# Values are kept in %CURRENT_TITLE / %REMOTE_METADATA; delayed callbacks run at once.

use strict;
use warnings;

our %CURRENT_TITLE;
our %REMOTE_METADATA;

sub setCurrentTitle {
	my ( $url, $title, $client ) = @_;
	$CURRENT_TITLE{$url} = $title;
	return;
}

sub getCurrentTitle {
	my ( $client, $url ) = @_;
	return undef unless $url;
	return $CURRENT_TITLE{$url};
}

sub setRemoteMetadata {
	my ( $url, $meta ) = @_;
	return unless isRemoteURL($url);
	$REMOTE_METADATA{$url} = { %{ $REMOTE_METADATA{$url} || {} }, %{ $meta || {} } };
	return;
}

sub setDelayedCallback {
	my ( $client, $cb ) = @_;
	$cb->() if $cb;
	return;
}

sub isRemoteURL {
	my $url = shift;
	return defined $url && $url =~ m{^[a-z][a-z0-9+.\-]*://}i && $url !~ m{^(?:file|db|tmp)://}i ? 1 : 0;
}

# test helper
sub reset { %CURRENT_TITLE = (); %REMOTE_METADATA = (); return }

1;
