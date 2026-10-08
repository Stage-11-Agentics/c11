# Narrow review: C11-282 merge resolution with C11-295 (Grok)

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Grok: read-only, no builds or tests, no subagents.

- Ticket **C11-282** (Grok PASS at 14c736b2, ev_01M3Y4YNKJA5MXGWS9GPKRZE5W). PR https://github.com/Stage-11-Agentics/c11/pull/529, merge head `f3192aae0a184d9b01e22d5595e6788a65f47270` merging main f731745df1 (C11-295: bounded screen reads, cold-start helper).
- Title `C11-282 Merge Review Grok`. Actor `agent:grok-review-282m`.
- Review ONLY the conflict resolution: `git show --remerge-diff f3192aae0a184d9b01e22d5595e6788a65f47270` (Sources/SocketHandlers/SurfaceHandlers.swift and anything else it touched). Owner's description (validation ev_01M3Y64E2M0J3XZMDVJ738DSZ8): the screen path keeps C11-295's five-second shared deadline, the off-main cold-start wait capped at 2 s/remaining deadline, main revalidation, and try-lock/free around the native read; the selection path keeps its five-second wait/abandonment, try-lock/capped copy/free on main, worker encoding and the same-deadline publication check.
- Blocking only if either path lost its caller bound or native lock-acquisition bound, a lock can be held across the other path, a freed surface can be read, or either side's behavior changed. Cite file:line.
- When done, send VERDICT and wait.
