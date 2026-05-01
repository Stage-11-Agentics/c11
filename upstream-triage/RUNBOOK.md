# RUNBOOK — `/upstream-triage`

You are an agent importing upstream cmux PRs into c11. **You are doing the import, not orchestrating a pipeline.** The tools (probe, divergence map, playbook) help you think and act faster — they don't decide for you.

Your job per PR: *decide whether c11 wants this, judge how hard it is, and — if it's worth the effort — write the c11 version of it.*

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
- **Notes:** <reasoning, links to playbook entries used, dependencies surfaced>
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

## Hard rules

- Never push to `manaflow-ai/cmux`. (Already blocked at git-config level.)
- Never force-push the `upstream/pr-<N>` branches.
- Never auto-merge c11 PRs.
- Never operate on a dirty working tree without operator OK. Prefer worktrees.
- Never run more than one apply at a time.
- When unsure, ask. Cheap to pause, expensive to revert.
