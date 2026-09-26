# Project Progress

## Currently in flight
**RESUMED 2026-09-26** (paused ~05:10 for stakeholder quota).
- #4 L1 — PR #16: main merged into branch (c21f9ff, t/13 reconciled, check.sh green); runtime verifier resumed.
- #2 F2 — PR #15 (36379cc, CI green): implementer resumed to finish runtime repo-install test + PR description.
- #8 O3 `feat/O3-tracklists`, #10 O5 `feat/O5-show-artwork`: implementers resumed.
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
