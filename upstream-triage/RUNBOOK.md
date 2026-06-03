# RUNBOOK — `/upstream-triage`

You are an agent importing upstream cmux PRs into c11. **You are doing the import, not orchestrating a pipeline.** The tools (probe, divergence map, playbook) help you think and act faster, they don't decide for you.

Your job per PR: *decide whether c11 wants this, judge how hard it is, and if it's worth the effort, write the c11 version of it.*

## Modes

The runbook supports two modes. Pick one per session.

- **Mode A: per-PR live.** A single agent walks through one PR (or a small explicit list) end-to-end with the operator in the loop. The procedure below ("Setup", "The per-PR loop", "Open vs closed PRs", "Working with the operator") is Mode A. Use it for discovery work, big architectural collisions, or any PR where the agent expects to surface scope questions live. Slow, high-context, high-fidelity.
- **Mode B: fleet sweep.** A classifier reads N PRs at a time, builds a single decision table, takes one batch-level approval from the operator, then dispatches a parallel implementation fleet across a worktree pool. CUA validation runs serialized at the end of the batch. See "Mode B: fleet sweep" below. Use it for `--since` or `--catchup` runs where Mode A would not finish in this lifetime. Fast, lower-context.

Default is Mode A for an arbitrary PR or a small named list. Default is Mode B when sweeping a backlog (operator says "catch us up to upstream" or names a date range).

Mode B reuses every primitive from Mode A: same EVALUATE / READ / LOCATE / JUDGE / APPLY / VALIDATE / REPORT vocabulary, same hard rules. The difference is the wrapper flow: who runs which step, how the batch is approved, where the work happens.

## Setup (once per run)

1. Confirm cwd is the c11 repo root (or a worktree of it).
2. `git fetch upstream main` and `git fetch origin main`.
3. Open today's triage log at `upstream-triage/triage-log/<YYYY-MM-DD>.md` (create if missing). Append, don't overwrite.
4. Read `divergence-map.md` and `playbook.md` into context. These are the agent's prior knowledge about c11.
5. Working tree must be clean for any apply step. If main is dirty, prefer running in a worktree (`git worktree add /tmp/c11-triage main`) or stashing the user's work *only with their explicit OK*.

## The per-PR loop

For every PR — open or closed, merged or unmerged — work through these steps in order. Skip later steps when an earlier one resolves the PR.

### 1. EVALUATE — does c11 want this?

Before any technical work, judge desirability. Read upstream PR title + body + linked issue.

Three outcomes:

- **Yes** — fits c11's direction. Continue.
- **No** — doesn't fit. Log `SKIP-doesnt-fit` with a one-sentence reason. Move to next PR. Don't waste time on the technical analysis.
- **Maybe** — gray area. Surface to the operator: "PR #N does X. c11 already has Y, which overlaps but differs in Z. Want it?" Wait for an answer before continuing.

Common SKIP reasons:
- Functionality c11 has chosen to do differently (different settings model, different panel system, etc.)
- cmux-specific direction (branding, features tied to manaflow's product vision)
- The PR is closed-without-merge upstream because it was a bad idea — usually, but not always, also a bad idea for c11

EVALUATE is **not** about whether the change is technically clean. That's later.

### 2. READ — understand intent

Pull the full upstream context:

```bash
gh pr view <N> --repo manaflow-ai/cmux --json title,body,files,additions,deletions,author,state,mergeCommit,headRefOid,baseRefName,mergedAt,comments
```

Form a one-sentence understanding of what this PR *does* — not the diff shape, the intent. ("Adds a backdrop layer behind the sidebar tint." "Adds a setting for terminal-background-matching.")

If intent isn't clear from title + body + diff, read the linked issue, PR comments, or related code. Don't proceed on a guess.

### 3. LOCATE — find the c11 equivalents

For each upstream file the PR touches, ask:

- **Same path exists in c11** → standard case.
- **Path renamed** (e.g. `cmuxApp.swift` → `c11App.swift`) → see playbook entry "cmux → c11 entry-point rename".
- **Path doesn't exist on c11** → upstream introduced it after our merge-base. The PR likely depends on an upstream feature c11 hasn't imported yet. See playbook entry "Modify/delete — file doesn't exist on c11".
- **Concept exists in a different place** (upstream changes a setting that c11 has reorganized) → translate.

### 4. JUDGE — how hard is this, and what's the right approach?

Now you have the upstream intent and the c11 target shape. Assess two things:

#### Difficulty (easy / moderate / hard)

- **Easy** — 1–3 files, no `adapt`-zone paths in divergence map, no rename pattern, no missing-on-c11 dependency, clean cherry-pick probable.
- **Moderate** — 4–10 files, **or** touches one `adapt` zone, **or** has the cmux→c11 rename pattern, **or** small adaptations needed around c11's panel system / theming.
- **Hard** — many files (>10), **or** multiple `adapt` zones, **or** depends on un-imported upstream features, **or** requires architectural rework.

Atin biases toward easy work. Easy + Yes imports should land with minimal ceremony; hard ones get focused sessions.

#### Approach (cherry-pick clean / cherry-pick with resolution / rewrite)

Three paths, in increasing cost:

- **Cherry-pick clean** — upstream commit applies as-is. Use this when probe reports `STATUS=clean`. No rewrite needed.
- **Cherry-pick with manual conflict resolution** — small, mechanical conflicts (a few hunks). Resolve, continue, commit.
- **Rewrite** — read the upstream diff as a *spec*, then write the c11 version. Apply the same semantic change to c11's current code. Translate paths, naming, and any structural differences. The result is a c11-authored commit that quotes the upstream PR for lineage.

Probe the PR (`upstream-triage/scripts/probe.sh <N>`) to inform this call when the PR has a merge commit. For open PRs without a merge commit, the probe falls back to the head SHA.

### 5. SCOPE AGREEMENT (conditional — non-trivial work only)

For **moderate or hard** work, **or** for **maybe-fit** PRs, write a short scope-and-approach note in `upstream-triage/in-flight/<feature-or-pr>.md`:

```markdown
# upstream PR #<N> — <title>

**Evaluate:** yes / maybe — <reason>
**Difficulty:** moderate / hard
**Approach:** cherry-pick with resolution / rewrite

## What this PR does
<one paragraph in plain language>

## How I'd land it on c11
<2–5 bullets — files I'd touch, anything I'd skip, any adaptation>

## Open questions
<bullets, if any>
```

Then wait for the operator's nod. Don't push.

For **easy + clear-yes** PRs, no scope note is required. Just land them. Batch the `easy + yes` ones into the triage log without per-PR ceremony.

### 6. APPLY

Choose the path matching the JUDGE step.

After APPLY, before REPORT, run **VALIDATE** for any user-visible feature change.

**Cherry-pick (clean or with conflict resolution):**

```bash
./upstream-triage/scripts/probe.sh <N>
# STATUS=clean: branch ready, push and open PR.
# STATUS=conflict, mechanical: resolve, git cherry-pick --continue, push, open PR.
# STATUS=conflict, non-trivial: switch to rewrite path.
```

**Rewrite:**

1. Fresh branch off main: `git checkout -b upstream/pr-<N> main`.
2. Apply the same semantic change to c11. The upstream diff is a guide; the c11 codebase is the target.
3. Commit with the upstream author attribution preserved:
   ```bash
   git commit \
     --author="<upstream-login> <upstream-email>" \
     -m "[upstream #<N>] <upstream title>" \
     -m "Adapted for c11. Original: https://github.com/manaflow-ai/cmux/pull/<N>"
   ```

Either path ends with: branch pushed, c11 PR opened, agent does *not* merge.

### 6b. VALIDATE — drive the feature in c11.app via the OpenAI CUA harness

For any import that touches user-visible behavior (UI, settings, panels, terminal, browser surfaces, sidebar, menus, hotkeys), the agent runs the **OpenAI CUA harness** to confirm the imported feature actually works *and looks right* in a real c11 build before declaring the PR ready.

The harness has two parts, both at `tools/computer-use/`:

- `mac-adapter/` — Swift CLI (`cua-mac-adapter`) for window discovery, screenshots, and input events on macOS.
- `openai-runner/` — Python runner (`openai_cua_runner`) using OpenAI Responses API's `computer` tool, with pre-baked scenarios (`launch-window`, `create-split`, `focus-and-type`, etc.).

It drives a tagged c11 DEV build (default bundle id `com.stage11.c11.debug.openai.cua`, default app path `~/Library/Developer/Xcode/DerivedData/c11-openai-cua/Build/Products/Debug/c11 DEV openai-cua.app`).

Key commands (run from c11 repo root):

```bash
# Build the mac adapter (one-time, then on adapter changes):
swift build --package-path tools/computer-use/mac-adapter

# Confirm permissions and harness wiring:
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner doctor --tag openai-cua

# Run a pre-baked scenario (with --build to rebuild the tagged c11 app first):
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner scenario <name> --tag openai-cua --build

# Run a custom validation task:
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner smoke --tag openai-cua --prompt "<validation prompt>"
```

The runner reads `OPENAI_API_KEY` from the environment. Artifacts (transcripts, screenshots) write to `artifacts/openai-cua-runs/`.

**When to validate (and when to skip):**

- **Validate** — UI changes, new settings, sidebar/panel work, hotkeys, menus, browser/terminal surface behavior. Anything an operator would feel.
- **Skip validate** — purely internal refactors, dependency bumps, build/CI config, agent-instruction docs, comment-only changes. CI catches breakage; CUA adds no signal.

**How to validate:**

1. Build the c11 PR's branch as a tagged DEV build via `./scripts/reload.sh --tag openai-cua` (or pass `--build` to the runner).
2. Compose a validation prompt that names the feature and the path the operator would take to use it. Pull the language from the upstream PR body when useful. If a pre-baked scenario fits, use it.
3. Run the appropriate runner command. The harness produces a transcript + screenshots in `artifacts/openai-cua-runs/`.
4. Read the verdict:
   - **Pass** — the feature works and looks right. Note this in the c11 PR body and proceed to REPORT.
   - **Fail** — the import has a real problem. Either fix on the same branch and re-validate, or escalate as NEEDS-HUMAN if the fix is beyond scope.
5. Attach the validation outcome to the c11 PR — either as a body section ("## Validation") or as a comment, including a link/path to the run artifacts.

**Operational notes:**

- The harness drives the operator's live desktop. The agent must announce before running so the operator isn't surprised by the cursor moving.
- Don't validate trivial (purely internal) changes — the harness time isn't free and adds no signal.
- If `doctor` fails, fix the harness setup before continuing the sweep — don't ship un-validated UI changes silently.

> **Status note:** the OpenAI CUA harness is on c11/main at `tools/computer-use/` (merged via PR #100 on 2026-04-30). Build the mac adapter once with `swift build --package-path tools/computer-use/mac-adapter`, then run `doctor` to confirm permissions. Validation is live for any user-visible PR import.

### 7. REPORT

Append a block to `triage-log/<YYYY-MM-DD>.md` for every PR processed:

```markdown
## #<N> — <title>

- **Evaluate:** yes / no / maybe
- **Difficulty:** easy / moderate / hard (only for evaluate=yes/maybe)
- **Decision:** LANDED-cherry-pick | LANDED-rewrite | NEEDS-HUMAN | SKIP-doesnt-fit | SKIP-blocked-by-#<N> | DEFERRED-hard
- **Author:** <upstream login>
- **State:** merged / open / closed-not-merged
- **Files (upstream):** <count>, +<add> -<del>
- **c11 PR:** <link if opened, else —>
- **Approach:** <one sentence>
- **Validation:** pass / fail / skipped (internal-only) / skipped (no harness)
- **Notes:** <reasoning, links to playbook entries used, dependencies surfaced>
- **Validation run:** <path or run-id, only when applicable>
```

For **easy + yes** sweeps, batch the entries — one shared block can cover several PRs if they were all cherry-pick clean.

If a non-obvious adaptation pattern came up, also update `playbook.md`. If a previously unmapped divergent area surfaced, also update `divergence-map.md`. Commit those updates as a separate commit on main: `chore(triage): update divergence map and playbook from <date> run`.

## Open vs closed PRs

The flow is the same regardless of PR state. Differences:

- **Closed and merged** — has a `mergeCommit`. probe.sh uses that. Default lane.
- **Closed without merge** — no merge commit. EVALUATE skews toward `no` (upstream didn't take it for a reason), but not always — sometimes the work is good, just blocked on cmux-specific concerns. Treat as a "maybe" at minimum and look at the PR's close-comments.
- **Open** — no merge commit. probe.sh falls back to `headRefOid` and cherry-picks the range from the PR's `baseRefName`. Risk: the PR may evolve or be abandoned upstream after we import; flag this in the PR body.

## Working with the operator

The agent works *with* the operator, not autonomously.

- **No surprises before push.** If the c11 PR will visibly differ from the upstream PR (rewrite, partial import, scope cut), explain in the PR body.
- **Escalate, don't guess.** If you're under 80% confident on a judgment call, pause and ask. Cost of pausing is a sentence; cost of a wrong import is a revert.
- **Batch the small stuff.** Don't ask the operator to weigh in on every cherry-pick that lands clean. Easy + yes imports just land.
- **Stack the hard stuff for focused sessions.** Don't try to drive a hard PR in the middle of an easy-sweep batch. Log it as DEFERRED-hard and surface as a candidate for its own session.

## PR shape

**Branch name:** `upstream/pr-<N>`

**Title:** `[upstream #<N>] <original title>`

**Body template:**

```markdown
Imports manaflow-ai/cmux#<N>: <title>

Original author: @<upstream-login>
Upstream PR: https://github.com/manaflow-ai/cmux/pull/<N>
Upstream state: merged / open / closed-not-merged
Upstream commit: <sha> (merge commit, or head if open)

## Approach

<one of:>

- **Cherry-pick (clean).** Applied without modification.
- **Cherry-pick (resolved).** Conflicts in <files>; resolved by <one-line summary>.
- **Rewrite.** Upstream diff applied semantically to c11's structure. Differences from upstream:
  - <bullet>

## What this changes in c11

<one paragraph in plain language. Helps the reviewer judge fit without re-reading both diffs.>

Triage log: upstream-triage/triage-log/<date>.md#<N>
```

**Labels:** `upstream-import` (create if missing).

**Do not** auto-merge. The operator reviews and merges.

## Mode B: fleet sweep

Mode B is for sweeping a backlog. The unit of work is a **batch** of N PRs, not a single PR. One agent fills two roles across the batch's life: **classifier** at the start, **coordinator** at the end. N parallel **implementation agents** do the actual import.

### Roles

- **Classifier / coordinator (1 agent).** Reads N PRs, runs EVALUATE+READ+LOCATE+JUDGE+probe in parallel, builds the decision table, holds for operator review. After the implementation fleet finishes, switches to coordinator: collects per-PR lessons, merges into divergence-map and playbook, runs the serialized CUA pass, updates the triage log.
- **Implementation agents (N).** Each claims one row from the table, claims one worktree slot from the pool, lands its PR (cherry-pick or rewrite), opens a c11 PR, writes its lessons file, releases its slot. Does not edit divergence-map or playbook directly.
- **Operator.** One review point per batch (the table). Optional second review at end-of-batch to merge the c11 PRs.

### The batch loop

1. **Classify.** Classifier picks N PRs (default N=5; tune to feel). For each PR, runs EVALUATE + READ + LOCATE + JUDGE + `probe.sh` in parallel, then assigns one Action:

   | Action | Meaning |
   |---|---|
   | `ATTEMPT` | Easy or moderate, clear-yes; fleet can land it without scope ceremony. |
   | `SCOPE-AGREE` | Moderate or hard with a real scope question; needs an in-flight scope note before APPLY. |
   | `NEEDS-HUMAN` | Real architectural call (overlap, cross-cutting, ambiguous fit). Operator decides direction. |
   | `SKIP-doesnt-fit` | EVALUATE = no. One-line reason. |
   | `DEFERRED-hard` | EVALUATE = yes, Difficulty = hard. Stack for a focused session. |

   Output: one markdown table at `upstream-triage/batches/<YYYY-MM-DD>-batch-<n>.md`:

   ```markdown
   | # | Title | Eval | Diff | Probe | Action |
   |---|-------|------|------|-------|--------|
   | 2916 | Add `--layout` to workspace.create | maybe | moderate | conflict | NEEDS-HUMAN |
   | ...  | ...                                | ...   | ...      | ...      | ...         |
   ```

2. **Operator review.** Classifier surfaces the table. Default surface is a c11 markdown surface (`c11 new-pane --type markdown`) for any table over 3 rows; inline scrollback is fine for shorter tables. Operator responds with this thin grammar:

   - `go`: accept the table as written, dispatch the fleet.
   - `redirect <pr#> <new-action>`: change one row's Action. Chainable: `redirect 2916 SCOPE-AGREE; redirect 3411 SKIP-doesnt-fit`.
   - `ask <pr#>`: operator wants to talk about this row first. Classifier holds that row, dispatches the rest.
   - `defer <pr#>`: move row to DEFERRED-hard.
   - `walk`: abandon the batch. Nothing dispatches.

   Classifier holds until `go` or `walk`.

3. **Dispatch the fleet.** For each `ATTEMPT` and `SCOPE-AGREE` row:
   - Implementation agent claims a worktree slot via `upstream-triage/scripts/worktree-pool.sh claim`.
   - For `SCOPE-AGREE` rows, agent writes the in-flight scope note first and waits for the operator's nod before APPLY.
   - Agent runs Mode A's APPLY step on its slot (cherry-pick or rewrite per JUDGE).
   - Agent pushes branch, opens c11 PR, writes `upstream-triage/lessons/<pr-#>.md`, releases its slot.
   - Agents do not touch divergence-map or playbook. Those land at consolidate time.

4. **Validate (serialized).** After all `ATTEMPT` and `SCOPE-AGREE` agents finish, the coordinator runs the OpenAI CUA harness once per user-visible PR, in turn. The desktop has one cursor; this step does not parallelize. Each PR gets a Validation section in its body before merge-readiness. Skip validation for PRs that are purely internal (per the VALIDATE step's skip list).

5. **Consolidate.** Coordinator:
   - Reads each `upstream-triage/lessons/<pr-#>.md`.
   - Merges divergence-map and playbook additions into the canonical files. Commits as `chore(triage): consolidate <date> batch <n>`.
   - Appends one combined block to `triage-log/<YYYY-MM-DD>.md` covering the batch.
   - Surfaces the batch's c11 PRs to the operator for merge review.

### Worktree pool

Mode B uses a long-lived pool of worktrees, not per-PR creation. Per-PR `git worktree add` is roughly 20s of overhead per dispatch; over a 5-PR batch that is a minute of nothing.

- Pool location: `c11-worktrees/import-pool-1` ... `c11-worktrees/import-pool-N`. (Matches the existing `c11-worktrees/` convention; do not put pool slots at the top level of `code/`.)
- Each slot has its own lockfile (`.claimed-by-<agent-id>` inside the slot's `.git/`).
- `worktree-pool.sh init <N>` creates slots from `origin/main`.
- `worktree-pool.sh claim` returns a free slot path, marks it claimed.
- `worktree-pool.sh release <path>` resets the slot (`git checkout main && git reset --hard origin/main && git clean -fd`), removes the lock.
- Slots are reused across batches. The pool is a fixture, not a per-batch artifact.

### Per-PR lessons files

Implementation agents write to `upstream-triage/lessons/<pr-#>.md`, never directly to divergence-map or playbook. This avoids N agents trampling the same file. Format:

```markdown
# Lessons: PR #<N>

## Divergence-map additions
<bulleted updates with rationale, or `none`>

## Playbook additions
<bulleted patterns the playbook needs, or `none`>

## Notes for the operator
<anything worth surfacing at consolidate time>
```

Coordinator merges these at end of batch.

### Failure isolation

If implementation agent #3 errors mid-import, agents #1, #2, #4, #5 keep going. Coordinator surfaces #3's failure separately at consolidate time. Slot reclamation: coordinator runs `worktree-pool.sh release <slot>` during cleanup. The failed PR drops to `NEEDS-HUMAN` for the next batch.

### Tuning

- **Batch size N.** Start at 5. Dial after a few runs. The constraint is parallel-agent count, not classifier throughput.
- **Validation timing.** Default is "validate at end of batch". If the desktop is the operator's daily driver, run validation in a quiet window.
- **When to skip Mode B.** Single PR with a known architectural collision. Operator wants to drive judgment live. Backlog is empty.

## Hard rules

- Never push to `manaflow-ai/cmux`. (Already blocked at git-config level.)
- Never force-push the `upstream/pr-<N>` branches.
- Never auto-merge c11 PRs.
- Never operate on a dirty working tree without operator OK. Prefer worktrees.
- Never run more than one apply at a time.
- When unsure, ask. Cheap to pause, expensive to revert.
