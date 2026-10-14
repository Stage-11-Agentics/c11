# Independent audit: which cmux bug fixes does c11 1.0 take?

You are one of two independent auditors (one Claude Fable, one GPT-6-Astra). **Work alone.** Do not read, message or coordinate with any other agent, tab or area, and do not open the other auditor's output file. Atin wants two genuinely independent opinions.

## Context

c11 is Stage 11's macOS terminal multiplexer for running many coding agents in parallel, a fork of cmux. The fork happened on 2026-03-18, and upstream cmux has since merged about 2,950 fix-like changes. A sweep has verified which of those bugs c11 still has. c11 1.0 is a major release that absorbs the ones worth having. Your job: **decide what 1.0 must take, what is nice to have, and what is not a priority, and challenge the verifiers where they were wrong.**

Read first:
- `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/C11-1.0.md`, the whole 1.0 plan. Section 5 is the bug harvest.
- `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep.md`, the round-one report: method, top ten, tracks.
- `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/LEDGER.md`, the merged, deduplicated list of every verified bug. This is the list you are auditing.
- The per-batch evidence: `05-bug-sweep-data/verdicts/*.md` and `verdicts-*.md`.

Sources:
- c11 at `~/Projects/Stage11/code/c11`. Read `origin/main` (`git show origin/main:<path>`), because the local checkout is behind.
- cmux at the `upstream/main` ref in the same repo.
- c11's Ghostty submodule is at `ghostty/`.

READ ONLY: no edits, branches, builds, tests or `git fetch`. This machine (Hyperion) is shared: no heavy work.

## Atin's use profile (drives priority)

- One operator running 10 to 40 agents (Claude Code, Codex, Grok) at once, across many workspaces.
- Sessions last days.
- Heavy agent-driven socket traffic: `send`, `read-screen`, `set-metadata`, `tree`.
- Frequent tab create and close, and restarts with session restore.
- c11 is also a public product with other users, some on 16 GB Macs.
- c11's own known problems:
  - the 2026-08-25 Surface.deinit deadlock;
  - main-thread congestion: C11-197, C11-202, C11-205;
  - PTYs that never attach: C11-130, C11-169, C11-235;
  - crash-resume and data loss: C11-131, C11-139.

## Method

1. **Spot-check the evidence.** Pick at least 15 `shared-confirmed` rows, weighted to high severity and to rows from Grok batches (`input-b`, `render`, `sidebar`, `socket-layout-perf`, `perf-supplement`). Read the upstream diff and the cited c11 lines yourself. Report how many held up, and list every one you overturn, with the reason.
2. **Tier every ledger row:**
   - **Must do:** a hang, deadlock, crash, data or layout loss, input corruption, or unbounded growth under Atin's profile, or a direct cause of a known c11 problem.
   - **Nice to have:** real and worth fixing, but it can slip past 1.0 without hurting anyone much.
   - **Not a priority:** rare, cosmetic, low value, or more cost than benefit.
   - You may also mark a row **reject** if you think the verdict is wrong.
3. **Look for clusters.** Several rows often share one root cause (for example Ghostty's shared mailbox, or SwiftUI sidebar recomputation). Name the clusters, and say which single fix retires the most rows.
4. **Sequence the must-dos** into a build order, with the reason for each position, and mark any whose fix risks typing latency or a new deadlock.
5. **Say what the sweep missed:** anything structurally risky you noticed in c11 while checking, even if no cmux PR points at it.

## Output

Write to `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/audit-fable.md`, where `fable` is `fable` or `astra`. Sections, in order:

1. **Verdict in five lines.** How many must do, nice to have, not a priority, rejected. The single most important fix.
2. **Spot-check results:** checked N, held M, overturned (list with reasons).
3. **Must do:** a table with columns ledger id, bug, cluster, why must, size (S/M/L), and risk.
4. **Clusters,** and the fix that retires each.
5. **Build order** for the must-dos.
6. **Nice to have:** a table.
7. **Not a priority:** a compact list (ledger ids plus a one-line reason).
8. **Rejected:** ledger ids with reasons.
9. **What the sweep missed.**

Style: plain, short sentences. No em-dashes. Cite file paths and line numbers for every factual claim. Mark inferences.

When you finish, set your c11 tab description to `Done: <must> must, <nice> nice, <not> not, <rejected> rejected` and stop. Do not message anyone.

You are the **fable** auditor. Your c11 tab title is "Bug Audit Fable"; end your description with `Lineage: cmux Harvest Lead → bug auditor`. Load the `c11` skill first. Atin's rulings since this brief was written: no separate point releases (everything ships in 1.0); GPU reclaim only on a clear bug; no sidebar rewrite; the run is planned in waves aiming for close to overnight, so size relatively (S/M/L), not in days.
