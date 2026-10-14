# Independent audit: which c11 1.0 features are worth building?

You are one of two independent auditors (one Claude Fable, one GPT-6-Astra). **Work alone.** Do not read, message or coordinate with any other agent, tab or area. Do not open the other auditor's output, and do not open the `05-bug-sweep-data/audit-*` files. Atin wants two genuinely independent opinions.

## Context

c11 is Stage 11's native macOS terminal multiplexer for one operator running many coding agents in parallel. It is a fork of cmux and a public product with live users. c11 1.0 is a major release that harvests the best of what cmux built since the fork (2026-03-18). Research agents proposed the features below and estimated their size. **They are the same agents that proposed them, so treat their value claims and estimates as optimistic until you have checked them against the code.**

Read, in this order:
1. `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/C11-1.0.md`: the plan, with decisions D1 to D27.
2. The reports behind it: `01-event-journal.md`, `02-ssh-agents.md`, `03-feed-attention.md`, `04-ios-companion.md`, `06-grab-list.md`. The bug harvest (`05`) is audited separately, so skip it except where a feature depends on a bug fix.
3. `~/Projects/Stage11/code/c11/PHILOSOPHY.md`, plus the "unopinionated about the terminal" section of `~/Projects/Stage11/code/c11/CLAUDE.md`.
4. `~/Projects/Stage11/code/c11/docs/aar-c11-188-attention-loop.md`, the after-action review of a reducer design that failed eight review cycles.

Sources:
- c11 at `~/Projects/Stage11/code/c11`. Read `origin/main` (`git show origin/main:<path>`), because the local checkout is behind.
- cmux at the `upstream/main` ref in the same repo.
- READ ONLY: no edits, builds, tests or `git fetch`. The machine is shared, so no heavy work.

## Who it is for

- **Atin:** 10 to 40 agents (Claude Code, Codex, Grok) across many workspaces, sessions lasting days. Hyperion is his MacBook, and Atlas is an always-on Mac Studio on the tailnet. He drives c11 mostly through agents and the CLI, and talks to Overwatch, an agent that watches his whole fleet. Most of his agents run in bypass-permissions mode.
- **c11's public users:** fewer agents, many on 16 GB Macs, no tailnet or Atlas.

## The items to audit

Audit each of these as its own row:
- **Event journal:** phases 1 to 4.
- **Feed:** phases 0 to 6.
- **Agents on remote hosts:** every slice in section 3's table.
- **The grab list:** items 4.1 to 4.20.
- **Phone:** the flag-notification fix, and the ntfy rungs.

Add any item that the plan bundles but that deserves its own row.

## For each item

- **Value to Atin:** high, med or low, with the concrete workflow moment it improves.
- **Value to public users:** high, med or low.
- **Real complexity:** S, M, L or XL. Name what you read in the code that drives the estimate. Say where you disagree with the report's estimate.
- **Risk:** typing-latency hot paths, new deadlocks or main-thread work, doctrine creep (writing tenant config, c11 knowing what agents think), a C11-188-shaped open-ended correctness target, security surface, and maintenance burden from tracking a fast-moving upstream.
- **Cheaper alternative:** does something smaller get most of the value?
- **Verdict:** `core 1.0`, `1.0 if time`, `1.x`, or `cut`, with the one-line reason.

## Also deliver

1. **A six-week 1.0.** Assume six weeks of a Codex and Grok worker fleet: about 6 to 8 parallel workers, cross-family reviews, builds and soaks on Atlas, and Atin's sign-off passes. What exactly ships? What is the critical path? Count the bug harvest's must-do work as roughly two of those weeks running in parallel.
2. **Red team.** Make the strongest honest case *against* the two biggest bets, the event journal and agents on remote hosts. Then say whether that case wins.
3. **Dependencies.** Which items unlock others? Which items are mis-sequenced in the plan's section 7?
4. **What the plan got wrong:** decisions D1 to D27 you would answer differently, and why.
5. **What it is missing:** anything cmux built that the plan skipped and you would argue back in, and anything 1.0 should have that cmux does not.

## Output

Write to `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/feature-audit-<YOU>.md`, where `<YOU>` is `fable` or `astra`. Sections, in order:

1. Verdict in five lines.
2. Item table.
3. The six-week 1.0.
4. Red team.
5. Dependencies and sequencing.
6. Decisions you would change.
7. Missing.

Style: plain, short sentences, no em-dashes. Cite file paths and line numbers for factual claims. Mark inferences.

When you finish, set your c11 tab description to `Done: <core> core, <iftime> if time, <1x> 1.x, <cut> cut` and stop. Do not message anyone.
