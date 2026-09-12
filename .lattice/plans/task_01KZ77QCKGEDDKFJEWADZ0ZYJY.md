# C11-196 plan (written retrospectively, work already delivered in PR #414)

1. Evidence: pull the C11-30/C11-31 event corpus from Sentry, filter on the xpc-sync-wait
   needles, and read the frames above the wait to name real call sites rather than guessing.
2. Audit the same call shape across Sources/ for sites the 24-frame wire truncation hides.
3. Remove synchronous LaunchServices XPC from main on every confirmed site: serve c11's own
   recorded activation policy, cache LS lookups behind a TTL, detach the Settings probes.
4. Add behavioral tests through an injectable clock seam (Sources/ExpiringValueCache.swift).
5. Open a PR, let CI be the build gate, and record on the ticket that the written acceptance
   criterion is not reachable by fixing c11 code.
