#!/usr/bin/perl
# The user and maintainer docs: README.md (install, usage with the real menu names, now playing
# and its limits, troubleshooting, compatibility, screenshots, self-test), RELEASING.md,
# docs/official-repository.md, and every relative link and image in them.

use strict;
use utf8;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use Test::More;

binmode( Test::More->builder->$_, ':encoding(UTF-8)' ) for qw(output failure_output todo_output);

sub slurp {
	my ( $file, $layer ) = @_;
	open( my $fh, '<' . ( $layer || ':encoding(UTF-8)' ), $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

# EN values of RTRFM/strings.txt
my %EN;
{
	my $token;
	for my $line ( split /\n/, slurp('RTRFM/strings.txt') ) {
		next if $line =~ /^\s*(?:#|$)/;
		if    ( $line =~ /^(\S+)\s*$/ )             { $token = $1 }
		elsif ( $token && $line =~ /^\tEN\t(.*)$/ ) { $EN{$token} = $1 }
	}
}

# "## Heading" => section text
sub sections {
	my $doc = shift;
	my %section;
	$section{$1} = $2 while $doc =~ /^## (.+?)\n(.*?)(?=^## |\z)/msg;
	return %section;
}

# GitHub's anchor for a heading
sub slug {
	my $slug = lc shift;
	$slug =~ s/[^\w\- ]//g;
	$slug =~ s/ /-/g;
	return $slug;
}

my $REPO_URL = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/repo.xml';
my @DOCS     = ( 'README.md', 'RELEASING.md', 'CHANGELOG.md', glob('docs/*.md') );

subtest 'README.md' => sub {
	my $readme   = slurp('README.md');
	my @headings = $readme =~ /^## (.+)$/mg;
	is_deeply(
		\@headings,
		[ 'About', 'Features', 'Disclaimer', 'Requirements', 'Installation', 'Usage', 'Now playing & limitations', 'Troubleshooting', 'Compatibility', 'Self-test', 'Updating', 'Uninstalling', 'Manual installation', 'Development', 'License' ],
		'sections in order'
	);
	my %section = sections($readme);

	unlike( $readme, qr/in development/i, 'nothing described as still in development' );
	like( $section{Features}, qr/\*\*RTRFM Infinite Mix\*\*/, 'Features: Infinite Mix' );
	like( $section{Features}, qr/track\s+list/,             'Features: track lists' );

	like( $section{Disclaimer}, qr/unofficial/,                 'Disclaimer: "unofficial"' );
	like( $section{Disclaimer}, qr/not affiliated with RTRFM/,  'Disclaimer: "not affiliated with RTRFM"' );
	like( $section{Disclaimer}, qr/name and logo belong to/,    'Disclaimer: name and logo belong to the station' );
	like( $section{Disclaimer}, qr{<https://rtrfm\.com\.au/>},  'Disclaimer: links rtrfm.com.au' );

	like( $section{Requirements}, qr/8\.0 or later/, 'Requirements: LMS 8.0 or later' );
	like( $section{Requirements}, qr/9\.1\.x/,       'Requirements: tested on 9.1.x' );

	my $install = $section{Installation};
	like( $install, qr/^\s+\Q$REPO_URL\E$/m,                     'Installation: the exact repository URL, on its own line' );
	like( $install, qr/Settings → Manage Plugins/,              'Installation: Settings → Manage Plugins' );
	like( $install, qr/Additional Repositories/,                'Installation: Additional Repositories' );
	like( $install, qr/empty field and click \*\*Apply\*\*/,     'Installation: the URL is saved with Apply' );
	unlike( $readme, qr/\*\*Save\*\*/,                            'no "Save" button (LMS 9.1 has Apply and Close)' );
	like( $install, qr/SqueezeRTRFM plugin repository/,         'Installation: repository section name' );
	like( $install, qr/Tick\s+\*\*RTRFM 92\.1\*\* and click \*\*Apply\*\*/, 'Installation: tick RTRFM 92.1, Apply' );
	like( $install, qr/You are about to\s+install: … Only install extensions from authors whom you trust/, 'Installation: the third-party confirmation popup' );
	like( $install, qr/Click \*\*OK\*\*/,                        'Installation: confirm with OK' );
	like( $install, qr/[Rr]estart LMS/,                         'Installation: restart' );
	like( $install, qr/Radio → RTRFM 92\.1/,                    'Installation: where to find it' );

	# Usage: the real menu tree, with the EN names from strings.txt
	my $usage = $section{Usage};
	like( $usage, qr/\*\*Radio → \Q$EN{PLUGIN_RTRFM}\E\*\*/, 'Usage: **Radio → RTRFM 92.1** (PLUGIN_RTRFM)' );
	for my $token (qw(PLUGIN_RTRFM_LIVE PLUGIN_RTRFM_INFINITE_MIX PLUGIN_RTRFM_PROGRAMS PLUGIN_RTRFM_PLAY_EPISODE)) {
		like( $usage, qr/\*\*\Q$EN{$token}\E\*\*/, "Usage: **$EN{$token}** ($token)" );
	}
	for my $token (qw(PLUGIN_RTRFM_INFINITE_MIX_DESC PLUGIN_RTRFM_NO_EPISODES PLUGIN_RTRFM_NO_TRACKLIST PLUGIN_RTRFM_TRACKLIST_PENDING)) {
		like( $usage, qr/"\Q$EN{$token}\E"/, "Usage: \"$EN{$token}\" ($token)" );
	}
	like( $usage, qr/\*\*\Q$EN{PLUGIN_RTRFM_TRACKLIST}\E \(N\)\*\*/, 'Usage: **Track list (N)**' );
	( my $onAir = $EN{PLUGIN_RTRFM_ON_AIR} ) =~ s/%s//;
	( my $next  = $EN{PLUGIN_RTRFM_NEXT} )   =~ s/%s//;
	like( $usage, qr/"\Q$onAir\E\*show\* · \*time slot\*"/, 'Usage: the "On air: …" line' );
	like( $usage, qr/"\Q$next\E\*show\* · \*time slot\*"/,  'Usage: the "Next: …" line' );
	like( $usage, qr/"\Q$EN{PLUGIN_RTRFM_HOSTED_BY}\E: …"/, 'Usage: "Hosted by: …"' );
	like( $usage, qr/### Favourites\n.*\*\*RTRFM 92\.1 Live\*\*.*\*\*episode\*\*/s,  'Usage: how to favourite a live stream or an episode' );
	like( $usage, qr/Material skin.*hardware players|Material skin, Squeezebox players/s, 'Usage: Material and hardware players' );
	like( $usage, qr/hasn't been tested/,                                             'Usage: ... untested' );

	my $np = $section{'Now playing & limitations'};
	like( $np, qr/no track-level data for the live streams/,  'Now playing: no live track data' );
	like( $np, qr/show on air.*artwork.*time slot and the next show/s, 'Now playing: live show name, artwork, time slot, next show' );
	like( $np, qr/updates by itself/,                         'Now playing: live updates when the show changes' );
	like( $np, qr/\*\*\Q$EN{PLUGIN_RTRFM_SHOW_INFO}\E\*\*/,     'Now playing: Show info' );
	like( $np, qr/track playing at that point/,               'Now playing: current track during episodes' );
	like( $np, qr/\*\*Episodes stay available for 28 days\.\*\*/,               'limits: 28-day retention' );
	like( $np, qr/\*\*New episodes appear about 6 minutes after a show ends\*\*/, 'limits: about 6 minutes after a show ends' );
	like( $np, qr/come from Airnet.*typically the next day/s,                     'limits: Airnet details and track lists possibly next day' );
	like( $np, qr/"\Q$EN{PLUGIN_RTRFM_EPISODE_UNAVAILABLE}\E"/,                   'limits: the "no longer available" message' );
	like( $np, qr/first time can take several seconds/,                          'limits: first-open latency' );
	like( $np, qr/regular weekly time slots/,                                    'limits: slot inference for daily shows' );

	my $ts = $section{Troubleshooting};
	my @items = $ts =~ /^\*\*([a-f])\. /mg;
	is_deeply( \@items, [qw(a b c d e f)], 'Troubleshooting: items a-f' );
	like( $ts, qr/\*\*a\. .*restart.*Settings → Manage Plugins/s,                     'a: restart, then Manage Plugins' );
	like( $ts, qr/\*\*b\. .*HE-AAC.*`faad`.*Settings →\s+Advanced → File Types/s,     'b: HE-AAC needs faad, File Types' );
	like( $ts, qr/\*\*c\. "\Q$EN{PLUGIN_RTRFM_EPISODE_UNAVAILABLE}\E"/,               'c: "no longer available"' );
	like( $ts, qr/\*\*d\. Programs is empty, or shows an error item\*\*.*"\Q$EN{PLUGIN_RTRFM_LOAD_FAILED}\E".*"\Q$EN{PLUGIN_RTRFM_ERROR}\E".*Try\s+again later/s, 'd: Programs empty or error item: try later' );
	like( $ts, qr/\*\*e\. .*Settings → Advanced → Logging.*\(plugin\.rtrfm\).*\*\*Debug\*\*/s, 'e: Logging page, plugin.rtrfm = Debug' );
	like( $ts, qr/\Q["debug","plugin.rtrfm","DEBUG"]\E/,                              'e: the JSON-RPC command' );
	like( $ts, qr/server\.log.*github\.com\/wilsonwaters\/SqueezeRTRFM\/issues/s,      'e: server.log lines in a GitHub issue' );
	like( $ts, qr/\*\*f\. .*`scripts\/smoke\.sh`/,                                     'f: smoke.sh' );

	my $compat = $section{Compatibility};
	like( $compat, qr/\*\*Tested\*\* on LMS \*\*9\.1\.x\*\*.*Default.*squeezelite/s, 'Compatibility: tested on 9.1.x (Default skin, squeezelite)' );
	like( $compat, qr/\*\*Declared\*\* for LMS \*\*8\.0 or later\*\*.*not tested/s,  'Compatibility: declares 8.0+, untested' );
	like( $compat, qr/Material skin.*hardware players/s,                             'Compatibility: Material and hardware players' );

	my $self = $section{'Self-test'};
	like( $self, qr{^scripts/smoke\.sh http://<your-lms>:9000 <player-mac>$}m, 'Self-test: how to run it' );
	like( $self, qr/\*\*Warning:\*\* the test plays audio .* replaces its queue/s, 'Self-test: warns that it interrupts playback' );
	like( $self, qr/bash 4 or later, `curl` and `jq`/,                          'Self-test: requirements' );
	like( $self, qr/`SMOKE: <passed>\/9 passed`/,                                'Self-test: the summary line' );

	like( $section{Updating},     qr/update notice/,             'Updating: update notice' );
	like( $section{Updating},     qr/automatic plugin\s+updates/, 'Updating: automatic updates' );
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

subtest 'README screenshots: at least 3 PNGs in docs/images, each <= 400 KB, with alt text' => sub {
	my $readme = slurp('README.md');
	my @images = $readme =~ /!\[([^\]]*)\]\(([^)\s]+)\)/g;
	my %alt    = reverse @images;
	my @files  = keys %alt;
	ok( @files >= 3, scalar(@files) . ' images embedded' );
	for my $file ( sort @files ) {
		like( $file, qr{\Adocs/images/[\w.-]+\.png\z}, "$file: a PNG in docs/images/" );
		ok( length $alt{$file} >= 20, "$file: alt text \"$alt{$file}\"" );
		ok( -f $file, "$file exists" ) or next;
		my $size = -s $file;
		ok( $size <= 400 * 1024, "$file: $size bytes <= 400 KB" );
		is( substr( slurp( $file, ':raw' ), 0, 8 ), "\x89PNG\r\n\x1a\n", "$file: PNG signature" );
	}
	for my $shot ( 'RTRFM 92.1 menu', "program's page", 'track list' ) {
		ok( ( grep { /\Q$shot\E/ } values %alt ), "a screenshot of the $shot" );
	}
	my @unused = grep { my $f = $_; !grep { $_ eq $f } @files } glob('docs/images/*');
	is_deeply( \@unused, [], 'every file in docs/images is used' );
};

subtest 'relative links and anchors resolve' => sub {
	my %anchors;
	for my $doc (@DOCS) {
		$anchors{$doc} = { map { slug($_) => 1 } slurp($doc) =~ /^#+ (.+)$/mg };
	}
	for my $doc (@DOCS) {
		my $text = slurp($doc);
		$text =~ s/^```.*?^```//msg;    # not in code blocks
		my @links = $text =~ /\]\(([^)\s]+)\)/g;
		for my $link (@links) {
			next if $link =~ m{\A(?:https?:|mailto:)};
			my ( $path, $anchor ) = $link =~ /\A([^#]*)(?:#(.*))?\z/;
			my $target = length $path ? File::Spec->canonpath( File::Spec->catfile( dirname($doc), $path ) ) : $doc;
			$target =~ s{\A(?:[^/]+/\.\./)+}{};
			ok( -e $target, "$doc: $link -> $target exists" );
			if ( defined $anchor ) {
				ok( $anchors{$target} && $anchors{$target}->{$anchor}, "$doc: $link -> anchor #$anchor exists in $target" );
			}
		}
	}
};

subtest 'no private hostnames or addresses in the docs' => sub {
	for my $doc (@DOCS) {
		my $text = slurp($doc);
		unlike( $text, qr/pi14|alintech/i, "$doc: no private host names" );
		my @ips = grep { $_ ne '127.0.0.1' } $text =~ /\b((?:\d{1,3}\.){3}\d{1,3})\b/g;
		is_deeply( \@ips, [], "$doc: no IP addresses" );
	}
};

subtest 'RELEASING.md' => sub {
	my $doc = slurp('RELEASING.md');

	like( $doc, qr{<version>.*RTRFM/install\.xml}s,                     'release by bumping <version> in install.xml' );
	like( $doc, qr/update `CHANGELOG\.md` before bumping the version/i, 'step: update CHANGELOG.md before bumping the version' );
	like( $doc, qr/`scripts\/changelog-section\.sh X\.Y\.Z`/,           'how to preview the notes' );
	like( $doc, qr/release notes are the\s+body of `CHANGELOG\.md`'s `## \[V\]` section.*GitHub generates notes/s, 'notes from CHANGELOG.md, GitHub fallback' );
	like( $doc, qr/Actions → Release → Run workflow/,                   'release from the Actions UI' );
	like( $doc, qr{POST /repos/wilsonwaters/SqueezeRTRFM/actions/workflows/release\.yml/dispatches\n\s*\{"ref":"main"\}}, 'REST dispatch call' );
	like( $doc, qr/## What the workflow does\n(?:.*\n)*?1\. .*\n(?:.*\n)*?7\. /,  'workflow steps 1 to 7' );
	like( $doc, qr/authored and committed as\s+`Wilson Waters <wilsonwaters\@users\.noreply\.github\.com>`/, 'repo.xml commit authored as the repository owner' );
	like( $doc, qr/push itself is made with\s+`GITHUB_TOKEN`/,        '... and pushed with GITHUB_TOKEN' );
	like( $doc, qr/## Dry runs/,                                        'dry runs' );
	like( $doc, qr/the release notes a release of that version would get/, 'dry runs show the notes' );
	like( $doc, qr/nothing to do/,                                      'no-op run' );
	like( $doc, qr/repair/,                                             'repair path' );
	unlike( $doc, qr/nothing is lost/,                                  'no claim that nothing is lost' );
	like( $doc, qr/superseded and never gets a tag or a release.*harmless for LMS users/s, 'rapid bumps: a waiting run can be superseded' );
	like( $doc, qr/sha1sum/,                                            'verify: sha1sum of the downloaded asset' );
	like( $doc, qr/Settings → Actions → General → Workflow permissions →\s+Read and write/, '403: workflow permissions' );
	like( $doc, qr/[Bb]ranch protection.*GitHub Actions \(`github-actions\[bot\]`/s, 'branch protection: GitHub Actions must be able to push' );
	like( $doc, qr/[Nn]on-fast-forward push.*[Rr]etried automatically/s, 'non-fast-forward retried' );
	like( $doc, qr/Never reuse a version number/,                       'rule: never reuse a version' );
	like( $doc, qr/Never hand-edit `sha`/,                              'rule: never hand-edit sha' );
	like( $doc, qr/Never replace an uploaded asset/,                    'rule: never replace an asset' );
	like( $doc, qr/Feature pull requests never touch `<version>`/,      'rule: feature PRs never touch <version>' );
	like( $doc, qr/tags\s+can't be pushed from the development container/, 'why the workflow creates tags' );
};

subtest 'docs/official-repository.md' => sub {
	my $doc = slurp('docs/official-repository.md');
	my %section = sections($doc);

	like( $doc, qr/\*\*Status: not submitted yet\. The stakeholder decides whether and when to submit \(FQ5\)/, 'status: not submitted yet (FQ5)' );
	like( $doc, qr{LMS-Community/lms-plugin-repository}, 'the official repository' );

	my $pre = $section{Prerequisites};
	like( $pre, qr/name `RTRFM` is globally unique.*name="RTRFM"/s,        'prerequisite: unique name, check extensions.xml' );
	like( $pre, qr/valid XML.*`buildrepo\.pl` dies/s,                      'prerequisite: valid XML (buildrepo.pl dies)' );
	like( $pre, qr/URL is stable.*\Q$REPO_URL\E/s,                         'prerequisite: stable raw main URL' );
	like( $pre, qr/Zip names are versioned/,                               'prerequisite: versioned zip names' );
	like( $pre, qr/`minTarget` and `maxTarget` are both present/,          'prerequisite: minTarget and maxTarget' );
	like( $pre, qr/category is valid.*`radio`/s,                           'prerequisite: valid category' );
	like( $pre, qr/icon URL is absolute/,                                  'prerequisite: absolute icon URL' );
	like( $pre, qr/`sha` is correct/,                                      'prerequisite: correct sha' );

	my $steps = $section{Steps};
	like( $steps, qr/Fork/,                                 'steps: fork' );
	like( $steps, qr/`include\.json`.*`"repositories"`/s,  'steps: add the URL to include.json repositories' );
	like( $steps, qr/\Q"$REPO_URL",\E/,                     'steps: the exact URL' );
	like( $steps, qr/open a pull request/,                  'steps: open a pull request' );

	my $after = $section{'What happens after the merge'};
	like( $after, qr/every 6 hours/,                          'aggregator: 6-hourly rebuild' );
	like( $after, qr/`installations`.*install count/s,        'aggregator: installations replaced by stats' );
	like( $after, qr/unknown category becomes `misc`/,        'aggregator: unknown categories become misc' );
	like( $after, qr/remove 3 or more lines.*pull\s+request/s, 'aggregator: large removals open a PR' );

	my $check = $section{'Pre-submission checklist'};
	like( $check, qr/stakeholder has accepted v1\.0\.0/,          'checklist: stakeholder acceptance' );
	like( $check, qr/v1\.0\.0 installs from the repository URL/,  'checklist: v1.0.0 installs from the repo URL' );
	like( $check, qr/`scripts\/smoke\.sh .*` passes/,             'checklist: smoke.sh passes' );

	my $rules = $section{'Maintenance rules once listed'};
	like( $rules, qr/Keep `repo\.xml` valid XML/,      'rule: keep the XML valid' );
	like( $rules, qr/Never reuse a version number/,    'rule: never reuse versions' );
};

done_testing();
