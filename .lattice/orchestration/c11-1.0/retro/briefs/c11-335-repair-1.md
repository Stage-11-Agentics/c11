# C11-335 repair 1 (review FAIL at e36108ee34)

Review: `../reviews/c11-335-r1.md`. Read it in full.

1. **The surviving run must test the newest main** (finding 1). GitHub can admit an older push's run after a newer one, and a pending run is replaced by whichever arrives last, so `$GITHUB_SHA` can be an old commit while main sits untested. Once a run is admitted: resolve the target branch's current tip once (for a `push` to main, the live `main` tip; for `workflow_dispatch`, the dispatched ref's tip, so branch proof runs still work), pass that one immutable SHA to the already-green check and to every checkout, and make the run's green record describe that tested SHA (so the already-green lookup reads what was actually tested, not the triggering commit). Add a deterministic test for "older triggering SHA admitted after a newer main" in your shell test. Fix the "newest main" wording in the workflow comment, `CLAUDE.md` and skills so it states what is guaranteed.
2. **Benchmark exclusion** (finding 2): already in your d63db38bcf. Keep it. Proof run 37394514088 is running on that head now; you do not need to wait for it.
3. Non-blocking, for the PR description only: list every installed skill copy that needs syncing at merge (Cairn runs the sync).

Push one head with both, keep the PR draft, and hand off as before. I will dispatch the proof run on your final head.
