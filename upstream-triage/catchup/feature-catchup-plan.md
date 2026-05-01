# Feature Catchup Plan

Strategic plan for closing the gap between c11 and upstream cmux.

## The problem

c11's last shared commit with upstream is `53910919` from 2026-03-18. Upstream has merged ~900+ PRs since then, and there are ~30+ open PRs at any given time. Most recent upstream PRs depend on foundational features that don't yet exist on c11.

A naive forward-triage hits a recurring failure mode: an upstream PR modifies a file c11 doesn't have, because the file was introduced by an earlier upstream PR c11 hasn't imported. PR #3405 was the first concrete case (modified `Resources/opencode-plugin.js`, introduced upstream in PR #3057).

## The approach: forward sweep first, foundations emerge from the work

Don't pre-curate a foundations list. Instead:

1. **Run forward-triage sweeps** on recent upstream PRs (e.g. `--since 2026-04-15 --state all`).
2. The agent runs each PR through EVALUATE → READ → LOCATE → JUDGE.
3. **Easy + yes PRs land** as quick wins (Atin's preferred work shape).
4. **Hard + yes PRs surface their dependencies** — when a probe hits the modify/delete pattern, the missing-on-c11 file points at the foundation upstream introduced.
5. **The foundations list builds itself** from these surfaced dependencies. We only chase a foundation when at least one downstream PR we want is blocked on it.

This is the difference between "guess which upstream features matter" and "let the actual work tell us." We end up importing only the foundations that block desirable downstream work, and the order is naturally driven by what we want to land.

## Naming

A unit of work is a **PR import** (or **upstream PR import** in c11 docs). We import individual PRs — open or closed, merged or unmerged — through the same skill (`/upstream-triage`).

A **foundation** is a PR import that unblocks one or more downstream PRs. The label emerges from triage; it's not a property the PR has on its own.

## Triage axes

Every PR gets two assessments:

- **EVALUATE** — does c11 want this functionality? `yes / no / maybe`
- **DIFFICULTY** — how hard to bring over? `easy / moderate / hard`

| | Easy | Moderate | Hard |
|---|---|---|---|
| **Want it** | ship it (often no scope check) | scope agreement, then ship | focused session, scope agreement |
| **Maybe** | just do it (low cost to revert) | surface to operator | defer until clear yes |
| **Skip** | skip | skip | skip |

The bias is toward **easy + yes** — those are the quick wins that build momentum. Hard work is deferred to dedicated sessions with their own scope agreements.

## Suspected foundations (informational; verify by triage)

These were sampled from upstream merged PRs since 2026-03-18. Listed here as **starting hypotheses** for what the foundations *might* be — but the actual foundation list is built by forward-sweep evidence, not this list.

If a forward-triage run hits a modify/delete blocked by one of these, we promote it to "foundation we want to chase." If no downstream PRs we care about depend on it, we never need to import it.

### Possible foundations

- **#3057** — Add Feed sidebar + cmux feed-hook + OpenCode plugin (2026-04-26). Already confirmed as the dependency for #3405.
- **#3024** — Add unified config settings utility window (2026-04-20).
- **#3244** — Add settings sidebar shell (2026-04-29).
- **#3217** — Add Dock sidebar TUI controls (2026-04-29).
- **#2936** — Add Sessions panel to right sidebar (2026-04-17).
- **#1963** — Add Finder-like file explorer sidebar with SSH support (2026-04-13).
- **#3290** — Add top snapshots and Task Manager window (2026-04-30).
- **#3181** — Add menu bar only mode (2026-04-27).

### Possible quick-win imports (probably easy + yes)

These looked self-contained when sampled — small enough that they may land clean even at the current divergence level. Good candidates for the first forward-sweep run.

- **#2293** — Add Match Terminal Background sidebar setting.
- **#2282** — Add copy-on-select setting.
- **#2389** — Add a system-wide hotkey to show and hide cmux windows.
- **#2475** — Add editable workspace descriptions.
- **#3329** — Add hover tooltips to workspace and pane tabs.
- **#3334** — Allow keyboard shortcuts to be unbound.

### Skip candidates (probably evaluate=no)

These look cmux-specific or don't fit c11's direction. The agent should still call EVALUATE on each, but these are likely skips.

- README / docs / blog post additions.
- Korean localization (#1811).
- AGPL + commercial dual-licensing changes (#2021) — c11 is its own license decision.
- cmux-specific marketing or product PRs.

## How to drive

The first forward-sweep run is the action item. From a clean c11 worktree:

```
/upstream-triage --since 2026-04-15 --state all --dry-run
```

Dry-run produces a triage table without applying anything. Operator scans the table, redirects the agent on any obvious miscalls, then runs again without `--dry-run` to land the easy+yes work. Hard cases stay in the triage log for focused sessions.

After the first sweep we'll know:
- What fraction of recent upstream is actually easy at the current divergence.
- Which foundations are surfacing as real blockers (not just hypotheses).
- Where the divergence map and playbook need new entries.

## Status

- 2026-05-01: catchup plan reframed around forward-sweep discovery. Initial hypotheses listed for context, not as a curated queue. **First forward-sweep run not yet executed.**
