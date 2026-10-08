# Seat: Restore Crashes Astra

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Restore Crashes Astra
- **Actor:** `agent:astra-crashes`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-crashes` (first branch `c11-1.0/C11-297-restore-socket`; later tickets get their own branch from origin/main)
- **Seat id for envelopes:** `crashes`

## Queue (each ticket its own branch and PR)
1. **C11-297** (P1, M): keep the control socket ready before restored agents call it (restore-time crash on a half-built window tree; shells starting before the socket listens).
2. **C11-299** (P1, S): restore a session that contains a duplicate tab id (trap in `Dictionary(uniqueKeysWithValues:)`).
3. **C11-298** (P1, S): a second copy of c11 must not kill the running fleet.
4. **C11-300** (P1, S): refuse to close a workspace from the wrong window.

## Specifics
- Sources: each ticket, `upstream-triage/c11-1.0/05-bug-sweep.md`, `05-bug-sweep-data/LEDGER.md` rows named in the tickets, the bug audits in that folder, and upstream cmux fixes named there (read-only).
- Restore is live-user critical (Atin ruled restore works well today; do not regress it). Each plan names its fixture (a synthetic snapshot for C11-299; a restore with N agents calling the socket in the first second for C11-297) and the Atlas tagged-build proof with `C11_QA_LAUNCH=resume`.
- C11-298 touches single-instance enforcement: tagged dev builds and the production app must still coexist (CLAUDE.md, tagged builds); state how.
