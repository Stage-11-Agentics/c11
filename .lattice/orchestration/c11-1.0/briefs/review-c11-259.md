# Review: C11-259 (workspace groups: folder model, persistence, CLI, atomic batch reorder), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-259**. PR https://github.com/Stage-11-Agentics/c11/pull/504, branch `c11-1.0/C11-259-workspace-groups`, head `3dc6383906a883f8dbd0ad77e76ddb05cfa24689`, base = merge-base with origin/main.
- Title `C11-259 Review Sol`. Actor `agent:codex-review-259`. Owner was Astra.
- Plan `.lattice/plans/task_01M3X3Q706AHNBFJT4AW4F07NE.md`; validation `ev_01M3XFRQFY52DF3MJ0HQHP6NJH`, artifact `art_01M3XFPM8P78G2S0GGH5308G7M` (tagged runtime on Hyperion). The comparative performance run against a main build is still pending (Atlas); list exactly what it must show.
- Atin rates workspace groups the most careful testing of the release. Focus hard on data integrity: persistence and restore round-trip (old snapshots without groups load unchanged; groups survive save/restore; no workspace lost or duplicated on any reorder/ungroup/delete path), atomic batch reorder (all-or-nothing, no partial state on a bad request), CLI semantics and errors, and that nothing here adds work to typing hot paths or the sidebar body beyond what the plan names. Tests must be behavioral.
- When done, send VERDICT and wait; the Orchestrator may send a delta re-review.
