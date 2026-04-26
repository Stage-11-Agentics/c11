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
            if let id = nsView.paneIdentity {
                nsView.controller?.removeAnchor(paneIdentity: id)
            }
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
            reportFrame()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            reportFrame()
        }

        func reportFrame() {
            guard let id = paneIdentity, let controller else { return }
            guard let window else {
                controller.removeAnchor(paneIdentity: id)
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
