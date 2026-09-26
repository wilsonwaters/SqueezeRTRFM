# Handoff — SqueezeRTRFM v1.0.0

_2026-09-26. Final summary for the stakeholder. Status: **delivered, awaiting acceptance on pi14**._

## What was built

A Lyrion Music Server plugin, **RTRFM 92.1**, in the Radio menu:

| Area | What the user gets |
|---|---|
| Live | **RTRFM 92.1 Live** (FM simulcast, HE-AAC) and **RTRFM Infinite Mix**. The menu shows "On air / Next". While live plays, Now Playing shows the on-air show name, artwork, time slot and next show (refreshed at show changes); track info has "Show info". RTRFM publishes no live track titles, so show-level is the ceiling. |
| Programs | rtrfm.com.au's current line-up (46 shows) with artwork and time slots. A program page shows description, schedule, hosts, then every episode RTRFM still holds (~28 days). Daily shows are filled out beyond Airnet's last 11 episodes using inferred weekly slots, and unavailable audio is hidden. |
| Episodes | Play, seek and favourite. The signed MP3 is resolved at play time, so favourites keep working until RTRFM deletes the audio. The episode submenu has "Play episode", notes and "Track list (N)" (e.g. "3:00 · Chris Foster – Looking Sideways (In Motion)"). During playback Now Playing follows the track list and changes at each track boundary. |
| Install | Add `https://raw.githubusercontent.com/wilsonwaters/SqueezeRTRFM/main/repo.xml` under Settings → Manage Plugins → Additional Repositories, tick RTRFM 92.1, Apply, then restart. Updates arrive the same way. |

## Brief success criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | Live stream plays | F1/L1 runtime checks; final system verification (clean profile, v1.0.0) |
| 2 | Web UI lists programs/episodes; selecting plays | IC-1 (browse → play → seek → favourite); final system verification |
| 3 | Track listings visible (+ bonus now playing) | IC-2 (all rows match Airnet); L2 live show metadata; O4 current track |
| 4 | Install via repository URL | IC-3 (v0.1.0) and final system verification (v1.0.0 from GitHub on a clean LMS profile) |
| 5 | Tests + independent review + runtime verification | Every PR was reviewed and runtime-verified; 321 unit tests in CI; `scripts/smoke.sh` 9/9 |

## Where things live

- **User docs:** `README.md` (install, usage, Now Playing, favourites, known limitations, troubleshooting), `CHANGELOG.md`, `docs/official-repository.md` (how to get listed in the official LMS repository).
- **Maintainer docs:** `RELEASING.md`. To release, bump `<version>` in `RTRFM/install.xml` on `main`; the release workflow builds, publishes and updates `repo.xml`, committing as Wilson Waters.
- **Acceptance test:** `scripts/smoke.sh <lms-url> <player-mac>`, e.g. `scripts/smoke.sh http://pi14.alintech.com.au:9000 <mac>`. It needs bash, curl and jq, and briefly plays audio on that player.
- **Quality gate:** `scripts/check.sh` (compile, 321 tests, XML and strings lint, package checks, shellcheck). CI runs it on every PR.
- **Project record:** `ai-state/` (brief, streams, master plans, progress log, open questions, runbook, research).

## Known limitations (also in the README)

- No live track titles, because RTRFM doesn't publish them.
- Episodes are kept about 28 days and appear about 6 minutes after airing. Airnet details and track lists can lag by hours or up to a day.
- A weekday on which a show aired only once in its recent episodes may not be listed for older weeks.
- The first open of a program takes about 8–12 s on slow links (show page plus availability checks), then it's cached for 24 h.
- Only tested on LMS 9.1.1 with squeezelite and the Default web skin. The plugin claims LMS 8.0+ and should work in Material and on hardware players (standard OPML menus), but that is untested here.

## Actions for you

1. **Accept on pi14:** install from the repo URL (above), then optionally run `scripts/smoke.sh` against pi14. Your server couldn't be reached from the build container.
2. **Delete leftover branches** in the GitHub UI (the container couldn't delete remote branches): `feat/push-probe`, `evidence/O1-playback`, and the merged `feat/*` branches.
3. **Optional:** submit to the official LMS plugin repository (see `docs/official-repository.md`).
4. **Optional follow-up:** #22 (fetch show page and episodes concurrently for shows without line-up artwork).
5. **Git history:** the first 11 commits on `main` (71a09c1…0701d66) still carry the earlier author and trailers. Rewriting them needs a force-push that this environment blocked. See OPEN-QUESTIONS §5.
