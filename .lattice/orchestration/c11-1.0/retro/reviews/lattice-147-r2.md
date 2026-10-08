PASS

LAT-395 / Stage-11-Agentics/lattice#147, repair verification, 2026-10-05 PDT.
Head: `354edc74bbf00e2a4df9ec0ec5400de71f81a410`.
Base and merge base: `b794c1b5059abe01e455e1d8a8c6d19e741edb69` (`origin/v2`).
Fetched the requested refs and checked out this detached head before verification. The PR is open, targets v2, and still names this exact head.

## Blocking findings

None in the requested repair scope. Both r1 blockers, the next-step hint, and the listed lifecycle invariants pass verification on v2.

## Non-blocking product findings

None added. No broader product discovery was performed. The r1 hosted-source limitation is resolved by this port; the v2 local dashboard also uses the shared operation, resolving r1's dashboard-cycle discrepancy.

## Reviewer-caused operational incident: cleanup required

This PASS is the product verdict. During this review, my initial test setup unintentionally wrote to the main checkout's live `.lattice` board. I placed pytest's temporary roots inside the review worktree to honor the file boundary, but did not initially put a separate git boundary around them. Lattice's linked-worktree discovery redirected some ops/MCP test roots to the primary checkout before inspecting their scratch boards. I also initially inherited v2's `-n auto` test setting instead of pinning two workers.

The affected run was `tests/test_ops/test_execute.py` plus `tests/test_mcp/test_ops_convergence.py`, around **2026-10-06 00:28:23–26 UTC**. The test origin names this review worktree, with actors `agent:t`, `agent:mcp-test`, and the newly created test session `Argus-4`.

Confirmed impact on `/Users/atin/Projects/Stage11/code/Lattice/.lattice`:

- **23 test tasks: LAT-396 through LAT-418.** Their IDs are listed below. Tests also wrote their plans, notes, snapshots, index/lifecycle entries, assignments, statuses, and test audit events. LAT-396 and LAT-402 were archived by tests.
- **Two test logs contain an intentionally invalid second line, `{not json`:** LAT-413 (`events/task_01M479S3AP82M3B2W7SRB6V7TG.jsonl`) and LAT-414 (`events/task_01M479S3XJYVFFZV72F203GQX7.jsonl`).
- **The live config's `workflow.review_cycle_limit` was set to `1`** by the ops tests and remains 1 at inspection. I have no saved pre-run config snapshot, so I have not guessed its prior value.
- **Test session:** `sessions/Argus-4.json`, session `sess_01M479S3AK09J5BC7GJNMD1XWN`.

I stopped using that setup when the failures exposed it. I added a standalone git boundary around subsequent scratch roots, verified an empty scratch directory resolves to no board, and reran the affected files with `-n 2`: all **52 ops/MCP** and **9 migration-ownership** checks passed. The earlier nine environment-induced failures are excluded from product conclusions. Subsequent probes used the isolated setup.

I have not attempted live-board cleanup. The review brief expressly says “Never … change a ticket's status, or edit files outside your review worktree.” Cleanup needs explicit authorization or an authorized board maintainer: repair/quarantine the two test-corrupted logs, remove the attributed test tasks/session through an appropriate audited procedure, and restore the intended review-cycle limit. Preserve unrelated board data and do not roll back the shared board wholesale. This was my test-isolation error, not a new LAT-395 finding.

| Test ticket | Full task ID |
|---|---|
| LAT-396 | `task_01M479S3AJJRHRXFRCW72221SW` |
| LAT-397 | `task_01M479S3C5J1R36DVRMA31B3G7` |
| LAT-398 | `task_01M479S3B2VSH90BM3AYNYG8AE` |
| LAT-399 | `task_01M479S3DPZJAMGAFY4FSY6KZY` |
| LAT-400 | `task_01M479S3F2EFPD34Z56EGW8F7A` |
| LAT-401 | `task_01M479S3AMANR5DWNM7MN2Z53W` |
| LAT-402 | `task_01M479S3GQAA6D12G8YQAPFT2G` |
| LAT-403 | `task_01J9ZABCDEFGHJKMNPQRSTVWXY` |
| LAT-404 | `task_01M479S3K71WDSX7H7JTKAE1V8` |
| LAT-405 | `task_01M479S3F7C864BXTG9YEGRVFC` |
| LAT-406 | `task_01M479S3ANYN221Z2JPFQQ6HZW` |
| LAT-407 | `task_01M479S3FBDF0EAHJ07Q7Q3CH9` |
| LAT-408 | `task_01M479S3ANK8QQ9359XE5YFRQX` |
| LAT-409 | `task_01M479S3PGPEBKD9SHEHC51D3B` |
| LAT-410 | `task_01M479S3AMKQ7XK0MJ0Q3CHG0B` |
| LAT-411 | `task_01M479S3RCB3QV1XX7FDDM1BE7` |
| LAT-412 | `task_01M479S3T447KXRQBQ7M9JQWCN` |
| LAT-413 | `task_01M479S3AP82M3B2W7SRB6V7TG` |
| LAT-414 | `task_01M479S3XJYVFFZV72F203GQX7` |
| LAT-415 | `task_01M479S3ASSKATQ3M7DGYB19FT` |
| LAT-416 | `task_01M479S3AMGM02RAMY43Y094Q2` |
| LAT-417 | `task_01M479S3WZVQZ6WF8JKNTFQXRE` |
| LAT-418 | `task_01M479S62X20YHBC3MJBMBX3DQ` |

LAT-398 uses the direct-execute test's fixed op ID `op_01J9ZABCDEFGHJKMNPQRSTVWXY` without reported worktree metadata; its timestamp, actor, title, and neighboring hook-test task identify the source. The other 22 creation records carry this review worktree in their origin.

## Repair verification

**R1 finding 1: fixed.** `ops/task_status.py:135-153` validates the configured policy against the authoritative snapshot and events before committing `in_validation -> done`. The local dashboard translates the request to `task.status` (`dashboard/api.py:1050`, `dashboard/server.py:662`). The hosted dashboard and operation endpoint execute the same operation through the server's writer (`server/dashboard.py`, `server/project.py:833`). MCP calls it at `mcp/tools.py:358`; the CLI calls it at `cli/task_cmds.py:473`.

Observed missing-evidence refusal followed by success after current review evidence was added through: local CLI, local dashboard HTTP, hosted dashboard HTTP, hosted operation HTTP, local MCP, and MCP through a bound hosted checkout. The negative HTTP tests also check unchanged durable board content. Disabling the shared policy refusal made all six selected CLI/dashboard/hosted/MCP negative tests fail.

**R1 finding 2: fixed.** `ops/task_complete.py:230-254` selects the route from the locked snapshot and requires `review -> done` only for the route that actually takes that hop. `:270-282` still checks the prospective completion evidence before artifact writes. Composed workflows with review enabled and disabled both complete from validation without a synthetic review hop, via local CLI, direct local ops, and hosted operation HTTP. Hosted CLI completion also succeeds. A composed task still in review continues to be refused when its graph has no `review -> done` edge.

MCP and dashboard expose status transitions, not a separate `task.complete` tool/route; their direct close is covered by the evidence-gated status probes above. No nonexistent entry point is counted as tested.

**Next-step hint: fixed.** `cli/task_cmds.py:382-408` names both routes and emits `next_steps.or: "done"` when the configured edge exists. Local and hosted CLI probes observed the alternate route. The regression also verifies it is omitted for an unmigrated graph without the edge. MCP and HTTP operation responses do not independently generate this CLI hint.

## Invariants retained

- **Automatic review hard stop:** `ops/task_status.py:110-132` uses the latest review-entry event and its matching auto-review audit event. Existing CLI, ops and MCP tests, plus hosted operation/dashboard probes, refuse over-budget rework. Turning enforcement off made six checks fail; the manual cases in that batch stayed green.
- **Manual review advisory behavior:** over-budget transitions succeed and persist `{cycle, limit, over_limit, enforced}`. The CLI warns on human-readable output. The prior automatic cycle does not bind a later manual review entry. Probe coverage includes all five valid rework edges across review, validation and pr_open, and both automatic/manual cases. The two `pr_open -> in_planning` attempts remain invalid graph transitions.
- **Other guards:** configured plan gates, force/reason behavior, completion roles, assignment and reachable-review-commit checks remain in their existing shared paths. The selected CLI/ops/MCP tests exercise these guards. A separate `task.complete` probe confirms custom missing validation evidence is refused without adding events or artifacts. Fixtures with a configured review stage enter review first, retaining v2's current-cycle evidence requirement.
- **Migration:** a populated board's task data, review comment, files and unknown nested config extension are preserved. Dry-run changes no bytes; apply changes only the intended config edge; a second apply is byte-identical and reports `changed: false`. Disabling the dry-run guard makes both the shipped dry-run test and the populated probe fail.
- **Hosted ownership:** the migration is registered local-only, refuses bound checkouts/caches, and follows the existing server-owner lock and `--offline-maintenance` mechanism. Nine targeted registry/ownership cases pass. This proves the scratch server procedure, not a migration of any deployed board.
- Auto-review defaults are unchanged in the diff against v2.

## Evidence

Final head-code verification, with two workers and isolated scratch git roots:

| Selection | Passed |
|---|---:|
| Touched CLI completion/status/migration and core events/presets | 158 |
| Touched ops execution and MCP convergence | 69 |
| Local dashboard rules; hosted completion and cycle probes | 15 |
| Migration registry and ownership cases | 9 |
| **Total** | **251** |

The total includes 24 temporary reviewer probes. Those probes were added only inside the review worktree and removed after verification.

Six independent mutations, restored after each run:

| Mutation | Expected failing checks observed |
|---|---:|
| Bypass shared status completion policy | 6 |
| Disable automatic cycle-limit enforcement | 6 |
| Restore unconditional review-to-done requirement | 7 |
| Bypass complete's prospective policy | 1 |
| Remove the alternate next-step route | 4 |
| Let migration write during dry-run | 2 |

For the author's base comparison, replacing the changed Python production modules with their `origin/v2` versions produced **22 failed, 13 passed** in the focused repair regression selection; the events file separately failed import of `latest_review_auto_fired`. Some base reds are fixture/shape assertions, so the guard mutations above provide the behavioral proof. The final 251-test run occurred after restoring head production code.

Ruff check and format check passed on all 23 changed Python files after restoring every tracked edit. `git diff --check` and the tracked diff are clean. No commits, pushes, PR comments, merges, or LAT-395 status changes were made. The accidental test-board writes are disclosed above.

Independently verified successful exact-head CI: lint, type-check, and Python 3.12/3.13/3.14 in [run 37393685636](https://github.com/Stage-11-Agentics/lattice/actions/runs/37393685636). Full-suite and complete parity-corpus reruns were left to CI; local work stayed in the touched files and targeted repair probes. Hosted HTTP checks used disposable localhost servers, with no live hosted-service writes. The protected c11 sign-off app, socket and seats were not accessed.
