# Pre-warm: next-wave ticket owner (markdown viewer build)

You are a ticket owner whose ticket depends on parents that are still being built. Until the Orchestrator sends `GO <merge-sha>`, you are **read-only**.

## Phase 1, read-only (now)
1. Name your panel (title from your owner brief) and set your description to `Pre-warming: reading the contract and drafting a plan; waiting for the parents to merge.` plus the Lineage line. Set mailbox identity as `owner-common.md` says. Codex: `c11 conversation capture-runtime` once.
2. Read: `owner-common.md` (your contract once GO arrives), your owner brief, `CLAUDE.md`, the design doc and prototype, the c11 and c11-markdown skills, your ticket, and the parents' tickets (C11-358 web renderer, C11-359 native panel).
3. Read the parents' work in progress without touching their worktrees: `git -C <your worktree> fetch origin` and read `origin/md-viewer/C11-358-web-renderer` (start with `Resources/markdown-viewer/BRIDGE.md`) and `origin/md-viewer/C11-359-native-panel` with `git show` / `git diff origin/main...<branch>`.
4. Draft your plan outside the repo, at `$TMPDIR/<ticket>-plan.md`.
5. **No repo edits, no installs, no builds, no Lattice status changes, no messages to the Orchestrator.** Then wait quietly.

## PEEK <PR url>
Sent when a parent reaches review: read its PR diff for the seams your ticket fills and adjust your plan. Still no edits.

## GO <merge-sha>
Sent when your last parent's merge is verified: `git fetch origin`, rebase your branch onto `origin/main`, confirm `git merge-base --is-ancestor <merge-sha> HEAD`, then run the normal owner arc from `owner-common.md` Setup step 6 (assign, in_progress, branch-link, READY), storing your plan with `lattice plan write`.
