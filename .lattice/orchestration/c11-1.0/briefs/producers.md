# Seat: Journal Producers Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Journal Producers Grok
- **Actor:** `agent:grok-producers`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-producers` (first branch `c11-1.0/C11-274-claude-hooks`; later tickets their own branch from origin/main)
- **Seat id for envelopes:** `producers`

## Queue (each ticket its own branch and PR)
1. **C11-274** widen Claude lifecycle observations through per-process hooks (`Resources/bin/claude` `--settings`): StopFailure, PermissionRequest (observe only), async PostToolUse, SubagentStart/Stop, PreCompact; bypass-mode AskUserQuestion/ExitPlanMode at PreToolUse become blocked asks.
2. **C11-275** Codex per-process hooks gated on an isolated trust proof (`--enable hooks`, `-c hooks.*`); if `--dangerously-bypass-hook-trust` cannot be proven to trust only c11's hooks and nothing from the operator's `~/.codex`, stay on `notify`. Canary marks the adapter degraded with no `session.started`. The trust probe itself needs Codex runs: in planning mode design it; a tiny isolated probe with a throwaway `CODEX_HOME` copy is allowed only if it writes nothing to `~/.codex` and uses a light model (`gpt-5.6-luna`).
3. **C11-276** advisory Codex and Grok turn edges from transcript observation (`AgentModelDetection` tailer; honest 4 MiB backlog skip; transcript rank never sets or clears blocked).
4. **C11-278** document the bounded per-process hook rule (D5) in CLAUDE.md and PHILOSOPHY.md, sync the journal operating skill, fix doc drift (`references/metadata.md` activity persisted; `references/events.md` seq starts at 1). This is the only doctrine amendment in 1.0; keep it bounded: optional, non-blocking observations; no tool bodies, no answers, no trust broadening.

The journal contract is settled: C11-272 spec (`/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`, reviewed and attested) and the C11-273 store/append/fold plan (`.lattice/plans/task_01M3X3XPNP88K5250NDJPYK02S.md`). Plan against their exact verbs, kinds, ranks and fields; do not redesign them. If the contract cannot support your ticket, send BLOCKED with the exact gap rather than inventing a second reducer. Your tickets implement only after C11-273 merges (dependencies merge before dependents implement).

Coordinate by name only: C11-306 (Stop hook transcript read bound, Launch seat) also edits the Claude hook path; C11-271 fixtures (Fixtures seat) are your oracle: `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-fixtures`.
