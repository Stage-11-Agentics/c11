# C11-274 repair (Luna takeover), round 1

You take over C11-274 from a Grok owner at its clean pushed head `a80794899f5293dac2dc271814b9fecb32062d66` (branch `c11-1.0/C11-274-claude-hooks`, worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-producers`, PR #533). Keep its commits; repair on top.

Fix all blocking findings in Astra's review `ev_01M3YK2KMJ34KEDS2511TG1RB6` (`lattice show C11-274`), using the reviewer's smallest fixes:
1. Keep C11-273's ordered (synchronous) PostToolUse callback for AskUserQuestion|ExitPlanMode; only ordinary PostToolUse may be async and bounded. Add the answer → Stop-before-resolution regression for both blocking tools.
2. One bounded observer path covering authentication, owner lookup and append within the 250 ms budget; on timeout or lock contention keep the structural draft via the existing spool and return neutral output; no blocking session-store flock on this path. Atlas must exercise a connected-but-silent peer and a held state lock.
3. StopFailure folds to error per plan AC2 (allowlisted native name, reasonCode=sessionFailure); fix the test that asserted the opposite.
Read the remaining findings in that review too and fix any other blocking ones. Atlas targeted tests and the fixture replay, push, `HANDOFF C11-274 REVIEW <head>`.
