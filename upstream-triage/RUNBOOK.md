# RUNBOOK — `/upstream-triage`

You are an agent importing an upstream cmux change into c11. **You are doing the import, not orchestrating a pipeline.** The tools (probe, divergence map, playbook) help you think and act faster — they don't decide for you.

Your job per PR: *understand what upstream wants, decide whether it belongs in c11, and write the c11 version of it.*

## Setup (once per run)

1. Confirm cwd is the c11 repo root (or a worktree of it).
2. `git fetch upstream main` and `git fetch origin main`.
3. Open today's triage log at `upstream-triage/triage-log/<YYYY-MM-DD>.md` (create if missing). Append, don't overwrite.
4. Read `divergence-map.md` and `playbook.md` into context. These are the agent's prior knowledge about c11.
5. Working tree must be clean for any apply step. If main is dirty, prefer running in a worktree (`git worktree add /tmp/c11-triage main`) or stashing the user's work *only with their explicit OK*.

## The per-PR loop: READ → LOCATE → JUDGE → APPLY → REPORT

This is a thinking shape, not a procedure. Skip steps when they're unnecessary; loop back when something surprises you.

### 1. READ

Pull the full upstream context:

```bash
gh pr view <N> --repo manaflow-ai/cmux --json title,body,files,additions,deletions,author,mergeCommit,mergedAt,comments
git fetch upstream <merge-sha>
git show <merge-sha>
```

Form a one-sentence understanding of what this PR *does* — not the diff shape, the intent. ("Adds a backdrop layer behind the sidebar tint." "Renames a constant." "Bridges OpenCode permission asks into the Feed UI.")

If the intent isn't clear from title + body + diff, read the linked issue, the PR comments, or the related code. Don't proceed on a guess.

### 2. LOCATE

Find the c11 equivalents of the files upstream touched. Common cases:

- **Same path exists in c11** → standard case. Cherry-pick may apply directly or with conflicts.
- **Path renamed** (e.g. `cmuxApp.swift` → `c11App.swift`) → see playbook entry "cmux→c11 rename". The code identity is the same; the path is not.
- **Path doesn't exist on c11** → upstream introduced it after our merge-base. The PR likely depends on an upstream feature c11 hasn't imported yet. See playbook entry "Modify/delete — file doesn't exist on c11".
- **Concept exists but in a different place** (e.g. upstream changes a setting that c11 has reorganized) → translate. Don't blindly drop changes into a structure they don't fit.

### 3. JUDGE

Now you have the upstream intent and the c11 target shape. Answer three questions:

1. **Does this change make sense for c11?** Most do. But some upstream PRs adjust features c11 has replaced, deleted, or never wanted. If c11's equivalent is intentionally different, skip — log the reason.
2. **What's the lightest path that preserves the change's intent?** Three options, in increasing cost:
   - **Cherry-pick clean** — the upstream commit applies as-is. Use this when probe reports `STATUS=clean`. No rewrite needed.
   - **Cherry-pick with manual conflict resolution** — small, mechanical conflicts (a few hunks). Resolve, continue, commit.
   - **Rewrite** — read the upstream diff as a *spec*, then write the c11 version. Apply the same semantic change to c11's current code. Translate paths, naming, and any structural differences. The result is a c11-authored commit that quotes the upstream PR for lineage.
3. **Is this within the agent's scope to do alone, or does it need a check-in?** Default to escalate when:
   - Rewrite touches >5 c11 files.
   - The change deletes or alters c11-specific behavior.
   - The upstream PR is part of a feature chain (depends on un-imported PRs) and importing the chain isn't a small lift.
   - You're not sure which c11 file is the right home for the change.

### 4. APPLY

Choose the path matching your judge step.

**Cherry-pick (clean or with conflict resolution):**

```bash
./upstream-triage/scripts/probe.sh <N>
# If STATUS=clean: branch ready, push and open PR.
# If STATUS=conflict and conflicts are small/mechanical: resolve, git cherry-pick --continue, push, open PR.
# If STATUS=conflict and conflicts are non-trivial: switch to rewrite path.
```

**Rewrite:**

1. Make sure you're on a fresh branch off main: `git checkout -b upstream/pr-<N> main`.
2. Apply the same semantic change to c11. The upstream diff is a guide; the c11 codebase is the target. Write the change as if you were authoring it natively.
3. Commit with the upstream author attribution preserved:
   ```bash
   git commit \
     --author="<upstream-login> <upstream-email>" \
     -m "[upstream #<N>] <upstream title>" \
     -m "Adapted for c11. Original: https://github.com/manaflow-ai/cmux/pull/<N>"
   ```
4. The PR body **must** clearly state this is a rewrite (see "PR shape" below).

**Either path** ends with: branch pushed, c11 PR opened, agent does *not* merge.

### 5. REPORT

Append a block to `triage-log/<YYYY-MM-DD>.md` for every PR processed:

```markdown
## #<N> — <title>

- **Decision:** <LANDED-cherry-pick | LANDED-rewrite | LANDED-rewrite-partial | NEEDS-HUMAN | SKIP-<reason>>
- **Author:** <upstream login>
- **Files (upstream):** <count>, +<add> -<del>
- **Files (c11 commit):** <count> — only when different from upstream (rewrite case)
- **c11 PR:** <link if opened, else —>
- **Approach:** <one sentence — cherry-pick? rewrite? what was adapted?>
- **Notes:** <anything that helps reconstruct the reasoning, links to playbook entries used, dependencies surfaced>
```

If a non-obvious adaptation pattern came up, also update `playbook.md`. If a previously unmapped divergent area surfaced, also update `divergence-map.md`. Commit those updates as a separate commit on main: `chore(triage): update divergence map and playbook from <date> run`.

## Working with the operator

The agent works *with* the operator, not autonomously. The default mode is "do the work, surface decisions worth surfacing." Specifically:

- **No surprises before push.** If the c11 PR will visibly differ from the upstream PR (rewrite, partial import, scope change), explain in the PR body. The operator should never be confused about why c11's version doesn't match upstream's.
- **Escalate, don't guess.** If you're under 80% confident on a judgment call (which file is the right home? does this feature belong in c11?), pause and ask the operator. The cost of pausing is a sentence; the cost of a wrong import is a revert.
- **Batch the small stuff.** Don't ask the operator to weigh in on every cherry-pick that lands clean. Do those, log them, move on. Surface only the calls that need a person.

## PR shape

**Branch name:** `upstream/pr-<N>`

**Title:** `[upstream #<N>] <original title>`

**Body template:**

```markdown
Imports manaflow-ai/cmux#<N>: <title>

Original author: @<upstream-login>
Upstream PR: https://github.com/manaflow-ai/cmux/pull/<N>
Upstream commit: <sha>

## Approach

<one of:>

- **Cherry-pick (clean).** Applied without modification.
- **Cherry-pick (resolved).** Conflicts in <files>; resolved by <one-line summary>.
- **Rewrite.** Upstream diff was applied semantically to c11's structure. Differences from upstream:
  - <bullet: e.g. "translated `cmuxApp.swift` references to `c11App.swift`">
  - <bullet: e.g. "skipped the part touching homebrew-cmux/ — no c11 equivalent">

## What this changes in c11

<one paragraph in plain language: what behavior or surface this affects on c11. Helps the reviewer judge fit without re-reading both diffs.>

Triage log: upstream-triage/triage-log/<date>.md#<N>
```

**Labels:** `upstream-import` (create the label if missing).

**Do not** auto-merge. The operator reviews and merges.

## Hard rules

- Never push to `manaflow-ai/cmux`. (Already blocked at git-config level.)
- Never force-push the `upstream/pr-<N>` branches.
- Never auto-merge c11 PRs.
- Never operate on a dirty working tree without operator OK. Prefer worktrees.
- Never run more than one apply at a time. Probe branches and rewrite branches must be sequential or they trample.
- When unsure, ask. Cheap to pause, expensive to revert.
