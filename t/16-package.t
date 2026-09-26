#!/usr/bin/perl
# scripts/build.sh and scripts/check-package.sh: the real build has the layout LMS expects and
# passes the package checks; bad manifests stop the build; each crafted bad zip fails the
# matching check. Needs zip and unzip (CI installs them).

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

for my $tool (qw(zip unzip sha1sum)) {
	next if grep { -x "$_/$tool" } split /:/, $ENV{PATH};
	# CI must run these tests; locally they are skipped with a notice
	BAIL_OUT("$tool is not installed") if $ENV{CI};
	plan skip_all => "$tool is not installed";
}

my $ROOT = getcwd();

sub slurp {
	my $file = shift;
	open( my $fh, '<:raw', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub spew {
	my ( $file, $content ) = @_;
	open( my $fh, '>:raw', $file ) or die "Can't write $file: $!";
	print {$fh} $content;
	close $fh;
	return $file;
}

# run a command (optionally in another directory); returns (exit code, stdout+stderr)
sub run {
	my ( $cmd, %opts ) = @_;
	my $pid = open( my $fh, '-|' ) // die "fork: $!";
	if ( !$pid ) {
		open( STDERR, '>&', \*STDOUT ) or die;
		chdir $opts{cwd} or die "chdir $opts{cwd}: $!" if $opts{cwd};
		exec(@$cmd) or die "exec $cmd->[0]: $!";
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return ( $? >> 8, $out );
}

sub copyTree {
	my ( $from, $to ) = @_;
	my ( $rc, $out ) = run( [ 'cp', '-R', $from, $to ] );
	die "cp failed: $out" if $rc;
	return $to;
}

sub zipDir {
	my ( $dir, $zip ) = @_;
	my ( $rc, $out ) = run( [ 'zip', '-q', '-r', $zip, '.' ], cwd => $dir );
	die "zip failed: $out" if $rc;
	return $zip;
}

sub sha1File {
	my ( $zip, $sha ) = @_;
	my ($name) = $zip =~ m{([^/]+)\z};
	spew( "$zip.sha1", "$sha  $name\n" );
	return;
}

sub checkPackage { return run( [ "$ROOT/scripts/check-package.sh", '--zip', shift ] ) }

sub failLines { return grep { /^FAIL / } split /\n/, shift }

my $tmp = tempdir( CLEANUP => 1 );
my ($version) = slurp('RTRFM/install.xml') =~ m{<version>([^<]*)</version>};
my $name = "RTRFM-$version.zip";

subtest 'real build' => sub {
	my $out = "$tmp/dist";
	my ( $rc, $stdout ) = run( [ 'scripts/build.sh', '--out', $out ] );
	is( $rc, 0, 'build.sh exits 0' ) or diag $stdout;
	like( $stdout, qr{^zip=\Q$out/$name\E$}m, 'prints the zip path' );
	like( $stdout, qr{^sha1=[0-9a-f]{40}$}m,  'prints the sha1' );

	ok( -f "$out/$name",      "$name written" );
	ok( -f "$out/$name.sha1", "$name.sha1 written" );

	my ( undef, $list ) = run( [ 'unzip', '-Z1', "$out/$name" ] );
	my @entries = split /\n/, $list;
	ok( ( grep { $_ eq 'install.xml' } @entries ), 'install.xml at the zip root' );
	ok( ( grep { $_ eq 'Plugin.pm' } @entries ),   'Plugin.pm at the zip root' );
	ok( ( grep { $_ eq 'strings.txt' } @entries ), 'strings.txt at the zip root' );
	ok( ( grep { $_ eq 'HTML/EN/plugins/RTRFM/html/images/icon.png' } @entries ), 'icon under HTML/' );
	is( ( grep { m{^RTRFM/} } @entries ), 0, 'no RTRFM/ prefix' );

	my ($sha) = $stdout =~ /^sha1=(\S+)/m;
	is( slurp("$out/$name.sha1"), "$sha  $name\n", '.sha1 is in sha1sum format: <hex><two spaces><file name>' );
	my ( $crc, $check ) = run( [ 'sha1sum', '-c', "$name.sha1" ], cwd => $out );
	is( $crc, 0, 'sha1sum -c passes' ) or diag $check;
	like( $check, qr/^\Q$name\E: OK$/m, 'sha1sum -c prints OK' );

	# a second build replaces the zip instead of adding to it
	( $rc, $stdout ) = run( [ 'scripts/build.sh', '--out', $out ] );
	is( $rc, 0, 'second build exits 0' );
	opendir( my $dh, $out ) or die;
	my @files = sort grep { !/^\./ } readdir $dh;
	closedir $dh;
	is_deeply( \@files, [ $name, "$name.sha1" ], 'after two builds the output holds exactly one zip and its .sha1' );

	( $rc, my $report ) = checkPackage("$out/$name");
	is( $rc, 0, 'check-package.sh --zip passes on the real build' ) or diag $report;

	( $rc, $report ) = run( ['scripts/check-package.sh'] );
	is( $rc, 0, 'check-package.sh (builds its own zip) passes' ) or diag $report;
	unlike( $report, qr/^FAIL/m, 'no failed package checks' );

	SKIP: {
		my ( $grc, $inside ) = run( [ 'git', 'rev-parse', '--is-inside-work-tree' ] );
		skip 'not a git work tree', 1 if $grc || $inside !~ /true/;
		my ($irc) = run( [ 'git', 'check-ignore', '-q', "dist/$name" ] );
		is( $irc, 0, 'dist/ is git-ignored' );
	}
};

subtest 'build.sh rejects a missing or malformed install.xml' => sub {
	my $src = "$tmp/src-missing";
	make_path($src);
	spew( "$src/Plugin.pm", "1;\n" );
	my ( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $src, '--out', "$tmp/out-missing" ] );
	isnt( $rc, 0, 'missing install.xml: non-zero exit' );
	like( $out, qr{\Q$src\E/install\.xml not found}, 'missing install.xml: clear message' );
	ok( !-e "$tmp/out-missing/$name", 'missing install.xml: no zip written' );

	my $manifest = slurp('RTRFM/install.xml');
	my %bad      = (
		'1.0'        => '1.0',
		'v1.0.0'     => 'v1.0.0',
		'1.0.0-beta' => '1.0.0-beta',
		'" 1.0.0 "'  => ' 1.0.0 ',
		'empty'      => '',
	);
	for my $label ( sort keys %bad ) {
		my $dir = "$tmp/src-bad-" . ( $label =~ s/\W/_/gr );
		make_path($dir);
		spew( "$dir/install.xml", $manifest =~ s{<version>[^<]*</version>}{<version>$bad{$label}</version>}r );
		spew( "$dir/Plugin.pm", "1;\n" );
		( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $dir, '--out', "$dir/out" ] );
		isnt( $rc, 0, "version $label: non-zero exit" );
		like( $out, $bad{$label} eq '' ? qr/no <version> element|not of the form X\.Y\.Z/ : qr/not of the form X\.Y\.Z/, "version $label: clear message" );
	}

	my $dir = "$tmp/src-noversion";
	make_path($dir);
	spew( "$dir/install.xml", $manifest =~ s{\s*<version>[^<]*</version>}{}r );
	( $rc, $out ) = run( [ 'scripts/build.sh', '--src', $dir, '--out', "$dir/out" ] );
	isnt( $rc, 0, 'no <version> element: non-zero exit' );
	like( $out, qr/no <version> element/, 'no <version> element: clear message' );
};

subtest 'check-package.sh fails each crafted bad zip on the matching rule' => sub {
	my $good = copyTree( "$ROOT/RTRFM", "$tmp/good" );

	# plugin files under an RTRFM/ folder
	my $nested = "$tmp/nested";
	make_path($nested);
	copyTree( $good, "$nested/RTRFM" );
	my $zip = zipDir( $nested, "$tmp/prefix-$name" );
	my ( $rc, $out ) = checkPackage($zip);
	isnt( $rc, 0, 'RTRFM/ prefix: non-zero exit' );
	like( $out, qr{^FAIL entries with a forbidden prefix}m, 'RTRFM/ prefix: forbidden-prefix rule' );
	like( $out, qr{^\s+RTRFM/install\.xml$}m, 'RTRFM/ prefix: offending entry listed' );
	like( $out, qr{^FAIL install\.xml is not at the zip root}m, 'RTRFM/ prefix: install.xml not at root' );

	my %cases = (
		'contains t/' => {
			setup => sub { make_path("$_[0]/t"); spew( "$_[0]/t/10-compile.t", "1;\n" ) },
			rule  => qr{^FAIL entries with a forbidden prefix}m,
		},
		'contains .DS_Store' => {
			setup => sub { spew( "$_[0]/HTML/.DS_Store", "junk" ) },
			rule  => qr{^FAIL \.DS_Store or __MACOSX entries}m,
		},
		'contains __MACOSX' => {
			setup => sub { make_path("$_[0]/__MACOSX"); spew( "$_[0]/__MACOSX/._install.xml", "junk" ) },
			rule  => qr{^FAIL \.DS_Store or __MACOSX entries}m,
		},
		'wrong .sha1' => {
			sha1 => '0' x 40,
			rule => qr{^FAIL \Q$name\E\.sha1 does not match}m,
		},
		'version mismatch' => {
			zipname => 'RTRFM-9.9.9.zip',
			rule    => qr{^FAIL version mismatch: file name says 9\.9\.9, install\.xml in the zip says '\Q$version\E'}m,
		},
	);

	for my $label ( sort keys %cases ) {
		my $case = $cases{$label};
		my $dir  = copyTree( $good, "$tmp/case-" . ( $label =~ s/\W/_/gr ) );
		$case->{setup}->($dir) if $case->{setup};
		my $outDir = "$dir-zip";
		make_path($outDir);
		my $zip = zipDir( $dir, "$outDir/" . ( $case->{zipname} || $name ) );
		my ( undef, $sum ) = run( [ 'sha1sum', $zip ] );
		sha1File( $zip, $case->{sha1} || ( split ' ', $sum )[0] );

		my ( $rc, $out ) = checkPackage($zip);
		isnt( $rc, 0, "$label: non-zero exit" );
		like( $out, $case->{rule}, "$label: fails the matching rule" );
		is( scalar( () = failLines($out) ), 1, "$label: no other rule fails" ) or diag $out;
	}

	# the unmodified copy passes, so the failures above come from the crafted defects
	my $outDir = "$tmp/good-zip";
	make_path($outDir);
	$zip = zipDir( $good, "$outDir/$name" );
	my ( undef, $sum ) = run( [ 'sha1sum', $zip ] );
	sha1File( $zip, ( split ' ', $sum )[0] );
	( $rc, $out ) = checkPackage($zip);
	is( $rc, 0, 'control: the same files zipped correctly pass' ) or diag $out;
};

done_testing();
