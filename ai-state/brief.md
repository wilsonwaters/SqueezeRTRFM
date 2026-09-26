# Project Brief — SqueezeRTRFM

_Agreed brief for the orchestrated build. Source: stakeholder request (Wilson Waters), 2026-09-26._

## What we're building

A **Lyrion Music Server (LMS, formerly Logitech Media Server / Squeezebox Server) plugin** that lets
Squeezebox users listen to **RTRFM 92.1** (Perth community radio, <https://rtrfm.com.au/>):

1. **Live stream** — play RTRFM's live digital stream from the LMS "Radio" menu.
2. **On-demand episodes** — browse RTRFM programs and their past episodes, and play/re-stream episode
   audio (the MP3s the RTRFM website loads in the browser).
3. **Track listings (bonus)** — show the track names from each episode's show listing/playlist, and,
   where the data allows, "now playing" show/track info for the live stream and during episode playback.

## Users

- The stakeholder, running LMS at `http://pi14.alintech.com.au:9000/` (Raspberry Pi) with Squeezebox players.
- Other LMS users who want RTRFM — they must be able to **install the plugin easily** (no manual file copying).

## Platform & tech constraints

- LMS plugin in **Perl**, namespace `Plugins::RTRFM`, built on `Slim::Plugin::OPMLBased` (standard LMS
  pattern for radio/podcast plugins). Target current LMS releases (9.x, with 8.x compatibility where free).
- Must work in the stock LMS web UI (Default skin) and ideally Material skin / hardware players too
  (OPML menus give this for free).
- Data comes from RTRFM's public website/API as used by their browser client; no private credentials.
- Repository: <https://github.com/wilsonwaters/SqueezeRTRFM> (Apache-2.0 licence, already present).

## Distribution ("install easily")

- Publish a **third-party LMS repository XML** (`repo.xml`) in the GitHub repo, pointing at a versioned
  plugin zip with its SHA1, so users add one URL under *Settings → Manage Plugins → Additional Repositories*
  and install/update from the LMS UI.
- Automate packaging (zip + sha1 + repo.xml) so releases are repeatable; document how to later submit to
  the official LMS-Community plugin repository.
- README with clear installation and usage instructions.

## Success criteria (definition of done)

1. On an LMS instance with the plugin installed, the RTRFM live stream **plays audio** on a player.
2. The LMS **web interface** shows an RTRFM menu with a **listing of programs/episodes**, and selecting an
   episode plays it.
3. Episode **track listings** are visible in the menu (bonus: live "now playing" metadata).
4. A user can install the plugin via the repository URL in LMS settings.
5. Automated tests + independent review pass; runtime verification on a real LMS instance passes.

## Environment & verification (adapted to this session)

- Work runs in a Claude Code cloud container. The stakeholder's LMS (pi14) is **not reachable** from the
  container (egress proxy blocks plain HTTP on :9000), so runtime/system verification runs against a
  **local LMS + squeezelite instance inside the container** (see `ai-state/RUNBOOK.md`). The stakeholder
  performs final acceptance on pi14.
- Because the stakeholder cannot start servers inside the container, a dev-environment sub-agent owns
  starting/stopping the local LMS (deviation from the orchestrator manual's "user starts the dev env" rule).
- No `gh` CLI: the board is GitHub Issues/PRs driven through the GitHub MCP tools.

## Out of scope

- Other radio stations; RTRFM's non-audio content (news, events, gig guide, memberships).
- Writing back to RTRFM (accounts, favourites sync, donations).
- Transcoding or caching audio on the LMS server beyond what LMS does natively.

## Timeline

Single orchestrated session, driven to completion.
