# Owner: C11-278 (document bounded lifecycle hooks; sync the journal operating skill)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (Codex GPT-6-Luna max, fast mode off).

- Worktree: create it yourself from current origin/main: `git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b c11-1.0/C11-278-hooks-docs /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-278 origin/main` (fetch first), then provision submodules and GhosttyKit before any build.
- Actor `agent:luna-278`; tab title `C11-278 Luna`. `lattice assign` and link the branch first.
- Read the ticket in full (`lattice show C11-278`). Dependencies merged: C11-273, 274, 275, 276, 277 and 231. Document the CLI as it actually ships on main; run every documented example against an Atlas-built tagged app (build on Atlas; never upload an app across the link) and compare outputs with the documented schema (acceptance 4).
- C11-231 states that Claude AskUserQuestion picker answers are not observed; keep the skill consistent with that.
- Source edits only. Do not run `scripts/sync-installed-skills.sh` yourself: the Merge Captain syncs after merge and records the byte/hash verification (acceptance 4's sync item is the captain's post-merge step; say so in the PR).
- Time-box any single validation step to 15 minutes. Push only at handoff, then `HANDOFF C11-278 REVIEW <head> <PR> <validation>` to tab:210.
