import AppKit
import SwiftUI

final class PanelManifestViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [UUID: PanelManifestViewerWindowController] = [:]

    private let surfaceId: UUID

    private init(workspaceId: UUID, surfaceId: UUID, kind: PanelManifestKind) {
        self.surfaceId = surfaceId
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "surfaceManifest.windowTitle", defaultValue: "Panel Details")
        panel.titleVisibility = .visible
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("c11.surfaceManifestViewer.\(surfaceId.uuidString)")
        panel.center()
        let handle = TerminalController.shared.surfaceHandleInfo(workspaceId: workspaceId, surfaceId: surfaceId)
        panel.contentView = NSHostingView(
            rootView: PanelManifestView(workspaceId: workspaceId, surfaceId: surfaceId, kind: kind, handle: handle)
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
    class func show(workspaceId: UUID, surfaceId: UUID, kind: PanelManifestKind) {
        if let existing = openControllers[surfaceId] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PanelManifestViewerWindowController(
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

/// A small, non-activating transient HUD used to confirm a clipboard copy
/// (e.g. "Copied surface:75") triggered from a context menu, where the menu
/// closes before any inline feedback could show. Appears near the pointer and
/// auto-dismisses. Does not steal focus.
@MainActor
final class CopyConfirmationHUD {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    enum Style {
        /// A copy confirmation: small, under a second.
        case confirmation
        /// C11H-349: an operator jump that could not land or opened elsewhere:
        /// larger, with a warning mark, for a few seconds.
        case notice

        var duration: TimeInterval { self == .confirmation ? 0.9 : 3.5 }
    }

    /// - Parameter anchor: where to show it, in AppKit global points; nil is
    ///   just above the pointer.
    static func show(message: String, style: Style = .confirmation, anchor: NSPoint? = nil) {
        let hud = panel ?? makePanel()
        panel = hud

        let host = NSHostingView(rootView: CopyConfirmationHUDView(message: message, style: style))
        hud.contentView = host
        hud.layoutIfNeeded()
        var size = host.fittingSize
        size.width = max(size.width, 96)
        size.height = max(size.height, 36)

        // Position just above the anchor (the pointer), clamped to its screen.
        let mouse = anchor ?? NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        hud.setFrame(NSRect(origin: origin, size: size), display: true)
        hud.alphaValue = 1
        hud.orderFrontRegardless()

        dismissWork?.cancel()
        let work = DispatchWorkItem { Self.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + style.duration, execute: work)
    }

    private static func dismiss() {
        guard let hud = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            hud.animator().alphaValue = 0
        }, completionHandler: {
            hud.orderOut(nil)
        })
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }
}

private struct CopyConfirmationHUDView: View {
    let message: String
    var style: CopyConfirmationHUD.Style = .confirmation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style == .notice ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.09))
            Text(message)
                .font(.system(size: style == .notice ? 15 : 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .accessibilityIdentifier("c11.hud.message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .fixedSize()
    }
}
