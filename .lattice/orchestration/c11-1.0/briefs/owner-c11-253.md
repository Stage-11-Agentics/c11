# Owner: C11-253 (backlog-review admission, Atin approved 2026-10-02)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (you may be on Sol rather than Luna; everything else applies).

- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-253`, branch `c11-1.0/C11-253-ci-host-gate` (on current origin/main). Provision submodules and GhosttyKit before the first build.
- Actor `agent:sol-253`; tab title `C11-253 Sol`; `lattice assign` and link the branch first. The ticket is in backlog: move it backlog → in_planning → planned → in_progress as you go.
- Read the ticket and its plan (`lattice show C11-253`); the plan is a stub from triage. Re-check every claim against current main (much has merged today), write a concise plan with `lattice plan write`, then implement. No separate plan review.
- This seat owns **C11-253 and C11-256** together (one owner, two PRs or one, your call; C11-256 gets its own branch from origin/main if separate). Make the c11Tests host CI step gating again: triage the 44 failures (real regression vs environment vs obsolete), fix real ones or route them to their owning ticket via DECISION, quarantine the rest behind a named, commented skip list in the workflow (never silent). Prefer deleting obsolete or flaky tests (Atin's standing rule). Wire tests/test_codex_wrapper_resume.py into CI (C11-256). Do not trigger release.yml. Workflow edits must keep fork PRs safe. Fits beside C11-314/315, which are merged.
- Atlas builds only under tag `c11-253` (one tag per ticket). Push only at handoff. Then `HANDOFF C11-253 REVIEW <head> <PR> <validation>` to tab:210.
