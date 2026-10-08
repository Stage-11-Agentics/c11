# C11-330: Tab-rail tip Undo leaves the area's rail open state; choosing Rail later reopens it

Found in the C11-292 sign-off rehearsal on signoff-1-1 (step 20, Rehearsal B; evidence build-remote/rehearsal-b/evidence/c11-292b-02/20b-*). Repro: force-offer the tab-rail tip, overflow the strip, choose Try Rail, choose Undo, then select Rail in Settings; the same area's rail reopens instead of starting closed. Minor: the operator explicitly chose Rail. Not a 1.0 blocker (Orchestrator triage 2026-10-03). Fix: Undo should also clear the area's remembered rail-open state. Owner area: C11-249.
