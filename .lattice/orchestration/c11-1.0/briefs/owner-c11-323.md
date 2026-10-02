# Owner: C11-323 (agents never change the operator's visible workspace) — TOP PRIORITY

Atin made this the top priority of the c11 1.0 run (2026-10-02). Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (you are on Sol; everything else applies).

- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-323`, branch `c11-1.0/C11-323-no-agent-switch` (on current origin/main). Provision submodules and GhosttyKit before the first build.
- Actor `agent:sol-323`; tab title `C11-323 Sol`; `lattice assign` and link the branch first; move the ticket backlog → in_planning → planned → in_progress.
- The ticket (`lattice show C11-323`) is the spec: scope items 1-7 and the acceptance list. Re-verify every cited line on current main (C11-283's `--window` focus fix is merged; build on it, do not redo it).
- Hard block, no setting, no override flag (Atin's choice). One gate in the selection setter; operator paths (sidebar, shortcuts, palette, notification click, jump-to-unread, menu bar, launch restore) unaffected. Background work and in-workspace focus stay fully allowed.
- **Risk list:** runtime proof before merge on an Atlas tagged build. Run the acceptance list through the CLI and raw socket v1 and v2, with the operator on workspace A and the agent in workspace B: the workspace stays selected, the app is not activated, refused calls return `workspace_switch_blocked`, and `c11 events tail` names the caller. Prove every operator path still switches, including notification click and jump-to-unread. Prove background `send`, `browser eval/click/snapshot`, `new-surface`, `launch-agent` and `set-metadata` still work. Computer use only for the visible claims.
- This fleet drives c11 through the socket all day. Nothing in it should rely on agent workspace switching; if you find a c11 skill instruction or script that does, fix it in this ticket.
- Skill, api.md, events.md and CLAUDE.md changes are part of the ticket. Do not run `sync-installed-skills.sh`; the Merge Captain syncs after merge.
- Atlas builds only under tag `c11-323`. You have VM priority after the Validator. Push only at handoff, then `HANDOFF C11-323 REVIEW <head> <PR> <validation>` to tab:210.
