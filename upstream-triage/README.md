# Upstream Triage

This folder is the home of c11's upstream-import workflow. Upstream is `manaflow-ai/cmux`. We are a fork: we want to pull in many of upstream's changes, but not all, and most need at least light rework before they fit.

## What lives here

| Path                    | Role                                                                         |
| ----------------------- | ---------------------------------------------------------------------------- |
| `RUNBOOK.md`            | The flow the `/upstream-triage` skill follows. The agent reads this each run. |
| `divergence-map.md`     | c11 hot zones — areas where upstream changes need care or should be skipped. |
| `playbook.md`           | Patterns the agent has learned over time for resolving common conflicts.     |
| `scripts/probe.sh`      | Mechanical: try cherry-pick of an upstream PR, report status.                |
| `scripts/list-merged.sh`| List upstream PRs merged since a given date or PR number.                    |
| `scripts/analyze-hotspots.sh` | Scan c11's unique commits for hot files; output seeds the divergence map. |
| `triage-log/<date>.md`  | Per-day decision log (one file per agent run-day).                           |
| `catchup/backlog.md`    | The 912-commit backlog from the last common ancestor (2026-03-18). Marked yes/no/maybe/done. |

## How to run

From inside Claude Code in this repo:

```
/upstream-triage <pr-number> [<pr-number> ...]
/upstream-triage --since 2026-04-15
/upstream-triage --catchup    # walks the next batch from catchup/backlog.md
```

The skill drives the flow described in `RUNBOOK.md`.

## Two layers of accumulating knowledge

- **`divergence-map.md` = facts.** Where c11 has diverged from upstream. The agent uses it as a "skip or handle with care" map. Grows as we discover new divergent areas.
- **`playbook.md` = patterns.** Resolve recipes for recurring conflict shapes. The agent adds entries when it learns something reusable.

Without these, every run rediscovers the same lessons. With them, the process gets sharper.

## Scope of v1

- Manual invocation only (no cron yet). Build trust before automating.
- Local execution. Move to a cloud agent later.
- One c11 PR per upstream PR. CI on the c11 PR is the build verification — the agent does not build locally.
- Skip filter is judgment-based, not just path-based — the agent reads the divergence map and decides.
