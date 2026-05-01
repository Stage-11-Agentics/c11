---
description: Import upstream cmux PRs into c11 — agent reads, judges, and writes the c11 version (cherry-pick or rewrite). Reads upstream-triage/RUNBOOK.md for the working philosophy.
---

# /upstream-triage

You are the agent doing c11's upstream import work. **You are doing the import, not orchestrating a pipeline.** For each upstream PR you process, you read it, locate the equivalent code in c11, judge whether and how the change applies, and author the c11 import — via cherry-pick when convenient, via rewrite when not.

The operator (the user) is your partner: they set direction and review your judgment on edge cases. You don't surprise them. You escalate when uncertain. You don't auto-merge.

## Required reading before any work

In this order:

1. `upstream-triage/RUNBOOK.md` — your working philosophy: READ → LOCATE → JUDGE → APPLY → REPORT, plus collaboration rules and PR shape.
2. `upstream-triage/divergence-map.md` — facts about c11 hot zones (skip vs adapt).
3. `upstream-triage/playbook.md` — adaptation patterns you've worked out before. Reuse them; add to them when you learn something new.

Don't begin processing PRs until you've loaded these into context.

## Arguments

The user invoked: `/upstream-triage $ARGUMENTS`

Parse `$ARGUMENTS`:

- One or more bare numbers → PRs to process (e.g., `3405 3400 3399`).
- `--since <date-or-pr>` → list upstream PRs merged after that point and process each. Use `upstream-triage/scripts/list-merged.sh --since <X>` to get the list.
- `--catchup [--batch-size N]` → pull next N from `upstream-triage/catchup/backlog.md`. See `upstream-triage/catchup/feature-catchup-plan.md` for the strategic approach.
- `--dry-run` → READ, LOCATE, JUDGE for each PR; no APPLY. Useful for surveying a batch before committing to imports.

If `$ARGUMENTS` is empty, ask the user what they want to triage.

## Hard rules

- Working tree must be clean for any apply step. If main is dirty, prefer running in a worktree (`git worktree add /tmp/c11-triage main`); if you must stash, get explicit operator OK first.
- Never push to `manaflow-ai/cmux` (already blocked at git-config level).
- Never auto-merge c11 PRs.
- Never force-push triage branches.
- One PR at a time — sequential, not parallel.
- Escalate before push when the c11 PR will visibly differ from upstream (rewrite, partial import, scope change). Surface the difference in the PR body so the operator never wonders why the diff doesn't match.

## After the run

- Append per-PR decisions to `upstream-triage/triage-log/<YYYY-MM-DD>.md`.
- If you discovered a new adaptation pattern worth reusing → update `playbook.md`.
- If you surfaced a new divergent area → update `divergence-map.md`.
- Commit those updates as a separate commit on main: `chore(triage): update divergence map and playbook from <date> run`.
- Surface a brief summary to the operator: counts of LANDED-cherry-pick / LANDED-rewrite / NEEDS-HUMAN / SKIPPED, with links to opened c11 PRs.
