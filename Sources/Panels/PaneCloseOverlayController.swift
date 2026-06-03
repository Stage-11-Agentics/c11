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
final class PaneCloseOverlayController {
    let runtime: PaneInteractionRuntime
    private var anchors: [UUID: AnchorRecord] = [:]
    private var hosts: [UUID: PaneInteractionOverlayHost] = [:]
    private var activeIds: Set<UUID> = []
    private var subscription: AnyCancellable?
    // Weak registry of every live AnchorView so the controller can ask
    // them to re-query their window-coord frames after a sibling-close
    // reflow has settled. Required because reportFrame is called by
    // SwiftUI (updateNSView) and AppKit (viewDidMoveToWindow) DURING
    // the reflow, when convert(bounds, to: nil) can return transient
    // half-applied coordinates that the system never corrects.
    private let liveAnchorViews = NSHashTable<PaneInteractionOverlayHostView.AnchorView>.weakObjects()

    private struct AnchorRecord {
        var frameInWindow: NSRect
        weak var window: NSWindow?
    }

    init(runtime: PaneInteractionRuntime) {
        self.runtime = runtime
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
    func registerAnchorView(_ view: PaneInteractionOverlayHostView.AnchorView) {
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
            guard let anchor = anchors[id],
                  let window = anchor.window,
                  let themeFrame = window.contentView?.superview
            else {
#if DEBUG
                let reason: String
                if anchors[id] == nil { reason = "no_anchor" }
                else if anchors[id]?.window == nil { reason = "anchor_window_nil" }
                else { reason = "no_themeFrame" }
                dlog("paneClose.sync skip pane=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
                continue
            }

            let host: PaneInteractionOverlayHost
            if let existing = hosts[id] {
                host = existing
            } else {
                host = PaneInteractionOverlayHost(panelId: id, runtime: runtime)
                hosts[id] = host
            }

            // themeFrame and the window share the same coordinate system (themeFrame
            // is the window's outermost view at origin (0,0), full window size).
            // `convert(_:to: nil)` from any descendant gives window-coords directly.
            host.frame = anchor.frameInWindow

            // Re-add as the topmost subview so we sit above the portal hostView,
            // the file-drop overlay, and any SwiftUI hosting view.
            themeFrame.addSubview(host, positioned: .above, relativeTo: nil)
        }
    }
}
