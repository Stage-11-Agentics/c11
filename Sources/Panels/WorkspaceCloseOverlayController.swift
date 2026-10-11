import AppKit
import Combine
import Foundation

/// Where a close card may mount when its own anchor cannot be drawn.
/// `.onScreen` is the window that owns the workspace or panel. A hidden,
/// miniaturized, or missing window is not a place to mount: the confirm is
/// released instead of landing on whichever window happens to be key.
enum CloseOverlayOwner: Equatable {
    case onScreen(NSWindow)
    case notOnScreen
    case missing

    static func == (lhs: CloseOverlayOwner, rhs: CloseOverlayOwner) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing), (.notOnScreen, .notOnScreen):
            return true
        case (.onScreen(let left), .onScreen(let right)):
            return left === right
        default:
            return false
        }
    }
}

/// Owning-window content rect, in window coordinates, for a close card that
/// has no usable anchor. Shared by the workspace and area overlay controllers.
@MainActor
enum CloseOverlayFallback {
    static func themePlacement(in window: NSWindow) -> (frame: NSRect, theme: NSView)? {
        guard let content = window.contentView,
              let theme = content.superview,
              content.bounds.width >= 1,
              content.bounds.height >= 1 else { return nil }
        if let contentFrame = workspaceContentFrame(in: content) {
            return (contentFrame, theme)
        }
        return (content.convert(content.bounds, to: nil), theme)
    }

    /// On-screen owner with no drawable content rect. Hidden, minimized, and
    /// missing windows stay `owner_window_not_visible`.
    static func unmountedOwnerReason(owner: CloseOverlayOwner, hasUsableContent: Bool) -> String {
        if case .onScreen = owner, !hasUsableContent {
            return "no_content_rect"
        }
        return "owner_window_not_visible"
    }

    /// The workspace content anchor excludes the sidebar. A fallback that
    /// ignores it covers the sidebar with the scrim.
    private static func workspaceContentFrame(in view: NSView) -> NSRect? {
        if let anchor = view as? WorkspaceCloseOverlayHostView.AnchorView,
           anchor.bounds.width >= 1,
           anchor.bounds.height >= 1,
           anchor.window != nil,
           !anchor.isHiddenOrHasHiddenAncestor {
            return anchor.convert(anchor.bounds, to: nil)
        }
        for subview in view.subviews {
            if let frame = workspaceContentFrame(in: subview) {
                return frame
            }
        }
        return nil
    }

    static func ownerState(of window: NSWindow?) -> CloseOverlayOwner {
        guard let window else { return .missing }
        guard window.isVisible, !window.isMiniaturized, window.screen != nil else {
            return .notOnScreen
        }
        return .onScreen(window)
    }

    /// A card inside a hidden tab is not on screen. `isHidden` on the host
    /// itself stays false when an ancestor scroll view is hidden.
    static func cardIsOnScreen(_ view: NSView, active: Bool) -> Bool {
        active
            && view.window?.isVisible == true
            && !view.isHiddenOrHasHiddenAncestor
            && view.bounds.width >= 1
            && view.bounds.height >= 1
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
    /// Tests inject an owner. Production resolves the workspace's window.
    /// The default refuses to mount, so an unwired controller cannot fall
    /// through to `NSApp.keyWindow`.
    var ownerWindow: @MainActor () -> CloseOverlayOwner = { .missing }

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
        let owner = ownerWindow()
        if case .onScreen(let window) = owner,
           let placement = CloseOverlayFallback.themePlacement(in: window) {
            CloseLog.fallback(scope: "workspace", workspace: workspaceId)
            mount(frame: placement.frame, theme: placement.theme)
            return
        }

        host?.removeFromSuperview()
        host = nil
        CloseLog.overlayUnmounted(
            scope: "workspace",
            workspace: workspaceId,
            reason: CloseOverlayFallback.unmountedOwnerReason(owner: owner, hasUsableContent: false)
        )
        runtime.releaseUnmounted()
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
