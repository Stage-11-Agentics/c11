# Review: C11-261 (workspace groups: 50/60-workspace validation and numbered sign-off script), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-261**. PR https://github.com/Stage-11-Agentics/c11/pull/549, head `990f443566de1a277907deeea5415409166e362c`, base = merge-base with origin/main. Six files, all test, fixture, script and doc (no Swift).
- Title `C11-261 Review Astra`. Actor `agent:astra-review-261`. Owner is Codex Sol.
- Validation: ev_01M3YZQ7BSXPV3QNARZGH4SWQ7 and ev_01M3YZRKA6BGKJCQTSB8PA41PC.
- **Release blocker carried here from C11-259/260:** the groups performance gate at the 60-workspace scale. Verify it was measured on Atlas at a current-main build, against a matched control, on a quiet machine with load recorded, and that the result meets the ticket's threshold, or is reported as unmet with numbers. Never accept "within noise" without the noise figures.
- C11-260's review left rulings for this ticket (header unread follows suppression; perf watch points; dead code). This PR has no Swift changes: confirm each ruling was either verified as already satisfied on main, with evidence, or routed somewhere explicit. Silence is a finding.
- The sign-off script is something Atin will run by hand at C11-292: numbered steps, each with an observable expected result, safe to rerun, never touching the operator's real session or running c11 (tagged build, `C11_QA_LAUNCH`, its own socket). Fixtures contain no home paths or identity.
- The scale test (994 lines) must assert behavior, not source shape, and must be runnable through the documented entry point on Atlas.
- When done, send VERDICT and wait.
