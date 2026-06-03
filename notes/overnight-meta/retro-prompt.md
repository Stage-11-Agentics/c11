# Overnight Run Retrospective — Analysis Prompt

You are a fresh Claude Code session running in a new c11 surface inside the operator's chat pane. Atin (the operator) is awake and will read your output directly in this surface.

## Your task

Investigate what happened during the overnight Lattice multi-delegation run that started at 2026-05-06T22:46:57Z (~3.5 hours before this writing) and produce a retrospective. The run is **still in flight** — the orchestrator and four delegators are running in `workspace:3` ("Overnight Run") on the same c11 instance. Don't disrupt them; just investigate.

The output is a markdown report at:

`/Users/atin/Projects/Stage11/code/c11/notes/overnight-retrospective-2026-05-06.md`

It should answer three questions, in this order, with specific evidence:

1. **What went well.** Patterns, infrastructure, decisions that held up under pressure. Be specific — name the design choice and the moment it earned its keep.
2. **What went wrong.** Real bugs, near-misses, surprises. Don't sanitize. Include the bugs that *would have* shipped a false-positive validation if the operator hadn't questioned the silence.
3. **What to do differently next run.** Concrete changes — to the runbook, to the lattice-delegate skill, to the c11 surface model, to delegator prompt structure. Each recommendation should trace back to a specific incident in section 2 (or a specific success in section 1 worth doubling down on).

## Sources to read

In rough priority order:

1. **`/Users/atin/Projects/Stage11/code/c11/notes/overnight-orchestration-plan-2026-05-06.md`** — the runbook. Read in full. This is the contract that was executed. Note especially the operator-confirmed policies and the resume checklist.
2. **`/Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/state.json`** — orchestrator's persistent state. Tells you the live status of each delegation as of last polling tick.
3. **`/Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/digest.md`** — heartbeat trail. The chronological story of the run, written by the meta-orchestrator. This is your timeline.
4. **`/Users/atin/Projects/Stage11/code/c11/notes/c11-1-recommendation-2026-05-06.md`** — the C11-1 research deliverable that landed in 5:37. Worth a read for context on what the research path looks like.
5. **The four delegator prompts in their worktrees:**
   - `c11-worktrees/c11-17-overnight-installer-purge/.lattice/prompts/c11-17-delegator.md`
   - `c11-worktrees/c11-30-overnight-close-overlay/.lattice/prompts/c11-30-delegator.md`
   - `c11-worktrees/c11-24-overnight-manifest-viewer/.lattice/prompts/c11-24-delegator.md`
   - `c11-worktrees/c11-16-overnight-fda-detect/.lattice/prompts/c11-16-delegator.md`
6. **The lattice-delegate skill** at `/Users/atin/Projects/Stage11/.claude/skills/lattice-delegate/SKILL.md` — the pattern that was implemented. Compare its claims against what actually happened.
7. **Validation artifacts on disk:**
   - `/tmp/c11-16-validate/` — Codex computer-use screenshots from C11-16
   - `c11-worktrees/c11-30-overnight-close-overlay/.lattice/artifacts/c11-30-validation/` — Codex screenshots from C11-30
8. **Branch commit history** — for each `c11-{17,30,24,16,18}-overnight-*` branch on origin, `git log origin/main..origin/<branch> --oneline` shows the actual code work. Compare to what state.json claims.
9. **Lattice ticket trails** — `lattice show C11-{17,30,24,16,18,1} --full` for each ticket. Note: the run hit a known regression where parent-repo `.lattice/events/*.jsonl` got truncated by a parallel session's auto-stash; the digest captures what was lost. Use this as part of section 2.

## Known issues you should look into (don't treat this list as exhaustive)

- **Cross-wired sub-agent launches.** At least two times (C11-16 Review, C11-24 Validate) a delegator spawned a sub-agent that inherited the wrong worktree's cwd, causing the agent to read the wrong phase prompt and validate the wrong ticket. The C11-24 Validate case posted a "Validate pass" Lattice comment for C11-17 — would have shipped a false validation if not caught. Why did this happen? What should the launch protocol enforce to make it impossible?
- **Codex vs Claude Code mismatch.** The C11-24 delegator launched a Claude Code session for Validate when its prompt mandated Codex computer-use. Why? How does the lattice-delegate skill enforce TUI choice on sub-agent launches?
- **Lattice events stash regression.** A parallel session's `git stash` (auto-stash before branch switch) captured ~75 lines of overnight Lattice events from the parent repo's `.lattice/events/*.jsonl`. Delegators self-recovered via `lattice status --force` with audit-trail comments — robust, but the stash recovery is now an operator action queued for after the run. How should we prevent this in the future? Is `.lattice/events/` in `.gitignore`? Should it be?
- **Validate phase pacing.** The runbook implicitly suggested ~1-3 hours total for the queue; in reality, heavy validation (Codex computer-use on tagged builds) took 30-60+ minutes per ticket and the queue still hasn't drained 3.5 hours in. What's the realistic per-ticket estimate?
- **C11-16 Validate Test 1 FAILED.** The TCC primer didn't appear during validation. Was that a real product bug, a test-setup flaw, or something else? Track the resolution.
- **CI workflow name mismatch.** The runbook listed `build`, `compat-tests`, `workflow-guard-tests` as the blocking workflows. Real names are `CI`, `macOS Compatibility`, `Build GhosttyKit`. The orchestrator caught and adjusted at run-time. Why was the runbook wrong? How to verify before launch next time?
- **Stray surfaces in delegator panes.** Each delegator pane accumulated 1-2 unlabeled "Terminal" or stray-cwd surfaces. Cosmetic, but it makes the pane sidebar harder to scrub. What launches these? Is the lattice-delegate skill making them on purpose?

## Style guide for the report

- Be specific. Names, surfaces, timestamps, file paths, commit SHAs where relevant.
- Treat the runbook as the contract; deviations from it are findings.
- Don't repeat what happened end-to-end. Start with patterns and findings; reference moments to support them.
- Section 3 ("what to do differently") is the most valuable part — give it the most thought. Tag each recommendation with where the change lands: `runbook`, `lattice-delegate skill`, `c11 surface model`, `delegator prompt template`, `orchestrator polling logic`, etc.
- Length: as long as it needs to be. A two-page report is fine if it's dense; a five-page report is fine if every paragraph earns its place.

## Constraints

- **Do NOT modify the runbook, state.json, digest.md, or any in-flight delegator state.** The run is live; touching shared state can disrupt it. Read-only on all of those.
- **Do NOT post Lattice comments on the in-flight tickets** — comments are for the delegators, not for retro analysis.
- **Do NOT spawn sub-agents.** This is a single-pass investigation by one Claude Code session.
- **Do NOT touch the worktrees' git state** — no `git stash`, no `git checkout`, no `git reset`. Read-only operations only (`git log`, `git diff origin/main..origin/<branch>`, `git show`).
- **Do NOT pop `stash@{0}`** — it contains C11-34 + perf code from another active session. The orchestrator already noted this constraint.

When the report is written, post a one-line note to this surface ("Retro complete. File at: ...") and stop. The operator will read your report directly.
