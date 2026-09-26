#!/usr/bin/perl
# README.md and RELEASING.md cover what users and the release manager need: install from the
# repository URL, the disclaimer, and the release procedure with its rules.

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

my $REPO_URL = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/repo.xml';

subtest 'README.md' => sub {
	my $readme   = slurp('README.md');
	my @headings = $readme =~ /^## (.+)$/mg;
	is_deeply( \@headings, [ 'About', 'Disclaimer', 'Requirements', 'Installation', 'Updating', 'Uninstalling', 'Manual installation', 'Development', 'License' ], 'sections in order' );

	my %section;
	$section{$1} = $2 while $readme =~ /^## (.+?)\n(.*?)(?=^## |\z)/msg;

	like( $section{About}, qr/in development/, 'About: says what is still in development' );

	like( $section{Disclaimer}, qr/unofficial/,                 'Disclaimer: "unofficial"' );
	like( $section{Disclaimer}, qr/not affiliated with RTRFM/,  'Disclaimer: "not affiliated with RTRFM"' );
	like( $section{Disclaimer}, qr/name and logo belong to/,    'Disclaimer: name and logo belong to the station' );
	like( $section{Disclaimer}, qr{<https://rtrfm\.com\.au/>},  'Disclaimer: links rtrfm.com.au' );

	like( $section{Requirements}, qr/8\.0 or later/, 'Requirements: LMS 8.0 or later' );
	like( $section{Requirements}, qr/9\.1\.x/,       'Requirements: tested on 9.1.x' );

	my $install = $section{Installation};
	like( $install, qr/^\s+\Q$REPO_URL\E$/m,               'Installation: the exact repository URL, on its own line' );
	like( $install, qr/Settings → Manage Plugins/,        'Installation: Settings → Manage Plugins' );
	like( $install, qr/Additional Repositories/,          'Installation: Additional Repositories' );
	like( $install, qr/SqueezeRTRFM plugin repository/,   'Installation: repository section name' );
	like( $install, qr/Tick\s+\*\*RTRFM 92\.1\*\*/,       'Installation: tick RTRFM 92.1' );
	like( $install, qr/[Rr]estart LMS/,                   'Installation: restart' );
	like( $install, qr/Radio → RTRFM 92\.1/,              'Installation: where to find it' );

	like( $section{Updating},     qr/update notice/,             'Updating: update notice' );
	like( $section{Updating},     qr/automatic plugin updates/,  'Updating: automatic updates' );
	like( $section{Uninstalling}, qr/untick/,                    'Uninstalling: untick' );
	like( $section{Uninstalling}, qr/[Rr]estart LMS/,            'Uninstalling: restart' );
	like( $section{Uninstalling}, qr/repository URL/,            'Uninstalling: optionally remove the repository URL' );

	my $manual = $section{'Manual installation'};
	like( $manual, qr{RTRFM-<version>\.zip},                          'Manual: the release zip' );
	like( $manual, qr{github\.com/wilsonwaters/SqueezeRTRFM/releases}, 'Manual: Releases link' );
	like( $manual, qr{named `RTRFM`},                                 'Manual: folder named RTRFM' );
	like( $manual, qr{/usr/share/squeezeboxserver/Plugins/},          'Manual: Debian path' );
	like( $manual, qr{/config/cache/Plugins/},                        'Manual: Docker path' );

	like( $section{Development}, qr{scripts/check\.sh},     'Development: check.sh' );
	like( $section{Development}, qr{scripts/build\.sh},     'Development: build.sh' );
	like( $section{Development}, qr{\(RELEASING\.md\)},     'Development: links RELEASING.md' );
	like( $section{License},     qr/Apache License 2\.0/,   'License: Apache-2.0' );
};

subtest 'RELEASING.md' => sub {
	my $doc = slurp('RELEASING.md');

	like( $doc, qr{<version>.*RTRFM/install\.xml}s,                     'release by bumping <version> in install.xml' );
	like( $doc, qr/Actions → Release → Run workflow/,                   'release from the Actions UI' );
	like( $doc, qr{POST /repos/wilsonwaters/SqueezeRTRFM/actions/workflows/release\.yml/dispatches\n\s*\{"ref":"main"\}}, 'REST dispatch call' );
	like( $doc, qr/## What the workflow does\n(?:.*\n)*?1\. .*\n(?:.*\n)*?7\. /,  'workflow steps 1 to 7' );
	like( $doc, qr/## Dry runs/,                                        'dry runs' );
	like( $doc, qr/nothing to do/,                                      'no-op run' );
	like( $doc, qr/repair/,                                             'repair path' );
	like( $doc, qr/sha1sum/,                                            'verify: sha1sum of the downloaded asset' );
	like( $doc, qr/Settings → Actions → General → Workflow permissions →\s+Read and write/, '403: workflow permissions' );
	like( $doc, qr/[Bb]ranch protection.*github-actions\[bot\]/s,       'branch protection' );
	like( $doc, qr/[Nn]on-fast-forward push.*[Rr]etried automatically/s, 'non-fast-forward retried' );
	like( $doc, qr/Never reuse a version number/,                       'rule: never reuse a version' );
	like( $doc, qr/Never hand-edit `sha`/,                              'rule: never hand-edit sha' );
	like( $doc, qr/Never replace an uploaded asset/,                    'rule: never replace an asset' );
	like( $doc, qr/Feature pull requests never touch `<version>`/,      'rule: feature PRs never touch <version>' );
	like( $doc, qr/tags\s+can't be pushed from the development container/, 'why the workflow creates tags' );
};

done_testing();
