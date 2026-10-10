import AppKit
import Combine
import Foundation

/// Key-window content rect, in window coordinates, for a close card that has
/// no usable anchor. Shared by the workspace and area overlay controllers.
@MainActor
enum CloseOverlayFallback {
    static func themePlacement(in window: NSWindow) -> (frame: NSRect, theme: NSView)? {
        guard let content = window.contentView,
              let theme = content.superview,
              content.bounds.width >= 1,
              content.bounds.height >= 1 else { return nil }
        return (content.convert(content.bounds, to: nil), theme)
    }
}

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
    let workspaceId: UUID
    private var anchor: AnchorRecord?
    private var host: WorkspaceCloseOverlayHost?
    private var hasActive: Bool = false
    private var subscription: AnyCancellable?
    /// Tests inject a window. Production uses the key window.
    var fallbackWindowProvider: @MainActor () -> NSWindow? = { NSApp.keyWindow }

    private struct AnchorRecord {
        var frameInWindow: NSRect
        weak var window: NSWindow?
        weak var owner: WorkspaceCloseOverlayHostView.AnchorView?
    }

    init(runtime: WorkspaceCloseInteractionRuntime, workspaceId: UUID) {
        self.runtime = runtime
        self.workspaceId = workspaceId
        subscription = runtime.$active
            .receive(on: RunLoop.main)
            .sink { [weak self] content in
                self?.hasActive = (content != nil)
                self?.synchronize()
            }
        hasActive = (runtime.active != nil)
    }

    func updateAnchor(
        frameInWindow: NSRect,
        window: NSWindow,
        owner: WorkspaceCloseOverlayHostView.AnchorView
    ) {
        anchor = AnchorRecord(frameInWindow: frameInWindow, window: window, owner: owner)
        synchronize()
    }

    /// Only the view that registered the current anchor may clear it. A
    /// dismantled predecessor that runs after the replacement registered
    /// must not drop the new frame.
    func removeAnchor(owner: WorkspaceCloseOverlayHostView.AnchorView) {
        guard anchor?.owner === owner else { return }
        anchor = nil
        synchronize()
    }

    var debugAnchorOwner: ObjectIdentifier? {
        anchor?.owner.map { ObjectIdentifier($0) }
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
            runtime.noteConfirmVisible(false)
            return
        }

        if let placement = usableAnchorPlacement() {
            mount(frame: placement.frame, theme: placement.theme)
            return
        }

        let reason = unmountReason()
        CloseLog.overlayUnmounted(scope: "workspace", workspace: workspaceId, reason: reason)
        if let window = fallbackWindowProvider(),
           let placement = CloseOverlayFallback.themePlacement(in: window) {
            CloseLog.fallback(scope: "workspace", workspace: workspaceId)
            mount(frame: placement.frame, theme: placement.theme)
            return
        }

        host?.removeFromSuperview()
        host = nil
        runtime.noteConfirmVisible(false)
    }

    private func usableAnchorPlacement() -> (frame: NSRect, theme: NSView)? {
        guard let anchor,
              let window = anchor.window,
              let theme = window.contentView?.superview,
              anchor.frameInWindow.width >= 1,
              anchor.frameInWindow.height >= 1 else { return nil }
        return (anchor.frameInWindow, theme)
    }

    /// A zero frame draws nothing, so it is logged as `no_anchor`.
    private func unmountReason() -> String {
        guard let anchor else { return "no_anchor" }
        if anchor.window == nil { return "anchor_window_nil" }
        if anchor.frameInWindow.width < 1 || anchor.frameInWindow.height < 1 { return "no_anchor" }
        return "no_themeFrame"
    }

    private func mount(frame: NSRect, theme: NSView) {
        let host: WorkspaceCloseOverlayHost
        if let existing = self.host {
            host = existing
        } else {
            host = WorkspaceCloseOverlayHost(runtime: runtime)
            self.host = host
        }

        host.frame = frame
        theme.addSubview(host, positioned: .above, relativeTo: nil)
    }
}
