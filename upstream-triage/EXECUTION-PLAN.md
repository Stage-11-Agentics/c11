# Execution Plan — Upstream Triage Sweeps

Captured 2026-05-02 at end of the design session. This doc is the "start here" for resuming the catch-up work; once the fleet pattern below is shipped and felt, distill the durable parts into RUNBOOK.md / divergence-map.md / playbook.md and trim this file.

## Status summary

The upstream-triage system is built and on c11/main (last commit `5706c9a5`). The first sweep started in a c11 surface but was paused mid-flight on PR #2916. The big architectural decisions (the agent fleet, the compatibility-bias principle, batch sizing) were agreed in conversation but **not yet encoded in RUNBOOK / divergence-map / playbook** — that's the open work.

## What's built (on c11/main)

- `upstream-triage/RUNBOOK.md` — per-PR procedure (EVALUATE → READ → LOCATE → JUDGE → SCOPE-AGREEMENT → APPLY → VALIDATE → REPORT). Open + closed PR support. Hard rules.
- `upstream-triage/divergence-map.md` — c11 hot zones (skip vs adapt).
- `upstream-triage/playbook.md` — adaptation patterns (cmux→c11 rename, pbxproj, xcstrings, modify/delete).
- `upstream-triage/scripts/{probe.sh, list-merged.sh, analyze-hotspots.sh}` — mechanical tools.
- `upstream-triage/catchup/feature-catchup-plan.md` — strategic frame: forward-sweep first, foundations emerge from real evidence.
- `upstream-triage/triage-log/2026-05-01.md` — first decision (PR #3405 → NEEDS-HUMAN, dependency surfaced).
- `.claude/commands/upstream-triage.md` — slash-command skill.
- `tools/computer-use/{mac-adapter,openai-runner}` — OpenAI CUA harness for validation (merged via PR #100).

## What's NOT yet encoded — the agreed architecture

These decisions were made in the design session and need to land in the docs before the next sweep run.

### 1. The agent fleet (Mode B for sweeps)

Per-PR live mode (current Mode A) is good for *discovery* — surfacing big architectural collisions like the #2916 `--layout` vs c11 blueprints case. But it's too slow for the 100+ PR backlog. The agreed shape:

1. **Classifier (1 agent)** reads N PRs at a time (start at N=5), runs EVALUATE + READ + LOCATE + JUDGE + probe.sh in parallel, builds a single table:

   | # | Title | Eval | Diff | Probe | Action |

   Where Action ∈ { ATTEMPT, SCOPE-AGREE, NEEDS-HUMAN, SKIP-doesnt-fit, DEFERRED-hard }.

2. **Operator review** — table surfaces, classifier holds. Operator responds with `go` / `redirect <pr#> <new-action>` / `ask <pr#>` / `walk` / `defer <pr#>`.

3. **Implementation fleet** — for each ATTEMPT entry, spawn one parallel implementation agent. Each works on its own worktree from a pool (`/Users/atin/Projects/Stage11/code/c11-import-1` ... `c11-import-N`), each on its own `upstream/pr-<#>` branch, each opens its own c11 PR. Don't collide.

4. **CUA pass (serialized)** — the one part that **cannot** parallelize: CUA drives the live desktop, only one cursor. After all N implementations land, validate them in turn.

5. **Consolidate + report** — classifier (in coordinator role) gathers each agent's `upstream-triage/lessons/<pr-#>.md` artifacts, merges new entries into divergence-map / playbook, updates triage log, then moves to next batch.

**Design points still to nail:**

- **Per-PR lessons files, not direct edits to divergence-map / playbook.** Each implementation agent writes to `upstream-triage/lessons/<pr-#>.md`. The coordinator merges at end-of-batch. Avoids N agents trampling the same file.
- **Worktree pool, not per-PR creation.** Creating/destroying a worktree per PR is heavy (~20s per add). Maintain a pool of N worktrees, each agent claims one, returns it clean when done. Reuse across batches.
- **Failure isolation.** If one implementation agent errors, the others keep going. Coordinator surfaces the failure separately.
- **Batch size = parallel-agent count**, ideally. Start at 5; dial after we feel it.

### 2. Compatibility bias as a principle

Belongs at the top of `divergence-map.md` as a guiding principle:

> **Compatibility bias.** When c11 has a feature that overlaps with upstream's, the default move is to align c11 with upstream's naming, parameters, and shape — not to preserve c11's divergent version. Sacrifice compatibility only when there's a concrete reason (which we then document). Be conscious about those calls.

This reframes the EVALUATE step: instead of "does c11 want this *as-is*?" the question becomes "does c11 want this functionality? and if c11 already has an overlap, can we adapt c11 toward upstream rather than skip?"

### 3. The #2916 in-flight decision

PR #2916 (`Add --layout to workspace.create for programmatic split layouts`) was being triaged when the session paused. Operator's call (per the compatibility-bias principle):

> Adopt upstream's `--layout` flag and `CmuxLayoutNode` schema. Make c11's blueprint system a *superset* — it accepts upstream's shape as a sub-case of its richer schema. Compatibility-preserving + capability-additive. The PR also adds `--name` and `--description` to `new-workspace`; c11 dropped those, worth re-adding.

This is the **first real test of the compatibility-bias principle** — should be documented in the playbook as an example once landed.

The in-flight note for #2916 lives at `upstream-triage/in-flight/pr-2916.md` in the catchup worktree (`/Users/atin/Projects/Stage11/code/c11-cmux-catchup`). Verify it captures the operator's call before resuming.

## How to resume — concrete first move

When you sit back down to this:

1. **Open this file first.** Read top-to-bottom. ~5 minutes.

2. **Verify state:**
   ```bash
   cd /Users/atin/Projects/Stage11/code/c11-cmux-catchup
   git status              # should be clean or have only the in-flight note for #2916
   git log --oneline -3
   ```
   If the catchup worktree is gone or dirty, recreate from main:
   ```bash
   cd /Users/atin/Projects/Stage11/code/c11
   git fetch origin
   git worktree add /Users/atin/Projects/Stage11/code/c11-cmux-catchup -b catchup/sweep-2026-04-15 origin/main
   ```

3. **Encode the three pending pieces** (in this order, each as its own commit on c11/main):
   - **a.** Add the *Compatibility bias* principle section at the top of `upstream-triage/divergence-map.md`.
   - **b.** Add Mode B (the fleet pattern) to `upstream-triage/RUNBOOK.md`. The current RUNBOOK procedure becomes Mode A — explicit single-PR or small-list mode for discovery. Mode B is the default for `--since`/`--catchup` sweeps. Reference the design points above.
   - **c.** Add a playbook entry for the #2916 pattern once the import lands ("Aligning c11 to upstream when c11 has a richer overlap" or similar).

4. **Land #2916 first** — single agent, with the operator's compatibility-bias call. This is the discovery-phase finish; once landed, transition to Mode B for the rest.

5. **Build a thin worktree-pool helper** — `upstream-triage/scripts/worktree-pool.sh` with subcommands `init N`, `claim`, `release <path>`. Doesn't need to be fancy; a directory of N worktrees with a lockfile per slot is fine.

6. **Spawn the first Mode B batch** — N=5 PRs, classifier in one surface, 5 implementation agents in 5 sibling surfaces, all in workspace "CMUX Catch-Up". After classifier produces the table, operator reviews, classifier dispatches the implementation fleet.

## Open questions to settle before Mode B's first batch

- **Where does the classifier surface the table?** Inline in its terminal (operator scrolls), or in a fresh markdown surface (`c11 new-pane --type markdown`)? The markdown surface is more readable for a 5-row table; inline is simpler.
- **How does the operator actually respond?** Typing into the classifier's terminal works for `go` / `redirect <pr#> ...`, but is the parser robust? Worth a thin response grammar.
- **CUA validation timing** — after each implementation agent lands its PR (sequential), or after the whole batch lands (one big sequential pass)? Probably after the whole batch — the desktop only gets disrupted once per batch.
- **Failure recovery** — if implementation agent #3 fails halfway through a rewrite, what happens to its worktree slot? Coordinator should reclaim it for the next batch.
- **Lessons consolidation** — agreed in principle. Format of `upstream-triage/lessons/<pr-#>.md` is TBD; suggest `{ "divergence_additions": [...], "playbook_additions": [...] }` JSON or a templated markdown.

## Reference: what was built today (2026-05-01) and yesterday

Commits on c11/main from this design session, in order:

```
5706c9a5  upstream-triage: drop stale 'harness lives on a branch' notes
c70f9e8d  upstream-triage: point at the right harness — OpenAI CUA, not Anthropic
680d21a6  upstream-triage: add VALIDATE step using c11 computer-use harness
d862dc70  upstream-triage: EVALUATE+DIFFICULTY axes, open-PR support, forward-sweep frame
62ba106d  upstream-triage: holistic reframe — agent-driven imports, not cherry-pick pipeline
cd5c3a97  upstream-triage: first end-to-end run on PR #3405; capture lessons
285ac90e  upstream-triage: fix probe.sh empty-array expansion under set -u
965053a0  upstream-triage: probe restores original ref instead of hardcoded main
cab67713  upstream-triage: probe checks HEAD == origin/main, not branch name
4d8debdf  upstream-triage: per-PR cherry-pick flow from manaflow-ai/cmux
```

(Plus `8189d57a` — the OpenAI CUA harness merge, which was always on main but I briefly thought had been rolled back. It hadn't. Lesson: `git fetch origin` and compare local main to origin/main as the first action of any session.)

## Key references

- `upstream-triage/README.md` — orientation tour.
- `upstream-triage/RUNBOOK.md` — per-PR procedure (Mode A; Mode B to be added).
- `upstream-triage/divergence-map.md` — c11 hot zones (compat-bias principle to be added).
- `upstream-triage/playbook.md` — adaptation patterns.
- `upstream-triage/catchup/feature-catchup-plan.md` — strategic context.
- `tools/computer-use/openai-runner/README.md` — CUA harness setup.
- This file — execution plan + handoff state.

## Workspace state at handoff

- c11 workspace named "CMUX Catch-Up" (workspace:7) — close at will.
- `/Users/atin/Projects/Stage11/code/c11-cmux-catchup` worktree on `catchup/sweep-2026-04-15` branch — preserve if you want to keep the in-flight #2916 note; safe to delete and recreate.
- `/tmp/c11-probe-3405` worktree on `triage-base` — disposable; safe to delete.
- `feat/openai-cua-runner` branch on origin restored to `75455042` (matches the PR #100 source) — leave alone.
