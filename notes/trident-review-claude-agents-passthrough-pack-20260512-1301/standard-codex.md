## Code Review
- **Date:** 2026-05-12T17:06:30Z
- **Model:** Ucodex (Codex/GPT-5)
- **Branch:** fix/claude-agents-wrapper-passthrough
- **Latest Commit:** 0fdb91e653b37da65dfab68fd83b5859691378b7
- **Linear Story:** claude-agents-passthrough
---

This is a small, targeted fix in `Resources/bin/claude`: the c11 PATH-scoped Claude wrapper now passes through the Agent View command family (`agents`, `attach`, `logs`, `stop`, `kill`, `respawn`, `rm`) instead of injecting c11's synthetic `--session-id` and hook `--settings` into those argv shapes.

The architectural direction is right. Agent View commands operate against Claude Code's per-user supervisor and background session pool, while c11's wrapper rail is surface/session scoped. Treating those commands like fresh foreground sessions corrupts the command contract, especially for id-bearing forms such as `claude attach <id>` and `claude logs <id>`. The change preserves c11's unopinionated-terminal boundary: it does not write tenant config and does not alter Claude's supervisor state beyond letting the real CLI see the original argv.

Runtime flow after this branch:

1. The wrapper confirms it is inside a c11 terminal with a live socket.
2. It resolves the real `claude` binary outside `Resources/bin`.
3. It checks the first argv token against the passthrough command set.
4. Agent View commands immediately `exec "$REAL_CLAUDE" "$@"`.
5. All other supported foreground Claude sessions continue through `unset CLAUDECODE`, `c11 set-agent`, hook settings, and optional synthetic `--session-id` injection.

Validation note: I did not run the rubric's `git fetch`/`git pull` because the handoff forbids writes other than this review file, and fetch/pull mutate `.git`. I also did not run local tests because this repo's project policy says never to run tests locally. I reviewed the branch against the local `origin/main` ref plus the supplied PR/CI context. The supplied CI snapshot has build, build-ghosttykit, web-typecheck, workflow-guard-tests, and remote-daemon-tests passing, with compat-tests still pending at capture time.

### Blockers

None found.

### Important

1. ❓ **Agent View passthroughs skip the wrapper's `CLAUDECODE` cleanup.** In `Resources/bin/claude:125`, the new Agent View passthrough arm executes before `unset CLAUDECODE` at `Resources/bin/claude:133`. That was already true for older administrative passthrough commands, but this branch adds `agents` and `attach`, which are interactive/supervisor-facing Claude Code entry points. If Claude Code applies nested-session detection to those commands, c11-launched panes that inherited `CLAUDECODE` from a parent Claude session may still get refused or warned. I could not validate this empirically without launching real Claude Code Agent View. The cheap hardening is to move `unset CLAUDECODE` above the passthrough `case`, or unset it inside the passthrough arm when `IN_C11=1`.

2. ✅ **The existing wrapper test harness does not cover this new passthrough behavior.** `tests/test_claude_wrapper_hooks.py:126` through `tests/test_claude_wrapper_hooks.py:185` verifies hook injection and stale/missing socket behavior, but it never exercises first-token passthrough commands on a live c11 socket. This branch changes exactly that argv-classification behavior. A meaningful regression test is available without grep-style source assertions: use the existing fake real `claude` harness, invoke `claude agents` and one id-bearing command such as `claude attach 7c5dcf5d`, and assert the real binary receives the original argv with no `--session-id` or `--settings`. That would catch the bug class this PR fixes.

### Potential

3. ❓ **`claude --bg ...` remains on the injection path and should be consciously triaged.** The Agent View docs describe `claude --bg "<prompt>"` as the shell entry point for launching a background session, but this branch only handles top-level subcommands. If `--bg` sessions are also supervisor-owned and detached from the current c11 surface, injecting surface-scoped hooks and a synthetic session id may be surprising or wrong. The supplied context frames this PR specifically as a subcommand fix, so I would not block this change on `--bg`; I would track it as a follow-up decision.

4. ⬇️ **Upstream coordination should be recorded.** `Resources/bin/claude` is part of the wrapper pattern that overlaps with upstream cmux, and the project notes ask agents to flag non-c11-specific fixes that would benefit `manaflow-ai/cmux`. The supplied context already mentions upstream issue `manaflow-ai/cmux#4005`; add a PR note or follow-up saying whether this exact diff should be offered upstream. This is a process item, not a code defect.

Overall: I would ship this after either validating item 1 against Claude Code 2.1.139+ or moving the `unset CLAUDECODE` line above the passthrough case as a low-risk defensive cleanup. The functional core of the PR is correct and narrowly scoped.
