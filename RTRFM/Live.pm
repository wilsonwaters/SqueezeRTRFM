package Plugins::RTRFM::Live;

# Live stream items for the top-level menu (hook API: see Plugin.pm):
#   "RTRFM 92.1 Live"     the FM simulcast (stream1). line2 is "On air: <show> · <time>"; the
#                         description adds the show description and "Next: <show> · <time>".
#   "RTRFM Infinite Mix"  the second stream (stream2), static.
#
# The show data comes from Plugins::RTRFM::NowPlaying: the cached data while it is fresh,
# otherwise a fetch that gets at most MENU_DEADLINE seconds. After a failed fetch or at the
# deadline, the last good data is used while its show is still on air; otherwise the Live item
# has no show lines. The menu is always answered, exactly once.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::RTRFM::NowPlaying;
use Plugins::RTRFM::Util;

use constant MENU_DEADLINE => 3;    # seconds

my $log = logger('plugin.rtrfm');

# Now-playing metadata for the live streams. Loaded here, so the menu works even if it can't be.
sub init {
	require Plugins::RTRFM::LiveMetadata;
	Plugins::RTRFM::LiveMetadata->init();
}

sub menuItems {
	my ( $class, $client, $cb, $args ) = @_;

	my $answered = 0;
	my $timer;

	my $answer = sub {
		my $info = shift;
		return if $answered++;

		if ($timer) {
			Slim::Utils::Timers::killSpecific($timer);
			undef $timer;
		}

		$cb->( _items( $client, $info ) );
	};

	my $info = eval { Plugins::RTRFM::NowPlaying->cached() };
	return $answer->($info) if $info;

	eval {
		Plugins::RTRFM::NowPlaying->fetch( sub { $answer->( $_[0] || _stillOnAir() ) } );
		1;
	} or do {
		$log->error( 'Could not get the now/next show info: ' . ( $@ || 'unknown error' ) );
		$answer->( _stillOnAir() );
	};

	return if $answered;

	$timer = Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + MENU_DEADLINE, sub {
		undef $timer;
		main::DEBUGLOG && $log->is_debug && $log->debug( 'No now/next show info within ' . MENU_DEADLINE . ' s; answering the menu without it' );
		$answer->( _stillOnAir() );
	} );

	return;
}

# The last good show data while its current show is still on air, else undef.
sub _stillOnAir {
	my $info = Plugins::RTRFM::NowPlaying->lastGood();
	return $info && $info->{current} && defined $info->{current}{end} && $info->{current}{end} > time() ? $info : undef;
}

# [ Live item, Infinite Mix item ]. If building them from the show data fails, the error is
# logged and the items are built without it.
sub _items {
	my ( $client, $info ) = @_;

	my $items = eval { [ _liveItem( $client, $info ), _infiniteMixItem($client) ] };
	return $items if $items;

	$log->error( 'Could not build the live menu from the show data, using the static items: ' . ( $@ || 'unknown error' ) );
	return [ _liveItem( $client, undef ), _infiniteMixItem($client) ];
}

sub _liveItem {
	my ( $client, $info ) = @_;

	my ( $current, $next ) = $info ? @{$info}{qw(current next)} : ();

	my $onAir    = $current ? Plugins::RTRFM::NowPlaying::showLabel($current) : undef;
	my $upcoming = $next    ? Plugins::RTRFM::NowPlaying::showLabel($next)    : undef;

	my $line2 = defined $onAir ? cstring( $client, 'PLUGIN_RTRFM_ON_AIR', $onAir ) : undef;

	my @description = grep { defined && length } (
		$line2,
		$current ? $current->{description} : undef,
		defined $upcoming ? cstring( $client, 'PLUGIN_RTRFM_NEXT', $upcoming ) : undef,
	);

	return _item(
		cstring( $client, 'PLUGIN_RTRFM_LIVE' ),
		( $info && $info->{streamUrl} ) || Plugins::RTRFM::Util::STREAM1_URL,
		defined $line2 ? ( line2 => $line2 ) : (),
		@description ? ( description => join( "\n", @description ) ) : (),
	);
}

sub _infiniteMixItem {
	my $client = shift;

	my $description = cstring( $client, 'PLUGIN_RTRFM_INFINITE_MIX_DESC' );

	return _item(
		cstring( $client, 'PLUGIN_RTRFM_INFINITE_MIX' ),
		Plugins::RTRFM::Util::STREAM2_URL,
		line2       => $description,
		description => $description,
	);
}

# A playable stream item; favourites keep the stream URL, the name and the station icon.
sub _item {
	my ( $name, $url, %extra ) = @_;

	return {
		name            => $name,
		line1           => $name,
		favorites_title => $name,
		type            => 'audio',
		on_select       => 'play',
		url             => $url,
		favorites_url   => $url,
		image           => Plugins::RTRFM::Util::ICON,
		favorites_icon  => Plugins::RTRFM::Util::ICON,
		%extra,
	};
}

1;
