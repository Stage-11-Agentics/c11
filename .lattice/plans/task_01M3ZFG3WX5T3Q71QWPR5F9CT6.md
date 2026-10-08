# C11-326: Sandbox agents follow-ups from C11-322: verify-clean token floors, single-kind launch, honest exit codes, Grok mail rerun

Non-blocking follow-ups from the C11-322 reviews (Fable Review 2 at 1065c68e73, Astra Review 1). None leaks a credential or acts on the wrong target in normal use.

1. scripts/sandbox-agent.sh ~711/715 (export ~98): verify-clean re-exports with seat.sh's default floors (Grok 3 h of 6, Codex 72 h), so the verify can itself rotate the token and then report ROTATED and fail with no recovery (stage at 3 h 10 m left, 45-minute proof, down, verify -> FAIL). Fix: --min-hours 0 on verify's export; optionally record expires_at beside each fingerprint.
2. scripts/sandbox-agent.sh ~532: launch uses the comma-list kind validator, so `launch claude,codex` passes and fails in the guest as --type claude,codex. Accept exactly one kind.
3. scripts/sandbox-agent.sh ~112: an empty pattern list exits 1, which search() (~742) would read as FOUND; unreachable today because the self-test dies first, but exit 2 is the honest code.
4. scripts/sandbox-agent.sh ~711/715: 2>/dev/null on the re-export hides the reason (billing mismatch, API down). Capture stderr and print it on failure.
5. scripts/sandbox-down.sh ~28: every down makes two SSH hops for the wipe, agents or not; an unreachable guest costs a 20 s ConnectTimeout before the delete. Skip when the run has no agents.env.
6. Grok mail steps 3/4/6 (C11-257 sign-off) rerun in the sandbox after the seat Grok login's weekly reset (Tue 2026-10-06 10:31 PDT), per the Orchestrator ruling on C11-322.
