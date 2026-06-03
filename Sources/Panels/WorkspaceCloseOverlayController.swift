import AppKit
import Combine
import Foundation

/// Owns the AppKit overlay layer that renders the workspace-close
/// confirmation card.
///
/// Shape mirrors `PaneCloseOverlayController` but at workspace scope: a
/// single anchor (the workspace's content area, excluding the sidebar)
/// and a single host. The controller mounts `WorkspaceCloseOverlayHost`
/// directly into the window's themeFrame so it sits above the
/// `WindowTerminalPortal` host view, browser portal, and any SwiftUI
/// content. Anchor frames are pushed in from
/// `WorkspaceCloseOverlayHostView`, which is rendered inside the
/// `WorkspaceContentView` body so its window-coord rect excludes the
/// sidebar by construction.
@MainActor
final class WorkspaceCloseOverlayController {
    let runtime: WorkspaceCloseInteractionRuntime
    private var anchor: AnchorRecord?
    private var host: WorkspaceCloseOverlayHost?
    private var hasActive: Bool = false
    private var subscription: AnyCancellable?

    private struct AnchorRecord {
        var frameInWindow: NSRect
        weak var window: NSWindow?
    }

    init(runtime: WorkspaceCloseInteractionRuntime) {
        self.runtime = runtime
        subscription = runtime.$active
            .receive(on: RunLoop.main)
            .sink { [weak self] content in
                self?.hasActive = (content != nil)
                self?.synchronize()
            }
        hasActive = (runtime.active != nil)
    }

    func updateAnchor(frameInWindow: NSRect, window: NSWindow) {
        anchor = AnchorRecord(frameInWindow: frameInWindow, window: window)
        synchronize()
    }

    func removeAnchor() {
        anchor = nil
        if let host {
            host.removeFromSuperview()
        }
        host = nil
    }

    func cleanup() {
        host?.removeFromSuperview()
        host = nil
        anchor = nil
        hasActive = false
    }

    private func synchronize() {
        if !hasActive {
            host?.removeFromSuperview()
            host = nil
            return
        }

        guard let anchor,
              let window = anchor.window,
              let themeFrame = window.contentView?.superview
        else { return }

        let host: WorkspaceCloseOverlayHost
        if let existing = self.host {
            host = existing
        } else {
            host = WorkspaceCloseOverlayHost(runtime: runtime)
            self.host = host
        }

        host.frame = anchor.frameInWindow

        // Re-add as the topmost subview so we sit above the portal hostView
        // and any SwiftUI hosting view.
        themeFrame.addSubview(host, positioned: .above, relativeTo: nil)
    }
}
