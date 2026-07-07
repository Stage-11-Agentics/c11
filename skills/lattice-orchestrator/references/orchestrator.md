# Dispatch playbook (Phase 1 — Orchestrator)

Operational depth for running the fleet. Assumes SKILL.md and an intake completed per `references/intake.md`. Each rule is stated exactly once; boot templates reference the named blocks rather than restating them.

---

## The Identity Block (used by every spawned agent)

`$C11_SURFACE_ID` is unreliable in fresh `c11 new-surface` shells — frequently empty. An empty value makes `--surface ""` fall back to the **focused** surface, silently rewriting someone else's title and metadata. So every spawned session (delegator, sub-agent, captain, validator) begins with:

```bash
MY_SURF=$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')
test -n "$MY_SURF" || { echo "FATAL: could not resolve own surface ref"; exit 99; }
```

then uses `--surface "$MY_SURF"` on every surface-scoped write. Ticket-bound roles additionally claim **before** titling — `(cd "$REPO_ROOT" && lattice claim <TICKET-ID> --surface "$MY_SURF" --actor agent:<id>)` — because claim auto-renames the tab and the explicit title must win. Then set identity with **both** `c11 rename-tab` and `c11 set-title` (single-call propagation is unreliable), plus `set-agent` and `set-description`. `lattice unclaim` releases; claim bindings are liveness hints, not truth — they don't survive restarts.

## Standard Clauses (baked into every delegator and sub-agent prompt)

1. **Worktree assertion, line 1:** `test "$(pwd)" = "<abs-worktree>" || { echo "FATAL: wrong cwd"; exit 99; }`. On mismatch, HALT — do not `cd` to the expected worktree, do not improvise; the bug is at the spawn side and downstream repair only hides it. Line 1 because that's the only point where `pwd` reflects the launch cwd unmolested.
2. **Environment:** `export LATTICE_SPAWN_BACKEND=headless` and `export LATTICE_ROOT=<primary-checkout-root>` — never `$PWD`. A worktree carries its own `.lattice/` from its branch point; writing to that divergent board surfaces later as duplicate short IDs and unmapped tickets.
3. **Status discipline:** bump ticket status BEFORE starting each phase; only the delegator bumps (sub-agents post a completion comment and stop); verify bumps with `lattice show --json`; re-bump after triage roundtrips. Status drift is the #1 silent-failure mode of well-meaning delegators.
4. **Re-fetch at phase boundaries:** `git fetch <remote>` and record "working against <remote>/main @ <sha>"; impl phases rebase before editing.
5. **Deviate-with-flag (impl):** when the plan contradicts SPEC, the codebase, or itself — deviate and flag the contradiction, the side taken, and why, in the completion comment.
6. **Lattice items live in the root repo.** The CLI auto-routes from worktrees, but Claude's `Write` tool does not: a planner writing `.lattice/plans/<uuid>.md` by relative path lands it in the worktree's shadow copy — the parent plan file stays an empty scaffold and plan-review reads stale content. Plan files are written with the **absolute parent-repo path**. (Recovery: the planner's context still holds the plan — nudge it to re-Write to the absolute path.) `Invalid transition` errors usually mean wrong `LATTICE_ROOT` or an old install, not corrupted state.
7. **Monitor/watcher paths include `.lattice/`:** a watcher on `$REPO_ROOT/plans/...` (missing the `.lattice/` segment) silently never fires and the run stalls.
8. **Source paths in prompts are worktree-relative.** An absolute parent-repo path in an impl prompt sends edits to the parent working tree: the feature branch ends up empty while uncommitted changes pile up in the wrong checkout. Write prompts as if typing at a shell prompt inside the worktree. The Clause-2 "absolute parent path for `.lattice` writes" rule bleeds: delegators over-generalize it to source files — so every boot prompt also carries a **pre-commit guard**: `test "$(git rev-parse --show-toplevel)" = "<abs-worktree>"` before each commit. Recovery when a commit still lands on the parent checkout's main: freeze the delegator, cherry-pick the stray commit onto the feature branch, then restore the parent with per-file `git restore` + `git reset --soft` — **never `reset --hard` a checkout whose `.lattice/` is the live board** (the working tree is the database; a hard reset destroys run events).
9. **Sub-agents live in c11 surfaces, never headless `claude -p &` shells** — headless background shells break the c11 auth chain, are invisible to the operator, and lose sidebar telemetry.
10. **Verify the push landed:** after `git push`, `git fetch <remote> && test "$(git rev-parse HEAD)" = "$(git rev-parse <remote>/<branch>)"` and re-push until equal. A silently-failed push — or a commit leaked onto the root checkout's `main` — is the #1 false-completion mode. Then confirm the PR's `head.sha != base.sha`.
11. **Cadence:** `/loop` with a 60-second tick; never bash `sleep`/`watch`/`lattice watch --exec` (subprocess loops die on compaction, can't re-enter the model, and are invisible to the harness). **Once you say `Loop ended`, you're dead** — no `send-key` revives a terminated loop, so do post-PR cleanup before ending it. (Codex has no `/loop`; use explicit `codex exec` re-invocations and flag the difference.)
12. **Stop after the completion comment.** Sub-agents do not bump status and do not address the operator; the delegator is the only interface upward. Read-before-Write on pre-existing files (plan files are scaffolded at ticket creation — the path always exists).

## Spawning: atomic cwd binding

`c11 new-surface --pane <ref>` inherits the pane's *last* shell cwd — set by whichever sibling tab most recently ran `cd`. Non-deterministic; an un-anchored sub-agent lands in some other delegator's worktree. And Claude Code's Bash tool does not persist `cd` across tool calls. Therefore every launch line is atomic:

```bash
c11 new-surface --pane "$DELEGATE_PANE" --no-focus            # capture the new surface ref
c11 send --workspace $WS --surface $NEW_SURF "cd <abs-worktree> && claude --dangerously-skip-permissions --model <model> \"Read <prompt-path> and follow the instructions.\""
c11 send-key --workspace $WS --surface $NEW_SURF enter
```

The send + explicit `send-key enter` two-step is the durable Claude-to-Claude handoff. Stage prompts at `<worktree>/.lattice/tmp-prompts/<phase>-prompt.md` (physically bound to the worktree); a `/tmp/<proj>-<n>-<phase>-prompt.md` path is acceptable only with an atomic launch plus the receiver guard (Standard Clause 1).

## Worktree prep (at dispatch)

```bash
git worktree add <repo>-worktrees/<ticket-slug> -b <branch> <base>
```

Base is `<remote>/main` — or the parent's branch for press-ahead children. Then **propagate gitignored credentials**: copy the root checkout's `.env` (and `~/.netrc`-style material where the project needs it) into the worktree at create time; without it, impl phases die mid-tool-call on confusing "missing secret" errors.

## The dispatch loop

Tick body: (1) refresh — run-state, Lattice board, `c11 tree`, rewrite agents.md active table; (2) surface escalations — re-banner **every tick** while `needs_human`/`blocked` stands (a banner that scrolled away 30 minutes ago is the same as silence); (3) press-ahead audit over unspawned tickets; (4) auto-merge pass if enabled; (5) auto-close finished surfaces (`c11 close-surface` — it reaps children; `/quit` does not, and orphaned review subprocesses can keep spawning panes after merge); (6) spawn next available delegators, routed to the lightest-loaded delegate pane; (7) `ScheduleWakeup` — one pending wake at a time.

**Cadence:** active dispatch 270s (inside the 5-minute prompt-cache window); quiescent 1200–1800s; never 300s (pays the cache miss without amortizing it). End the loop explicitly at run completion; silence after closeout is correct.

## Reading delegators, and recovery

Three tells: bare `❯` with no indicator = genuinely idle; `✻ <verb> for Xm` plus an "N shells running" footer = background task, don't intervene; `✻` with no footer = thinking, wait. Don't take an operator's "looks idle" at face value.

The canonical stall tell is a **cost counter frozen across 2+ ticks**. Diagnose before nudging: frozen cost + a live shell footer usually means a legitimately long-running command — `pgrep -fl "<worktree-slug>.*<suite>"` for a live PID, and read tee'd logs for buffered progress. Frozen cost + live shell = background-watching, not a stall.

- Real stall → `c11 send` an "ORCHESTRATOR NOTE: cost frozen N ticks — report status and continue" **plus** `send-key enter`. Never trust `send-key enter` alone — the TUI sometimes swallows synthetic Return; always pair it with a fresh `send`.
- Auth halt (`⎿ Not logged in · Please run /login` in a deep screen read — typically after the operator swaps accounts mid-run) → once restored, send "auth restored, retry the tool call, resume /loop".
- Queued-but-unsubmitted text (cost moves slightly, input box shows stuck content) → a new `send` replaces the buffer.
- Two consecutive dead sends → the session is dead; surface to the operator and offer a respawn from the latest commit. Dead-session state recovery itself belongs to c11 (workspace persistence + session-resume hook), not the Orchestrator.

## Mode boot templates

Every template begins with Standard Clause 1 (worktree assertion), the Clause-2 environment exports, and the Identity Block, then claims its ticket. Phase arcs below substitute the pinned status vocabulary for any literal:

**Fast-track** (no sub-agents, no headless reviews, no `/loop` — runs synchronously):
1. *Plan* — bump `in_planning`; write the plan to `$LATTICE_ROOT/.lattice/plans/<task_uuid>.md` (absolute path, Clause 6); bump `planned`.
2. *Implement* — bump `in_progress`; fetch/rebase; edit + tests; commit.
3. *Self-review* — bump `review`; attach the verdict: `lattice attach <ID> --type note --role review --inline "<verdict>" --actor agent:<id>-reviewer`.
4. *Validate* — bump `in_validation`; exercise the change end-to-end (browser, simulator, curl — whatever proves behavior); attach evidence `--role validation` (or a one-line justified N/A). The terminal pre-merge status is **gated on this artifact**.
5. *PR* — push with Clause-10 verification; attach the PR as a `--type reference`; bump to the terminal pre-merge status. Stop there — the Orchestrator merges and completes.

**Inline-full** (default for medium work — fresh eyes without PTY pressure): the fast-track arc plus
- after *Plan*: headless plan-review — `(cd $LATTICE_ROOT && lattice plan-review <ID> --mode single --actor agent:<id>-plan-reviewer)`; triage findings into an amendment block (below); restore the tab title after every lattice review call (the CLI sometimes clobbers it).
- after *Implement*: headless code-review under the 600-second rule (below); a fix phase if Critical/Major findings.
- `/loop` with a 60s tick between phases; post the completion comment and end the loop only after cleanup.

**Sub-agent-full** (escalation only): planner, impl, and fix sub-agents as new tabs on the delegator's pane, each launched atomically with the Standard Clauses; the delegator coordinates, watches plan files via Monitor (Clause 7), and owns all status bumps. The impl phase additionally scans open PRs for cross-ticket contracts (`gh pr list` / the forgejo equivalent; honor "open contract" and "lock in before X" notes). At PR time, create the PR and bump status as **parallel calls in the same batch** — never sequence them.

**Plan-validation variant:** when dispatch targets a ticket already `planned` (pre-planned upstream or in a prior run), the delegator does *not* re-plan. It reads the existing plan against the current SPEC and parent-branch code: aligned → one comment ("plan revalidated; no amendments") → impl; mechanical drift → append an amendment block → impl; architectural drift → amendment block + re-run headless plan-review.

## Reviews

- **Force the headless backend.** `lattice plan-review` / `code-review` internally spawn an agent with backend auto-select `cmux → terminal → headless`; inside c11 the cmux backend wins and spawns each reviewer into a **brand-new c11 workspace** — a 15-ticket run can shed ~30 stray workspaces. `LATTICE_SPAWN_BACKEND=headless` (Clause 2) plus `--mode single` prevents it. Flag names drift across installs (`No such option: --headless` means rely on the env var). Never `c11 send` the review command into a separate surface — fresh surfaces start in `$HOME` with no `.lattice/`.
- **The 600-second rule (HARD).** Code-review invoked from a worktree fails often enough that the fallback is documented behavior, not an exception. Wrap it: `(cd <WORKTREE> && timeout 600 bash -c "LATTICE_SPAWN_BACKEND=headless lattice code-review <ID> --mode single --base <remote>/main --actor agent:<id>-reviewer")` (macOS without coreutils: `gtimeout`, or background-job + kill). On RC 124, an empty diff, or a vacuous review — pivot immediately to the **own-reviewer fallback**: compute the diff yourself (`git log <remote>/main..HEAD --stat` + per-file diffs), write a review in the standard shape (Verdict PASS / PASS-WITH-NITS / FAIL; Critical/Major/Minor/NIT findings with file:line + recommendation), attach it `--role review`, and note "own-reviewer fallback, CLI hung/empty" in the completion comment and decision log.
- **Base is `<remote>/main`, never bare `main`.** Post-merge they differ; bare `main` produces an empty diff that reads as a clean review.
- **Amendment blocks.** Never proceed to impl with untriaged plan-review findings — the impl agent stalls (correctly) on stale guidance. Triage each finding (obvious / evolutionary / complex → `needs_human`) and append to the plan file: `## N. Plan-Review Cycle K Resolutions (AUTHORITATIVE — overrides earlier text on conflict)` with per-finding concern / resolution / section affected. Impl prompts state that the latest Resolutions block is binding. Re-review only when findings were architectural or numerous.

## Verified state, not reported state

The single highest-leverage discipline in an auto-merge run — never act on what an agent *said* happened:

- Branch exists remotely: `git ls-remote <remote> refs/heads/<branch>` non-empty; PR non-empty: `head.sha != base.sha`. **An empty PR (head==base) is the dominant cause of a Forgejo `405 "Please try again later"` on merge — that is the empty-PR symptom, not a transient queue, and `force_merge` won't fix it.**
- Merging: capture the HTTP code (`-w "%{http_code}"`); **never `curl -sf` a merge** — `-f` swallows the error body that says what failed. Re-GET the PR and assert `.merged == true` before `lattice complete`.
- Before pushing any shared branch: `git log <remote>/main..HEAD` contains only intended commits, and `git rev-parse --show-toplevel` is the expected checkout. Never wrap a commit/push in or after `cd <root-repo>` — a commit inheriting the root cwd lands on the root checkout's `main`, the feature branch looks empty, and the work hides on the wrong branch.

## Press-ahead

Spawn dependents when a dependency reaches `review` or the terminal pre-merge status — not at merge.

**Planning-only variant (merge-barrier runs).** When the run config forbids cutting dependent branches before the dependency merges, press-ahead still applies to *planning*: spawn the dependent delegators at the dependency's `review` in a **scratch-sandbox cwd** (no worktree, no branch), reading the in-review branch's code shape read-only, writing plans to the board, and halting at `planned` until an explicit `RESUME IMPLEMENTATION` message names their post-merge worktree. Costs zero barrier wall-clock; the sandbox cwd also means a confused delegator has no repo to damage. After every transition, audit all unspawned tickets; default to spawning; don't wait for operator approval to start an unblocked ticket. Children branch **off the in-review parent** (`git worktree add ... -b <child> <remote>/<parent-branch>`), never off main — they inherit the parent's interfaces import-stable. The child PR body names its anchor ("based on #N — merge that first; this rebases"), and the anchor is recorded in run-state's ticket table.

## Auto-merge (opt-in at Phase 0)

Per PR, in dependency order (parent first): verify state (above) → mergeability check with plain `curl -s` (`.mergeable`, `.has_merge_conflicts`) → squash-merge with the HTTP code captured → re-GET `.merged == true` → `lattice complete <ID> --review "Merged via auto-merge (PR #N, squash)" --actor ...` → close the delegator surface. Forgejo PAT via `security find-internet-password -s forgejo.stage11.ai -w`. After merging a parent: the child rebases onto the new `<remote>/main`, `git push --force-with-lease`, then **wait out the forge's mergeability recompute** (~5–15s Forgejo, 10–25s GitHub) before merging the child.

- **Additive-registration conflicts** (`__init__.py` re-exports, CLI/plugin registries): resolve as the union, ordered by ticket ID — the standing pattern. Real semantic conflicts → escalate with a `🛑` banner.
- **A squash-merged parent is NOT an ancestor of its children.** `git merge-base --is-ancestor` returns false even though the content landed, and child PRs show phantom diffs. Don't gate on ancestry after squash — gate on validating the assembled tree.
- **Deep stacks:** prefer one `integration/<run>` branch — merge leaf tips in dependency order, validate the assembled tree once (assembled-tree checks catch what per-PR review can't), single PR to main, close the individual PRs with a "merged via integration/<run>" comment.
- Record every auto-merge in agents.md.

## Captains

One-shot recovery agents for cross-cutting batch work (a Merge Captain, a Rebase Captain, a Status Captain) — distinct from delegators (ticket-scoped) and sub-agents (phase-scoped). Name them `<Scope> Captain`; spawn a fresh one per engagement rather than re-tasking the last.

**Merge Captain** — for the stacked-branches-after-squash artifact (every PR after the first hits conflicts; expect it on nearly all stacked PRs, ~1–2 minutes each):
1. Hygiene first: `git -C <wt> reset --hard HEAD && git -C <wt> clean -fd` per worktree.
2. Mechanical fix: `git rebase --onto <remote>/main <cut-sha> <branch>` + `--force-with-lease`, then wait out the recompute window.
3. **Retarget before delete:** `gh pr merge --delete-branch` auto-closes any PR based on the deleted branch, and closed PRs with a missing base **cannot be reopened or retargeted** — `gh pr edit <child> --base main` first. Orphan recovery = rebase, force-push, fresh PRs.
4. Conflict triage: additive manifests/lockfiles → union + regenerate the lockfile; empty/no-op rebase conflicts → the `--onto` recipe; modify/delete in code, schemas, or tests → **stop and run the touched tests first** (deleting code the other side modified without running its suite is how broken tests ship); anything novel → surface.
5. Terminal-state check: installs differ on the final status name — confirm with `lattice show <done-ticket> --json` before completing.

**Degraded mode (Orchestrator-as-captain):** direct merging from the Orchestrator session is the last resort when captain dispatch itself is blocked (e.g., a PTY wedge) — fix the underlying problem first, and log every direct merge in agents.md.

## Escalation format

Terse banners, one per condition, re-surfaced every tick while standing: `🛑 NEEDS YOUR INPUT` (the `needs_human` flag — orthogonal to status, set via `lattice needs-human <ID>`), `⛔ BLOCKED`, `✅ READY FOR REVIEW`, `🎉 DONE`, `📋 UPDATE`. The body answers three questions: what changed, what it means, what's next and whose ball it is. An OS notification (`osascript -e 'display notification ...'`) sparingly for hard blocks; sidebar highlight color while blocked.

## Master Validator (if enabled)

Fresh tab in the Main View Area. Boot: Identity Block; read SPEC, BUILDPLAN, run-state; `/loop` on a 5-minute tick; walk delegator surfaces via agents.md; check build/test/PR/CI state across worktrees; surface anomalies via `lattice comment` and sidebar flags; audit run-state against Lattice ground truth for drift. It audits and reports — it does not implement, and it does not dispatch.

## Footgun catalog (the run learns)

When a new silent-failure mode appears mid-run: (1) add a row to run-state `## Run-time footguns` (symptom → cause → mitigation); (2) fold the mitigation into every subsequent boot prompt — a catalog entry without a prompt update guarantees the next delegator hits the same wall. Promotion path: mitigated three times in one run, or seen across two runs (archived agents.md notes are the signal) → propose it as a permanent rule in this file, with the story going to `runs-ledger.md`.
