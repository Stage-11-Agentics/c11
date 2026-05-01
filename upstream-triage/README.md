# Upstream Triage

Where c11 imports changes from `manaflow-ai/cmux`, one PR at a time, by hand-and-agent.

## The frame

c11 is a fork that has diverged meaningfully from upstream cmux: renamed entry points, custom theming, Lattice integration, c11-only panels, separate release flow. Most upstream changes don't drop in cleanly with `git cherry-pick`. The right tool for crossing that gap isn't a smarter merge algorithm — it's an agent that **reads the upstream change, understands what it wants to do, and writes the c11 version of it.**

The work happens through a partnership:

- **The agent** reads upstream PRs, locates the equivalent code in c11, judges whether and how the change applies, and authors the c11 import (via cherry-pick when convenient, via rewrite when not). It surfaces non-trivial decisions before acting on them.
- **The operator** (you) sets direction, reviews the agent's judgment on edge cases, and merges the resulting c11 PRs.

Cherry-pick, the probe script, the divergence map, the playbook — these are *aids to the agent's judgment*, not a pipeline the agent rides on rails.

## What lives here

| Path                          | Role                                                                         |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `RUNBOOK.md`                  | How the agent thinks about an import. Read every run.                        |
| `divergence-map.md`           | Facts about c11's hot zones — where to expect adaptation work.               |
| `playbook.md`                 | Adaptation patterns the agent has worked out and may reuse.                  |
| `scripts/probe.sh`            | Quick check: would this PR cherry-pick clean, or is rewrite called for?     |
| `scripts/list-merged.sh`      | Listing of upstream PRs since a given point.                                 |
| `scripts/analyze-hotspots.sh` | Scan c11's unique commits → hot files (seeds the divergence map).            |
| `triage-log/<date>.md`        | The agent's reasoning and decisions, per PR, per day.                        |
| `catchup/backlog.md`          | The 912-PR catch-up backlog, marked yes/no/maybe/done.                       |
| `catchup/feature-catchup-plan.md` | Strategic plan for importing the foundational upstream features first.   |

## How to invoke

From inside Claude Code in this repo:

```
/upstream-triage <pr-number> [<pr-number> ...]
/upstream-triage --since 2026-04-15
/upstream-triage --catchup            # walks the next batch from catchup/backlog.md
```

The skill loads the agent into the right frame and points it at `RUNBOOK.md` for the working philosophy.

## Two layers of accumulating knowledge

- **`divergence-map.md` = facts.** Where c11 has diverged. The agent uses it to know where to look and what to expect.
- **`playbook.md` = patterns.** Adaptation recipes the agent has worked out before. Grows when something non-obvious comes up that's likely to recur.

These get updated by the agent at the end of each run. Without them, every session relearns the same lessons.

## Scope of v1

- **Manual invocation only.** No cron yet. We build trust before automating.
- **Local execution.** Cloud agent later.
- **One c11 PR per upstream PR.** CI on the c11 PR is the build verification — the agent doesn't build locally.
- **Agent escalates before pushing on non-trivial adaptations.** A clean cherry-pick can land without a check-in; a rewrite that touches multiple files or alters intent gets surfaced first.
- **No auto-merge.** Operator merges every c11 PR.
