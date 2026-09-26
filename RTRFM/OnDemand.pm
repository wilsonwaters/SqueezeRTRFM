package Plugins::RTRFM::OnDemand;

# On-demand items for the top-level menu (hook API: see Plugin.pm).
# Placeholder: registers the rtrfm:// protocol handler used by episode URLs
# (Plugins::RTRFM::Util::episodeUrl) and returns no menu items yet. The ondemand stream (O1-O6)
# fills in the menus; the handler registration stays here.

use strict;
use warnings;

use Slim::Player::ProtocolHandlers;

use Plugins::RTRFM::ProtocolHandler;

sub init {
	Slim::Player::ProtocolHandlers->registerHandler( rtrfm => 'Plugins::RTRFM::ProtocolHandler' );
}

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	$cb->( [] );
}

1;
