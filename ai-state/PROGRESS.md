# Project Progress

## Currently in flight
**RESUMED 2026-09-26** (paused ~05:10 for stakeholder quota).
- #9 O4 → PR #20: runtime PASS; review REQUEST_CHANGES (major: track list TTL expires mid-episode for recent shows; major: polls cancel boundary notifications; minor: onStream position after seek/advance) → fix agent running.
- #11 O6 `feat/O6-28-day-window` (stretch): implementation dispatched in parallel.
- Next: F2 review + runtime verify; merge L1 → dispatch L2; merge O3 → dispatch O4, O6; release v0.1.0 after F2.

## Issue map
| Task | Issue | Stream | Size | Depends on |
|---|---|---|---|---|
| F1 | #1 | foundation | M | – |
| F2 | #2 | foundation | M | #1 |
| F3 | #3 | foundation | M | #2, #5, #8 (+#9–#11) |
| L1 | #4 | live | S | #1 |
| L2 | #5 | live | M | #4 |
| O1 | #6 | ondemand | M | #1 |
| O2 | #7 | ondemand | M | #1 |
| O3 | #8 | ondemand | M | #7 (+#6 runtime) |
| O4 | #9 | ondemand | M | #6, #8 |
| O5 | #10 | ondemand | M | #7 |
| O6 | #11 | ondemand | M | #6, #7 (soft #8) |

## Last 5 completions
- 2026-09-26 — #5 L2 merged (PR #18, squash f8f34ef): review REQUEST_CHANGES → fixed (no re-push churn with stream2 queued; polls recover), title-callback approved; runtime PASS (show name/artwork/slot/next in Now Playing, never blank, Show info, light polling, ondemand + other stations unaffected). Live stream complete.
- 2026-09-26 — #10 O5 merged (PR #19, squash edbaef3): review APPROVE (orchestrator merged main, fixed t/38 for O3's link rows, added 768w + sort tests), runtime PASS (46-show line-up with artwork, program header; cold Programs load 5.6 s).
- 2026-09-26 — #8 O3 merged (PR #17, squash aff0b0d): review APPROVE, runtime PASS; **IC-2 PASS** (track lists visible in web UI, all rows match Airnet) → brief criterion 3 met. **All 5 brief success criteria now met on main.**
- 2026-09-26 — **IC-3 PASS**: v0.1.0 installs from the raw GitHub repo.xml via Settings → Manage Plugins; live + episode play; clean uninstall → brief criterion 4 met.
- 2026-09-26 — #2 F2 merged (PR #15, squash 6c75cc5): review APPROVE. **v0.1.0 released** by `release.yml` (run 36233625445): asset RTRFM-0.1.0.zip sha1 bbf7fc7f… = repo.xml `<sha>` (bot commit 6aaf7e6); re-dispatch (run 36233685343) was a no-op. Follow-ups for F3: RELEASING.md wording on superseded queued runs; optional: read targets from built commit.
- 2026-09-26 — #4 L1 merged (PR #16, squash d716ecf): review APPROVE, runtime PASS on merged-with-main c21f9ff (both streams play, on-air/next matches site, favourite survives restart, 1.75 s cold menu).
- 2026-09-26 — #7 O2 merged (PR #14, squash 4cb41ec): review APPROVE, runtime PASS; **IC-1 PASS** (web UI browse → play episode → seek → favourite replay after restart) → brief criterion 2 met.
- 2026-09-26 — #6 O1 merged (PR #13, squash 1cb1cbb): review APPROVE (leak + cover(0) fixed pre-merge), runtime PASS (play, seek 1800, fallback metadata, unavailable handling, favourite after restart, direct + proxied).
- 2026-09-26 — #1 F1 merged (PR #12, squash a8c59ba): review APPROVE (4 minor findings fixed pre-merge: anchored URL validation, 25 s hook timeout, $cb outside eval, Playlist stub), runtime PASS (stream1 plays via JSON-RPC and web UI).
- 2026-09-26 — All 11 task specs published to issues #1–#11; master-plan changelogs updated with spec refinements.
- 2026-09-26 — Streams + master plans accepted (`ai-state/streams.md`, `ai-state/streams/*/master-plan.md`); 11 issues filed.
- 2026-09-26 — Local LMS 9.1.1 + squeezelite test bed ready (`ai-state/RUNBOOK.md`); RTRFM stream1 (HE-AAC) plays on DevPlayer; test-bed lock added.
- 2026-09-26 — RTRFM research merged (`ai-state/research/rtrfm-api.md`).
- 2026-09-26 — LMS plugin architecture research merged (`ai-state/research/lms-plugin-architecture.md`).
- 2026-09-26 — Brief written (`ai-state/brief.md`).

## Next 3 to dispatch (in order)
- Review + runtime verification for each wave-1 PR as it opens
- IC-1 (O1+O2 browse→play) after both merge; release v0.1.0 via workflow after F2 merges
- Wave 2: #5 L2 (after #4), #8 O3 + #10 O5 (after #7)

## Active blockers
- None. (pi14 unreachable from container — final acceptance by stakeholder; see OPEN-QUESTIONS §2.)
