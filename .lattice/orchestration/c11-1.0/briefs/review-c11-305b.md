# Review: C11-305 fix-forward (ShellGitWatcherTests cleanup), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-305** fix-forward. PR https://github.com/Stage-11-Agentics/c11/pull/521, head `cca7b3e085264743e63b43967d3840290bae7bdc`, base = merge-base with origin/main. Test-fixture-only.
- Title `C11-305b Review Astra`. Actor `agent:astra-review-305`. Owner was Codex Sol (its own Codex check does not count).
- Validation `ev_01M3XTVBDDMYHBHQ56XBYV33AG`. Incident: GitHub CI run 36980318254, os.killpg PermissionError in cleanup at tests/test_shell_git_watchers.py:129.
- Focus: teardown tolerates an already-exited/reaped process group without masking a real leak (the helper's exit is still asserted independently and a surviving helper still fails the test); no production change; no sleep-based flakiness added.
- When done, send VERDICT and wait.
