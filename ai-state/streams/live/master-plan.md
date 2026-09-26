# Master Plan — live

## Goal
From the RTRFM menu users play the FM simulcast (`https://live.rtrfm.com.au/stream1`, AAC+ 64 kbps) and RTRFM Infinite
Mix (`/stream2`, AAC+ 96 kbps). While stream1 plays, LMS shows the on-air show (name, artwork, time slot, next show),
updating at show changes. Live track-level data does not exist (ICY/SHOUTcast titles always empty, no track endpoint —
research §4b), so show-level metadata is the ceiling.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| L1 | Live menu: FM simulcast + Infinite Mix items with "On air: <show> · <time>" / "Next: …" lines; stream-URL discovery with safe fallback; `NowPlaying.pm` fetch/parse/cache | S | F1 | planned |
| L2 | Live now-playing metadata: RemoteMetadata provider+parser for stream1 (show name, artwork, slot, next show); per-player polling scheduled at show changes; push to UIs; song info with description + next show; static metadata for stream2 | M | L1 | planned |

### L1 — live menu
- **`NowPlaying.pm`**: `fetch($cb)` → `GET https://rtrfm.com.au/wp-admin/admin-ajax.php?action=get_current_and_next_show`
  via `HTTP.pm`; response uncached upstream → cache plugin-side until `next.startTime` (min 60 s, max 15 min).
  `parse($json)` (pure) → `{current => {name, slug, start, end (epoch), timeText, image, description, link}, next => {...},
  streamUrl}`; tolerates missing `current`/`next`, `success:false`, HTML entities.
- **`Live.pm` `menuItems`** → two items, both `type audio`, `on_select play`:
  - "RTRFM 92.1 Live" — line2 "On air: Saturday Jazz · 9.00am – 11.00am"; description = show short_description + "Next: …".
  - "RTRFM Infinite Mix" — static.
  - Favourites use a stable stream URL + station icon (`favorites_icon`). stream1 URL = API `stream_url` if it matches
    `^https?://live\.rtrfm\.com\.au/`, else the `Util` constant.
  - Menu returns within ~3 s: serve from cache, wait briefly for a fetch, else fall back to static items without line2.
    An API outage never breaks the menu.
- **Tests**: fixtures `t/data/live/now-next-*.json` (normal, no `next`, `success:false`, entity-encoded names, changed
  `stream_url`); item shape, fallback paths, requests via `HTTP.pm`.
- **Runtime**: web UI shows both items with on-air line; both streams play on DevPlayer (`mode=play`, time advancing);
  a favourite saved from the menu replays after LMS restart.

### L2 — live now-playing metadata
- **Registration**: `LiveMetadata.pm` registered from `Live->init`: `registerProvider` + `registerParser` for
  `^https?://live\.rtrfm\.com\.au/stream[12]`; parser returns 1 (suppresses empty ICY titles). stream2 gets static
  metadata (title "RTRFM Infinite Mix", artist "RTRFM 92.1", cover = station icon). Regex must not overlap ondemand
  URLs (`rtrfm://`, `restreams.rtrfm.com.au`).
- **Polling**: provider returns cached metadata immediately; while a player (master for sync groups) plays stream1, one
  timer per player: next poll at `next.start` + ~60 s; 30 s after error; 5 min when no `next`. Kill timers when the
  player stops or `Slim::Player::Playlist::url` no longer matches. All players share one upstream fetch via the
  `NowPlaying` cache.
- **Push sequence** (research §5.3): `setCurrentTitle($url, $line)` (no client) → `$song->pluginData(wmaMeta => {...})`
  → `$client->currentPlaylistUpdateTime(...)` → `notifyFromArray($client, ['newmetadata'])`.
- **Fields** (LQ2): title = show name; artist = "RTRFM 92.1"; album = time slot + " · Next: <show> <time>"; cover = show
  thumbnail, fallback icon.
- **Song info**: `Slim::Menu::TrackInfo` provider shows show description + next show while stream1 plays.
- Do **not** set `$song->duration`/`startOffset` (progress bar out of scope, LQ3).
- **Tests** (fake clock/timers): first provider call triggers fetch; reaching `next.start` re-fetches + `newmetadata`;
  error backs off 30 s; polling stops on stop/URL change; sync groups use master; no leaked timers.
- **Runtime**: play stream1; `status` `playlist_loop[0].title` = current show (matches rtrfm.com.au now playing),
  `artwork_url` set; Default skin Now Playing shows the show; clean `server.log`. Show-change transition covered by unit
  tests (runtime would mean waiting hours).

## Integration points
- **F1 hook API**: L1 implements `Live->menuItems`, L2 registers from `Live->init`; neither edits `Plugin.pm`.
- **Shared helpers**: `HTTP.pm` (UA, JSON), `Util.pm` (Perth time, stream-URL constants).
- **Provider precedence**: `Plugins::RTRFM` initialises before RadioNowPlaying (ASCII order), which defers to existing
  providers; keep regex away from ondemand URLs.
- **Strings** (pre-seeded by F1 in L1/L2 sections): `PLUGIN_RTRFM_LIVE`, `PLUGIN_RTRFM_INFINITE_MIX`,
  `PLUGIN_RTRFM_INFINITE_MIX_DESC`, `PLUGIN_RTRFM_ON_AIR`, `PLUGIN_RTRFM_NEXT`, `PLUGIN_RTRFM_SHOW_INFO`.
- **Foundation**: F3 documents live behaviour; `scripts/smoke.sh` checks live playback.

## Out of scope
- Live track titles (no source) and ICY parsing; show progress bar / listen-delay pref (candidate follow-up);
  "streams down" switch detection; port-8000 PLS URLs; `rtrfm://live` pseudo-URL; schedule/program grid.

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| LQ1 | Hardware players: https stream (LMS proxies for non-HTTPS players, Pi CPU cost) or `http://live.rtrfm.com.au/stream1`? | https (site's own `stream_url`); revisit if stakeholder's players struggle. | L1 |
| LQ2 | Show data → title/artist/album mapping. | As in L2. | L2 (non-blocking) |
| LQ3 | Progress bar for elapsed time within show? | Out of scope. | L2 |
| LQ4 | Non-AAC players rely on LMS `faad` transcoding — acceptable? | Yes; README troubleshooting (F3). | L1 (non-blocking) |

## Changelog
- 2026-09-26 — Initial master plan (stream-planning sub-agent); accepted by orchestrator, defaults applied.
- 2026-09-26 — Spec-writing refinements (issues #4, #5): Default skin shows the on-air line only on the item detail
  view (line2 visible in Material/menu mode); 3 s menu deadline, 20 s fetch back-off, 60–900 s poll clamp, 300 s poll
  when `current`/`next` missing; album text uses "·" separator.
- 2026-09-26 — L1 review finding: `HTTP.pm` logs every failed request at WARN (foundation, append-only), so "one WARN
  per run of failures" can't be met by callers. Decision: L2 (#5) adds an additive, caller-controlled failure log level
  option to `HTTP.pm` (e.g. `quiet => 1` → DEBUG) — flagged in its PR — and switches `NowPlaying.pm` to use it.
- 2026-09-26 — L2 scope additions (orchestrator): HTTP.pm `quiet` option adopted by NowPlaying; fix blank live
  title (`current_title` " " from empty icy-name) via a `Slim::Music::Info` title-change callback (public API, reviewed:
  stable LMS 8.0–9.2, scoped to live URLs — KEEP). Review REQUEST_CHANGES: churn when [stream1, stream2] both queued
  (re-push every ~1.3 s under Jivelite subscribe) and stuck poll state after async `_fetched` death / forgetTimer —
  fix agent dispatched.
