C11-253 validation: CI is the proof (batch fast rule)

Merged: PR #552 (shared with C11-256), squash 9cd41788261e3a02f32d46e81dd0e5aba18cd96e, landing head 6170a03a737830b8b99c45ec79cad321b181487f. Merge Captain receipt ev_01M3ZB0VJPGBMTPM0EFJ6DJA0T (exact-head logic gate dc84a1b7964143cc86d998d6bc2245f6). Review: Astra round-2 PASS ev_01M3ZAN67ARMVVRXQ3FA1DX5C7 with an independent mutation check that the restored lifetime guard fails (fb083330691b44b49a2f7b09a6bdddf7). Owner validation ev_01M3ZA8YMQ5TWXV3FTEVWZX4MJ / ev_01M3ZA8YS9NWB337MFBZ1RBGMZ; owner exact-head native host run d3ee7be942534f779d6a7787042378d5 (1,583 tests, 0 failures); triage inventory notes/c11-253-host-test-triage.md.

Ask -> evidence -> result
1. Triage the failing host tests (fix, or quarantine with a named skip list) -> notes/c11-253-host-test-triage.md: 47-method baseline, 33 repaired, 6 obsolete deletions, 8 named method quarantines plus 7 unchanged historical class quarantines; all 15 exclusions named and commented in ci-hourly.yml -> PASS.
2. Drop continue-on-error so the host step gates -> ci-hourly.yml "Host-bound unit tests (gate)" on main runs xcodebuild under `set -euo pipefail` with no continue-on-error and no baseline-growth allowance; a failing retained test fails the job -> PASS (by construction, confirmed in review).
3. The gate runs on main after the merge -> GitHub Actions run 37071613801 (CI hourly (macOS), workflow_dispatch on main at 9cd4178826, the merge commit itself): "Host-bound unit tests (gate)" success, all 15 quarantines printed and passed to xcodebuild, Executed 1,570 tests with 0 failures, ** TEST SUCCEEDED **; "Logic tests (gate)" success; run conclusion success -> PASS. The previous hourly runs (22:01 and earlier) predate the merge and are not counted.

Residual native proof, deliberately outside the host gate (named quarantines whose real behavior needs a live surface or real pointer events):
- Guest scenarios 9 and 10: collapsed-divider reopening with a browser portal and with a terminal portal.
- Real-input proof for the three quarantined Ghostty input cases: Shift+Backquote literal tilde, Option+Delete word delete, Korean IME commit plus Return.
- Split-click and first-responder recovery (the two WorkspaceTerminalFocusRecoveryTests quarantines, owner scenario 4).
These are routed to the C11-292 sign-off script; the production pointer, input and focus code is unchanged by this PR.

No check contradicts the ask.

Verdict: COMPLETE with the guest/real-input residuals routed to C11-292.