# Master Plan — foundation

## Goal
Deliver an installable, tested, releasable RTRFM plugin:
1. First merge puts **"RTRFM 92.1"** in the LMS Radio menu with a playable live stream, frozen hook points for the
   live/ondemand streams, shared HTTP/time helpers, and a test harness + CI.
2. Second task makes installation a one-URL operation (GitHub-hosted `repo.xml`, automated releases).
3. Last task ships v1.0.0 with user docs, an official-repository guide, and a scripted acceptance smoke test.

## Tasks

| ID | Summary | Size | Depends on | Status |
|---|---|---|---|---|
| F1 | Installable skeleton: Radio-menu entry with playable stream1 item; frozen hook API + module stubs; `HTTP.pm`, `Util.pm`; unit-test harness; `scripts/check.sh`; CI | M (upper; review plan like an L) | – | planned |
| F2 | Packaging & distribution: zip+sha1 build script, `repo.xml`, release workflow (tag + Release + repo.xml update via `GITHUB_TOKEN`), CI package checks, README install section; cut v0.1.0 | M | F1 | planned |
| F3 | v1.0.0: README usage/troubleshooting, official-repo guide, `scripts/smoke.sh` JSON-RPC acceptance test, CHANGELOG, version bump → release, clean-LMS install from repo URL + smoke pass | M | F2, L2, O3 (+O4/O5/O6 if shipped) | planned |

### F1 — installable skeleton, shared helpers, harness

**Plugin files**
- `RTRFM/install.xml`: module `Plugins::RTRFM::Plugin`; name/description string tokens; version `0.1.0` (unreleased);
  `targetApplication` minVersion `8.0`, maxVersion `*` (FQ2); category `radio`; defaultState `enabled`; icon
  `plugins/RTRFM/html/images/icon.png`; homepageURL = GitHub repo; creator.
- `RTRFM/Plugin.pm`: `Slim::Plugin::OPMLBased`, `tag => 'rtrfm'`, `menu => 'radios'`, weight; `getDisplayName` →
  `PLUGIN_RTRFM` ("RTRFM 92.1"); `playerMenu` → `RADIO`; log category `plugin.rtrfm`. Implements the hook API from
  `streams.md` (async join: Live items then OnDemand items; a dying hook becomes an error text item, never a hang).
- Stubs: `Live.pm` (`init` no-op; `menuItems` → one item "RTRFM 92.1 Live", `type audio`, url
  `https://live.rtrfm.com.au/stream1`, `on_select play`, station icon); `OnDemand.pm` (`init` registers `rtrfm` →
  `Plugins::RTRFM::ProtocolHandler`; `menuItems` → `[]`); `ProtocolHandler.pm` (empty package, base
  `Slim::Player::Protocols::HTTPS`).
- `HTTP.pm`: `getJSON($url, $cb, $ecb, \%opts)` and `postFormJSON(...)` over SimpleAsyncHTTP. Always sends an explicit
  User-Agent (LMS `userAgentString`), never `libwww-perl/*`; default timeout 15 s; passes `cache`/`expires`; decodes JSON
  in `eval` regardless of content type (rzz answers `application/javascript`); every path calls exactly one callback.
- `Util.pm`:
  - Constants: station name, stream URLs, `rtrfm.com.au` base, Airnet base `https://airnet.org.au/rest/stations/6RTR`,
    rzz base, icon path.
  - Perth time helpers with fixed UTC+8 (independent of server TZ): parse `YYYY-MM-DD HH:MM:SS` and ISO `+08:00`;
    epoch → Perth date/weekday; `perthToday()`; friendly "Sat 19 Sep" format.
  - `decodeEntities`.
  - Episode-URL contract: `episodeUrl($slug, $date[, $hhmm])` → `rtrfm://episode/<slug>/<YYYY-MM-DD>[/<HHMM>]`;
    `parseEpisodeUrl($url)` → `{slug, date, hhmm}` or undef (slug `[a-z0-9_-]+`, real date).
  - Episode-metadata cache contract: `setEpisodeMeta` / `getEpisodeMeta($slug, $date)` (cache namespace `rtrfm`),
    shape `{slug, date, start, duration, title, show, image, description}`.
- `strings.txt`: EN only, per-task sections, pre-seeded tokens — foundation `PLUGIN_RTRFM`, `PLUGIN_RTRFM_DESC`,
  `PLUGIN_RTRFM_ERROR`; plus all live/ondemand tokens listed in those master plans.
- Icon: 512×512 PNG at `RTRFM/HTML/EN/plugins/RTRFM/html/images/icon.png` (FQ1).

**Test harness**
- `t/lib` stubs: `Slim::Plugin::OPMLBased`; `Slim::Utils::{Log,Prefs,Strings,Cache,Timers,Misc}`;
  `Slim::Networking::SimpleAsyncHTTP` (routes URLs to fixtures, synchronous); `Slim::Formats::RemoteMetadata`;
  `Slim::Player::{ProtocolHandlers,Protocols::HTTP,Protocols::HTTPS,Playlist,Source}`; `Slim::Utils::Scanner::Remote`;
  `Slim::Music::Info`; `Slim::Control::Request`; `Slim::Menu::TrackInfo`.
- LMS-bundled non-core modules used by the plugin need a shim or CI install — at least `JSON::XS::VersionOneAndTwo` and
  `HTML::Entities` (missing from system Perl here).
- `main::DEBUGLOG`, `main::INFOLOG`, `main::WEBUI` constants; `Plugins::RTRFM::*` → `RTRFM/*.pm` mapping (e.g.
  `t/lib/Plugins/RTRFM` symlink); `t/lib/RTRFMTest.pm` (fixture loader, fake clock/timers, callback collector).

**Tests**: `t/10-compile.t` (all `RTRFM/**/*.pm` compile vs stubs); `t/11-util.t` (Perth-midnight maths with UTC server
clock; URL contract round-trip + invalid inputs; metadata cache); `t/12-http.t` (UA set, never libwww; bad JSON/HTTP
errors → error callback; POST form encoding); `t/13-plugin-feed.t` (hooks initialised; Live then OnDemand order; dying
hook → error item).

**Quality gates**: `scripts/check.sh` = single middle-loop command: compile check; `prove -lr -It/lib t`;
`xmllint --noout` on `RTRFM/install.xml` (and `repo.xml` once it exists); strings lint (tab format; every
`PLUGIN_RTRFM_*` token used in code is defined). `.github/workflows/ci.yml` runs it on PRs and `main`.

**Runtime demo**: link `RTRFM/` into test-bed LMS, restart; `["pref","plugin.state:RTRFM","?"]` → `enabled`; Default
skin Radio menu shows "RTRFM 92.1" with icon, containing "RTRFM 92.1 Live"; playing it on DevPlayer → `mode=play`,
`time` advancing; no `plugin.rtrfm` errors in `server.log`; screenshot.

### F2 — packaging, repo.xml, automated release
- `scripts/build.sh`: reads version from install.xml; zips the **contents** of `RTRFM/` (install.xml at zip root) into
  `dist/RTRFM-<ver>.zip`; writes `dist/RTRFM-<ver>.zip.sha1`.
- `repo.xml` at repo root: `<extensions><details><title lang="EN">…</details><plugins><plugin name="RTRFM" version
  minTarget maxTarget>` with `title`, `desc`, category `radio`, absolute raw.githubusercontent.com `icon`, `url`
  `https://github.com/wilsonwaters/SqueezeRTRFM/releases/download/v<ver>/RTRFM-<ver>.zip`, `sha`, `link`, `creator`;
  min/maxTarget mirror install.xml.
- `scripts/update-repo-xml.pl` (core Perl only, idempotent): sets version, url, sha.
- `.github/workflows/release.yml`: triggers `workflow_dispatch` + `push` to `main` with `paths: [RTRFM/install.xml]`;
  `permissions: contents: write`. Steps: read version, exit 0 if tag/release `v<ver>` exists; build once and sha1 that
  exact file (never re-zip after hashing); update repo.xml + xmllint; commit repo.xml to `main` with `[skip ci]`
  (rebase/retry on non-fast-forward); create tag + Release server-side (e.g. `softprops/action-gh-release` with
  `tag_name`) and upload the zip asset.
- CI additions: build zip on every PR and check layout (install.xml at root; no `t/`, `dev/`, `ai-state/`, `.github/`);
  xmllint repo.xml; min/maxTarget match install.xml.
- Docs: README (what it is, "unofficial" disclaimer, **Installation**: Settings → Manage Plugins → Additional
  Repositories → add `https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/repo.xml` → tick RTRFM → Apply →
  restart; updating; uninstalling). `RELEASING.md` (bump version on main or run workflow; what it does; permissions — FQ4).
- Verification: (a) local repo install — remove dev link, serve `dist/` + test repo.xml from a localhost HTTP server,
  add in Manage Plugins, install, restart, plugin loads from `cache/InstalledPlugins/Plugins/RTRFM` with Radio entry,
  restore dev link; (b) after merge the orchestrator dispatches the workflow → Release `v0.1.0` with zip asset, repo.xml
  on main has matching version/url/sha (check sha1 of downloaded asset); (c) if egress to GitHub release hosts works,
  test bed installs v0.1.0 from the raw GitHub URL.

### F3 — v1.0.0 release, docs, acceptance
- README: usage tour (Radio → RTRFM 92.1 → Live / Infinite Mix / Programs → Program → Episode → Play / Track list);
  now-playing behaviour and limits (no live track data; 28-day retention; episodes ~6 min after airing; Airnet
  metadata next day); troubleshooting (AAC needs LMS `faad` on older players; raising `plugin.rtrfm` log level;
  "episode no longer available"); test-bed screenshots; compatibility (tested 9.1.x; claims 8.0+).
- `docs/official-repository.md`: how to get listed in `LMS-Community/lms-plugin-repository` (PR adding repo.xml URL to
  `include.json`; prerequisites: unique name, valid XML, stable URL, versioned zip names). `CHANGELOG.md`.
- `scripts/smoke.sh` (bash + curl + jq; LMS URL + player MAC params): plugin enabled; top level has Live + Programs;
  live plays (mode=play, time advances ≥5 s); programs non-empty; first available episode plays and seeks; episode menu
  has "Track list". Must pass on the test bed; stakeholder can run it against pi14.
- Release: bump install.xml to `1.0.0` → workflow publishes v1.0.0; clean LMS profile installs from raw GitHub
  repo.xml; `scripts/smoke.sh` passes.

## Integration points
- **Hook API (frozen in F1)**: consumed by L1/L2 (`Live`) and O1–O6 (`OnDemand`); live items first.
- **`HTTP.pm`**: used by live (now-playing) and ondemand (Airnet, WP, rzz). Contract: explicit non-libwww UA; exactly one
  callback per request; JSON errors → error callback with message.
- **`Util.pm` contracts**: episode URL + metadata cache written by O2/O5/O6, read by O1/O3/O4; Perth time helpers used
  by L1, L2, O2, O6.
- **`rtrfm` handler registration** lives in F1's `OnDemand->init`; O1 only fills `ProtocolHandler.pm`.
- **Test harness** shared by all streams; gaps filled by new stub files.
- **Release workflow** triggers on install.xml version change → feature tasks never bump version.
- **Test bed (`dev/`)**: F1 relies on `$LMS_HOME/Plugins/RTRFM` → `<worktree>/RTRFM`; F2/F3 repo-install tests remove it temporarily.

## Out of scope
- Settings page/prefs; Radio-vs-My-Apps toggle; non-EN languages.
- Actually submitting to the official repository (document only; FQ5).
- CI tests against live RTRFM endpoints (fixtures only); runtime testing on LMS 8.x; gh-pages/dev-build channels.

## Open questions

| # | Question | Default (applied) | Blocks |
|---|---|---|---|
| FQ1 | Icon: RTRFM's own logo (trademark; plugin unofficial) or neutral self-made? | Scale RTRFM's publicly served logo to 512×512 (usual for station plugins); "unofficial, not affiliated" in README; replace on request. | F1 (non-blocking) |
| FQ2 | Claim `minVersion 8.0` without an 8.x test bed? | Yes — APIs unchanged 8.3→9.1 (research §2); README says "tested on 9.1.x". | F1 |
| FQ3 | repo.xml URL: raw `main` or `releases/latest/download/repo.xml`? | Raw `main`. | F2 |
| FQ4 | Actions "Workflow permissions" may make `GITHUB_TOKEN` read-only. | Workflow declares `contents: write`; on 403 stakeholder enables read/write in Settings → Actions. | F2 (release step) |
| FQ5 | Submit to official repo now, or document only? | Document only; stakeholder decides after pi14 acceptance. | F3 |
| FQ6 | Cadence v0.1.0 (F2) → v0.2.0 (IC-3) → v1.0.0 (F3)? | Yes. | F2/F3 |

## Changelog
- 2026-09-26 — Initial master plan (stream-planning sub-agent); accepted by orchestrator, defaults applied to FQ1–FQ6.
- 2026-09-26 — Spec-writing refinements (issues #2, #3): release workflow creates the GitHub Release first, verifies
  the downloaded asset's sha1, then commits repo.xml (repair path if interrupted); committed repo.xml starts with a
  placeholder sha; headless repo install via `scripts/lms-repo-install.sh` (form POST to
  `/settings/server/plugins.html`); PR dry-run of the release build; CHANGELOG-based release notes.
- 2026-09-26 — IC-3 PASS (v0.1.0 installed from the raw GitHub repo.xml via the real Manage Plugins UI; live +
  episode played; clean uninstall). README fixes for F3: "Save" → "Apply"; mention the third-party install
  confirmation popup; list Infinite Mix; keep repo.xml/plugin descriptions consistent with shipped features.
  Also for F3: RELEASING.md wording on superseded queued runs; optionally make release.yml commit repo.xml as the
  repository owner rather than github-actions[bot] (stakeholder authorship preference — confirm).
