# LMS plugin architecture: reference for SqueezeRTRFM

_Research date: 2026-09-26. Everything here comes from the real source files listed below (cloned `--depth 1`).
Where something is my own design or inference and not copied from a source, it is marked **(design)** or **(inferred)**._

## Sources (abbreviations used throughout)

| Tag | Repo / artefact | Why it matters |
|---|---|---|
| **LMS** | `LMS-Community/slimserver` branch `public/9.1` (`$VERSION = '9.1.2'`, current stable; `public/9.2` is 9.2.0 dev) | Core: OPMLBased, XMLBrowser, PluginManager/Downloader, ExtensionsManager, RemoteMetadata, HTTP(S) protocol handlers, CLI |
| **REPO** | `LMS-Community/lms-plugin-repository` (`README.md`, `include.json`, `buildrepo.pl`, `extensions.xml`, workflow) | Official aggregate repository and how you get listed |
| **DOC** | <https://lyrion.org/reference/repository-dev/>, <https://lyrion.org/reference/music-service-plugin/> | Official repo-XML reference and plugin layout guide |
| **RH** | `patapovich/rh-ondemand-lyrion` (Radio Helsinki, v1.4.0) | **Closest analogue**: a community station with a live stream plus polled now-playing, program→episode MP3s, and per-episode tracklists |
| **RP** | `michaelherger/RadioParadise` (v3.6.6, by an LMS core dev) | MetadataProvider polling, custom `radioparadise://` ProtocolHandler |
| **SOMA** | `danielvijge/lms-somafm` (v0.4) | Minimal OPMLBased radio plugin, Settings page, tag-push release workflow with gh-pages repo XML |
| **BBC** | `expectingtofly/LMS_BBC_Sounds_Plugin` (v2.54.8) | Position/offset-based track metadata during on-demand playback |
| **RNP** | `RadioNowPlaying-0.0.56.zip` from radionowplaying.com (sha1 matches `extensions.xml`) | The generic now-playing plugin: its push sequence and how it defers to other plugins |
| **SXM** | `paul-1/plugin-SiriusXM` | Tag-push release workflow that publishes `repo.xml` as a release asset |
| **TIDAL** | `michaelherger/lms-plugin-tidal` | `workflow_dispatch` release with `repo/release.pl` (XML::Simple + Digest::SHA) |
| **PLEX** | `onmomo/lms-squeeze-plex-hub` | The only plugin found with real unit tests (`t/`, Test::More, Test::MockModule, stubbed `Slim::` modules in `t/lib`) |
| **WFMU** | `toddmazierski/lms-wfmu-plugin` | Freeform-station plugin: live streams plus archive feeds through a `parser` class |
| **MAT** | `CDrummond/lms-material` `MaterialSkin/HTML/material/html/js/icon-mapping.js` | The `_svg.png` icon convention |
| **PLAT** | `LMS-Community/slimserver-platforms` `public/9.1` `Docker/start-container.sh` | Docker paths |
| **SL** | `ralph-irving/squeezelite` `main.c` | Headless test player |

---

## 0. Recommended design for an RTRFM plugin

### 0.1 Module list (repo layout)
```
SqueezeRTRFM/
├── RTRFM/                         # = the plugin; zip its *contents* (install.xml at zip root)
│   ├── install.xml                # module Plugins::RTRFM::Plugin, minVersion 8.0, maxVersion *
│   ├── strings.txt                # PLUGIN_RTRFM, PLUGIN_RTRFM_DESC, menu labels (EN)
│   ├── Plugin.pm                  # Slim::Plugin::OPMLBased subclass: menu tree only
│   ├── API.pm                     # every HTTP call to rtrfm.com.au, JSON->plain hashes, Slim::Utils::Cache
│   ├── Live.pm                    # RemoteMetadata provider(+parser) for the live stream URL; poll+push loop
│   ├── Metadata.pm                # RemoteMetadata provider for episode MP3 URLs (episode title/cover; optional current-track-by-position)
│   ├── ProtocolHandler.pm         # OPTIONAL v2: thin rtrfm:// wrapper (resume position, stable favourites)
│   ├── Settings.pm                # optional (poll interval, listening delay); page = plugins/RTRFM/settings/basic.html
│   └── HTML/EN/plugins/RTRFM/
│       ├── html/images/icon.png   # 512x512 PNG (+ icon_svg.png + icon.svg if you want Material to use an SVG)
│       └── settings/basic.html
├── repo.xml                       # third-party repository file (raw URL on main is what users add)
├── t/  (+ t/lib/Slim/... stubs)   # prove -lr t
└── .github/workflows/release.yml  # build zip -> sha1 -> GitHub Release -> update repo.xml
```
Keep pure data mapping (JSON → item hashes) in `API.pm` or a small `Parser` module with no `Slim::` calls at load time, so it can be unit-tested (§8.1).

### 0.2 URL scheme
- **Live stream:** play the real `https://…` stream URL directly (`type => 'audio'`). Attach now-playing with
  `Slim::Formats::RemoteMetadata->registerProvider/registerParser(match => qr{^https?://<live-host>/…})`, the approach RH `Live.pm` uses. There is no custom scheme to maintain.
  - Alternative (v2, **design**): a `rtrfm://live` pseudo-URL with a ProtocolHandler whose `scanUrl`/`new` map it to the current https stream. The advantage is that favourites survive a stream-URL change. The cost is a ProtocolHandler to maintain (§5.2).
- **Episodes:** v1 plays the plain `https://…mp3` (LMS's HTTPS handler streams and seeks it, §6.1). `Metadata.pm` matches the on-demand host/path regex.
  v2 (optional) wraps episodes as `rtrfm://https://…mp3{from=N}`, copying `Slim::Plugin::Podcast::ProtocolHandler` / RH `ProtocolHandler.pm`. That adds resume-from-position and lifecycle hooks (`onStream`, `onStop`).

### 0.3 Menu structure (**design**, patterns from RH/SOMA/WFMU)
```
RTRFM 92.1                      (initPlugin tag=>'rtrfm', menu=>'radios', weight=>10; playerMenu 'RADIO')
├─ ▶ Live: RTRFM 92.1           type audio, url <live https>, on_select play, line2 = current show
├─ Programs                     type link, url => \&programs  (coderef)
│   └─ <Program>                type link, url => \&programEpisodes, passthrough [$slug], image, favorites_url (string!)
│        ├─ <program blurb>     type textarea
│        └─ <Episode: date – title>   type link, play => <mp3>, duration, image, items => [
│               ▶ Play episode        type audio, url/play <mp3>, duration, on_select play
│               <episode blurb>       type textarea
│               Track list (N)        type link, items => [ {type=>'text', name=>"Artist – Title"} … ] ]
├─ Latest episodes              flat list of episode items
└─ (optional) Search programs   type search
```
Why the episode row is a `link` that carries `play`: `type => 'audio'` makes an item a playable leaf that cannot be browsed into. A `link` item with a `play` attribute can still be played or favourited from its play button (XMLBrowser `hasAudio()` checks `play` first; `_favoritesParams` uses `play`). RH `_maybeResume` does exactly this. See §3.

### 0.4 Metadata approach
1. **Live, level 0:** if the RTRFM stream carries useful ICY `StreamTitle`, core shows it without any plugin code (§5.1).
2. **Live, level 1 (recommended):** `Live.pm` registers a **provider** for the live URL regex. When the provider is called while a client plays the stream, it seeds a per-client `Slim::Utils::Timers` poll of RTRFM's now-playing/schedule endpoint. That is the timer lifecycle core TuneIn uses. Each result is **pushed** with `$song->pluginData(wmaMeta => {...})`, `Slim::Music::Info::setCurrentTitle($url, $stationLine)`, `$client->currentPlaylistUpdateTime(Time::HiRes::time())` and `notifyFromArray($client, ['newmetadata'])`, the sequence RH and RNP use. Also register a **parser** for the same regex that returns `1` if our data should beat the raw ICY text.
3. **Episodes:** `Metadata.pm` provider returns the cached `{title, artist => program, album => 'RTRFM 92.1', cover, duration}` recorded when the menu was built. RH `Metadata.pm` does this and adds a URL-derived fallback so favourites work after a restart.
4. **Stretch, current track during an episode:** if the tracklist has time offsets, the provider reads `Slim::Player::Source::songTime($client)` and returns the matching track as title/artist. A timer set for the next boundary sends `newmetadata`. BBC `_getAODTrack` uses the same offset-window lookup (§6.4).

### 0.5 Distribution approach
- `repo.xml` at repo root, added by users as `https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/repo.xml`.
  (Alternative used by SXM: `https://github.com/<o>/<r>/releases/latest/download/repo.xml`.)
- Zip name must carry the version (`RTRFM-1.0.0.zip`, per DOC). Host it as a GitHub Release asset. `<sha>` is the zip's SHA1.
- **Container constraint:** tags cannot be pushed from this container, so the workflow must create the tag and release itself. Trigger it with `workflow_dispatch` (TIDAL) and/or on push to `main` when `RTRFM/install.xml`'s `<version>` changes. It then commits the updated `repo.xml` back (TIDAL/SXM). See §7.4.
- Official listing later: PR adding the `repo.xml` URL to `include.json` in LMS-Community/lms-plugin-repository (§7.3).

---

## 1. Plugin layout, icons, zip structure, install locations

**Plugin name = module namespace.** `PluginManager::_parseInstallManifest` derives the name from `<module>`:
```perl
# LMS Slim/Utils/PluginManager.pm
if ($module && $module =~ /^Plugins::(.*)::/) { $pluginName = $1; }
...
} else { ($pluginName) = $file =~ /.*[\/|\\](.*)[\/|\\]install.xml/; }
```
So `<module>Plugins::RTRFM::Plugin</module>` means plugin name `RTRFM`. That name is the plugin-state pref key, the repo.xml `name=` and the install folder name.
PluginDownloader's header says it outright: *"The plugin 'name' must match the package naming of the plugin, i.e. name 'MyPlugin' equates to package 'Plugins::MyPlugin::Plugin'"* (LMS `Slim/Utils/PluginDownloader.pm` l.12).

**Where LMS looks for plugins:** it scans for `install.xml` under `dirsFor('Plugins')`:
- `<cachedir>/InstalledPlugins/Plugins/<Name>/` receives repository installs (LMS `Slim/Utils/OS.pm` l.154, PluginDownloader l.9: *"downloaded to <cachedir>/DownloadedPlugins and then extracted to <cachedir>/InstalledPlugins/Plugins/"*).
- Manual/dev installs go in `<server>/Plugins` on Debian (`/usr/share/squeezeboxserver/Plugins`, `Slim/Utils/OS/Debian.pm`), `/usr/share/lyrionmusicserver/Plugins` on RedHat, or `<cachedir>/Plugins` on Docker and piCorePlayer (`Slim/Utils/OS/Docker.pm`, `pCP.pm`).
- Official Docker image: `--cachedir /config/cache` (PLAT `start-container.sh` l.30). That gives dev path `/config/cache/Plugins/RTRFM/`; repo installs land in `/config/cache/InstalledPlugins/Plugins/RTRFM/`.
- Each plugin's `HTML/` dir is added to the template include path (`Slim::Web::HTTP::addTemplateDirectory($htmlDir)`, PluginManager l.365–378). So `HTML/EN/plugins/RTRFM/html/images/icon.png` is served at `/plugins/RTRFM/html/images/icon.png`. A plugin `lib/` dir is added to `@INC`, and `Bin/` to the binary search path.

**Zip structure:** `install.xml` goes at the zip root. PluginDownloader l.11: *"Plugins zip files should not include any additional path information - i.e. they include the install.xml file at the top level"*. Extraction also tolerates one prefix:
```perl
# LMS Slim/Utils/PluginDownloader.pm extract()
for my $search ("Plugins/$plugin/", "$plugin/") {
    if ( $zip->membersMatching("^$search") ) { $source = $search; last; }
}
$zip->extractTree($source, "$targetDir/")   # $targetDir = <cachedir>/InstalledPlugins/Plugins/<plugin>
```
Real zips: SOMA zips the repo root (`zip -r somafm-$VER.zip . -x …`). RH does `( cd RadioHelsinki && zip -qr "../$ZIP" . )`, i.e. files at the root. SXM zips a `SiriusXM/` folder, which also works thanks to the prefix search. RNP's zip has `Plugin.pm`, `install.xml` and the rest at the root.
Downloaded zips are saved as `<cachedir>/DownloadedPlugins/<Name>.zip`, SHA1-verified, then marked `needs-install`. Extraction happens on **restart** (`_installDownload` → `$prefs->set($name, 'needs-install')`).

**Icons:**
- `install.xml` `<icon>` is a path relative to `HTML/EN`, e.g. `plugins/RadioParadise/html/icon.png` (RP) or `plugins/SiriusXM/html/images/SiriusXMLogo.png` (SXM). `Slim::Plugin::Base::initPlugin` registers it with `addPageLinks("icons", …)`. OPMLBased uses it in the Jive/Radios menus via `proxiedImage($class->_pluginDataFor('icon'))`, falling back to `html/images/radio.png`.
- Sizes seen: 512×512 PNG (RP `icon.png`, SOMA `SomaFM_svg.png`, core Podcast `icon.png`, plus a `icon_40x40_m.png`). BBC uses 230×230.
- Material convention (MAT `icon-mapping.js` l.142): a name ending in `_svg.png` makes Material load the sibling `.svg` instead (`lmsIcon.replace("_svg.png", ".svg")`). `…MTL_svg_<name>.png` and `…MTL_icon_<name>.png` map to built-in Material icons. Ship `icon_svg.png` and `icon.svg` only if a monochrome SVG rendering is acceptable. Otherwise use a plain `icon.png`.
- repo.xml `<icon>` must be an **absolute public URL** (e.g. a `raw.githubusercontent.com` link). It is shown in Manage Plugins before install (SOMA, SXM, RP entries in `extensions.xml`).

**Settings page (optional).** Real example, SOMA `Settings.pm`:
```perl
package Plugins::SomaFM::Settings;
use base qw(Slim::Web::Settings);
sub name  { 'PLUGIN_SOMAFM' }
sub page  { 'plugins/SomaFM/settings/basic.html' }
sub prefs { return (preferences('plugin.somafm'), qw(menuLocation orderBy groupByGenre ...)); }
```
Template (SOMA `HTML/EN/plugins/SomaFM/settings/basic.html`): `[% PROCESS settings/header.html %]` … `[% WRAPPER setting title="TOKEN" desc="TOKEN_DESC" %]<input name="pref_groupByGenre" …>[% END %]` … `[% PROCESS settings/footer.html %]`.
Create it inside `initPlugin` behind `if (main::WEBUI) { require …::Settings; …::Settings->new; }` (RP, WFMU). `main::WEBUI` is a constant in `slimserver.pl` l.28. RH's comment that "WEB_UI" doesn't exist is only a misspelling.

---

## 2. install.xml

Real, minimal and current: RH `RadioHelsinki/install.xml`, SOMA `install.template.xml`, SXM, RP, core `Slim/Plugin/Podcast/install.xml`:
```xml
<?xml version="1.0"?>
<extension>
  <id>6B19E1A4-3C82-415D-A4C1-5B706B8D2ED1</id>        <!-- optional; used as Jive menu uuid -->
  <name>PLUGIN_PODCAST</name>                         <!-- string token from strings.txt -->
  <module>Slim::Plugin::Podcast::Plugin</module>      <!-- 3rd party: Plugins::<Name>::Plugin -->
  <version>2.0</version>
  <description>PLUGIN_PODCAST_DESC</description>      <!-- string token -->
  <creator>Lyrion Community</creator>
  <email>…</email>                                    <!-- optional -->
  <category>musicservices</category>                  <!-- radio|musicservices|… -->
  <defaultState>disabled</defaultState>               <!-- enabled|disabled (3rd party: enabled) -->
  <optionsURL>plugins/Podcast/settings/basic.html</optionsURL>
  <icon>plugins/Podcast/html/images/icon.png</icon>
  <homepageURL>https://…</homepageURL>                <!-- optional, shown in Manage Plugins -->
  <type>2</type><!-- type=extension -->                <!-- legacy, harmless -->
  <targetApplication>
    <id>Lyrion Music Server</id>                      <!-- free text; SqueezeCenter/SlimServer also seen -->
    <minVersion>7.0a</minVersion>
    <maxVersion>*</maxVersion>
  </targetApplication>
</extension>
```
How keys are consumed (LMS):
- `module`: **required**. Missing gives `INSTALLERROR_NO_MODULE`. `importmodule` is the scanner/importer module (TIDAL: `<importmodule>Plugins::TIDAL::Importer</importmodule>`), selected by `$manifest->{ $moduleType . 'module' }`. **Not needed** for RTRFM.
- `targetApplication/minVersion`, `maxVersion`: **required**. `_checkPluginVersion` returns 0 (gives `INSTALLERROR_INVALID_VERSION`) if `targetApplication` is missing or `$::VERSION` falls outside the range. `maxVersion` is ignored if the user enabled "use unsupported".
- `name`, `description`: string tokens. `getCurrentPlugins` displays `Slim::Utils::Strings::getString($entry->{name})`. Strings for disabled plugins are still loaded for these two tokens (`PluginManager::dirsFor('strings')`).
- `optionsURL`: the settings link in Manage Plugins (`ExtensionsManager::getCurrentPlugins`: `settings => … $entry->{'optionsURL'}`). **There is no `settingsPage` key.** `homepageURL`, `creator`, `email`, `category`, `icon` and `version` are shown in the same list. RH's `<link>` in install.xml is not read by anything.
- `defaultState`: applied only the first time (when `plugin.state:<Name>` pref is undefined).
- Also recognised: `enforce` (cannot be disabled), `targetPlatform`, `playerMenu` (read by `Base::playerMenu`), `onlineLibrary` (TIDAL), `needsMySB` (skipped since mysb is gone).

**Version targets:** the OPMLBased, RemoteMetadata and PluginDownloader APIs used here are unchanged between `public/8.3` and `public/9.1`. I diffed `OPMLBased.pm`: only the removal of an SN-disabled check. Recommend `<minVersion>8.0</minVersion><maxVersion>*</maxVersion>`, as in ARD (8.0), SXM (8.3) and RH (8.2). Plain OPML plus RemoteMetadata also works back to 7.9 (SOMA, RP, BBC), but there is no need to claim it.

---

## 3. `Slim::Plugin::OPMLBased` and the OPML item vocabulary

### 3.1 initPlugin / display name / menus
```perl
# RP Plugin.pm (also SOMA, WFMU, RH): radios menu, optional apps menu
$class->SUPER::initPlugin(
    feed   => \&handleFeed,        # coderef ($client,$cb,$args) or a URL string
    tag    => 'radioparadise',     # CLI command name + web path plugins/<tag>/index.html
    menu   => 'radios',            # 'radios' = Radio menu; is_app => 1 forces menu 'apps' (My Apps)
    is_app => $prefs->get('showInRadioMenu') ? 0 : 1,
    weight => 1,                   # sort order in the menu (default 1000)
);
sub getDisplayName { 'PLUGIN_RADIO_PARADISE' }   # string token; uc(name) eq name => string() lookup
sub playerMenu { $prefs->get('showInRadioMenu') ? 'RADIO' : undef; }  # ip3k (Classic/Boom) button UI
```
What OPMLBased does with these (LMS `Slim/Plugin/OPMLBased.pm`):
- `is_app` sets `menu = 'apps'`.
- It installs `feed`, `tag`, `menu`, `weight` (default 1000) and `type` (default `link`; `search` is also allowed) as class methods.
- It registers the CLI dispatches `[<tag>,'items',_index,_quantity]` and `[<tag>,'playlist',_method]`, plus `[<menu>,_index,_quantity]` (e.g. `radios 0 100`).
- It registers a Jive node (`id => 'opml'.$tag`, `node => menu`).
- `webPages` adds a link under the `radios` web menu and serves `plugins/<tag>/index.html` through `Slim::Web::XMLBrowser->handleWebIndex(… timeout => 35)`.
- Optional hook: `sub condition { my ($class,$client)=@_; … }` hides the menu when it returns false.

### 3.2 Coderef callback signature
XMLBrowser invokes a top-level feed as `$feed->( $client, $callback, \%args )`. A sub-item whose `url` is a coderef is invoked as
```perl
# LMS Slim/Control/XMLBrowser.pm l.525
$subFeed->{url}->( $client, $callback, \%args, @{ $subFeed->{passthrough} || [] } );
```
- `%args` contains `params` (the request params), `isControl => 1`, and optionally `index`/`quantity` (paging hints), `search` (for `type => 'search'`) and `orderBy`.
- The callback accepts either a hashref `{ items => [...], title?, cachetime?, nocache? }` (`type` defaults to `opml`) or an arrayref of items.
- Error pattern (SOMA): `$callback->([ { name => $_[1], type => 'text' } ]);`

### 3.3 Item keys (from XMLBrowser code plus real plugin items)
| key | meaning / source |
|---|---|
| `name` / `title` | label (`title` also used for window title) |
| `line1`, `line2` | two-line rendering in Material and other skins (SOMA `_parseChannel`, RH `_urlItem`) |
| `type` | `link` (browse; default when `items` or coderef `url`), `audio` (playable leaf), `playlist` (container that is also playable; `url` may be a feed with `parser`), `text`, `textarea` (+`wrap => 1`), `search` (`url` coderef gets `$args->{search}`; string URLs get `{QUERY}` substituted), `outline` (RP groups streams) |
| `url` | string (stream/feed URL) or coderef (sub-menu) |
| `play` | playable URL used instead of `url` for playback (XMLBrowser l.683 "Items with a 'play' attribute will use this for playback"). Lets a `link` be both browsable and playable |
| `items` | inline children (arrayref) |
| `passthrough` | arrayref appended to the coderef call |
| `image` / `icon` / `cover` | artwork. When the URL is added to the playlist, `setRemoteMetadata(cover => cover‖image‖icon)` caches it as `remote_image_$url` (LMS `DEVELOPERS.txt`) |
| `duration`, `bitrate`, `mime`, `year` | passed to `Slim::Music::Info::setRemoteMetadata($url,{secs=>duration, bitrate, ct=>mime, …})` at play time (XMLBrowser l.693–700). `duration` also shows as "Length: m:ss" in item info |
| `description` | info text (`hasDescription`). Also shown in the item-info list together with `listeners`, `current_track`, `genre`, `bitrate`, `duration` (`@mapAttributes`) |
| `on_select => 'play'` | touch-to-play (XMLBrowser `touchToPlay`); podcast items use it too (core `Podcast/Parser.pm` l.90) |
| `playall` | include this item when "play all" runs from a sibling |
| `favorites_url` / `favorites_type` / `favorites_title` / `favorites_icon` | what "Add to favourites" saves. Default is `play`‖`url`, and only if **not a coderef** (`_favoritesParams`). Use a string URL plus a `parser` (RH `Parser.pm`) or a PH `explodePlaylist` (RH `radiohelsinki://kesken`) to make program menus favouritable |
| `parser` | class with `parse($class,$http,$params)` for string feed URLs (WFMU `ArchiveFeedParser`; return `{items=>[…], nocache=>1}`) |
| `enclosure => {url,type}` | RSS-style audio (core Podcast) |
| `nextWindow`, `cachetime`, `nocache`, `wrap`, `hide` | less common |

Real episode item (RH `Plugin.pm` `_urlItem`):
```perl
return {
    name => $name, line1 => $name, line2 => $line2,
    type => 'audio', url => $wrapped, play => $wrapped, on_select => 'play',
    image => $cover || FALLBACK_ICON,
    $meta->{duration} ? ( duration => $meta->{duration} ) : (),
    length( $meta->{description} || '' ) ? ( description => $meta->{description} ) : (),
};
```
Real "episode submenu with tracklist" (RH `_episodeMenus`, trimmed):
```perl
push @episodes, {
    name => $name, line1 => $name, line2 => $episode->{line2},
    type => 'link', image => $episode->{image} || $icon,
    items => [
        ( { name => $episode->{description}, type => 'textarea', wrap => 1 } ),
        _playItem( $client, $episode, cstring($client,'PLUGIN_RADIOHELSINKI_PLAY_EPISODE') ),
        { name  => cstring($client,'PLUGIN_RADIOHELSINKI_TRACKLIST') . ' (' . scalar(@$tracks) . ')',
          type  => 'link',
          items => [ map { Plugins::RadioHelsinki::Search::trackItem($client,$_,$prog) } @$tracks ] },
    ],
};
```
(RH track rows are `link`s to a library/Spotify search. For RTRFM, plain `{ name => "Artist – Title", type => 'text' }` rows are enough.)

---

## 4. Async HTTP, caching, JSON, logging, prefs, strings

**SimpleAsyncHTTP** (LMS `Slim/Networking/SimpleAsyncHTTP.pm`, `SimpleHTTP/Base.pm`). Never block the server: DOC music-service guide says *"use LMS' own Slim::Networking::SimpleAsyncHTTP … crucial to not interrupt playback, as LMS is single threaded"*.
```perl
# core Slim/Plugin/Podcast/PodcastIndex.pm (HTTPS + custom headers + cache)
Slim::Networking::SimpleAsyncHTTP->new(
    sub { my $response = shift; my $result = eval { from_json( $response->content ) }; ... },
    sub { $log->warn("can't get new episodes for $url ", shift->error); $cb2->(); },
    { cache => 1, expires => 900, timeout => 30 },
)->get($url, @$headers);          # headers as a flat list: 'X-Auth-Key' => $k, ...
```
- Constructor: `new($successCb, $errorCb, \%params)`. Your own keys (e.g. `client => $client`) come back via `$http->params('client')`. The error callback gets `($http, $error)`; `$http->error` also works.
- Options: `timeout` (default is pref `remotestreamtimeout`), `cache => 1` + `expires => '1h'|seconds` (otherwise honours `Cache-Control: max-age`), `saveAs`, `maxRedirect` (default is pref `maxRedirects`; redirects are followed), `insecureHTTPS`, `options`, `socks`.
- Default headers: `Accept-Language`, `Accept-Encoding: gzip` (when zlib is available), and `If-None-Match`/`If-Modified-Since` for cached entries. Override `User-Agent` by passing it as a header (RH Live.pm passes a browser UA plus `Referer` because the station's Cloudflare bot-blocks). `Slim::Utils::Misc::userAgentString()` is LMS's UA.
- HTTPS works when `SimpleAsyncHTTP->hasSSL` is true (RP guards lossless features with `Slim::Networking::Async::HTTP->hasSSL()`).
- `$http->content`, `->contentRef`, `->code`, `->headers`, `->url`.
- For polling now-playing use `cache => 0`. For program/episode lists, `cache => 1, expires => 300..3600`.

**Slim::Utils::Cache** (LMS `Slim/Utils/Cache.pm`): `my $cache = Slim::Utils::Cache->new($namespace, $version, $noPeriodicPurge)`, then `->set($k,$data,$expires)` / `->get($k)` / `->remove($k)`. Data is SQLite-backed and Storable-serialised, so **no coderefs**. Bumping `$version` wipes the namespace. RH: `Slim::Utils::Cache->new('radiohelsinki', 1, 1)` is a persistent, non-purged namespace for song-art lookups. `Slim::Utils::Cache->new()` is the shared default namespace (used for `remote_image_$url`).

**JSON:** core plugins use `use JSON::XS::VersionOneAndTwo;` → `from_json`/`to_json` (core `Podcast/Plugin.pm`, `PodcastIndex.pm`; RH). SOMA and RP use `use JSON::XS qw(decode_json);`. Both are bundled with LMS. Always wrap parsing in `eval { }`.

**Logging:** `my $log = Slim::Utils::Log->addLogCategory({ category => 'plugin.rtrfm', defaultLevel => 'ERROR', description => 'PLUGIN_RTRFM' });`. Elsewhere use `logger('plugin.rtrfm')`. Guard debug calls: `main::DEBUGLOG && $log->is_debug && $log->debug(...)` (`main::DEBUGLOG`/`INFOLOG` are constants in `slimserver.pl` l.24–25). Levels can be raised at startup with `--debug plugin.rtrfm=debug,formats.metadata=debug` (`Slim::Utils::Log` parses `cat=level` pairs), or in Settings → Advanced → Logging.

**Prefs:** `my $prefs = preferences('plugin.rtrfm'); $prefs->init({ pollinterval => 15 }); $prefs->get('x'); $prefs->set('x',1);` plus `setChange`, `setValidate`, `migrate` (LMS `Slim/Utils/Prefs/Namespace.pm`). Stored in `prefs/plugin/rtrfm.prefs`.

**strings.txt:** a token line, then tab-indented `<LANG><TAB>text` lines (SOMA):
```
PLUGIN_SOMAFM
	EN	SomaFM

PLUGIN_SOMAFM_DESC
	EN	Play radio channels from SomaFM
```
Use `cstring($client,'TOKEN')` (capitalised) or `string('TOKEN', @sprintfArgs)` from `Slim::Utils::Strings`.

---

## 5. Live-stream "now playing" metadata

### 5.1 (a) Default ICY pass-through: zero code
`Slim::Player::Protocols::HTTP::parseMetadata` first asks `RemoteMetadata->getParserFor($url)`. If no parser handled the data, it parses `StreamTitle='…'`, optionally taking artwork from `StreamUrl='…jpg'`, and calls `setCurrentTitle`. `getMetadataFor` then splits `"Artist - Title"` on a single ` - ` into artist/title (LMS `Slim/Player/Protocols/HTTP.pm` l.270–330, l.1035–1085). Order inside `getMetadataFor`: **registered provider** (if it returns a non-empty hash) → `$song->pluginData('wmaMeta')` → the current ICY title → cached `remote_image_$url`.
**Trade-off:** free, and it syncs with the audio. But the quality is whatever the station encoder sends, with no show name, cover or duration. SOMA relies entirely on this.

### 5.2 (b) Custom ProtocolHandler (pseudo scheme)
Real example, RP `ProtocolHandler.pm` (registered in `Plugin.pm`: `Slim::Player::ProtocolHandlers->registerHandler(radioparadise => 'Plugins::RadioParadise::ProtocolHandler')`):
```perl
package Plugins::RadioParadise::ProtocolHandler;
use base qw(Slim::Player::Protocols::HTTPS);
sub new {                       # open the socket on the real stream URL, avoid redirect loops
    my ($class, $args) = @_;
    my $streamUrl = $args->{song}->streamUrl() || return;
    $streamUrl = $args->{url} if $args->{url} && $args->{redir} && $args->{redir} ne $args->{url};
    return $class->SUPER::new({ url => $streamUrl, song => $args->{song}, client => $args->{client} });
}
sub canSeek { 0 }  sub isRemote { 1 }  sub canDirectStream { 0 }  sub isRepeatingStream { 1 }
sub scanUrl { my ($class, $url, $args) = @_; $args->{cb}->( $args->{song}->currentTrack() ); }  # skip scanning
sub getNextTrack { my ($class,$song,$successCb,$errorCb)=@_; ... $song->streamUrl($songdata->{gapless_url}); ... }
```
- BBC's handler (`sounds://`) implements `getMetadataFor($class,$client,$url,$forceCurrent)`, reads `$song->pluginData('meta')`, and returns `{artist, album, title, duration, secs, cover, buttons, live_edge}`.
- Core thin-handler rules (LMS `DEVELOPERS.txt` "Thin Protocol Handler"): unwrap in `scanUrl`, let `Slim::Utils::Scanner::Remote` do the HTTP work, rewrite `$track->url` back to your scheme in the callback, set `$song->streamUrl`, and check `$args->{redir}` in `new()` to avoid infinite redirect loops. The model is `Slim::Plugin::Podcast::ProtocolHandler`.
- **Trade-off:** full control (stable pseudo URLs, lifecycle hooks `onStream`/`onStop`/`onPlayout`, `canDoAction`, custom buttons) against more code and more ways to break streaming, seeking and direct-streaming. Not needed for v1 live metadata.

### 5.3 (c) RemoteMetadata provider/parser keyed by URL regex (recommended)
API (LMS `Slim/Formats/RemoteMetadata.pm` POD):
```perl
Slim::Formats::RemoteMetadata->registerProvider( match => qr/soma\.fm/, func => \&provider );
sub provider { my ($client,$url)=@_; return { artist=>…, album=>…, title=>…, cover=>'http://…', bitrate=>128, type=>'Internet Radio' }; }
Slim::Formats::RemoteMetadata->registerParser( match => qr/soma\.fm/, func => \&parser );
sub parser { my ($client,$url,$metadata)=@_; ...; return 1; }  # 1 = handled (suppress core ICY), 0 = let core handle
```
Storage is `Tie::RegexpHash`: lookup walks the regexes **in registration order and the first match wins** (`CPAN/Tie/RegexpHash.pm` `_find`). Plugins `initPlugin` in `sort keys %$loaded` order (PluginManager l.389). `Plugins::RTRFM::…` sorts before `Plugins::RadioNowPlaying::…` in ASCII order. RNP also checks `getProviderFor($urlRegex)` and skips registration if someone else already owns the URL (RNP `Plugin.pm` l.6730–6765).

**Polling pattern (core TuneIn / RP):** the provider seeds a per-client timer and returns cached or default metadata straight away:
```perl
# RP MetadataProvider.pm (same shape as LMS Slim/Plugin/InternetRadio/TuneIn/Metadata.pm)
sub provider {
    my ($client, $url) = @_;
    return defaultMeta(undef, $url) unless $client;
    $client = $client->master;
    return defaultMeta($client, $url) if !$client->isPlaying && !$client->isPaused;
    if ( my $meta = $client->pluginData('metadata') ) { return $meta if $meta->{_url} eq $url; }
    fetchMetadata($client, $url) unless $client->pluginData('fetchingMeta');
    return defaultMeta($client, $url);
}
sub fetchMetadata {
    my ($client, $url) = @_;
    Slim::Utils::Timers::killTimers($client, \&fetchMetadata);
    $client = $client->master;
    return if Slim::Player::Playlist::url($client) ne $url;       # stop when the player moved on
    Slim::Networking::SimpleAsyncHTTP->new(\&_gotMetadata, \&_gotMetadataError, { client=>$client, url=>$url })->get($metaUrl);
}
sub _gotMetadata {  ...
    $client->pluginData( metadata => $meta );
    Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
    Slim::Utils::Timers::setTimer( $client, time() + $ttl, \&fetchMetadata, $url );
}
```
**Push pattern with progress bar (RH `Live.pm` `_push`, derived from RNP `Plugin.pm` l.21468–21562):**
```perl
my $song = $client->playingSong or return;
$song->duration( $s->{len} || 0 );                                         # live only!
$song->startOffset( ( time() - $delay - $s->{start} ) - $client->songElapsedSeconds ) if $s->{len};
Slim::Music::Info::setCurrentTitle( $surl, $progline );    # station/show line; clientless on purpose
$song->pluginData( wmaMeta => { artist=>…, album=>…, title=>…, cover=>… } );  # read by HTTP::getMetadataFor
$client->currentPlaylistUpdateTime( Time::HiRes::time() );  # Default web skin refreshes on this
Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );        # Jive/Material status push
```
RH also registers `registerParser(match => MATCH, func => sub { return 1 })` so stray ICY blocks (and other plugins' parsers) cannot overwrite its title. It exposes a `listendelay` pref (default 7 s) to shift progress bars to what the listener actually hears.
**How the UI shows it:** `status` → `Slim::Control::Queries::_songData` calls `handler->getMetadataFor($client,$url)` for remote tracks and maps `title`, `artist`→`a`, `album`→`l`, `cover`→`K` (`artwork_url`), `duration`→`d`, `buttons`→`B`, and so on (Queries.pm l.5880–5905). Top-level `current_title` = `getCurrentTitle($client,$url)`. `time` = `songTime`, `duration` = `$song->duration`. Material and Default poll or subscribe to `status`, and `newmetadata` triggers a re-fetch.
**Trade-offs:** (c) is the least code and doesn't touch streaming. Without a delay the text runs a few seconds ahead of the audio (use a listen-delay offset, or `Slim::Music::Info::setDelayedCallback($client,$cb)`, which delays by the player's buffer; RP and BBC use it). It needs an RTRFM now-playing/schedule endpoint.

---

## 6. On-demand episodes

### 6.1 Playback and seeking of remote HTTPS MP3s
- A plain `type => 'audio', url => 'https://…mp3'` item plays through `Slim::Player::Protocols::HTTPS` (subclass of `IO::Socket::SSL` + `Protocols::HTTP`). Certificates are verified unless the server pref `insecureHTTPS` is on. `canDirectStream` direct-streams only if `$client->canHTTPS`; otherwise LMS proxies the stream (LMS `Slim/Player/Protocols/HTTPS.pm`).
- **Seeking needs bitrate + duration:** `Protocols::HTTP::canSeek` returns 0 unless `$song->bitrate` and `$song->duration` are both known. `getSeekData` converts seconds to a byte offset (`(bitrate/8) * t`), and the next GET uses a `Range` request (LMS `HTTP.pm` l.1150–1208; `DEVELOPERS.txt` "The 'GET' request … uses a 'Range' byte offset").
- **Where they come from:** when scanning an MP3, `Slim::Utils::Scanner::Remote::parseAudioStream` reads the first frames, runs `scanBitrate`, and if `Content-Length` is present sets `duration = Content-Length*8/bitrate` (`Scanner/Remote.pm` ~l.1078–1096). So **range support + Content-Length is enough for seeking**. RH `Metadata.pm`: *"plain MP3 on Cloudflare with Content-Length and Accept-Ranges, so the stock HTTP(S) machinery streams and seeks it natively"*.
- **Still pass `duration`** in the OPML item. XMLBrowser calls `setRemoteMetadata($url,{secs=>duration,…})`, which shows the length before the scan and in menus. The byte→time mapping for VBR files is approximate (an average bitrate is used).
- Resume/"start at" needs a PH: the Podcast/RH `{from=N}` suffix. `scanUrl` stores `seekdata({startTime})`, and `getNextTrack` converts it with `$song->getSeekData($startTime)` after the scan (core `Podcast/ProtocolHandler.pm` l.100–112). `onStop` saves `playingSongElapsed` to the cache.

### 6.2 Episode metadata while playing
RH `Metadata.pm` registers a provider on the on-demand URL regex (it explicitly excludes the live host so it cannot shadow `Live.pm`). It returns metadata cached when the menu was built (`API::getMeta($url)`). If that is missing, it synthesises a result from the URL, and it returns `{}` for URLs it doesn't recognise so ICY/other providers still work: *"Returning anything non-empty here would suppress other providers' and ICY handling for it."* Cache the episode meta keyed by the plain URL when building episode lists. This is also what makes favourites display correctly.

### 6.3 Track list per episode
Use a sub-menu of `text` items, or `link` items like RH (§3.3). RH also adds the episode info to the **Now Playing → song info** view:
```perl
Slim::Menu::TrackInfo->registerInfoProvider( radiohelsinki => ( after => 'top', func => \&trackInfoMenu ) );
sub trackInfoMenu { my ($client,$url,$track,$remoteMeta)=@_; ...
    return [ { name => 'Episode info', items => [ { type=>'text', wrap=>1, name=>$meta->{description} } ], unfold => 1 } ]; }
```
The same hook could list the current episode's tracklist in song info (**design**).

### 6.4 Stretch: current track from playback position
Real precedent (BBC `ProtocolHandler.pm` `_getAODTrack`): pick the segment whose offset window contains the current time.
```perl
for my $track (@$jsonData) {
    if ($currentOffsetTime >= $track->{offset}->{start} && $currentOffsetTime < $track->{offset}->{end}) {
        $cbY->({'total' => 1, 'data' => [$track]}); return;
    }
}
```
BBC derives `$currentOffsetTime` from DASH segment numbers inside `sysread`, then updates `$song->pluginData('meta')` and calls `setCurrentTitle`, then `notifyFromArray($client,['newmetadata'])` via `setDelayedCallback`.
For a plain MP3 the audible position is `Slim::Player::Source::songTime($client)` = `$client->controller->playingSongElapsed` (includes `startOffset`, reports `resumeTime` when paused; LMS `Source.pm` l.51, `StreamingController.pm` l.1719). The same value is used by core Podcast `onStop` and BBC `canDoAction`.
**(design)** sketch for `Metadata.pm`:
```perl
sub provider {
    my ($client, $url) = @_;
    my $ep = API::getMeta(API::plainUrl($url)) or return {};
    my $meta = { title => $ep->{title}, artist => $ep->{program}, album => 'RTRFM 92.1',
                 cover => $ep->{image}, duration => $ep->{duration} };   # keep EPISODE duration
    return $meta unless $client && $ep->{tracks} && $ep->{tracks}[0]{start};
    $client = $client->master;
    my $song = $client->playingSong;
    return $meta unless $song && API::plainUrl($song->currentTrack->url) eq API::plainUrl($url);
    my $pos = Slim::Player::Source::songTime($client) || 0;
    my ($cur, $next) = API::trackAt($ep->{tracks}, $pos);     # pure function -> unit-testable
    if ($cur) { @$meta{qw(title artist album)} = ($cur->{title}, $cur->{artist}, "$ep->{program}: $ep->{title}") }
    Slim::Utils::Timers::killTimers($client, \&_tick);
    Slim::Utils::Timers::setTimer($client, time() + ($next ? $next->{start} - $pos : 30), \&_tick, $url)
        if $client->isPlaying;
    return $meta;
}
sub _tick { my ($client) = @_; $client->currentPlaylistUpdateTime(Time::HiRes::time());
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']); }
```
Do **not** call `$song->duration()` or `$song->startOffset()` for episodes. Seeking and the real progress bar depend on them. The live-stream trick in §5.3 is for live streams only.

---

## 7. Distribution

### 7.1 Repository XML schema (confirmed from code + real files)
Parser (LMS `Slim/Utils/ExtensionsManager.pm` `_parseResponse`): `XMLin(… KeyAttr => {title=>'lang', desc=>'lang', changes=>'lang'}, GroupTags => {plugins=>'plugin', …}, ForceArray => [...])`. Attributes and child elements are interchangeable (XML::Simple). `extensions.xml` uses attributes; SOMA, SXM, RH and WFMU use elements.
Fields read (`_parseXML`): `name`, `url`, `version`, `sha` (lower-cased), `title{lang}`, `desc{lang}`, `changes{lang}` (or plain text), `link`, `creator`, `category`, `icon`, `email`, `path`, `installations`, `target`, `minTarget`, `maxTarget`; plus `details/title{lang}` for the repo name.
- `target` is an OS regex filter (`windows|mac|unix`). Omit it.
- The version filter applies **only if both** `minTarget` and `maxTarget` are present (`if ($version && $entry->{'minTarget'} && $entry->{'maxTarget'})`).
- Categories (DOC): `hardware, information, misc, musicservices, playlists, radio, scanning, skin, tools`. Anything else becomes `misc`.
Real third-party file (SOMA `public.template.xml`, rendered):
```xml
<extensions>
    <details><title lang="EN">SomaFM plugin repository</title></details>
    <plugins>
        <plugin name="SomaFM" version="0.4" minTarget="7.9" maxTarget="*">
            <title lang="EN">SomaFM</title>
            <desc lang="EN">Play radio channels from SomaFM</desc>
            <category>radio</category>
            <icon>https://raw.githubusercontent.com/danielvijge/lms-somafm/main/HTML/EN/plugins/SomaFM/SomaFM_svg.png</icon>
            <url>https://github.com/danielvijge/lms-somafm/releases/download/0.4/somafm-0.4.zip</url>
            <link>https://github.com/danielvijge/lms-somafm</link>
            <sha>24e92551ab96807c16dfb01684c6fb0d3a163632</sha>
            <creator>Daniel Vijge</creator></plugin>
    </plugins>
</extensions>
```
The same entry as the official aggregator emits it (REPO `extensions.xml` l.544): `<plugin name="SomaFM" category="radio" creator="Daniel Vijge" icon="…" installations="695" link="…" maxTarget="*" minTarget="7.9" sha="24e9…" url="…/somafm-0.4.zip" version="0.4"><desc lang="EN">…</desc><title lang="EN">SomaFM</title></plugin>`.

### 7.2 User flow, SHA verification, updates
- UI: **Settings → Manage Plugins** (`SETUP_PLUGINS` = "Manage Plugins"). At the bottom is **"Additional Repositories"**: *"You may add additional third-party extension repositories by entering the URL for the repository below."* (`strings.txt` `SETUP_EXTENSIONS_REPOS[_DESC]`; input `name="repos"` in `HTML/EN/settings/server/plugins_main.html`). Save, tick the plugin, Apply, then LMS asks for a restart.
- Stored in pref `plugin.extensions:repos`. The default repo is `https://lms-community.github.io/lms-plugin-repository/extensions.xml` (ExtensionsManager `%repos`).
- Install: download to `<cachedir>/DownloadedPlugins/<Name>.zip` → `Digest::SHA1` hexdigest compared with the repo `sha` → on a match, `plugin.state:<Name> = needs-install` → extract on restart. On a mismatch the log shows *"digest does not match … will not be installed: expected X, got Y"* (PluginDownloader `_installDownload`).
- Updates: a higher `version` in the repo raises an update notice (the auto-update pref `plugin.extensions:auto` exists). DOC: *"include the version number in the archive's filename, as LMS otherwise might be re-using cached data"*.

### 7.3 Getting into the official repository
REPO `README.md`: *"`include.json` contains a list URLs to plugin repositories … If a plugin author wants his plugins to be included in the default list of extensions in LMS, just add the URL to his repository XML file to this list."* In practice that is a PR against `LMS-Community/lms-plugin-repository` adding your `repo.xml` URL to `include.json` `"repositories"`. A scheduled workflow (`cron: "06 */6 * * *"`) runs `buildrepo.pl`, which:
- fetches every repo XML and **`die`s on invalid XML**, so a broken file blocks everyone;
- strips `installations` and replaces it with stats from `stats.lms-community.org`;
- forces unknown categories to `misc` (or its own `$categoriesMap`);
- merges with `KeyAttr => ['name']`, so **plugin names must be globally unique**;
- if the diff removes ≥ `MAX_REMOVAL_DIFF` (3) lines, it opens a PR instead of pushing.
Radio-station plugins already listed this way include SomaFM, BBCSounds, PlanetRadio, RadioParadise and ARDAudiothek.

### 7.4 GitHub Actions release pattern
Real tag-push workflow (SXM `.github/workflows/release.yml`, trimmed):
```yaml
on: { push: { tags: [ 'v*' ] } }
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with: { ref: main }
    - id: version
      run: echo "version=${GITHUB_REF#refs/tags/v}" >> $GITHUB_OUTPUT
    - run: sed -i "s/<version>.*<\/version>/<version>${{ steps.version.outputs.version }}<\/version>/" Plugins/SiriusXM/install.xml
    - run: |
        mkdir -p package && cp -r Plugins/SiriusXM package/ && cd package
        zip -r ../SiriusXM-${{ steps.version.outputs.version }}.zip SiriusXM/ && cd ..
        echo "sha=$(sha1sum SiriusXM-${{ steps.version.outputs.version }}.zip | cut -d' ' -f1)" >> $GITHUB_ENV
    - run: |
        sed -i "s|<url>.*</url>|<url>https://github.com/paul-1/plugin-SiriusXM/releases/download/v${{ steps.version.outputs.version }}/SiriusXM-${{ steps.version.outputs.version }}.zip</url>|" repo.xml
        sed -i "s|<sha>.*</sha>|<sha>${{ env.sha }}</sha>|" repo.xml
    - run: xmllint --noout Plugins/SiriusXM/install.xml && xmllint --noout repo.xml
    - run: |
        git config user.name github-actions && git config user.email github-actions@github.com
        git add Plugins/SiriusXM/install.xml repo.xml && git commit -m "Update version …" && git push || exit 0
    - uses: softprops/action-gh-release@v2
      with: { files: "SiriusXM-${{ steps.version.outputs.version }}.zip\nrepo.xml" }
      env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
```
Other real variants:
- TIDAL: `on: workflow_dispatch`. Reads the version from `install.xml` (`egrep -o "version>(.*)</version"`), zips, and runs `perl repo/release.pl repo/repo.xml $VER TIDAL.zip $url` (XML::Simple + Digest::SHA; sets `version`, `sha`, `url`). Commits `repo.xml` to main, then `softprops/action-gh-release` with `tag_name: $VER`, which **creates the tag server-side**.
- SOMA: on `main` push and on tags. Renders `install.xml`/`public.xml` from Jinja templates, puts dev builds on `gh-pages`, and creates the release on tags.
- PLEX `publish.yml`: `workflow_dispatch`, `EndBug/add-and-commit` with `tag:`.
**Recommended for SqueezeRTRFM (design)**, because tags cannot be pushed from the container: `on: workflow_dispatch` + `push: {branches: [main], paths: ['RTRFM/install.xml']}`.
- `permissions: contents: write`.
- Read `<version>` from `RTRFM/install.xml`, and skip if release `v$VER` already exists (`gh release view`).
- `(cd RTRFM && zip -r ../RTRFM-$VER.zip . -x '*.DS_Store')`, then `sha1sum`.
- Rewrite `repo.xml` (`version=`, `<url>…/releases/download/v$VER/RTRFM-$VER.zip</url>`, `<sha>`), `xmllint --noout`, commit to main (commit message containing `[skip ci]`).
- `softprops/action-gh-release@v2` with `tag_name: v$VER`, `target_commitish: main`, `files: RTRFM-$VER.zip`.
Keep `repo.xml`'s `minTarget`/`maxTarget` in step with `install.xml`.

---

## 8. Testing

### 8.1 Unit tests outside LMS (real pattern: PLEX)
PLEX layout: `t/ProtocolHandler.t` plus stub modules `t/lib/Slim/{Utils/Log,Utils/Cache,Music/Info,Schema,Control/Request,Networking/SimpleAsyncHTTP,Player/ProtocolHandlers,Formats/RemoteStream}.pm`; `cpanfile` with `Test::More` and `Test::MockModule`; CI is `container: perl:5` → `cpanm --installdeps --notest .` → `prove -lr t`.
```perl
# PLEX t/ProtocolHandler.t
use Test::More; use Test::MockModule;
use lib 't/lib'; use lib '.';
require SqueezePlexHub::ProtocolHandler;     # repo layout, i.e. not Plugins/...
$INC{'Plugins/SqueezePlexHub/ProtocolHandler.pm'} = 'SqueezePlexHub/ProtocolHandler.pm';
my $cacheMock = Test::MockModule->new('Slim::Utils::Cache');
$cacheMock->redefine('get' => sub { my ($self,$k)=@_; return { title=>'CACHED' } if $k eq $key; undef });
is_deeply($returned, ['http://pms:32400/…'], 'explodePlaylist returns clean URL list');
```
```perl
# PLEX t/lib/Slim/Networking/SimpleAsyncHTTP.pm: synchronous fake driven by package vars
our $NEXT_CONTENT = ''; our $NEXT_ERROR;
sub new { my ($class,$ok,$err,$opts)=@_; bless { onSuccess=>$ok, onError=>$err, opts=>$opts||{} }, $class }
sub get { my ($self,$url)=@_; if (defined $NEXT_ERROR) { $self->{_error}=$NEXT_ERROR; return $self->{onError}->($self) }
          $self->{_content}=$NEXT_CONTENT; $self->{onSuccess}->($self) }
sub content { $_[0]{_content} }  sub error { $_[0]{_error} }
```
Notes (**inferred** from how the modules compile):
- Plugin code that uses `main::DEBUGLOG && …` needs `BEGIN { no strict 'refs'; *{"main::$_"} = sub () { 0 } for qw(DEBUGLOG INFOLOG WEBUI SCANNER) }` in the test before `require`.
- The file `Plugins/RTRFM/X.pm` must be mapped to the repo path (the `$INC{…}` trick above), or `t/lib/Plugins/RTRFM` can be a symlink to `../../RTRFM`.
- Keep JSON→item mapping and `trackAt()` pure, and drive them from recorded RTRFM JSON fixtures in `t/data/`.
- Callbacks: call `Plugin::handleFeed(undef, sub { $got = shift }, {})` with the fake HTTP layer primed, then assert on `$got->{items}` keys (`type`, `url`, `play`, `duration`, `items`).
- SXM's alternative (`git clone --branch public/9.0 slimserver` and put it on `@INC`) only does structural checks. Loading real `Slim::` modules needs the LMS bootstrap, so stubs are more practical.

### 8.2 Driving LMS via JSON-RPC
Endpoint: `POST http://<host>:9000/jsonrpc.js` with body `{"id":1,"method":"slim.request","params":["<playerid|''>",[<cmd…>]]}` (LMS `Slim/Web/JSONRPC.pm` `requestMethod`: `$reqParams->[0]` = player, `$reqParams->[1]` = command array). Core's own smoke test (LMS `t/00_smoketest.sh`):
```bash
curl -m1 -sX POST -d '{"id":0,"params":["",["serverstatus"]],"method":"slim.request"}' http://localhost:9000/jsonrpc.js
```
Headless player (SL `main.c`: `-o -` = stdout, `-m <mac>`, `-n <name>`, `-s <server>`):
`squeezelite -s 127.0.0.1 -n rtrfm-test -m 02:00:00:00:00:01 -o - > /dev/null &`
Commands (P = `"02:00:00:00:00:01"`):
| Purpose | params |
|---|---|
| players / server | `["", ["players",0,10]]`, `["", ["serverstatus",0,99]]` |
| plugin loaded? | `["", ["pref","plugin.state:RTRFM","?"]]` (`namespace:pref` syntax in `prefQuery`) → `_p2: "enabled"`; the menu appears in `[P, ["radios",0,100]]` with `cmd: "rtrfm"` |
| (a) top menu | `[P, ["rtrfm","items",0,100]]` → `result.count`, `result.loop_loop[] = {id,name,type,image,isaudio,hasitems}` (add `"want_url:1"` to get string urls) |
| (a) drill down | `[P, ["rtrfm","items",0,100,"item_id:<id from previous loop_loop>"]]`, e.g. `"item_id:1.3"` |
| (b) play item | `[P, ["rtrfm","playlist","play","item_id:<id>"]]` (also `add`/`insert`). For `link` items with `play`, the `play` URL is used |
| play raw URL | `[P, ["playlist","play","https://…mp3"]]` |
| (c) status | `[P, ["status","-",1,"tags:aclKNdrux"]]` → top-level `mode`, `time`, `duration`, `remote`, `current_title`; `playlist_loop[0]` = `{title, artist(a), album(l), remote_title(N), artwork_url(K), duration(d), bitrate(r), url(u), remote(x)}` |
| seek / stop | `[P, ["time", 1800]]`, `[P, ["stop"]]` |
| restart server | `["", ["restartserver"]]` (re-execs on Unix/Docker: `Slim::Utils::OS::Unix::canRestartServer` = 1) |
`item_id` notes: XMLBrowser prefixes an 8-hex **session id** (`a1b2c3d4.0.1`) when the level has no coderefs (`getSID`, l.330–360). Coderef levels give plain `0.1`. Always reuse the `id` from the previous response.
**Code changes need a restart.** LMS has no hot reload: modules load once at `initPlugin`. `plugin-data.yaml` (in cachedir) is rebuilt when the manifest mtime sum, count or server version changes (PluginManager cache checks). No library rescan is needed for OPML plugins. The dev loop is: edit in `<cachedir>/Plugins/RTRFM` (or bind-mount it there), `restartserver` or restart the process, wait for port 9000, re-run the JSON-RPC checks. Use `--debug plugin.rtrfm=debug` for logs in `server.log`.
Running LMS from a git checkout (**inferred**): 9.1 bundles `CPAN/arch/5.38/x86_64-linux-thread-multi`, and `Slim/bootstrap.pm` strips `gnu-` from `archname`, so system Perl 5.38 on Ubuntu can run `perl slimserver.pl --cachedir … --prefsdir … --logdir … --httpport 9000`.

---

## Gotchas

1. **Name consistency:** `Plugins::RTRFM::Plugin` ⇔ install folder `RTRFM` ⇔ repo.xml `name="RTRFM"` ⇔ pref `plugin.state:RTRFM`. A mismatch installs into the wrong folder or never loads.
2. **install.xml without `targetApplication/minVersion`/`maxVersion`** fails with `INSTALLERROR_INVALID_VERSION`. Without `<module>` it fails with `INSTALLERROR_NO_MODULE`. The settings link key is `optionsURL`; `settingsPage` does not exist.
3. **repo.xml:** give **both** `minTarget` and `maxTarget`, or version filtering is skipped. Use a valid `category` (SXM's `<catagory>` typo is silently ignored). `installations` is stripped. Invalid XML makes `buildrepo.pl` `die` for the whole official aggregate, so run `xmllint --noout` in CI.
4. **SHA1 of the exact uploaded zip.** Re-zipping changes the hash (timestamps). Compute it after the final zip and never rebuild that zip. Put the version in the zip filename.
5. **Extraction happens on restart.** After "Apply", the plugin is only `needs-install` until LMS restarts.
6. **No hot reload** of plugin code or strings. Restart LMS after every change.
7. **Never block:** no LWP/sleep in server code. Use SimpleAsyncHTTP with timeouts and always call the OPML `$callback` on error too (SOMA pattern), or the UI spins until the 35 s XMLBrowser timeout.
8. **Coderefs are not serialisable:** keep them out of `Slim::Utils::Cache` and favourites. Use string `favorites_url` + `parser` or PH `explodePlaylist`. A parser returning coderef items needs `nocache => 1` (RH `Parser.pm` comment: "Can't store CODE items").
9. **`type => 'audio'` is a leaf.** To make an episode both playable and browsable (tracklist), use `type => 'link'` + `play => $url` + `items` (RH `_maybeResume`). Don't set `on_select => 'play'` on such wrappers, or touch skins play instead of opening.
10. **Metadata provider precedence:** the first registered matching regex wins, and any non-empty hash suppresses ICY/`wmaMeta` fallback. Return `{}` for URLs you don't own. Keep the live and episode regexes disjoint (RH excludes `stream.` from the episode regex). RadioNowPlaying (≈2.9k installs) may already know a station, but it defers if a provider is already registered, and `Plugins::RTRFM` inits before it.
11. **Sync groups and timers:** use `$client->master`. Key timers by client (`Slim::Utils::Timers::killTimers($client, \&fn)` before `setTimer`). Stop polling when `Slim::Player::Playlist::url($client)` no longer matches or the player is stopped (TuneIn/RP/RH), so you don't hammer RTRFM's API.
12. **Don't touch `$song->duration`/`startOffset` for episodes.** That is for live-stream progress bars only (RH/RNP). Also, core stream-open resets `startOffset`, so RH re-applies it every poll cycle.
13. **Seeking needs bitrate + duration** (LMS derives duration from `Content-Length`). The on-demand host must return `Content-Length` and honour `Range`; VBR seeks are approximate. Old players without HTTPS are proxied by LMS (fine), and self-signed certs fail unless `insecureHTTPS` is on.
14. **Stream title vs track title:** `setCurrentTitle` is what `current_title` and the stream line show. RH calls it **without** `$client` on purpose, because with a client it also fires `playlist newsong` on every update. Bump `currentPlaylistUpdateTime` or the Default web skin won't refresh.
15. **Guard settings with `main::WEBUI`** (not `WEB_UI`). Put `$prefs->init` defaults in the module that reads them. Settings.pm and Plugin.pm both call init in SOMA, which is harmless.
16. **Menu weights and placement:** `menu => 'radios'` puts the plugin in Radio. `is_app => 1` moves it to My Apps. `playerMenu` controls the old button UI only (return `'RADIO'`, or `undef` to hide it from Extras).
17. **Icons:** `install.xml` `<icon>` is relative (`plugins/RTRFM/html/images/icon.png`), but repo.xml `<icon>` must be an absolute URL. A `_svg.png` name makes Material swap in the sibling `.svg`.
18. **item_id stability:** ids are positional (plus a random session prefix on cacheable levels). Tests must walk the menu by names and reuse the returned ids.
19. **Container constraint (this project):** tags cannot be pushed from the container, so the release workflow must create the tag and release (TIDAL-style `workflow_dispatch` or version-bump trigger) with `permissions: contents: write`.
20. **Docker/dev paths:** manual plugin dir is `/config/cache/Plugins/RTRFM` in the official image (`--cachedir /config/cache`). Repo installs go to `/config/cache/InstalledPlugins/Plugins/RTRFM`. If a manual copy and a repo install both exist, the scan finds both. `_readInstallManifests` keys by plugin name, so whichever manifest is read last silently wins. Remove the dev copy before testing a repo install.
