# Project Progress

## Currently in flight
- Wave 1 implementation agents (parallel worktrees): #2 F2 `feat/F2-packaging`, #4 L1 `feat/L1-live-menu`, #6 O1 → PR #13 (under review + runtime verification), #7 O2 → PR #14 (under review; runtime verifier also running IC-1 on a local O1+O2 combination).

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
