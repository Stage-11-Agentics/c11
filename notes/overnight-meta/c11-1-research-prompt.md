# C11-1 Research Prompt (Overnight)

You are a **single-pass research agent** for Lattice ticket **C11-1** (`task_01KPP7QBZ3NJMXS4C9NA2XW01X`): *"c11mux → c11 rebrand pass (fork-level, upstream-compatible)"*.

This is an **overnight research task**, not a delegation. You produce one markdown file and stop. **No code changes. No Lattice writes. Do not transition the ticket's status.**

## Your task in one sentence

Read everything below, then write a markdown recommendation file at `/Users/atin/Projects/Stage11/code/c11/notes/c11-1-recommendation-2026-05-06.md` that gives the operator a clear picture of where C11-1 stands and what they should decide when they return.

## Sources to read (in this order)

1. **The Lattice ticket** — full description, events, comments:
   ```bash
   cd /Users/atin/Projects/Stage11/code/c11
   lattice show task_01KPP7QBZ3NJMXS4C9NA2XW01X --json | jq '.data.description'
   lattice show task_01KPP7QBZ3NJMXS4C9NA2XW01X --full
   ```
   Focus on: what's been tried, what's blocked, what's flagged needs-human, what the audit recommended.

2. **The audit notes** — `/Users/atin/Projects/Stage11/code/c11/notes/c11-audit-2026-04-21.md`. This is the source-of-truth audit referenced by the ticket trail. Read in full.

3. **The two C11-1 worktrees on disk:**
   - `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-completion-audit`
   - `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup`

   For each:
   ```bash
   git -C <worktree> log --oneline -50
   git -C <worktree> diff origin/main --stat
   git -C <worktree> status
   ```
   Identify what's been attempted, what's pending, and what's clean-vs-dirty. If either worktree has uncommitted changes that look load-bearing, surface them.

4. **The project CLAUDE.md** — `/Users/atin/Projects/Stage11/code/c11/CLAUDE.md`. The "Lineage", "Pitfalls", and "Localization" sections are particularly relevant; the rebrand pass is fork-level and must keep upstream-merge ergonomics intact.

5. **The cmux→c11 naming feedback memory:**
   `/Users/atin/.claude/projects/-Users-atin-Projects-Stage11-code-c11/memory/feedback_cmux_to_c11_naming.md`
   Captures the operator's distinction between "lineage talk" (where `cmux` should remain) and "wrong residual `cmux`" (where it should become `c11`). This is the rule of thumb you'll cite throughout the recommendation.

6. **Stage 11 repo CLAUDE files for context** (skim, don't deep-read):
   - `/Users/atin/Projects/Stage11/CLAUDE.md`
   - `/Users/atin/Projects/Stage11/code/CLAUDE.md`

## What to write

File path: `/Users/atin/Projects/Stage11/code/c11/notes/c11-1-recommendation-2026-05-06.md`

Structure:

### 1. Current state (concrete, not abstract)
- What's been completed (with commit SHAs / PR refs where applicable).
- What's been attempted but not landed (which worktree, what state).
- What the audit found (specific items, count, severity).
- Where the ticket's `needs_human` parking originated.

### 2. Open decisions (operator-judgment items)
List every item the audit (or the ticket trail) flagged as needing operator judgment. For each:
- One-sentence statement of the decision.
- Why it's a judgment call (not a mechanical one).
- The specific code/file/string at issue.

This is the section the operator will scan first when they return. Make it scan-friendly: numbered list, one decision per item.

### 3. Recommended resolution per item
For each open decision in section 2, state what you'd do if it were yours, with a one-paragraph rationale. Cite the cmux→c11 naming memory's lineage-vs-residual distinction wherever it applies. Be opinionated — "I don't know" is rarely useful here; the operator wants a starting point to push back against.

### 4. Suggested next steps
A proposed sequence of actions to land C11-1, given the recommendations in section 3. Should answer:
- Which worktree (if any) is the right base?
- What's the right commit ordering?
- Where the natural commit boundaries are (one PR or multiple).
- What validation the operator should run before merging.
- Any remaining "needs_human" items that would survive even after your recommendations are accepted.

## Constraints

- **No code changes.** Do not edit any source files.
- **No Lattice writes.** Do not transition the ticket's status, do not post comments.
- **No PRs.** Do not push branches.
- **No screen scraping the running c11 app.** This is a documentation-and-code-archaeology task, not a behavior-validation task.
- **Stay opinionated but honest.** If the audit found something you'd defer, say "defer" and why. If you'd ship something the audit flagged as "ask the operator," say "ship" and why.
- Use absolute file paths in your recommendation so the operator can navigate quickly.

## When you're done

1. Write the recommendation file at the path above.
2. Append the file path to `/Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/c11-1-research-done.txt` (one line, the absolute path).
3. Stop. Do not address the human directly — the meta-orchestrator will pick up the completion signal from the `c11-1-research-done.txt` file on its next polling tick.
