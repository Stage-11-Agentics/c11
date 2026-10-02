# Review: C11-269 (reset claude-teams SIGPIPE, stop persistent OpenCode plugin installation), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-269**. PR https://github.com/Stage-11-Agentics/c11/pull/517, head `bbe2e2500a57239b68f334aa243c02e496f7e5f0`, base = merge-base with origin/main.
- Title `C11-269 Review Astra`. Actor `agent:astra-review-269`. Owner was Codex Sol (the owner's own Codex check does not count as this review).
- Plan `.lattice/plans/task_01M3X3WRXD0V83MKS46ZCJ4QM0.md`; validation `art_01M3XQNKVSQFQRGECP3678SVRS`. CI pending.
- Doctrine is the main axis (read CLAUDE.md "unopinionated about the terminal"): after this PR c11 makes **no persistent write** under `~/.config/opencode/*` or any agent tool's config; any per-process hook goes only through launch-time env/args; existing users' previously installed plugin is handled as the plan says (no silent deletion of user files unless the plan and rulings allow it) and the Settings UI copy matches the new behavior (localized). SIGPIPE: claude-teams children start with default SIGPIPE so closed pipes end them normally, without changing c11's own handler. Tests behavioral; no source-grep tests.
- When done, send VERDICT and wait.
