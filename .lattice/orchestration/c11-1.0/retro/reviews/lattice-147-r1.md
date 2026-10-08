FAIL

LAT-395 / PR Stage-11-Agentics/lattice#147, reviewed 2026-10-05.
Head: `9232862a1fa8324d04a4777cfaa8545976e248e5`.
Base: `7cb18be31ee91a768d4bc3376b16d91b028ccdbf` (verified merge base with `origin/main`).

## Blocking findings

1. **P1 — The new validation-to-done edge lets the dashboard complete tasks without completion evidence.**

   Locations: `src/lattice/core/config.py:246` and `:344`; `src/lattice/cli/migration_cmds.py:383`; consuming handler `src/lattice/dashboard/server.py:878-904`.

   Invariant: every newly allowed `in_validation -> done` transition must satisfy the configured done policy, regardless of entry point.

   Scenario: a task is in `in_validation`, with no review comment or artifact, on a board whose default done policy requires review evidence. After initialization with the new graph, or after `migrate validation-done` on an existing board, `POST /api/tasks/<id>/status` with `{"status":"done","actor":"agent:reviewer"}` returns 200 and persists `done`. The CLI correctly refuses the same task with `COMPLETION_BLOCKED`. The handler validates the graph but never calls `validate_completion_policy`.

   Evidence: a temporary test invoked the production `_handle_post_task_status` handler in-process against a real scratch board and captured its response. With the old edge absent it returned 400. After the real migration, the CLI refused completion, then the handler returned `(200, {"ok": true, "data": {"status": "done", ...}})` and persisted the transition. The task had `comment_count: 0` and no evidence. This is a new reachable bypass: the old graph refused this particular transition. The same handler omission affects fresh stage11 boards, composed workflows, and migrated boards; it skips custom done requirements as well as the default review requirement.

   Smallest fix: apply the same completion-policy validation inside the dashboard's locked mutation callback before emitting the status event, with the context needed by configured policies and the existing force/reason semantics. Add an endpoint regression for no evidence and a positive evidence case. The scratch experiment adding the default policy check made this failing probe pass; the experimental code was restored.

2. **P2 — `lattice complete` still refuses direct completion on composed workflows.**

   Locations: `src/lattice/cli/task_cmds.py:1702-1708`, before the new direct-path logic at `:1785-1791`; `src/lattice/core/config.py:343-344`.

   Invariant: when the current status has a permitted direct edge to done, completion should validate that route and its evidence, without requiring an unrelated review-to-done edge.

   Scenario: use `compose_workflow(include_review=True, include_validation=True, include_pr_open=True)`, as exposed by custom initialization. Its review stage leads to validation, while this PR adds `in_validation -> done`. From `in_validation`, run `lattice complete <task> --review "Review PASS; merged and validated." --actor agent:reviewer --json`. It fails before reaching the new direct-path logic:

   ```json
   {"ok":false,"error":{"code":"INVALID_TRANSITION","message":"Cannot complete: no transition from review to done in workflow."}}
   ```

   Evidence: two parameterized scratch cases failed with this exact output: composed workflows with review enabled and with review disabled, both with validation and pr_open enabled. The early unconditional check requires `review -> done` even though neither direct completion needs it. Existing customized or migrated graphs that omit this skip edge have the same problem. The shipped stage11 preset masks it because that preset separately has `review -> done`.

   Smallest fix: decide the actual route from the authoritative current snapshot first; require `review -> done` only when completion will take that hop. Keep the existing done policy check for both routes. Moving the check behind route selection made both probes pass. The experimental code was restored.

Implementation-level rework needed for findings 1 and 2.

## Non-blocking observations and coverage limits

1. **Hosted-server parity: BLOCKED-ENV / source-scope mismatch.** This pinned PR is Lattice v1 (`pyproject.toml:10`), with no `src/lattice/server/` or `src/lattice/ops/`. `src/lattice/storage/fs.py:242-265` explicitly refuses hosted bindings with `BOUND_CHECKOUT`. Consequently, the brief's hosted-server parity requirement cannot be verified at this head. The dashboard handler tested above is the local v1 HTTP path, not a hosted-v2 server. No hosted parity claim is made; this mismatch is not classified as a new product defect.

2. **The CLI next-step hint still prescribes the pr_open detour.** `src/lattice/cli/task_cmds.py:664-677` tells validation callers “On pass move to pr_open” and emits JSON `next_steps.then: "pr_open"`. The transition itself works on stage11 boards, but the agent-facing hint omits the new merge-first route. Consider exposing both valid routes.

3. **Existing dashboard review-cycle bypass remains.** `src/lattice/dashboard/server.py:878-904` neither checks review-cycle limits nor records `review_cycle`. This predates the PR, so it is not counted as a new blocker. The automatic/manual cycle guarantees verified below apply to the local CLI; do not generalize them to every HTTP mutation entry point.

## Verification

Read the ticket, owner brief, PR description, all 14 changed files, and surrounding transition, policy, persistence, migration, and dashboard code. The PR remained open at the pinned head at final verification. No commits, pushes, PR comments, or ticket-status changes were made.

The intended invariants were: automatic review loops retain the hard limit; other review loops record and warn; existing graph and evidence guards remain effective; direct validation completion respects the configured done policy; migration only adds the intended edge and preserves board data.

- **Touched suite:** `uv run pytest tests/test_cli/test_migrate.py tests/test_cli/test_task_status.py tests/test_core/test_events.py tests/test_core/test_status_presets.py` passed **130 tests** initially and **130 tests in 0.95s** after restoration. Tests used worktree-local scratch directories and had c11 integration environment variables removed. The initial environment lacked dev dependencies; that collection-only setup failure was resolved by installing the worktree's dev dependencies.
- **Author's claimed RED reproduced:** replacing only the changed production modules with their pinned-base versions produced **14 failed, 62 passed** across migrate/status/preset tests, and the separate events file failed collection because `latest_review_auto_fired` did not exist. Two migration reds were fixture `list.remove("done")` failures, so the count alone does not demonstrate migration behavior; the populated probe below supplies that evidence.
- **Hard-limit mutation:** forcing `enforced = False` caused both the existing automatic review rework test and automatic validation rework test to fail because the forbidden transitions succeeded. Restored afterward.
- **Completion-policy mutation:** bypassing the status command's policy refusal made `test_in_validation_to_done_still_needs_completion_evidence` fail because completion succeeded. Restored afterward.
- **Additional invariant probes:** **14 passed**. Ten cases checked automatic/manual behavior for the five permitted rework edges from review, validation, and pr_open; two checked that `pr_open -> in_planning` still returns `INVALID_TRANSITION`. Another checked that `complete` preserves custom validation-role/assignment requirements, refuses without appending events, and removes provisional artifacts. The last checked populated migration preservation.
- **Populated migration:** a scratch board contained task events, a review comment, snapshots, plans, and an unknown nested configuration extension. Dry-run preserved every file byte-for-byte. Apply changed only config.json, semantically adding only the done edge. A second apply reported `changed: false` and preserved every file byte-for-byte. This was sequential migration proof, not a concurrent config-writer test.
- **Finding probes:** three expected-success/refusal assertions failed at the pinned implementation (two composed-completion cases, one dashboard policy case); minimal temporary fixes made all three pass. These experiments demonstrate the findings and are not a submitted patch.
- **Lint:** `uv run ruff check` passed for all changed Python source/test files. Final `git diff --check` and tracked diff were clean.
- **CI:** independently read the pinned PR's successful lint, Python 3.12, Python 3.13, and type-check statuses in [CI run 37359465028](https://github.com/Stage-11-Agentics/lattice/actions/runs/37359465028). The full suite was not rerun on Hyperion.

All temporary tracked edits were restored with `git -C /Users/atin/Projects/Stage11/code/review-worktrees/lattice-147 checkout -- .`. Scratch probe data was removed after recording the results here. No c11 app was launched, quit, focused, or driven; no protected sign-off socket or seat was accessed.
