#!/usr/bin/perl
# scripts/smoke.sh walks the plugin menus by item name. The names it matches are hard-coded in
# the script (it runs against any LMS, without the plugin source); they must equal the EN values
# in RTRFM/strings.txt.

use strict;
use utf8;
use warnings;

use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

sub slurp {
	my $file = shift;
	open( my $fh, '<:encoding(UTF-8)', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

# EN values of RTRFM/strings.txt: TOKEN lines followed by "<TAB>EN<TAB>text" lines
my %EN;
{
	my $token;
	for my $line ( split /\n/, slurp('RTRFM/strings.txt') ) {
		next if $line =~ /^\s*(?:#|$)/;
		if    ( $line =~ /^(\S+)\s*$/ )           { $token = $1 }
		elsif ( $token && $line =~ /^\tEN\t(.*)$/ ) { $EN{$token} = $1 }
	}
}
ok( scalar keys %EN > 10, 'strings.txt parsed' );

my $script = slurp('scripts/smoke.sh');

# STR_<NAME>='<text>'   # PLUGIN_RTRFM_<TOKEN>
my %names;
while ( $script =~ /^(STR_\w+)='([^']*)'\s+# (PLUGIN_RTRFM_\w+)\s*$/mg ) {
	$names{$1} = { text => $2, token => $3 };
}

my @required = qw(PLUGIN_RTRFM_LIVE PLUGIN_RTRFM_PROGRAMS PLUGIN_RTRFM_TRACKLIST PLUGIN_RTRFM_NO_TRACKLIST);
my %byToken = map { $names{$_}->{token} => $_ } keys %names;

subtest 'the names smoke.sh needs are all hard-coded' => sub {
	ok( $byToken{$_}, "$_ is hard-coded" ) for @required, qw(PLUGIN_RTRFM_INFINITE_MIX PLUGIN_RTRFM_TRACKLIST_PENDING);
	is( scalar( () = $script =~ /^STR_\w+=/mg ), scalar keys %names, 'every STR_ line names its strings.txt token' );
};

subtest 'each hard-coded name equals the EN value in strings.txt' => sub {
	for my $var ( sort keys %names ) {
		my ( $text, $token ) = @{ $names{$var} }{qw(text token)};
		ok( exists $EN{$token}, "$token exists in strings.txt" );
		is( $text, $EN{$token}, "$var equals $token" );
	}
};

subtest 'each hard-coded name is used' => sub {
	for my $var ( sort keys %names ) {
		my $uses = () = $script =~ /\$\{?\Q$var\E\b/g;
		ok( $uses >= 1, "$var is used ($uses times)" );
	}
};

subtest 'prefix matching can tell the track list apart from "not yet available"' => sub {
	# "Track list not yet available" starts with "Track list", so smoke.sh excludes it explicitly
	my ( $tracklist, $pending ) = @EN{qw(PLUGIN_RTRFM_TRACKLIST PLUGIN_RTRFM_TRACKLIST_PENDING)};
	if ( index( $pending, $tracklist ) == 0 ) {
		like( $script, qr/startswith\(\$pending\)\) \| not/, 'smoke.sh leaves out items starting with TRACKLIST_PENDING' );
	}
	else {
		pass('TRACKLIST_PENDING does not start with TRACKLIST');
	}
	isnt( index( $EN{PLUGIN_RTRFM_NO_TRACKLIST}, $tracklist ), 0, 'NO_TRACKLIST does not start with TRACKLIST' );
	isnt( index( $EN{PLUGIN_RTRFM_INFINITE_MIX}, $EN{PLUGIN_RTRFM_LIVE} ), 0, 'INFINITE_MIX does not start with LIVE' );
};

done_testing();
