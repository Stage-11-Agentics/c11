# Dispatch playbook (Phase 1 — Orchestrator)

Operational depth for running the fleet. Assumes SKILL.md and an intake completed per `references/intake.md`. Each rule is stated exactly once; boot templates reference the named blocks rather than restating them.

---

## The Identity Block (used by every spawned agent)

`$C11_TAB_ID` is unreliable in fresh `c11 new-tab` shells — frequently empty. An empty value makes `--tab ""` fall back to the **focused** tab, silently rewriting someone else's title and metadata. So every spawned session (delegator, sub-agent, captain, validator) begins with:

```bash
MY_TAB=$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["tab_ref"])')
test -n "$MY_TAB" || { echo "FATAL: could not resolve own tab ref"; exit 99; }
```

then uses `--tab "$MY_TAB"` on every tab-scoped write. Ticket-bound roles additionally claim **before** titling — `(cd "$REPO_ROOT" && lattice claim <TICKET-ID> --surface "$MY_TAB" --actor agent:<id>)` — because claim auto-renames the tab and the explicit title must win. Then set identity with **both** `c11 rename-tab` and `c11 set-title` (single-call propagation is unreliable), plus `set-agent` and `set-description`. `lattice unclaim` releases; claim bindings are liveness hints, not truth — they don't survive restarts.

## Standard Clauses (baked into every delegator and sub-agent prompt)

1. **Worktree assertion, line 1:** `test "$(pwd)" = "<abs-worktree>" || { echo "FATAL: wrong cwd"; exit 99; }`. On mismatch, HALT — do not `cd` to the expected worktree, do not improvise; the bug is at the spawn side and downstream repair only hides it. Line 1 because that's the only point where `pwd` reflects the launch cwd unmolested.
2. **Environment:** `export LATTICE_SPAWN_BACKEND=headless` and `export LATTICE_ROOT=<primary-checkout-root>` — never `$PWD`. A worktree carries its own `.lattice/` from its branch point; writing to that divergent board surfaces later as duplicate short IDs and unmapped tickets.
3. **Status discipline:** bump ticket status BEFORE starting each phase; only the delegator bumps (sub-agents post a completion comment and stop); verify bumps with `lattice show --json`; re-bump after triage roundtrips. Status drift is the #1 silent-failure mode of well-meaning delegators.
4. **Re-fetch at phase boundaries; never rebase a pushed branch.** `git fetch <remote>` and record "working against <remote>/main @ <sha>". Before the first push, rebase freely. After it, bring in `<remote>/main` (or a landed anchor) by merge only: others may already stand on the branch, and every rewrite forces each dependent to restack, then theirs.
5. **Deviate-with-flag (impl):** when the plan contradicts SPEC, the codebase, or itself — deviate and flag the contradiction, the side taken, and why, in the completion comment.
6. **Lattice items live in the root repo.** The CLI auto-routes from worktrees, but Claude's `Write` tool does not: a planner writing `.lattice/plans/<uuid>.md` by relative path lands it in the worktree's shadow copy — the parent plan file stays an empty scaffold and plan-review reads stale content. Plan files are written with the **absolute parent-repo path**. (Recovery: the planner's context still holds the plan — nudge it to re-Write to the absolute path.) `Invalid transition` errors usually mean wrong `LATTICE_ROOT` or an old install, not corrupted state.
7. **Monitor/watcher paths include `.lattice/`:** a watcher on `$REPO_ROOT/plans/...` (missing the `.lattice/` segment) silently never fires and the run stalls.
8. **Source paths in prompts are worktree-relative.** An absolute parent-repo path in an impl prompt sends edits to the parent working tree: the feature branch ends up empty while uncommitted changes pile up in the wrong checkout. Write prompts as if typing at a shell prompt inside the worktree. The Clause-2 "absolute parent path for `.lattice` writes" rule bleeds: delegators over-generalize it to source files — so every boot prompt also carries a **pre-commit guard**: `test "$(git rev-parse --show-toplevel)" = "<abs-worktree>"` before each commit. Recovery when a commit still lands on the parent checkout's main: freeze the delegator, cherry-pick the stray commit onto the feature branch, then restore the parent with per-file `git restore` + `git reset --soft` — **never `reset --hard` a checkout whose `.lattice/` is the live board** (the working tree is the database; a hard reset destroys run events).
9. **Sub-agents live in c11 tabs, never headless `claude -p &` shells** — headless background shells break the c11 auth chain, are invisible to the operator, and lose sidebar telemetry.
10. **Verify the push landed:** after `git push`, `git fetch <remote> && test "$(git rev-parse HEAD)" = "$(git rev-parse <remote>/<branch>)"` and re-push until equal. A silently-failed push — or a commit leaked onto the root checkout's `main` — is the #1 false-completion mode. Then confirm the PR's `head.sha != base.sha`.
11. **Cadence:** `/loop` with a 60-second tick; never bash `sleep`/`watch`/`lattice watch --exec` (subprocess loops die on compaction, can't re-enter the model, and are invisible to the harness). **Once you say `Loop ended`, you're dead** — no `send-key` revives a terminated loop, so do post-PR cleanup before ending it. (Codex has no `/loop`; use explicit `codex exec` re-invocations and flag the difference.)
12. **Stop after the completion comment.** Sub-agents do not bump status and do not address the operator; the delegator is the only interface upward. Read-before-Write on pre-existing files (plan files are scaffolded at ticket creation — the path always exists).
13. **Flag only human-required blockers:** on hitting a blocker only the operator can clear (a decision, a credential, an account swap), `c11 raise-flag --tab "$MY_TAB" "<one-line reason>"` in addition to the Lattice `needs_human` escalation, and `c11 lower-flag` once unblocked. Recoverable blockers go to the parent (delegator or Orchestrator), never to a flag. Do not launch delegators `--suppressed` by default — the operator watches these tabs directly; suppression is reserved for workers whose completion the launching agent alone consumes (see the c11 skill's attention model).
14. **Positive launch receipt:** before consequential work, the child returns
    `READY <ticket> CWD <abs-worktree> HEAD <sha> BASE <sha> MODE active` to the
    Orchestrator on the named channel. Reviewers use `REVIEWING`. Standby seats use
    `MODE standby` and name the mutation not started. The parent verifies the fields;
    tab creation and an idle TUI prove only liveness.

15. **One build per machine.** Never run `xcodebuild` bare; every build goes through `scripts/with-build-lock.sh` (the repo's `reload.sh` / `test-unit-local.sh` already do), so parallel delegators queue instead of stacking swift-frontends until the load average is in the hundreds. `build-for-testing` and local `test` actions are CI's job, not a delegator's. Boot prompts state this; a waiting `[build-lock]` line is the expected shape, not a hang. The same holds for any heavy local command a project has (a pre-PR gate, a whole-tree lint or typecheck): one machine-wide lock, named in every boot prompt, because builders on one machine start them at the same moments.
16. **Questions go to the parent's tab.** Every question, decision request and receipt is sent with `c11 send` + `send-key enter` to the named parent tab, and the child keeps working on whatever the question does not block. A question left only on the child's own screen is never read; "idle until you answer" on its own screen is this failure, however clearly the brief said otherwise.
17. **The CI window (shared runner).** A branch push without a PR costs no CI; opening or updating a PR starts a gate run. When the gate shares one runner and its wall budget is tight, children push freely but open or update a PR only when the Orchestrator grants the window by name. With headroom, the window is off and runs overlap.
18. **Shared enumerations are edited at their canonical source.** A child adding a value to a shared allow-list or replacing a shared object uses the canonical list and landing order its ticket names, never a copy from the last migration it saw.

## Spawning: atomic cwd binding

`c11 new-tab --area <ref>` starts in the workspace root (or, in a rootless workspace, the area's last shell cwd), never in a particular delegator's worktree, so an un-anchored sub-agent lands in the wrong tree. And Claude Code's Bash tool does not persist `cd` across tool calls. Therefore bind the cwd at birth with `--cwd` and keep the launch line atomic:

```bash
c11 new-tab --area "$DELEGATE_AREA" --cwd <abs-worktree> --no-focus   # capture the new tab ref
c11 send --workspace $WS --tab $NEW_TAB "cd <abs-worktree> && claude --dangerously-skip-permissions --model <model> \"Read <prompt-path> and follow the instructions.\""
c11 send-key --workspace $WS --tab $NEW_TAB enter
```

The send + explicit `send-key enter` two-step is the durable Claude-to-Claude handoff. Stage prompts at `<worktree>/.lattice/tmp-prompts/<phase>-prompt.md` (physically bound to the worktree); a `/tmp/<proj>-<n>-<phase>-prompt.md` path is acceptable only with an atomic launch plus the receiver guard (Standard Clause 1).

## Worktree prep (at dispatch)

```bash
git worktree add <repo>-worktrees/<ticket-slug> -b <branch> <base>
```

Base is `<remote>/main` — or the parent's branch for press-ahead children. Then **propagate gitignored credentials**: copy the root checkout's `.env` (and `~/.netrc`-style material where the project needs it) into the worktree at create time; without it, impl phases die mid-tool-call on confusing "missing secret" errors.

## The dispatch loop

Tick body: (1) refresh — run-state, Lattice board, `c11 tree`, rewrite agents.md active table; (2) surface escalations — re-banner **every tick** while `needs_human`/`blocked` stands (a banner that scrolled away 30 minutes ago is the same as silence); (3) press-ahead audit over unspawned tickets; (4) landing-train pass if auto-merge is enabled; (5) auto-close finished tabs, meaning every PR of that builder is merged (`c11 close-tab` — it reaps children; `/quit` does not, and orphaned review subprocesses can keep spawning areas after merge; also kill any process whose cwd is a merged ticket's worktree, since an orphaned test worker outlives its delegator); (6) spawn next available delegators, routed to the lightest-loaded delegate area; (7) `ScheduleWakeup` — one pending wake at a time.

**Cadence:** active dispatch 270s (inside the 5-minute prompt-cache window); quiescent 1200–1800s; never 300s (pays the cache miss without amortizing it). End the loop explicitly at run completion; silence after closeout is correct.

## Reading delegators, and recovery

Three tells: bare `❯` with no indicator = genuinely idle; `✻ <verb> for Xm` plus an "N shells running" footer = background task, don't intervene; `✻` with no footer = thinking, wait. Don't take an operator's "looks idle" at face value.

The canonical stall tell is a **cost counter frozen across 2+ ticks**. Diagnose before nudging: frozen cost + a live shell footer usually means a legitimately long-running command — `pgrep -fl "<worktree-slug>.*<suite>"` for a live PID, and read tee'd logs for buffered progress. Frozen cost + live shell = background-watching, not a stall.

- Real stall → `c11 send` an "ORCHESTRATOR NOTE: cost frozen N ticks — report status and continue" **plus** `send-key enter`. Never trust `send-key enter` alone — the TUI sometimes swallows synthetic Return; always pair it with a fresh `send`.
- Auth halt (`⎿ Not logged in · Please run /login` in a deep screen read — typically after the operator swaps accounts mid-run) → once restored, send "auth restored, retry the tool call, resume /loop".
- Queued-but-unsubmitted text (cost moves slightly, input box shows stuck content) → a new `send` replaces the buffer.
- **After a usage-limit reset or any fleet-wide outage, nudge every tab**: delegators, their sub-agent tabs (planners, implementers, fixers), in-process review agents and captains. Verify each shows fresh commits or activity within one tick. A nudged delegator whose implementer died waits forever, and one whose work is done may be waiting on a CI window you never gave it.
- **A subtitle unchanged for over 45 minutes means read the screen.** The description is self-reported and goes stale exactly when an agent is stuck or waiting on you.
- Two consecutive dead sends → the session is dead; surface to the operator and offer a respawn from the latest commit. Dead-session state recovery itself belongs to c11 (workspace persistence + session-resume hook), not the Orchestrator.

## Mode boot templates

Every template begins with Standard Clause 1 (worktree assertion), the Clause-2 environment exports, and the Identity Block, then claims its ticket. Phase arcs below substitute the pinned status vocabulary for any literal:

**Fast-track** (no sub-agents, no headless reviews, no `/loop` — runs synchronously):
1. *Plan* — bump `in_planning`; write the plan to `$LATTICE_ROOT/.lattice/plans/<task_uuid>.md` (absolute path, Clause 6); bump `planned`.
2. *Implement* — bump `in_progress`; fetch (Clause 4); edit + tests; commit.
3. *Self-review* — bump `review`; attach the verdict: `lattice attach <ID> --type note --role review --inline "<verdict>" --actor agent:<id>-reviewer`.
4. *Validate* — bump `in_validation`; exercise the change end-to-end (browser, simulator, curl — whatever proves behavior); attach evidence `--role validation` (or a one-line justified N/A). The terminal pre-merge status is **gated on this artifact**.
5. *PR* — push with Clause-10 verification; attach the PR as a `--type reference`; bump to the terminal pre-merge status. Stop there — the Orchestrator merges and completes.

**Inline-full** (default for medium work — fresh eyes without PTY pressure): the fast-track arc plus
- after *Plan*: headless plan-review — `(cd $LATTICE_ROOT && lattice plan-review <ID> --mode single --actor agent:<id>-plan-reviewer)`; triage findings into an amendment block (below); restore the tab title after every lattice review call (the CLI sometimes clobbers it).
- after *Implement*: headless code-review under the 600-second rule (below); a fix phase if Critical/Major findings.
- `/loop` with a 60s tick between phases; post the completion comment and end the loop only after cleanup.

**Sub-agent-full** (escalation only): planner, impl, and fix sub-agents as new tabs in the delegator's area, each launched atomically with the Standard Clauses; the delegator coordinates, watches plan files via Monitor (Clause 7), and owns all status bumps. The impl phase additionally scans open PRs for cross-ticket contracts (`gh pr list` / the forgejo equivalent; honor "open contract" and "lock in before X" notes). At PR time, create the PR and bump status as **parallel calls in the same batch** — never sequence them.

**Plan-validation variant:** when dispatch targets a ticket already `planned` (pre-planned upstream or in a prior run), the delegator does *not* re-plan. It reads the existing plan against the current SPEC and parent-branch code: aligned → one comment ("plan revalidated; no amendments") → impl; mechanical drift → append an amendment block → impl; architectural drift → amendment block + re-run headless plan-review.

## Reviews

- **Force the headless backend.** `lattice plan-review` / `code-review` internally spawn an agent with backend auto-select `cmux → terminal → headless`; inside c11 the cmux backend wins and spawns each reviewer into a **brand-new c11 workspace** — a 15-ticket run can shed ~30 stray workspaces. `LATTICE_SPAWN_BACKEND=headless` (Clause 2) plus `--mode single` prevents it. Flag names drift across installs (`No such option: --headless` means rely on the env var). Never `c11 send` the review command into a separate tab — fresh tabs start in `$HOME` with no `.lattice/`.
- **The 600-second rule (HARD).** Code-review invoked from a worktree fails often enough that the fallback is documented behavior, not an exception. Wrap it: `(cd <WORKTREE> && timeout 600 bash -c "LATTICE_SPAWN_BACKEND=headless lattice code-review <ID> --mode single --base <remote>/main --actor agent:<id>-reviewer")` (macOS without coreutils: `gtimeout`, or background-job + kill). On RC 124, an empty diff, or a vacuous review — pivot immediately to the **own-reviewer fallback**: compute the diff yourself (`git log <remote>/main..HEAD --stat` + per-file diffs), write a review in the standard shape (Verdict PASS / PASS-WITH-NITS / FAIL; Critical/Major/Minor/NIT findings with file:line + recommendation), attach it `--role review`, and note "own-reviewer fallback, CLI hung/empty" in the completion comment and decision log.
- **Base is `<remote>/main`, never bare `main`.** Post-merge they differ; bare `main` produces an empty diff that reads as a clean review.
- **A fired review is not a finished review — the gate FAILS OPEN.** The review runner can die without a trace the task ever sees (600s timeout, `claude -p` session-limit exit, the firing session killed): `.lattice/review_state/<task>.json` then says `running` forever, and the completion policy passes on ANY lifetime `review`-role evidence — including a FAIL artifact from a previous rework cycle. (2026-07-11, acetate 0.4.0 sweep: one review dead 223 min while reporting `running`, caught only by a merge agent's voluntary cold re-review; one rework merged with only its pre-rework FAIL attached; a third recovered only because the delegator reviewed inline after a 600s timeout.) So: after every review invocation, before advancing, confirm a NEW `--role review` artifact exists that **postdates this cycle's `→ review` transition**, **names the reviewed commit** (== branch HEAD), and **carries a PASS verdict**. At merge time, re-run the same check — a rework cycle invalidates all earlier review evidence. Diagnosis kit: `lattice show <ID> --json` (artifact list + event times), `lattice review-status <ID>`, `ps -p <started_by_pid>` (state `running` + dead pid = dead review), `.lattice/review_state/failures.jsonl` (where timeouts and session-limit exits land — a `session limit` stderr means every subsequent spawn will die too until the limit resets; go straight to own-reviewer). Dead review → own-reviewer fallback (above). Never wait on a `running` claim past ~12 min, never advance on stale evidence.
- **Review cycles must converge — the cycle limit is a circuit breaker, not a pacing suggestion (HARD).** Cap fix→re-review cycles at 2 per ticket, 3 absolute. At the cap, stop and escalate to the operator even when every finding is concrete and no single finding needs a human decision — "each finding is individually actionable" is exactly how a divergent loop disguises itself. Watch the finding *class* across cycles: prior Majors confirmed fixed but new Majors appearing in newly-added mechanism means the spec, not the code, is the problem — usually absolute acceptance language ("fail closed under any crash," "correct under any reordering") applied across a process/socket/filesystem boundary, which licenses infinite legitimate descent; that is a scope defect only the operator can resolve, never something to force past. Plan reviews should flag absolute acceptance language as a scope hazard before impl begins. Companion tripwire: cumulative diff exceeding ~3× the plan's size estimate escalates on its own, regardless of review verdicts. (2026-07-31, C11-188: eight cycles, eight FAILs, ~10k lines for what was a callback-guard bug; the orchestrator overrode its own 3-cycle guard three times with "no human decision required," and the run ended in a full revert. Full story: `docs/aar-c11-188-attention-loop.md`.)
- **A green gate proves the tests pass, not that they still detect.** For a change to the test harness, the gate or a sweep, the review demonstrates each claim: a two-file probe for state crossing files, a planted failure (mutation) for each guard, then reverts. Green CI on such a change is not evidence until that review passes.
- **Amendment blocks.** Never proceed to impl with untriaged plan-review findings — the impl agent stalls (correctly) on stale guidance. Triage each finding (obvious / evolutionary / complex → `needs_human`) and append to the plan file: `## N. Plan-Review Cycle K Resolutions (AUTHORITATIVE — overrides earlier text on conflict)` with per-finding concern / resolution / section affected. Impl prompts state that the latest Resolutions block is binding. Re-review only when findings were architectural or numerous.

## Verified state, not reported state

The single highest-leverage discipline in an auto-merge run — never act on what an agent *said* happened:

- Branch exists remotely: `git ls-remote <remote> refs/heads/<branch>` non-empty; PR non-empty: `head.sha != base.sha`. **An empty PR (head==base) is the dominant cause of a Forgejo `405 "Please try again later"` on merge — that is the empty-PR symptom, not a transient queue, and `force_merge` won't fix it.**
- Merging: capture the HTTP code (`-w "%{http_code}"`); **never `curl -sf` a merge** — `-f` swallows the error body that says what failed. Re-GET the PR and assert `.merged == true` before `lattice complete`.
- Before pushing any shared branch: `git log <remote>/main..HEAD` contains only intended commits, and `git rev-parse --show-toplevel` is the expected checkout. Never wrap a commit/push in or after `cd <root-repo>` — a commit inheriting the root cwd lands on the root checkout's `main`, the feature branch looks empty, and the work hides on the wrong branch.
- Review evidence is part of verified state: fresh (postdates the last `→ review` transition), names the merged commit, and its newest verdict is PASS — see "A fired review is not a finished review" under Reviews. "An artifact with role `review` exists" verifies nothing.
- Gate evidence is exact-head state too: the receipt's gated head equals the PR head,
  its parsed status is passing under the project's documented vocabulary, and no push
  happened afterward. A timeout/unknown result and a green run on an earlier head are
  both non-evidence.
- Every PR/review/gate/merge transition appends a machine-readable delivery receipt
  per `references/intake.md`. Receipts are projections of verified state, never a
  substitute for checking it.

## Press-ahead

Spawn dependents when a dependency reaches `review` or the terminal pre-merge status — not at merge.

**Planning-only variant (merge-barrier runs).** When the run config forbids cutting dependent branches before the dependency merges, press-ahead still applies to *planning*: spawn the dependent delegators at the dependency's `review` in a **scratch-sandbox cwd** (no worktree, no branch), reading the in-review branch's code shape read-only, writing plans to the board, and halting at `planned` until an explicit `RESUME IMPLEMENTATION` message names their post-merge worktree. Costs zero barrier wall-clock; the sandbox cwd also means a confused delegator has no repo to damage. After every transition, audit all unspawned tickets; default to spawning; don't wait for operator approval to start an unblocked ticket. Children branch **off the in-review parent** (`git worktree add ... -b <child> <remote>/<parent-branch>`), never off main — they inherit the parent's interfaces import-stable. The child PR body names its anchor ("based on #N — merge that first"), and the anchor is recorded in run-state's ticket table. When the anchor lands, the child merges `<remote>/main` (Clause 4): the squashed content merges cleanly, the PR diff shows only the child's work, and its own dependents need not restack.

## Landing train and auto-merge (opt-in at Phase 0)

Build, ordinary review, and local validation may proceed in parallel. **Final landing
is serial.** Maintain one dependency-ordered ready queue and grant the front PR the
only finalization slot. This prevents every queued branch from repeatedly paying an
exact review/gate against a base another merge is about to replace.

### C11-315 hourly-main gate

For c11 1.0, `.github/workflows/ci.yml` is the PR fast lane only: require its
workflow guards, remote-daemon tests, and web typecheck. The native app build,
logic/host tests, compatibility smoke, and GhosttyKit packaging run on the
hourly main workflows on the internal Atlas runner (`self-hosted, macOS, atlas`),
never on fork pull requests. The Merge Captain does not wait for an hourly run
to land a ready PR. At the exact PR head, require fresh review evidence and the
cheap checks, then use `scripts/remote-build.sh` on Atlas for changes that touch
CI/build tooling. A Ghostty or bonsplit pointer change keeps the hosted
GhosttyKit checksum-flow exception and is not replaced by the generic Atlas
fallback. After landing, an hourly main failure is a fix-forward incident: do
not reclassify an older PR as green or use a rerun to conceal a broken main.

For the front PR only:

1. Fetch `<remote>` and compare the PR with current `<remote>/main`. Merge
   `<remote>/main` into the head if required, push with Clause 10, and record the
   resulting base/head pair.
2. Obtain fresh review evidence naming that exact head. Require the reviewer's
   positive `REVIEWING <work-item> CWD <path> HEAD <head> BASE <base>` receipt before
   spending the review cycle.
3. Run the project gate on the same head and append its parsed status. Any push,
   conflict resolution, or generated-file change invalidates both review and gate.
4. Re-check verified state and mergeability with plain `curl -s` (`.mergeable`,
   `.has_merge_conflicts`), squash-merge with the HTTP code captured, then re-GET and
   assert `.merged == true`.
5. Append the merge receipt, `lattice complete <ID> --review "Merged via auto-merge
   (PR #N, squash)" --actor ...`, close the delegator tab, and release the slot.

Do not final-review several queued PRs "to save time"; that creates stale evidence
as soon as the first one lands. Early reviews remain valuable for finding design and
implementation defects, but only the front-of-train exact-head review and gate
authorize merge. Keep that review on every PR however clean the builder's own reviews
were: cross-ticket defects (a deadlock with another ticket's lock order, a list that
drops a sibling's value) are visible only against the assembled base. After merging a
parent, a dependent child merges the new `<remote>/main`, waits out the forge's
mergeability recompute (~5–15s Forgejo, 10–25s GitHub), and then enters the front slot.

**The gate is shared capacity.** On a wall-clock gate, our own concurrent runs are the
foreign load: when PR CI shares one runner and the budget is tight, grant the CI window
(Clause 17) to one PR at a time; with headroom, let runs overlap. When `main` itself fails the gate, reruns cannot clear it; fix
`main` first. Measure before hypothesizing a lever: instrument the phases (setup, queue
or pool wait, shard skew) and probe one variable at a time on a quiet runner. When the
CI runner is also the measurement machine, measurement takes a lock: short windows with
gaps between them so CI gets clean slots, and load-independence proved in process, never
with a machine-wide load generator.

**Clean text is not independence.** Landing a green head without re-merging a moved
`main` is safe only when what moved cannot reach the PR's behaviour (docs that no test
reads, checked by a grep of the tests). Files interact through shared processes,
registries and databases with no overlapping lines, so otherwise merge and gate again.

Forgejo PAT via `security find-internet-password -s forgejo.stage11.ai -w`.

- **Additive-registration conflicts** (`__init__.py` re-exports, CLI/plugin registries): resolve as the union, ordered by ticket ID — the standing pattern. Real semantic conflicts → escalate with a `🛑` banner.
- **A squash carries only the ticket's own files, and a child lands after its anchor.** Before squashing, `git diff --stat <remote>/main...HEAD` shows only the ticket's own files; a branch that merged an unlanded anchor waits until that anchor lands. Otherwise the squash puts the anchor's files on main in whatever state the child last merged, and when those are migrations, the anchor's later edits change already-applied files: a runner that checksums applied migrations would refuse to boot on the next deploy, so deploys freeze until the anchor lands.
- **A squash-merged parent is NOT an ancestor of its children.** `git merge-base --is-ancestor` returns false even though the content landed, and child PRs show phantom diffs. Don't gate on ancestry after squash — gate on validating the assembled tree.
- **Deep stacks:** prefer one `integration/<run>` branch — merge leaf tips in dependency order, validate the assembled tree once (assembled-tree checks catch what per-PR review can't), single PR to main, close the individual PRs with a "merged via integration/<run>" comment.
- Record every auto-merge in agents.md.

## Captains

One-shot recovery agents for cross-cutting batch work (a Merge Captain, a Diagnostic Captain, a Status Captain) — distinct from delegators (ticket-scoped) and sub-agents (phase-scoped). Name them `<Scope> Captain`; spawn a fresh one per engagement rather than re-tasking the last.

**Merge Captain** — for the stacked-branches-after-squash artifact (every PR after the first hits conflicts; expect it on nearly all stacked PRs, ~1–2 minutes each):
1. Hygiene first: `git -C <wt> reset --hard HEAD && git -C <wt> clean -fd` per worktree.
2. Mechanical fix: merge `<remote>/main` into the branch, resolving the parent's files to main's version. `git rebase --onto <remote>/main <cut-sha> <branch>` + `--force-with-lease` only for a branch nobody stands on. Then wait out the recompute window.
3. **Retarget before delete:** `gh pr merge --delete-branch` auto-closes any PR based on the deleted branch, and closed PRs with a missing base **cannot be reopened or retargeted** — `gh pr edit <child> --base main` first. Orphan recovery = rebase, force-push, fresh PRs only for a branch nobody stands on; otherwise merge main as in step 2, then open fresh PRs.
4. Conflict triage: additive manifests/lockfiles → union + regenerate the lockfile; empty/no-op rebase conflicts → the `--onto` recipe, only for a branch nobody stands on (same caveat as step 2); modify/delete in code, schemas, or tests → **stop and run the touched tests first** (deleting code the other side modified without running its suite is how broken tests ship); anything novel → surface.
5. Terminal-state check: installs differ on the final status name — confirm with `lattice show <done-ticket> --json` before completing.

**Reproduce before attributing.** Before naming the cause of a red check (a ticket's regression, a harness race, load), read the failing request's status and body and reproduce with the smallest set: the failing file alone, then with each co-tenant of its process. A failure that tracks one branch can still be shared state that branch merely exposed. **Diagnostic Captain:** the second time a failure repeats unexplained, spawn a read-only captain to reproduce and bisect it, rather than guessing again.

**Degraded mode (Orchestrator-as-captain):** direct merging from the Orchestrator session is the last resort when captain dispatch itself is blocked (e.g., a PTY wedge) — fix the underlying problem first, and log every direct merge in agents.md.

## Checkpoints and re-proofs

- **A checkpoint walks the public entry path.** Checkpoints driven through admin APIs and seeded personas never touch registration and sign-in, so a broken front door ships past all of them. Every deploy's smoke walks the path a new participant takes, end to end.
- **Scope a re-proof by what changed, not by how many merges.** Diff the proven build against the final one by path class (engine, writes and validation, pages, docs). A GET-only crawl proves reads and links, never a POST path or server-side validation.
- **Record a human checkpoint from the system's records.** When the operator says they walked something, confirm each step from logs or audit rows before marking it done; what is not in the record did not happen.

## Escalation format

Terse banners, one per condition, re-surfaced every tick while standing: `🛑 NEEDS YOUR INPUT` (the `needs_human` flag — orthogonal to status, set via `lattice needs-human <ID>`), `⛔ BLOCKED`, `✅ READY FOR REVIEW`, `🎉 DONE`, `📋 UPDATE`. The body answers three questions: what changed, what it means, what's next and whose ball it is. For hard blocks, `c11 raise-flag` on the blocked tab (one-line reason; lower it when cleared) — it escalates to the menu bar and outlives a scrolled-away banner; an OS notification (`osascript -e 'display notification ...'`) sparingly as backup; sidebar highlight color while blocked.

## Master Validator (if enabled)

Fresh tab in the Main View Area. Boot: Identity Block; read SPEC, BUILDPLAN, run-state; `/loop` on a 5-minute tick; walk delegator tabs via agents.md; check build/test/PR/CI state across worktrees; surface anomalies via `lattice comment` and sidebar flags; audit run-state against Lattice ground truth for drift. It audits and reports — it does not implement, and it does not dispatch.

## Footgun catalog (the run learns)

When a new silent-failure mode appears mid-run: (1) add a row to run-state `## Run-time footguns` (symptom → cause → mitigation); (2) fold the mitigation into every subsequent boot prompt — a catalog entry without a prompt update guarantees the next delegator hits the same wall. Promotion path: mitigated three times in one run, or seen across two runs (archived agents.md notes are the signal) → propose it as a permanent rule in this file, with the story going to `runs-ledger.md`.
