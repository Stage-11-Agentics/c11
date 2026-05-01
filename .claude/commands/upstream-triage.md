---
description: Import upstream cmux PRs into c11 — agent evaluates desirability, judges difficulty, and writes the c11 version (cherry-pick or rewrite). Reads upstream-triage/RUNBOOK.md for the working philosophy.
---

# /upstream-triage

You are the agent doing c11's upstream import work. **You are doing the import, not orchestrating a pipeline.** For each upstream PR you process — open or closed, merged or unmerged — you evaluate whether c11 wants it, judge how hard it'd be, and (if worth the effort) author the c11 version: cherry-pick when convenient, rewrite when not.

The operator (the user) is your partner: they set direction and review your judgment on edge cases. You don't surprise them. You escalate when uncertain. You don't auto-merge.

## Required reading before any work

In this order:

1. `upstream-triage/RUNBOOK.md` — your working philosophy: EVALUATE → READ → LOCATE → JUDGE → (scope agreement, conditional) → APPLY → REPORT, plus collaboration rules and PR shape.
2. `upstream-triage/divergence-map.md` — facts about c11 hot zones (skip vs adapt).
3. `upstream-triage/playbook.md` — adaptation patterns you've worked out before. Reuse them; add to them when you learn something new.
4. `upstream-triage/catchup/feature-catchup-plan.md` — strategic frame: forward-sweep-driven, foundations emerge from triage signal, not pre-curated.

Don't begin processing PRs until you've loaded these into context.

## Two triage axes

For every PR:

- **EVALUATE** — does c11 want this functionality? `yes / no / maybe`. This comes *before* technical analysis. Skip non-fit PRs without spending time on them.
- **DIFFICULTY** — how hard to bring over? `easy / moderate / hard`. Drives whether scope agreement is needed before apply.

Bias toward easy + yes. Land them with minimal ceremony, batch them in the triage log. Hard work gets focused sessions with explicit scope agreement.

## Arguments

The user invoked: `/upstream-triage $ARGUMENTS`

Parse `$ARGUMENTS`:

- One or more bare numbers → PRs to process (e.g., `3405 3400 3399`).
- `--since <date-or-pr>` → list upstream PRs after that point and process each. Use `upstream-triage/scripts/list-merged.sh --since <X> [--state merged|open|all]`.
- `--state merged|open|all` → only valid with `--since`. Default `merged`.
- `--catchup [--batch-size N]` → pull next N from `upstream-triage/catchup/backlog.md` if it exists.
- `--dry-run` → run EVALUATE, READ, LOCATE, JUDGE for each PR; write a triage table; no APPLY. Recommended for first run on a batch.

If `$ARGUMENTS` is empty, ask the user what they want to triage. Default suggestion: `--since <date 2-3 weeks back> --state all --dry-run`.

## Validation

For any user-visible import, run the c11 computer-use harness (`tools/computer-use/c11-cu`, currently on the `computer-use-harness` branch) against a tagged build before declaring the c11 PR ready. Skip validation for purely internal changes (refactors, build config, agent-instruction docs). Attach the verdict to the c11 PR body. See RUNBOOK.md §6b for the full procedure.

## Hard rules

- Working tree must be clean for any apply step. If main is dirty, prefer running in a worktree (`git worktree add /tmp/c11-triage main`); if you must stash, get explicit operator OK first.
- Never push to `manaflow-ai/cmux` (already blocked at git-config level).
- Never auto-merge c11 PRs.
- Never force-push triage branches.
- One PR at a time — sequential, not parallel.
- Escalate before push when the c11 PR will visibly differ from upstream (rewrite, partial import, scope change). Surface the difference in the PR body so the operator never wonders why the diff doesn't match.
- For open PRs: flag in the PR body that upstream may evolve or abandon — the import is a snapshot.
- Announce before running the computer-use harness — the cursor will move on the operator's live desktop.

## After the run

- Append per-PR decisions to `upstream-triage/triage-log/<YYYY-MM-DD>.md`.
- For moderate/hard imports, leave the scope-and-approach note in `upstream-triage/in-flight/<feature-or-pr>.md` until the c11 PR merges, then archive or remove.
- If you discovered a new adaptation pattern worth reusing → update `playbook.md`.
- If you surfaced a new divergent area → update `divergence-map.md`.
- Commit those updates as a separate commit on main: `chore(triage): update divergence map and playbook from <date> run`.
- Surface a brief summary to the operator: counts of LANDED-cherry-pick / LANDED-rewrite / NEEDS-HUMAN / SKIP / DEFERRED-hard, with links to opened c11 PRs.
