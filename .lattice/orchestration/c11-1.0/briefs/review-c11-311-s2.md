# Review: C11-311 slice 2 (B018: clear the observed window on close; P2 tier-2 sweep), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-311**, slice 2. PR https://github.com/Stage-11-Agentics/c11/pull/546, head `0b5f04dbeaf5a39de08c2c35d7308a056d266b70`, base = merge-base with origin/main. Small diff: Sources/ContentView.swift (+6) and c11Tests/WindowAndDragTests.swift (+63).
- Title `C11-311 Review Astra`. Actor `agent:astra-review-311`. Owner was Codex Luna. Owner validation: ev_01M3YXQ20XEPKY8X1W0Q2RCY60.
- Ticket rule: re-find the bug on current main, the trigger is established or explicitly disproved, a missing reproducer is not a fix. Check B018 against the ledger row in the ticket description.
- Focus: the window reference is cleared on every close path (close button, Cmd-W of the last tab, programmatic close, app quit) without touching the typing path (`TabItemView`, `hitTest`, `forceRefresh`); no retain cycle remains; the test goes red when the fix is removed (break it and confirm). As a P2 it must add no risk to the release.
- Earlier slices of this ticket (B078/B080) are merged; review only this PR.
- When done, send VERDICT and wait.
