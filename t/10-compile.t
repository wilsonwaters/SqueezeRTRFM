#!/usr/bin/perl
# Every plugin module (RTRFM/**/*.pm) compiles and loads against the t/lib Slim:: stubs, and
# stubs whose behaviour matters match LMS (Slim::Player::Playlist::url).

use strict;
use warnings;

use RTRFMTest;
use Test::More;

use File::Find;

use Slim::Player::Playlist;

my @modules;
find( { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm$/ } }, 'RTRFM' );
@modules = sort @modules;

ok( scalar @modules >= 6, 'found the plugin modules' ) or diag "modules: @modules";

for my $expected (qw(Plugin Live OnDemand ProtocolHandler HTTP Util)) {
	ok( ( grep { $_ eq "RTRFM/$expected.pm" } @modules ), "RTRFM/$expected.pm exists" );
}

for my $file (@modules) {
	# RTRFM/Foo.pm is loaded as Plugins/RTRFM/Foo.pm through the t/lib/Plugins/RTRFM symlink
	( my $incPath = $file ) =~ s{^RTRFM/}{Plugins/RTRFM/};
	( my $package = $incPath ) =~ s{/}{::}g;
	$package =~ s/\.pm$//;

	my $warnings = '';
	local $SIG{__WARN__} = sub { $warnings .= join '', @_ };

	ok( eval { require $incPath; 1 }, "$package compiles and loads" ) or diag $@;
	is( $warnings, '', "$package loads without warnings" );
}

isa_ok( 'Plugins::RTRFM::Plugin',          'Slim::Plugin::OPMLBased' );
isa_ok( 'Plugins::RTRFM::ProtocolHandler', 'Slim::Player::Protocols::HTTPS' );

subtest 'Slim::Player::Playlist stub: url() returns $track->url for track objects, like LMS' => sub {
	Slim::Player::Playlist->reset;

	my $track = bless { url => 'rtrfm://episode/saturdayjazz/2026-09-19' }, 'RTRFMTest::FakeTrack';
	$Slim::Player::Playlist::PLAYLISTS{''} = [ 'https://example.test/a', $track ];

	is( Slim::Player::Playlist::url( undef, 0 ), 'https://example.test/a', 'URL string entry: the string' );
	is( Slim::Player::Playlist::url( undef, 1 ), 'rtrfm://episode/saturdayjazz/2026-09-19', 'track object entry: its url' );
	is( Slim::Player::Playlist::track( undef, 1 ), $track, 'track() returns the object itself' );

	$Slim::Player::Playlist::INDEX{''} = 1;
	is( Slim::Player::Playlist::url(undef), 'rtrfm://episode/saturdayjazz/2026-09-19', 'default index: the playing song' );

	Slim::Player::Playlist->reset;
	is( Slim::Player::Playlist::url(undef), undef, 'empty playlist: undef' );
};

done_testing();

package RTRFMTest::FakeTrack;

sub url { $_[0]->{url} }
