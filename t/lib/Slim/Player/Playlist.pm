package Slim::Player::Playlist;

# Test stub for LMS Slim::Player::Playlist.
# Real API: url($client, $index) returns the URL of the track at $index (default: the playing
# song); track($client, $index) returns the track object (here: the URL); count($client).
# Tests set %PLAYLISTS{$clientId} = [ urls ] and optionally %INDEX{$clientId}.

use strict;
use warnings;

our %PLAYLISTS;
our %INDEX;

sub count {
	my $client = shift;
	return scalar @{ $PLAYLISTS{ _id($client) } || [] };
}

sub track {
	my ( $client, $index ) = @_;
	my $id = _id($client);
	$index = $INDEX{$id} || 0 unless defined $index;
	return ( $PLAYLISTS{$id} || [] )->[$index];
}

sub url { track(@_) }

# test helper
sub reset { %PLAYLISTS = (); %INDEX = (); return }

sub _id {
	my $client = shift;
	return '' unless defined $client;
	return ref $client && $client->can('id') ? $client->id : "$client";
}

1;
