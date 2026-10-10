import AppKit
import SwiftUI

/// SwiftUI anchor that reports the workspace content area's bounds (in window
/// coordinates) to the workspace-scoped close-overlay controller.
///
/// Mirrors `PaneInteractionOverlayHostView` but at workspace scope. Mounted
/// inside `WorkspaceContentView` so its window-coord rect excludes the
/// sidebar by construction — the overlay scrim covers exactly the workspace
/// content area, leaving the sidebar visible and interactive.
///
/// We can't render the close-confirmation as a SwiftUI overlay because
/// portal-hosted terminal/browser content is reparented into AppKit layers
/// that sit above the workspace's SwiftUI tree (see CLAUDE.md "Terminal find
/// layering contract"). This view stays invisible and just publishes its
/// frame; `WorkspaceCloseOverlayController` mounts the AppKit overlay at
/// the matching frame in themeFrame.
struct WorkspaceCloseOverlayHostView: View {
    let controller: WorkspaceCloseOverlayController

    var body: some View {
        AnchorRepresentable(controller: controller)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct AnchorRepresentable: NSViewRepresentable {
        let controller: WorkspaceCloseOverlayController

        func makeNSView(context: Context) -> AnchorView {
            let v = AnchorView()
            v.controller = controller
            return v
        }

        func updateNSView(_ nsView: AnchorView, context: Context) {
            nsView.controller = controller
            nsView.reportFrame()
        }

        static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
            // A zoom identity change rebuilds this anchor. The old view's
            // dismantle can run after the new view has registered. Only the
            // current owner may clear the anchor.
            nsView.controller?.removeAnchor(owner: nsView)
        }
    }

    final class AnchorView: NSView {
        weak var controller: WorkspaceCloseOverlayController?

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
            guard let controller else { return }
            // A nil window during SwiftUI reparenting is transient. Removing
            // the anchor here orphans the card; the next report fills it in.
            // C11-40 dropped the same removal on the area anchor.
            guard let window else { return }
            let frameInWindow = convert(bounds, to: nil)
            controller.updateAnchor(frameInWindow: frameInWindow, window: window, owner: self)
        }
    }
}
