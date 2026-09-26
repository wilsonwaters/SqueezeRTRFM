package Plugins::RTRFM::LiveMetadata;

# Now-playing metadata for the live streams: stream1 (the FM simulcast) shows the show on air,
# stream2 (Infinite Mix) a static station title. RTRFM publishes no live track data, so the
# show is as detailed as it gets.
#
#   init()                     called from Live->init. Registers, for LIVE_RE, the
#                              Slim::Formats::RemoteMetadata provider and parser, the "Show info"
#                              song info entry (Slim::Menu::TrackInfo) and a current-title change
#                              callback (see "Stream title" below).
#   provider($client, $url)    metadata for a live URL: synchronous, cheap, no network, never
#                              dies. stream2: { title, artist, cover }, static. stream1:
#                              buildMeta() of NowPlaying's cached data (or its last good data);
#                              starts polling for the player (see "Polling").
#   parser($client, $url, $metadata)   returns 1: the streams' ICY titles are always empty, so
#                              they are swallowed instead of replacing the show.
#   buildMeta($info, $now)     pure: NowPlaying $info -> { title, artist, album, cover }
#   trackInfo($client, $url, $track, $remoteMeta, $tags)   the "Show info" item, or undef
#   streamOf($url)             1 or 2 for a live stream URL, else undef
#
# buildMeta picks the show on air: current until current.end; from next.start, next (as the
# site does at a show change, before the data is refreshed); otherwise none, and the metadata
# is the default { title => "RTRFM 92.1 Live", artist, cover => icon }. For a show:
# title = show name, artist = "RTRFM 92.1", album = "<time> · Next: <name> · <time>" (the
# parts that exist), cover = show thumbnail or the station icon. No duration or secs: there is
# no progress bar, and $song->duration/startOffset are never touched.
#
# Polling: while a player plays (or pauses) stream1, one Slim::Utils::Timers timer keyed on the
# player (the master of a sync group) refreshes NowPlaying: at clamp(next.start + 60 - now,
# 60, 900) s, 300 s when current or next is missing, 30 s after a failure. A poll stops (no
# fetch, no new timer) once the player is stopped or plays something other than stream1; a
# stream2 provider call stops it too. All players share NowPlaying's cache, so any number of
# players costs one upstream request per refresh.
#
# Push, when the metadata a player last got changes: setCurrentTitle (without a client, so it
# doesn't count as a new song), the playing song's wmaMeta, currentPlaylistUpdateTime (the
# Default web skin refreshes on it), then a 'newmetadata' notification (Material, players).
#
# Stream title (current_title): the streams send an empty icy-name header, which LMS stores as
# the stream's current title (" "). The current-title change callback replaces any title LMS
# is about to store for a live URL with ours, and the provider sets ours when it changes (e.g.
# at a show boundary), so it is always the show name (stream1) or "RTRFM Infinite Mix".
#
# Logging: DEBUG for each poll, push and stop decision. Fetch failures are logged (WARN once per
# run) by NowPlaying only. An unexpected error is logged at ERROR the first time, then DEBUG.
#
# Known limitation: metadata is attached to the /stream1 and /stream2 paths only.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Control::Request;
use Slim::Formats::RemoteMetadata;
use Slim::Menu::TrackInfo;
use Slim::Music::Info;
use Slim::Player::Playlist;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Timers;

use Plugins::RTRFM::NowPlaying;
use Plugins::RTRFM::Util;

use constant LIVE_RE        => qr{\Ahttps?://live\.rtrfm\.com\.au(?::[0-9]+)?/stream([12])(?:[?#]|\z)};
use constant BOUNDARY_GRACE => 60;     # poll this long after next.start
use constant MIN_DELAY      => 60;
use constant MAX_DELAY      => 900;
use constant MISSING_DELAY  => 300;    # current or next missing
use constant ERROR_DELAY    => 30;
use constant SEPARATOR      => " \x{B7} ";

my $log = logger('plugin.rtrfm');

my %polls;           # master id => { master, pushed => last pushed metadata }
our $settingTitle;   # true while we set a stream title ourselves
my %errorsSeen;      # unexpected errors already logged at ERROR

sub init {
	Slim::Formats::RemoteMetadata->registerProvider( match => LIVE_RE, func => \&provider );
	Slim::Formats::RemoteMetadata->registerParser( match => LIVE_RE, func => \&parser );

	Slim::Menu::TrackInfo->registerInfoProvider( rtrfm_live_show => (
		after => 'top',
		func  => \&trackInfo,
	) );

	Slim::Music::Info::setCurrentTitleChangeCallback( \&_titleChanged );

	return;
}

sub streamOf {
	my $url = shift;
	return undef unless defined $url && !ref $url && $url =~ LIVE_RE;
	return $1;
}

sub provider {
	my ( $client, $url ) = @_;

	my $meta = eval { _provide( $client, $url ) };
	return $meta if $meta;

	_error( 'Live metadata provider failed', $@ );
	return _default( streamOf($url) );
}

sub parser { return 1 }

sub buildMeta {
	shift if _isClass( $_[0] );
	my ( $info, $now ) = @_;
	$now = time() unless defined $now;

	my ( $show, $upcoming ) = _pick( $info, $now );
	return _default(1) unless $show;

	my $next  = Plugins::RTRFM::NowPlaying::showLabel($upcoming);
	my @album = grep { defined && length } $show->{timeText}, defined $next ? string( 'PLUGIN_RTRFM_NEXT', $next ) : undef;

	return {
		title  => $show->{name},
		artist => string('PLUGIN_RTRFM'),
		@album ? ( album => join( SEPARATOR, @album ) ) : (),
		cover  => $show->{image} || Plugins::RTRFM::Util::ICON,
	};
}

sub trackInfo {
	my ( $client, $url ) = @_;

	return undef unless ( streamOf($url) || 0 ) == 1;

	my ( $show, $upcoming ) = _pick( _info(), time() );
	my $onAir = Plugins::RTRFM::NowPlaying::showLabel($show);
	return undef unless defined $onAir;

	my $next = Plugins::RTRFM::NowPlaying::showLabel($upcoming);

	return {
		name  => cstring( $client, 'PLUGIN_RTRFM_SHOW_INFO' ),
		items => [
			{ type => 'text', name => cstring( $client, 'PLUGIN_RTRFM_ON_AIR', $onAir ) },
			defined $show->{description} ? { type => 'textarea', wrap => 1, name => $show->{description} } : (),
			defined $next ? { type => 'text', name => cstring( $client, 'PLUGIN_RTRFM_NEXT', $next ) } : (),
		],
	};
}

# Forget all poll state (for tests; a restarted LMS starts like this).
sub _reset {
	%polls      = ();
	%errorsSeen = ();
	undef $settingTitle;
	return;
}

sub _provide {
	my ( $client, $url ) = @_;

	my $stream = streamOf($url) or return {};
	my $master = $client ? $client->master : undef;

	if ( $stream == 2 ) {
		_stop( $master, 'stream2 metadata requested' ) if $master && $polls{ $master->id };
	}
	elsif ( $master && !$polls{ $master->id } && _playingStream1($master) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: start polling for ' . $master->id );
		$polls{ $master->id } = { master => $master };
		_poll($master);
	}

	my $meta = _meta($stream);
	_setTitle( $url, $meta->{title} );

	return $meta;
}

# The metadata for stream 1 or 2 right now.
sub _meta {
	my $stream = shift;
	return $stream == 1 ? buildMeta( _info(), time() ) : _default($stream);
}

sub _default {
	my $stream = shift || 1;
	return {
		title  => string( $stream == 2 ? 'PLUGIN_RTRFM_INFINITE_MIX' : 'PLUGIN_RTRFM_LIVE' ),
		artist => string('PLUGIN_RTRFM'),
		cover  => Plugins::RTRFM::Util::ICON,
	};
}

sub _info { Plugins::RTRFM::NowPlaying->cached() || Plugins::RTRFM::NowPlaying->lastGood() }

# (show on air, the show after it) from $info at $now, or () when no show is known to be on air.
sub _pick {
	my ( $info, $now ) = @_;
	return () unless ref $info eq 'HASH';

	my ( $current, $next ) = map { ref $_ eq 'HASH' ? $_ : undef } @{$info}{qw(current next)};

	return ( $current, $next ) if $current && ( !defined $current->{end} || $now < $current->{end} );

	return ( $next, undef )
		if $next && defined $next->{start} && $now >= $next->{start} && ( !defined $next->{end} || $now < $next->{end} );

	return ();
}

# The stream1 URL $master plays, if it is playing or paused; else undef.
sub _playingStream1 {
	my $master = shift;

	return undef unless $master->isPlaying || $master->isPaused;

	my $url = Slim::Player::Playlist::url($master);
	return ( streamOf($url) || 0 ) == 1 ? $url : undef;
}

sub _poll {
	my $master = shift;

	Slim::Utils::Timers::killTimers( $master, \&_poll );

	my $state = $polls{ $master->id } or return;

	eval {
		if ( _playingStream1($master) ) {
			main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: polling the show info for ' . $master->id );
			Plugins::RTRFM::NowPlaying->fetch( sub { _fetched( $master, $state, @_ ) } );
		}
		else {
			_stop( $master, 'not playing stream1 any more' );
		}
		1;
	} or do {
		_error( 'Live metadata poll failed', $@ );
		_schedule( $master, ERROR_DELAY ) if _isCurrent( $master, $state );
	};

	return;
}

sub _fetched {
	my ( $master, $state, $info ) = @_;

	# stopped, or stopped and started again, while the request was in flight
	return unless _isCurrent( $master, $state );

	my $url = _playingStream1($master);
	return _stop( $master, 'not playing stream1 any more' ) unless $url;

	if ( !$info ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: no show info for ' . $master->id . ', no push' );
		return _schedule( $master, ERROR_DELAY );
	}

	my $now  = time();
	my $meta = buildMeta( $info, $now );

	if ( _changed( $state->{pushed}, $meta ) ) {
		_push( $master, $url, $meta );
		$state->{pushed} = $meta;
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: unchanged for ' . $master->id . ', no push' );
	}

	_schedule( $master, _nextDelay( $info, $now ) );
	return;
}

sub _isCurrent {
	my ( $master, $state ) = @_;
	my $current = $polls{ $master->id };
	return $current && $current == $state;
}

sub _nextDelay {
	my ( $info, $now ) = @_;

	my ( $current, $next ) = @{$info}{qw(current next)};
	return MISSING_DELAY unless $current && $next && defined $next->{start};

	my $delay = $next->{start} + BOUNDARY_GRACE - $now;
	return $delay < MIN_DELAY ? MIN_DELAY : $delay > MAX_DELAY ? MAX_DELAY : $delay;
}

sub _schedule {
	my ( $master, $delay ) = @_;

	Slim::Utils::Timers::killTimers( $master, \&_poll );
	Slim::Utils::Timers::setTimer( $master, Time::HiRes::time() + $delay, \&_poll );

	main::DEBUGLOG && $log->is_debug && $log->debug( sprintf( 'Live metadata: next poll for %s in %d s', $master->id, $delay ) );
	return;
}

sub _stop {
	my ( $master, $reason ) = @_;

	Slim::Utils::Timers::killTimers( $master, \&_poll );
	delete $polls{ $master->id };

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Live metadata: stop polling for ' . $master->id . ": $reason" );
	return;
}

sub _changed {
	my ( $old, $new ) = @_;
	return 1 unless $old;

	for my $key (qw(title artist album cover)) {
		my ( $x, $y ) = ( $old->{$key}, $new->{$key} );
		return 1 if defined $x != defined $y || ( defined $x && $x ne $y );
	}

	return 0;
}

sub _push {
	my ( $master, $url, $meta ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug( sprintf( "Live metadata: push '%s' to %s", $meta->{title}, $master->id ) );

	_setTitle( $url, $meta->{title} );

	if ( my $song = $master->playingSong ) {
		$song->pluginData( wmaMeta => { map { $_ => $meta->{$_} } grep { defined $meta->{$_} } qw(title artist album cover) } );
	}

	$master->currentPlaylistUpdateTime( Time::HiRes::time() );
	Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

	return;
}

# Set a live stream's current title (without a client; LMS ignores an unchanged title).
sub _setTitle {
	my ( $url, $title ) = @_;

	local $settingTitle = 1;
	Slim::Music::Info::setCurrentTitle( $url, $title );

	return;
}

# Slim::Music::Info current-title change callback, called as ($url, $title) just before LMS
# stores $title as $url's current title. Its arguments alias setCurrentTitle's own variables,
# so assigning to $_[1] changes the title LMS stores: for a live URL, ours replaces any other
# (in practice the blank icy-name header). Never dies: it runs inside LMS's stream handling.
sub _titleChanged {
	return if $settingTitle;

	eval {
		my $stream = streamOf( $_[0] ) or return 1;

		my $ours = eval { _meta($stream)->{title} };
		if ( !defined $ours ) {
			_error( 'Live metadata title lookup failed', $@ );
			$ours = _default($stream)->{title};
		}

		if ( !defined $_[1] || $_[1] ne $ours ) {
			main::DEBUGLOG && $log->is_debug && $log->debug( sprintf( "Live metadata: stream title '%s' for %s replaced with '%s'", defined $_[1] ? $_[1] : '', $_[0], $ours ) );
			$_[1] = $ours;
		}
		1;
	} or _error( 'Live metadata title callback failed', $@ );

	return;
}

# Log an unexpected error at ERROR the first time, at DEBUG after that (the provider runs on
# every status request).
sub _error {
	my ( $what, $error ) = @_;

	$error = 'unknown error' unless defined $error && length $error;
	$error =~ s/\s+\z//;
	my $message = "$what: $error";

	if ( $errorsSeen{$message}++ ) {
		main::DEBUGLOG && $log->is_debug && $log->debug($message);
	}
	else {
		$log->error($message);
	}

	return;
}

sub _isClass { defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__ }

1;
