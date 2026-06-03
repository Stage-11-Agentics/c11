# Launch-time white line artifact — investigation log

**Status:** Open. Not reproduced under instrumented build (2026-04-27). No fix has been applied. The diagnostic probes have already been **reverted from source** — the running `c11 DEV overlay-redraw.app` binary still has them compiled in, but the next `./scripts/reload.sh --tag overlay-redraw` rebuild will produce a clean (un-instrumented) binary unless the probes are re-added. See [Status](#status) and [Cleanup when confirmed fixed](#cleanup-when-confirmed-fixed) before closing this out.

## Symptom

Intermittent rendering artifact on c11 launch:

- A thin **default-white** vertical line appears inside a workspace's content area, OR a larger rectangular region in which the live workspace content is occluded by stale UI.
- The line/region does not span the full height of the workspace — typically only the upper or lower portion.
- Once visible, it is **permanent** for that session: no resize, scroll, divider drag, focus change, or interaction clears it.
- It persists **across workspace switches** — the same artifact at the same coordinates stays put when the user switches to a totally different workspace with totally different content.
- It is **not affected by changing the workspace's custom color**: setting the workspace color to (e.g.) red changes the SwiftUI workspace frame stroke to red, but the artifact stays default white.

In some launches the artifact is just a thin chrome stroke. In others — confirmed by Screenshot 4 in the source conversation — an entire rectangular sub-region renders the bonsplit `EmptyPanelView` UI (the "+ A 🌐 doc" empty-pane placeholder buttons, panel-type icons) on top of the live workspace, occluding parts of markdown panels, terminal panes, or whatever happens to share that screen region.

Reference screenshots are in the conversation that produced this doc; they are not stored in the repo.

## Reproduction

Tricky. Has been observed across many "plain" launches — **not** crash-restore-specific. Has appeared with various workspace contents, including the user's normal Mission Statement and Upstream Sweep workspaces. Under the instrumented `overlay-redraw` tagged build the artifact has not yet reproduced (multiple launches), so the timing window is narrow.

Things that may or may not matter (untested):

- Window size at launch.
- Number of mounted workspaces.
- Whether the saved layout differs significantly from bonsplit's default proportional split (intermediate vs. settled divider positions can be far apart — see Findings).
- Whether a workspace contains a browser-portal pane (BrowserWindowPortal vs TerminalWindowPortal each own their own overlay; see Architecture).

## Architecture context

c11 has three nested rendering layers per window. Only the top layer is per-window:

```
NSWindow
└─ contentView
   └─ WindowTerminalHostView (per-window)
      ├─ SwiftUI host containing ContentView
      │  └─ Selected Workspace (per-workspace, replaced on switch)
      │     └─ BonsplitView → panes → terminal/browser/markdown panels
      ├─ TerminalWindowPortal.dividerOverlayView (PortalSplitDividerOverlayView, per-window)
      ├─ BrowserWindowPortal.chromeOverlayView    (PortalSplitDividerOverlayView, per-window)
      ├─ Portal-hosted Ghostty terminal NSViews   (per-window registry)
      └─ Portal-hosted WKWebView surfaces         (per-window registry)
```

Two layers draw the workspace frame edges:

1. **`Sources/Theme/WorkspaceFrame.swift`** — SwiftUI `RoundedRectangle.strokeBorder` overlay. Lives inside the workspace subtree. Observes `ThemeManager.shared.version` via `.id(themeManager.version)`. Re-renders on theme changes. Per-workspace.
2. **`Sources/TerminalWindowPortal.swift` `PortalSplitDividerOverlayView.draw(_:)`** — AppKit overlay drawn on top of portal-hosted surfaces (because portal-hosted Ghostty/WKWebView surfaces sit above SwiftUI in z-order during split/workspace churn — see CLAUDE.md "Pitfalls"). Per-window. The bug lives here.

The AppKit overlay paints divider segments (collected by walking `window.contentView` for `NSSplitView`s) plus chrome segments (workspace frame edges, derived from each portal entry's `hostedView.frame` / `containerView.frame`).

`PortalSplitDividerOverlayView` is a **shared class** with **two instances per window**:
- One owned by `TerminalWindowPortal` (`occlusionPolicy: .crossingCenterline`, internal probe label `kind=term`).
- One owned by `BrowserWindowPortal` (`occlusionPolicy: .touchingSegment`, internal probe label `kind=browse`).

Each draws the chrome segments for its own surface type only. The workspace's frame is therefore painted **piecewise** by both overlays cooperating.

## Theories evaluated

Numbered as they were in the original investigation. Each verdict reflects what we know after instrumentation and screenshot analysis.

| # | Theory | Verdict |
|---|--------|---------|
| A | Portal-hosted child NSWindow stuck at intermediate frame | **Ruled out** — portals are NSViews reparented into hostView, not separate NSWindows. |
| B | Chrome-segment draw at intermediate frame leaks into backing CALayer | **Possible but not observed** — instrumented runs show overlays redraw correctly across the intermediate-to-settled transition. AppKit clears the layer's contents on each `setNeedsDisplay = true`, so a stuck cache would require a missed invalidation. |
| C | Bonsplit applies default layout BEFORE workspace blueprint resizes panes | **Confirmed by instrumentation.** Logs from 11:37:43.585 → 11:37:43.828 show the vertical divider jumping from x=1379 to x=972 (407pt) within ~243ms of first paint. This is the timing race the bug would exploit if a redraw is missed. |
| D | `PortalSplitDividerOverlayView.draw(_:)` collects divider segments during transient bonsplit state | **Theoretical mechanism, not observed in current logs.** Both overlays produced fresh segments on each draw cycle in the instrumented runs. |
| E | Markdown panel renders at intermediate width, caches narrow render | **Doesn't explain Screenshot 1 (Claude Code surface — no markdown).** May be a secondary effect for screenshots showing clipped markdown. Unconfirmed. |
| F | SwiftUI `.overlay` with stale geometry due to `.id(...)` not invalidating on layout-only changes | **Ruled out as primary** — the SwiftUI WorkspaceFrame *does* update with theme changes (red on red). The artifact stays default white, so the artifact isn't drawn by SwiftUI. |
| G | Custom hitTest interacts with first-draw ordering | **Ruled out** — hitTest is event-routing only, not rendering. |
| H | TabManager creates transient "ghost" panel during snapshot apply | **Ruled out** — no evidence in code or logs. |

**Confirmed root cause (after Apr-27 reproduction):** an **orphan portal entry bound to a transient `EmptyPanelView` anchor**. The mechanism, captured in the instrumented log:

1. On launch, bonsplit mounts panes whose `_ConditionalContent` initially shows `EmptyPanelView` (the placeholder UI for empty panes — `+`, panel-type icons).
2. `TerminalWindowPortal.bind(...)` fires for that pane, registering an entry in `entriesByHostedId` with the bonsplit `NSHostingView` as the hosted view, anchored against the empty-branch view, and `visibleInUI=true` with a default-white `workspaceFrameStyle`. Initial frame is whatever bonsplit's intermediate layout dictates (e.g. `200,108 920x740`).
3. The actual workspace content is materialized — surfaces are mounted, `_ConditionalContent` flips from `EmptyPanelView` to `PanelContentView`. The original anchor view is gone from the SwiftUI tree.
4. Bonsplit settles: dividers move, host bounds update, sibling panes resize. **Live entries get their frames updated by `synchronizeAllEntriesFromExternalGeometryChange()`. The orphan does not** — its anchor is gone, so the geometry-sync path can't compute a new frame, and it's left frozen at step 2's coordinates.
5. From this point on, every paint cycle:
   - `workspaceFrameSegmentsForChromeOverlay` happily includes the orphan in chrome-segment generation (it still has `visibleInUI=true` and a `style`), painting white frame edges at the stale coordinates → the thin-stroke symptom.
   - The orphan's `hostedView` (an `NSHostingView`) keeps sitting in `hostView`'s subview list at the stale frame, painting whatever its current SwiftUI subtree is (often `EmptyPanelView`) on top of the live workspace → the content-occlusion symptom.

This explains every quirk:
- Window-level persistence (registry is per-window).
- Survives workspace switches (registry doesn't care about `selectedTabId`).
- Stays default-white when workspace customColor changes (the orphan's `style` was captured once and never re-resolves; the live theme observer only reaches active panel views).
- Variable x/y across launches (depends on the intermediate bonsplit frame at the moment of bind).
- Timing-sensitive (only fires when the `EmptyPanelView` branch is briefly visible at bind time).

## Key findings

1. **The artifact is window-level, not workspace-level.** Survives workspace switches at the same x-coordinate.
2. **The artifact is drawn by the AppKit overlay, not the SwiftUI workspace frame.** Workspace customColor changes do not affect it; the SwiftUI frame turns red while the line stays white.
3. **Each window has two `PortalSplitDividerOverlayView` instances** — one terminal, one browser — each drawing chrome segments for its own surface type. The workspace's frame is painted piecewise.
4. **Bonsplit applies a sizeable intermediate layout before settling.** Observed: vertical divider jumping 407pt between first paint and settled paint within ~243ms.
5. **`ensureDividerOverlayOnTop()` already calls `dividerOverlayView.needsDisplay = true` unconditionally** at the end (`Sources/TerminalWindowPortal.swift:978`). The earlier "agent" theory that it was conditional was wrong on inspection.
6. **Parked terminal portal entries persist across workspace switches.** Logs show entries with `visibleInUI=0, style=nil, hidden=1, attached=1` remaining in `entriesByHostedId`. They are correctly filtered out of chrome-segment generation by the existing guard. Risk: if any code path flips `visibleInUI=true` on these without updating their style/frame, they'd inject phantom segments at stale positions. Unconfirmed mechanism for this.
7. **Asymmetry between the two overlays**: in instrumented logs, `kind=browse` reports `dividers=2` while `kind=term` consistently reports `dividers=0`, even though both walk the same `window.contentView`. Mechanism unknown. Noted for follow-up but not on critical path. (Possible cause: terminal overlay's coordinate system or window membership at draw time is producing zero-intersection results in `collectDividerSegments`.)
8. **The browser overlay's chrome segment is invariant under horizontal divider movement when the right pane is right-pinned.** In one instrumented run the right edge stayed at `[1744,458,1x355]` across both intermediate and settled paints. This means a stuck-paint bug in the browser overlay would be invisible during such layouts. To reproduce visually we may need a launch where the *browser* pane's right edge actually moves between intermediate and settled.

## Diagnostic instrumentation

All probes are wrapped in `#if DEBUG` and use the existing `dlog` from `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`. They write to `/tmp/cmux-debug-<tag>.log` (env path: `CMUX_TAG`).

### Files modified

#### `Sources/TerminalWindowPortal.swift`

- **`PortalSplitDividerOverlayView.draw(_ dirtyRect:)`** (around line 622, after `visibleSegments` is computed):
  - Logs `overlay.draw kind=<term|browse> dirty=<rect> bounds=<rect> dividers=<n> chrome=<n> div0=<first 3 divider segments> chr0=<first 3 chrome segments>`.
  - The `kind` tag is derived from `occlusionPolicy` so terminal vs browser overlay is distinguishable from a single shared class.

- **`ensureDividerOverlayOnTop()`** (around line 967):
  - Logs `overlay.ensureOnTop branch=<install|reorder|frameSync|noop|combo> host=<size> overlay=<size>`.
  - Used to verify the overlay's `needsDisplay = true` is being toggled.

- **`workspaceFrameSegmentsForChromeOverlay(in:dividerSegments:)`** (around line 1028):
  - Logs `overlay.chromeSegments host=<rect> entries=<n> segments=<n>` followed by per-entry `use[hosted=<id> frame=<rect> color=<hex> thick=<n> opac=<n>]` or `skip[hosted=<id> vis=<0|1> style=<0|1> hidden=<0|1> attached=<0|1> frame=<rect>]`.
  - The skip variant is critical for spotting parked entries that could leak into a chrome segment if `visibleInUI` flips.

#### `Sources/BrowserWindowPortal.swift`

- **`workspaceFrameSegmentsForChromeOverlay(in:dividerSegments:)`** (around line 2250):
  - Logs `browserOverlay.chromeSegments host=<size> entries=<n> segments=<n>` with the same per-entry use/skip format as the terminal version (using `containerView` and `entriesByWebViewId` instead of `hostedView` and `entriesByHostedId`).

#### `Sources/WorkspaceLayoutExecutor.swift`

- **Around the `applyDividerPositions` call site** (around line 176):
  - Logs `layout.applyDividerPositions.begin workspace=<short id>` before, and `layout.applyDividerPositions.end workspace=<short id> failures=<n>` after.

- **Inside `applyDividerPositions(planNode:liveNode:workspace:path:)`** after `setDividerPosition` (around line 1066):
  - Logs `layout.setDividerPosition split=<short id> pos=<float> path=<dotted plan path>`.

### Probe field reference

- `kind=term` → TerminalWindowPortal's overlay.
- `kind=browse` → BrowserWindowPortal's overlay.
- `dividers=N` → number of `NSSplitView` divider segments collected from `window.contentView` and intersecting the overlay's bounds.
- `chrome=N` → number of workspace-frame edge segments produced by the overlay's `chromeSegmentProvider`.
- `chr0=[x,y,w_x_h c=#RRGGBB], …` → first up to 3 chrome segment rects with their fill color.
- `use[…]` → entry that contributed segments this draw cycle.
- `skip[…]` → entry that was filtered out of segment generation. Watch the `vis` and `style` flags — a `skip` becoming `use` mid-launch with a stale `frame` would be the bug signature.

### Log location

- Path: `/tmp/c11-debug-overlay-redraw.log` (because the tag is `overlay-redraw`).
- Format: `HH:mm:ss.SSS <event message>`.
- Tail in real time: `tail -f /tmp/c11-debug-overlay-redraw.log | grep -E 'overlay\.|browserOverlay\.|layout\.applyDivider'`.

### Building / launching the instrumented variant

```bash
rm -f /tmp/c11-debug-overlay-redraw.log
./scripts/reload.sh --tag overlay-redraw
```

The `reload.sh --tag` workflow is documented in `skills/c11-hotload/SKILL.md`. Do not `open` an untagged `c11 DEV.app` while debugging — it conflicts with the tagged debug instance.

App bundle: `/Users/atin/Library/Developer/Xcode/DerivedData/c11-overlay-redraw/Build/Products/Debug/c11 DEV overlay-redraw.app`.

## Status

- **Bug confirmed reproduced under instrumentation on 2026-04-27** (probe trace at 11:43:18–19; visual confirmation in production app at 11:48:03 showing `EmptyPanelView` UI bleeding into a markdown surface).
- **Root cause identified**: orphan portal entry whose anchor was deallocated mid-bind (see [Theories evaluated](#theories-evaluated)).
- **Fix #1 (visible-symptom stop) implemented on 2026-04-27** in `Sources/TerminalWindowPortal.swift` and `Sources/BrowserWindowPortal.swift`. See [Implemented fixes](#implemented-fixes). **Fix #2 (root cause: don't bind to empty branch) still pending.**
- Diagnostic probes reverted from source. The fix is independent of the probes.

## Implemented fixes

### Fix #1 — Orphan-entry detect-and-hide (landed 2026-04-27)

Each portal class (`TerminalWindowPortal`, `BrowserWindowPortal`) now reaps orphan entries during the geometry-sync pass and additionally guards them out of chrome-segment generation as a belt-and-suspenders measure.

**`Sources/TerminalWindowPortal.swift`**:
- New `hideOrphanEntriesIfNeeded()` method. Walks `entriesByHostedId`. For each entry, classifies the anchor:
  - `anchor == nil` (weak reference deallocated, anchor's owning representable was dismantled) → orphan.
  - `anchor != nil && anchor.window !== self.window` → orphan (anchor migrated to another window).
  - `anchor != nil && anchor.window == nil` → **not** treated as orphan, deliberately. This is a transient window-less limbo state during attach/detach and `synchronizeHostedView`'s existing transient-recovery path handles it. Hiding here would cause a flash during legitimate remounts.
- Called from `synchronizeAllEntriesFromExternalGeometryChange()` before `synchronizeAllHostedViews(excluding:)`. If any entry was hidden, `dividerOverlayView.needsDisplay = true` after the sync so the chrome strokes re-paint without the orphan.
- `workspaceFrameSegmentsForChromeOverlay`'s entry guard extended with `let anchor = entry.anchorView, anchor.window === window` so chrome segments derived from a still-live entry whose anchor has departed don't paint, even on a redraw cycle that hasn't yet triggered a geometry-sync pass.

**`Sources/BrowserWindowPortal.swift`**: same shape, mutatis mutandis (`entriesByWebViewId`, `containerView` instead of `hostedView`, `chromeOverlayView.needsDisplay`).

**Behavioural notes**:
- The hide marks `visibleInUI = false` and `hostedView/containerView.isHidden = true`. If the entry's anchor is later re-bound (e.g., after a workspace remount that originally deallocated the anchor and later registers a new one against the same hosted view via `bind(...)`), `bind` overwrites `visibleInUI` with the call-site value and `synchronizeHostedView` unhides on the next sync. So a hidden orphan can come back to life via a legitimate rebind without manual intervention.
- The check is conservative by design — it requires anchor to be either deallocated or in a verifiably different window. Pure window-less limbo (anchor alive, no window) is left to the existing transient-recovery code path.

**Probes for validation**: when an orphan is detected, the fix emits `portal.orphan.hide hosted=<id> anchor=<id> anchorWindow=<deallocated|nil|self|other>` (or the `browser.portal.orphan.hide` twin) into the existing `dlog` channel. These appear in `/tmp/c11-debug-<tag>.log` for any DEBUG build.

**What this fix does not do**: it does not prevent the orphan entry from being created in the first place. Bind still happens against a transient anchor that subsequently gets dismantled. The hide pass only catches the orphan after it forms. **Fix #2 (gate the bind) is still required to address the root cause.**

## Cleanup when confirmed fixed

Apply in order:

1. **Probe edits already reverted from source.** No action needed for the source tree — the `dlog("overlay.draw …")`, `dlog("overlay.ensureOnTop …")`, `dlog("overlay.chromeSegments …")`, `dlog("browserOverlay.chromeSegments …")`, and `dlog("layout.applyDividerPositions …" / "layout.setDividerPosition …")` calls are no longer present in `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift`, or `Sources/WorkspaceLayoutExecutor.swift`. If you re-add them for a future investigation and need to revert, the placement notes are in [Files modified](#files-modified) below.

2. **Stop the tagged debug instance and clean up its artifacts.** From `reload.sh`'s own teardown advice:

   ```bash
   pkill -f "c11 DEV overlay-redraw.app/Contents/MacOS/c11"
   rm -rf "/Users/atin/Library/Developer/Xcode/DerivedData/c11-overlay-redraw" "/tmp/c11-overlay-redraw" "/tmp/c11-debug-overlay-redraw.sock"
   rm -f "/tmp/c11-debug-overlay-redraw.log"
   rm -f "/Users/atin/Library/Application Support/c11/c11d-dev-overlay-redraw.sock"
   ```

3. **Prune the `overlay-redraw` build tag** along with any other stale tags:

   ```bash
   ./scripts/prune-tags.sh          # dry run
   ./scripts/prune-tags.sh --yes    # actually delete
   ```

4. **Decide what to do with the recommended fixes below.** They're correctness wins independent of this specific reproduction; consider landing the workspace-switch invalidation hook even if the artifact stays away.

5. **Delete this doc** (`notes/launch-white-line-artifact.md`) **only if you are confident the bug will not return.** Otherwise leave it as a starting point for the next investigation.

## Recommended fixes

Land in order. Items 1 and 2 directly address the confirmed root cause; items 3–5 are independent hardening that would catch related future bugs.

### Primary fixes (address the confirmed cause)

1. **(Visible-symptom fix — small, surgical) — IMPLEMENTED 2026-04-27.** See [Implemented fixes](#implemented-fixes). Detects orphan entries during `synchronizeAllEntriesFromExternalGeometryChange` and hides their hosted view, plus a belt-and-suspenders guard in `workspaceFrameSegmentsForChromeOverlay`.

2. **(Root-cause fix — proper) — STILL TO DO.** Don't bind a portal entry against an anchor that's about to be dismantled in the first place. The orphan we observed had `anchor=nil` at detach time, meaning the anchor (a `GhosttyTerminalView` host container) had already been deallocated by the time the workspace was torn down. That implies the anchor's owning SwiftUI representable was unmounted between bind and detach — likely because bonsplit's `_ConditionalContent` flipped from `EmptyPanelView` to `PanelContentView` (or vice versa) shortly after a `TerminalWindowPortalRegistry.bind(...)` call ran against the not-yet-final representable.

   Locate the bind call sites in `Sources/GhosttyTerminalView.swift` (`onDidMoveToWindow` / `onGeometryChanged` / inline `updateNSView` block — see lines ~9215–9314) and the equivalent in `Sources/Panels/BrowserPanelView.swift`. Add a stability gate so we only bind once the host container has been in the live tree across at least one settle cycle, or once we can confirm the surrounding `_ConditionalContent` is in the populated branch.

   Alternative formulation: register a one-shot "anchor stable in window" observation and only enter the registry once that fires. Either way, the goal is that no entry is ever registered against a host container that's about to be dismantled.

### Independent hardening (catch related future bugs)

3. **Invalidate the AppKit overlays on workspace switch.** Currently the `PortalSplitDividerOverlayView`s have no signal that the underlying SwiftUI/bonsplit content has been replaced when the user switches workspaces. Add a hook that calls `dividerOverlayView.needsDisplay = true` and `chromeOverlayView.needsDisplay = true` from `ContentView`'s `onChange(of: tabManager.selectedTabId)` (or the registry-level workspace-switch handler). Free correctness win regardless of the orphan-entry fix.

4. **Invalidate the AppKit overlays on theme/workspace-color change.** The SwiftUI `WorkspaceFrame` observes `themeManager.version` via `.id(...)`. The AppKit overlays have no equivalent. They should subscribe (via `NotificationCenter` or a `Combine` sink on `ThemeManager.shared.$version`) and flip `needsDisplay = true` when the resolved frame color or thickness changes. This is what causes the "color stays white when changed to red" symptom even for non-orphan paints.

5. **Investigate why `kind=term` reports `dividers=0`** while `kind=browse` reports `dividers=2` from the same `window.contentView` walk. This asymmetry means the terminal overlay's divider painting is currently a no-op — possibly intentional (browser handles dividers, terminal does only chrome) but worth confirming so the next person doesn't waste time on it.

## Open questions for the next investigation

- What is the exact mechanism by which `kind=term` collects zero divider segments? (Possibly window-membership check, coordinate conversion edge case, or `isHidden` on an ancestor.)
- Is there ever a code path where a parked portal entry has `visibleInUI=true` but a stale frame? Search for `entriesByHostedId.values` / `entriesByWebViewId.values` writes that could re-flip visibility without re-binding the frame.
- Is the WKWebView snapshot machinery (which uses CALayer-level snapshots for portal handoff) involved in the screenshots that show clipped markdown content? Markdown is pure SwiftUI but WKWebView surfaces aren't.
- Capture a launch with the artifact actually visible. The log slice from that exact moment will identify which overlay (`kind=term` vs `kind=browse`) and which entry is producing the visible stale segment.

## Conversation history reference

This investigation was carried out interactively. Key turning points:

1. Initial framing as a workspace-frame border issue.
2. Pushback after Screenshot 2 showed clipped markdown (not just a thin stroke).
3. Operator clarified bug is **not** crash-restore-specific — happens on plain launches too. This dropped per-restore theories.
4. Operator observed line **persists across workspace switches** at the same x. This narrowed cause to window-level components.
5. Operator observed line stays default-white when workspace customColor is changed to red. This isolated cause to the AppKit overlay (which doesn't observe theme changes), distinct from the SwiftUI WorkspaceFrame.
6. Probes wired and tagged build (`overlay-redraw`) launched.
7. Multiple launches under instrumentation — bug not reproduced. Probes captured the intermediate-to-settled bonsplit transition (407pt divider jump in ~243ms) and the existence of parked terminal entries.
