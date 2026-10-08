C11-361 completion (Orchestrator). PR #624 merged 22786494a8 at head f96fa397d1, rebased onto C11-360 with a semantic conflict in MarkdownWebRenderer resolved; Opus attested the rebase.
Reviews:
- Opus Review 1 FAIL: unmounted and evicted panels returned not_ready; open-external stole focus.
- Grok Review 2 FAIL: an unresolvable --panel ref acted on the focused panel.
- Repair c428aefca8: Opus and Grok verify PASS.
Gate: Atlas exact-head compile plus c11LogicTests (2689 tests). Drawbridge (dry-run) is not a gate. Skill synced by the captain.
Follow-up: the shared resolver's focused-panel fallback for unresolvable refs remains in DebugHandlers (low severity); see run-state.
