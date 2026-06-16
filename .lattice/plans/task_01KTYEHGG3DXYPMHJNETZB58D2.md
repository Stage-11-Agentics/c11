# C11-132: Browser portals: fix SwiftUI layout feedback loop (multi-browser freeze)

Operator-reported freezes when multiple browser surfaces are open; corroborated fleet-wide by Sentry and a local macOS CPU-resource diagnostic.

EVIDENCE
- Sentry C11-1 (https://stage-11-kl.sentry.io/issues/C11-1): AppHang >=8s in DisplayList.ViewRenderer, 135 events / 8 users since 2026-05-04, still firing on 0.51.0+108. Main thread stuck in NSHostingView.layout -> ViewGraph.renderDisplayList with deep recursive _layoutSubtreeWithOldSize chains. ~20 sibling AppHang groups share the same main-thread-layout signature.
- Local CPU diag /Library/Logs/DiagnosticReports/c11_2026-06-11-135049_Hyperion.cpu_resource.diag: 56% CPU for 160s, heaviest stacks = continuous NSHostingView.beginTransaction -> GraphHost.flushTransactions -> repeated sizeThatFits passes every runloop turn. Zero WebKit frames - churn is in c11 chrome, not the webviews.

MECHANISM (verified in source)
- BrowserPanelView.swift:589-590 - onPreferenceChange(BrowserAddressBarHeightPreferenceKey) writes addressBarHeight @State with no equality guard.
- That state feeds paneTopChromeHeight into WebViewRepresentable (BrowserPanelView.swift:1325); updateNSView + host.onGeometryChanged call BrowserWindowPortalRegistry.updatePaneTopChromeHeight + 4 more portal updates synchronously on every geometry change (BrowserPanelView.swift:6282+, 6315+, 6357+). Portal updates can move frames -> geometry preference re-fires -> oscillation. N browsers = N interfering loops.
- Terminal portals already have the fix browser portals lack: deferred/batched geometry sync (scheduledExternalGeometrySynchronize + dirty-ID sets, TerminalWindowPortal.swift:1017-1034) and epsilon guards (TerminalWindowPortal.swift:1695). Browser side only has a downstream epsilon check (BrowserWindowPortal.swift:2907) which stops the portal write but not the upstream SwiftUI re-render.

FIX SHAPE
1. Port the terminal portals' deferred+batched geometry sync pattern to browser portals.
2. Equality-guard the addressBarHeight preference write (epsilon, like TerminalWindowPortal.swift:1695).
3. Validate with C11_PORTAL_DEBUG=1: open 3-4 browser panes, confirm geom.external/sync.result spam disappears in /tmp/c11-portal.log; confirm idle CPU with 4 browser panes open.

Repro/validation notes will be appended from the instrumented repro pass (tag: browser-freeze).

---

## IMPLEMENTATION PLAN (Delegator-1, 2026-06-12)

Worktree: `../c11-worktrees/c11-132-browser-portal-sync`, branch `fix/c11-132-browser-portal-geometry-sync` off a3f8855fd.

Source survey result: BrowserWindowPortal already has the scheduling *skeleton* (`hasExternalGeometrySyncScheduled`, `hasDeferredFullSyncScheduled`, `scheduleDeferredFullSynchronizeAll`) but is missing three things the terminal portal has:

1. **Dirty-ID batching.** Browser's deferred tick re-syncs ALL webviews unconditionally (`synchronizeAllWebViews(source: "deferredTick")`); terminal's `runDeferredHostedSync` iterates only `dirtyHostedIds`, skipping entirely when empty. Port: add `dirtyWebViewIds`, mark at the three scheduler call sites (anchor-geometry primary, transient-recovery retry, hostBoundsNotReady) + bind's deferred re-check, and make the deferred tick dirty-snapshot-driven.
2. **Settled-layout deferral.** Browser's `scheduleExternalGeometrySynchronize` dispatches once; terminal's defers a second runloop turn when NOT in live-resize/drag so layout settles before the sync pass. Port with trigger labels on the three NSNotification observers.
3. **portalLog observability.** Browser portal has ZERO portalLog calls — /tmp/c11-portal.log only shows terminal-portal events today, so the WebContent-kill experiment can't see browser remount storms. Add env-gated (`C11_PORTAL_DEBUG`) `browser.*` events: geom.external, bind.before/after, detach, orphan.hide, deferredSync.run/skip, sync.result. portalLog is release-safe (env gate, not #if DEBUG).

Plus the upstream guard: epsilon-guard the `addressBarHeight` @State write in BrowserPanelView's onPreferenceChange (0.5pt, matching the downstream guard in `updatePaneTopChromeHeight`).

Validation: c11-logic scheme locally; tagged build `c11-132` with 4 browser panes; WebContent-kill remount-storm logs before/after as artifacts.
