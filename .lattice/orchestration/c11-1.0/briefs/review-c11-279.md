# Review: C11-279 (reject misspelled routing keys instead of hitting the focused tab), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-279**. PR https://github.com/Stage-11-Agentics/c11/pull/508, head `eb80662004cc3ed10db3013374598511074931d0`, base = merge-base with origin/main.
- Title `C11-279 Review Astra`. Actor `agent:astra-review-279`. Owner was Codex Sol.
- Plan: the ticket's plan file. Validation on the ticket (6 Atlas tests; tagged worker/main rejection; alias PTY delivery). CI pending.
- Scope (audit note 13): an upstream-sized check covering normalized selector spellings only; `surfce_id`-style typos outside that list remain undetected, and docs must not claim general typo safety. Focus: a misspelled or non-canonical routing key in a socket request is rejected with a clear error instead of silently routing to the focused tab; canonical keys and documented aliases (including the C11-248 vocabulary aliases) still work; the `routing.canonical_keys` registry feature is enabled; no change to C11-257's send/mailbox behavior beyond key validation; tests behavioral.
- When done, send VERDICT and wait.
