#!/usr/bin/perl
# repo.xml, the third-party LMS repository file users add in Manage Plugins: well-formed, has
# every element/attribute LMS reads (ExtensionsManager::_parseXML), and agrees with install.xml.

use strict;
use warnings;

use Test::More;

sub slurp {
	my $file = shift;
	open( my $fh, '<:raw', $file ) or die "Can't open $file: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub versionCmp {
	my ( $x, $y ) = map { [ split /\./ ] } @_;
	return $x->[0] <=> $y->[0] || $x->[1] <=> $y->[1] || $x->[2] <=> $y->[2];
}

my $xml      = slurp('repo.xml');
my $manifest = slurp('RTRFM/install.xml');

my ($installVersion) = $manifest =~ m{<version>([^<]*)</version>};
my ($target)         = $manifest =~ m{<targetApplication>(.*?)</targetApplication>}s;
my ($minVersion)     = $target =~ m{<minVersion>([^<]*)</minVersion>};
my ($maxVersion)     = $target =~ m{<maxVersion>([^<]*)</maxVersion>};
my ($category)       = $manifest =~ m{<category>([^<]*)</category>};

SKIP: {
	skip 'xmllint not installed', 1 unless grep { -x "$_/xmllint" } split /:/, $ENV{PATH};
	my $out = qx{xmllint --noout repo.xml 2>&1};
	is( $? >> 8, 0, 'xmllint --noout repo.xml passes' ) or diag $out;
}

like( $xml, qr{\A<\?xml version="1\.0" encoding="UTF-8"\?>\n}, 'XML declaration, UTF-8' );
like( $xml, qr{<extensions>.*</extensions>\s*\z}s, 'root element <extensions>' );
like( $xml, qr{<details>\s*<title lang="EN">SqueezeRTRFM plugin repository</title>\s*</details>}, 'repository title (details/title lang=EN)' );
like( $xml, qr{<plugins>.*</plugins>}s, '<plugins> group' );

my @entries = $xml =~ m{(<plugin\s[^>]*>.*?</plugin>)}sg;
is( scalar @entries, 1, 'exactly one plugin entry' );
my $entry = $entries[0] // '';

my ($startTag) = $entry =~ m{\A(<plugin\s[^>]*>)};
my %attr;
$attr{$1} = $2 while ( $startTag // '' ) =~ m{(\w+)="([^"]*)"}g;

is_deeply( [ sort keys %attr ], [qw(maxTarget minTarget name version)], 'attributes: name, version, minTarget, maxTarget (and nothing else)' );
is( $attr{name}, 'RTRFM', 'name="RTRFM" (matches Plugins::RTRFM::Plugin, install folder, plugin.state:RTRFM)' );
like( $attr{version}, qr/\A[0-9]+\.[0-9]+\.[0-9]+\z/, 'version is X.Y.Z' );
ok( versionCmp( $attr{version}, $installVersion ) <= 0, "version $attr{version} is not ahead of install.xml ($installVersion)" );
is( $attr{minTarget}, $minVersion, 'minTarget equals install.xml targetApplication/minVersion' );
is( $attr{maxTarget}, $maxVersion, 'maxTarget equals install.xml targetApplication/maxVersion' );

my %child;
$child{$1} = $2 while $entry =~ m{<(\w+)(?:\s+lang="EN")?>([^<]*)</\1>}g;

is_deeply( [ sort keys %child ], [qw(category creator desc icon link sha title url)], 'children: title, desc, category, icon, url, sha, link, creator (no email/installations/target)' );
like( $entry, qr{<title lang="EN">RTRFM 92\.1</title>}, 'title lang=EN "RTRFM 92.1"' );
like( $entry, qr{<desc lang="EN">Unofficial [^<]+</desc>}, 'desc lang=EN says it is unofficial' );
is( $child{category}, 'radio',     'category radio' );
is( $child{category}, $category,   'category matches install.xml' );
is( $child{creator},  'Wilson Waters', 'creator' );
is( $child{link}, 'https://github.com/wilsonwaters/SqueezeRTRFM', 'link to the GitHub repository' );

my $v = $attr{version} // '';
is( $child{url}, "https://github.com/wilsonwaters/SqueezeRTRFM/releases/download/v$v/RTRFM-$v.zip", 'url is the release asset for the version attribute' );
like( $child{sha}, qr/\A[0-9a-f]{40}\z/, 'sha is 40 lower-case hex digits' );

my $prefix = 'https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/';
like( $child{icon}, qr/\A\Q$prefix\E/, 'icon is an absolute raw.githubusercontent.com URL on main' );
( my $iconPath = $child{icon} // '' ) =~ s/\A\Q$prefix\E//;
ok( length $iconPath && -f $iconPath, "icon path '$iconPath' exists in the repository" );

done_testing();
