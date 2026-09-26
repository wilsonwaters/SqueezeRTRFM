package Plugins::RTRFM::Live;

# Live stream items for the top-level menu (hook API: see Plugin.pm).
# Placeholder: a single playable item for the FM simulcast stream. The live stream (L1/L2)
# replaces this with stream discovery, the Infinite Mix item and now-playing metadata.

use strict;
use warnings;

use Slim::Utils::Strings qw(cstring);

use Plugins::RTRFM::Util;

sub init { }

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [ {
		name      => cstring( $client, 'PLUGIN_RTRFM_LIVE' ),
		type      => 'audio',
		url       => Plugins::RTRFM::Util::STREAM1_URL,
		on_select => 'play',
		image     => Plugins::RTRFM::Util::ICON,
	} ] );
}

1;
