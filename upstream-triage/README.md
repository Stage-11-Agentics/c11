# Upstream Triage

Where c11 imports PRs from `manaflow-ai/cmux`, one at a time, by hand-and-agent. Open or closed, merged or unmerged.

## The frame

c11 is a fork that has diverged meaningfully from upstream cmux: renamed entry points, custom theming, Lattice integration, c11-only panels, separate release flow. Most upstream changes don't drop in cleanly with `git cherry-pick`. The right tool for crossing that gap isn't a smarter merge algorithm — it's an agent that **decides whether c11 wants this, judges how hard the import would be, and — if it's worth the effort — writes the c11 version of it.**

The work happens through a partnership:

- **The agent** evaluates desirability, reads the upstream PR, locates the equivalent code in c11, judges difficulty and approach, and authors the c11 import (via cherry-pick when convenient, via rewrite when not). It surfaces non-trivial decisions before acting on them.
- **The operator** (you) sets direction, reviews the agent's judgment on edge cases, and merges the resulting c11 PRs.

Cherry-pick, the probe script, the divergence map, the playbook — these are *aids to the agent's judgment*, not a pipeline the agent rides on rails.

## Two triage axes

Every upstream PR gets assessed on two independent dimensions:

- **EVALUATE** — does c11 want this functionality? `yes / no / maybe`
- **DIFFICULTY** — how hard to bring over? `easy / moderate / hard`

The agent's bias is toward **easy + yes** — those land with minimal ceremony. **Moderate and hard** work goes through a scope-agreement step before any apply. Skips are logged with a one-sentence reason.

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
| `catchup/feature-catchup-plan.md` | Strategy for closing the 912-commit gap — forward-sweep first, foundations emerge from real triage signal. |
| `in-flight/<feature>.md`      | Scope-and-approach notes for moderate/hard imports, written before apply.    |

## How to invoke

From inside Claude Code in this repo:

```
/upstream-triage <pr-number> [<pr-number> ...]
/upstream-triage --since 2026-04-15 [--state merged|open|all]
/upstream-triage --since 2026-04-15 --dry-run    # evaluate without applying
/upstream-triage --catchup                        # walks next batch from catchup backlog
```

The skill loads the agent into the right frame and points it at `RUNBOOK.md` for the working philosophy. The recommended entry point is a `--dry-run --since <recent-date> --state all` sweep — it produces a triage table without applying anything, so the operator can scan and redirect before any code lands.

## Two layers of accumulating knowledge

- **`divergence-map.md` = facts.** Where c11 has diverged. The agent uses it to know where to look and what to expect.
- **`playbook.md` = patterns.** Adaptation recipes the agent has worked out before. Grows when something non-obvious comes up that's likely to recur.

These get updated by the agent at the end of each run. Without them, every session relearns the same lessons.

## Scope of v1

- **Live engagement.** The operator drives the sweep with the agent; the agent surfaces decisions in real time. Easy + yes / easy + no fly through; moderate / hard pause for nod.
- **Local execution.** No cron yet. Cloud agent later.
- **One c11 PR per upstream PR.** CI on the c11 PR catches build/test breakage.
- **Computer-use validation for user-visible imports.** The c11 computer-use harness (`tools/computer-use/c11-cu`) drives a tagged build to confirm the imported feature works and looks right. Internal-only changes (refactors, build config) skip this step — CI is enough.
- **Agent escalates before pushing on non-trivial adaptations.** Clean cherry-pick lands without check-in; rewrite or scope-cut surfaces first.
- **No auto-merge.** Operator merges every c11 PR.
