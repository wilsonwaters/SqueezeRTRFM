package Plugins::RTRFM::Shows;

# RTRFM's current line-up and show details (artwork, schedule, hosts, genres, description) from
# the rtrfm.com.au WordPress site. No menu code: Plugins::RTRFM::OnDemand merges the line-up with
# Airnet's program list. All requests go through Plugins::RTRFM::HTTP.
#
# Contract (the ondemand stream relies on it; change only with care):
#
#   lineup($cb)
#       POST <SITE_BASE>/wp-admin/admin-ajax.php with the form fields action=filter_shows,
#       search= (empty), postTypes[]=show and page=N. The response is
#       {"success":true,"data":{"items":"<html>","postsPerPage":12}}.
#       Pages 1-4 are requested together (47 shows at 12 per page on 2026-09-26), so a cold load
#       costs one round trip to the slow admin-ajax (1.5-5.5 s per request measured). Going
#       through the pages in order, paging stops at the first page without a tease, when the
#       teases collected reach page 1's data-total-posts, or after page 10; pages after the stop
#       are ignored. Any further pages the total calls for are then requested together (one at a
#       time when the total is missing). Calls back exactly once:
#         $cb->(\@shows)         site order; slug 'training' dropped; the first tease per slug wins
#         $cb->(undef, $error)   any page failed (HTTP error, timeout, not JSON, success false, no
#                                data.items), or there were no shows at all
#       Each show is a hash as described under parseLineupPage. Cached for 24 hours (rtrfm cache
#       namespace, key 'shows:lineup'); failures, partial line-ups and empty ones never are.
#
#   showPage($slug, $cb)
#       GET <SITE_BASE>/shows/<slug>/ (HTTP.pm's raw get). Calls back exactly once:
#         $cb->({ description, image })   as parseShowPage; either may be undef
#         $cb->(undef, $error)            HTTP error (e.g. 404), timeout, or an invalid slug
#                                         (no request)
#       Cached for 24 hours (key 'shows:page:<slug>') when it found a description or an image.
#
#   parseLineupPage($html)                pure
#       filter_shows items HTML -> { total => data-total-posts (or undef), shows => \@shows },
#       one show per div.tease-show that has a /shows/<slug>/ link and an <h5> name, in page
#       order (duplicates and 'training' included):
#         slug      the first path segment after /shows/ ('drivetime', never 'drivetime/monday')
#         name      the <h5> text: entity-decoded, trimmed, whitespace collapsed
#         schedule  the first <span> after the name, e.g. 'Fridays 11.00pm - 1.00am', or undef
#         image     the srcset candidate of width 768w; else the smallest of at least 600w; else
#                   the largest; else src; else undef
#         hosts     [ span.font-mono texts after "Hosted by" ], where '+ 4' becomes '+4 more'
#         genres    [ span.midnight-border chip texts after the name, as shown (e.g. '+1') ]
#
#   parseShowPage($html)                  pure
#       Show page HTML (UTF-8 bytes or characters) -> { description, image }:
#         description  the div.post-description block as plain text (Airnet::htmlToText:
#                      paragraphs separated by blank lines, entities decoded), or undef
#         image        the first <meta property="og:image" content="...">, or undef
#
# Both parsers make one linear pass over the markup (no nested backtracking), so ~400 KB show
# pages are cheap, and they never die on unexpected markup.

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::RTRFM::Airnet;
use Plugins::RTRFM::HTTP;
use Plugins::RTRFM::Util;

use constant AJAX_URL   => Plugins::RTRFM::Util::SITE_BASE . '/wp-admin/admin-ajax.php';
use constant LINEUP_KEY => 'shows:lineup';
use constant LINEUP_TTL => 24 * 3600;    # seconds
use constant PAGE_TTL   => 24 * 3600;    # seconds
use constant MAX_PAGES  => 10;
use constant FIRST_PAGES => 4;    # requested together to start with

# An unclosed description block runs to the end of the page; don't convert more than this.
use constant MAX_DESCRIPTION_HTML => 64 * 1024;    # characters

my $log = logger('plugin.rtrfm');

my $MORE = qr/\A\+\s*(\d+)\z/;

# ---------------------------------------------------------------------------
# Line-up
# ---------------------------------------------------------------------------

sub lineup {
	my $cb = shift;

	my $cached = _cache()->get(LINEUP_KEY);
	return $cb->($cached) if ref $cached eq 'ARRAY' && @$cached;

	_fetchPages( { cb => $cb, teases => [] }, 1, FIRST_PAGES );
}

# Request pages $first..$last together. When all have answered, go through them in page order:
# a failed page is an error; an empty page, reaching the total or page 10 ends the line-up
# (later pages are ignored). Otherwise request the next pages.
sub _fetchPages {
	my ( $state, $first, $last ) = @_;

	my ( %pages, %errors );
	my $pending = $last - $first + 1;

	for my $n ( $first .. $last ) {
		_fetchPage( $n, sub {
			my ( $page, $error ) = @_;
			return if $state->{done};

			if ($page) {
				$pages{$n} = $page;
			}
			else {
				$errors{$n} = defined $error ? $error : "Couldn't load line-up page $n";
			}

			return if --$pending;

			for my $m ( $first .. $last ) {
				return _finishLineup( $state, $errors{$m} ) if $errors{$m};

				my $shows = $pages{$m}->{shows};
				return _finishLineup($state) unless @$shows;

				push @{ $state->{teases} }, @$shows;

				if ( $m == 1 ) {
					$state->{total}   = $pages{1}->{total};
					$state->{perPage} = scalar @$shows;
				}

				return _finishLineup($state) if $m >= MAX_PAGES || ( defined $state->{total} && @{ $state->{teases} } >= $state->{total} );
			}

			# enough pages for the rest of the total at once, else one more page
			my $total = $state->{total};
			my $next  = $last + 1;
			my $end   = defined $total ? $last + int( ( $total - @{ $state->{teases} } + $state->{perPage} - 1 ) / $state->{perPage} ) : $next;
			$end = MAX_PAGES if $end > MAX_PAGES;

			_fetchPages( $state, $next, $end );
		} );
	}
}

sub _fetchPage {
	my ( $n, $cb ) = @_;

	Plugins::RTRFM::HTTP::postFormJSON(
		AJAX_URL,
		{ action => 'filter_shows', search => '', 'postTypes[]' => 'show', page => $n },
		sub {
			my $data = shift;

			my $items = ref $data eq 'HASH' && $data->{success} && ref $data->{data} eq 'HASH' ? $data->{data}->{items} : undef;

			if ( !defined $items || ref $items ) {
				my $error = "Unexpected filter_shows response for page $n (" . AJAX_URL . ')';
				$log->warn($error);
				return $cb->( undef, $error );
			}

			my $page = eval { parseLineupPage($items) };

			if ( ref $page ne 'HASH' ) {
				my $error = "Couldn't read the rtrfm.com.au line-up page $n: " . ( $@ || 'unknown error' );
				$log->error($error);
				return $cb->( undef, $error );
			}

			$cb->($page);
		},
		sub { $cb->( undef, $_[0] ) },
	);
}

sub _finishLineup {
	my ( $state, $error ) = @_;
	$state->{done} = 1;

	my $cb = $state->{cb};
	return $cb->( undef, $error ) if defined $error;

	my ( @shows, %seen );
	for my $show ( @{ $state->{teases} } ) {
		next if $show->{slug} eq 'training' || $seen{ $show->{slug} }++;
		push @shows, $show;
	}

	if ( !@shows ) {
		$error = 'No shows found in the rtrfm.com.au line-up';
		$log->warn($error);
		return $cb->( undef, $error );
	}

	_cache()->set( LINEUP_KEY, \@shows, LINEUP_TTL );
	$cb->( \@shows );
}

sub parseLineupPage {
	my $html = shift;

	my %page = ( total => undef, shows => [] );
	return \%page unless defined $html && !ref $html && length $html;

	if ( $html =~ /data-total-posts\s*=\s*["']?([0-9]{1,6})/ && $1 > 0 ) {
		$page{total} = $1 + 0;
	}

	my $tokens = _tokenise($html);

	my @starts = grep {
		my $t = $tokens->[$_];
		$t->[0] eq 'div' && !$t->[1] && _hasClass( $t, 'tease-show' );
	} 0 .. $#$tokens;

	for my $i ( 0 .. $#starts ) {
		my $show = _parseTease( $tokens, $starts[$i], $i < $#starts ? $starts[ $i + 1 ] : scalar @$tokens );
		push @{ $page{shows} }, $show if $show;
	}

	return \%page;
}

# One tease: the tokens from its opening div ($from) up to the next tease ($to, exclusive).
sub _parseTease {
	my ( $tokens, $from, $to ) = @_;

	my ( $href, $img, $name, $schedule, $afterName, $hostedBy, $spans, @hosts, @genres );

	for ( my $i = $from + 1 ; $i < $to ; $i++ ) {
		my $t   = $tokens->[$i];
		my $tag = $t->[0];

		if ( $tag eq '#text' ) {
			$hostedBy = 1 if $afterName && $t->[2] =~ /hosted\s+by/i;
			next;
		}

		next if $t->[1];    # closing tag

		if ( $tag eq 'a' ) {
			$href = _attrs($t)->{href} unless defined $href;
		}
		elsif ( $tag eq 'img' ) {
			$img = _attrs($t) unless $img;
		}
		elsif ( $tag eq 'h5' && !defined $name ) {
			( $name, $i ) = _innerText( $tokens, $i, $to );
			$afterName = 1;
		}
		elsif ( $tag eq 'span' && $afterName ) {
			my $first = !$spans++;
			my $class = _classes($t);

			( my $text, $i ) = _innerText( $tokens, $i, $to );

			if ( $text =~ /\Ahosted\s+by\b/i ) {
				$hostedBy = 1;
			}
			elsif ($first) {
				$schedule = $text if length $text;
			}
			elsif ( $hostedBy && $class->{'font-mono'} ) {
				push @hosts, $text =~ $MORE ? "+$1 more" : $text if length $text;
			}
			elsif ( $class->{'midnight-border'} ) {
				push @genres, $text if length $text;
			}
		}
	}

	return undef unless defined $href && defined $name && length $name;

	my ($slug) = Plugins::RTRFM::Util::decodeEntities($href) =~ m{/shows/([^/?#]+)};
	return undef unless defined $slug && $slug =~ /\A[a-z0-9_-]+\z/;

	return {
		slug     => $slug,
		name     => $name,
		schedule => $schedule,
		image    => _chooseImage($img),
		hosts    => \@hosts,
		genres   => \@genres,
	};
}

# srcset candidate of width 768w; else the smallest of at least 600w; else the largest; else src.
sub _chooseImage {
	my $attrs = shift or return undef;

	my ( @candidates, $url );

	for my $part ( split ' ', Plugins::RTRFM::Util::decodeEntities( defined $attrs->{srcset} ? $attrs->{srcset} : '' ) ) {
		# a width descriptor ('768w', '768w,' or '768w,<next url>' without a space) ends a candidate
		if ( defined $url && $part =~ /\A([0-9]{1,5})w(?:,(.*))?\z/s ) {
			push @candidates, [ $url, $1 ];
			$url = $2;
		}
		else {
			$url = $part;
		}

		if ( defined $url ) {
			$url =~ s/\A,+//;
			$url =~ s/,+\z//;
			$url = undef unless length $url;
		}
	}

	if (@candidates) {
		my ($exact) = grep { $_->[1] == 768 } @candidates;
		return _absoluteUrl( $exact->[0] ) if $exact;

		my ($smallest) = sort { $a->[1] <=> $b->[1] } grep { $_->[1] >= 600 } @candidates;
		return _absoluteUrl( $smallest->[0] ) if $smallest;

		my ($largest) = sort { $b->[1] <=> $a->[1] } @candidates;
		return _absoluteUrl( $largest->[0] );
	}

	return _absoluteUrl( Plugins::RTRFM::Util::decodeEntities( $attrs->{src} ) );
}

# ---------------------------------------------------------------------------
# Show pages
# ---------------------------------------------------------------------------

sub showPage {
	my ( $slug, $cb ) = @_;

	if ( !defined $slug || ref $slug || $slug !~ /\A[a-z0-9_-]+\z/ ) {
		my $error = 'Invalid show slug: ' . ( defined $slug ? "'$slug'" : 'undef' );
		$log->warn($error);
		return $cb->( undef, $error );
	}

	my $key    = "shows:page:$slug";
	my $cache  = _cache();
	my $cached = $cache->get($key);
	return $cb->($cached) if ref $cached eq 'HASH';

	my $url = Plugins::RTRFM::Util::SITE_BASE . "/shows/$slug/";

	Plugins::RTRFM::HTTP::get(
		$url,
		sub {
			my $page = eval { parseShowPage(shift) };

			if ( ref $page ne 'HASH' ) {
				$log->error( "Couldn't read the show page $url: " . ( $@ || 'unknown error' ) );
				$page = { description => undef, image => undef };
			}

			if ( defined $page->{description} || defined $page->{image} ) {
				$cache->set( $key, $page, PAGE_TTL );
			}
			else {
				main::INFOLOG && $log->is_info && $log->info("No description or image on $url");
			}

			$cb->($page);
		},
		sub { $cb->( undef, $_[0] ) },
	);
}

sub parseShowPage {
	my $html = shift;

	my %page = ( description => undef, image => undef );
	return \%page unless defined $html && !ref $html && length $html;

	my $tokens = _tokenise($html);
	my $blockSeen;    # only the first post-description block counts

	for ( my $i = 0 ; $i < @$tokens ; $i++ ) {
		last if $blockSeen && defined $page{image};

		my $t = $tokens->[$i];
		next if $t->[1];

		if ( $t->[0] eq 'meta' && !defined $page{image} ) {
			my $attrs = _attrs($t);
			if ( defined $attrs->{property} && lc $attrs->{property} eq 'og:image' ) {
				$page{image} = _absoluteUrl( Plugins::RTRFM::Util::decodeEntities( _utf8( $attrs->{content} ) ) );
			}
		}
		elsif ( $t->[0] eq 'div' && !$blockSeen && _hasClass( $t, 'post-description' ) ) {
			$blockSeen = 1;

			# the block ends at the matching </div> (or the end of the page)
			my ( $depth, $end ) = ( 1, length $html );
			for ( my $j = $i + 1 ; $j < @$tokens ; $j++ ) {
				my $u = $tokens->[$j];
				next unless $u->[0] eq 'div';
				if ( $u->[1] ) {
					if ( --$depth == 0 ) {
						$end = $u->[3];
						last;
					}
				}
				else {
					$depth++;
				}
			}

			my $inner = substr( $html, $t->[4], $end - $t->[4] );
			if ( length $inner > MAX_DESCRIPTION_HTML ) {
				$inner = substr( $inner, 0, MAX_DESCRIPTION_HTML );
				$inner =~ s/<[^<>]*\z//;    # a tag cut in half
			}

			$page{description} = Plugins::RTRFM::Airnet::htmlToText( _utf8($inner) );
		}
	}

	return \%page;
}

# ---------------------------------------------------------------------------
# Markup helpers
# ---------------------------------------------------------------------------

# One linear pass over the markup. Returns a list of tokens:
#   [ '#text', 0, $text ]                           text (entities not decoded)
#   [ $name, $isEnd, $attrs, $from, $to, \%attrs ]  a tag: lower-case name, 1 for </name>, the raw
#                                                   attribute string, its offsets in $html; the
#                                                   parsed attributes are filled in by _attrs
# Comments and the contents of <script> and <style> are skipped. A '<' that doesn't start a
# well-formed tag is text. Attribute values may be quoted and contain '<' or '>'.
my $TAG = qr{\G<(/?)([a-zA-Z][a-zA-Z0-9:-]*+)((?:[^<>"']++|"[^"]*+"|'[^']*+')*+)>};

sub _tokenise {
	my $html = shift;

	my @tokens;
	my ( $pos, $length ) = ( 0, length $html );

	while ( $pos < $length ) {
		my $lt = index( $html, '<', $pos );

		if ( $lt < 0 ) {
			push @tokens, [ '#text', 0, substr( $html, $pos ) ];
			last;
		}

		push @tokens, [ '#text', 0, substr( $html, $pos, $lt - $pos ) ] if $lt > $pos;

		if ( substr( $html, $lt, 4 ) eq '<!--' ) {
			my $end = index( $html, '-->', $lt + 4 );
			last if $end < 0;
			$pos = $end + 3;
			next;
		}

		pos($html) = $lt;

		if ( $html !~ /$TAG/gc ) {
			push @tokens, [ '#text', 0, '<' ];
			$pos = $lt + 1;
			next;
		}

		my ( $isEnd, $name, $attrs ) = ( $1 ? 1 : 0, lc $2, $3 );
		$pos = pos($html);
		push @tokens, [ $name, $isEnd, $attrs, $lt, $pos ];

		if ( !$isEnd && ( $name eq 'script' || $name eq 'style' ) ) {
			last unless $html =~ m{\G.*?(?=</\Q$name\E\b)}gcsi;
			$pos = pos($html);
		}
	}

	return \@tokens;
}

# A tag token's attributes as { lower-case name => value } (the first of each name wins; a bare
# attribute has the value undef).
sub _attrs {
	my $t = shift;

	return $t->[5] ||= do {
		my %attrs;
		my $string = defined $t->[2] ? $t->[2] : '';

		while ( $string =~ /([^\s"'<>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>]+)))?/g ) {
			my $name = lc $1;
			next if exists $attrs{$name};
			$attrs{$name} = defined $2 ? $2 : defined $3 ? $3 : $4;
		}

		\%attrs;
	};
}

sub _classes {
	my $class = _attrs(shift)->{class};
	return { map { $_ => 1 } split ' ', defined $class ? $class : '' };
}

sub _hasClass { _classes( $_[0] )->{ $_[1] } ? 1 : 0 }

# The text inside the element whose opening tag is token $i (nested tags of the same name are
# counted), cleaned. Returns (text, index of the closing tag, or the last token before $to).
sub _innerText {
	my ( $tokens, $i, $to ) = @_;

	my $tag   = $tokens->[$i]->[0];
	my $depth = 1;
	my $text  = '';

	my $j = $i + 1;
	for ( ; $j < $to ; $j++ ) {
		my $t = $tokens->[$j];

		if ( $t->[0] eq '#text' ) {
			$text .= $t->[2];
		}
		elsif ( $t->[0] eq $tag ) {
			if ( !$t->[1] ) {
				$depth++;
			}
			elsif ( --$depth == 0 ) {
				last;
			}
		}
		elsif ( $t->[0] eq 'br' ) {
			$text .= ' ';
		}
	}

	return ( _clean($text), $j < $to ? $j : $to - 1 );
}

# Entity-decode, collapse whitespace and trim.
sub _clean {
	my $text = Plugins::RTRFM::Util::decodeEntities(shift);
	return '' unless defined $text;

	$text =~ s/\s+/ /g;
	$text =~ s/\A //;
	$text =~ s/ \z//;

	return $text;
}

# Make site-relative image URLs absolute; anything else is passed through (LMS's image proxy
# copes with odd characters). Empty -> undef.
sub _absoluteUrl {
	my $url = shift;
	return undef unless defined $url;

	$url =~ s/\A\s+//;
	$url =~ s/\s+\z//;
	return undef unless length $url;

	return "https:$url" if $url =~ m{\A//};
	return Plugins::RTRFM::Util::SITE_BASE . $url if $url =~ m{\A/};
	return $url;
}

# Show pages arrive as UTF-8 bytes; decode an extracted part (left alone if it already holds
# characters or isn't valid UTF-8).
sub _utf8 {
	my $string = shift;
	utf8::decode($string) if defined $string && !utf8::is_utf8($string);
	return $string;
}

sub _cache { Slim::Utils::Cache->new( Plugins::RTRFM::Util::CACHE_NAMESPACE ) }

1;
