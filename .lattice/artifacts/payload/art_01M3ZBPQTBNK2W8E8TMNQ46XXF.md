C11-256 validation: CI is the proof (batch fast rule)

Merged: PR #552 (shared with C11-253), squash 9cd41788261e3a02f32d46e81dd0e5aba18cd96e, landing head 6170a03a737830b8b99c45ec79cad321b181487f. Merge Captain receipt ev_01M3ZB12P8PA9KC6BJ3140KE4P. Review: Astra round-2 PASS ev_01M3ZAN67ARMVVRXQ3FA1DX5C7 (C11-256 wiring unchanged since it passed round 1). Owner validation ev_01M3ZA8YMQ5TWXV3FTEVWZX4MJ.

Ask -> evidence -> result
1. Wire tests/test_codex_wrapper_resume.py into ci.yml -> `.github/workflows/ci.yml` on main, job workflow-guard-tests, step "Validate agent wrapper lifecycle and resume", runs `python3 tests/test_codex_wrapper_resume.py` under `set -euo pipefail` with no continue-on-error, so a failing script fails the job -> PASS (gating by construction).
2. It actually runs in CI -> GitHub Actions run 37070227518 (ci.yml, pull_request, exact landing head 6170a03a73): workflow-guard-tests success; the step executed the script and printed "PASS: Codex wrapper claims before exec and preserves passthrough/argv/exit/signal behavior" -> PASS. Earlier exact-head run 37054627011 (head 34a59fead0) also executed all six scripts green.
3. Peer wrapper tests wired too -> the same step runs test_codex_wrapper_hooks.py, test_claude_wrapper_hooks.py, test_opencode_wrapper_hooks.py, test_pi_wrapper_hooks.py and test_agent_wrapper_interactive_marker.py; all printed PASS/ok lines in run 37070227518 -> PASS.

Scope note: these scripts run in ci.yml on pull_request (Ubuntu, synthetic wrappers), not in the hourly macOS workflow. The Captain confirmed triggers are unchanged (no pull_request_target, no release.yml reference, no dispatch of other workflows).

Routed to C11-292 sign-off: none.

No check contradicts the ask.

Verdict: COMPLETE.