# LAT-395 repair 1 (review FAIL at 9232862a1f)

Review: `../reviews/lattice-147-r1.md`. Read it in full. Fix everything below in one push, same ticket, same PR.

0. **Retarget to `v2`.** Lattice development lands on `v2` now (every recent PR, #140 to #145, has base `v2`), and the installed `lattice` runs from a v2-lineage checkout. Your branch is on `main` (v1), which has no `src/lattice/ops/` or `src/lattice/server/`, so the fix never reaches the live tool or the hosted path. Port the change onto `origin/v2` (new branch from `origin/v2`, or rebase; force-push the PR branch is fine since nobody else builds on it), and change the PR base: `gh pr edit 147 -R Stage-11-Agentics/lattice --base v2`. On v2 the cycle limit is enforced in `ops/task_status.py`; the local CLI, the dashboard and the hosted server must all apply the same rules.
1. **P1, completion evidence bypass.** Every entry point that can move a task `in_validation → done` must run the configured completion policy, with the same force/reason semantics as the CLI: the dashboard status handler (on v1 `dashboard/server.py` `_handle_post_task_status`; find its v2 equivalent) and the hosted server path. Add endpoint regressions: refused without evidence, allowed with it.
2. **P2, `lattice complete` on composed workflows.** Decide the route from the current status first; require `review → done` only when completion takes that hop. Cover the composed-workflow cases the reviewer used (review enabled and disabled, with validation and pr_open).
3. **Next-step hint** (small, do it): the validation next-step hint should name both valid routes (merge first then done, or pr_open), not only pr_open.

Prove each fix red on the old code and green on yours. Run the touched test files plus `ruff`; let PR CI run the full suite.

Hand off with one line (the mailbox drops message bodies on this build, so use send):
`c11 send --workspace workspace:11 --tab tab:687 "HANDOFF LAT-395 REVIEW <new head> <PR url>"`

The queued auto-review-default PR also bases on `origin/v2`.
