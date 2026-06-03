import AppKit
import Bonsplit
import SwiftUI

/// SwiftUI anchor that reports a pane's bounds (in window coordinates) to a
/// workspace-level overlay controller.
///
/// We can't render the pane-close confirmation as a SwiftUI overlay because
/// portal-hosted terminal/browser content is reparented into an AppKit layer
/// that sits above the workspace's SwiftUI tree (see `WindowTerminalPortal`).
/// Anything we draw inside the pane in SwiftUI ends up behind the terminal.
///
/// Instead, this view stays invisible and just publishes its window-coord
/// frame; `PaneCloseOverlayController` mounts an AppKit overlay (the existing
/// `PaneInteractionOverlayHost`) at the matching frame in the window's
/// themeFrame, which is above the portal layer.
struct PaneInteractionOverlayHostView: View {
    let paneId: PaneID
    let controller: PaneCloseOverlayController

    var body: some View {
        AnchorRepresentable(
            paneIdentity: paneId.id,
            controller: controller
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct AnchorRepresentable: NSViewRepresentable {
        let paneIdentity: UUID
        let controller: PaneCloseOverlayController

        func makeNSView(context: Context) -> AnchorView {
            let v = AnchorView()
            v.paneIdentity = paneIdentity
            v.controller = controller
            return v
        }

        func updateNSView(_ nsView: AnchorView, context: Context) {
            nsView.paneIdentity = paneIdentity
            nsView.controller = controller
            nsView.reportFrame()
        }

        static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
            // Intentionally NOT calling removeAnchor here. SwiftUI dismantles
            // AnchorViews during transient layout reconfigurations (e.g. the
            // sibling subtree replacement that follows closing a neighbor
            // pane), and the replacement AnchorView for the SAME paneId
            // doesn't always re-reportFrame promptly afterward. Removing the
            // anchor on every dismantle therefore orphans surviving panes
            // until the user forces a resize. Authoritative cleanup lives in
            // Workspace.splitTabBar(_:didClosePane:), which fires once per
            // truly-removed pane. weak anchor.window also covers the case
            // where the host NSWindow deallocates underneath us.
        }
    }

    final class AnchorView: NSView {
        var paneIdentity: UUID?
        weak var controller: PaneCloseOverlayController?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        override var frame: NSRect {
            didSet { reportFrame() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                // Register so the controller can ask us to re-poll our
                // window-coord frame after a sibling-pane close reflow.
                // The hash table is weak — no explicit unregister needed.
                controller?.registerAnchorView(self)
            }
            reportFrame()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            reportFrame()
        }

        func reportFrame() {
            guard let id = paneIdentity, let controller else { return }
            guard let window else {
                // Transient detachment during SwiftUI split-tree reparenting
                // can flip our window to nil for a single layout pass while
                // the AppKit view is being moved between superviews. The
                // re-attachment fires viewDidMoveToWindow / updateNSView and
                // we'll reportFrame again with a valid window. Removing the
                // anchor on every nil-window blip leaves surviving panes
                // orphaned because subsequent layout passes can settle
                // without touching this AnchorView. Authoritative cleanup
                // happens in Workspace.splitTabBar(_:didClosePane:);
                // weak anchor.window naturally goes nil when the host
                // NSWindow deallocates.
                return
            }
            let frameInWindow = convert(bounds, to: nil)
            controller.updateAnchor(
                paneIdentity: id,
                frameInWindow: frameInWindow,
                window: window
            )
        }
    }
}
