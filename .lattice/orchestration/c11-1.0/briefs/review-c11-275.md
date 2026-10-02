# Review: C11-275 (gate Codex per-process lifecycle hooks on isolated trust proof), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-275**. PR https://github.com/Stage-11-Agentics/c11/pull/535, head `2cd018ef9ea8107eca7c58f0dfb3c34bb95c85e9`, base = merge-base with origin/main (C11-273 journal on main).
- Title `C11-275 Review Astra`. Actor `agent:astra-review-275`. Owner was Codex Luna.
- Plan: the ticket's plan file. Evidence `ev_01M3YKYAGKMP6Y0MW74R8EAEVV`, `ev_01M3YKYGYDD5VRB1XGFYKXXF1D`.
- Recorded ruling: Codex stays on notify (the trust-isolation probe failed on Codex 0.159.3, within ruling D2); per-process hooks stay gated off unless an isolated trust proof passes. Focus: no write to ~/.codex or any tenant config (doctrine); the Codex wrapper (Resources/bin/codex) adds only launch-time, per-process configuration; notify events map to the C11-272 event types with the privacy allowlist; the degraded capability is advertised truthfully (journal/agents JSON and capabilities do not claim hook-level fidelity for Codex); the C11-271 Codex fixtures replay; C11-273's resolution semantics unaffected; tests behavioral.
- When done, send VERDICT and wait.
