# Seat: Flaky Tests Grok (C11-314)

Read `grok-owner.md`, `owner-common.md` and `go-owner.md`. Actor `agent:grok-flaky`. Worktree: `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-fixtures` (the C11-286 WIP is pushed on its own branch; leave it). New branch `c11-1.0/C11-314-delete-flaky-tests` from origin/main.

Atin's ruling: delete flaky tests rather than fix them. Plan just in time (a short plan via `lattice plan write`), then delete exactly the cases the run recorded as flaky: the WorkspaceRemoteConnectionTests timing/relay cases (evidence on C11-306), MessagesPageTests.testWriterMaxWaitRunsDuringSteadyTraffic, and any other test the run recorded as flaky (search run-state.md and ticket comments for "flake"). Keep a deterministic non-timing test of the same behavior only if one already exists. No product code changes. Prove: logic suite on Atlas WITHOUT the two exclusions passes. Open the PR at handoff.
