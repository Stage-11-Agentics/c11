# Feature Catchup Plan

Strategic plan for closing the gap between c11 and upstream cmux.

## The problem

c11's last shared commit with upstream is `53910919` from 2026-03-18. Upstream has merged ~900+ PRs since then, many building on foundational features that don't yet exist on c11.

A naive forward-triage hits a recurring failure mode: an upstream PR modifies a file c11 doesn't have because the file was introduced by an earlier upstream PR c11 hasn't imported. PR #3405 was the first concrete case (modifies `Resources/opencode-plugin.js`, introduced upstream in PR #3057).

## The approach

Rather than process every upstream PR forward in time, identify the **foundational feature PRs** c11 wants, import each one as a focused multi-PR session ("feature catch-up"), then resume forward-triage from a much closer base.

Each feature catch-up is its own small project:
1. The agent reads the foundational PR + its in-tree follow-ons end-to-end.
2. The agent + operator decide together how the feature should land in c11 (sometimes 1:1, sometimes adapted to fit c11's panel system, sometimes split into stages).
3. The result is one or a small number of c11 PRs that bring the feature in coherently — not a 1:1 replay of every upstream commit along the way.

This is a different shape from daily triage. Daily triage is "small change → small PR." Feature catch-up is "feature → feature."

## Candidate foundations (initial seed list)

Sampled from upstream merged PRs since 2026-03-18, filtered to feature-introducing titles. **This is a starting point, not a final list — every entry needs an operator yes/no/defer call.**

### Agent & Feed system

- [ ] **#3057 — Add Feed sidebar + cmux feed-hook + OpenCode plugin (workstream MVP)** (2026-04-26)
  - The dependency that blocked PR #3405. Foundational for any Feed-related upstream import.
  - c11 status: not present. Operator decision: import / skip / defer.
- [ ] **#3252 — Add iMessage mode for agent prompts** (2026-04-30) — likely depends on Feed
- [ ] **#3405 — Bridge OpenCode plan approvals into Feed** (2026-05-01) — blocked on #3057
- [ ] Any Feed follow-ons between 3057 and 3405

### Settings rework

- [ ] **#3024 — Add unified config settings utility window** (2026-04-20)
- [ ] **#3244 — Add settings sidebar shell** (2026-04-29)
- [ ] **#2514 — Add Claude Binary Path setting** (2026-04-01)
- [ ] **#3400 — Consolidate sidebar settings** (2026-05-01) — likely depends on #3244
- [ ] Operator decision: c11 may already have a divergent settings approach. Adapt or skip the whole stack.

### Dock TUI

- [ ] **#3217 — Add Dock sidebar TUI controls** (2026-04-29)
- [ ] **#3366 — Require explicit Dock config** (2026-04-30)
- [ ] **#3376 — Add Dock documentation page** (2026-05-01)
- [ ] **#3393 — Improve Dock agent prompt docs** (2026-05-01)

### Sessions panel

- [ ] **#2936 — Add Sessions panel to right sidebar** (2026-04-17)
- [ ] **#3396 — Search Codex rollout content from sessions sidebar** (2026-05-01)

### File explorer sidebar

- [ ] **#1963 — Add Finder-like file explorer sidebar with SSH support** (2026-04-13)
- [ ] **#3139 — Add sidebar file preview panels** (2026-04-30)

### Task Manager / Snapshots

- [ ] **#3290 — Add top snapshots and Task Manager window** (2026-04-30)

### Menu bar only mode

- [ ] **#3181 — Add menu bar only mode** (2026-04-27)

### Workspace / CLI features

- [ ] **#2475 — Add editable workspace descriptions** (2026-04-03)
- [ ] **#2916 — Add `--layout` to workspace.create for programmatic split layouts** (2026-04-16)
- [ ] **#3084 — Add configurable cmux.json workspace and tab bar actions** (2026-04-23)
- [ ] **#2389 — Add a system-wide hotkey to show and hide cmux windows** (2026-04-07)

### Agent integrations

- [ ] **#2103 — Add Codex CLI hooks integration** (2026-03-25)
- [ ] **#2087 — Add `cmux omo` command for oh-my-openagent integration** (2026-03-26)
- [ ] **#2619 — Add cmux omx and cmux omc agent integrations** (2026-04-06)
- [ ] **#2717 — Add Cursor and Gemini CLI agent integrations + setup-hooks** (2026-04-09)

### Browser pane

- [ ] **#2660 — Add passkey, WebAuthn, and FIDO2 support to browser pane** (2026-04-07)
- [ ] **#3256 — Add cmux browser disable switch** (2026-04-29)
- [ ] **#2373 — Add React Grab inject button to browser toolbar** (2026-03-31)

### Misc

- [ ] **#2293 — Add Match Terminal Background sidebar setting** (2026-03-28)
- [ ] **#2282 — Add copy-on-select setting** (2026-03-30)
- [ ] **#2127 — Cmd+N workspace creation crash regression coverage** (2026-03-25)

## How to use this list

1. **Curate.** Operator walks the list and marks each `[y]` (import), `[n]` (skip), or `[?]` (defer / needs more thought). Comment with reasoning if useful.
2. **Sequence.** Once curated, the `[y]` items get an order. Default to date order; override when a later PR is a better fit for c11 (e.g. c11 may want #3400 "Consolidate sidebar settings" without first importing the original sidebar split).
3. **Drive each catch-up.** For each foundation marked `[y]`:
   - Open a focused `/upstream-triage` session named after the feature.
   - Read the foundation PR + every follow-on that builds on it (use `git log --all -- <key-path>` to find them).
   - Decide with the operator: import as one c11 PR, or split into stages?
   - Author the c11 import. The agent does the writing; the operator nods on scope and approach.
4. **Resume forward triage** from the new base once the major catch-ups are landed.

## Selection criteria — when to mark `[y]`

A foundation is worth importing if:

- It's a feature c11 wants (not a cmux-specific direction c11 has chosen to deviate from).
- Multiple later upstream PRs build on it (importing it unblocks a chain).
- The cost to import is bounded — a multi-thousand-line refactor that conflicts with c11's panel system may not be worth it even if c11 wants the feature.

Mark `[n]` when c11 already has its own equivalent (e.g., c11's panel system likely subsumes some upstream "sidebar X" features), or when the feature's a direction c11 isn't taking.

Mark `[?]` when you don't have enough context to decide yet.

## Status

- 2026-05-01: initial list seeded by sampling upstream merged PRs since merge-base. **Uncurated.** First operator pass needed before any catch-up sessions run.
