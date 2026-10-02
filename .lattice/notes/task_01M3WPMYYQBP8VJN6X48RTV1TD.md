# You are the orchestrator for C11-257 (c11 agent messaging)

Atin (the operator) authorized this run on 2026-10-01. Work in `~/Projects/Stage11/code/c11`. Load the `c11` skill first, name your tab "C11-257 Orchestrator", then load `lattice-orchestrator-v2` and run the ticket with it (finish-first, bounded WIP, independent review, runtime proof). The board is the local `.lattice/` in the c11 repo.

## The ticket

`lattice show C11-257` and its plan (`.lattice/plans/task_01M3WPMYYQBP8VJN6X48RTV1TD.md`) are the contract, including the comment about the 52 lost EIO inbox copies (folded into Lane B). Read both completely before planning.

**One ticket, by Atin's choice. Do not split it into child tickets.** The five lanes (A record sends, B deliver mail to waiting agents, C drain at turn boundaries through hooks, D messages page, E `--help` fix plus teaching) are phases of C11-257: one delegator, worktree, branch (`c11-257-a` … `c11-257-e`) and PR per lane, progress recorded as comments on C11-257 prefixed with the lane letter. This is how C11-248 ran.

The four pinned contracts (C1 to C4 in the plan) are what let the lanes run in parallel. A delegator that needs to change one posts the change as a comment on C11-257 and you broadcast it to the other lanes before anyone builds on it.

## Atin's decisions (do not reopen)

- Two channels: `c11 send` stays the plain explicit poke and keeps its behavior; the mailbox is the durable, sophisticated channel.
- Full text is recorded for both channels. Full visibility.
- c11 writes the page as a self-contained file (C4), never a localhost server.

## Lane D design reference

The Overwatch prototype is at `~/Projects/Stage11/code/overwatch/tools/mailbox-viz/` (`build.py`, `template.html`; run `python3 build.py` to regenerate `index.html`). Lane D ports its views and visual language into the c11-written page and adds the `send` channel. Atin has not signed the design off yet, so Lane D's PR, like every lane, holds for his sign-off. Known nit to fix in the port: the Health funnel's sublabels overlap the next row's labels.

## Machine rules

- This is Hyperion, Atin's laptop, shared with other agents. **Another orchestrator (C11-248, vocabulary rename) is active in this repo right now.** Do not touch its worktrees, branches or `.lattice/orchestration/run-state.md`; keep your run state in `.lattice/orchestration/c11-257/` (write it with `lattice board write`).
- One c11 build per machine: every build goes through `scripts/with-build-lock.sh` (the repo's build scripts already do). Keep WIP to 3 delegators building at once; Lane E's `--help` fix and doc work don't need the lock.
- Local tests: the `c11-logic` scheme narrowed with `-only-testing`, per the repo CLAUDE.md. Never the host `c11-unit` scheme locally. Tagged builds only (`./scripts/reload.sh --tag <slug>`), launched with `C11_QA_LAUNCH=fresh` for validation.
- Provision each new worktree before its first build (submodules + GhosttyKit link; see the repo CLAUDE.md).
- Lanes B and C need live proof: a Claude, a Codex and a Grok tab in a tagged build actually receiving mail while waiting and while busy. If the screen is locked, park and ask Atin.

## Merging

Hold every lane at `pr_open`. When all five are reviewed and validated, assemble one integrated tagged dev build and write one numbered sign-off script for Atin covering: a `send` and a mailbox message showing up on the page; mail to a waiting agent arriving as a turn; mail to a busy agent arriving at its turn boundary; one of each for Claude, Codex and Grok; a send to a tab titled like `a/b: c` with a ~100-byte title; `c11 mailbox --help`. Atin's pass on that script is merge approval for all five PRs.

## Reporting

Atin switches between many agents and arrives cold. Keep your tab description current (what is happening now and the next gate). Post a short status at each checkpoint: which lanes are done, which are in flight, what is blocked. Open every report to him with what he must act on ("Needs you: nothing" or numbered questions, each with what hangs on the answer). Raise a c11 flag only for a decision only he can make.

Lineage: Mailbox research (Overwatch workspace, tab 71) → C11-257 Orchestrator
