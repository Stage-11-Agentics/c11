import AppKit
import Bonsplit
import Combine
import Foundation

/// Owns the AppKit overlay layer that renders the pane-close confirmation card.
/// One instance per workspace. The controller mounts `PaneInteractionOverlayHost`
/// instances directly into the window's themeFrame so they sit above the
/// `WindowTerminalPortal` host view (and above all SwiftUI content). Anchor
/// frames are pushed in from `PaneInteractionOverlayHostView`, which is
/// rendered inside each Bonsplit pane via the pane-overlay environment value.
@MainActor
final class AreaCloseOverlayController {
    let runtime: AreaInteractionRuntime
    private var anchors: [UUID: AnchorRecord] = [:]
    private var hosts: [UUID: AreaInteractionOverlayHost] = [:]
    private var activeIds: Set<UUID> = []
    private var subscription: AnyCancellable?
    // Weak registry of every live AnchorView so the controller can ask
    // them to re-query their window-coord frames after a sibling-close
    // reflow has settled. Required because reportFrame is called by
    // SwiftUI (updateNSView) and AppKit (viewDidMoveToWindow) DURING
    // the reflow, when convert(bounds, to: nil) can return transient
    // half-applied coordinates that the system never corrects.
    private let liveAnchorViews = NSHashTable<AreaInteractionOverlayHostView.AnchorView>.weakObjects()
    let workspaceId: UUID
    /// Tests inject a window. Production uses the key window.
    var fallbackWindowProvider: @MainActor () -> NSWindow? = { NSApp.keyWindow }

    private struct AnchorRecord {
        var frameInWindow: NSRect
        weak var window: NSWindow?
    }

    init(runtime: AreaInteractionRuntime, workspaceId: UUID) {
        self.runtime = runtime
        self.workspaceId = workspaceId
        subscription = runtime.$active
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.activeIds = Set(active.keys)
                self?.synchronize()
            }
        activeIds = Set(runtime.active.keys)
    }

    func updateAnchor(paneIdentity: UUID, frameInWindow: NSRect, window: NSWindow) {
        anchors[paneIdentity] = AnchorRecord(frameInWindow: frameInWindow, window: window)
        synchronize()
    }

    func removeAnchor(paneIdentity: UUID) {
        anchors.removeValue(forKey: paneIdentity)
        if let host = hosts.removeValue(forKey: paneIdentity) {
            host.removeFromSuperview()
        }
    }

    func cleanup() {
        for host in hosts.values {
            host.removeFromSuperview()
        }
        hosts.removeAll()
        anchors.removeAll()
        activeIds.removeAll()
    }

    /// Called by AnchorView the first time it gains a window. The hash table is
    /// weak, so dead entries auto-prune when SwiftUI deallocates the view —
    /// no explicit unregister needed.
    func registerAnchorView(_ view: AreaInteractionOverlayHostView.AnchorView) {
        liveAnchorViews.add(view)
    }

    /// After Bonsplit fires its authoritative didClosePane, ask every live
    /// AnchorView to re-publish its window-coord frame. We schedule the walk
    /// on `main.async` (next runloop tick) and again at +60ms because the
    /// SwiftUI/Bonsplit reflow can take more than one layout pass to settle —
    /// the in-flight reportFrame calls fire mid-reflow with transient values
    /// (we've logged `convert(bounds, to: nil)` returning a 923-wide frame
    /// for a 461-wide pane) and no post-settle event corrects them. Without
    /// this re-query the controller's anchors map stays stale and the
    /// confirmation overlay mounts at the wrong pane position.
    func refreshAllAnchorsAfterReflow() {
        let refresh: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            for view in self.liveAnchorViews.allObjects {
                view.reportFrame()
            }
        }
        DispatchQueue.main.async(execute: refresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: refresh)
    }

    private func synchronize() {
        // Drop hosts for panes that are no longer active.
        for (id, host) in hosts where !activeIds.contains(id) {
            host.removeFromSuperview()
            hosts.removeValue(forKey: id)
        }

        for id in activeIds {
            if let placement = usablePlacement(for: id) {
                mount(id: id, frame: placement.frame, theme: placement.theme)
                continue
            }

            let reason = unmountReason(for: id)
            CloseLog.overlayUnmounted(scope: "area", workspace: workspaceId, reason: reason)
#if DEBUG
            dlog("paneClose.sync skip pane=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            if let window = fallbackWindowProvider(),
               let placement = CloseOverlayFallback.themePlacement(in: window) {
                CloseLog.fallback(scope: "area", workspace: workspaceId)
                mount(id: id, frame: placement.frame, theme: placement.theme)
                continue
            }

            if let host = hosts.removeValue(forKey: id) {
                host.removeFromSuperview()
            }
            // Leave the interaction active so a close that outlives the window
            // can still resolve. Mark it unmounted so the next present is not
            // swallowed by the dedupe token, and Return does not accept it.
            runtime.noteConfirmVisible(panelId: id, visible: false)
        }
    }

    private func usablePlacement(for id: UUID) -> (frame: NSRect, theme: NSView)? {
        guard let anchor = anchors[id],
              let window = anchor.window,
              let theme = window.contentView?.superview,
              anchor.frameInWindow.width >= 1,
              anchor.frameInWindow.height >= 1 else { return nil }
        return (anchor.frameInWindow, theme)
    }

    /// A zero frame draws nothing, so it is logged as `no_anchor`.
    private func unmountReason(for id: UUID) -> String {
        guard let anchor = anchors[id] else { return "no_anchor" }
        if anchor.window == nil { return "anchor_window_nil" }
        if anchor.frameInWindow.width < 1 || anchor.frameInWindow.height < 1 { return "no_anchor" }
        return "no_themeFrame"
    }

    private func mount(id: UUID, frame: NSRect, theme: NSView) {
        let host: AreaInteractionOverlayHost
        if let existing = hosts[id] {
            host = existing
        } else {
            host = AreaInteractionOverlayHost(panelId: id, runtime: runtime)
            hosts[id] = host
        }
        // themeFrame and the window share the same coordinate system (themeFrame
        // is the window's outermost view at origin (0,0), full window size).
        // `convert(_:to: nil)` from any descendant gives window-coords directly.
        host.frame = frame
        theme.addSubview(host, positioned: .above, relativeTo: nil)
    }
}
