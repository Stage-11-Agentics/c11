# Seat: Atlas Builds Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Atlas Builds Grok
- **Actor:** `agent:grok-atlas`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-atlas` (branch `c11-1.0/C11-216-atlas-builds`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `atlas`

## Queue
1. **C11-216** (P0): tagged builds, tests and release builds on Atlas. **This gates build mode for the whole run.**

## Specifics
- A draft exists at worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-216-remote-build` (`scripts/remote-build.sh`, reloads no-launch work). Inspect it; do not assume it works; bring what is useful into your branch. Read `lattice comments C11-216`.
- **Atlas is being prepared right now by another agent ("Atlas Fleet Prep")**: Xcode 26, Codex, Grok, current c11. Its report will appear at `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/atlas-prep.md`. Do not install, update or restart anything on Atlas, do not touch its keychains or launch agents, and do not kill processes there. Another agent ("Atlas Leak Hunt") is also active on Atlas.
- In planning mode you **may** write the script and docs and probe Atlas read-only over `ssh atlas` (user `atinwoodard`; never hardcode a home path). Do not run xcodebuild on Atlas until `atlas-prep.md` shows Xcode verified; then you may run your first remote build **on Atlas** (never on Hyperion) through `scripts/with-build-lock.sh`. That first tagged artifact is the run's gate; send a HANDOFF when you have a reviewed-ready PR.
- Design: thin SSH entry around the existing locked scripts; per-tag directory on Atlas; SHA-keyed GhosttyKit cache and DerivedData there; exact source + submodule identity recorded; artifact and logs copied back; nonzero on remote failure and never launch a stale artifact; serialized by Atlas's lock. Update the `c11-hotload` skill (and `skills/c11` if relevant) so delegators default to the remote path, then `scripts/sync-installed-skills.sh` after merge (the Orchestrator will tell you when).
- Release/notarization on Atlas: document what is missing (signing identity, notary profile) as a DECISION if it needs Atin; do not copy credentials anywhere.
