# C11-32 Phase 6 Research Memo — Bonsplit Nesting Reduction

**Author:** agent:claude-opus-4-7-c11-32-p6research (research lead, no code changes)
**Date:** 2026-05-06
**Scope:** Reopen-or-skip decision for Phase 6 of the workspace-switch performance umbrella, given new sample(1) evidence captured against the `phase4-store` build at 17:09 PDT.
**Status:** Research only. No source files modified. No instrumentation added or reverted. The bonsplit submodule was read but not modified; no submodule SHA touched.

---

## TL;DR

**Recommendation: keep Phase 6 skipped.** The new sample(1) evidence does **not** support reopening it. The recursion depth claim from the original Phase 6 description is approximately correct (we measured 25 levels of `-[NSView _layoutSubtreeWithOldSize:]` in the deepest path, vs. the plan's "~30 levels"), but the absolute time spent in that cascade in the captured sample is small — **176 of 4732 main-thread samples (~3.7 % of total wall time / ~8.9 % of active time)** — and the dominant addressable cost in the sample is **upstream of bonsplit**: the unconditional `synchronizeLayoutHierarchy()` calls in `WindowTerminalPortal` that drive the cascade in the first place, plus hit-testing on every frame (`dividerHit`, `dividerCursorKind`).

If the operator wants more headroom on heavy-switch p95 after Phases 4 + 5 + 8 land, the highest-yield-per-risk move is **a portal-layer optimization** (skip `synchronizeLayoutHierarchy()` when geometry hasn't changed; coalesce the multi-bind storm into one deferred sync; possibly cache the last-known frame map so a return-visit doesn't re-walk). That captures ~30–50 % of the cascade work without touching bonsplit's wrapper chain, and is reversible. A bonsplit nesting rewrite remains technically feasible — every wrapper has been audited and a flatter alternative is plausible — but the regression surface (drag-and-drop, focus routing, minimal-mode window-drag, divider behaviour) is wide, the per-pane wrapper count is only 4 (not 5+), and the time budget the cascade actually owns in this sample doesn't justify the risk yet.

**Pursue the cheaper portal-layer fix first; revisit a bonsplit rewrite only if Phase 8d's first-visit warm-up still leaves a heavy-switch tail above ~800 ms attributable to per-level layout time.**

---

## 1. Wrapper inventory

Bonsplit's per-pane and per-split chains were inventoried by reading every NSView/NSViewController subclass and NSViewRepresentable in `vendor/bonsplit/Sources/Bonsplit/Internal/Views/`. The chain depth and per-wrapper rationale are summarized below; concrete file:line references follow.

### Per-pane chain (one pane inside one split)

```
ThemedSplitView (NSSplitView subclass)
└── SplitArrangedContainerView                 [bare NSView]
    └── NSHostingView (= NonDraggableHostingController.view)
        └── PaneDragContainerView              [bare NSView]
            └── NSHostingView (= NonDraggableHostingController.view)
                └── PaneContainerView          [SwiftUI]
                    └── <client content, e.g. GhosttyTerminalView>
```

**Concrete depth: 4 native NSView wrappers + 2 NSHostingView bridges per pane**, plus the `NSSplitView` itself once per split level. The original Phase 6 description's "~5 wrappers per split level" overcounts: the actual figure is 1 `NSSplitView` + 2 `SplitArrangedContainerView` (one per arranged subview) + 2 `NSHostingView` bridges = 5 per *split level*, and an additional `PaneDragContainerView` + 1 `NSHostingView` + 1 SwiftUI `PaneContainerView` per *pane*. The plan's count was directionally right.

### Wrapper-by-wrapper purpose

| # | Wrapper | File:line | Purpose | What breaks if removed |
|---|---|---|---|---|
| 1 | `ThemedSplitView : NSSplitView` | `Internal/Views/ThemedSplitView.swift:11` | Custom `dividerColor`, configurable `dividerThickness`, **`mouseDownCanMoveWindow=false`** (line 38), `isOpaque=false` (line 26). | In minimal-titlebar mode, AppKit treats opaque NSSplitView as a window-drag source; tab clicks would be stolen. Divider colour/thickness customisation lost. |
| 2 | `SplitArrangedContainerView : NSView` | `Internal/Views/SplitNodeView.swift:87` | Bare arranged subview of `NSSplitView`. **`mouseDownCanMoveWindow=false`** (line 89), `isOpaque=false` (line 88). | Divider drags could be misinterpreted as window drags in minimal mode; divider hit-test routing breaks. |
| 3 | `NonDraggableHostingView<C> : NSHostingView<C>` | `Internal/Views/SplitNodeView.swift:61` | **`mouseDownCanMoveWindow=false`** override (line 62) at the SwiftUI→AppKit bridge. | NSHostingView default is to allow window-drag passthrough when content appears opaque; tabs become unclickable in minimal mode. |
| 4 | `NonDraggableHostingController<C> : NSHostingController<C>` | `Internal/Views/SplitNodeView.swift:69` | `loadView()` override (line 70) installs a `NonDraggableHostingView` as `view`. Pure construction-time wrapper. | Lifecycle-only: ensures every hosted SwiftUI subtree gets the non-draggable bridge by default. |
| 5 | `PaneDragContainerView : NSView` | `Internal/Views/SplitNodeView.swift:76` | Bare AppKit pane container. **`mouseDownCanMoveWindow=false`** (line 81), `isOpaque=false` (line 77). Belt-and-suspenders against AppKit drag promotion. | Drag intent could leak around the inner `NonDraggableHostingView`. |
| 6 | `SinglePaneWrapper : NSViewRepresentable` | `Internal/Views/SplitNodeView.swift:93` | SwiftUI bridge that builds wrappers 4 + 5 and wires layout constraints (line 103 `makeNSView`); manages hosted-controller lifecycle in `Coordinator`; toggles container visibility on `controller.isInteractive` (line 136). | Not an NSView — a representable. Required for SwiftUI ↔ AppKit interop; can't be flattened without replacing the SwiftUI bridge. |
| 7 | `SplitContainerView : NSViewRepresentable` (hosts `ThemedSplitView`) | `Internal/Views/SplitContainerView.swift:68` | Builds `ThemedSplitView` + 2 `SplitArrangedContainerView` arranged subviews + 2 `NonDraggableHostingController`s (line 92 `makeNSView`); divider-position sync; structural pane↔split swap detection (`updateNSView`, line 287). Implements `NSSplitViewDelegate` via `Coordinator` (line 455). | Same — required SwiftUI bridge to NSSplitView. |
| 8 | `TabBarBackgroundNSView : NSView` | `Internal/Views/TabBarView.swift:1283` | Tab-bar hover detection + minimal-mode window-drag handle. Tracking areas; `mouseDownCanMoveWindow` toggled situationally (line 1288). | Window-dragging from tab bar in minimal mode breaks; hover fade-in breaks; bonsplit's tab-bar hit-region registry breaks. |
| 9 | `DragNSView : NSView` (leading inset of tab bar) | `Internal/Views/TabBarView.swift:1379` | Pane-focus on click; minimal-mode window-drag in leading inset; double-click zoom/minimize. `hitTest` always returns `self` (line 1390). | Pane focus on tab-bar click breaks; double-click zoom breaks. |
| 10 | `ResolverView : NSView` | `Internal/Views/TabBarView.swift:1457` | Walks superview chain to expose the enclosing `NSScrollView` to SwiftUI for programmatic tab scrolling. | Programmatic tab-bar scroll-into-view breaks (selected tab won't auto-centre). |
| 11 | `Coordinator : NSObject, NSSplitViewDelegate` | `Internal/Views/SplitContainerView.swift:455` | Drag-state tracking, programmatic-position re-entrancy guards, structural change detection, entry animation flags, geometry callbacks. | Divider drags don't update model; programmatic position changes don't reach view; pane↔split swaps glitch; entry animations don't play. |

### Two important corrections to the Phase 6 plan's wrapper description

1. **`masksToBounds` is not used.** The plan said wrappers exist for "`mouseDownCanMoveWindow=false` and `masksToBounds`." A grep across `vendor/bonsplit/Sources/` finds no `masksToBounds` usage at all on the wrapper chain. The actual reason every wrapper exists is **window-drag suppression in minimal-titlebar mode** — c11 ships with a minimal/transparent titlebar, and AppKit will promote any opaque NSView (especially NSSplitView, NSHostingView) to a window-drag source unless explicitly told not to. Every wrapper in the chain (1, 2, 3, 5) overrides `mouseDownCanMoveWindow=false` for that one purpose. The plan's prescription "set `mouseDownCanMoveWindow=false` on the hosted view directly or via a subclass" is the right idea — it just needs to be done in *every* layer, not just one, which is why bonsplit currently has belt-and-suspenders.

2. **The per-split overhead is `NSSplitView` + 2× `SplitArrangedContainerView` + 2× `NSHostingView`** = 5 native AppKit views per split level. The plan was right. Per pane there is `PaneDragContainerView` + `NSHostingView` + `PaneContainerView` (1 native NSView + 1 NSHostingView bridge + 1 SwiftUI view). Total per pane (one split level + one pane): **8 native NSView descendants** between `NSSplitView` and the client content.

### Could each behaviour be moved onto an existing sibling or onto a subclassed hosting view?

| Wrapper | Subsumable into a single subclassed hosting view? | Risk |
|---|---|---|
| `ThemedSplitView` | No — it IS the `NSSplitView`. | n/a |
| `SplitArrangedContainerView` | **Yes, plausibly.** `NSSplitView.arrangedSubviews` can in principle host a `NonDraggableHostingView` directly if that subclass also overrides `isOpaque=false`. | Low-medium. Some risk that `NSSplitView` requires its arranged subviews to be plain `NSView` (its dividers measure subview rects) — needs empirical test. |
| `NonDraggableHostingView` | n/a — IS the bridge. | n/a |
| `PaneDragContainerView` | **Yes.** Its only job is `mouseDownCanMoveWindow=false`. If the immediate inner `NonDraggableHostingView` has the same override, this layer is redundant. The "belt-and-suspenders" framing in the bonsplit source suggests it was added defensively; whether it's genuinely load-bearing is testable by removing it and exercising tab clicks in minimal mode. | Medium. The defensive layer was added for a reason; need to confirm by audit + UI test before removing. |
| `PaneContainerView` (SwiftUI) | No — composes tab bar + content. Lives at the SwiftUI level, not NSView level. | n/a |

**Best-case flat shape per pane:**
```
ThemedSplitView
└── NonDraggableHostingView    [absorbs SplitArrangedContainerView's role]
    └── PaneContainerView      [SwiftUI]
        └── <client content>
```
That's **2 native NSViews + 1 SwiftUI view per pane**, vs. today's 4 + 2 + 1. **Realistic depth reduction: per-pane chain ~50 % shorter.** Per-split chain is unchanged because `NSSplitView` itself is irreducible. Whole-tree depth reduction therefore depends on the workspace shape: a workspace with N split levels and one pane per leaf would go from `(5N + 3)` views to roughly `(3N + 2)` — about 40 % fewer view levels.

---

## 2. Depth measurement

The empirical numbers come from three sources, cross-checked.

### From `c11 tree` of the live workspace

The current research surface is in a 4-pane / 3-split-level workspace:
```
window:1 → workspace:1
  ├── pane:59 (V:top)            — 1 outer V split, this pane on the top half
  └── (V:bottom)                  — bottom half is an H split
      ├── pane:61 (H:left)        — left of inner H
      └── (H:right)               — right is another H split
          ├── pane:62 (H:left)    — inner-inner left
          └── pane:63 (H:right)   — inner-inner right
```
**3 nesting levels (V → H → H), 4 panes.** Phase 7 was measuring a 5-pane / 4-level shape (`729F1 V → BD893 H → 1B763 H → A068D H`); the captured sample is from a comparable but shallower configuration.

### From `/tmp/phase4-sample-heavy.txt` (sample(1), 4732 main-thread samples @ 1 ms, ~4.7 s wall)

**Maximum recursion depth on the deepest path: 25 distinct `-[NSView _layoutSubtreeWithOldSize:]` frames stacked one inside the other.** The path enters via:
```
_dispatch_main_queue_drain
└── closure #1 in WindowTerminalPortal.scheduleDeferredFullSynchronizeAll()    [TerminalWindowPortal.swift:1508]
    └── synchronizeAllHostedViews(excluding:)                                   [:1513]
        └── ensureInstalled()                                                   [:1142]
            └── synchronizeLayoutHierarchy()                                    [:915]
                └── -[NSView layoutSubtreeIfNeeded]
                    └── -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]
                        └── -[NSView _layoutSubtreeWithOldSize:]      ←  ×25 nested
```

**Per-frame sample counts in the recursion descend monotonically** from 175 (outermost) → 154 → 153 → 85 → ... → 56 (innermost leaf). At the leaves, the work hands off to `_NSViewLayout` → AppKit private symbols → `NSHostingView.layout()` (56 samples) → `NSAnimationContext.runAnimationGroup`.

**Two `NSHostingView.layout()` frames** appear interleaved within the 25-level recursion (56 samples and 29 samples) — these are the two `NonDraggableHostingView` bridges per pane confirmed in §1.

**Notably absent on the deep path:** there is **no `-[NSSplitView ...]` selector frame** anywhere in the deepest cascade. The recursion is pure NSView parent→child layout chaining. `NSSplitView`'s own layout entry points show up only at the cumulative-count level (not in the deep stack), suggesting AppKit's splitview layout delegates to its arranged subviews' `_layoutSubtreeWithOldSize:` and the bulk of the time is in those subview chains — i.e., in the `SplitArrangedContainerView → NSHostingView → PaneDragContainerView → NSHostingView → SwiftUI` per-pane stack.

### Validation of the plan's "~30 levels" claim

**Slightly conservative.** The plan said ~30; we measured 25 in a 3-level / 4-pane workspace. Phase 7 was looking at a 4-level / 5-pane workspace, which would add ~5 more frames (one extra split level × 5 wrappers). The "~30 levels" figure is plausible for the deeper Phase-7 workspace; the figure depends on workspace shape and is roughly `5 × (split levels) + 8 × (depth of deepest pane)`, with both terms growing with the user's split topology.

### Time attribution in this sample

| Bucket | Samples | % of total |
|---|---|---|
| Idle (`mach_msg_trap` waiting in event loop) | 2753 | 58.2 % |
| Active main-thread work | 1979 | 41.8 % |
| ↳ Inside `_dispatch_main_queue_drain` (queued blocks) | 223 | 4.7 % |
| ↳   ↳ `synchronizeAllHostedViews` cascade | 176 | 3.7 % |
| ↳   ↳   ↳ `_layoutSubtreeWithOldSize:` recursion | 175 | 3.7 % |
| Hit-testing (`dividerHit` cumulative) | 238 | 5.0 % |
| Hit-testing (`dividerCursorKind` cumulative) | 147 | 3.1 % |
| SwiftUI layout (`LayoutEngineBox.sizeThatFits` cum.) | 323 | 6.8 % |

**The cascade in this sample owns ~176 ms of wall time, not the multi-second figure Phase 7 inferred from the log.** Two complementary explanations:
1. The sample window did not align with the worst-case heavy switch's silent band. The 4.7 s capture includes some idle time and ambient hit-testing, with one workspace switch's cascade visible. The Phase 7 log evidence (4112 ms outlier, 1.94 s silent band) was a different (and worse) instance.
2. The phase4-store build under measurement may already be lighter than the phase3-instr build Phase 7 logged against, because Phase 4's per-workspace observable narrowing reduces the number of representables that trigger `updateNSView` per switch.

Either way, the sample evidence suggests **the addressable cascade is in the ~150–700 ms range per heavy switch**, not the 1.5–2 s range the Phase 6 description estimated. That changes the cost-benefit of a bonsplit rewrite materially.

---

## 3. Reduction options ranked

Five candidate strategies, ranked by yield-per-risk under the new evidence.

### Option A — Portal-layer "skip layout when stable" + bind coalescing (RECOMMENDED FIRST)

**Mechanism.** In `WindowTerminalPortal.swift:914 synchronizeLayoutHierarchy()`, guard the unconditional `layoutSubtreeIfNeeded()` calls behind a "geometry actually changed" check (compare reference view's bounds in window coordinates to last-synced bounds; skip if equal). In `bindHostedView` (line 1470) and `synchronizeHostedViewForAnchor` (line 1488), let multiple binds in one runloop coalesce into a single `scheduleDeferredFullSynchronizeAll` (already deduped via `hasDeferredFullSyncScheduled`, but the in-line `synchronizeLayoutHierarchy()` calls before the schedule still fire per bind). Optional layer: cache `hostedId → frameInContainer` map per workspace and apply the cached map directly via `CATransaction.disableActions` on a return-visit, only falling back to the full sync if any anchor bounds drift.

**Estimated depth reduction.** None — bonsplit is unchanged. But a portal-layer skip eliminates *redundant* cascade firings (Phase 7's evidence shows the cascade fires twice per heavy switch — once during the SwiftUI mount window and once during the post-bind silent band — and the second one is the one that's redundant when geometry hasn't drifted since the first).

**Estimated wall-clock yield.** **300–600 ms off heavy-switch p95** under heavy load. The sample shows the in-flight cascade owns ~176 ms; the second cascade (Phase 7's "second AppKit Auto Layout pass triggered by deferred-bind completions") is comparable or larger. Eliminating the redundant second pass is most of the win.

**Regression risk surface.** Low-medium. The risk is correctness: if the "skip" guard is too aggressive, frames that should re-flow (window resize during switch, divider drag mid-switch, anchor reparent) won't. Mitigations: (i) only skip when no anchor's bounds have changed since last sync; (ii) clear the skip cache on every divider-drag, window-resize, and pane structural change; (iii) keep the existing transient-recovery retry path intact; (iv) tag-build behind a feature flag and A/B compare per-phase log dt.

**Effort estimate.** **3–5 days.** Localized to `Sources/TerminalWindowPortal.swift` (and the parallel patch in `Sources/BrowserWindowPortal.swift` at lines 3078, 3081, 3143, 3368). No SwiftUI changes, no bonsplit changes, no `Phase 1 invariant` interaction.

### Option B — Bonsplit nesting reduction: drop `SplitArrangedContainerView` only

**Mechanism.** Modify `Internal/Views/SplitContainerView.swift:92 makeNSView` so each child is hosted directly via a `NonDraggableHostingController`-managed `NonDraggableHostingView` as the splitView's `arrangedSubviews[i]` — no intervening bare `SplitArrangedContainerView` container. The `mouseDownCanMoveWindow=false` and `isOpaque=false` overrides already exist on `NonDraggableHostingView`.

**Estimated depth reduction.** **Per split level: 5 → 4 native views (-20 %).** Per-pane chain unchanged.

**Estimated wall-clock yield.** **80–150 ms off heavy-switch p95** under heavy load. AppKit Auto Layout cost is roughly super-linear in tree depth (each level adds an `_layoutSubtreeWithOldSize:` frame plus its `_NSViewLayout` + `__36-..._block_invoke` epilogue, ~2–3 ms per level on heavy state). 5→4 per split, 3 split levels in the sample → ~3 levels removed × ~30 ms = ~90 ms.

**Regression risk surface.** Medium. (i) `NSSplitView` may rely on its `arrangedSubviews` being plain `NSView` instances for divider-rect computations; an `NSHostingView` arranged subview may interact differently with `splitView(_:additionalEffectiveRectOfDividerAt:)`. (ii) The existing `Coordinator.splitViewDidResizeSubviews` (line 771) reads `subview.frame` from arranged subviews; if AppKit adjusts hosting-view frames asynchronously, position-sync to model could become race-prone. (iii) Layout constraint installation today happens against the `SplitArrangedContainerView`; removing it requires the host controller's view to be the constraint anchor, which interacts with `NSHostingView`'s automatic intrinsic sizing.

**Effort estimate.** **4–7 days** of careful work in `vendor/bonsplit/`, including a UI matrix test (single split, nested splits, mixed pane↔split children, divider drag, structural pane↔split swap, minimal-mode window drag, focus restore, drop targets).

### Option C — Bonsplit nesting reduction: collapse per-pane chain to a single subclassed hosting view

**Mechanism.** Replace the `SinglePaneWrapper` (`SplitNodeView.swift:93`) construction `PaneDragContainerView { Constraints { NonDraggableHostingView(PaneContainerView) } }` with a single subclassed hosting view that absorbs `PaneDragContainerView`'s `mouseDownCanMoveWindow=false` + `isOpaque=false` responsibilities directly: `class PaneHostingView<C>: NonDraggableHostingView<C>` (which already has `mouseDownCanMoveWindow=false`; just add `isOpaque=false`). Then arrangedSubview contains only `PaneHostingView<PaneContainerView>` — no extra container layer, no constraint installation.

**Estimated depth reduction.** **Per pane: 3 native views (`PaneDragContainerView` + `NSHostingView` + constraint chain) → 1 (`PaneHostingView`).** ~33 % per-pane shortening; combined with Option B (the two are complementary), ~50 % total view-tree shortening.

**Estimated wall-clock yield.** **150–300 ms off heavy-switch p95** if applied alone; **250–500 ms combined with Option B**.

**Regression risk surface.** Medium-high. (i) The constraint chain in `SinglePaneWrapper.makeNSView` sets `controller.view.translatesAutoresizingMaskIntoConstraints = false` and pins to the container — removing the container changes who owns layout. `NSSplitView` resize behaviour with NSHostingView arranged subviews under autoresizing-mask layout is the unknown. (ii) `controller.isInteractive` toggling currently hides the *container* (`SinglePaneWrapper.swift:136-137`) so inactive workspaces don't intercept drag events — that exact view is the layer we'd remove. The hide would have to move onto the `PaneHostingView` itself, which interacts with Phase 1's `AppKitHiddenWrapper` semantics. (iii) `mouseDownCanMoveWindow` belt-and-suspenders is removed; if any AppKit version regresses the inner override semantics, tabs become unclickable in minimal mode and we don't notice for weeks.

**Effort estimate.** **5–10 days** of careful work in `vendor/bonsplit/`, including a UI test matrix (focus correctness, drag-and-drop, window-drag in minimal mode, hide/show on inactive workspaces, divider drag rect, drop-target hit testing). Same sub-test matrix as Option B but with more interaction surface to validate.

### Option D — Cache + replay last-known frame map per workspace

**Mechanism.** On every `synchronizeHostedView` that successfully computes `frameInContainer`, store `(workspaceId, hostedId) → frameInContainer` plus the reference view's bounds at the time. On a workspace switch (detected via the existing `bindHostedView` storm), if the cached frames are present and the reference view's bounds haven't changed, apply the cached frames directly via `CATransaction.disableActions` and skip `synchronizeLayoutHierarchy()` entirely for this switch — bonsplit's tree still has to lay out, but only once (during the SwiftUI cascade), not twice (no redundant post-bind pass).

**Estimated depth reduction.** None — bonsplit unchanged.

**Estimated wall-clock yield.** **200–400 ms on return-visits to a workspace whose geometry hasn't changed.** First-visit unaffected (no cached map yet). Heavy returners (the common case in operator workflows) benefit most.

**Regression risk surface.** Low-medium. Cache invalidation is the only sharp edge: divider drag, window resize, pane add/remove, agent-driven layout change all need to bust the cache. The bust path can be conservative (any `splitViewDidResizeSubviews` callback → invalidate all entries for that workspace) without losing much, because the cascade-skip optimization is only meaningful when nothing changed.

**Effort estimate.** **3–5 days** in `Sources/TerminalWindowPortal.swift`.

### Option E — Pre-warm the about-to-be-active workspace's layout (Phase 7 §4 alt #2)

Same as Phase 7's recommendation #2: pre-warm a primed workspace's bonsplit layout by transiently flipping `AppKitHiddenWrapper.isHidden=false`. This is **already Phase 8d** in the umbrella (line ~100 in the plan note). Not a Phase 6 alternative — it's the headline first-visit fix, gated on Phases 4 + 5 landing. Mentioned here for completeness; it's the single biggest yield (1.5–3 s on first-visit class) but Phase 6 doesn't compete with it — they target different cost classes.

---

## 4. The "via WindowTerminalPortal" angle (could a portal-layer change capture most of the win without touching bonsplit?)

**Yes — partially.**

The 2026-05-06 sample shows `WindowTerminalPortal.synchronizeAllHostedViews` is the entry point that initiates the cascade in this run. Specifically:

- **`synchronizeAllHostedViews(excluding:)` at line 1512** unconditionally calls `synchronizeLayoutHierarchy()` (line 1514) before iterating the per-host work.
- **`synchronizeLayoutHierarchy()` at line 914** unconditionally calls `installedContainerView?.layoutSubtreeIfNeeded()`, `installedReferenceView?.layoutSubtreeIfNeeded()`, `hostView.superview?.layoutSubtreeIfNeeded()`, `hostView.layoutSubtreeIfNeeded()` — **four unconditional `layoutSubtreeIfNeeded` calls per sync**, each capable of triggering the bonsplit cascade if any subview is dirty.
- **Frame management is already manual** (line 939): `CATransaction.setDisableActions(true); hostView.frame = frameInContainer; CATransaction.commit()`. The portal does not rely on Auto Layout for hosted-view positioning. **However**, the portal does install Auto Layout *for the host container itself* against the reference view (line 1118–1124, 4 edge constraints), which means the `installedContainerView`'s subtree (the bonsplit tree) is laid out via Auto Layout — and that's what the unconditional `layoutSubtreeIfNeeded` calls walk.

### What the portal layer can capture without bonsplit changes

1. **Skip `synchronizeLayoutHierarchy()` when the reference view's bounds in window coordinates haven't drifted.** Phase 7's evidence is that the cascade fires twice per heavy switch (once during SwiftUI mount, once post-bind). The post-bind pass walks the same tree the SwiftUI mount pass already walked, with the same target geometry. If we cache the last reference bounds and short-circuit the post-bind pass when bounds are equal, we get most of the cascade work back. This is **Option A**, ~300–600 ms.

2. **Coalesce multiple per-bind `synchronizeLayoutHierarchy()` calls.** Today, `bindHostedView` (line 1470) calls `scheduleDeferredFullSynchronizeAll`, but `synchronizeHostedViewForAnchor` (line 1487) calls `synchronizeAllHostedViews` directly *and then also* schedules a deferred sync. During a workspace switch with 5 binds, that's potentially 5 in-line full syncs + 1 deferred sync = 6 cascades. Coalescing to "schedule once, sync once" is a 3–5× reduction in cascade firings.

3. **Cache the per-host frame map per workspace** (Option D) so a return-visit can apply cached frames synchronously and skip the cascade entirely on the post-bind pass.

### What the portal layer cannot capture

1. **The first-pass cascade during SwiftUI mount.** The bonsplit tree still has to lay out from zero bounds at least once per workspace's first appearance in the window. AppKit's `_layoutSubtreeWithOldSize:` chain runs as part of that. Portal-layer changes don't address this.

2. **First-visit Ghostty surface creation cost** (~225 ms on main per workspace). That's Phase 8's territory.

3. **Per-level layout cost intrinsic to the bonsplit tree depth.** If the cascade fires once and walks 25 levels, the 25 levels still cost what they cost. Only Options B + C reduce this.

### Conclusion on the portal angle

**A portal-layer fix (Option A + D combined) can capture ~50–60 % of Phase 6's headline yield without touching bonsplit at all**, at much lower regression risk and roughly 1/3 the effort. It's the right first move. The bonsplit-rewrite options (B + C) become worthwhile only if Phase 8d's first-visit warm-up still leaves a heavy-switch tail above ~800 ms, AND the residual cost is provably attributable to per-level layout time after the portal-layer fix is in place.

---

## 5. Recommendation

**Keep Phase 6 skipped for now.** Pursue **Option A (portal-layer skip-when-stable + bind coalescing)** as a new lightweight Phase 6.5, in parallel with or after Phase 8 lands, with a 3–5 day budget and a tagged-build A/B against the post-Phase-4/5 baseline. Add **Option D (cached-frame replay on return-visit)** if Option A's measurement leaves room. Defer **Options B and C (the actual bonsplit nesting rewrite)** until Phase 8d is in production AND a fresh sample(1) on a representative heavy-load build shows the residual heavy-switch tail is ≥800 ms AND clearly attributable to per-level `_layoutSubtreeWithOldSize:` cost (not first-visit Metal/Ghostty work, not setActive cascades, not ensureFocus). Under Phase 8 + 8d's expected yields, the residual tail is more likely to be in the 400–600 ms range, at which point the cost-benefit no longer favours the bonsplit rewrite.

**Honest assessment of the 2026-05-06 sample as "evidence to reopen Phase 6":** the sample confirms the *mechanism* (a 25-level layout cascade triggered by `WindowTerminalPortal.synchronizeAllHostedViews`) but not the *severity* originally implied. The bonsplit nesting is a real, measurable, addressable structural cost; it is not, in this sample, the dominant addressable cost. The portal-layer entry point is the higher-leverage fix.

---

## 6. Effort / risk summary

| Option | Effort | Risk | Expected yield (heavy p95) | Touches bonsplit? | Phase 1 invariant interaction |
|---|---|---|---|---|---|
| **A — portal "skip when stable" + coalesce** | 3–5 d | Low-medium | 300–600 ms | No | None |
| **B — drop `SplitArrangedContainerView`** | 4–7 d | Medium | 80–150 ms | Yes | None |
| **C — collapse per-pane chain** | 5–10 d | Medium-high | 150–300 ms (alone) / 250–500 ms (with B) | Yes | Mild (interactive-hide moves) |
| **D — cached frame replay (return-visit)** | 3–5 d | Low-medium | 200–400 ms (return-visits only) | No | None |
| **E — Phase 8d pre-warm** | 1 wk | Medium-high | 1.5–3 s (first-visit only) | No | **Load-bearing** — must end with `isHidden=true` |

**Recommended sequencing:** Phase 8c (ensureFocus) + 8e (async setActive) [already planned, low-risk] → Phase 8d (pre-warm, headline) → re-baseline → Option A (portal skip-when-stable) → re-baseline → decide on D, B, C in that order.

---

## 7. Notes for the orchestrator / next agent

- **No code was modified during this research.** No instrumentation added or reverted. No source files touched. The bonsplit submodule was read but not modified; submodule SHA unchanged.
- **The phase4-store sample at `/tmp/phase4-sample-heavy.txt` is a single 4.7 s capture** of the live phase4-store build (PID 34882 at capture time). It includes one observable workspace-switch cascade entered via `synchronizeAllHostedViews`. A second capture aligned with a manually-triggered first-visit-class switch on the phase3-instr build would corroborate Option A's expected yield more rigorously; the operator was the only one who could trigger that cleanly during Phase 7's investigation, and the same is true here.
- **If Option A is pursued**, the most important measurement is the per-switch dt before and after the skip guard, broken down by switch class (first-visit vs return-visit). The Phase 3 instrumentation (`portal.bind.timing`, `ws.geometryReconcile.pass`, `ws.select.async*`) is sufficient — no new os_signpost markers required.
- **If Options B or C are eventually pursued**, do them sequentially, not together: Option B is the lower-risk experiment and proves out whether `NSSplitView` + `NSHostingView` arranged-subview interaction is actually safe before Option C's larger restructure.
- **Testing methodology for Options B/C** must include: minimal-mode window-drag from divider areas, tab clicks under load, drag-and-drop pane reordering, structural pane↔split swap, divider drag with mouse, divider drag with the pane resize keyboard shortcuts, focus correctness on workspace switch, focus restoration on app reactivation. The bonsplit wrapper chain is "boring infrastructure" precisely because each layer is load-bearing for one of these subtle behaviours; a tagged build behind a feature flag with the operator running real workloads for a week would be the right shape for validation.

---

## Appendix — file:line references collected during research

| Concern | Location |
|---|---|
| Portal cascade entry point | `Sources/TerminalWindowPortal.swift:1512` (`synchronizeAllHostedViews`), `:914` (`synchronizeLayoutHierarchy`), `:1502` (`scheduleDeferredFullSynchronizeAll`) |
| Portal cascade callsites | `Sources/TerminalWindowPortal.swift:953, 963, 1142, 1470, 1476, 1487, 1488, 1508, 1514, 1550, 1677` |
| Browser portal mirror | `Sources/BrowserWindowPortal.swift:3078, 3081, 3143, 3368` |
| Portal frame management | `Sources/TerminalWindowPortal.swift:939` (CATransaction-disabled assign), `:1426–1430` (seeded frame on bind) |
| Portal Auto Layout install | `Sources/TerminalWindowPortal.swift:1118–1124` (4 edge constraints to reference view) |
| Bonsplit `ThemedSplitView` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/ThemedSplitView.swift:11–41` |
| `SplitArrangedContainerView` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift:87–91` |
| `NonDraggableHostingView` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift:61–67` |
| `NonDraggableHostingController` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift:69–74` |
| `PaneDragContainerView` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift:76–85` |
| `SinglePaneWrapper` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift:93–162` (`makeNSView` line 103, `updateNSView` line 136, `Coordinator` line 157) |
| `SplitContainerView` | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift:68` (`makeNSView` line 92, `updateNSView` line 287, `Coordinator` line 455) |
| Bonsplit tab-bar wrappers | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:1283 (TabBarBackgroundNSView), 1379 (DragNSView), 1457 (ResolverView)` |
| Plan section: Phase 6 | `.lattice/plans/task_01KQZACEWKSA2E4WMX1HZY628N.md:76–85` |
| Plan section: Phase 7 findings | same file lines 180–281 |
| Plan section: Phase 7 follow-up | same file lines 284–360 |

End of memo.
