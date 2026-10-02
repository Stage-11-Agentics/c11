# Seat: Launch Hygiene Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Launch Hygiene Grok
- **Actor:** `agent:grok-launch`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-launch` (branch `c11-1.0/C11-258-launch-prompt-file`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `launch`

## Queue (each ticket its own branch and PR)
1. **C11-258** launch-agent: deliver long prompts by file reference and report startup truthfully. Incident: on 2026-10-01 a long `--prompt-file` launch left the shell at a `>` continuation prompt for 40 minutes (tab:113). Find out whether it is quoting or the bracketed-paste split, from the code path (no reproduction by launching on this Mac beyond tiny, cheap probes in a workspace you create and close).
2. **C11-269** runtime hygiene: reset claude-teams' inherited SIGPIPE before exec; stop writing `c11-notify.js` into `~/.config/opencode/plugins/` (the wrapper loads it per process). The second is a doctrine fix: plan what happens to copies already installed on users' machines (c11 must not reach in to delete them unless that is clearly within its own installed footprint; recommend, and send DECISION if it needs Atin).
