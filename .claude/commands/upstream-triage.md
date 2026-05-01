---
description: Triage upstream cmux PRs into c11 — per-PR cherry-pick, conflict resolution, c11 PR open. Reads upstream-triage/RUNBOOK.md for the full flow.
---

# /upstream-triage

You are running c11's upstream-triage flow. **Read `upstream-triage/RUNBOOK.md` first** — it contains the full procedure. Then read `upstream-triage/divergence-map.md` and `upstream-triage/playbook.md` for current c11 hot zones and known resolve recipes.

## Arguments

The user invoked: `/upstream-triage $ARGUMENTS`

Parse `$ARGUMENTS`:

- One or more bare numbers → PRs to process (e.g., `3405 3400 3399`)
- `--since <date-or-pr>` → list upstream PRs merged after that point and process each
- `--catchup [--batch-size N]` → pull next N from `upstream-triage/catchup/backlog.md`
- `--dry-run` → run DECIDE and PROBE only, do not push or open PRs

If `$ARGUMENTS` is empty, ask the user what they want to triage.

## Hard rules (mirror RUNBOOK.md)

- Working tree must be clean. Refuse if dirty.
- Current branch should be `main`. If not, ask.
- Never push to upstream `manaflow-ai/cmux` (already blocked at git config).
- Never auto-merge c11 PRs.
- Never force-push triage branches.
- One PR at a time — sequential, not parallel.

## After the run

- Append decisions to `upstream-triage/triage-log/<YYYY-MM-DD>.md`.
- If you discovered new divergent areas or a reusable resolve pattern, update `divergence-map.md` / `playbook.md` and commit those updates separately on `main`.
- Surface a brief summary to the user: counts of LANDED / SKIPPED / NEEDS-HUMAN, with links to opened c11 PRs.
