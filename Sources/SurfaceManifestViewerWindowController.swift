import AppKit
import SwiftUI

final class SurfaceManifestViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [UUID: SurfaceManifestViewerWindowController] = [:]

    private let surfaceId: UUID

    private init(workspaceId: UUID, surfaceId: UUID, kind: SurfaceManifestKind) {
        self.surfaceId = surfaceId
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "surfaceManifest.windowTitle", defaultValue: "Surface manifest")
        panel.titleVisibility = .visible
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("c11.surfaceManifestViewer.\(surfaceId.uuidString)")
        panel.center()
        panel.contentView = NSHostingView(
            rootView: SurfaceManifestView(workspaceId: workspaceId, surfaceId: surfaceId, kind: kind)
        )
        AppDelegate.shared?.applyWindowDecorations(to: panel)
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    class func show(workspaceId: UUID, surfaceId: UUID, kind: SurfaceManifestKind) {
        if let existing = openControllers[surfaceId] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SurfaceManifestViewerWindowController(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            kind: kind
        )
        openControllers[surfaceId] = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeValue(forKey: surfaceId)
    }
}
