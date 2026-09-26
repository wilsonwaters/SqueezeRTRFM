package Plugins::RTRFM::Plugin;

# RTRFM 92.1 for Lyrion Music Server: registers the "RTRFM 92.1" entry in the Radio menu.
#
# Hook API (frozen: the live and ondemand streams never edit this file). Both hook classes,
# Plugins::RTRFM::Live and Plugins::RTRFM::OnDemand, implement:
#
#   Class->init()
#       Called once from initPlugin, Live first, then OnDemand. If it dies the error is logged
#       and the plugin still loads.
#
#   Class->menuItems($client, $cb, $args)
#       Called for every top-level menu request, Live first, then OnDemand. Must call
#       $cb->(\@items) exactly once, synchronously or later, even on error. The top-level menu
#       is Live's items followed by OnDemand's. A hook that dies or calls back with anything but
#       an array ref contributes a single error text item instead; a second call back is ignored.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.rtrfm',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_RTRFM',
} );

# Hook classes, in menu order. Loaded at runtime so a broken module only breaks its own items.
my @HOOKS = qw(Plugins::RTRFM::Live Plugins::RTRFM::OnDemand);

sub initPlugin {
	my $class = shift;

	for my $hook (@HOOKS) {
		eval {
			( my $file = "$hook.pm" ) =~ s{::}{/}g;
			require $file;
			$hook->init();
			1;
		} or $log->error( "$hook init failed: " . ( $@ || 'unknown error' ) );
	}

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'rtrfm',
		menu   => 'radios',
		is_app => 0,
		weight => 10,
	);
}

sub getDisplayName { 'PLUGIN_RTRFM' }

sub playerMenu { 'RADIO' }

# Top-level feed: ask every hook for its items (all requests start at once), wait for all of
# them, then call $cb once with the items in hook order.
sub toplevel {
	my ( $client, $cb, $args ) = @_;

	my @results;
	my $pending = scalar @HOOKS;

	for my $i ( 0 .. $#HOOKS ) {
		my $hook   = $HOOKS[$i];
		my $called = 0;

		my $hookCb = sub {
			my $items = shift;

			if ( $called++ ) {
				$log->warn("$hook->menuItems called back more than once; ignoring the extra call");
				return;
			}

			if ( ref $items ne 'ARRAY' ) {
				$log->error( "$hook->menuItems called back with " . ( defined $items ? ( ref $items || 'a scalar' ) : 'undef' ) . ' instead of an array ref' );
				$items = [ _errorItem($client) ];
			}

			$results[$i] = $items;

			if ( --$pending == 0 ) {
				$cb->( { items => [ map { @$_ } @results ] } );
			}
		};

		eval {
			$hook->menuItems( $client, $hookCb, $args );
			1;
		} or do {
			my $error = $@ || 'unknown error';
			$log->error("$hook->menuItems failed: $error");
			$hookCb->( [ _errorItem($client) ] ) unless $called;
		};
	}

	return;
}

sub _errorItem {
	my $client = shift;

	return {
		name => cstring( $client, 'PLUGIN_RTRFM_ERROR' ),
		type => 'text',
	};
}

1;
