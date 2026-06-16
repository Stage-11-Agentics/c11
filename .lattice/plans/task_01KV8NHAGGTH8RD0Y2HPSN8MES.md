# C11-150: Lattice board: worktree/divergent-state sync causes short-ID collisions — harden + fix LATTICE_ROOT doc

Root-caused during v0.53.0 release (filing the mailbox follow-ups C11-148/149 collided with the shipped C11-143/144).

== Failure mode ==
When Lattice board work is performed against a DIVERGENT .lattice (a worktree's own board, or a separate checkout) and the resulting files are later synced/copied into the main checkout's .lattice/ WITHOUT reconciling the index, you get:
  - Duplicate short IDs: main's ids.json 'next_seqs' counter lags reality, so the next 'lattice create' reissues an in-use short ID. (Hit live: C11-143/144 existed as done tickets from the mailbox workstream but were unmapped in main's ids.json; counter sat at 145; creating two follow-ups reissued 143/144.)
  - Unmapped tickets: C11-145/146/147 task files were on disk but missing from ids.json 'map', so 'lattice show C11-145' failed until repaired.
  - Lifecycle gaps: 5 task_created events were missing from events/_lifecycle.jsonl (doctor flagged them).
This matches the worktree-guide warning that divergent state is 'unrecoverable without manual intervention' — which is exactly what the v0.53.0 repair was (hand-edited ids.json + _lifecycle.jsonl; see commit 376d9801a).

== Likely trigger (doc bug) ==
The lattice worktree-guide (references/worktree-guide.md, ~line 19) instructs: 'export LATTICE_ROOT=$(cd .../.lattice && pwd)' — i.e. point at the .lattice DIRECTORY. But the CLI REJECTS a .lattice path and wants the PROJECT ROOT (the lattice-orchestrator boot templates correctly use 'export LATTICE_ROOT=<absolute-repo-root>'). An agent following the worktree-guide sets a path the CLI ignores -> find_root walks up / creates a divergent worktree board -> the collision above. The two docs contradict each other.

== Fixes ==
1. (Lattice/global skill) Fix worktree-guide.md: LATTICE_ROOT MUST be the PROJECT ROOT, not the .lattice/ dir. Reconcile with the orchestrator boot templates. (Confirmed by repeated field experience; see agent memory 'LATTICE_ROOT in worktrees'.)
2. (Lattice upstream, code/Lattice) Make 'lattice create' collision-resistant: derive the next short-ID seq from max(existing short_id on disk), never blindly trust a counter that can lag. Reject/repair on detected duplicate at create time.
3. (Lattice upstream, code/Lattice) Add 'lattice doctor --fix' to auto-repair: rebuild ids.json next_seqs + map from task files, backfill _lifecycle.jsonl. Today doctor only REPORTS; recovery is manual hand-editing.
4. (lattice-orchestrator skill) Delegator/merge protocol: after any worktree-originated board work lands in main, run 'lattice doctor' and reconcile before declaring the run done. Add to the worktree footgun section.

== Acceptance ==
- worktree-guide.md and orchestrator boot agree on LATTICE_ROOT = project root.
- 'lattice create' cannot reissue an on-disk short ID (test: seed a tasks/ file with a higher short_id than next_seqs, create, assert no collision).
- 'lattice doctor --fix' repairs counter/map/lifecycle on a synthetic divergent board.
- orchestrator skill documents the post-merge doctor+reconcile step.
