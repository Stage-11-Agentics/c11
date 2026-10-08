# Review: C11-273 (journal append, SQLite store, pure fold, bounded replay), cycle 1 — Fable

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Claude Fable in Claude Code: **read-only**, no subagents of any kind, no edits, no builds or tests on this Mac.

- Ticket **C11-273** (risk list, critical path: the Feed, producers and consumers build on it). PR https://github.com/Stage-11-Agentics/c11/pull/527, head `8c6cd8d881779f14722da2c1ad937afde391f403`, base = merge-base with origin/main.
- Title `C11-273 Review Fable`. Actor `agent:fable-review-273`. Owner was Codex Astra.
- Contract: the attested spec C11-272 (`.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`) and this plan (`.lattice/plans/task_01M3X3XPNP88K5250NDJPYK02S.md`). Evidence: latest validation comment and `docs/validation/c11-273/README.md`. Orchestrator ruling on the ticket: the performance comparison was invalid on both sides (probe failure) and is a named residual for the end-of-run soak, not blocking here.
- Read `docs/aar-c11-188-attention-loop.md` first. Blocking signatures: epochs, fences, markers, coordinators or other mechanism beyond the attested spec; "fail closed everywhere" claims.
- Focus: (1) the fold is pure and matches the spec's state machine, replaying C11-271's real fixture corpus to the recorded oracles (blocked-or-unread, sibling isolation, bypass asks); (2) append and SQLite writes never run on main or block a socket/telemetry path (socket threading policy); bounded replay and storage growth, and corruption or schema-mismatch handling degrades to "no journal" without crashing; (3) integration with C11-263's attention repair keeps its behavior (sibling clears, bypass waiting, flags in the menu bar); (4) no tenant config writes and no transcript or prompt text stored beyond the spec's allowlist (privacy); (5) tests behavioral.
- When done, send VERDICT and wait.
