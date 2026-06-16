# C11-133: Hosted-inspector divider hit-test: cache/early-exit the per-event view-tree scan

hostedInspectorDividerHit(at:) runs from hitTest() on EVERY pointer event and, per browser slot, recursively walks the slot's entire view tree (Self.visibleDescendants) looking for inspector divider candidates - BrowserWindowPortal.swift:840-927, visibleDescendants at :1129-1137. Cost is O(N slots x tree depth) per event; with several browsers + DevTools attached (20-50+ descendants each) this contributes to pointer/typing lag.

Corroborating: the 2026-06-11 CPU diag (c11_2026-06-11-135049_Hyperion.cpu_resource.diag) shows WindowTerminalHostView.dividerCursorKind(at:in:) / updateDividerCursor(at:) burning samples from cursorUpdate(with:) - the same per-event divider-scan genre on the terminal side.

Also: BrowserWindowHostView.layout() calls reapplyHostedInspectorDividerIfNeeded() for ALL visible slots on every layout pass (BrowserWindowPortal.swift:361-369), each triggering the same descendant scan.

FIX SHAPE
- Cache divider candidates per slot, invalidated on view-hierarchy change (or on inspector attach/detach), instead of rescanning per event.
- Early-exit the descendant walk once a candidate is found.
- Mirror the discipline already documented for WindowTerminalHostView.hitTest() (pointer-event gating; see CLAUDE.md typing-latency pitfalls).

Related: C11-132 (browser portal geometry feedback loop) - same multi-browser freeze investigation, independent deliverable.

---

## IMPLEMENTATION PLAN (Delegator-1, 2026-06-12)

Stacked on C11-132's branch (`fix/c11-132-browser-portal-geometry-sync`) — both touch BrowserWindowPortal.swift.

Source survey findings (beyond the ticket):

1. **Double-scan on every pointer event with no inspector.** `BrowserWindowHostView.hitTest` computes `hostedInspectorDividerHit(at:)` then passes it to `updateDividerCursor(at:dividerHit:hostedInspectorHit:)` — which resolves via `hostedInspectorHit ?? hostedInspectorDividerHit(at: point)`. A computed-nil (the common no-DevTools case) is indistinguishable from not-provided, so the full O(slots x tree) scan runs TWICE per event. Fix the parameter contract so a caller-computed nil is honored.
2. **No pointer-event gating.** `BrowserWindowHostView.hitTest` runs divider scans on every hitTest call regardless of event type. `WindowTerminalHostView.hitTest` (TerminalWindowPortal.swift:252) gates all divider/cursor work behind an `isPointerEvent` switch. Mirror it.
3. **Per-slot candidate cache.** `hostedInspectorDividerCandidate(in: slot)` runs `visibleDescendants(in:)` (full recursive walk) + filter + per-candidate ancestor walks. Cache the resolved candidate per slot (keyed by slot ObjectIdentifier), validated cheaply on use (views alive, still descendants of slot, still visible); invalidate on slot hierarchy change (didAddSubview/willRemoveSubview already intercepted), on `onHostedInspectorLayout`, and on inspector attach/detach. Negative results ("slot has no inspector") are the high-value cache entry — most slots never have DevTools.
4. **Early-exit walk.** Keep the scored-best selection but stop the descendant walk early where pruning is safe.

Validation: tagged build, 4 browser panes + DevTools attached; debug counters or Instruments to confirm no per-mouse-event tree walks; manual divider hit/drag still works (screenshot).
