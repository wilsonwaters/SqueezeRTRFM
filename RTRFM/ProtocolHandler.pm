package Plugins::RTRFM::ProtocolHandler;

# Protocol handler for rtrfm://episode/... URLs (registered by Plugins::RTRFM::OnDemand->init).
# Placeholder: the episode playback task (O1) implements resolving and streaming.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

1;
