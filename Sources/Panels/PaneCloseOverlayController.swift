import AppKit
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
            else { continue }

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
