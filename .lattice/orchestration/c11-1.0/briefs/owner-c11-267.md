# Owner: C11-267 (send input-state inspection and draft/dialog guard; P2)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you.

- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-267`, branch `c11-1.0/C11-267-send-guard` (already on origin/main 9df90421ef). Provision submodules and GhosttyKit before the first build.
- Actor `agent:luna-267`; tab title `C11-267 Luna`; link the branch on the ticket.
- A plan exists on the ticket (`.lattice/plans/task_01M3X3WRBXMCM5NY1SEJ8TW4YG.md`). Re-check it against current main (much has merged since) and amend only real errors, then implement.
- **Risk list for this ticket:** `c11 send` is the transport every agent in this fleet, including the Orchestrator, uses. Runtime proof before merge, on an Atlas tagged build: a real typed draft refused, an empty prompt accepted, a faint Claude auto-suggest NOT treated as a draft, a Codex prompt with a queued message, a dialog, and a cold tab returning unknown. Multi-line sends and `send-key` must be unchanged for the empty case. Show the compatibility outcome against an older server. Include a short typing-latency sample, since inspection reads the screen.
- Default behavior must not break orchestration: if a guard would refuse sends that agents rely on today, stop and send `DECISION C11-267 ...` with the choice and consequences before shipping it.
- Atlas builds only under tag `c11-267`. Push only at handoff. Then `HANDOFF C11-267 REVIEW <head> <PR> <validation>` to tab:210.
