# Seat: Ghostty Patch Astra

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Ghostty Patch Astra
- **Actor:** `agent:astra-ghostty`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-ghostty` (branch `c11-1.0/C11-294-ghostty-patchset`, base origin/main)
- **Seat id for envelopes:** `ghostty`

## Queue
1. **C11-294** (P0, L): make Ghostty mailbox waits abortable and ship the 1.0 terminal patch set, including the 2026-08-25 freeze root (Atin ruling B2: fix it in the same Ghostty update as the cmux fixes). One submodule bump.

## Specifics
- Sources: the ticket, `upstream-triage/c11-1.0/05-bug-sweep.md` and `05-bug-sweep-data/LEDGER.md` (rows named in the ticket) plus the Fable/Astra bug audits in that folder; `docs/ghostty-fork.md`; CLAUDE.md "Ghostty submodule workflow" and "GhosttyKit xcframework and checksums".
- The submodule is not initialized in your worktree. For planning, read Ghostty at `/Users/atin/Projects/Stage11/code/c11/ghostty` (read-only; its remotes: `origin` = manaflow-ai/ghostty upstream, `stage11` = Stage-11-Agentics/ghostty fork). Upstream cmux's Ghostty fork changes are the reference. **Never push to manaflow-ai.** In build mode you will init the submodule in your worktree, branch in it, push to the `stage11` fork's `main` before moving the parent pointer, and expect a red first CI run until `build-ghosttykit` publishes the checksum.
- Plan: each patch, its upstream source commit (credit preserved), the observed incident or ledger row it closes, and how it is proven (fixture/stress on an Atlas tagged build; the soak C11-270 measures the fleet). Note the sibling ticket C11-295 (app-side half of B010 and the main-thread stalls, another Astra seat) and keep the app/submodule boundary clean between you.
- Bounded patch set: only the rows the ticket names. No speculative hardening.
