# Review: C11-268 (Feed: explicit guarded text replies and answer-bearing flag lowering; RISK LIST), cycle 1

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-268 Review Astra`. Actor `agent:astra-review-268`. Owner: Codex Luna.

- PR https://github.com/Stage-11-Agentics/c11/pull/576, head `f6bdab0b67518098e229d96c82c970bfaff5fefc`, base = merge-base with origin/main. Ticket acceptance 1-5 (`lattice show C11-268`). Validation ev_01M3ZV4279YD601SFS7R42GXSS. The owner states unproven: live Claude (by Orchestrator ruling, covered through C11-267's recorded real-Claude fixtures plus real Codex), the post-paste close race, and the final full test run (being added now).
- Focus: `c11 feed answer` reuses C11-267's input guard exactly (no second classifier) and refuses draft, dialog, unknown and stale targets with nothing typed; question, plan and permission rows are rejected; a successful flag reply emits exactly one `flag.lowered` with the text and correct `by` attribution and never lowers a replaced flag; queued, failed or unconfirmed submission is never reported as answered, and the result lets callers avoid duplicate pastes; answer text only in the documented local event channel, never the analytics journal; it delivers to a background tab without selecting it and its "open the tab" fallback respects C11-323's gate; multiline is one submission; docs chain `send && send-key`.
- Break the guard path and confirm a test goes red.
- Reply `VERDICT C11-268 PASS|FAIL <head> <artifact>` to tab:210.
