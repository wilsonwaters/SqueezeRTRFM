#!/usr/bin/perl
# scripts/smoke.sh command line and failure paths, against a small fake LMS JSON-RPC server
# (no real LMS, no network): --help, missing tools, bad or unreachable LMS_URL, unknown or
# ambiguous player (exit 2, players listed), password-protected server, and a server without
# the plugin (exit 1, checks 3-9 fail, the player is left alone). The full pass needs a real
# LMS and player: see the README's Self-test section. Needs curl and jq (CI installs them).

use strict;
use warnings;

use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Test::More;
use Time::HiRes qw(time);

for my $tool (qw(bash curl jq)) {
	next if grep { -x "$_/$tool" } split /:/, $ENV{PATH};
	BAIL_OUT("$tool is not installed") if $ENV{CI};
	plan skip_all => "$tool is not installed";
}

# requests to the fake server must not go through a proxy
delete @ENV{qw(http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY LMS_URL PLAYER LMS_USER LMS_PASS)};

my $DIR    = tempdir( CLEANUP => 1 );
my $SCRIPT = 'scripts/smoke.sh';
my $JSON   = JSON::PP->new->canonical;

my $DEV   = { playerid => '00:00:00:00:00:01', name => 'DevPlayer',  connected => 1, power => 1 };
my $OTHER = { playerid => 'aa:bb:cc:dd:ee:ff', name => 'Kitchen',    connected => 1, power => 0 };
my $GONE  = { playerid => '00:04:20:00:00:02', name => 'Old Boom',   connected => 0, power => 0 };

# run smoke.sh with @args (and %env); returns { code, out, err, secs }
sub smoke {
	my ( $args, %opt ) = @_;
	my $start = time;
	my $pid   = open( my $fh, '-|' ) // die "fork: $!";
	if ( !$pid ) {
		open( STDERR, '>', "$DIR/stderr" ) or die;
		$ENV{$_} = $opt{env}->{$_} for keys %{ $opt{env} || {} };
		exec( $opt{bash} || 'bash', $SCRIPT, @$args ) or die "exec: $!";
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	my $code = $? >> 8;
	open( my $efh, '<', "$DIR/stderr" ) or die;
	my $err = do { local $/; <$efh> } // '';
	close $efh;
	return { code => $code, out => $out, err => $err, secs => time - $start };
}

# A fake LMS: answers serverstatus, players, pref and radios; any other command (such as
# "rtrfm items" without the plugin) gets no answer, like LMS. Returns (url, stop, commands).
sub fake_lms {
	my %opt = @_;
	my $server = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 16, ReuseAddr => 1 ) or die "listen: $!";
	my $port = $server->sockport;
	my $log  = "$DIR/commands-$port.log";

	my $pid = fork // die "fork: $!";
	if ( !$pid ) {
		while ( my $c = $server->accept ) {
			my ( %h, $line );
			my $request = <$c>;
			while ( defined( $line = <$c> ) && $line =~ /\S/ ) {
				$h{ lc $1 } = $2 if $line =~ /^([^:]+):\s*(.*?)\r?$/;
			}
			my $body = '';
			read( $c, $body, $h{'content-length'} || 0 );

			if ( $opt{auth} && ( $h{authorization} || '' ) ne 'Basic ' . encode_base64( $opt{auth}, '' ) ) {
				print $c "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"LMS\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
				close $c;
				next;
			}

			my $req = eval { $JSON->decode($body) } || {};
			my ( $player, $cmd ) = @{ $req->{params} || [] };
			open( my $lfh, '>>', $log ) or die;
			print $lfh $JSON->encode( [ $player, $cmd ] ), "\n";
			close $lfh;

			my $name = ref $cmd eq 'ARRAY' ? $cmd->[0] : '';
			my $result =
				  $name eq 'serverstatus' ? { version => '9.1.1', 'player count' => scalar @{ $opt{players} } }
				: $name eq 'players'      ? { count => scalar @{ $opt{players} }, players_loop => $opt{players} }
				: $name eq 'pref'         ? { _p2 => $opt{state} }
				: $name eq 'radios'       ? { count => scalar @{ $opt{radios} || [] }, radioss_loop => $opt{radios} || [] }
				:                           undef;

			if ($result) {
				my $json = $JSON->encode( { id => 1, method => 'slim.request', params => $req->{params}, result => $result } );
				print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . length($json) . "\r\nConnection: close\r\n\r\n$json";
			}
			close $c;
		}
		exit 0;
	}
	close $server;

	my $stop = sub { kill 'TERM', $pid; waitpid( $pid, 0 ) };
	my $commands = sub {
		open( my $fh, '<', $log ) or return ();
		my @c = map { $JSON->decode($_) } <$fh>;
		close $fh;
		return @c;
	};
	return ( "http://127.0.0.1:$port", $stop, $commands );
}

subtest '--help prints the usage and exits 0' => sub {
	for my $flag ( '--help', '-h' ) {
		my $r = smoke( [$flag] );
		is( $r->{code}, 0, "$flag: exit 0" );
		like( $r->{out}, qr/^Usage: scripts\/smoke\.sh \[-h\|--help\] \[LMS_URL\] \[PLAYER_MAC\]$/m, "$flag: usage line" );
		like( $r->{out}, qr/WARNING: the test plays audio on the chosen player/,                  "$flag: warns that it plays audio" );
		like( $r->{out}, qr/LMS_USER and LMS_PASS/,                                                "$flag: mentions basic auth" );
	}
};

subtest 'missing tools: exit 2, says which' => sub {
	my $bin = "$DIR/bin";
	mkdir $bin;
	for my $tool (qw(bash sed head mktemp rm sleep)) {
		my ($path) = grep { -x "$_/$tool" } split /:/, $ENV{PATH};
		symlink( "$path/$tool", "$bin/$tool" ) if $path;
	}

	my $r = smoke( [ 'http://127.0.0.1:9', '00:00:00:00:00:01' ], bash => "$bin/bash", env => { PATH => $bin } );
	is( $r->{code}, 2, 'curl and jq missing: exit 2' );
	like( $r->{err}, qr/missing: curl jq/, 'curl and jq missing: both named' );

	my ($curl) = grep { -x "$_/curl" } split /:/, $ENV{PATH};
	symlink( "$curl/curl", "$bin/curl" );
	$r = smoke( [ 'http://127.0.0.1:9', '00:00:00:00:00:01' ], bash => "$bin/bash", env => { PATH => $bin } );
	is( $r->{code}, 2, 'jq absent from PATH: exit 2' );
	like( $r->{err}, qr/missing: jq \(needs bash 4\+, curl and jq\)/, 'jq absent from PATH: says jq' );
	is( $r->{out}, '', 'jq absent from PATH: no check was run' );
};

subtest 'bad arguments: exit 2' => sub {
	my $r = smoke( ['localhost:9000'] );
	is( $r->{code}, 2, 'LMS_URL without http(s)://' );
	like( $r->{err}, qr/LMS_URL must look like http:\/\/host:9000/, 'says what LMS_URL should look like' );

	$r = smoke( [qw(http://127.0.0.1:9000 00:00:00:00:00:01 extra)] );
	is( $r->{code}, 2, 'too many arguments' );
};

subtest 'unreachable LMS: exit 2 within 20 s' => sub {
	# a port nobody listens on
	my $s = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1 ) or die;
	my $port = $s->sockport;
	close $s;

	my $r = smoke( [ "http://127.0.0.1:$port", '00:00:00:00:00:01' ] );
	is( $r->{code}, 2, 'exit 2' );
	like( $r->{out}, qr/^FAIL  1\. Server reachable — no answer to \["serverstatus",0,0\] \(curl exit 7: /m, 'FAIL on check 1 with the reason' );
	unlike( $r->{out}, qr/^(?:PASS|FAIL)  2\./m, 'no further checks' );
	like( $r->{err}, qr/can't talk to LMS at http:\/\/127\.0\.0\.1:$port/, 'says it cannot reach LMS' );
	ok( $r->{secs} < 20, sprintf( 'within 20 s (%.1f s)', $r->{secs} ) );

	$r = smoke( [], env => { LMS_URL => "http://127.0.0.1:$port/" } );
	like( $r->{out}, qr{on http://127\.0\.0\.1:$port\n}, 'LMS_URL from the environment, trailing slash dropped' );
};

subtest 'unknown player: exit 2, players listed' => sub {
	my ( $url, $stop, $commands ) = fake_lms( players => [ $DEV, $GONE ] );

	my $r = smoke( [ $url, '00:00:00:00:00:99' ] );
	is( $r->{code}, 2, 'exit 2' );
	like( $r->{out}, qr/^PASS  1\. Server reachable — LMS 9\.1\.1 at \Q$url\E$/m,              'check 1 passes' );
	like( $r->{out}, qr/^FAIL  2\. Player connected — 00:00:00:00:00:99 is not a connected player$/m, 'check 2 fails' );
	like( $r->{err}, qr/^  00:00:00:00:00:01  DevPlayer  connected=1$/m, 'lists the connected player' );
	like( $r->{err}, qr/^  00:04:20:00:00:02  Old Boom  connected=0$/m, 'and the disconnected one' );

	$r = smoke( [ $url, '00:04:20:00:00:02' ] );
	is( $r->{code}, 2, 'a known but disconnected player: exit 2' );

	$r = smoke( [ $url, '00:00:00:00:00:99' ], env => { PLAYER => '00:00:00:00:00:01' } );
	is( $r->{code}, 2, 'the argument wins over $PLAYER' );

	my @touching = grep { ref $_->[1] eq 'ARRAY' && $_->[1][0] =~ /^(?:power|playlist|stop|time|rtrfm)$/ } $commands->();
	is( scalar @touching, 0, 'the player was not touched' );
	$stop->();
};

subtest 'no player given: the only connected one, else exit 2' => sub {
	my ( $url, $stop ) = fake_lms( players => [ $DEV, $OTHER ], state => 'enabled' );
	my $r = smoke( [$url] );
	is( $r->{code}, 2, 'two connected players, none given: exit 2' );
	like( $r->{out}, qr/^FAIL  2\. Player connected — 2 players connected and none chosen$/m, 'check 2 says why' );
	like( $r->{err}, qr/00:00:00:00:00:01  DevPlayer.*aa:bb:cc:dd:ee:ff  Kitchen/s, 'lists both' );
	$stop->();

	( $url, $stop ) = fake_lms( players => [ $GONE, $DEV ], state => 'enabled' );
	$r = smoke( [$url] );
	like( $r->{out}, qr/^PASS  2\. Player connected — DevPlayer \(00:00:00:00:00:01\)$/m, 'one connected player: used' );
	$r = smoke( [ $url, '00:00:00:00:00:01' ] );
	like( $r->{out}, qr/^PASS  2\. Player connected — DevPlayer/m, 'given as an argument' );
	$r = smoke( [$url], env => { PLAYER => '00:00:00:00:00:01' } );
	like( $r->{out}, qr/^PASS  2\. Player connected — DevPlayer/m, 'given as $PLAYER' );
	$stop->();

	( $url, $stop ) = fake_lms( players => [ $GONE ] );
	$r = smoke( [$url] );
	is( $r->{code}, 2, 'no connected player: exit 2' );
	like( $r->{out}, qr/^FAIL  2\. Player connected — 0 players connected and none chosen$/m, 'says none is connected' );
	$stop->();
};

subtest 'player MACs are not case sensitive' => sub {
	my ( $url, $stop ) = fake_lms( players => [ { %$OTHER, power => 1 } ] );
	my $r = smoke( [ $url, 'AA:BB:CC:DD:EE:FF' ] );
	like( $r->{out}, qr/^PASS  2\. Player connected — Kitchen \(aa:bb:cc:dd:ee:ff\)$/m, 'upper-case MAC accepted' );
	$stop->();
};

subtest 'password-protected server: LMS_USER / LMS_PASS' => sub {
	my ( $url, $stop ) = fake_lms( players => [$DEV], auth => 'admin:s3cret' );

	my $r = smoke( [ $url, '00:00:00:00:00:01' ] );
	is( $r->{code}, 2, 'no credentials: exit 2' );
	like( $r->{out}, qr/^FAIL  1\. Server reachable — \Q$url\E asks for a password: set LMS_USER and LMS_PASS$/m, 'says to set LMS_USER and LMS_PASS' );

	$r = smoke( [ $url, '00:00:00:00:00:01' ], env => { LMS_USER => 'admin', LMS_PASS => 's3cret' } );
	like( $r->{out}, qr/^PASS  1\. Server reachable/m, 'with credentials: check 1 passes' );
	like( $r->{out}, qr/^PASS  2\. Player connected/m, 'with credentials: check 2 passes' );
	$stop->();
};

subtest 'LMS without the plugin: exit 1, FAIL on checks 3-9, player left alone' => sub {
	my ( $url, $stop, $commands ) = fake_lms(
		players => [$DEV],
		state   => undef,
		radios  => [ { cmd => 'presets', name => 'My Presets', type => 'xmlbrowser' } ],
	);

	my $r = smoke( [ $url, '00:00:00:00:00:01' ] );
	is( $r->{code}, 1, 'exit 1' );
	my @lines = grep { /^(?:PASS|FAIL)  \d\. / } split /\n/, $r->{out};
	is( scalar @lines, 9, 'one line per check' );
	is_deeply( [ map { /^(PASS|FAIL)  (\d)\./ ? "$1 $2" : $_ } @lines ], [ 'PASS 1', 'PASS 2', map { "FAIL $_" } 3 .. 9 ], 'checks 1-2 pass, 3-9 fail' );
	like( $r->{out}, qr/^FAIL  3\. Plugin enabled — plugin\.state:RTRFM = unset \(install or enable RTRFM/m, 'check 3: plugin state and a hint' );
	like( $r->{out}, qr/^FAIL  4\. Radio menu lists RTRFM — no entry with cmd rtrfm/m,                        'check 4: not in the Radio menu' );
	like( $r->{out}, qr/^FAIL  5\. Top level — no answer to \["rtrfm","items",0,100\]/m,                     'check 5: no answer' );
	like( $r->{out}, qr/^FAIL  6\. Live plays — skipped: no "RTRFM 92\.1 Live" item$/m,                       'check 6 skipped' );
	like( $r->{out}, qr/^FAIL  7\. Programs non-empty — skipped: no "Programs" item$/m,                       'check 7 skipped' );
	like( $r->{out}, qr/^FAIL  8\. Episode plays and seeks — skipped: no programs$/m,                         'check 8 skipped' );
	like( $r->{out}, qr/^FAIL  9\. Track list — skipped: no programs$/m,                                      'check 9 skipped' );
	like( $r->{out}, qr/SMOKE: 2\/9 passed\n\z/, 'final line: SMOKE: 2/9 passed' );

	my @touching = grep { ref $_->[1] eq 'ARRAY' && $_->[1][0] =~ /^(?:power|playlist|stop|time)$/ } $commands->();
	is( scalar @touching, 0, 'nothing was played, so the player was not touched' );
	$stop->();
};

done_testing();
