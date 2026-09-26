# Open Questions

_Unresolved product/technical decisions and what they block. Resolved items move to the bottom with the decision._

## Open

_(none yet)_

## Resolved / decided by orchestrator (stakeholder may override)

1. **Human gates collapsed** (2026-09-26) — The stakeholder asked for the build to be orchestrated to
   completion in one session. The orchestrator records its decisions here and in `brief.md` instead of
   blocking on sign-off at the streams/plan gates. Stakeholder can override any decision below.
2. **Runtime test bed** (2026-09-26) — pi14 (`http://pi14.alintech.com.au:9000/`) is unreachable from the
   cloud container (egress proxy: no plain HTTP, CONNECT to :9000 → 502). Verification uses a local LMS +
   squeezelite in the container. Final acceptance on pi14 is the stakeholder's.
3. **Git workflow** (2026-09-26) — Stakeholder allowed direct commits to `main`. `ai-state/` and scaffolding go
   straight to `main`; feature tasks go through PRs (branch → review agent → merge) per the methodology.
