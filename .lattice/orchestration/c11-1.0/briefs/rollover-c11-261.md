# C11-261 rollover (Sonnet)

Read `sonnet-rollover.md` in this directory and follow it. Ticket C11-261, PR #549. Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-261`, branch `c11-1.0/C11-261-groups-validation`, parked head `5968d3640c369ebf8132a39b54a168b654930870`. Atlas tag `c11-261`.

**Scope ruling (Atin):** the performance top-up is deferred to the C11-270 soak at the end of the run (see the latest Orchestrator comment on C11-261). Do not run any performance measurement and do not request a quiet Atlas window.

Your remaining work is the round-2 review's finding 5: rewrite step C4 in `docs/groups-signoff.md` so it tests the carried C11-260 residual exactly. That means browser omnibar text entry in one split, then keyboard split navigation to the adjacent terminal in the same workspace, with the expected terminal-input receipt. Also finish anything the PARKED note lists as unfinished outside performance.

Then push and send `HANDOFF C11-261 REVIEW <head> <PR>` to tab:210, stating that the perf gate is deferred to C11-270 by ruling.
