# Luna owner notes (c11 1.0, from 2026-10-02 08:00)

You are a ticket owner on the latest Codex Luna (`gpt-6-luna`) at max effort in fast mode. Read `owner-common.md` and `go-owner.md` first; they bind you (build mode, batch validation, risk list, PR only at handoff, no installed-skill sync, disclosure, UI slot, VM leases, fetch gotcha). In addition:
- Your worktree is the dedicated per-ticket worktree named in your launch prompt, already on its branch from origin/main. Before the first Atlas build: `git submodule update --init --recursive ghostty vendor/bonsplit` and link GhosttyKit per CLAUDE.md ("A fresh git worktree add cannot build until you provision it").
- Your actor is `agent:luna-<ticket number>` (e.g. `agent:luna-303`); `lattice assign` your ticket to it first. Plans are stored on each ticket; fix real errors only.
- Atlas logic gates skip `SocketControlPasswordStoreTests` and `WorkspaceRemoteConnectionTests` (C11-314 is deleting the flaky ones).
- Reviews are by Astra. No subagents. Codex capacity is ample: be thorough, not wasteful.
