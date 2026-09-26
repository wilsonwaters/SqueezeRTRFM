#!/usr/bin/perl
# Plugin manifest and resources: install.xml fields, the 512x512 icon, and strings.txt
# (per-task sections, every pre-seeded token, LMS strings format).

use strict;
use warnings;

use RTRFMTest;
use Test::More;

sub slurp {
	my ( $file, $layer ) = @_;
	open( my $fh, '<' . ( $layer || '' ), $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

subtest 'install.xml' => sub {
	my $xml = slurp('RTRFM/install.xml');

	my %field;
	( my $top = $xml ) =~ s{<targetApplication>.*?</targetApplication>}{}s;
	$field{$1} = $2 while $top =~ m{<(\w+)>([^<]*)</\1>}g;
	my ($target) = $xml =~ m{<targetApplication>(.*?)</targetApplication>}s;

	like( $field{id}, qr/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i, 'stable UUID id' );
	is( $field{module},       'Plugins::RTRFM::Plugin',                        'module' );
	is( $field{name},         'PLUGIN_RTRFM',                                  'name is a string token' );
	is( $field{description},  'PLUGIN_RTRFM_DESC',                             'description is a string token' );
	like( $field{version}, qr/\A[0-9]+\.[0-9]+\.[0-9]+\z/, 'version is X.Y.Z (bumped only by release commits)' );
	is( $field{category},     'radio',                                         'category radio' );
	is( $field{defaultState}, 'enabled',                                       'enabled by default' );
	is( $field{icon},         'plugins/RTRFM/html/images/icon.png',            'icon path' );
	is( $field{homepageURL},  'https://github.com/wilsonwaters/SqueezeRTRFM',  'homepage URL' );
	is( $field{creator},      'Wilson Waters',                                 'creator' );
	ok( !exists $field{settingsPage} && !exists $field{optionsURL}, 'no settings page keys' );

	ok( defined $target, 'has targetApplication' );
	like( $target, qr{<minVersion>8\.0</minVersion>}, 'minVersion 8.0' );
	like( $target, qr{<maxVersion>\*</maxVersion>},   'maxVersion *' );

	ok( -f "RTRFM/HTML/EN/$field{icon}", 'icon path resolves to a file under HTML/EN' );
};

subtest 'icon' => sub {
	my $file = 'RTRFM/HTML/EN/plugins/RTRFM/html/images/icon.png';
	ok( -f $file, 'icon exists' ) or return;

	my $png = slurp( $file, ':raw' );
	is( substr( $png, 0, 8 ), "\x89PNG\r\n\x1a\n", 'PNG signature' );
	is( substr( $png, 12, 4 ), 'IHDR', 'IHDR chunk first' );
	my ( $width, $height ) = unpack( 'NN', substr( $png, 16, 8 ) );
	is( $width,  512, 'width 512' );
	is( $height, 512, 'height 512' );
};

subtest 'strings.txt' => sub {
	my @lines = split /\n/, slurp( 'RTRFM/strings.txt', ':encoding(UTF-8)' );

	# parse sections, tokens and EN texts
	my ( @sections, %sectionOf, %text, $section, $token );
	for my $line (@lines) {
		if ( $line =~ /^# === (\w+) ===/ ) {
			$section = $1;
			push @sections, $section;
		}
		elsif ( $line =~ /^([A-Z0-9_]+)$/ ) {
			$token = $1;
			$sectionOf{$token} = $section;
		}
		elsif ( $line =~ /^\tEN\t(.+)$/ && $token ) {
			$text{$token} = $1;
		}
	}

	is_deeply( \@sections, [qw(F1 L1 L2 O1 O2 O3 O4 O5 O6)], 'per-task sections F1, L1, L2, O1..O6 in order' );

	my %expected = (
		F1 => [qw(PLUGIN_RTRFM PLUGIN_RTRFM_DESC PLUGIN_RTRFM_ERROR)],
		L1 => [qw(PLUGIN_RTRFM_LIVE PLUGIN_RTRFM_INFINITE_MIX PLUGIN_RTRFM_INFINITE_MIX_DESC PLUGIN_RTRFM_ON_AIR PLUGIN_RTRFM_NEXT)],
		L2 => [qw(PLUGIN_RTRFM_SHOW_INFO)],
		O1 => [qw(PLUGIN_RTRFM_EPISODE_UNAVAILABLE PLUGIN_RTRFM_RESOLVE_FAILED)],
		O2 => [qw(PLUGIN_RTRFM_PROGRAMS PLUGIN_RTRFM_NO_EPISODES)],
		O3 => [qw(PLUGIN_RTRFM_PLAY_EPISODE PLUGIN_RTRFM_TRACKLIST PLUGIN_RTRFM_NO_TRACKLIST)],
		O5 => [qw(PLUGIN_RTRFM_HOSTED_BY)],
		O6 => [qw(PLUGIN_RTRFM_TRACKLIST_PENDING PLUGIN_RTRFM_AVAILABILITY_UNKNOWN)],
	);

	for my $sec ( sort keys %expected ) {
		for my $tok ( @{ $expected{$sec} } ) {
			ok( defined $text{$tok} && length $text{$tok}, "$tok has English text" );
			is( $sectionOf{$tok}, $sec, "$tok is in section $sec" );
		}
	}

	is( $text{PLUGIN_RTRFM},      'RTRFM 92.1',      'plugin name text' );
	is( $text{PLUGIN_RTRFM_LIVE}, 'RTRFM 92.1 Live', 'live item text' );

	my $output = qx{"$^X" scripts/lint-strings.pl 2>&1};
	is( $? >> 8, 0, 'scripts/lint-strings.pl passes (LMS format, every referenced token defined)' ) or diag $output;
};

done_testing();
