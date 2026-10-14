# Topic 05: Upstream bug-fix sweep

**Report path:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep.md`

Atin: "Investigate all the bug fixes and see if there's anything we want to pull over." This is the bug-oracle sweep. It goes wider than the 12 items in the landscape doc, which are only a grep-level starting point.

Method:

1. **Enumerate** upstream fixes since the fork (`53910919`, 2026-03-18): "Fixed" changelog entries from v0.63.0 through Unreleased, plus merged PRs whose titles or labels say fix, crash, hang, leak, livelock, regression or race. Expect several hundred.
2. **Filter** to code paths c11 still shares with cmux: Ghostty embedding and terminal surfaces, PTY sizing, Metal and rendering, the socket and CLI, session autosave and restore, the sidebar, focus, IME and keyboard, the browser, notifications, memory and CPU. Drop fixes to features c11 does not have (cloud, iOS, vault, diff viewer and so on), but count them.
3. **Verify** each survivor against c11 source. Is the buggy code still present in c11, already fixed differently, or diverged so far that the bug cannot occur? Read the upstream diff, then the matching c11 code. Use subagents to fan out by subsystem, and keep the verdicts yourself.
4. **Cross-reference** c11's own known problems: `~/Projects/Stage11/code/c11/notes/` (the 2026-08-25 freeze and deadlock, the 2026-07-28 hang, restart recovery) and open c11 bugs in its Lattice board, if `lattice` works there read-only. Note any upstream fix that explains one.

Output: a ranked table with these columns: bug · upstream PR(s) · subsystem · c11 status (`shared-confirmed`, `shared-probable`, `already-fixed`, `n/a-diverged`) · severity for Atin's use (many agents, many workspaces, long sessions) · port difficulty (S/M/L) · recommendation (`port`, `reimplement`, `watch`, `skip`). Put the top ten first with a paragraph each. End with the full counts: enumerated, filtered out, verified, and confirmed.

Take the time this needs.
