---
name: c11-full-review
version: 1
description: Audit every workspace in the current c11 window and prioritize what the operator should attend to next. Reads each pane's actual terminal scrollback — not just sidebar metadata — to distinguish what is blocked on the operator from what is progressing on its own. Use when the operator says "where are we", "what should I do next", "triage", "give me a status", or any variation that asks for cross-pane synthesis. For a single workspace, use c11-workspace-review instead.
---

# c11 Full Review

A single-pass audit of every workspace, every pane, every agent — boiled down to one clear next action.

The operator is running many agents in parallel. The sidebar shows tabs and statuses, but **sidebar metadata drifts** — `status=pr-open` lingers minutes after the PR merged; "throttled" can mean "finished and idle." The fastest reliable source of truth is the **actual terminal scrollback** of each pane. That is the bet: read what the agents themselves say, not what the binary inferred.

## When to invoke

Operator phrases that match: "where are we", "what should I do next", "what should I attend to", "give me a status", "triage this", "what's blocked".

Not for: implementing tickets, reviewing code, planning new work. This is the *orient* step only.

## Procedure

### 1. Get the spatial layout

```bash
c11 tree --json
```

Build the mental map: which workspaces exist, which panes inside each, what each tab is titled.

### 2. Read every non-trivial pane in parallel

For each terminal surface where an agent is or was running:

```bash
c11 read-screen --workspace <ws> --surface <surf> --scrollback --lines 200
```

**Issue all reads in one tool batch.** Reading panes sequentially is the single biggest waste of time in this procedure — they are independent.

For each transcript, extract:
- **What is the agent actually doing now?** (Last 1–3 interactions trump the tab title.)
- **Has it finished?** Look for "merged", PR links, "ready for review", final summary, idle prompt.
- **Is it waiting on the operator?** Look for "want me to…", clarifying questions, "let me know how to proceed".
- **Is it stuck?** Errors, retries, tool failures, ambiguous state.
- **Cross-references** to other panes, tickets, PRs, agents — so threads can be connected.

**The sidebar lies. The terminal usually doesn't.** If sidebar status says "throttled" but the transcript shows "✓ merged PR #29 12 minutes ago", trust the transcript.

### 3. Use external tools only when the terminal is ambiguous

The transcript is usually enough. Reach for `gh pr list`, the forgejo MCP, `lattice ticket show`, etc. **only** when:

- A transcript says "PR opened" without confirming merge state, AND that matters for ranking.
- Two panes contradict each other and you need a tiebreaker.
- An external-state claim ("CI red", "deployed", "all green") needs a real check before the operator acts on it.

Don't pre-emptively verify everything. The whole point of reading transcripts is to skip the tool round-trip.

### 4. Synthesize

For each pane, place it in one of these buckets:

- **Blocked on operator** — needs a decision, answer, or "go" before anything else moves. **Highest-leverage bucket.**
- **In flight (verified)** — actively progressing, no operator input needed. State the most recent concrete signal so the operator knows it is *actually* moving (not just titled as if it is).
- **Releasable** — finished work, idle agents whose task completed, surfaces with placeholder titles and no real work. Worth closing.
- **Defer** — exists but isn't load-bearing for the next operator action.

Then pick **one** thing as the top call — the single action that, if the operator did nothing else, would unblock the most downstream work.

### 5. Report

Free-form prose. Use plain English.

Required sections, in this order:

- **Top call** — one sentence. If the operator only reads one line, this is it.
- **Blocked on you** — bullet list. Each item: which agent (de-jargoned name + surface ref), what decision it needs, why it matters. Say "nothing" if empty.
- **In flight** — bullet list. Each item: agent, what it is actually doing (from transcript, not title), most recent concrete signal.
- **Releasable** — what can be closed/released. Say "nothing" if empty.

Whatever else matters (a cross-workspace dependency, an external risk, a follow-up question for the operator) goes in free-form paragraphs around these sections.

**De-jargon every agent name on first use.** "GR Architect" becomes "GR Architect (Gate-Rerun architect in workspace 2, holodeck repo)". The operator may have spawned that agent days ago and forgotten the acronym.

## Worked example

**After running `c11 tree --json` and reading 4 panes in parallel, the transcripts say:**

- Pane A (workspace 1, c11 repo): C11 Orchestrator, ticket C11-116 loaded, last line is *"awaiting your direction — dispatch delegator or stand down?"*
- Pane B (workspace 2, holodeck): GR Architect, last line *"Phase 2 handoff complete. Idle."*
- Pane C (workspace 2, holodeck): GR Orchestrator, transcript shows *"PRs #29, #30, #31, #32, #33 all merged ✓"* 12 minutes ago, then idle.
- Pane D (workspace 3): Skill onboarding agent, placeholder title, no transcript activity.

**Good output:**

> **Top call:** Tell GR Architect (workspace 2) what to do next — the 5 gate-rerun PRs merged 12 minutes ago and the natural follow-on (HOLO-38 re-run) is sitting unstarted.
>
> **Blocked on you**
> - **C11 Orchestrator** (workspace 1, c11 repo, surface:7) — has C11-116 loaded, asking whether to dispatch a delegator or stand down. Caveat: surface:4 is already orchestrating C11-111 in the same repo, so dispatching means two concurrent orchestrators on c11.
> - **GR Architect** (Gate-Rerun architect, workspace 2, holodeck, surface:10) — Phase 2 handoff complete, idle. The 5 PRs it planned merged cleanly. Needs either "prep HOLO-38 re-run" or "stand down".
>
> **In flight**
> - Nothing actively progressing. The gate-rerun campaign already landed.
>
> **Releasable**
> - **Skill onboarding agent** (workspace 3, surface:8) — placeholder title, no work declared. Close.
> - **5 holodeck delegator panes** (workspace 2, surface:15–19) — sidebar still says `status=pr-open`, but PRs #29–#33 all merged. Stale metadata; safe to close.

Notice what made that output good: the top call is one sentence; every agent is de-jargoned; "in flight" is honest when nothing is actually progressing; the "releasable" section names *why* each thing is stale (so the operator can override).

## Anti-patterns

- **Five generic "Check X / Monitor Y / Review Z" items.** Those are status-dashboard verbs, not action verbs. The operator already has a sidebar for "check the dashboard." This skill exists to pre-digest that into decisions.
- **Trusting sidebar `status` / `task` / `progress` over transcript content.** The sidebar is a lossy projection. The transcript is what the agent itself said.
- **Recommending "investigate why X is throttled" without first reading the transcript** to see if "throttled" actually means "finished and idle."
- **Padding with caveats and hedges.** If you don't know, say "I don't know" in one line and move on.

## Related

- `c11-workspace-review` — the same procedure scoped to the operator's current workspace only.
