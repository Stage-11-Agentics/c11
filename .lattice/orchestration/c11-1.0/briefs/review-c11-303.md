# Review: C11-303 (stop scroll updates from laying out every window), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-303** (risk list: runtime proof before merge). PR https://github.com/Stage-11-Agentics/c11/pull/543, head `8213e1185f3c3227ca856c09c4e6559d92de2d37`, base = merge-base with origin/main (C11-294 Ghostty patch set and C11-302 wakeup coalescing on main; it shares Ghostty view hunks with them).
- Title `C11-303 Review Astra`. Actor `agent:astra-review-303`. Owner: Codex Luna, finished on Sol.
- Plan: the ticket's plan file. Evidence `ev_01M3YS5P9FDH6R0FYVQFEVCTVQ` (risk-list tagged runtime proof).
- Focus: a scroll update in one surface invalidates only that surface's layout (no window-wide or all-windows layout pass); the last scroll position always renders (no stale scrollbar after coalescing); no new main-thread work per keystroke or per frame (CLAUDE.md: forceRefresh allocation-free, no display link or manual draw loop, hitTest guard); scrollbar drag still works (C11-302's named residual is a sign-off item; do not regress it further); no use-after-free against C11-294's teardown; the runtime proof measures the incident (layout counts or main-thread time with many windows) on a tagged build; tests behavioral.
- When done, send VERDICT and wait.
