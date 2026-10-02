# Review: C11-294 (abortable Ghostty mailbox waits + the 1.0 terminal patch set), cycle 1 — Fable

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Claude Fable in Claude Code: **read-only**, no subagents of any kind, no edits, no builds or tests on this Mac.

- Ticket **C11-294**. PR https://github.com/Stage-11-Agentics/c11/pull/507, head `e2af4cb60cfb89b4369da0be979100ac1d0931bc`, base = merge-base with origin/main. This PR moves the `ghostty` submodule pointer (and maybe a pinned libxev); review the submodule range too: `git -C <review checkout>/ghostty log --oneline <old>..<new>` and its diff.
- Title `C11-294 Review Fable`. Actor `agent:fable-review-294`. Owner was Codex Astra.
- Plan `.lattice/plans/task_01M3X6K1QPK3S6ZW46E38NG432.md`; validation comment on the ticket plus artifact `art_01M3XJZDS8YEQ2ZT6XQJ15FX0T` (native and tagged runtime runs with documented limits). CI and the GhosttyKit checksum flow are still pending; the captain gates on them.
- Focus, in order: (1) mailbox waits are actually abortable/bounded on teardown and cannot deadlock or use-after-free a surface (the 08-25 freeze root and the bug ledger rows the plan maps to this ticket); (2) each ride-along patch is clean, minimal, attributable, and matches its incident; deviations from BACKLOG H-A (queue stays 64, omitted ride-alongs) are recorded honestly; (3) the B072 libxev nonblocking write path handles WouldBlock without an unconditional queue pop; (4) submodule safety: the new ghostty SHA is on `Stage-11-Agentics/ghostty` main, `docs/ghostty-fork.md` updated, no detached/orphaned commits; (5) no new main-thread work on typing hot paths (forceRefresh, hitTest); (6) the runtime evidence covers what the plan's acceptance names, and what is honestly left as a residual.
- C11-188 guardrail applies: concrete failures only, no new mechanism.
- When done, send VERDICT and wait.
