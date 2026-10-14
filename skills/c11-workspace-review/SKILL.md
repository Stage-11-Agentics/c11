---
name: c11-workspace-review
version: 1
description: Audit every pane in the caller's current c11 workspace and prioritize what the operator should attend to next. Reads each pane's actual terminal scrollback — not just sidebar metadata — to distinguish what is blocked on the operator from what is progressing on its own. Use when the operator wants a focused triage of one project rather than the whole window. For a full-window audit, use c11-full-review.
---

# c11 Workspace Review

A focused audit of one workspace — every pane, every agent inside it — boiled down to one clear next action for the operator.

This is `c11-full-review` scoped down. The principles are identical: **trust the terminal scrollback over sidebar metadata**, distinguish *blocked on the operator* from *progressing on its own*, pick one top call. The only difference is that the survey is narrowed to the workspace the operator is currently in.

## When to invoke

Operator phrases that match: "what's going on in this workspace", "what should I do next *here*", "triage this project", "where are we in [project]".

Not for: implementing tickets, reviewing code, planning new work.

## Procedure

### 1. Identify the workspace and its panes

```bash
c11 identify --json    # caller's workspace_ref
c11 tree --json        # scoped to current workspace by default
```

Build the map: which panes, which surfaces (terminals, browsers, markdown), what each tab is titled.

### 2. Read every non-trivial terminal pane in parallel

```bash
c11 read-screen --workspace <ws> --surface <surf> --scrollback --lines 200
```

**Issue all reads in one tool batch.** They are independent.

For each transcript, extract:
- **What is the agent actually doing now?** (Last 1–3 interactions trump the tab title.)
- **Has it finished?** "Merged", PR links, final summary, idle prompt.
- **Is it waiting on the operator?** Clarifying questions, "want me to…", "let me know how to proceed".
- **Is it stuck?** Errors, retries, ambiguous state.
- **Cross-references** within the workspace — pane A's plan may depend on pane B's output.

**The sidebar lies. The terminal usually doesn't.** If sidebar says "running" but the transcript shows the agent posted its summary and went idle, trust the transcript.

### 3. Use external tools only when the terminal is ambiguous

The transcript is usually enough. Reach for `gh pr list`, the forgejo MCP, `lattice ticket show`, etc. **only** when:

- A transcript says "PR opened" without confirming merge state, AND that matters for ranking.
- Two panes contradict each other.
- An external claim ("CI red", "deployed", "all green") needs a real check before the operator acts on it.

### 4. Synthesize

For each pane, place it in one of:

- **Blocked on operator** — needs a decision, answer, or "go". **Highest-leverage bucket.**
- **In flight (verified)** — actively progressing, no operator input needed. Name the most recent concrete signal.
- **Releasable** — finished, idle, or placeholder. Worth closing.
- **Defer** — exists but isn't load-bearing right now.

Then pick **one** top call — the single action that, if the operator did nothing else, would unblock the most downstream work in this workspace.

### 5. Report

Free-form prose. Plain English.

Required sections, in this order:

- **Top call** — one sentence. The single most important next action in this workspace.
- **Blocked on you** — bullets, each: which agent (de-jargoned + surface ref), what decision it needs, why it matters. Say "nothing" if empty.
- **In flight** — bullets, each: agent, what it is actually doing (from transcript), most recent concrete signal.
- **Releasable** — what can be closed/released. Say "nothing" if empty.

If something in this workspace is **blocked on another workspace** (e.g., a delegator here waiting on a decision the operator owes an agent in workspace 2), surface it explicitly — that's the most common cross-workspace dependency.

**De-jargon every agent name on first use.** "GR Architect" → "GR Architect (Gate-Rerun architect, surface:10)".

## Worked example

**Operator is in workspace 2 (holodeck). After `c11 tree --json` and reading 4 panes in parallel:**

- Pane A: GR Orchestrator, last line *"PRs #29, #30, #31, #32, #33 all merged ✓"* 12 minutes ago, then idle.
- Pane B: GR Architect, last line *"Phase 2 handoff complete. Idle."*
- Pane C: HOLO-59 delegator, last line *"PR #31 merged. Standing by."*
- Pane D: HOLO-38 architect, no recent activity, last interaction 2 hours ago — *"awaiting decision on rerun scope"*.

**Good output:**

> **Top call:** Decide HOLO-38 rerun scope — the HOLO-38 architect (surface:14) has been stuck on that for two hours, and the gate-rerun PRs it depends on already merged, so this is the only thing holding the next phase.
>
> **Blocked on you**
> - **HOLO-38 architect** (surface:14) — asked "rerun scope?" 2 hours ago, no response. Now actionable because dependency PRs landed.
> - **GR Architect** (Gate-Rerun architect, surface:10) — Phase 2 done, idle. Needs "prep HOLO-38" or "stand down".
>
> **In flight**
> - Nothing actively progressing. The gate-rerun campaign landed; everyone is either idle-waiting or blocked on you.
>
> **Releasable**
> - **HOLO-59 delegator** (surface:13) and the other 4 delegator panes (surface:15–19) — PRs merged, agents standing by. Safe to close.

Notice what made it good: the top call names the bottleneck precisely (2 hours stuck, dependency just unblocked); the in-flight section is honest about "nothing"; the releasable items name *why* they are stale.

## Anti-patterns

- **Five generic "Check / Monitor / Review" items.** Pre-digest into decisions, not chores.
- **Trusting sidebar metadata over transcript content.**
- **"Investigate why X is throttled"** without first reading the transcript to see if "throttled" actually means "finished and idle".

## Related

- `c11-full-review` — same procedure across every workspace in the current window.
