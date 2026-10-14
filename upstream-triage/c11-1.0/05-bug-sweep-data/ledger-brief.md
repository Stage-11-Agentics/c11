# Merge the bug-sweep verdicts into one ledger

READ ONLY on the c11 repo. Write only the two files named below. No builds and no fetches. Load the `c11` skill. Your tab is "Bug Ledger"; end your description with `Lineage: cmux Harvest Lead → Bug Ledger`.

**Inputs** (all in `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/`):
- Round 1: `verdicts-lead.md`, `verdicts-browser.md`, `verdicts-focus.md`, plus the full ranked table in `../05-bug-sweep.md`.
- Round 2: `verdicts/*.md`. The `skipped-1` and `skipped-2` files finish rows that other batches skipped, and their spot-checks override the original verdict where they disagree.

**Task:**
1. Collect every row whose final status is `shared-confirmed` or `shared-probable`. Also count, but do not list, `already-fixed`, `n/a-diverged`, `na-feature`, `noise` and `done-round1`.
2. **Deduplicate.** The same bug often appears in several batches, or in both round 1 and round 2. Merge by root cause, not only by PR number, and keep every PR and commit id.
3. Give each merged bug a stable id `B001`, `B002` and so on, ordered by severity (high, then med, then low), then confirmed before probable.
4. Write `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/LEDGER.md`:
   - **Counts:** per batch and in total, before and after dedup.
   - **One table:** id, bug in plain English, upstream PRs and commits, subsystem, status, severity, port size, recommendation, evidence (c11 `path:line` plus upstream ref), source batch or batches, and notes. The notes link any known c11 problem: the 08-25 deadlock, C11-130/169/235, C11-197/202/205, C11-131/139.
   - **Conflicts:** any row where two sources disagree on status, with both views.
5. Write `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/LEDGER.tsv` with the same table, tab-separated.

When finished, set your tab description to `Done: <N> bugs (<confirmed> confirmed, <probable> probable) after dedup` and stop. Do not message anyone.
