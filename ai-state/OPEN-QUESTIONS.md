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
4. **Git proxy limits** (2026-09-26) — From the container, pushing branches/commits works, but pushing tags and
   deleting remote branches is refused, and the GitHub MCP has no "create release" tool. Releases must therefore
   be cut by a GitHub Actions workflow (workflow_dispatch or version-bump trigger) using `GITHUB_TOKEN`.
   A probe branch `feat/push-probe` (identical to `main` at 71a09c1) could not be deleted — stakeholder can
   delete it in the GitHub UI.
5. **Commit authorship** (2026-09-26, stakeholder instruction) — All commits, PRs and issues are authored as
   Wilson Waters <wilsonwaters@users.noreply.github.com> with no tool/vendor attribution trailers or footers.
   The first 11 commits on `main` after the initial commit (71a09c1 … 0701d66) were made under a different author
   with attribution trailers; correcting them requires rewriting `main` and a force-push, which is left to the
   stakeholder to authorise or perform. PRs are squash-merged with an explicit clean commit message.
