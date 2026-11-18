# Review brief: the c11h M1 plan, before launch

You are a fresh-context reviewer. Atin wants the c11h M1 plan to be really good, at the high level and technically, before an orchestrated build starts. Nothing has been built yet. Do not edit any of the documents under review and do not build, launch or push anything. Read-only on code.

## Read

1. `docs/c11h-vision.md` (the goal, laws, milestones, decisions)
2. `docs/c11h-plan.md` (what Atin can do when M1 is done, ten tickets, go/no-go checks, risks): the main subject
3. `docs/c11h-m1-brief.md` (the Orchestrator's launch brief: setup, Pathfinder, waves, seats)
4. Evidence: `notes/c11v-herdr-core/SPIKE-0B.md`, `notes/c11v-herdr-core/feature-map.md`, `notes/c11v-herdr-core/EXPLORATION.md`, `docs/c11v-herdr-core.md`
5. Code: c11 `main` in `~/src/c11` (read-only), and the spike at commit `dd0d4e75a9f` in `~/src/c11-worktrees/c11v-hc-spike` (`Sources/C11vSpikeBackends.swift`, the seam in `Sources/GhosttyTerminalView.swift`). Project rules: `CLAUDE.md` at the c11 root.

## Your lens

See the line for your seat at the bottom.

## Findings

Write numbered findings, most severe first, to the file named for your seat. Each finding:

- **What is wrong or missing**, in one sentence.
- **Evidence**: a file and line, a doc quote, or the reasoning.
- **Consequence**: what goes wrong in the build or in Atin's use if it stays.
- **Smallest fix to the plan**: the exact change (a ticket's scope, an acceptance line, an order, a check).

Then a short section "What the plan gets right" (at most five lines), and a one-line verdict: `READY`, `READY WITH FIXES` or `NOT READY`.

Count only findings that would change what gets built, in what order, or whether Atin can use the result. No style notes, no wording edits.

When done, send one line to panel c11h: `c11 mailbox send --to c11h --topic c11h.review "VERDICT <seat>: <verdict>, <n> findings, <path>"`.

## Seats

- **Fable (high level):** findings file `notes/c11v-herdr-core/reviews/fable.md`. Does M1 as scoped actually get Atin to "I can use this for real agent work"? Is the scope right (too much, too little, missing a must-have for daily use)? Are the milestones after M1 in the right order? Are the go/no-go checks the right ones, and is anything a hidden project-killer? Is the parallel plan (waves, seats, the build host capacity) realistic? Does anything in the run threaten live c11 or Atin's machine? Read enough code to ground your claims.
- **Astra (technical):** findings file `notes/c11v-herdr-core/reviews/astra.md`. Check the ten tickets against the code. For each, is the scope complete (every code path it must touch, using the feature map's file:line citations, spot-checked against current `main`), is the acceptance provable in a guest in minutes, and are the dependencies and file overlaps between tickets right for parallel work? Hunt specifically for: places c11 keys off its bundle id or fixed paths that ticket 1 would miss and that would let c11h disturb a running c11 on the same machine; restart semantics an agent would hit (env, refs, resume, gate); and what the spike left half-done.
