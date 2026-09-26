# Master Plan — ondemand

## Goal
From RTRFM → Programs, users pick a show, see episodes whose audio still exists (28-day retention), play an episode
(seekable; favourites work because a `rtrfm://` protocol handler resolves the signed MP3 URL just before playback), and
open its track list. Bonus/stretch: current track shown during episode playback; program artwork/descriptions/current
line-up; full 28-day window for daily shows with episodes lacking audio hidden.

## Contracts (defined in F1 `Util.pm`, resolver created by O1 — do not fork)
- **Episode URL**: `rtrfm://episode/<slug>/<YYYY-MM-DD>[/<HHMM>]` — `slug` = Airnet/rzz slug (never the WP "full
  slug": `drivetime`, not `drivetime/monday`); `date` = Perth calendar date of episode start; `HHMM` = Perth start time
  (needed for Airnet playlist lookups, optional for rzz).
- **Episode metadata cache**: `Util::setEpisodeMeta` / `getEpisodeMeta($slug, $date)` →
  `{slug, date, start ('YYYY-MM-DD HH:MM:SS' Perth), duration (s), title, show, image, description}`. Written by menu
  builders (O2, O5, O6); read by protocol handler (O1, O4) and tracklist code (O3).
- **Resolver**: `Restream.pm` (O1) `resolve($slug, $date, $cb)` → `{url}` | `{unavailable => 1}` | `{error}`. URL
  containing `.mp3?` = available; anything else (e.g. `.mp4?` → 404) = unavailable. O6 reuses it.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| O1 | Episode playback engine: `Restream.pm` rzz resolver + thin `rtrfm://` protocol handler (resolve at play time; seekable; direct + proxied; "no longer available" error; title/show/cover from metadata cache or URL fallback; favourites replay) | M (upper; highest technical risk) | F1 | done |
| O2 | Programs → Episodes browse: `Airnet.pm` (programs, episodes, 28-day window, titles) + `OnDemand.pm` menus emitting `rtrfm://` episode items and filling the metadata cache; empty/error states; caching | M | F1 (integrates with O1 at IC-1) | done |
| O3 | Episode track listings: `Tracklist.pm` (Airnet playlists, `approximateTime` offsets) + episode submenu (Play episode, description, "Track list (N)") | M | O2 (runtime playback also needs O1) | done |
| O4 | Current track during episode playback (position-based metadata, timers at track boundaries) + tracklist in song info | M | O1, O3 | done |
| O5 | Show artwork, descriptions, current line-up from rtrfm.com.au (`Shows.pm`), Airnet fallback | M | O2 | done |
| O6 | Stretch: full 28-day window for daily shows from inferred weekly slots; rzz availability check hiding episodes without audio; just-aired episodes | M | O1, O2 (soft: after O3) | done |

### O1 — playback engine
- **`Restream.pm`**: `GET https://restreams.rtrfm.com.au/rzz?n=<slug>&d=<date>` via `HTTP.pm` (JSON body despite
  `application/javascript`); signed URLs not cached beyond a few seconds.
- **`ProtocolHandler.pm`** (base `Slim::Player::Protocols::HTTPS`; model on core thin handler
  `/opt/lms-dev/server/Slim/Plugin/Podcast/ProtocolHandler.pm`):
  - `scanUrl`: parse rtrfm URL → resolve via rzz → on success `SUPER::scanUrl($mp3Url)` with a wrapped callback that sets
    `$song->streamUrl($mp3Url)` and restores `$track->url` to the rtrfm URL; unavailable/failed → callback with error
    token `PLUGIN_RTRFM_EPISODE_UNAVAILABLE` / `PLUGIN_RTRFM_RESOLVE_FAILED` so the UI shows a message.
  - `new()` uses `$song->streamUrl` unless `redir`. Seeking relies on scan-derived bitrate/duration (128 kbps CBR +
    Content-Length) — verify `canSeek` is true. `isRemote` → 1; `getIcon`.
  - `getMetadataFor`: metadata cache, else URL fallback (title "<Show or slug> – Sat 19 Sep", artist "RTRFM 92.1",
    cover = station icon).
  - Registration already in F1's `OnDemand->init`. **O1 does not edit `OnDemand.pm`.**
- **Tests**: resolver (mp3 → `{url}`, mp4 → unavailable, bad JSON/HTTP error → error); scanUrl flow with stubbed
  `Scanner::Remote`; metadata fallback.
- **Runtime** (JSON-RPC, before O2): `["playlist","play","rtrfm://episode/<slug>/<recent date>"]` plays on DevPlayer;
  `["time",1800]` → status time ≈1800 and audio continues; status shows title/artist; a date >28 days old shows the
  unavailable message without crashing; a favourite of the rtrfm URL replays after `restartserver`; check direct
  streaming (DevPlayer supports HTTPS) and the LMS-proxied path if it can be forced (`mp3StreamingMethod`).

### O2 — Programs → Episodes browse
- **`Airnet.pm`**: programs from `GET …/6RTR/programs` — keep non-null slug and `archived == false`; drop junk ("Add Show
  Name Here"-style, `training`); decode entities; sort by name; cache ~6 h. Episodes from `GET …/programs/<slug>/episodes`
  — keep Perth start date within [today−28, today) (Airnet never lists today); newest first; title = Airnet title or
  "<Show> – Sat 19 Sep" if null; description HTML → plain text; keep duration; cache ~30 min; one episode per date (OQ3).
- **`OnDemand.pm`**: `menuItems` → one "Programs" link. Data-driven builders `_programsFeed`, `_programItem`,
  `_episodesFeed`, `_episodeItem`. Episode items (pre-O3): `type audio`, `url` and `play` = `Util::episodeUrl(slug,
  date, hhmm)`, `on_select play`, `duration`, `line2` (weekday date · time), `description`, `image` =
  `$program->{image}` (undef until O5). Building an episode list writes the metadata cache.
- Empty/error: "No episodes available in the last 28 days" text item; upstream failure → text item with message;
  callback always called.
- **Tests**: fixtures `t/data/ondemand/programs.json`, `episodes-saturdayjazz.json`, `episodes-drivetime.json`; filtering
  (archived, junk, window edges at Perth midnight with UTC server clock), ordering, titles, item shape, cache writes,
  error paths.
- **Runtime**: web UI Radio → RTRFM 92.1 → Programs → Saturday Jazz lists dated episodes (screenshot); after O1 (IC-1)
  selecting an episode plays it.

### O3 — episode track listings
- **`Tracklist.pm`**: `fetch($slug, $start, $cb)` → `GET …/episodes/<YYYY-MM-DD>+<HH>%3A<MM>%3A00/playlists`; keep
  `type == 'track'`; offset = `approximateTime` − episode start (**never** `time`: 12-hour, no am/pm); clamp negatives to
  0; sort; normalise to `{offset, artist, title, release, isLocal}`; cache 24 h (1 h for last 2 days).
- Episode items become `type link` with `play` (rtrfm URL) and a coderef url — **no** `on_select play` on the link
  (gotcha 9). Opening shows: "Play episode" (`type audio`, `on_select play`); description (`textarea`); "Track list
  (N)" with `text` rows "0:03 · Artist – Title (Release)". Empty list / 400 / 404 / failure → "No track list available".
  Tracklist fetched only when an episode is opened.
- **Tests**: fixtures Saturday Jazz 2026-09-19 playlist, Drivetime (12-hour `time` trap), empty playlist, 400 "No such
  episode"; offset maths, row formatting, submenu shape, `play` kept on link.
- **Runtime**: open an episode in web UI → "Track list (N)" rows; episode still plays from row play control and "Play episode".

### O4 — current track during episode playback
- At stream start (PH `onStream`) ensure tracklist cached (start time from metadata cache or URL HHMM).
- `getMetadataFor`: when this episode is playing and a tracklist exists, title/artist from
  `Tracklist::trackAt($tracks, songTime)` (pure), album "<Show> – <date>", cover = episode image; before first track or
  without tracklist → O1 episode metadata.
- One timer per (master) player at the next track boundary → `currentPlaylistUpdateTime` + `newmetadata`; re-arm after
  seek/pause/resume; kill on stop/URL change; never touch `$song->duration`/`startOffset`.
- Song info: TrackInfo provider with episode description + full tracklist.
- **Tests**: `trackAt` boundaries (before first, exactly on boundary, last, unsorted input); timer scheduling with fake
  clock; stop conditions.
- **Runtime**: play episode, seek to 10 s after track 5 start → status title = track 5; seek to 5 s before track 6 →
  within ~10 s title changes to track 6; song info shows tracklist.

### O5 — artwork, descriptions, line-up
- **`Shows.pm`**: POST admin-ajax `action=filter_shows&search=&postTypes[]=show&page=N`, N = 1.. until empty page or
  `data-total-posts` reached; from each `div.tease-show` take slug (href), name (`<h5>`), image (~768w from `srcset`),
  schedule text, hosts, genres; defensive parsing; cache 24 h; drop `training`.
- Program list = WP line-up merged with Airnet by slug (WP names win); `line2` = schedule text; `image`. WP failure or
  empty parse → keep O2's Airnet list.
- Program header: description `textarea` from `post-description` block of `/shows/<slug>/` (`og:image` image
  fallback), fetched lazily on program open, cached 24 h; hosts line.
- Episode items inherit the program image via `$program->{image}` (no episode-builder change).
- **Tests**: HTML fixtures (page 1, last page, empty page 5, entity names, missing `srcset`); Airnet merge; fallback.
- **Runtime**: program list shows artwork + schedule lines in Default skin (Material if installed); screenshot.

### O6 — full 28-day window + availability (stretch)
- Infer weekly slots from Airnet episode starts (weekday → HH:MM, ≥2 observations); after-midnight shows dated by Perth
  start date; synthesise missing dates in [today−28, today]; include today only after slot end + ~10 min.
- Check every candidate (Airnet or synthesised) with `Restream::resolve`, bounded concurrency (~4), cache 24 h available
  / 1 h unavailable; hide unavailable; on check error keep and flag in line2.
- Synthesised episodes: title "<Show> – Sat 19 Sep"; start from slot; duration from slot/siblings; tracklist tried at
  inferred start, else "Track list not yet available".
- **Tests**: slot inference (weekly, Mon–Fri, after-midnight, irregular → no synthesis); window edges; availability
  filtering; cache TTLs; concurrency cap.
- **Runtime**: Drivetime lists ~20 episodes over ~4 weeks and the oldest plays; nothing >28 days; cold menu load < ~10 s
  (well inside XMLBrowser's 35 s timeout).

## Integration points
- **F1**: hook API (`OnDemand->init`, `OnDemand->menuItems`); `rtrfm` handler registration; `HTTP.pm`; `Util.pm`
  contracts; test harness.
- **IC-1 (O1 + O2)**: browse → play in web UI, seek, favourite replay (criterion 2). **IC-2 (O3)**: track lists (criterion 3).
- **Live stream**: ondemand supplies metadata only via the protocol handler's `getMetadataFor`; never registers
  RemoteMetadata providers matching `live.rtrfm.com.au`.
- **`OnDemand.pm` builder ownership**: O2 creates; O3 `_episodeItem` + submenu; O5 `_programsFeed`/`_programItem`/header;
  O6 `_episodesFeed`.
- **Strings** (pre-seeded by F1 in O1–O6 sections): `PLUGIN_RTRFM_PROGRAMS`, `PLUGIN_RTRFM_PLAY_EPISODE`,
  `PLUGIN_RTRFM_TRACKLIST`, `PLUGIN_RTRFM_NO_TRACKLIST`, `PLUGIN_RTRFM_TRACKLIST_PENDING`, `PLUGIN_RTRFM_NO_EPISODES`,
  `PLUGIN_RTRFM_EPISODE_UNAVAILABLE`, `PLUGIN_RTRFM_RESOLVE_FAILED`, `PLUGIN_RTRFM_HOSTED_BY`,
  `PLUGIN_RTRFM_AVAILABILITY_UNKNOWN`.
- **F3**: README usage + `scripts/smoke.sh` cover browse, play, tracklist.

## Out of scope
- Podcasts/mixes (Mixcloud/SoundCloud); global `search_playlists` track search; program search; flat "Latest
  episodes"; browse by day.
- Resume from last position; "play from this track" (need start offsets in PH) — candidate follow-ups.
- Favouriting program menus (coderef menus); episodes >28 days (deleted upstream); downloading/caching audio; second
  same-date episode of a show (rzz can't address it).

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| OQ1 | Signed URL `e` expiry isn't enforced today; seeks reuse `$song->streamUrl` without re-scan. If RTRFM enforces ~10 s expiry, seeks 403. Handle now or document? | Document + clear error; O1 looks for a cheap re-resolve hook but no workaround for an unenforced rule. | O1 |
| OQ2 | Until O5, program list = Airnet `archived:false` (may include a few off-air shows). OK? | Yes. | O2 |
| OQ3 | `multipleEpsOnDay`: keep first episode per date? | Yes; log others. | O2 |
| OQ4 | Tracklist row format; show "WA" local marker? | "m:ss · Artist – Title (Release)"; WA marker optional. | O3 |
| OQ5 | One show-page scrape per program open (cached 24 h) acceptable load? | Yes. | O5 |
| OQ6 | Hide or flag episodes without audio? | Hide when rzz says unavailable; flag when check fails. | O6 |
| OQ7 | List today's just-aired episode before Airnet metadata exists? | Yes, synthesised title + "tracklist pending". | O6 |

## Changelog
- 2026-09-26 — Initial master plan (stream-planning sub-agent); accepted by orchestrator, defaults applied.
- 2026-09-26 — Spec-writing refinements (issues #6–#11, verified against live endpoints): (1) Default skin never shows
  `line2`, so O2 puts the date in the episode `name`; O5 schedule verified with `menu:1` and repeated as a header item.
  (2) O3 renders "pending" for episodes flagged `synthetic`; O6 only sets the flag (no O3 code edits). (3) O4 adds one
  line to `OnDemand->init` to register its song-info provider (protocol handler loads lazily). (4) O5 builds the program
  header via a new `_programMenu` wrapper around `_episodesFeed` (which stays O6's). (5) O2 fixes contracts: 
  `Airnet::episodes` returns unfiltered data + pure `filterWindow`; feed callbacks are `{items=>[…]}`; program/episode
  hash shapes defined. (6) New file `EpisodeWindow.pm` (O6) and token `PLUGIN_RTRFM_LOAD_FAILED` (O2, own section).
  Measured retention ≈29 days; Airnet returns HTTP 500 for unknown slugs.
- 2026-09-26 — O1 merged. Runtime note for O4 (#9): status `current_title` can stay empty for a whole play if a
  controller polls during the ~5 s scan (LMS per-player title cache stores the empty pre-scan title under the
  rtrfm URL). Web UI / `playlist_loop` titles unaffected. O4 should refresh the title (e.g. `setCurrentTitle` /
  `newmetadata`) once metadata is known. Review nit for O6 (#11): move `filterWindow`/empty check inside
  `_respond`'s eval in `_episodesFeed`.
- 2026-09-26 — Stream complete: all tasks merged (see PROGRESS.md for PRs); v1.0.0 released.
