# RUNBOOK — `/upstream-triage`

This is the flow the skill follows for each upstream PR. **Read this every run before doing anything.**

## Inputs

The skill is invoked one of three ways:

1. `/upstream-triage <pr-number> [<pr-number> ...]` — explicit PRs.
2. `/upstream-triage --since <date-or-pr>` — list all upstream PRs merged after this point.
3. `/upstream-triage --catchup [--batch-size N]` — pull the next N "yes" or "maybe" entries from `catchup/backlog.md`.

## Setup (once per run)

1. Confirm cwd is the c11 repo root.
2. Confirm `git status` is clean. If not, **stop** and report — never operate on a dirty tree.
3. Confirm current branch is `main`. If not, ask before continuing.
4. `git fetch upstream main` and `git fetch origin main`.
5. Confirm local `main` is up to date with `origin/main`. If not, fast-forward (or stop and ask if it's diverged).
6. Open today's triage log at `upstream-triage/triage-log/<YYYY-MM-DD>.md` (create if missing). Append, don't overwrite.
7. Read `divergence-map.md` and `playbook.md` into context.

## Per-PR loop

For each PR number, run **DECIDE → PROBE → APPLY → REPORT.**

### 1. DECIDE

Fetch PR metadata via `gh pr view <N> --repo manaflow-ai/cmux --json title,body,files,additions,deletions,author,mergeCommit,mergedAt`.

Categorize. The decision is one of:

- **SKIP-divergence** — touches a file in `divergence-map.md` marked "skip". Log reason and move on.
- **SKIP-low-reward** — pure infrastructure that doesn't apply to c11 (release flow, homebrew, branding, Sentry-cmux config, CHANGELOG, README, version bumps). Log and move on.
- **SKIP-not-merged** — PR was closed without merge. Log and move on.
- **SKIP-already-applied** — `mergeCommit.oid` is already reachable from c11/main. Log and move on.
- **ATTEMPT** — looks landable. Continue to PROBE.
- **ESCALATE** — agent is uncertain. Stop the per-PR loop, surface the question to the user with the relevant context.

Bias: when in doubt, ATTEMPT. The probe is cheap; we'd rather see real conflicts than over-skip.

### 2. PROBE

Run `upstream-triage/scripts/probe.sh <pr-number>`. It will:

- Create branch `upstream-probe/pr-<N>` from `origin/main`.
- Try `git cherry-pick <merge-commit>` (using `-m 1` if it's a merge commit, else direct).
- Report one of: `clean`, `conflict <files>`, `empty` (no changes — already applied), `error <reason>`.

The probe never pushes. It leaves the branch in whatever state for inspection.

### 3. APPLY

Based on probe result:

- **clean** — the cherry-pick worked with no conflicts.
  - Push the branch: `git push -u origin upstream-probe/pr-<N>:upstream/pr-<N>`
  - Open c11 PR (see "PR shape" below).
  - Delete the local probe branch.
  - Switch back to main.

- **conflict** — read each conflicted file. Decide:
  - All conflicts in files marked "skip" in divergence map → abort, log as **SKIP-divergence-conflict**, clean up branch.
  - Conflicts in shared code, scope is tractable (a few hunks, no architectural rework) → resolve, `git cherry-pick --continue`, push, open PR with a note in the body explaining the adaptation.
  - Conflicts are heavy or beyond the agent's confident scope → abort, log as **NEEDS-HUMAN** with the conflict files and a one-paragraph diagnosis. Clean up branch.

- **empty** — already in c11. Log SKIP-already-applied. Clean up branch.

- **error** — log the error verbatim, escalate to user.

### 4. REPORT

Append to `triage-log/<YYYY-MM-DD>.md` for every PR processed. One block per PR:

```markdown
## #<N> — <title>

- **Decision:** <SKIP-... | LANDED | NEEDS-HUMAN>
- **Author:** <upstream author>
- **Files:** <count> files, +<add> -<del>
- **Probe:** <clean | conflict files | empty | error>
- **c11 PR:** <link if opened, else —>
- **Reason:** <one sentence>
- **Notes:** <optional adaptation notes, conflict description, etc.>
```

## PR shape

When opening a c11 PR for a clean or resolved import:

- **Branch name:** `upstream/pr-<N>` (so it's obvious in the branch list)
- **Title:** `[upstream #<N>] <original title>`
- **Body:**

  ```markdown
  Imports manaflow-ai/cmux#<N>: <title>

  Original author: @<upstream-login>
  Upstream PR: https://github.com/manaflow-ai/cmux/pull/<N>
  Merge commit: <upstream-sha>

  ## Original summary
  <quote relevant parts of upstream PR body, trimmed>

  ## Adaptation notes
  <if any conflicts were resolved, describe; otherwise: "Cherry-picked clean.">

  Triage log: upstream-triage/triage-log/<date>.md#<N>
  ```

- **Labels:** `upstream-import` (create if missing).
- **Do not** auto-merge. The c11 PR's CI runs; you (the human) review and merge.

## Updating the divergence map and playbook

After processing a batch, **always**:

1. If a SKIP-divergence reason came up that isn't in the divergence map yet, add it.
2. If a conflict resolution was non-obvious and might recur, add a playbook entry.
3. Commit the updates as a separate commit on main: `chore(triage): update divergence map and playbook from <date> run`.

This is how the system gets smarter. Don't skip it.

## Hard rules

- **Never push to `manaflow-ai/cmux`.** That's already blocked at the git-config level, but be aware.
- **Never force-push** the `upstream/pr-<N>` branches. Each PR gets one branch; if it needs revision, push a new commit on top.
- **Never auto-merge** c11 PRs. Always leave to the human.
- **Never operate on a dirty working tree.** Refuse and report.
- **Never run more than one cherry-pick at a time.** The probe branches must be sequential or they trample each other.
