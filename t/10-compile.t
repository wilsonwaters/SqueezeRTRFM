#!/usr/bin/perl
# Every plugin module (RTRFM/**/*.pm) compiles and loads against the t/lib Slim:: stubs.

use strict;
use warnings;

use RTRFMTest;
use Test::More;

use File::Find;

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

done_testing();
