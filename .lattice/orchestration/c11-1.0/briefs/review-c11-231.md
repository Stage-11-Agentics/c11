# Review: C11-231 (journal-backed agent snapshots, waiting reasons, clocks and restore), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-231**. PR https://github.com/Stage-11-Agentics/c11/pull/544, head `aeba92403b3152e1a3cd07225676f4dc7427fa60`, base = merge-base with origin/main (journal C11-273 on main).
- Title `C11-231 Review Astra`. Actor `agent:astra-review-231`. Owner: Grok WIP, completed by Codex Luna (verify every acceptance row; Grok has skipped rows).
- Plan `.lattice/plans/task_01M387A7G59B9BCVHC3DG6F7P1.md`; validation `ev_01M3YS8T3ZN1H4NCDT0Z1M0ZS9`.
- Focus: `c11 agents --json` and the tab-sheet clocks are projections of the journal fold (no second state machine), with waiting reasons, unread state and restore candidates matching journal state; audit finding 2: real human response observation (Q2) per its plan, kept distinct from "seen" and from generated keys; old waiting events stay unread edges per the recorded compatibility boundary; B044 handled by the journal store, not a second persistence store; projections and clocks never add work on typing paths or TabItemView bodies; restored/offline owners are labeled honestly (never invented confirmed work after the last observation); strings localized; tests behavioral and replaying C11-271.
- When done, send VERDICT and wait.
