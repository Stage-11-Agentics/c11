# Fix-forward: C11-251 stale CLI window-scope test (hourly CI red)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-251fix`; tab title `C11-251 Fix Luna`.

Hourly CI on main has been red since C11-251 merged (4994d7fce3). Run 37080441663, step "SSH shell command availability", fails `tests/test_cli_window_scope.py:654`. That C11-283 test expects `--window B set-status` with caller env A to land on B's selected workspace. C11-251's contract now refuses targetless or window-only sidebar writes (not_found, nothing written). The test is stale; the product is right. Details: the latest Validator comment on C11-251.

- Worktree: `git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b c11-1.0/C11-251-hourly-fix /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-251-fix origin/main` (fetch first).
- Update only that test's v1 sidebar block to the C11-251 contract: with env A and `--window B` alone, expect not_found and no write; with `--workspace <B's workspace>`, expect success on B. Do not weaken any other assertion. Check the rest of `tests/` for other tests asserting the old window-only fallback, and update those the same way.
- Run the changed test file the way the hourly step runs it (read `.github/workflows/ci-hourly.yml`), on Atlas if it needs the app. Time-box 30 minutes.
- Open a PR on C11-251 and send `HANDOFF C11-251 REVIEW <head> <PR> <evidence>` to tab:210. After merge, the Orchestrator dispatches ci-hourly.yml.
