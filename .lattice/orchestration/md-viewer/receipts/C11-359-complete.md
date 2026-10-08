C11-359 completion (Orchestrator, large-ticket track).
- Main PR #621 merged a95823705c (head 75abca4256): Fable PASS, Astra FAIL -> Opus synthesis FAIL -> repair c3d4d0867d (verify 1 FAIL, V1 nested lists) -> 75abca4256 (verify 2 PASS). Atlas exact-head gate by the Merge Captain; CI main (macOS) green post-merge.
- Post-merge review: Fable + Astra both FAIL (evicted reader loses place after edits above it; appearance switch not reaching system-theme readers) -> Opus synthesis -> follow-up PR #622 381b05f685 verified PASS -> merged fd263426f9.
- Runtime evidence: packaged acceptance, eviction screenshot pairs, 20-panel footprint (960 MiB physical / 10 procs with eviction vs ~2.9 GB RSS / 25 procs without), on the ticket.
- Below-bar findings: the run's hardening list (run-state.md), minted at closeout.
