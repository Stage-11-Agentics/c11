# Resume a parked ticket (Codex Luna, max effort, fast mode off)

You resume a ticket that was parked mid-flight when Codex ran out of quota. Your ticket, branch, worktree and the parked head are in your launch prompt.

Read first, in this order:
1. `owner-common.md` and `go-owner.md` in this directory: your contract (mailbox tab:210, envelopes, Atlas builds via `scripts/remote-build.sh` under your ticket's tag, VM priority rule, free your tag at handoff, disclosure, no installed-skill sync).
2. Your ticket: `lattice show <ticket> --full`. The latest comment titled **PARKED for rollover** is the handover: what is done, what remains, open review findings. Read the review verdicts in the events too.
3. The branch diff against `origin/main`.

Then:
- Actor `agent:luna-<ticket number>`. `lattice assign` the ticket to it. Rename your tab `<ticket> Luna` and set the description.
- Your worktree already holds the parked branch. `git fetch origin && git status`; confirm HEAD equals the parked head before editing. If the previous owner's tab is still open, never touch its files; it has stopped.
- Finish the remaining work and any open review findings as the handover lists them. The bar is unchanged: behavioral tests that go red without the fix, runtime proof where the ticket or the risk list requires it, the typing-path rules in CLAUDE.md.
- No subagents for implementation. Push only at handoff, then `HANDOFF <ticket> REVIEW <head> <PR> <validation>` to tab:210 (`c11 send --workspace 8D68EE13-823E-44FF-B2DE-611FFD7BDA7F --tab tab:210 "<line>" && c11 send-key --workspace 8D68EE13-823E-44FF-B2DE-611FFD7BDA7F --tab tab:210 enter`).
- If you hit something you cannot resolve safely, send `BLOCKED <ticket> <evidence> NEXT <smallest action>`.
