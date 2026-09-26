#!/usr/bin/perl
# .github/workflows/release.yml: release notes come from CHANGELOG.md (scripts/changelog-section.sh)
# with a GitHub-generated fallback and are shown on dry runs too; the repo.xml commit is authored
# as the repository owner, keeps [skip ci], and is pushed with GITHUB_TOKEN.

use strict;
use warnings;

use Test::More;

open( my $fh, '<:encoding(UTF-8)', '.github/workflows/release.yml' ) or die "Can't open release.yml: $!";
my $yml = do { local $/; <$fh> };
close $fh;

# the steps of the release job: name => text of the step
my %step;
$step{$1} = $2 while $yml =~ /^      - name: ([^\n]+)\n(.*?)(?=^      - |\z)/msg;

subtest 'release notes from CHANGELOG.md, GitHub-generated as the fallback' => sub {
	my $notes = $step{'Release notes'};
	ok( $notes, 'a "Release notes" step' ) or return;
	unlike( $notes, qr/^\s+if:/m, 'it runs on every path, dry runs included' );
	like( $notes, qr/scripts\/changelog-section\.sh "\$V" > "\$notes"/, 'takes the CHANGELOG.md section for V' );
	like( $notes, qr/NOTES_FILE=\$notes" >> "\$GITHUB_ENV"/,             'passes the notes file on' );
	like( $notes, qr/cat "\$notes"/,                                     'prints the notes it would use' );
	like( $notes, qr/GITHUB_STEP_SUMMARY/,                               'and adds them to the run summary' );

	my $create = $step{'Create release'};
	like( $create, qr/notes=\(--generate-notes\)/,                                  'fallback: --generate-notes' );
	like( $create, qr/notes=\(--notes-file "\$NOTES_FILE"\)/,                       'CHANGELOG notes when there is a section' );
	like( $create, qr/gh release create "v\$V" "\$ZIP" .*"\$\{notes\[@\]\}"/,       'gh release create uses them' );

	my ($paths) = $yml =~ /^  pull_request:\n    paths:\n((?:      - .*\n)+)/m;
	like( $paths, qr/'CHANGELOG\.md'/,                  'pull requests changing CHANGELOG.md get a dry run' );
	like( $paths, qr/'scripts\/changelog-section\.sh'/, 'pull requests changing changelog-section.sh get a dry run' );
};

subtest 'repo.xml commit: authored as the repository owner, [skip ci], pushed with GITHUB_TOKEN' => sub {
	my $commit = $step{'Commit and push repo.xml'};
	ok( $commit, 'a "Commit and push repo.xml" step' ) or return;
	like( $commit, qr/^\s+COMMIT_NAME: Wilson Waters$/m,                          'author name' );
	like( $commit, qr/^\s+COMMIT_EMAIL: wilsonwaters\@users\.noreply\.github\.com$/m, 'author email' );
	like( $commit, qr/git config user\.name "\$COMMIT_NAME"/,                     'git user.name' );
	like( $commit, qr/git config user\.email "\$COMMIT_EMAIL"/,                   'git user.email' );
	unlike( $yml, qr/git config user\.\w+ '[^']*github-actions\[bot\]/,          'no longer committed as github-actions[bot]' );
	like( $commit, qr/git commit -m "Release v\$V: update repo\.xml \[skip ci\]"/, 'message keeps [skip ci]' );
	like( $commit, qr/git push origin HEAD:refs\/heads\/main/,                    'pushed to main' );

	like( $yml, qr/^      GH_TOKEN: \$\{\{ github\.token \}\}$/m, 'GITHUB_TOKEN for the GitHub CLI' );
	unlike( $yml, qr/secrets\./,                                   'no other token or secret' );
	unlike( $yml, qr/persist-credentials:\s*false/,                'checkout keeps GITHUB_TOKEN for the push' );
};

done_testing();
