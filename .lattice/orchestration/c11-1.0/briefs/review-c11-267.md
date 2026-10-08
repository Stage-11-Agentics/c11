# Review: C11-267 (send input-state inspection and draft/dialog guard; RISK LIST), cycle 1

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-267 Review Astra`. Actor `agent:astra-review-267`. Owner: Claude Sonnet (rolled over from Codex Luna).

- PR https://github.com/Stage-11-Agentics/c11/pull/565, head `84ce7088d7b1f7953580d51b65b7d16e509ccfed`, base = merge-base with origin/main. Ticket C11-267 (acceptance 1-5) and the Orchestrator's DECISION (default-refuse; chain `c11 send ... && c11 send-key ... enter` everywhere it is taught; refusal text says nothing was sent and do not press Enter; prove no false refusal on this fleet's traffic).
- Validation: the validation comments (unit 24/24 at head; real-app Atlas matrix with a real Claude chooser, auto-suggest and draft; older server unguarded; latency). The owner states two gaps: scrolled viewport and a real Codex prompt are not proven at runtime.
- This is the transport every agent in this fleet uses. Treat a false refusal on a Codex prompt (including one showing queued 'messages to be submitted') or on Claude's faint auto-suggest as release-blocking. The real-Codex gap must be closed before merge, not deferred. Acceptance 3 (active screen even when scrolled up) must be proven or explicitly covered by a test that drives the scrolled state.
- Check: draft contents never leave the app (only a length); cold/unattached tabs return unknown, not empty; the check-to-use race is documented with no "atomic safe" claim; no polling or input capture; `send-key` semantics unchanged; `--allow-unguarded` explicit; all docs and skill examples chained; typing paths untouched.
- Break the guard and confirm a test goes red.
- Reply `VERDICT C11-267 PASS|FAIL <head> <artifact>` to tab:210.
