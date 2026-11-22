import AppKit
import Bonsplit
import Combine
import ImageIO
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit
import os

private var initialMainWindowGeometryReconcileKey: UInt8 = 0

/// `NSViewControllerRepresentable` that hosts SwiftUI content and toggles
/// `isHidden` on the hosting view based on a Bool. When `isHidden = true`,
/// AppKit's `_layoutSubtreeWithOldSize:` walk short-circuits the entire
/// subtree, eliminating the layout cost of off-screen workspaces during
/// workspace switches.
///
/// Phase 1 of the workspace-switch perf fix. The SwiftUI subtree is preserved
/// (surfaces don't dismount/remount) — only the AppKit visibility flag toggles.
/// `.opacity()` alone does not skip layout; AppKit recurses into transparent
/// views just like opaque ones, so `.opacity(0)` workspaces still pay full
/// Auto Layout cost on every switch.
///
/// SwiftUI environment propagates through `NSHostingController`, so
/// `@EnvironmentObject` / `@Environment` reads in the hosted content continue
/// to resolve from the parent view's environment.
private struct AppKitHiddenWrapper<Content: View>: NSViewControllerRepresentable {
    let isHidden: Bool
    let content: Content

    init(isHidden: Bool, @ViewBuilder content: () -> Content) {
        self.isHidden = isHidden
        self.content = content()
    }

    func makeNSViewController(context: Context) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: content)
        host.view.isHidden = isHidden
        return host
    }

    func updateNSViewController(_ host: NSHostingController<Content>, context: Context) {
        if host.view.isHidden != isHidden {
            host.view.isHidden = isHidden
        }
        GraphChurnMeter.note(.hiddenWrapperUpdate)
        host.rootView = content
    }
}

private extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

private func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = NSApp?.effectiveAppearance
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let baseColor: NSColor = (bestMatch == .darkAqua) ? .white : .black
    return baseColor.withAlphaComponent(clampedOpacity)
}

// c11 brand accent. Stage 11 is void-dominant; accent is a single gold
// regardless of appearance. See `BrandColors`.
func cmuxAccentNSColor(for colorScheme: ColorScheme) -> NSColor {
    _ = colorScheme
    return BrandColors.gold
}

func cmuxAccentNSColor(for appAppearance: NSAppearance?) -> NSColor {
    _ = appAppearance
    return BrandColors.gold
}

func cmuxAccentNSColor() -> NSColor {
    BrandColors.gold
}

func cmuxAccentColor() -> Color {
    BrandColors.goldSwiftUI
}

struct SidebarRemoteErrorCopyEntry: Equatable {
    let workspaceTitle: String
    let target: String
    let detail: String
}

enum SidebarRemoteErrorCopySupport {
    static func menuLabel(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 {
            return String(localized: "contextMenu.copyError", defaultValue: "Copy Error")
        }
        return String(localized: "contextMenu.copyErrors", defaultValue: "Copy Errors")
    }

    static func clipboardText(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.single", defaultValue: "SSH error (%@): %@"),
                entry.target,
                entry.detail
            )
        }

        return entries.enumerated().map { index, entry in
            String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.item", defaultValue: "%lld. %@ (%@): %@"),
                Int64(index + 1),
                entry.workspaceTitle,
                entry.target,
                entry.detail
            )
        }.joined(separator: "\n")
    }
}

func sidebarSelectedWorkspaceBackgroundNSColor(for colorScheme: ColorScheme) -> NSColor {
    _ = colorScheme
    return BrandColors.black
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return BrandColors.white.withAlphaComponent(clampedOpacity)
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum InternalPanelDragConfigurationProvider {
    // These drags only make sense inside cmux. Outside the app, Finder should
    // reject them instead of materializing placeholder files from the payload.
    static let value = DragConfiguration(
        operationsWithinApp: .init(allowCopy: false, allowMove: true, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: false, allowMove: false, allowDelete: false)
    )
}
#endif

private struct InternalPanelDragConfigurationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.dragConfiguration(InternalPanelDragConfigurationProvider.value)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func internalOnlyPanelDrag() -> some View {
        modifier(InternalPanelDragConfigurationModifier())
    }
}

struct ShortcutHintPillBackground: View {
    var emphasis: Double = 1.0

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.30 * emphasis), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.22 * emphasis), radius: 2, x: 0, y: 1)
    }
}

/// Applies NSGlassEffectView (macOS 26+) to a window, falling back to NSVisualEffectView
enum WindowGlassEffect {
    private static var glassViewKey: UInt8 = 0
    private static var tintOverlayKey: UInt8 = 0

    static var isAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    static func apply(to window: NSWindow, tintColor: NSColor? = nil) {
        guard let originalContentView = window.contentView else { return }

        // Check if we already applied glass (avoid re-wrapping)
        if let existingGlass = objc_getAssociatedObject(window, &glassViewKey) as? NSView {
            // Already applied, just update the tint
            updateTint(on: existingGlass, color: tintColor, window: window)
            return
        }

        let bounds = originalContentView.bounds

        // Create the glass/blur view
        let glassView: NSVisualEffectView
        let usingGlassEffectView: Bool

        // Try NSGlassEffectView first (macOS 26 Tahoe+)
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSVisualEffectView.Type {
            usingGlassEffectView = true
            glassView = glassClass.init(frame: bounds)
            glassView.wantsLayer = true
            glassView.layer?.cornerRadius = 0

            // Apply tint color via private API
            if let color = tintColor {
                let selector = NSSelectorFromString("setTintColor:")
                if glassView.responds(to: selector) {
                    glassView.perform(selector, with: color)
                }
            }
        } else {
            usingGlassEffectView = false
            // Fallback to NSVisualEffectView
            glassView = NSVisualEffectView(frame: bounds)
            glassView.blendingMode = .behindWindow
            // Favor a lighter fallback so behind-window glass reads more transparent.
            glassView.material = .underWindowBackground
            glassView.state = .active
            glassView.wantsLayer = true
        }

        glassView.autoresizingMask = [.width, .height]

        if usingGlassEffectView {
            // NSGlassEffectView is a full replacement for the contentView.
            window.contentView = glassView

            // Re-add the original SwiftUI hosting view on top of the glass, filling entire area.
            originalContentView.translatesAutoresizingMaskIntoConstraints = false
            originalContentView.wantsLayer = true
            originalContentView.layer?.backgroundColor = NSColor.clear.cgColor
            glassView.addSubview(originalContentView)

            NSLayoutConstraint.activate([
                originalContentView.topAnchor.constraint(equalTo: glassView.topAnchor),
                originalContentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
                originalContentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                originalContentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
            ])
        } else {
            // For NSVisualEffectView fallback (macOS 13-15), do NOT replace window.contentView.
            // Replacing contentView can break traffic light rendering with
            // `.fullSizeContentView` + `titlebarAppearsTransparent`.
            glassView.translatesAutoresizingMaskIntoConstraints = false
            originalContentView.addSubview(glassView, positioned: .below, relativeTo: nil)

            NSLayoutConstraint.activate([
                glassView.topAnchor.constraint(equalTo: originalContentView.topAnchor),
                glassView.bottomAnchor.constraint(equalTo: originalContentView.bottomAnchor),
                glassView.leadingAnchor.constraint(equalTo: originalContentView.leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: originalContentView.trailingAnchor)
            ])
        }

        // Add tint overlay between glass and content (for fallback)
        if let tintColor, !usingGlassEffectView {
            let tintOverlay = NSView(frame: bounds)
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = tintColor.cgColor
            glassView.addSubview(tintOverlay)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: glassView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: glassView.trailingAnchor)
            ])
            objc_setAssociatedObject(window, &tintOverlayKey, tintOverlay, .OBJC_ASSOCIATION_RETAIN)
        }

        // Store reference
        objc_setAssociatedObject(window, &glassViewKey, glassView, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Update the tint color on an existing glass effect
    static func updateTint(to window: NSWindow, color: NSColor?) {
        guard let glassView = objc_getAssociatedObject(window, &glassViewKey) as? NSView else { return }
        updateTint(on: glassView, color: color, window: window)
    }

    private static func updateTint(on glassView: NSView, color: NSColor?, window: NSWindow) {
        // For NSGlassEffectView, use setTintColor:
        if glassView.className == "NSGlassEffectView" {
            let selector = NSSelectorFromString("setTintColor:")
            if glassView.responds(to: selector) {
                glassView.perform(selector, with: color)
            }
        } else {
            // For NSVisualEffectView fallback, update the tint overlay
            if let tintOverlay = objc_getAssociatedObject(window, &tintOverlayKey) as? NSView {
                tintOverlay.layer?.backgroundColor = color?.cgColor
            }
        }
    }

    static func remove(from window: NSWindow) {
        // Note: Removing would require restoring original contentView structure
        // For now, just clear the reference
        objc_setAssociatedObject(window, &glassViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, &tintOverlayKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// CALayer-backed titlebar background. Uses layer-level opacity (not per-pixel alpha)
/// to match how the terminal's Metal surface composites its background.
struct TitlebarLayerBackground: NSViewRepresentable {
    var backgroundColor: NSColor
    var opacity: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        view.layer?.opacity = Float(opacity)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = backgroundColor.withAlphaComponent(1.0).cgColor
        nsView.layer?.opacity = Float(opacity)
    }
}

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat
    // Shared with this window's native accessory, whose controls may overhang the sidebar.
    @Published var customTitlebarForeground = Color.white.opacity(0.82)
    // Opaque fill behind the titlebar control group, derived from the titlebar background.
    @Published var titlebarControlsBackdrop = Color(white: 0.2)
    @Published var titlebarControlsBackdropIsLight = false
    /// What the sidebar draws now (C11H-221). Not published: the sidebar owns
    /// the decision and `sidebar-state` only reads it.
    var shownDensity: SidebarDensity = .cards

    init(isVisible: Bool = true, persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        isVisible.toggle()
    }

    /// Columns the sidebar shows now in a window this wide; 0 when hidden.
    func shownColumns(windowWidth: Double, scale: Double) -> Int {
        guard isVisible else { return 0 }
        return SidebarLayoutPolicy.shownColumns(requested: Double(persistedWidth),
                                                windowWidth: windowWidth, scale: scale)
    }

    /// Shows `count` columns, or the most below it the window fits; 0 hides.
    /// Returns the columns actually chosen.
    @discardableResult
    func show(columns count: Int, windowWidth: Double, scale: Double) -> Int {
        guard count > 0 else {
            isVisible = false
            return 0
        }
        for candidate in stride(from: min(count, SidebarLayoutPolicy.maximumColumnChoice), through: 1, by: -1) {
            guard let width = SidebarLayoutPolicy.requestedWidth(
                forColumns: candidate, current: Double(persistedWidth),
                windowWidth: windowWidth, scale: scale) else { continue }
            if abs(Double(persistedWidth) - width) > 0.5 {
                persistedWidth = CGFloat(width)
            }
            isVisible = true
            return candidate
        }
        isVisible = true
        return shownColumns(windowWidth: windowWidth, scale: scale)
    }

    /// The titlebar button: hidden → 1 → 2 → 3 columns → hidden.
    func cycleColumns(windowWidth: Double, scale: Double) {
        let next = SidebarLayoutPolicy.nextColumnChoice(
            after: shownColumns(windowWidth: windowWidth, scale: scale)
        ) { candidate in
            SidebarLayoutPolicy.requestedWidth(forColumns: candidate, current: Double(persistedWidth),
                                               windowWidth: windowWidth, scale: scale) != nil
        }
        show(columns: next, windowWidth: windowWidth, scale: scale)
    }
}

enum SidebarResizeInteraction {
    static let handleWidth: CGFloat = 6
    static let hitInset: CGFloat = 3

    static var hitWidthPerSide: CGFloat {
        hitInset + (handleWidth / 2)
    }
}

// MARK: - File Drop Overlay

enum DragOverlayRoutingPolicy {
    /// WebKit must not register text types that swallow sibling tab/drop overlays.
    static func webViewDragTypes(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        let blocked: Set<NSPasteboard.PasteboardType> = [
            .string, NSPasteboard.PasteboardType("public.text"), NSPasteboard.PasteboardType("public.plain-text"),
            bonsplitTabTransferType, sidebarWorkspaceReorderType
        ]
        return types.filter { !blocked.contains($0) }
    }

    /// Bonsplit's own id for a panel drag, read from Bonsplit so a c11
    /// rename can't drift from what Bonsplit writes.
    static let bonsplitTabTransferType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)
    static let sidebarWorkspaceReorderType = NSPasteboard.PasteboardType(SidebarWorkspaceDragPayload.typeIdentifier)

    static func hasBonsplitTabTransfer(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(bonsplitTabTransferType)
    }

    /// True while a panel drag is carrying the pointer. Hit tests call this on
    /// every event, keystrokes included, so the event type is checked first.
    /// The drag pasteboard keeps the last drag's types after it ends, so the
    /// held mouse button is what says a drag is live.
    @MainActor static func isPanelDragInFlight() -> Bool {
        switch NSApp.currentEvent?.type {
        case nil, .leftMouseDragged?, .rightMouseDragged?, .otherMouseDragged?,
             .mouseMoved?, .cursorUpdate?, .flagsChanged?, .periodic?:
            break
        default:
            return false
        }
        guard NSEvent.pressedMouseButtons != 0 else { return false }
        return hasBonsplitTabTransfer(NSPasteboard(name: .drag).types)
    }

    static func hasSidebarWorkspaceReorder(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(sidebarWorkspaceReorderType)
    }

    static func hasFileURL(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let pasteboardTypes else { return false }
        return pasteboardTypes.contains(.fileURL)
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hasLocalDraggingSource: Bool
    ) -> Bool {
        // Local file drags (e.g. in-app draggable folder views) are valid drop
        // inputs; rely on explicit non-file drag types below to avoid hijacking
        // Bonsplit/sidebar drags.
        _ = hasLocalDraggingSource
        guard hasFileURL(pasteboardTypes) else { return false }

        // Prefer explicit non-file drag types so stale fileURL entries cannot hijack
        // Bonsplit tab drags or sidebar tab reorder drags.
        if hasBonsplitTabTransfer(pasteboardTypes) { return false }
        if hasSidebarWorkspaceReorder(pasteboardTypes) { return false }
        return true
    }

    static func shouldCaptureFileDropDestination(
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureFileDropDestination(
            pasteboardTypes: pasteboardTypes,
            hasLocalDraggingSource: false
        )
    }

    static func shouldCaptureFileDropOverlay(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard shouldCaptureFileDropDestination(pasteboardTypes: pasteboardTypes) else { return false }
        guard isDragMouseEvent(eventType) else { return false }
        return true
    }

    static func shouldCaptureSidebarExternalOverlay(
        hasSidebarDragState: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        guard hasSidebarDragState else { return false }
        return hasSidebarWorkspaceReorder(pasteboardTypes)
    }

    static func shouldCaptureSidebarExternalOverlay(
        draggedWorkspaceId: UUID?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?
    ) -> Bool {
        shouldCaptureSidebarExternalOverlay(
            hasSidebarDragState: draggedWorkspaceId != nil,
            pasteboardTypes: pasteboardTypes
        )
    }

    static func shouldPassThroughPortalHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) -> Bool {
        guard isPortalDragEvent(eventType) else { return false }
        return hasBonsplitTabTransfer(pasteboardTypes) || hasSidebarWorkspaceReorder(pasteboardTypes)
    }

    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
    }

    private static func isPortalDragEvent(_ eventType: NSEvent.EventType?) -> Bool {
        // Restrict portal pass-through to explicit drag-motion events so stale
        // NSPasteboard(name: .drag) types cannot hijack normal pointer input.
        guard let eventType else { return false }
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}

/// Transparent NSView installed on the window's theme frame (above the NSHostingView) to
/// handle file/URL drags from Finder. Nested NSHostingController layers (created by bonsplit's
/// SinglePaneWrapper) prevent AppKit's NSDraggingDestination routing from reaching deeply
/// embedded terminal views. This overlay sits above the entire content view hierarchy and
/// intercepts file drags, forwarding drops to the GhosttyNSView under the cursor.
///
/// Mouse events are forwarded to the views below via a hide-send-unhide pattern so clicks,
/// scrolls, and other interactions pass through normally.
final class FileDropOverlayView: NSView {
    /// Fallback handler when no terminal is found under the drop point.
    var onDrop: (([URL]) -> Bool)?
    private var isForwardingMouseEvent = false
    private weak var forwardedMouseDragTarget: NSView?
    private var forwardedMouseDragButton: ForwardedMouseDragButton?
    /// The WKWebView currently receiving forwarded drag events, so we can
    /// synthesize draggingExited/draggingEntered as the cursor moves.
    private weak var activeDragWebView: WKWebView?
    /// [TextBox] InputTextView under the cursor during an active drag, if any.
    /// Set by `updateDragTarget` during `draggingUpdated` so `performDragOperation`
    /// can route the drop without re-hit-testing. Plan §4.9.
    private weak var activeDragTextBox: InputTextView?
    private var lastHitTestLogSignature: String?
    private var lastDragRouteLogSignatureByPhase: [String: String] = [:]

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private enum ForwardedMouseDragButton: Equatable {
        case left
        case right
        case other(Int)
    }

    private func dragButton(for event: NSEvent) -> ForwardedMouseDragButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return .other(Int(event.buttonNumber))
        default:
            return nil
        }
    }

    private func shouldTrackForwardedMouseDragStart(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private func shouldTrackForwardedMouseDragEnd(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    // MARK: Hit-testing — participation is routed by DragOverlayRoutingPolicy so
    // file-drop, bonsplit tab drags, and sidebar tab reorder drags cannot conflict.

    override func hitTest(_ point: NSPoint) -> NSView? {
        let pb = NSPasteboard(name: .drag)
        let eventType = NSApp.currentEvent?.type
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
            pasteboardTypes: pb.types,
            eventType: eventType
        )
#if DEBUG
        logHitTestDecision(
            pasteboardTypes: pb.types,
            eventType: eventType,
            shouldCapture: shouldCapture
        )
#endif
        guard shouldCapture else { return nil }

        return super.hitTest(point)
    }

    // MARK: Mouse forwarding — safety net for the rare case where stale drag pasteboard
    // data causes hitTest to return self when no drag is actually active.
    // We hit-test contentView directly and dispatch to the target rather than using
    // window.sendEvent(), which caches the mouse target and causes infinite recursion.

    private func forwardEvent(_ event: NSEvent) {
        guard !isForwardingMouseEvent else { return }
        guard let window, let contentView = window.contentView else { return }
        let eventButton = dragButton(for: event)

        isForwardingMouseEvent = true
        isHidden = true
        defer {
            isHidden = false
            isForwardingMouseEvent = false
        }

        let target: NSView?
        if let eventButton,
           forwardedMouseDragButton == eventButton,
           let activeTarget = forwardedMouseDragTarget,
           activeTarget.window != nil {
            // Preserve normal AppKit mouse-delivery semantics: once a drag starts,
            // keep routing dragged/up events to the original mouseDown target.
            target = activeTarget
        } else {
            let point = contentView.convert(event.locationInWindow, from: nil)
            target = contentView.hitTest(point)
        }

        guard let target, target !== self else {
            if shouldTrackForwardedMouseDragEnd(for: event.type),
               let eventButton,
               forwardedMouseDragButton == eventButton {
                forwardedMouseDragTarget = nil
                forwardedMouseDragButton = nil
            }
            return
        }

        if shouldTrackForwardedMouseDragStart(for: event.type), let eventButton {
            forwardedMouseDragTarget = target
            forwardedMouseDragButton = eventButton
        }

        switch event.type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .leftMouseUp: target.mouseUp(with: event)
        case .leftMouseDragged: target.mouseDragged(with: event)
        case .rightMouseDown: target.rightMouseDown(with: event)
        case .rightMouseUp: target.rightMouseUp(with: event)
        case .rightMouseDragged: target.rightMouseDragged(with: event)
        case .otherMouseDown: target.otherMouseDown(with: event)
        case .otherMouseUp: target.otherMouseUp(with: event)
        case .otherMouseDragged: target.otherMouseDragged(with: event)
        case .scrollWheel: target.scrollWheel(with: event)
        default: break
        }

        if shouldTrackForwardedMouseDragEnd(for: event.type),
           let eventButton,
           forwardedMouseDragButton == eventButton {
            forwardedMouseDragTarget = nil
            forwardedMouseDragButton = nil
        }
    }

    override func mouseDown(with event: NSEvent) { forwardEvent(event) }
    override func mouseUp(with event: NSEvent) { forwardEvent(event) }
    override func mouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseDown(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseUp(with event: NSEvent) { forwardEvent(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseDown(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseUp(with event: NSEvent) { forwardEvent(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardEvent(event) }
    override func scrollWheel(with event: NSEvent) { forwardEvent(event) }

    // MARK: NSDraggingDestination – accept file drops over terminal and browser views.
    //
    // AppKit sends draggingEntered once when the drag enters this overlay, then
    // draggingUpdated as the cursor moves within it. We track which WKWebView (if
    // any) is under the cursor and synthesize enter/exit calls so the browser's
    // HTML5 drag events (dragenter, dragleave, drop) fire correctly.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return updateDragTarget(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return updateDragTarget(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let prev = activeDragWebView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }
        // [TextBox] No per-step notification needed — InputTextView does not
        // maintain cross-event drag state. Just drop our reference.
        activeDragTextBox = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        let webView = activeDragWebView
        activeDragWebView = nil
        // [TextBox] Capture the TextBox target before resetting it.
        let textBox = activeDragTextBox
        activeDragTextBox = nil
        let terminal = terminalUnderPoint(sender.draggingLocation)
        let hasTerminalTarget = terminal != nil
#if DEBUG
        logDragRouteDecision(
            phase: "perform",
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasTerminalTarget: hasTerminalTarget
        )
#endif
        guard shouldCapture else { return false }
        if let webView {
            return webView.performDragOperation(sender)
        }
        // [TextBox] TextBox wins over terminal when the cursor is over one
        // (TextBox sits below the terminal view, so they do not overlap; this
        // branch fires when the drop lands inside the bordered text field).
        if let textBox {
            let urls = (sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            textBox.insertDroppedFilePaths(urls)
            return true
        }
        guard let terminal else { return false }
        return terminal.performDragOperation(sender)
    }

    private func updateDragTarget(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let loc = sender.draggingLocation
        let hasLocalDraggingSource = sender.draggingSource != nil
        let types = sender.draggingPasteboard.types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
        let webView = shouldCapture ? webViewUnderPoint(loc) : nil

        if let prev = activeDragWebView, prev !== webView {
            prev.draggingExited(sender)
            activeDragWebView = nil
        }

        if let webView {
            // [TextBox] Browser beats TextBox when the browser pane owns the point.
            activeDragTextBox = nil
            if activeDragWebView !== webView {
                activeDragWebView = webView
                return webView.draggingEntered(sender)
            }
            return webView.draggingUpdated(sender)
        }

        // [TextBox] After browser has had its turn, check whether the cursor is
        // over an InputTextView. Return `.copy` so macOS shows the green `+`
        // badge — otherwise users see the reject cursor over a target that
        // will actually accept the drop. Plan §4.9.
        let textBox = shouldCapture ? textBoxUnderPoint(loc) : nil
        activeDragTextBox = textBox
        if textBox != nil { return .copy }

        let terminal = terminalUnderPoint(loc)
        let hasTerminalTarget = terminal != nil
#if DEBUG
        logDragRouteDecision(
            phase: phase,
            pasteboardTypes: types,
            shouldCapture: shouldCapture,
            hasLocalDraggingSource: hasLocalDraggingSource,
            hasTerminalTarget: hasTerminalTarget
        )
#endif
        guard shouldCapture, let terminal else { return [] }
        // C11H-363: the terminal's own answer, so a drop it will refuse shows
        // no operation before the operator lets go.
        return terminal.dropOperation(for: sender)
    }

    /// [TextBox] Hit-test the window for an `InputTextView` (TextBox field)
    /// at the given window point. Mirrors `webViewUnderPoint` but walks the
    /// hit view's ancestor chain for the custom NSTextView subclass.
    private func textBoxUnderPoint(_ windowPoint: NSPoint) -> InputTextView? {
        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        guard let hitView = contentView.hitTest(point) else { return nil }
        var current: NSView? = hitView
        while let view = current {
            if let inputView = view as? InputTextView { return inputView }
            current = view.superview
        }
        return nil
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
    }

    /// Hit-tests the window to find a WKWebView (browser panel) under the cursor.
    func webViewUnderPoint(_ windowPoint: NSPoint) -> WKWebView? {
        if let window,
           let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window) {
            return portalWebView
        }

        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(point)

        var current: NSView? = hitView
        while let view = current {
            if let webView = view as? WKWebView { return webView }
            current = view.superview
        }
        return nil
    }

    private func debugTopHitViewForCurrentEvent() -> String {
        guard let window,
              let currentEvent = NSApp.currentEvent,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return "-" }

        let pointInTheme = themeFrame.convert(currentEvent.locationInWindow, from: nil)
        // Don't toggle isHidden here — it triggers setNeedsDisplay which can
        // exceed AppKit's display-pass limit during cursor-update display cycles.
        guard let hit = themeFrame.hitTest(pointInTheme) else { return "nil" }
        var chain: [String] = []
        var current: NSView? = hit
        var depth = 0
        while let view = current, depth < 6 {
            chain.append(debugHitViewDescriptor(view))
            current = view.superview
            depth += 1
        }
        return chain.joined(separator: "->")
    }

    private func debugHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let ptr = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let dragTypes = debugRegisteredDragTypes(view)
        return "\(className)@\(ptr){dragTypes=\(dragTypes)}"
    }

    private func debugRegisteredDragTypes(_ view: NSView) -> String {
        let types = view.registeredDraggedTypes
        guard !types.isEmpty else { return "-" }

        let interestingTypes = types.filter { type in
            let raw = type.rawValue
            return raw == NSPasteboard.PasteboardType.fileURL.rawValue
                || raw == DragOverlayRoutingPolicy.bonsplitTabTransferType.rawValue
                || raw == DragOverlayRoutingPolicy.sidebarWorkspaceReorderType.rawValue
                || raw.contains("public.text")
                || raw.contains("public.url")
                || raw.contains("public.data")
        }
        let selected = interestingTypes.isEmpty ? Array(types.prefix(3)) : interestingTypes
        let rendered = selected.map(\.rawValue).joined(separator: ",")
        if selected.count < types.count {
            return "\(rendered),+\(types.count - selected.count)"
        }
        return rendered
    }

    private func hasRelevantDragTypes(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return types.contains(.fileURL)
            || types.contains(DragOverlayRoutingPolicy.bonsplitTabTransferType)
            || types.contains(DragOverlayRoutingPolicy.sidebarWorkspaceReorderType)
    }

    private func debugEventName(_ eventType: NSEvent.EventType?) -> String {
        guard let eventType else { return "none" }
        switch eventType {
        case .cursorUpdate: return "cursorUpdate"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .periodic: return "periodic"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .scrollWheel: return "scrollWheel"
        default: return "other(\(eventType.rawValue))"
        }
    }

#if DEBUG
    private func logHitTestDecision(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        shouldCapture: Bool
    ) {
        let isDragEvent = eventType == .leftMouseDragged
            || eventType == .rightMouseDragged
            || eventType == .otherMouseDragged
        guard shouldCapture || isDragEvent || hasRelevantDragTypes(pasteboardTypes) else { return }

        let signature = "\(shouldCapture ? 1 : 0)|\(debugEventName(eventType))|\(debugPasteboardTypes(pasteboardTypes))"
        guard lastHitTestLogSignature != signature else { return }
        lastHitTestLogSignature = signature
        dlog(
            "overlay.fileDrop.hitTest capture=\(shouldCapture ? 1 : 0) " +
            "event=\(debugEventName(eventType)) " +
            "topHit=\(debugTopHitViewForCurrentEvent()) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    private func logDragRouteDecision(
        phase: String,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        shouldCapture: Bool,
        hasLocalDraggingSource: Bool,
        hasTerminalTarget: Bool
    ) {
        guard shouldCapture || hasRelevantDragTypes(pasteboardTypes) else { return }
        let signature = [
            shouldCapture ? "1" : "0",
            hasLocalDraggingSource ? "1" : "0",
            hasTerminalTarget ? "1" : "0",
            debugPasteboardTypes(pasteboardTypes)
        ].joined(separator: "|")
        guard lastDragRouteLogSignatureByPhase[phase] != signature else { return }
        lastDragRouteLogSignatureByPhase[phase] = signature
        dlog(
            "overlay.fileDrop.\(phase) capture=\(shouldCapture ? 1 : 0) " +
            "localSource=\(hasLocalDraggingSource ? 1 : 0) " +
            "hasTerminal=\(hasTerminalTarget ? 1 : 0) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }
#endif
    /// Hit-tests the window to find the GhosttyNSView under the cursor.
    func terminalUnderPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        if let window,
           let portalTerminal = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window) {
            return portalTerminal
        }

        guard let window, let contentView = window.contentView else { return nil }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(point)

        var current: NSView? = hitView
        while let view = current {
            if let terminal = view as? GhosttyNSView { return terminal }
            current = view.superview
        }
        return nil
    }
}

var fileDropOverlayKey: UInt8 = 0
private var commandPaletteWindowOverlayKey: UInt8 = 0
let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")

enum CommandPaletteOverlayPromotionPolicy {
    static func shouldPromote(previouslyVisible: Bool, isVisible: Bool) -> Bool {
        isVisible && !previouslyVisible
    }
}

@MainActor
private final class CommandPaletteOverlayContainerView: NSView {
    var capturesMouseEvents = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesMouseEvents else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class WindowCommandPaletteOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = CommandPaletteOverlayContainerView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedThemeFrame: NSView?
    private var focusLockTimer: DispatchSourceTimer?
    private var scheduledFocusWorkItem: DispatchWorkItem?
    private var isPaletteVisible = false
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var windowDidResignKeyObserver: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.capturesMouseEvents = false
        containerView.identifier = commandPaletteOverlayContainerIdentifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        _ = ensureInstalled()
        installWindowKeyObservers()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return false }

        if containerView.superview !== themeFrame {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            themeFrame.addSubview(containerView, positioned: .above, relativeTo: nil)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedThemeFrame = themeFrame
        }

        return true
    }

    private func promoteOverlayAboveSiblingsIfNeeded() {
        guard let themeFrame = installedThemeFrame,
              containerView.superview === themeFrame else { return }
        themeFrame.addSubview(containerView, positioned: .above, relativeTo: nil)
    }

    private func isPaletteResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let view = responder as? NSView, view.isDescendant(of: containerView) {
            return true
        }

        if let textView = responder as? NSTextView {
            if let delegateView = textView.delegate as? NSView,
               delegateView.isDescendant(of: containerView) {
                return true
            }
        }

        return false
    }

    private func isPaletteFieldEditor(_ textView: NSTextView) -> Bool {
        guard textView.isFieldEditor else { return false }

        if let delegateView = textView.delegate as? NSView,
           delegateView.isDescendant(of: containerView) {
            return true
        }

        // SwiftUI text fields can keep a field editor delegate that isn't an NSView.
        // Fall back to validating editor ownership from the mounted palette text field.
        if let textField = firstEditableTextField(in: hostingView),
           textField.currentEditor() === textView {
            return true
        }

        return false
    }

    private func isPaletteTextInputFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let textView = responder as? NSTextView {
            return isPaletteFieldEditor(textView)
        }

        if let textField = responder as? NSTextField {
            return textField.isDescendant(of: containerView)
        }

        return false
    }

    private func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField,
           textField.isEditable,
           textField.isEnabled,
           !textField.isHiddenOrHasHiddenAncestor {
            return textField
        }

        for subview in view.subviews {
            if let match = firstEditableTextField(in: subview) {
                return match
            }
        }
        return nil
    }

    private func scheduleFocusIntoPalette(retries: Int = 4) {
        scheduledFocusWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledFocusWorkItem = nil
            self?.focusIntoPalette(retries: retries)
        }
        scheduledFocusWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func focusIntoPalette(retries: Int) {
        guard let window else { return }
        if isPaletteTextInputFirstResponder(window.firstResponder) {
            return
        }

        if let textField = firstEditableTextField(in: hostingView),
           window.makeFirstResponder(textField),
           isPaletteTextInputFirstResponder(window.firstResponder) {
            normalizeSelectionAfterProgrammaticFocus()
            return
        }

        if window.makeFirstResponder(containerView) {
            if let textField = firstEditableTextField(in: hostingView),
               window.makeFirstResponder(textField),
               isPaletteTextInputFirstResponder(window.firstResponder) {
                normalizeSelectionAfterProgrammaticFocus()
                return
            }
        }

        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.focusIntoPalette(retries: retries - 1)
        }
    }

    private func installWindowKeyObservers() {
        guard let window else { return }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusLockForWindowState()
            }
        }
        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusLockForWindowState()
            }
        }
    }

    private func updateFocusLockForWindowState() {
        guard let window else {
            stopFocusLockTimer()
            return
        }
        guard isPaletteVisible else {
            stopFocusLockTimer()
            return
        }

        guard window.isKeyWindow else {
            stopFocusLockTimer()
            if isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            return
        }

        startFocusLockTimer()
        if !isPaletteTextInputFirstResponder(window.firstResponder) {
            scheduleFocusIntoPalette(retries: 8)
        }
    }

    private func startFocusLockTimer() {
        guard focusLockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(12))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.stopFocusLockTimer()
                return
            }
            if self.isPaletteTextInputFirstResponder(window.firstResponder) {
                return
            }
            self.focusIntoPalette(retries: 1)
        }
        focusLockTimer = timer
        timer.resume()
    }

    private func stopFocusLockTimer() {
        focusLockTimer?.cancel()
        focusLockTimer = nil
        scheduledFocusWorkItem?.cancel()
        scheduledFocusWorkItem = nil
    }

    private func normalizeSelectionAfterProgrammaticFocus() {
        guard let window,
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else { return }

        let text = editor.string
        let length = (text as NSString).length
        let selection = editor.selectedRange()
        guard length > 0 else { return }
        guard selection.location == 0, selection.length == length else { return }

        // Keep commands-mode prefix semantics stable after focus re-assertions:
        // if AppKit selected the entire query (e.g. ">foo"), restore caret-at-end
        // so the next keystroke appends instead of replacing and switching modes.
        guard text.hasPrefix(">") else { return }
        editor.setSelectedRange(NSRange(location: length, length: 0))
    }

    func update(rootView: AnyView, isVisible: Bool) {
        guard ensureInstalled() else { return }
        // Skip redundant work when the palette is not visible and the new update
        // also hides it. SwiftUI calls this on every parent render cycle; without
        // this guard each cycle would re-set hostingView.rootView = EmptyView(),
        // driving unnecessary SwiftUI layout work and contributing to idle spin.
        guard isVisible || isPaletteVisible else { return }
        let shouldPromote = CommandPaletteOverlayPromotionPolicy.shouldPromote(
            previouslyVisible: isPaletteVisible,
            isVisible: isVisible
        )
        isPaletteVisible = isVisible
        if isVisible {
            hostingView.rootView = rootView
            containerView.capturesMouseEvents = true
            containerView.isHidden = false
            containerView.alphaValue = 1
            if shouldPromote {
                promoteOverlayAboveSiblingsIfNeeded()
            }
            updateFocusLockForWindowState()
        } else {
            stopFocusLockTimer()
            if let window, isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            hostingView.rootView = AnyView(EmptyView())
            containerView.capturesMouseEvents = false
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }

    func underlyingResponder(atWindowPoint windowPoint: NSPoint) -> NSResponder? {
        guard let window,
              let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }

        let previousCapturesMouseEvents = containerView.capturesMouseEvents
        containerView.capturesMouseEvents = false
        defer {
            containerView.capturesMouseEvents = previousCapturesMouseEvents
        }

        let pointInTheme = themeFrame.convert(windowPoint, from: nil)
        return themeFrame.hitTest(pointInTheme)
    }
}

@MainActor
private func commandPaletteWindowOverlayController(for window: NSWindow) -> WindowCommandPaletteOverlayController {
    if let existing = objc_getAssociatedObject(window, &commandPaletteWindowOverlayKey) as? WindowCommandPaletteOverlayController {
        return existing
    }
    let controller = WindowCommandPaletteOverlayController(window: window)
    objc_setAssociatedObject(window, &commandPaletteWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
}

private func commandPaletteOwningWebView(for responder: NSResponder?) -> WKWebView? {
    guard let responder else { return nil }

    if let webView = responder as? WKWebView {
        return webView
    }

    if let view = responder as? NSView {
        var current: NSView? = view
        while let candidate = current {
            if let webView = candidate as? WKWebView {
                return webView
            }
            current = candidate.superview
        }
    }

    if let textView = responder as? NSTextView,
       let delegateView = textView.delegate as? NSView,
       let webView = commandPaletteOwningWebView(for: delegateView) {
        return webView
    }

    var currentResponder = responder.nextResponder
    while let next = currentResponder {
        if let webView = commandPaletteOwningWebView(for: next) {
            return webView
        }
        currentResponder = next.nextResponder
    }

    return nil
}

enum WorkspaceMountPolicy {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    static let maxMountedWorkspaces = 1
    // During workspace cycling, keep only a minimal handoff pair (selected + retiring).
    static let maxMountedWorkspacesDuringCycle = 2

    // B012: pending creation requests are a queue, not unbounded mount pins.
    static let maxBackgroundMountedWorkspaces = 1

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        retiring: UUID?,
        pendingBackgroundIds: Set<UUID>,
        debugPinnedIds: Set<UUID>,
        orderedWorkspaceIds: [UUID],
        isCycleHot: Bool
    ) -> [UUID] {
        let existing = Set(orderedWorkspaceIds)
        let selectedIds = Set([selected].compactMap { $0 }).intersection(existing)
        // Debug fixture retention is deliberately outside the production cap.
        var pinnedIds = debugPinnedIds.intersection(existing)
        if let retiring, existing.contains(retiring) { pinnedIds.insert(retiring) }
        let pending = pendingBackgroundIds.intersection(existing)
            .subtracting(selectedIds).subtracting(pinnedIds)
        // Retain the admitted load until it completes or times out. Otherwise
        // choose in workspace order, so a completed body cannot occupy its slot.
        let retained = current.filter { pending.contains($0) }
        let candidates = retained + orderedWorkspaceIds.filter { pending.contains($0) && !retained.contains($0) }
        pinnedIds.formUnion(candidates.prefix(maxBackgroundMountedWorkspaces))
        return nextMountedWorkspaceIds(
            current: current,
            selected: selectedIds.first,
            pinnedIds: pinnedIds,
            orderedWorkspaceIds: orderedWorkspaceIds,
            isCycleHot: isCycleHot,
            maxMounted: max(maxMountedWorkspaces, selectedIds.union(pinnedIds).count)
        )
    }

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedWorkspaceIds: [UUID],
        isCycleHot: Bool,
        maxMounted: Int
    ) -> [UUID] {
        let existing = Set(orderedWorkspaceIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        if isCycleHot, let selected {
            let warmIds = cycleWarmIds(selected: selected, orderedWorkspaceIds: orderedWorkspaceIds)
            for id in warmIds.reversed() {
                ordered.removeAll { $0 == id }
                ordered.insert(id, at: 0)
            }
        }

        if isCycleHot,
           pinnedIds.isEmpty,
           let selected {
            ordered.removeAll { $0 != selected }
        }

        // Ensure pinned ids (retiring handoff workspaces) are always retained at highest priority.
        // This runs after warming to prevent neighbor warming from evicting the retiring workspace.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedWorkspaceIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedWorkspaceIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }

    private static func cycleWarmIds(selected: UUID, orderedWorkspaceIds: [UUID]) -> [UUID] {
        guard orderedWorkspaceIds.contains(selected) else { return [selected] }
        // Keep warming focused to the selected workspace. Retiring/target workspaces are
        // pinned by handoff logic, so warming adjacent neighbors here just adds layout work.
        return [selected]
    }
}

struct MountedWorkspacePresentation: Equatable {
    let isRenderedVisible: Bool
    let isPanelVisible: Bool
    let renderOpacity: Double
}

enum MountedWorkspacePresentationPolicy {
    static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool,
        shouldPrimeInBackground: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace
        let renderOpacity: Double = {
            if isRenderedVisible {
                return 1
            }
            if shouldPrimeInBackground {
                // Keep the workspace mounted long enough to warm the terminal surface, but do
                // not mark it panel-visible. Visible portal entries intentionally survive
                // transient anchor loss during bonsplit drag/reparent churn.
                return 0.001
            }
            return 0
        }()

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: renderOpacity
        )
    }
}

/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.
func installFileDropOverlay(on window: NSWindow, workspaceManager: WorkspaceManager) {
    guard objc_getAssociatedObject(window, &fileDropOverlayKey) == nil,
          let contentView = window.contentView,
          let themeFrame = contentView.superview else { return }

    let overlay = FileDropOverlayView(frame: contentView.frame)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.onDrop = { [weak workspaceManager] urls in
        MainActor.assumeIsolated {
            guard let workspaceManager, let terminal = workspaceManager.selectedWorkspace?.focusedTerminalPanel else { return false }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }

    themeFrame.addSubview(overlay, positioned: .above, relativeTo: contentView)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
        overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    ])

    objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
}

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    /// c11 (C11H-197): this window's name and theme override.
    @ObservedObject private var windowAttributes = WindowAttributesStore.shared
    let windowId: UUID
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @Environment(\.colorScheme) private var colorScheme
    @State private var sidebarWidth: CGFloat = 200
    @State private var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State private var isResizerDragging = false
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var selectedWorkspaceIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State private var observedWindow: NSWindow?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var sidebarDraggedWorkspaceId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State private var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State private var sidebarResizerPointerMonitor: Any?
    @State private var isResizerBandActive = false
    @State private var isSidebarResizerCursorActive = false
    @State private var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @State private var isCommandPalettePresented = false
    @State private var commandPaletteQuery: String = ""
    @State private var commandPaletteMode: CommandPaletteMode = .commands
    @State private var commandPaletteRenameDraft: String = ""
    @State private var commandPaletteSelectedResultIndex: Int = 0
    @State private var commandPaletteSelectionAnchorCommandID: String?
    @State private var commandPaletteHoveredResultIndex: Int?
    @State private var commandPaletteScrollTargetIndex: Int?
    @State private var commandPaletteScrollTargetAnchor: UnitPoint?
    @State private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @State private var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @State private var commandPaletteSearchCommandsByID: [String: CommandPaletteCommand] = [:]
    @State private var cachedCommandPaletteResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResultsScope: CommandPaletteListScope?
    @State private var commandPaletteVisibleResultsFingerprint: Int?
    @State private var cachedCommandPaletteScope: CommandPaletteListScope?
    @State private var cachedCommandPaletteFingerprint: Int?
    @State private var commandPalettePendingDismissFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem?
    @State private var commandPalettePendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior?
    @State private var commandPaletteSearchTask: Task<Void, Never>?
    @State private var commandPaletteSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchScope: CommandPaletteListScope?
    @State private var commandPaletteResolvedSearchFingerprint: Int?
    @State private var commandPaletteResolvedMatchingQuery = ""
    @State private var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @State private var isCommandPaletteSearchPending = false
    @State private var commandPalettePendingActivation: CommandPalettePendingActivation?
    /// Who submitted the pending activation (nil: the operator), replayed with it.
    @State private var commandPalettePendingOrigin: SocketCommandContext?
    @State private var commandPaletteResultsRevision: UInt64 = 0
    @State private var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]
    @State private var isFeedbackComposerPresented = false
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    private var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    private var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool

    private enum CommandPaletteMode {
        case commands
        case renameInput(CommandPaletteRenameTarget)
        case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
    }

    private enum CommandPaletteListScope: String {
        case commands
        case switcher
    }

    enum CommandPalettePendingActivation: Equatable {
        case selected(requestID: UInt64, fallbackSelectedIndex: Int, preferredCommandID: String?)
        case command(requestID: UInt64, commandID: String)
    }

    enum CommandPaletteResolvedActivation: Equatable {
        case selected(index: Int)
        case command(commandID: String)
    }

    private struct CommandPaletteRenameTarget: Equatable {
        enum Kind: Equatable {
            case workspace(workspaceId: UUID)
            case panel(workspaceId: UUID, panelId: UUID)
        }

        let kind: Kind
        let currentName: String

        var title: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspaceTitle", defaultValue: "Rename Workspace")
            case .panel:
                return String(localized: "commandPalette.rename.tabTitle", defaultValue: "Rename Panel")
            }
        }

        var description: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspaceDescription", defaultValue: "Choose a custom workspace name.")
            case .panel:
                return String(localized: "commandPalette.rename.tabDescription", defaultValue: "Pick a custom panel name.")
            }
        }

        var placeholder: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspacePlaceholder", defaultValue: "Workspace name")
            case .panel:
                return String(localized: "commandPalette.rename.tabPlaceholder", defaultValue: "Panel name")
            }
        }
    }

    private struct CommandPaletteRestoreFocusTarget {
        let workspaceId: UUID
        let panelId: UUID
        let intent: PanelFocusIntent
    }

    private enum CommandPaletteInputFocusTarget {
        case search
        case rename
    }

    private enum CommandPaletteTextSelectionBehavior {
        case caretAtEnd
        case selectAll
    }

    private enum CommandPaletteTrailingLabelStyle {
        case shortcut
        case kind
    }

    private struct CommandPaletteTrailingLabel {
        let text: String
        let style: CommandPaletteTrailingLabelStyle
    }

    private struct CommandPaletteInputFocusPolicy {
        let focusTarget: CommandPaletteInputFocusTarget
        let selectionBehavior: CommandPaletteTextSelectionBehavior

        static let search = CommandPaletteInputFocusPolicy(
            focusTarget: .search,
            selectionBehavior: .caretAtEnd
        )
    }

    private struct CommandPaletteCommand: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let subtitle: String
        let shortcutHint: String?
        let kindLabel: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let action: () -> Void

        var searchableTexts: [String] {
            [title, subtitle] + keywords
        }
    }

    private struct CommandPaletteUsageEntry: Codable, Sendable {
        var useCount: Int
        var lastUsedAt: TimeInterval
    }

    private struct CommandPaletteContextSnapshot {
        private var boolValues: [String: Bool] = [:]
        private var stringValues: [String: String] = [:]

        mutating func setBool(_ key: String, _ value: Bool) {
            boolValues[key] = value
        }

        mutating func setString(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else {
                stringValues.removeValue(forKey: key)
                return
            }
            stringValues[key] = value
        }

        func bool(_ key: String) -> Bool {
            boolValues[key] ?? false
        }

        func string(_ key: String) -> String? {
            stringValues[key]
        }

        func fingerprint() -> Int {
            ContentView.commandPaletteContextFingerprint(
                boolValues: boolValues,
                stringValues: stringValues
            )
        }
    }

    private struct CommandPaletteCommandsContext {
        let snapshot: CommandPaletteContextSnapshot
    }

    private enum CommandPaletteContextKeys {
        static let hasWorkspace = "workspace.hasSelection"
        static let workspaceName = "workspace.name"
        static let workspaceHasCustomName = "workspace.hasCustomName"
        static let workspaceMinimalModeEnabled = "workspace.minimalModeEnabled"
        static let workspaceShouldPin = "workspace.shouldPin"
        static let workspaceHasPullRequests = "workspace.hasPullRequests"
        static let workspaceHasSplits = "workspace.hasSplits"
        static let workspaceHasAbove = WorkspaceSidebarStepPalette.hasAboveKey
        static let workspaceHasBelow = WorkspaceSidebarStepPalette.hasBelowKey
        static let workspaceCanMoveToTop = "workspace.canMoveToTop"
        static let workspaceHasUnread = "workspace.hasUnread"
        static let workspaceHasRead = "workspace.hasRead"

        static let hasFocusedPanel = "panel.hasFocus"
        static let panelName = "panel.name"
        static let panelIsBrowser = "panel.isBrowser"
        static let panelIsTerminal = "panel.isTerminal"
        static let panelHasCustomName = "panel.hasCustomName"
        static let panelShouldPin = "panel.shouldPin"
        static let panelHasUnread = "panel.hasUnread"

        static let updateHasAvailable = "update.hasAvailable"
        static let cliInstalledInPATH = "cli.installedInPATH"

        static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> String {
            "terminal.openTarget.\(target.rawValue).available"
        }
    }

    private struct CommandPaletteCommandContribution {
        let commandId: String
        let title: (CommandPaletteContextSnapshot) -> String
        let subtitle: (CommandPaletteContextSnapshot) -> String
        let shortcutHint: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let when: (CommandPaletteContextSnapshot) -> Bool
        let enablement: (CommandPaletteContextSnapshot) -> Bool

        init(
            commandId: String,
            title: @escaping (CommandPaletteContextSnapshot) -> String,
            subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
            shortcutHint: String? = nil,
            keywords: [String] = [],
            dismissOnRun: Bool = true,
            when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
            enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
        ) {
            self.commandId = commandId
            self.title = title
            self.subtitle = subtitle
            self.shortcutHint = shortcutHint
            self.keywords = keywords
            self.dismissOnRun = dismissOnRun
            self.when = when
            self.enablement = enablement
        }
    }

    private struct CommandPaletteHandlerRegistry {
        private var handlers: [String: () -> Void] = [:]

        mutating func register(commandId: String, handler: @escaping () -> Void) {
            handlers[commandId] = handler
        }

        func handler(for commandId: String) -> (() -> Void)? {
            handlers[commandId]
        }
    }

    private struct CommandPaletteSearchResult: Identifiable {
        let command: CommandPaletteCommand
        let score: Int
        let titleMatchIndices: Set<Int>

        var id: String { command.id }
    }

    private struct CommandPaletteResolvedSearchMatch: Sendable {
        let commandID: String
        let score: Int
        let titleMatchIndices: Set<Int>
    }

    private struct CommandPaletteSwitcherWindowContext {
        let windowId: UUID
        let workspaceManager: WorkspaceManager
        let selectedWorkspaceId: UUID?
        let windowLabel: String?
    }

    struct CommandPaletteSwitcherFingerprintWorkspace: Sendable {
        let id: UUID
        let displayName: String
        let metadata: CommandPaletteSwitcherSearchMetadata
        let surfaces: [CommandPaletteSwitcherFingerprintPanel]
    }

    struct CommandPaletteSwitcherFingerprintPanel: Sendable {
        let id: UUID
        let displayName: String
        let kindLabel: String
        let metadata: CommandPaletteSwitcherSearchMetadata
    }

    struct CommandPaletteSwitcherFingerprintContext: Sendable {
        let windowId: UUID
        let windowLabel: String?
        let selectedWorkspaceId: UUID?
        let workspaces: [CommandPaletteSwitcherFingerprintWorkspace]
    }

    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    private static let commandPaletteUsageDefaultsKey = "commandPalette.commandUsage.v1"
    nonisolated private static let commandPaletteCommandsPrefix = ">"
    private static let commandPaletteVisiblePreviewResultLimit = 48
    private static let commandPaletteVisiblePreviewCandidateLimit = 192
    private static let minimumSidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0

    private enum SidebarResizerHandle: Hashable {
        case divider
    }

    private var sidebarResizerHitWidthPerSide: CGFloat {
        SidebarResizeInteraction.hitWidthPerSide
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return max(Self.minimumSidebarWidth, min(CGFloat(SessionPersistencePolicy.maximumSidebarWidth), resolvedAvailableWidth * Self.maximumSidebarWidthRatio))
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1920
        return max(Self.minimumSidebarWidth, min(CGFloat(SessionPersistencePolicy.maximumSidebarWidth), fallbackScreenWidth * Self.maximumSidebarWidthRatio))
    }

    static func clampedSidebarWidth(_ candidate: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        let minimumWidth = Self.minimumSidebarWidth
        let sanitizedMaximumWidth = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        }
        return max(minimumWidth, min(sanitizedMaximumWidth, candidate))
    }

    private func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = Self.clampedSidebarWidth(
            sidebarState.persistedWidth,
            maximumWidth: maxSidebarWidth(availableWidth: availableWidth)
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    private func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        Self.clampedSidebarWidth(candidate, maximumWidth: maxSidebarWidth())
    }

    private func activateSidebarResizerCursor() {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        sidebarResizerCursorReleaseWorkItem = nil
        isSidebarResizerCursorActive = true
        Self.fixedSidebarResizeCursor.set()
    }

    private func releaseSidebarResizerCursorIfNeeded(force: Bool = false) {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let shouldKeepCursor = !force
            && (isResizerDragging || isResizerBandActive || !hoveredResizerHandles.isEmpty || isLeftMouseButtonDown)
        guard !shouldKeepCursor else { return }
        guard isSidebarResizerCursorActive else { return }
        isSidebarResizerCursorActive = false
        NSCursor.arrow.set()
    }

    private func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: TimeInterval = 0) {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            sidebarResizerCursorReleaseWorkItem = nil
            releaseSidebarResizerCursorIfNeeded(force: force)
        }
        sidebarResizerCursorReleaseWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func dividerBandContains(pointInContent point: NSPoint, contentBounds: NSRect) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        let minX = sidebarWidth - sidebarResizerHitWidthPerSide
        let maxX = sidebarWidth + sidebarResizerHitWidthPerSide
        return point.x >= minX && point.x <= maxX
    }

    private func updateSidebarResizerBandState(using event: NSEvent? = nil) {
        guard sidebarState.isVisible,
              let window = observedWindow,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live global pointer location instead of per-event coordinates.
        // Overlapping tracking areas (notably WKWebView) can deliver stale/jittery
        // event locations during cursor updates, which causes visible cursor flicker.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = dividerBandContains(pointInContent: pointInContent, contentBounds: contentView.bounds)
        isResizerBandActive = isInDividerBand

        if isInDividerBand || isResizerDragging {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // AppKit cursorUpdate handlers from overlapped portal/web views can run
            // after our local monitor callback and temporarily reset the cursor.
            // Re-assert on the next runloop turn to keep the resize cursor stable.
            DispatchQueue.main.async {
                Self.fixedSidebarResizeCursor.set()
            }
        } else {
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func startSidebarResizerCursorStabilizer() {
        guard sidebarResizerCursorStabilizer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler {
            updateSidebarResizerBandState()
            if isResizerBandActive || isResizerDragging {
                Self.fixedSidebarResizeCursor.set()
            } else {
                stopSidebarResizerCursorStabilizer()
            }
        }
        sidebarResizerCursorStabilizer = timer
        timer.resume()
    }

    private func stopSidebarResizerCursorStabilizer() {
        sidebarResizerCursorStabilizer?.cancel()
        sidebarResizerCursorStabilizer = nil
    }

    private func installSidebarResizerPointerMonitorIfNeeded() {
        guard sidebarResizerPointerMonitor == nil else { return }
        observedWindow?.acceptsMouseMovedEvents = true
        sidebarResizerPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
            ]
        ) { event in
            updateSidebarResizerBandState(using: event)
            let shouldOverrideCursorEvent: Bool = {
                switch event.type {
                case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined:
                    return true
                default:
                    return false
                }
            }()
            if shouldOverrideCursorEvent, (isResizerBandActive || isResizerDragging) {
                // Consume hover motion in divider band so overlapped views cannot
                // continuously reassert their own cursor while we are resizing.
                activateSidebarResizerCursor()
                Self.fixedSidebarResizeCursor.set()
                return nil
            }
            return event
        }
        updateSidebarResizerBandState()
    }

    private func removeSidebarResizerPointerMonitor() {
        if let monitor = sidebarResizerPointerMonitor {
            NSEvent.removeMonitor(monitor)
            sidebarResizerPointerMonitor = nil
        }
        isResizerBandActive = false
        isSidebarResizerCursorActive = false
        stopSidebarResizerCursorStabilizer()
        scheduleSidebarResizerCursorRelease(force: true)
    }

    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredResizerHandles.insert(handle)
                    activateSidebarResizerCursor()
                } else {
                    hoveredResizerHandles.remove(handle)
                    let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if isLeftMouseButtonDown {
                        // Keep resize cursor pinned through mouse-down so AppKit
                        // cursorUpdate events from overlapping views do not flash arrow.
                        activateSidebarResizerCursor()
                    } else {
                        // Give mouse-down + drag-start callbacks time to establish state
                        // before any cursor pop is attempted.
                        scheduleSidebarResizerCursorRelease(delay: 0.05)
                    }
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                hoveredResizerHandles.remove(handle)
                if isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    isResizerDragging = false
                }
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isResizerDragging {
                            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
                            isResizerDragging = true
                            sidebarDragStartWidth = sidebarWidth
                        }

                        activateSidebarResizerCursor()
                        let startWidth = sidebarDragStartWidth ?? sidebarWidth
                        let nextWidth = Self.clampedSidebarWidth(
                            startWidth + value.translation.width,
                            maximumWidth: maxSidebarWidth(availableWidth: availableWidth)
                        )
                        withTransaction(Transaction(animation: nil)) {
                            sidebarState.persistedWidth = nextWidth
                            sidebarWidth = nextWidth
                        }
                    }
                    .onEnded { _ in
                        if isResizerDragging {
                            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                            isResizerDragging = false
                            sidebarDragStartWidth = nil
                        }
                        activateSidebarResizerCursor()
                        scheduleSidebarResizerCursorRelease()
                    }
            )
            .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
    }

    private var sidebarResizerOverlay: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let dividerX = min(max(sidebarWidth, 0), totalWidth)
            let leadingWidth = max(0, dividerX - sidebarResizerHitWidthPerSide)

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    .divider,
                    width: sidebarResizerHitWidthPerSide * 2,
                    availableWidth: totalWidth,
                    accessibilityIdentifier: "SidebarResizer"
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
            .onAppear {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
            .onChange(of: totalWidth) {
                clampSidebarWidthIfNeeded(availableWidth: totalWidth)
            }
        }
    }

    private var sidebarView: some View {
        WorkspaceSidebar(
            updateViewModel: updateViewModel,
            onSendFeedback: presentFeedbackComposer,
            width: sidebarWidth,
            selection: $sidebarSelectionState.selection,
            selectedWorkspaceIds: $selectedWorkspaceIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// Space at top of content area for the titlebar. This must be at least the actual titlebar
    /// height; otherwise controls like Bonsplit tab dragging can be interpreted as window drags.
    @State private var titlebarPadding: CGFloat = 32
    @Environment(\.chromeScaleTokens) private var chromeTokens
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        isMinimalMode ? 0 : titlebarPadding
    }

    private var terminalContent: some View {
        let mountedWorkspaceIdSet = Set(mountedWorkspaceIds)
        let mountedWorkspaces = workspaceManager.workspaces.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = workspaceManager.selectedWorkspaceId
        let retiringWorkspaceId = self.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { workspace in
                    let isSelectedWorkspace = selectedWorkspaceId == workspace.id
                    let isRetiringWorkspace = retiringWorkspaceId == workspace.id
                    let shouldPrimeInBackground = workspaceManager.pendingBackgroundWorkspaceLoadIds.contains(workspace.id)
                    let presentation = MountedWorkspacePresentationPolicy.resolve(
                        isSelectedWorkspace: isSelectedWorkspace,
                        isRetiringWorkspace: isRetiringWorkspace,
                        shouldPrimeInBackground: shouldPrimeInBackground
                    )
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    // Phase 1: wrap in AppKitHiddenWrapper so off-screen workspaces
                    // are isHidden=true at the AppKit level, which lets the
                    // _layoutSubtreeWithOldSize: walk short-circuit their subtrees
                    // entirely. .opacity(0) does not skip layout; isHidden does.
                    AppKitHiddenWrapper(isHidden: !presentation.isRenderedVisible) {
                        WorkspaceContentView(
                            workspace: workspace,
                            isWorkspaceVisible: presentation.isPanelVisible,
                            isWorkspaceInputActive: isInputActive,
                            workspacePortalPriority: portalPriority,
                            onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                                scheduleTitlebarThemeRefreshFromWorkspace(
                                    workspaceId: workspace.id,
                                    reason: reason,
                                    backgroundEventId: eventId,
                                    backgroundSource: source,
                                    notificationPayloadHex: payloadHex
                                )
                            }
                        )
                    }
                    .opacity(presentation.renderOpacity)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!presentation.isRenderedVisible)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                    .task(id: shouldPrimeInBackground ? workspace.id : nil) {
                        await primeBackgroundWorkspaceIfNeeded(workspaceId: workspace.id)
                    }
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
                .accessibilityHidden(sidebarSelectionState.selection != .notifications)
        }
        .padding(.top, effectiveTitlebarPadding)
        .overlay(alignment: .top) {
            if !isMinimalMode {
                // Titlebar overlay is only over terminal content, not the sidebar.
                customTitlebar
            }
        }
        // Published from here, not the custom titlebar, so the minimal-mode and
        // fullscreen control groups get their colors too.
        .onChange(of: titlebarControlsColors, initial: true) { _, colors in
            if sidebarState.customTitlebarForeground != colors.foreground {
                sidebarState.customTitlebarForeground = colors.foreground
            }
            if sidebarState.titlebarControlsBackdrop != colors.backdrop {
                sidebarState.titlebarControlsBackdrop = colors.backdrop
            }
            if sidebarState.titlebarControlsBackdropIsLight != colors.isLight {
                sidebarState.titlebarControlsBackdropIsLight = colors.isLight
            }
        }
    }

    private var terminalContentWithSidebarDropOverlay: some View {
        terminalContent
            .overlay {
                SidebarExternalDropOverlay(
                    draggedWorkspaceId: sidebarDraggedWorkspaceId,
                    workspaceManager: workspaceManager
                )
            }
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false
    @AppStorage("debugTitlebarLeadingExtra") private var debugTitlebarLeadingExtra: Double = 0
    @AppStorage(ThemeAppStorage.Keys.m1bCustomTitlebarMigrated, store: ThemeAppStorage.defaults)
    private var m1bCustomTitlebarMigrated = false

    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyleRaw = TitlebarControlsStyle.classic.rawValue
    @AppStorage(ShortcutHintDebugSettings.titlebarHintXKey) private var titlebarHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    private var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    private var fakeTitlebarTextColor: Color {
        titlebarControlsColors.foreground
    }

    private var titlebarControlsColors: TitlebarControlsColors {
        _ = titlebarThemeGeneration
        let background = useThemeM1bCustomTitlebarPath
            ? resolvedCustomTitlebarBackgroundColor
            : GhosttyApp.shared.defaultBackgroundColor
        return TitlebarControlsColors(titlebarBackground: background)
    }

    /// c11 (C11H-197): the theme this window overrides the app theme with; nil
    /// follows the app theme. Injected for every view in the window at the root.
    private var windowThemeName: String? {
        windowAttributes.themeName(for: windowId)
    }

    /// c11 (C11H-197): the operator's name for this window, if any.
    private var windowName: String? {
        windowAttributes.name(for: windowId)
    }

    private var useThemeM1bCustomTitlebarPath: Bool {
        themeManager.themedPathLive(flag: m1bCustomTitlebarMigrated, windowThemeName: windowThemeName)
    }

    private var titlebarThemeContext: ThemeContext {
        themeManager.makeContext(
            workspaceColor: workspaceManager.selectedWorkspace?.customColor,
            colorScheme: colorScheme,
            windowThemeName: windowThemeName
        )
    }

    private var legacyCustomTitlebarOpacity: CGFloat {
        let alpha = CGFloat(GhosttyApp.shared.defaultBackgroundOpacity)
        return alpha >= 0.999 ? alpha : 1.0 - pow(1.0 - alpha, 2)
    }

    private var resolvedCustomTitlebarBackgroundColor: NSColor {
        guard useThemeM1bCustomTitlebarPath,
              let color: NSColor = themeManager.resolve(.titleBar_background, context: titlebarThemeContext) else {
            return GhosttyApp.shared.defaultBackgroundColor
        }
        return color
    }

    private var resolvedCustomTitlebarBackgroundOpacity: CGFloat {
        guard useThemeM1bCustomTitlebarPath,
              let opacity: Double = themeManager.resolve(.titleBar_backgroundOpacity, context: titlebarThemeContext) else {
            return legacyCustomTitlebarOpacity
        }
        return CGFloat(opacity)
    }

    private var resolvedCustomTitlebarBottomBorder: Color {
        guard useThemeM1bCustomTitlebarPath,
              let color: NSColor = themeManager.resolve(.titleBar_borderBottom, context: titlebarThemeContext) else {
            return Color(nsColor: .separatorColor)
        }
        return Color(nsColor: color)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: TerminalNotificationStore.shared,
            viewModel: fullscreenControlsViewModel,
            sidebarState: sidebarState,
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: {
                if let appDelegate = AppDelegate.shared {
                    appDelegate.presentCreateWorkspaceSheet()
                } else {
                    workspaceManager.addTab()
                }
            },
            visibilityMode: .alwaysVisible
        )
    }

    private var customTitlebar: some View {
        let titleForeground = fakeTitlebarTextColor
        return ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            HStack(spacing: 8) {
                if isFullScreen && !sidebarState.isVisible {
                    fullscreenControls
                }

                // Draggable folder icon + focused command name
                if let directory = focusedDirectory {
                    DraggableFolderIcon(directory: directory)
                        .accessibilityIdentifier("workspace.titlebarFolder")
                }

                // c11 (C11H-197): the window's name, ahead of the workspace
                // title. It keeps its width; the title truncates first.
                if let windowName {
                    titlebarWindowNameLabel(windowName)
                }

                // With Big Board's clock the title is laid out first, so the
                // clock (not the title) gives way; without it, 0 is the default.
                let clockStyle = titlebarClockStyle
                styledTitlebarTitle
                    .foregroundColor(titleForeground)
                    .lineLimit(1)
                    .layoutPriority(clockStyle == nil ? 0 : 1)
                    .accessibilityIdentifier("workspace.titlebarTitle")
                    .allowsHitTesting(false)

                Spacer(minLength: 8)

                // Big Board's clock: in the trailing slot, dropped rather than
                // squeezing the title when the window is too narrow for both.
                if let clockStyle {
                    ViewThatFits(in: .horizontal) {
                        ThemeTitlebarClock(style: clockStyle)
                        Color.clear.frame(width: 0, height: 0)
                    }
                }

                WorkspaceRootTitlebarLabel(
                    workspace: selectedTitlebarWorkspace,
                    foregroundColor: fakeTitlebarTextColor
                )

                // C11-238: fixed trailing slot so it never moves with the title.
                WorkspaceRootInfoButton(
                    workspace: selectedTitlebarWorkspace,
                    foregroundColor: fakeTitlebarTextColor
                )

                // c11h: the top-right corner fills the screen, so a window left
                // as a sliver after a display change comes back in one click.
                // Disabled, not removed, in full screen so the slot never moves.
                WindowMaximizeButton(
                    foregroundColor: fakeTitlebarTextColor.opacity(0.75),
                    accessibilityIdentifier: "WindowMaximizeButton.titlebar"
                )
                .buttonStyle(.plain)
                .disabled(isFullScreen)
                .opacity(isFullScreen ? 0.3 : 1)
            }
            // HStack fills the titlebar height and the text centers within it.
            // Dropping the explicit frame(height: 28) + .padding(.top, 2) (which
            // sat the content 30pt tall in a 32pt outer, with the implicit
            // bottom space stacking against the 1pt bottom border so the text
            // read as bottom-heavy) lets the bold text sit symmetrically.
            .padding(.leading, customTitlebarLeadingPadding)
            .padding(.trailing, 8)
        }
        .frame(height: titlebarPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background({
            return TitlebarLayerBackground(
                backgroundColor: resolvedCustomTitlebarBackgroundColor,
                opacity: resolvedCustomTitlebarBackgroundOpacity
            )
        }())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(resolvedCustomTitlebarBottomBorder)
                .frame(height: 1)
        }
        .themeScanlines()
    }

    /// The window's name as a quiet capsule: the title's type at a smaller size, in
    /// the title bar's secondary colour. Priority 2 keeps it whole while the
    /// workspace title (0, or 1 beside the clock) truncates.
    private func titlebarWindowNameLabel(_ name: String) -> some View {
        let style = themeManager.themeOwnsChrome(windowThemeName: windowThemeName)
            ? themeManager.textStyle(.windowTitle, windowThemeName: windowThemeName)
            : .unset
        let baseSize = max(9, chromeTokens.windowTitlebarTitle - 2)
        let color = titlebarWindowNameColor
        var text = Text(style.apply(name)).font(style.chromeFont(size: baseSize, weight: .medium))
        if style.tracking != nil {
            text = text.tracking(style.trackingPoints(baseSize: baseSize))
        }
        return text
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 1))
            .layoutPriority(2)
            .accessibilityIdentifier("workspace.titlebarWindowName")
            .allowsHitTesting(false)
    }

    private var titlebarWindowNameColor: Color {
        if useThemeM1bCustomTitlebarPath,
           let color: NSColor = themeManager.resolve(.titleBar_foregroundSecondary, context: titlebarThemeContext) {
            return Color(nsColor: color)
        }
        return fakeTitlebarTextColor.opacity(0.65)
    }

    /// The title in the theme's `[type.windowTitle]`; unset, bold system at the top-bar size.
    private var styledTitlebarTitle: Text {
        let style = themeManager.themeOwnsChrome(windowThemeName: windowThemeName)
            ? themeManager.textStyle(.windowTitle, windowThemeName: windowThemeName)
            : .unset
        guard !style.isUnset else {
            return Text(titlebarText).font(.system(size: chromeTokens.windowTitlebarTitle, weight: .bold))
        }
        let baseSize = chromeTokens.windowTitlebarTitle
        let text = Text(style.apply(titlebarText)).font(style.font(baseSize: baseSize, defaultWeight: .bold))
        guard style.tracking != nil else { return text }
        return text.tracking(style.trackingPoints(baseSize: baseSize))
    }

    private var titlebarClockStyle: ThemeTitlebarClock.Style? {
        // Checked before any context or colour work: this runs on every body.
        guard themeManager.themeOwnsChrome(windowThemeName: windowThemeName),
              (themeManager.style(.ornamentTitlebarClock, context: titlebarThemeContext) as Bool?) == true else {
            return nil
        }
        let primary = fakeTitlebarTextColor
        return ThemeTitlebarClock.style(
            themeManager,
            context: titlebarThemeContext,
            primary: primary,
            secondary: primary.opacity(0.6)
        )
    }

    private var customTitlebarLeadingPadding: CGFloat {
        let config = (TitlebarControlsStyle(rawValue: titlebarControlsStyleRaw) ?? .classic).config
        return config.titleLeadingPadding(sidebarWidth: sidebarWidth,
            sidebarVisible: sidebarState.isVisible, isFullScreen: isFullScreen,
            extra: CGFloat(debugTitlebarLeadingExtra), hintXOffset: titlebarHintXOffset)
    }

    private func updateTitlebarText() {
        guard let selectedId = workspaceManager.selectedWorkspaceId,
              let workspace = workspaceManager.workspaces.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
    }

    private func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    private func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        if GhosttyApp.shared.backgroundLogEnabled {
            let eventLabel = backgroundEventId.map(String.init) ?? "nil"
            let sourceLabel = backgroundSource ?? "nil"
            let payloadLabel = notificationPayloadHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        }
    }

    private func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard workspaceManager.selectedWorkspaceId == workspaceId else {
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(workspaceManager.selectedWorkspaceId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    private var selectedTitlebarWorkspace: Workspace? {
        guard let selectedId = workspaceManager.selectedWorkspaceId else { return nil }
        return workspaceManager.workspaces.first(where: { $0.id == selectedId })
    }

    /// The titlebar's draggable folder: never a directory a terminal on
    /// another machine reported (C11H-363, `Workspace.localFolderDirectory`).
    private var focusedDirectory: String? {
        guard let selectedId = workspaceManager.selectedWorkspaceId,
              let workspace = workspaceManager.workspaces.first(where: { $0.id == selectedId }) else {
            return nil
        }
        return workspace.localFolderDirectory()
    }

    private var contentAndSidebarLayout: AnyView {
        let layout: AnyView
        if sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue {
            // Overlay mode: terminal extends full width, sidebar on top
            // This allows withinWindow blur to see the terminal content
            layout = AnyView(
                ZStack(alignment: .leading) {
                    terminalContentWithSidebarDropOverlay
                        .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                    if sidebarState.isVisible {
                        sidebarView
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarView
                    }
                    terminalContentWithSidebarDropOverlay
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

    var body: some View {
        // C11H-238 meter: name what invalidated this body (stdout, meter runs only).
        let _ = GraphChurnMeter.printsChanges ? Self._printChanges() : ()
        let _ = GraphChurnMeter.note(.contentViewBody)
        var view = AnyView(
            // C11H-38: the launch resume banner takes its own strip below the
            // content, so it never overlaps a terminal or the titlebar. It
            // observes its own model and adds nothing when there is no report.
            VStack(spacing: 0) {
                contentAndSidebarLayout
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topLeading) {
                        if isFullScreen && sidebarState.isVisible && !isMinimalMode {
                            fullscreenControls
                                .padding(.leading, 10)
                                .padding(.top, 4)
                        }
                    }
                LaunchResumeBannerView()
            }
            .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
            .background(Color.clear)
        )

        view = AnyView(view.onAppear {
            workspaceManager.applyWindowBackgroundForSelectedTab()
            reconcileMountedWorkspaceIds()
            previousSelectedWorkspaceId = workspaceManager.selectedWorkspaceId
            installSidebarResizerPointerMonitorIfNeeded()
            let restoredWidth = normalizedSidebarWidth(sidebarState.persistedWidth)
            if abs(sidebarWidth - restoredWidth) > 0.5 {
                sidebarWidth = restoredWidth
            }
            if selectedWorkspaceIds.isEmpty, let selectedId = workspaceManager.selectedWorkspaceId {
                selectedWorkspaceIds = [selectedId]
                lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == selectedId }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(workspaces: workspaceManager.workspaces)
            updateTitlebarText()

            // Startup recovery (#399): if session restore or a race condition leaves the
            // view in a broken state (empty tabs, no selection, unmounted workspaces),
            // detect and recover after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak workspaceManager] in
                guard let workspaceManager else { return }
                var didRecover = false

                // Ensure there is at least one workspace.
                if workspaceManager.workspaces.isEmpty {
                    workspaceManager.addWorkspace()
                    didRecover = true
                }

                // Ensure selectedTabId points to an existing workspace.
                if workspaceManager.selectedWorkspaceId == nil || !workspaceManager.workspaces.contains(where: { $0.id == workspaceManager.selectedWorkspaceId }) {
                    workspaceManager.selectedWorkspaceId = workspaceManager.workspaces.first?.id
                    didRecover = true
                }

                // Ensure mountedWorkspaceIds is populated.
                if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in workspaceManager.workspaces.contains { $0.id == id } }) {
                    reconcileMountedWorkspaceIds()
                    didRecover = true
                }

                // Ensure sidebar selection is valid.
                if selectedWorkspaceIds.isEmpty, let selectedId = workspaceManager.selectedWorkspaceId {
                    selectedWorkspaceIds = [selectedId]
                    lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == selectedId }
                    didRecover = true
                }

                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(workspaces: workspaceManager.workspaces)

                if didRecover {
#if DEBUG
                    dlog("startup.recovery tabCount=\(workspaceManager.workspaces.count) selected=\(workspaceManager.selectedWorkspaceId?.uuidString.prefix(8) ?? "nil") mounted=\(mountedWorkspaceIds.count)")
#endif
                    sentryBreadcrumb("startup.recovery", data: [
                        "tabCount": workspaceManager.workspaces.count,
                        "selectedTabId": workspaceManager.selectedWorkspaceId?.uuidString ?? "nil",
                        "mountedCount": mountedWorkspaceIds.count
                    ])
                }
            }
        })

        view = AnyView(view.onChange(of: workspaceManager.selectedWorkspaceId) { newValue in
#if DEBUG
            if let snapshot = workspaceManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                )
            } else {
                dlog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
            }
#endif
            if let signpostID = workspaceManager.currentSwitchSignpostID {
                WorkspaceSwitchSignpost.event(
                    signpostID,
                    "view.selectedChange",
                    "selected=\(String(newValue?.uuidString.prefix(5) ?? "nil"))"
                )
            }
            workspaceManager.applyWindowBackgroundForSelectedTab()
            startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
            reconcileMountedWorkspaceIds(selectedId: newValue)
            guard let newValue else { return }
            if selectedWorkspaceIds.count <= 1 {
                selectedWorkspaceIds = [newValue]
                lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == newValue }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: selectedWorkspaceIds) { _ in
            syncSidebarSelectedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: workspaceManager.isWorkspaceCycleHot) { _ in
#if DEBUG
            if let snapshot = workspaceManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(workspaceManager.isWorkspaceCycleHot ? 1 : 0)"
                )
            } else {
                dlog("ws.view.hotChange id=none hot=\(workspaceManager.isWorkspaceCycleHot ? 1 : 0)")
            }
#endif
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: retiringWorkspaceId) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(workspaceManager.$pendingBackgroundWorkspaceLoadIds) { pendingIds in
            // @Published emits before storage changes; use the new queue to
            // promote the next background load when the admitted one completes.
            reconcileMountedWorkspaceIds(pendingBackgroundIds: pendingIds)
        })

        view = AnyView(view.onReceive(workspaceManager.$debugPinnedWorkspaceLoadIds) { pinnedIds in
            reconcileMountedWorkspaceIds(debugPinnedIds: pinnedIds)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.workspaceId] as? UUID,
                  workspaceId == workspaceManager.selectedWorkspaceId else { return }
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelectionState.selection = .tabs
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.workspaceId] as? UUID,
                  workspaceId == workspaceManager.selectedWorkspaceId else { return }
            completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: workspaceId, reason: "focus")
            attemptCommandPaletteFocusRestoreIfNeeded()
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onChange(of: titlebarThemeGeneration) { oldValue, newValue in
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.workspaceId] as? UUID,
                  workspaceId == workspaceManager.selectedWorkspaceId else { return }
            completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: workspaceId, reason: "first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedWorkspaceId = workspaceManager.selectedWorkspaceId,
                  let selectedWorkspace = workspaceManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: selectedWorkspaceId, reason: "browser_first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedWorkspaceId = workspaceManager.selectedWorkspaceId,
                  let selectedWorkspace = workspaceManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  selectedWorkspace.browserPanel(for: panelId) != nil else { return }
            completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: selectedWorkspaceId, reason: "browser_address_bar")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )) { _ in
            attemptCommandPaletteFocusRestoreIfNeeded()
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
            guard commandPalettePendingTextSelectionBehavior != nil else { return }
            guard let editor = notification.object as? NSTextView,
                  editor.isFieldEditor else { return }
            guard let observedWindow else { return }
            guard editor.window === observedWindow else { return }
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onChange(of: isCommandPaletteSearchFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onChange(of: isCommandPaletteRenameFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onReceive(workspaceManager.$workspaces) { workspaces in
            let existingIds = Set(workspaces.map { $0.id })
            if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                self.retiringWorkspaceId = nil
                workspaceHandoffFallbackTask?.cancel()
                workspaceHandoffFallbackTask = nil
            }
            if let previousSelectedWorkspaceId, !existingIds.contains(previousSelectedWorkspaceId) {
                self.previousSelectedWorkspaceId = workspaceManager.selectedWorkspaceId
            }
            workspaceManager.pruneBackgroundWorkspaceLoads(existingIds: existingIds)
            reconcileMountedWorkspaceIds(workspaces: workspaces)
            selectedWorkspaceIds = selectedWorkspaceIds.filter { existingIds.contains($0) }
            if selectedWorkspaceIds.isEmpty, let selectedId = workspaceManager.selectedWorkspaceId {
                selectedWorkspaceIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= workspaces.count {
                if let selectedId = workspaceManager.selectedWorkspaceId {
                    lastSidebarSelectionIndex = workspaces.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(workspaces: workspaces)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
            let workspaceId = SidebarDragLifecycleNotification.workspaceId(from: notification)
            sidebarDraggedWorkspaceId = workspaceId
#if DEBUG
            dlog(
                "sidebar.dragState.content tab=\(debugShortWorkspaceId(workspaceId)) " +
                "reason=\(SidebarDragLifecycleNotification.reason(from: notification))"
            )
#endif
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            toggleCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteCommands()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteSwitcher()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteSubmitRequest()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            dismissCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenamePanelRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenamePanelInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameWorkspaceInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .commands = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            moveCommandPaletteSelection(by: delta)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteRenameInputInteraction()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            presentFeedbackComposer()
        })

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            MainActor.assumeIsolated {
                let overlayController = commandPaletteWindowOverlayController(for: window)
                overlayController.update(rootView: AnyView(commandPaletteOverlay), isVisible: isCommandPalettePresented)
            }
        }))

        view = AnyView(view.onChange(of: bgGlassTintHex) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onChange(of: bgGlassTintOpacity) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = true
            setTitlebarControlsHidden(true, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            setTitlebarControlsHidden(false, in: window)
            AppDelegate.shared?.fullscreenControlsViewModel = nil
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
            updateSidebarResizerBandState()
            updateTitlebarPadding(from: window)
        })

        view = AnyView(view.onChange(of: sidebarWidth) { _ in
            let sanitized = normalizedSidebarWidth(sidebarWidth)
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
                return
            }
            // Sidebar width changes are pure SwiftUI layout updates, so portal-hosted
            // terminals need an explicit post-layout geometry resync.
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow, trigger: "sidebarWidthChange")
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows(trigger: "sidebarWidthChange")
            }
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _ in
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow, trigger: "sidebarVisibilityChange")
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows(trigger: "sidebarVisibilityChange")
            }
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.persistedWidth) { newValue in
            let sanitized = normalizedSidebarWidth(newValue)
            guard !isResizerDragging else { return }
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
            }
        })

        view = AnyView(view.ignoresSafeArea())
        view = AnyView(view.sheet(isPresented: $isFeedbackComposerPresented) {
            SidebarFeedbackComposerSheet()
        })

        view = AnyView(view.onDisappear {
            if isResizerDragging {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                isResizerDragging = false
                sidebarDragStartWidth = nil
            }
            removeSidebarResizerPointerMonitor()
        })

        view = AnyView(view.background(WindowAccessor { [sidebarBlendMode, bgGlassEnabled, bgGlassTintHex, bgGlassTintOpacity] window in
            let didChangeChrome = applyMainWindowChrome(to: window)
            if didChangeChrome {
                performMainWindowLayoutPass(for: window)
            }

            // Track this window for fullscreen notifications
            if observedWindow !== window {
                DispatchQueue.main.async {
                    observedWindow = window
                    isFullScreen = window.styleMask.contains(.fullScreen)
                    clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
                    syncCommandPaletteDebugStateForObservedWindow()
                    installSidebarResizerPointerMonitorIfNeeded()
                    updateSidebarResizerBandState()
                }
            }
            scheduleInitialMainWindowGeometryReconcile(for: window)

            updateTitlebarPadding(from: window)
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
                UpdateLogStore.shared.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
            }
#endif
            // Background glass: skip on macOS 26+ where NSGlassEffectView can cause blank
            // or incorrectly tinted SwiftUI content. Keep native window rendering there so
            // Ghostty theme colors remain authoritative.
            let currentThemeBackground = GhosttyBackgroundTheme.currentColor()
            let shouldApplyWindowGlassFallback =
                sidebarBlendMode == SidebarBlendModeOption.behindWindow.rawValue
                && bgGlassEnabled
                && !WindowGlassEffect.isAvailable
            let shouldForceTransparentHosting =
                shouldApplyWindowGlassFallback || currentThemeBackground.alphaComponent < 0.999

            if shouldForceTransparentHosting {
                window.isOpaque = false
                // Keep the window clear whenever translucency is active. Relying only on
                // terminal focus-driven updates can leave stale opaque window fills.
                window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
                // Configure contentView hierarchy for transparency.
                if let contentView = window.contentView {
                    makeViewHierarchyTransparent(contentView)
                }
            } else {
                // Browser-focused workspaces may not have an active terminal panel to refresh
                // the NSWindow background. Keep opaque theme changes applied here as well.
                window.backgroundColor = currentThemeBackground
                window.isOpaque = currentThemeBackground.alphaComponent >= 0.999
            }

            if shouldApplyWindowGlassFallback {
                // Apply liquid glass effect to the window with tint from settings
                let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
                WindowGlassEffect.apply(to: window, tintColor: tintColor)
            }
            AppDelegate.shared?.applyMainWindowSizeConstraints(to: window)
            AppDelegate.shared?.attachUpdateAccessory(to: window)
            AppDelegate.shared?.applyWindowDecorations(to: window)
            AppDelegate.shared?.registerMainWindow(
                window,
                windowId: windowId,
                workspaceManager: workspaceManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState
            )
            installFileDropOverlay(on: window, workspaceManager: workspaceManager)
        }))

        // c11 (C11H-197): the AppKit title follows a rename (the accessor above
        // runs once per window).
        view = AnyView(view.onChange(of: windowName) { _, _ in
            guard let observedWindow, observedWindow.title != desiredWindowTitle else { return }
            observedWindow.title = desiredWindowTitle
        })

        // c11 (C11H-197): every view in this window paints its chrome with the
        // window's theme override (nil follows the app theme).
        view = AnyView(view.environment(\.c11WindowThemeName, windowThemeName))

        return view
    }

    private func reconcileMountedWorkspaceIds(
        workspaces: [Workspace]? = nil,
        selectedId: UUID? = nil,
        pendingBackgroundIds: Set<UUID>? = nil,
        debugPinnedIds: Set<UUID>? = nil
    ) {
        let currentTabs = workspaces ?? workspaceManager.workspaces
        let orderedWorkspaceIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? workspaceManager.selectedWorkspaceId
        let isCycleHot = workspaceManager.isWorkspaceCycleHot
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: mountedWorkspaceIds,
            selected: effectiveSelectedId,
            retiring: retiringWorkspaceId,
            pendingBackgroundIds: pendingBackgroundIds ?? workspaceManager.pendingBackgroundWorkspaceLoadIds,
            debugPinnedIds: debugPinnedIds ?? workspaceManager.debugPinnedWorkspaceLoadIds,
            orderedWorkspaceIds: orderedWorkspaceIds,
            isCycleHot: isCycleHot
        )
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            let removed = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
#if DEBUG
            if let snapshot = workspaceManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removed))"
                )
            } else {
                dlog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
#endif
            if let signpostID = workspaceManager.currentSwitchSignpostID {
                WorkspaceSwitchSignpost.event(
                    signpostID,
                    "mount.reconcile",
                    "mounted=\(mountedWorkspaceIds.count) +\(added.count) -\(removed.count) hot=\(isCycleHot ? 1 : 0)"
                )
            }
        }
    }

    private enum BackgroundWorkspacePrimeState {
        case pending
        case completed(reason: String)
    }

    private enum BackgroundWorkspacePrimePolicy {
        static let timeoutSeconds: TimeInterval = 2.0
    }

    private func primeBackgroundWorkspaceIfNeeded(workspaceId: UUID) async {
        let shouldPrime = await MainActor.run {
            workspaceManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId)
        }
        guard shouldPrime else { return }

#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        dlog("workspace.backgroundPrime.start workspace=\(workspaceId.uuidString.prefix(5))")
#endif

        let initialState = await MainActor.run {
            stepBackgroundWorkspacePrime(workspaceId: workspaceId)
        }
        let completionReason: String
        switch initialState {
        case .completed(let reason):
            completionReason = reason
        case .pending:
            completionReason = await waitForBackgroundWorkspacePrimeCompletion(
                workspaceId: workspaceId,
                timeoutSeconds: BackgroundWorkspacePrimePolicy.timeoutSeconds
            )
        }
#if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        dlog(
            "workspace.backgroundPrime.finish workspace=\(workspaceId.uuidString.prefix(5)) " +
            "reason=\(completionReason) ms=\(String(format: "%.2f", elapsedMs))"
        )
#endif
    }

    @MainActor
    private func stepBackgroundWorkspacePrime(workspaceId: UUID) -> BackgroundWorkspacePrimeState {
        guard workspaceManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return .completed(reason: "already_cleared")
        }
        guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
            workspaceManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: "workspace_removed")
        }

        workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
        guard workspace.hasLoadedTerminalSurface() else {
            return .pending
        }

        workspaceManager.completeBackgroundWorkspaceLoad(for: workspaceId)
        return .completed(reason: "surface_ready")
    }

    @MainActor
    private func waitForBackgroundWorkspacePrimeCompletion(
        workspaceId: UUID,
        timeoutSeconds: TimeInterval
    ) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resolved = false
            var workspacePanelsCancellable: AnyCancellable?
            var pendingLoadsCancellable: AnyCancellable?
            var workspacesCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?
            var timeoutWorkItem: DispatchWorkItem?

            @MainActor
            func finish(_ reason: String) {
                guard !resolved else { return }
                resolved = true
                workspacePanelsCancellable?.cancel()
                pendingLoadsCancellable?.cancel()
                workspacesCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                timeoutWorkItem?.cancel()
                continuation.resume(returning: reason)
            }

            @MainActor
            func evaluate() {
                switch stepBackgroundWorkspacePrime(workspaceId: workspaceId) {
                case .pending:
                    break
                case .completed(let reason):
                    finish(reason)
                }
            }

            if let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) {
                workspacePanelsCancellable = workspace.$panels
                    .map { _ in () }
                    .sink { _ in
                        Task { @MainActor in
                            evaluate()
                        }
                    }
            }

            pendingLoadsCancellable = workspaceManager.$pendingBackgroundWorkspaceLoadIds
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }

            workspacesCancellable = workspaceManager.$workspaces
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }

            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { notification in
                guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      readyWorkspaceId == workspaceId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { notification in
                guard let hostedWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      hostedWorkspaceId == workspaceId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            let timeoutWork = DispatchWorkItem {
                Task { @MainActor in
                    if workspaceManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) {
                        workspaceManager.completeBackgroundWorkspaceLoad(for: workspaceId)
                    }
                    finish("timeout")
                }
            }
            timeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            Task { @MainActor in
                evaluate()
            }
        }
    }

    private func addTab() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.presentCreateWorkspaceSheet()
        } else {
            workspaceManager.addTab()
        }
        sidebarSelectionState.selection = .tabs
    }

    private func makeViewHierarchyTransparent(_ root: NSView) {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
            stack.append(contentsOf: view.subviews)
        }
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private var desiredWindowTitle: String {
        windowName ?? ""
    }

    @discardableResult
    private func applyMainWindowChrome(to window: NSWindow) -> Bool {
        var didChange = false

        let identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        if window.identifier != identifier {
            window.identifier = identifier
            didChange = true
        }

        // c11 (C11H-197): the window's name is its AppKit title, so the Window
        // menu and Mission Control list it; the title itself stays hidden.
        if window.title != desiredWindowTitle {
            window.title = desiredWindowTitle
            didChange = true
        }

        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
            didChange = true
        }

        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
            didChange = true
        }

        // Do not make the entire background draggable; it interferes with drag gestures
        // like sidebar tab reordering in multi-window mode.
        if window.isMovableByWindowBackground {
            window.isMovableByWindowBackground = false
            didChange = true
        }

        // Keep the window immovable by default so titlebar controls (like the folder icon)
        // cannot accidentally initiate native window drags.
        if window.isMovable {
            window.isMovable = false
            didChange = true
        }

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
            didChange = true
        }

        return didChange
    }

    private func performMainWindowLayoutPass(for window: NSWindow) {
        applyMainWindowChrome(to: window)
        window.contentView?.superview?.needsLayout = true
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func reconcileMainWindowGeometry(for window: NSWindow) {
        performMainWindowLayoutPass(for: window)

        let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
        clampSidebarWidthIfNeeded(availableWidth: availableWidth)
        updateSidebarResizerBandState()
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window, trigger: "mainWindowGeometryReconcile")

        updateTitlebarPadding(from: window)
    }

    private func scheduleInitialMainWindowGeometryReconcile(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &initialMainWindowGeometryReconcileKey) == nil else { return }
        objc_setAssociatedObject(
            window,
            &initialMainWindowGeometryReconcileKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        // First launch can apply full-size content chrome after SwiftUI's first layout,
        // especially when AppKit restores/moves the window between displays.
        performMainWindowLayoutPass(for: window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            reconcileMainWindowGeometry(for: window)
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                reconcileMainWindowGeometry(for: window)
            }
        }
    }

    private func updateTitlebarPadding(from window: NSWindow) {
        // Keep content below the titlebar so drags on Bonsplit's tab bar don't
        // get interpreted as window drags.
        let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let nextPadding = max(28, min(72, computedTitlebarHeight))
        guard abs(titlebarPadding - nextPadding) > 0.5 else { return }
        DispatchQueue.main.async {
            titlebarPadding = nextPadding
        }
    }

    private func setTitlebarControlsHidden(_ hidden: Bool, in window: NSWindow) {
        let controlsId = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
        for accessory in window.titlebarAccessoryViewControllers {
            if accessory.view.identifier == controlsId {
                accessory.isHidden = hidden
                accessory.view.alphaValue = hidden ? 0 : 1
            }
        }
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            workspaceManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
            return
        }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        retiringWorkspaceId = oldSelectedId
        workspaceHandoffFallbackTask?.cancel()

#if DEBUG
        if let snapshot = workspaceManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.start id=\(snapshot.id) dt=\(debugMsText(dtMs)) old=\(debugShortWorkspaceId(oldSelectedId)) " +
                "new=\(debugShortWorkspaceId(newSelectedId))"
            )
        } else {
            dlog(
                "ws.handoff.start id=none old=\(debugShortWorkspaceId(oldSelectedId)) new=\(debugShortWorkspaceId(newSelectedId))"
            )
        }
#endif
        if let signpostID = workspaceManager.currentSwitchSignpostID {
            WorkspaceSwitchSignpost.event(
                signpostID,
                "handoff.start",
                "old=\(oldSelectedId.uuidString.prefix(5)) " +
                "new=\(newSelectedId.uuidString.prefix(5))"
            )
        }

        if canCompleteWorkspaceHandoffImmediately(for: newSelectedId) {
#if DEBUG
            if let snapshot = workspaceManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newSelectedId))"
                )
            } else {
                dlog("ws.handoff.fastReady id=none selected=\(debugShortWorkspaceId(newSelectedId))")
            }
#endif
            if let signpostID = workspaceManager.currentSwitchSignpostID {
                WorkspaceSwitchSignpost.event(
                    signpostID,
                    "handoff.fastReady",
                    "selected=\(newSelectedId.uuidString.prefix(5))"
                )
            }
            completeWorkspaceHandoff(reason: "ready")
            return
        }

        workspaceHandoffFallbackTask = Task { [generation] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard workspaceHandoffGeneration == generation else { return }
                completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: UUID, reason: String) {
        guard focusedWorkspaceId == workspaceManager.selectedWorkspaceId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspaceId: UUID) -> Bool {
        guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else { return true }
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Hide portal-hosted views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Hiding here prevents stale terminal/browser
        // portals from covering the newly selected workspace.
        if let retiring, let workspace = workspaceManager.workspaces.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
            workspace.hideAllBrowserPortalViews()
        }

        retiringWorkspaceId = nil
        workspaceManager.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        if let snapshot = workspaceManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(debugMsText(dtMs)) reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))"
            )
        } else {
            dlog("ws.handoff.complete id=none reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))")
        }
#endif
        if let signpostID = workspaceManager.currentSwitchSignpostID {
            WorkspaceSwitchSignpost.event(
                signpostID,
                "handoff.complete",
                "reason=\(reason) retiring=\(String(retiring?.uuidString.prefix(5) ?? "nil"))"
            )
        }
    }

    private var commandPaletteOverlay: some View {
        GeometryReader { proxy in
            let maxAllowedWidth = max(340, proxy.size.width - 260)
            let targetWidth = min(560, maxAllowedWidth)

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleCommandPaletteBackdropClick(atContentPoint: value.location)
                            }
                    )

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("CommandPaletteBackdrop")

                VStack(spacing: 0) {
                    switch commandPaletteMode {
                    case .commands:
                        commandPaletteCommandListView
                    case .renameInput(let target):
                        commandPaletteRenameInputView(target: target)
                    case let .renameConfirm(target, proposedName):
                        commandPaletteRenameConfirmView(target: target, proposedName: proposedName)
                    }
                }
                .frame(width: targetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            dismissCommandPalette()
        }
        .zIndex(2000)
    }

    private var commandPaletteCommandListView: some View {
        let visibleResults = commandPaletteVisibleResults
        let selectedIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        let commandPaletteListIdentity = "\(commandPaletteListScope.rawValue):\(commandPaletteQuery)"
        let commandPaletteListMaxHeight: CGFloat = 450
        let commandPaletteRowHeight: CGFloat = 24
        let commandPaletteEmptyStateHeight: CGFloat = 44
        let commandPaletteListContentHeight = visibleResults.isEmpty
            ? commandPaletteEmptyStateHeight
            : CGFloat(visibleResults.count) * commandPaletteRowHeight
        let commandPaletteListHeight = min(commandPaletteListMaxHeight, commandPaletteListContentHeight)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                CommandPaletteSearchFieldRepresentable(
                    placeholder: commandPaletteSearchPlaceholder,
                    text: $commandPaletteQuery,
                    isFocused: Binding(
                        get: { isCommandPaletteSearchFocused },
                        set: { isCommandPaletteSearchFocused = $0 }
                    ),
                    onSubmit: runSelectedCommandPaletteResult,
                    onEscape: { dismissCommandPalette() },
                    onMoveSelection: moveCommandPaletteSelection(by:)
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                // Rebuild the full results container on scope/query transitions so
                // stale switcher rows cannot linger above command-mode results.
                VStack(spacing: 0) {
                    if visibleResults.isEmpty {
                        if commandPaletteShouldShowEmptyState {
                            Text(commandPaletteEmptyStateText)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: commandPaletteEmptyStateHeight)
                        }
                    } else {
                        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                            let isSelected = index == selectedIndex
                            let isHovered = commandPaletteHoveredResultIndex == index
                            let rowBackground: Color = isSelected
                                ? cmuxAccentColor().opacity(0.12)
                                : (isHovered ? Color.primary.opacity(0.08) : .clear)

                            Button {
                                runCommandPaletteResult(commandID: result.id)
                            } label: {
                                HStack(spacing: 8) {
                                    commandPaletteHighlightedTitleText(
                                        result.command.title,
                                        matchedIndices: result.titleMatchIndices
                                    )
                                        .font(.system(size: 13, weight: .regular))
                                        .lineLimit(1)
                                    Spacer()

                                    if let trailingLabel = commandPaletteTrailingLabel(for: result.command) {
                                        switch trailingLabel.style {
                                        case .shortcut:
                                            Text(trailingLabel.text)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        case .kind:
                                            Text(trailingLabel.text)
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowBackground)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("CommandPaletteResultRow.\(index)")
                            .accessibilityValue(result.id)
                            .id(index)
                            .onHover { hovering in
                                if hovering {
                                    commandPaletteHoveredResultIndex = index
                                } else if commandPaletteHoveredResultIndex == index {
                                    commandPaletteHoveredResultIndex = nil
                                }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .id(commandPaletteListIdentity)
            .frame(height: commandPaletteListHeight)
            .scrollPosition(
                id: Binding(
                    get: { commandPaletteScrollTargetIndex },
                    // Ignore passive readback so manual scrolling doesn't mutate selection-follow state.
                    set: { _ in }
                ),
                anchor: commandPaletteScrollTargetAnchor
            )
            .onChange(of: commandPaletteSelectedResultIndex) { _ in
                updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: true)
            }

            // Keep Esc-to-close behavior without showing footer controls.
            Button(action: { dismissCommandPalette() }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            commandPaletteHoveredResultIndex = nil
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            resetCommandPaletteSearchFocus()
        }
        .onChange(of: commandPaletteQuery) { oldValue, newValue in
            commandPaletteSelectedResultIndex = 0
            commandPaletteSelectionAnchorCommandID = nil
            commandPaletteHoveredResultIndex = nil
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            if Self.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: oldValue,
                newQuery: newValue,
                hasVisibleResults: commandPaletteVisibleResultsScope != nil
            ) {
                cachedCommandPaletteResults = []
                commandPaletteVisibleResults = []
                commandPaletteVisibleResultsScope = nil
                commandPaletteVisibleResultsFingerprint = nil
            }
            scheduleCommandPaletteResultsRefresh(query: newValue)
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteCurrentSearchFingerprint) { _ in
            Task { @MainActor in
                // Let the query-state transition settle first so the forced corpus refresh
                // cannot rebuild the old command list after deleting the ">" prefix.
                await Task.yield()
                scheduleCommandPaletteResultsRefresh(
                    query: commandPaletteQuery,
                    forceSearchCorpusRefresh: true
                )
                updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
                syncCommandPaletteDebugStateForObservedWindow()
            }
        }
        .onChange(of: commandPaletteResultsRevision) { _ in
            let resultIDs = cachedCommandPaletteResults.map(\.id)
            commandPaletteSelectedResultIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                resultIDs: resultIDs
            )
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            let visibleResultCount = commandPaletteVisibleResults.count
            updateCommandPaletteScrollTarget(resultCount: visibleResultCount, animated: false)
            if let hoveredIndex = commandPaletteHoveredResultIndex, hoveredIndex >= visibleResultCount {
                commandPaletteHoveredResultIndex = nil
            }
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteSelectedResultIndex) { _ in
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private func commandPaletteRenameInputView(target: CommandPaletteRenameTarget) -> some View {
        VStack(spacing: 0) {
            TextField(target.placeholder, text: $commandPaletteRenameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                .focused($isCommandPaletteRenameFocused)
                .accessibilityIdentifier("CommandPaletteRenameField")
                .backport.onKeyPress(.delete) { modifiers in
                    handleCommandPaletteRenameDeleteBackward(modifiers: modifiers)
                }
                .onSubmit {
                    continueRenameFlow(target: target)
                }
                .onTapGesture {
                    handleCommandPaletteRenameInputInteraction()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text(renameInputHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                continueRenameFlow(target: target)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            resetCommandPaletteRenameFocus()
        }
    }

    private func commandPaletteRenameConfirmView(
        target: CommandPaletteRenameTarget,
        proposedName: String
    ) -> some View {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName.isEmpty ? String(localized: "commandPalette.rename.clearCustomName", defaultValue: "(clear custom name)") : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text(renameConfirmHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                applyRenameFlow(target: target, proposedName: proposedName)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private final class CommandPaletteNativeTextField: NSTextField {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func keyDown(with event: NSEvent) {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                super.keyDown(with: event)
                return
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return super.performKeyEquivalent(with: event)
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    // Keep navigation on the AppKit field editor so deleting the ">" prefix
    // cannot drop the palette's arrow-key handlers during the scope switch.
    private struct CommandPaletteSearchFieldRepresentable: NSViewRepresentable {
        let placeholder: String
        @Binding var text: String
        @Binding var isFocused: Bool
        let onSubmit: () -> Void
        let onEscape: () -> Void
        let onMoveSelection: (Int) -> Void

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: CommandPaletteSearchFieldRepresentable
            var isProgrammaticMutation = false
            weak var parentField: CommandPaletteNativeTextField?
            var pendingFocusRequest: Bool?
            var editorTextDidChangeObserver: NSObjectProtocol?
            weak var observedEditor: NSTextView?

            init(parent: CommandPaletteSearchFieldRepresentable) {
                self.parent = parent
            }

            deinit {
                detachEditorTextDidChangeObserver()
            }

            func controlTextDidChange(_ obj: Notification) {
                guard !isProgrammaticMutation else { return }
                guard let field = obj.object as? NSTextField else { return }
                parent.text = field.stringValue
            }

            func controlTextDidBeginEditing(_ obj: Notification) {
                if let field = obj.object as? NSTextField,
                   let editor = field.currentEditor() as? NSTextView {
                    attachEditorTextDidChangeObserverIfNeeded(editor)
                }
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func controlTextDidEndEditing(_ obj: Notification) {
                detachEditorTextDidChangeObserver()
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)):
                    parent.onMoveSelection(1)
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    parent.onMoveSelection(-1)
                    return true
                case #selector(NSResponder.insertNewline(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onEscape()
                    return true
                default:
                    return false
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: event.modifierFlags,
                    chars: event.characters ?? event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode
                ) {
                    parent.onMoveSelection(delta)
                    return true
                }

                if shouldSubmitCommandPaletteWithReturn(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags
                ) {
                    parent.onSubmit()
                    return true
                }

                if event.keyCode == 53,
                   event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])
                    .isEmpty {
                    parent.onEscape()
                    return true
                }

                return false
            }

            func attachEditorTextDidChangeObserverIfNeeded(_ editor: NSTextView) {
                if observedEditor !== editor {
                    detachEditorTextDidChangeObserver()
                }
                guard editorTextDidChangeObserver == nil else { return }
                observedEditor = editor
                editorTextDidChangeObserver = NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: editor,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, !self.isProgrammaticMutation else { return }
                    self.parent.text = editor.string
                }
            }

            func detachEditorTextDidChangeObserver() {
                if let editorTextDidChangeObserver {
                    NotificationCenter.default.removeObserver(editorTextDidChangeObserver)
                    self.editorTextDidChangeObserver = nil
                }
                observedEditor = nil
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteNativeTextField {
            let field = CommandPaletteNativeTextField(frame: .zero)
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = placeholder
            field.setAccessibilityIdentifier("CommandPaletteSearchField")
            field.delegate = context.coordinator
            field.stringValue = text
            field.isEditable = true
            field.isSelectable = true
            field.isEnabled = true
            field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            context.coordinator.parentField = field
            return field
        }

        func updateNSView(_ nsView: CommandPaletteNativeTextField, context: Context) {
            context.coordinator.parent = self
            context.coordinator.parentField = nsView
            nsView.placeholderString = placeholder

            if let editor = nsView.currentEditor() as? NSTextView {
                context.coordinator.attachEditorTextDidChangeObserverIfNeeded(editor)
                if editor.string != text, !editor.hasMarkedText() {
                    context.coordinator.isProgrammaticMutation = true
                    editor.string = text
                    nsView.stringValue = text
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if nsView.stringValue != text {
                context.coordinator.detachEditorTextDidChangeObserver()
                nsView.stringValue = text
            } else {
                context.coordinator.detachEditorTextDidChangeObserver()
            }

            guard let window = nsView.window else { return }
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView

            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let coordinator, coordinator.parent.isFocused else { return }
                    guard let nsView, let window = nsView.window else { return }
                    let firstResponder = window.firstResponder
                    let alreadyFocused =
                        firstResponder === nsView ||
                        nsView.currentEditor() != nil ||
                        ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard !alreadyFocused else { return }
                    window.makeFirstResponder(nsView)
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteNativeTextField, coordinator: Coordinator) {
            nsView.delegate = nil
            nsView.onHandleKeyEvent = nil
            coordinator.detachEditorTextDidChangeObserver()
            coordinator.parentField = nil
        }
    }

    private func renameInputHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceInputHint", defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel.")
        case .panel:
            return String(localized: "commandPalette.rename.tabInputHint", defaultValue: "Type a panel name. Press Enter to rename, Escape to cancel.")
        }
    }

    private func renameConfirmHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.")
        case .panel:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to rename the panel. Press Escape to cancel.")
        }
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        Self.commandPaletteListScope(for: commandPaletteQuery)
    }

    private var commandPaletteCurrentSearchFingerprint: Int {
        let scope = commandPaletteListScope
        return commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries,
            commandsContext: scope == .commands ? commandPaletteCachedCommandsContext() : nil
        )
    }

    nonisolated private static func commandPaletteListScope(for query: String) -> CommandPaletteListScope {
        if query.hasPrefix(Self.commandPaletteCommandsPrefix) {
            return .commands
        }
        return .switcher
    }

    static func commandPaletteShouldResetVisibleResultsForQueryTransition(
        oldQuery: String,
        newQuery: String,
        hasVisibleResults: Bool
    ) -> Bool {
        hasVisibleResults && commandPaletteListScope(for: oldQuery) != commandPaletteListScope(for: newQuery)
    }

    private var commandPaletteSwitcherIncludesSurfaceEntries: Bool {
        Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: commandPaletteQuery
        )
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherPlaceholderAllSurfaces", defaultValue: "Search workspaces and panels")
                : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherEmptyAllSurfaces", defaultValue: "No workspaces or panels match.")
                : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search.")
        }
    }

    private var commandPaletteQueryForMatching: String {
        Self.commandPaletteQueryForMatching(
            query: commandPaletteQuery,
            scope: commandPaletteListScope
        )
    }

    nonisolated private static func commandPaletteRefreshQuery(
        stateQuery: String,
        observedQuery: String?
    ) -> String {
        observedQuery ?? stateQuery
    }

    nonisolated static func commandPaletteRefreshInputsForTests(
        stateQuery: String,
        observedQuery: String?,
        searchAllSurfaces: Bool
    ) -> (scope: String, matchingQuery: String, includesSurfaces: Bool) {
        let effectiveQuery = commandPaletteRefreshQuery(
            stateQuery: stateQuery,
            observedQuery: observedQuery
        )
        let scope = commandPaletteListScope(for: effectiveQuery)
        return (
            scope: scope.rawValue,
            matchingQuery: commandPaletteQueryForMatching(query: effectiveQuery, scope: scope),
            includesSurfaces: commandPaletteSwitcherIncludesSurfaceEntries(
                searchAllSurfaces: searchAllSurfaces,
                query: effectiveQuery
            )
        )
    }

    nonisolated private static func commandPaletteQueryForMatching(
        query: String,
        scope: CommandPaletteListScope
    ) -> String {
        switch scope {
        case .commands:
            let suffix = String(query.dropFirst(Self.commandPaletteCommandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func commandPaletteEntries(for scope: CommandPaletteListScope) -> [CommandPaletteCommand] {
        commandPaletteEntries(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntries(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> [CommandPaletteCommand] {
        switch scope {
        case .commands:
            return commandPaletteCommands(commandsContext: commandsContext ?? commandPaletteCachedCommandsContext())
        case .switcher:
            return commandPaletteSwitcherEntries(includeSurfaces: includeSurfaces)
        }
    }

    nonisolated private static func commandPaletteSwitcherIncludesSurfaceEntries(
        searchAllSurfaces: Bool,
        query: String
    ) -> Bool {
        let scope = commandPaletteListScope(for: query)
        guard scope == .switcher else { return false }
        return searchAllSurfaces && !commandPaletteQueryForMatching(query: query, scope: scope).isEmpty
    }

    private func refreshCommandPaletteSearchCorpus(
        force: Bool = false,
        query: String? = nil
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let includeSurfaces = Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: effectiveQuery
        )
        let terminalOpenTargets = resolveCommandPaletteTerminalOpenTargets(for: scope)
        if commandPaletteTerminalOpenTargetAvailability != terminalOpenTargets {
            commandPaletteTerminalOpenTargetAvailability = terminalOpenTargets
        }
        let commandsContext = scope == .commands
            ? commandPaletteCommandsContext(terminalOpenTargets: terminalOpenTargets)
            : nil
        let fingerprint = commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        guard force || cachedCommandPaletteScope != scope || cachedCommandPaletteFingerprint != fingerprint else {
            return
        }

        let entries = commandPaletteEntries(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        commandPaletteSearchCommandsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let searchCorpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        commandPaletteSearchCorpus = searchCorpus
        commandPaletteSearchCorpusByID = Dictionary(uniqueKeysWithValues: searchCorpus.map { ($0.payload, $0) })
        cachedCommandPaletteScope = scope
        cachedCommandPaletteFingerprint = fingerprint
    }

    private func cancelCommandPaletteSearch() {
        commandPaletteSearchTask?.cancel()
        commandPaletteSearchTask = nil
    }

    nonisolated private static func commandPaletteResolvedSearchMatches(
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [CommandPaletteResolvedSearchMatch] {
        let results = CommandPaletteSearchEngine.search(
            entries: searchCorpus,
            query: query,
            historyBoost: { commandId, _ in
                Self.commandPaletteHistoryBoost(
                    for: commandId,
                    queryIsEmpty: queryIsEmpty,
                    history: usageHistory,
                    now: historyTimestamp
                )
            },
            shouldCancel: shouldCancel
        )

        return results.map { result in
            CommandPaletteResolvedSearchMatch(
                commandID: result.payload,
                score: result.score,
                titleMatchIndices: result.titleMatchIndices
            )
        }
    }

    private static func commandPaletteMaterializedSearchResults(
        matches: [CommandPaletteResolvedSearchMatch],
        commandsByID: [String: CommandPaletteCommand]
    ) -> [CommandPaletteSearchResult] {
        matches.compactMap { match in
            guard let command = commandsByID[match.commandID] else { return nil }
            return CommandPaletteSearchResult(
                command: command,
                score: match.score,
                titleMatchIndices: match.titleMatchIndices
            )
        }
    }

    private func setCommandPaletteVisibleResults(
        _ results: [CommandPaletteSearchResult],
        scope: CommandPaletteListScope,
        fingerprint: Int?
    ) {
        commandPaletteVisibleResults = results
        commandPaletteVisibleResultsScope = scope
        commandPaletteVisibleResultsFingerprint = fingerprint
    }

    private func refreshPendingCommandPaletteVisibleResults(
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval
    ) {
        let candidateCommandIDs: [String]
        if commandPaletteVisibleResultsScope == scope,
           commandPaletteVisibleResultsFingerprint == fingerprint {
            candidateCommandIDs = Self.commandPalettePreviewCandidateCommandIDs(
                resultIDs: commandPaletteVisibleResults.map(\.id),
                limit: Self.commandPaletteVisiblePreviewCandidateLimit
            )
        } else {
            candidateCommandIDs = []
        }

        let previewMatches = Self.commandPalettePreviewSearchMatches(
            scope: scope,
            searchCorpus: commandPaletteSearchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: commandPaletteSearchCorpusByID,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp,
            resultLimit: Self.commandPaletteVisiblePreviewResultLimit
        )
        let previewResults = Self.commandPaletteMaterializedSearchResults(
            matches: previewMatches,
            commandsByID: commandPaletteSearchCommandsByID
        )
        setCommandPaletteVisibleResults(
            previewResults,
            scope: scope,
            fingerprint: fingerprint
        )
    }

    nonisolated private static func commandPalettePreviewSearchMatches(
        scope: CommandPaletteListScope,
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval,
        resultLimit: Int
    ) -> [CommandPaletteResolvedSearchMatch] {
        guard resultLimit > 0 else {
            return []
        }

        if scope == .commands {
            let matches = commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: query,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp
            )
            guard matches.count > resultLimit else {
                return matches
            }
            return Array(matches.prefix(resultLimit))
        }

        guard !candidateCommandIDs.isEmpty else {
            return []
        }

        var seenCommandIDs: Set<String> = []
        let previewEntries: [CommandPaletteSearchCorpusEntry<String>] = candidateCommandIDs.compactMap { commandID in
            guard seenCommandIDs.insert(commandID).inserted else { return nil }
            return searchCorpusByID[commandID]
        }
        guard !previewEntries.isEmpty else {
            return []
        }

        let matches = commandPaletteResolvedSearchMatches(
            searchCorpus: previewEntries,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp
        )
        guard matches.count > resultLimit else {
            return matches
        }
        return Array(matches.prefix(resultLimit))
    }

    nonisolated static func commandPaletteCommandPreviewMatchCommandIDsForTests(
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        resultLimit: Int
    ) -> [String] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        return commandPalettePreviewSearchMatches(
            scope: .commands,
            searchCorpus: searchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: searchCorpusByID,
            query: query,
            usageHistory: [:],
            queryIsEmpty: preparedQuery.isEmpty,
            historyTimestamp: 0,
            resultLimit: resultLimit
        ).map(\.commandID)
    }

    static func commandPalettePreviewCandidateCommandIDs(
        resultIDs: [String],
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        guard resultIDs.count > limit else { return resultIDs }
        return Array(resultIDs.prefix(limit))
    }

    static func commandPaletteShouldSynchronouslySeedResults(
        hasVisibleResultsForScope: Bool
    ) -> Bool {
        !hasVisibleResultsForScope
    }

    static func commandPaletteShouldPreserveEmptyStateWhileSearchPending(
        isSearchPending: Bool,
        visibleResultsScopeMatches: Bool,
        resolvedSearchScopeMatches: Bool,
        resolvedSearchFingerprintMatches: Bool,
        resolvedResultsAreEmpty: Bool,
        currentMatchingQuery: String,
        resolvedMatchingQuery: String
    ) -> Bool {
        guard isSearchPending,
              visibleResultsScopeMatches,
              resolvedSearchScopeMatches,
              resolvedSearchFingerprintMatches,
              resolvedResultsAreEmpty else {
            return false
        }

        return currentMatchingQuery == resolvedMatchingQuery
            || currentMatchingQuery.hasPrefix(resolvedMatchingQuery)
    }

    private func scheduleCommandPaletteResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let matchingQuery = Self.commandPaletteQueryForMatching(
            query: effectiveQuery,
            scope: scope
        )

        refreshCommandPaletteSearchCorpus(
            force: forceSearchCorpusRefresh,
            query: effectiveQuery
        )

        commandPaletteSearchRequestID &+= 1
        let requestID = commandPaletteSearchRequestID
        let fingerprint = cachedCommandPaletteFingerprint
        let searchCorpus = commandPaletteSearchCorpus
        let commandsByID = commandPaletteSearchCommandsByID
        let usageHistory = commandPaletteUsageHistoryByCommandId
        let queryIsEmpty = CommandPaletteFuzzyMatcher.preparedQuery(matchingQuery).isEmpty
        let historyTimestamp = Date().timeIntervalSince1970
        commandPalettePendingActivation = nil; commandPalettePendingOrigin = nil
        cancelCommandPaletteSearch()
        if Self.commandPaletteShouldSynchronouslySeedResults(
            hasVisibleResultsForScope: commandPaletteVisibleResultsScope == scope
        ) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp
            )
            cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                matches: matches,
                commandsByID: commandsByID
            )
            commandPaletteResolvedSearchRequestID = requestID
            commandPaletteResolvedSearchScope = scope
            commandPaletteResolvedSearchFingerprint = fingerprint
            commandPaletteResolvedMatchingQuery = matchingQuery
            isCommandPaletteSearchPending = false
            setCommandPaletteVisibleResults(
                cachedCommandPaletteResults,
                scope: scope,
                fingerprint: fingerprint
            )
            commandPaletteResultsRevision &+= 1
            return
        }
        refreshPendingCommandPaletteVisibleResults(
            scope: scope,
            fingerprint: fingerprint,
            query: matchingQuery,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp
        )
        isCommandPaletteSearchPending = true

        commandPaletteSearchTask = Task.detached(priority: .userInitiated) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                shouldCancel: { Task.isCancelled }
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = Self.commandPaletteListScope(for: commandPaletteQuery)
                guard commandPaletteSearchRequestID == requestID,
                      isCommandPalettePresented,
                      currentScope == scope,
                      Self.commandPaletteQueryForMatching(
                          query: commandPaletteQuery,
                          scope: currentScope
                      ) == matchingQuery,
                      cachedCommandPaletteFingerprint == fingerprint else {
                    return
                }

                cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                    matches: matches,
                    commandsByID: commandPaletteSearchCommandsByID
                )
                let resultIDs = cachedCommandPaletteResults.map(\.id)
                let pendingActivation = commandPalettePendingActivation
                let pendingOrigin = commandPalettePendingOrigin
                let resolvedActivation = Self.commandPaletteResolvedPendingActivation(
                    pendingActivation,
                    requestID: requestID,
                    resultIDs: resultIDs
                )
                commandPaletteResolvedSearchRequestID = requestID
                commandPaletteResolvedSearchScope = scope
                commandPaletteResolvedSearchFingerprint = fingerprint
                commandPaletteResolvedMatchingQuery = matchingQuery
                isCommandPaletteSearchPending = false
                setCommandPaletteVisibleResults(
                    cachedCommandPaletteResults,
                    scope: scope,
                    fingerprint: fingerprint
                )
                if Self.commandPalettePendingActivationRequestID(pendingActivation) == requestID {
                    commandPalettePendingActivation = nil
                    commandPalettePendingOrigin = nil
                }
                commandPaletteResultsRevision &+= 1
                if commandPaletteSearchRequestID == requestID {
                    commandPaletteSearchTask = nil
                }
                if let resolvedActivation {
                    SocketCommandContext.withContext(pendingOrigin) {
                        runCommandPaletteResolvedActivation(resolvedActivation)
                    }
                }
            }
        }
    }

    private func commandPaletteEntriesFingerprint(for scope: CommandPaletteListScope) -> Int {
        commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntriesFingerprint(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> Int {
        switch scope {
        case .commands:
            return commandPaletteCommandsFingerprint(
                commandsContext: commandsContext ?? commandPaletteCachedCommandsContext()
            )
        case .switcher:
            return commandPaletteSwitcherEntriesFingerprint(includeSurfaces: includeSurfaces)
        }
    }

    private func commandPaletteCommandsFingerprint(commandsContext: CommandPaletteCommandsContext) -> Int {
        commandsContext.snapshot.fingerprint()
    }

    private func commandPaletteSwitcherEntriesFingerprint(includeSurfaces: Bool) -> Int {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        let fingerprintContexts = windowContexts.map { context in
            CommandPaletteSwitcherFingerprintContext(
                windowId: context.windowId,
                windowLabel: context.windowLabel,
                selectedWorkspaceId: context.selectedWorkspaceId,
                workspaces: commandPaletteOrderedSwitcherWorkspaces(for: context).map { workspace in
                    CommandPaletteSwitcherFingerprintWorkspace(
                        id: workspace.id,
                        displayName: workspaceDisplayName(workspace),
                        metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                        surfaces: includeSurfaces
                            ? commandPaletteOrderedSwitcherPanels(for: workspace).compactMap { panelId in
                                guard let panel = workspace.panels[panelId] else { return nil }
                                return CommandPaletteSwitcherFingerprintPanel(
                                    id: panelId,
                                    displayName: panelDisplayName(
                                        workspace: workspace,
                                        panelId: panelId,
                                        fallback: panel.displayTitle
                                    ),
                                    kindLabel: commandPaletteSurfaceKindLabel(for: panel.panelType),
                                    metadata: commandPaletteSurfaceSearchMetadata(
                                        for: workspace,
                                        panelId: panelId
                                    )
                                )
                            }
                            : []
                    )
                }
            )
        }
        return Self.commandPaletteSwitcherFingerprint(windowContexts: fingerprintContexts)
    }

    private func commandPaletteHighlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(.primary)
        }

        // Build a flat AttributedString rather than accumulating Text + Text.
        // Repeated `result = result + Text(...)` produces a recursive
        // ConcatenatedTextStorage tree whose `resolve` is depth-N recursive;
        // a highly fragmented match pattern (long title, alternating runs)
        // blows the render-thread stack at SwiftUI resolve time (C11-26).
        let chars = Array(title)
        var index = 0
        var attributed = AttributedString()

        while index < chars.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < chars.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            var run = AttributedString(String(chars[index..<end]))
            run.foregroundColor = isMatched ? .blue : .primary
            attributed.append(run)
            index = end
        }

        return Text(attributed)
    }

    private func commandPaletteTrailingLabel(for command: CommandPaletteCommand) -> CommandPaletteTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        if let kindLabel = command.kindLabel {
            return CommandPaletteTrailingLabel(text: kindLabel, style: .kind)
        }
        return nil
    }

    private func commandPaletteSwitcherEntries(includeSurfaces: Bool) -> [CommandPaletteCommand] {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        guard !windowContexts.isEmpty else { return [] }

        var entries: [CommandPaletteCommand] = []
        let estimatedCount = windowContexts.reduce(0) { partial, context in
            let workspaceCount = context.workspaceManager.workspaces.count
            guard includeSurfaces else { return partial + workspaceCount }
            let surfaceCount = context.workspaceManager.workspaces.reduce(0) { count, workspace in
                count + commandPaletteOrderedSwitcherPanels(for: workspace).count
            }
            return partial + workspaceCount + surfaceCount
        }
        entries.reserveCapacity(estimatedCount)
        var nextRank = 0

        for context in windowContexts {
            let workspaces = commandPaletteOrderedSwitcherWorkspaces(for: context)
            guard !workspaces.isEmpty else { continue }

            let windowId = context.windowId
            let windowWorkspaceManager = context.workspaceManager
            let windowKeywords = commandPaletteWindowKeywords(windowLabel: context.windowLabel)
            for workspace in workspaces {
                let workspaceName = workspaceDisplayName(workspace)
                let workspaceCommandId = "switcher.workspace.\(workspace.id.uuidString.lowercased())"
                let workspaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                    baseKeywords: [
                        "workspace",
                        "switch",
                        "go",
                        "open",
                        workspaceName
                    ] + windowKeywords,
                    metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                    detail: .workspace
                )
                let workspaceId = workspace.id
                entries.append(
                    CommandPaletteCommand(
                        id: workspaceCommandId,
                        rank: nextRank,
                        title: workspaceName,
                        subtitle: commandPaletteSwitcherSubtitle(base: String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace"), windowLabel: context.windowLabel),
                        shortcutHint: nil,
                        kindLabel: String(localized: "commandPalette.kind.workspace", defaultValue: "Workspace"),
                        keywords: workspaceKeywords,
                        dismissOnRun: true,
                        action: {
                            focusCommandPaletteSwitcherTarget(
                                windowId: windowId,
                                workspaceManager: windowWorkspaceManager,
                                workspaceId: workspaceId
                            )
                        }
                    )
                )
                nextRank += 1

                guard includeSurfaces else { continue }

                for panelId in commandPaletteOrderedSwitcherPanels(for: workspace) {
                    guard let panel = workspace.panels[panelId] else { continue }
                    let panelName = panelDisplayName(
                        workspace: workspace,
                        panelId: panelId,
                        fallback: panel.displayTitle
                    )
                    let surfaceKindLabel = commandPaletteSurfaceKindLabel(for: panel.panelType)
                    let surfaceCommandId = "switcher.surface.\(panelId.uuidString.lowercased())"
                    let surfaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
                        baseKeywords: [
                            "surface",
                            "panel",
                            "tab",
                            "switch",
                            "go",
                            "open",
                            panelName,
                            workspaceName
                        ] + commandPaletteSurfaceKeywords(for: panel.panelType) + windowKeywords,
                        metadata: commandPaletteSurfaceSearchMetadata(for: workspace, panelId: panelId),
                        detail: .surface
                    )
                    entries.append(
                        CommandPaletteCommand(
                            id: surfaceCommandId,
                            rank: nextRank,
                            title: panelName,
                            subtitle: commandPaletteSwitcherSubtitle(base: workspaceName, windowLabel: context.windowLabel),
                            shortcutHint: nil,
                            kindLabel: surfaceKindLabel,
                            keywords: surfaceKeywords,
                            dismissOnRun: true,
                            action: {
                                focusCommandPaletteSwitcherSurfaceTarget(
                                    windowId: windowId,
                                    workspaceManager: windowWorkspaceManager,
                                    workspaceId: workspace.id,
                                    panelId: panelId
                                )
                            }
                        )
                    )
                    nextRank += 1
                }
            }
        }

        return entries
    }

    private func commandPaletteSwitcherWindowContexts() -> [CommandPaletteSwitcherWindowContext] {
        let fallback = CommandPaletteSwitcherWindowContext(
            windowId: windowId,
            workspaceManager: workspaceManager,
            selectedWorkspaceId: workspaceManager.selectedWorkspaceId,
            windowLabel: nil
        )

        guard let appDelegate = AppDelegate.shared else { return [fallback] }
        let summaries = appDelegate.listMainWindowSummaries()
        guard !summaries.isEmpty else { return [fallback] }

        let orderedSummaries = summaries.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.windowId == windowId
            let rhsIsCurrent = rhs.windowId == windowId
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        var windowLabelById: [UUID: String] = [:]
        if orderedSummaries.count > 1 {
            for (index, summary) in orderedSummaries.enumerated() where summary.windowId != windowId {
                windowLabelById[summary.windowId] = String(localized: "commandPalette.switcher.windowLabel", defaultValue: "Window \(index + 1)")
            }
        }

        var contexts: [CommandPaletteSwitcherWindowContext] = []
        var seenWindowIds: Set<UUID> = []
        for summary in orderedSummaries {
            guard let manager = appDelegate.workspaceManagerFor(windowId: summary.windowId) else { continue }
            guard seenWindowIds.insert(summary.windowId).inserted else { continue }
            contexts.append(
                CommandPaletteSwitcherWindowContext(
                    windowId: summary.windowId,
                    workspaceManager: manager,
                    selectedWorkspaceId: summary.selectedWorkspaceId,
                    windowLabel: windowLabelById[summary.windowId]
                )
            )
        }

        if contexts.isEmpty {
            return [fallback]
        }
        return contexts
    }

    private func commandPaletteSwitcherSubtitle(base: String, windowLabel: String?) -> String {
        guard let windowLabel else { return base }
        return "\(base) • \(windowLabel)"
    }

    private func commandPaletteWindowKeywords(windowLabel: String?) -> [String] {
        guard let windowLabel else { return [] }
        return ["window", windowLabel.lowercased()]
    }

    private func commandPaletteOrderedSwitcherWorkspaces(
        for context: CommandPaletteSwitcherWindowContext
    ) -> [Workspace] {
        var workspaces = context.workspaceManager.workspaces
        guard !workspaces.isEmpty else { return [] }

        let selectedWorkspaceId = context.selectedWorkspaceId ?? context.workspaceManager.selectedWorkspaceId
        if let selectedWorkspaceId,
           let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
            let selectedWorkspace = workspaces.remove(at: selectedIndex)
            workspaces.insert(selectedWorkspace, at: 0)
        }

        return workspaces
    }

    private func commandPaletteOrderedSwitcherPanels(for workspace: Workspace) -> [UUID] {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        guard orderedPanelIds.count < workspace.panels.count else { return orderedPanelIds }

        var panelIds = orderedPanelIds
        var seen = Set(orderedPanelIds)
        for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seen.insert(panelId).inserted {
            panelIds.append(panelId)
        }
        return panelIds
    }

    private func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        workspaceManager: WorkspaceManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        workspaceManager.focusPaletteSwitcherTarget(windowId: windowId, workspaceId: workspaceId)
    }

    private func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        workspaceManager: WorkspaceManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        workspaceManager.focusPaletteSwitcherTarget(windowId: windowId, workspaceId: workspaceId, surfaceId: panelId)
    }

    private func commandPaletteWorkspaceSearchMetadata(for workspace: Workspace) -> CommandPaletteSwitcherSearchMetadata {
        // Keep workspace rows coarse and stable for predictable workspace switching queries.
        let directories = [workspace.currentDirectory]
        let branches = [workspace.gitBranch?.branch].compactMap { $0 }
        let ports = workspace.listeningPorts
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPaletteSurfaceSearchMetadata(
        for workspace: Workspace,
        panelId: UUID
    ) -> CommandPaletteSwitcherSearchMetadata {
        let directories = [workspace.panelDirectories[panelId]].compactMap { $0 }
        let branches = [workspace.panelGitBranches[panelId]?.branch].compactMap { $0 }
        let ports = workspace.panelListeningPorts[panelId] ?? []
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }

    private func commandPaletteSurfaceKindLabel(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal:
            return String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "commandPalette.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "commandPalette.kind.markdown", defaultValue: "Markdown")
        }
    }

    private func commandPaletteSurfaceKeywords(for panelType: PanelType) -> [String] {
        switch panelType {
        case .terminal:
            return ["terminal", "shell", "console"]
        case .browser:
            return ["browser", "web", "page"]
        case .markdown:
            return ["markdown", "note", "preview"]
        }
    }

    private func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteTerminalOpenTargetAvailability
        )
    }

    private func resolveCommandPaletteTerminalOpenTargets(
        for scope: CommandPaletteListScope
    ) -> Set<TerminalDirectoryOpenTarget> {
        guard scope == .commands,
              focusedPanelContext?.panel.panelType == .terminal else {
            return []
        }
        // C11-196: cached. The uncached probe issues one synchronous
        // LaunchServices XPC round trip per editor it cannot find on disk, and
        // this runs on every command-palette keystroke.
        return TerminalDirectoryOpenTarget.availableTargetsCached()
    }

    private func commandPaletteCommandsContext(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>
    ) -> CommandPaletteCommandsContext {
        let cliInstalledInPATH = AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false
        var snapshot = commandPaletteContextSnapshot(terminalOpenTargets: terminalOpenTargets)
        snapshot.setBool(CommandPaletteContextKeys.cliInstalledInPATH, cliInstalledInPATH)
        return CommandPaletteCommandsContext(
            snapshot: snapshot
        )
    }

    private func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: contribution.title(context),
                    subtitle: contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution, context: context),
                    kindLabel: nil,
                    keywords: contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteShortcutHint(
        for contribution: CommandPaletteCommandContribution,
        context: CommandPaletteContextSnapshot
    ) -> String? {
        // Preserve browser reload semantics for Cmd+R when a browser tab is focused.
        if contribution.commandId == "palette.renameTab",
           context.bool(CommandPaletteContextKeys.panelIsBrowser) {
            return nil
        }
        if let action = commandPaletteShortcutAction(for: contribution.commandId) {
            return KeyboardShortcutSettings.shortcut(for: action).displayString
        }
        if let staticShortcut = commandPaletteStaticShortcutHint(for: contribution.commandId) {
            return staticShortcut
        }
        return contribution.shortcutHint
    }

    private func commandPaletteShortcutAction(for commandId: String) -> KeyboardShortcutSettings.Action? {
        switch commandId {
        case "palette.newWorkspace":
            return .newWorkspace
        case "palette.newWindow":
            return .newWindow
        case "palette.openFolder":
            return .openFolder
        case "palette.newTerminalTab":
            return .newSurface
        case "palette.newBrowserTab":
            return .openBrowser
        case "palette.closeWindow":
            return .closeWindow
        case "palette.toggleSidebar":
            return .toggleSidebar
        case "palette.showNotifications":
            return .showNotifications
        case "palette.jumpUnread":
            return .jumpToUnread
        case "palette.renameTab":
            return .renamePanel
        case "palette.renameWorkspace":
            return .renameWorkspace
        case "palette.nextWorkspace":
            return .nextSidebarWorkspace
        case "palette.previousWorkspace":
            return .prevSidebarWorkspace
        case "palette.nextTabInPane":
            return .nextSurface
        case "palette.previousTabInPane":
            return .prevSurface
        case "palette.browserToggleDevTools":
            return .toggleBrowserDeveloperTools
        case "palette.browserConsole":
            return .showBrowserJavaScriptConsole
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
        case "palette.toggleSplitZoom":
            return .toggleSplitZoom
        case "palette.triggerFlash":
            return .triggerFlash
        case "palette.globalFontIncrease":
            return .globalFontIncrease
        case "palette.globalFontDecrease":
            return .globalFontDecrease
        case "palette.globalFontReset":
            return .globalFontReset
        default:
            return nil
        }
    }

    private func commandPaletteStaticShortcutHint(for commandId: String) -> String? {
        switch commandId {
        case "palette.closeTab":
            return "⌘W"
        case "palette.closeWorkspace":
            return "⌘⇧W"
        case "palette.reopenClosedBrowserTab":
            return "⌘⇧T"
        case "palette.openSettings":
            return "⌘,"
        case "palette.browserBack":
            return "⌘["
        case "palette.browserForward":
            return "⌘]"
        case "palette.browserReload":
            return "⌘R"
        case "palette.browserFocusAddressBar":
            return "⌘L"
        case "palette.browserZoomIn":
            return "⌘="
        case "palette.browserZoomOut":
            return "⌘-"
        case "palette.browserZoomReset":
            return "⌘0"
        case "palette.terminalFind":
            return "⌘F"
        case "palette.terminalFindNext":
            return "⌘G"
        case "palette.terminalFindPrevious":
            return "⌘⇧G"
        case "palette.terminalHideFind":
            return "⌘⇧F"
        case "palette.terminalUseSelectionForFind":
            return "⌘E"
        case "palette.toggleFullScreen":
            return "\u{2303}\u{2318}F"
        default:
            return nil
        }
    }

    private func commandPaletteContextSnapshot(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>? = nil
    ) -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.workspaceMinimalModeEnabled, isMinimalMode)

        if let workspace = workspaceManager.selectedWorkspace {
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, !workspace.isPinned)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasPullRequests,
                !workspace.sidebarPullRequestsInDisplayOrder().isEmpty
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasSplits,
                workspace.bonsplitController.allPaneIds.count > 1
            )
            // C11H-342: Move Up/Down enable from the sidebar step they perform;
            // Move to Top keeps its flat rule.
            for (key, value) in WorkspaceSidebarStepPalette.context(workspaceManager) { snapshot.setBool(key, value) }
            snapshot.setBool(CommandPaletteContextKeys.workspaceCanMoveToTop,
                             (workspaceManager.workspaces.firstIndex { $0.id == workspace.id } ?? 0) > 0)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasUnread,
                notificationStore.notifications.contains { $0.workspaceId == workspace.id && !$0.isRead }
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasRead,
                notificationStore.notifications.contains { $0.workspaceId == workspace.id && $0.isRead }
            )
        }

        if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(
                CommandPaletteContextKeys.panelName,
                panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle)
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            let hasUnread = workspace.manualUnreadPanelIds.contains(panelId)
                || notificationStore.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: panelId)
            snapshot.setBool(CommandPaletteContextKeys.panelHasUnread, hasUnread)

            if panelIsTerminal {
                let availableTargets = terminalOpenTargets ?? TerminalDirectoryOpenTarget.availableTargetsCached()
                for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
                    snapshot.setBool(
                        CommandPaletteContextKeys.terminalOpenTargetAvailable(target),
                        availableTargets.contains(target)
                    )
                }
            }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            snapshot.setBool(CommandPaletteContextKeys.updateHasAvailable, true)
        }

        return snapshot
    }

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
            return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Panel")
            return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Panel • \(name)")
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Panel")
            return String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(name)")
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Panel")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")),
                subtitle: constant(String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(String(localized: "command.newWindow.title", defaultValue: "New Window")),
                subtitle: constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window")),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'c11' in PATH")),
                subtitle: constant(String(localized: "command.installCLI.subtitle", defaultValue: "CLI")),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'c11' from PATH")),
                subtitle: constant(String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(String(localized: "command.openFolder.title", defaultValue: "Open Folder…")),
                subtitle: constant(String(localized: "command.openFolder.subtitle", defaultValue: "Workspace")),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Panel")),
                subtitle: constant(String(localized: "command.newTerminalTab.subtitle", defaultValue: "Panel")),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "panel", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant(String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Panel")),
                subtitle: constant(String(localized: "command.newBrowserTab.subtitle", defaultValue: "Panel")),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "panel", "tab", "web"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.surfaceDetails",
                title: constant(String(localized: "command.surfaceDetails.title", defaultValue: "Panel Details")),
                subtitle: panelSubtitle,
                keywords: ["surface", "details", "manifest", "metadata", "id", "number", "panel", "tab"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(String(localized: "command.closeTab.title", defaultValue: "Close Panel")),
                subtitle: constant(String(localized: "command.closeTab.subtitle", defaultValue: "Panel")),
                shortcutHint: "⌘W",
                keywords: ["close", "panel", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace")),
                subtitle: constant(String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace")),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(String(localized: "command.closeWindow.title", defaultValue: "Close Window")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")),
                subtitle: constant(String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window")),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant(String(localized: "command.reopenClosedBrowserTab.title", defaultValue: "Reopen Closed Browser Panel")),
                subtitle: constant(String(localized: "command.reopenClosedBrowserTab.subtitle", defaultValue: "Browser")),
                shortcutHint: "⌘⇧T",
                keywords: ["reopen", "closed", "browser"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(String(localized: "command.toggleSidebar.title", defaultValue: "Toggle Sidebar")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["toggle", "sidebar", "layout"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Area")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(String(localized: "command.showNotifications.title", defaultValue: "Show Notifications")),
                subtitle: constant(String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications")),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(String(localized: "command.openSettings.title", defaultValue: "Open Settings")),
                subtitle: constant(String(localized: "command.openSettings.subtitle", defaultValue: "Global")),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")),
                subtitle: constant(String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global")),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)")),
                subtitle: constant(String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global")),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update")),
                subtitle: constant(String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener")),
                subtitle: constant(String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global")),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant(String(localized: "command.renameWorkspace.title", defaultValue: "Rename Workspace…")),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant(String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? String(localized: "command.pinWorkspace.title", defaultValue: "Pin Workspace") : String(localized: "command.unpinWorkspace.title", defaultValue: "Unpin Workspace")
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant(String(localized: "command.nextWorkspace.title", defaultValue: "Next Workspace")),
                subtitle: constant(String(localized: "command.nextWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant(String(localized: "command.previousWorkspace.title", defaultValue: "Previous Workspace")),
                subtitle: constant(String(localized: "command.previousWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: WorkspaceSidebarStepPalette.moveUpCommandId,
                title: constant(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "up", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: WorkspaceSidebarStepPalette.moveDownCommandId,
                title: constant(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "down", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceToTop",
                title: constant(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "top", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanMoveToTop) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceRead",
                title: constant(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "read", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasUnread) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceUnread",
                title: constant(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "unread", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasRead) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant(String(localized: "command.renameTab.title", defaultValue: "Rename Panel…")),
                subtitle: panelSubtitle,
                keywords: ["rename", "panel", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant(String(localized: "command.clearTabName.title", defaultValue: "Clear Panel Name")),
                subtitle: panelSubtitle,
                keywords: ["clear", "panel", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? String(localized: "command.pinTab.title", defaultValue: "Pin Panel") : String(localized: "command.unpinTab.title", defaultValue: "Unpin Panel")
                },
                subtitle: panelSubtitle,
                keywords: ["panel", "tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? String(localized: "command.markTabRead.title", defaultValue: "Mark Panel as Read") : String(localized: "command.markTabUnread.title", defaultValue: "Mark Panel as Unread")
                },
                subtitle: panelSubtitle,
                keywords: ["panel", "tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(String(localized: "command.nextTabInPane.title", defaultValue: "Next Panel in Area")),
                subtitle: constant(String(localized: "command.nextTabInPane.subtitle", defaultValue: "Panel Navigation")),
                keywords: ["next", "panel", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(String(localized: "command.previousTabInPane.title", defaultValue: "Previous Panel in Area")),
                subtitle: constant(String(localized: "command.previousTabInPane.subtitle", defaultValue: "Panel Navigation")),
                keywords: ["previous", "panel", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant(String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links")),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    $0.bool(CommandPaletteContextKeys.workspaceHasPullRequests)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserBack",
                title: constant(String(localized: "command.browserBack.title", defaultValue: "Back")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant(String(localized: "command.browserForward.title", defaultValue: "Forward")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant(String(localized: "command.browserReload.title", defaultValue: "Reload Page")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant(String(localized: "command.browserOpenDefault.title", defaultValue: "Open Current Page in Default Browser")),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant(String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant(String(localized: "command.browserToggleDevTools.title", defaultValue: "Toggle Developer Tools")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant(String(localized: "command.browserConsole.title", defaultValue: "Show JavaScript Console")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant(String(localized: "command.browserZoomIn.title", defaultValue: "Zoom In")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant(String(localized: "command.browserZoomOut.title", defaultValue: "Zoom Out")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant(String(localized: "command.browserZoomReset.title", defaultValue: "Actual Size")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant(String(localized: "command.browserClearHistory.title", defaultValue: "Clear Browser History")),
                subtitle: constant(String(localized: "command.browserClearHistory.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant(String(localized: "command.browserSplitRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.browserSplitRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant(String(localized: "command.browserSplitDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.browserSplitDown.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant(String(localized: "command.browserDuplicateRight.title", defaultValue: "Duplicate Browser to the Right")),
                subtitle: constant(String(localized: "command.browserDuplicateRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "duplicate", "clone", "split"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebStop",
                title: constant(String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebRestart",
                title: constant(String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(String(localized: "command.terminalFind.title", defaultValue: "Find…")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(String(localized: "command.terminalFindNext.title", defaultValue: "Find Next")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")),
                subtitle: constant(String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")),
                subtitle: constant(String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant(String(localized: "command.terminalSplitBrowserRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant(String(localized: "command.terminalSplitBrowserDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Area Zoom")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.globalFontIncrease",
                title: constant(String(localized: "command.globalFontIncrease.title", defaultValue: "Increase Font Size (All Terminals)")),
                subtitle: constant(String(localized: "command.globalFont.subtitle", defaultValue: "Terminal Font")),
                keywords: ["font", "size", "increase", "bigger", "zoom", "all", "global", "terminal"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.globalFontDecrease",
                title: constant(String(localized: "command.globalFontDecrease.title", defaultValue: "Decrease Font Size (All Terminals)")),
                subtitle: constant(String(localized: "command.globalFont.subtitle", defaultValue: "Terminal Font")),
                keywords: ["font", "size", "decrease", "smaller", "zoom", "all", "global", "terminal"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.globalFontReset",
                title: constant(String(localized: "command.globalFontReset.title", defaultValue: "Reset Font Size (All Terminals)")),
                subtitle: constant(String(localized: "command.globalFont.subtitle", defaultValue: "Terminal Font")),
                keywords: ["font", "size", "reset", "default", "zoom", "all", "global", "terminal"]
            )
        )

        return contributions
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            workspaceManager.addWorkspace()
        }
        registry.register(commandId: "palette.openFolder") {
            // The workspace records who ran the command, not the modal's run loop (C11H-260).
            let creation = PanelLineage.shared.captureCreation()
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let openPanel = NSOpenPanel()
                openPanel.canChooseFiles = false
                openPanel.canChooseDirectories = true
                openPanel.allowsMultipleSelection = false
                openPanel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                openPanel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if openPanel.runModal() == .OK, let url = openPanel.url {
                    PanelLineage.shared.replay(creation) {
                        _ = workspaceManager.addWorkspace(workingDirectory: url.path)
                    }
                }
            }
        }
        registry.register(commandId: "palette.newWindow") {
            AppDelegate.shared?.openNewMainWindow(nil)
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            workspaceManager.newSurfaceAskingMachine()
        }
        registry.register(commandId: "palette.newBrowserTab") {
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            let creation = PanelLineage.shared.captureCreation()
            DispatchQueue.main.async {
                PanelLineage.shared.replay(creation) {
                    _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
                }
            }
        }
        registry.register(commandId: "palette.surfaceDetails") {
            guard let workspace = workspaceManager.selectedWorkspace,
                  let panelId = workspace.focusedPanelId,
                  let panel = workspace.panels[panelId] else {
                NSSound.beep()
                return
            }
            workspace.showSurfaceDetails(for: panel)
        }
        registry.register(commandId: "palette.closeTab") {
            workspaceManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            workspaceManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            if let appDelegate = AppDelegate.shared {
                appDelegate.closeWindowWithConfirmation(window)
            } else {
                window.performClose(nil)
            }
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            _ = workspaceManager.reopenMostRecentlyClosedBrowserPanel()
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registry.register(commandId: "palette.triggerFlash") {
            workspaceManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.operatorJumpToLatestUnread()
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            dlog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                dlog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = workspaceManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            workspaceManager.clearCustomTitle(workspaceId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = workspaceManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            workspaceManager.setPinned(workspace, pinned: !workspace.isPinned)
        }
        registry.register(commandId: "palette.nextWorkspace") {
            workspaceManager.selectNextWorkspace(cause: "palette")
            workspaceManager.acknowledgeOperatorOpen(workspaceId: workspaceManager.selectedWorkspaceId)
        }
        registry.register(commandId: "palette.previousWorkspace") {
            workspaceManager.selectPreviousWorkspace(cause: "palette")
            workspaceManager.acknowledgeOperatorOpen(workspaceId: workspaceManager.selectedWorkspaceId)
        }
        for command in WorkspaceSidebarStepPalette.commands {
            registry.register(commandId: command.commandId) { moveSelectedWorkspace(commandId: command.commandId) }
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = workspaceManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            workspaceManager.moveWorkspacesToTop([workspace.id])
            SocketCommandContext.withContext(nil) { workspaceManager.selectWorkspace(workspace, cause: "sidebar") }
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = workspaceManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forWorkspaceId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = workspaceManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forWorkspaceId: workspaceId)
        }

        registry.register(commandId: "palette.renameTab") {
            beginRenamePanelFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId)
                || notificationStore.hasUnreadNotification(forWorkspaceId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            workspaceManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            workspaceManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequestsInConfiguredBrowser() {
                    NSSound.beep()
                }
            }
        }

        registry.register(commandId: "palette.browserBack") {
            workspaceManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            workspaceManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            workspaceManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !workspaceManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !workspaceManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !workspaceManager.zoomInFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !workspaceManager.zoomOutFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !workspaceManager.resetZoomFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            BrowserHistoryStore.shared.clearHistory()
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = workspaceManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = workspaceManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = workspaceManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = workspaceManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.vscodeServeWebStop") {
            stopInlineVSCodeServeWeb()
        }
        registry.register(commandId: "palette.vscodeServeWebRestart") {
            if !restartInlineVSCodeServeWeb() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            workspaceManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            workspaceManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            workspaceManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            workspaceManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            workspaceManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            workspaceManager.createSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            workspaceManager.createSplit(direction: .down)
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = workspaceManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = workspaceManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !workspaceManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            guard let workspace = workspaceManager.selectedWorkspace,
                  workspaceManager.equalizeSplits(workspaceId: workspace.id) else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: "palette.globalFontIncrease") {
            GlobalTerminalFontSize.apply(.increase)
        }
        registry.register(commandId: "palette.globalFontDecrease") {
            GlobalTerminalFontSize.apply(.decrease)
        }
        registry.register(commandId: "palette.globalFontReset") {
            GlobalTerminalFontSize.apply(.reset)
        }
    }

    private var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = workspaceManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : title
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Panel") : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    static func commandPaletteResolvedSelectionIndex(
        preferredCommandID: String?,
        fallbackSelectedIndex: Int,
        resultIDs: [String]
    ) -> Int {
        guard !resultIDs.isEmpty else { return 0 }
        if let preferredCommandID,
           let anchoredIndex = resultIDs.firstIndex(of: preferredCommandID) {
            return anchoredIndex
        }
        return min(max(fallbackSelectedIndex, 0), resultIDs.count - 1)
    }

    static func commandPaletteSelectionAnchorCommandID(
        selectedIndex: Int,
        resultIDs: [String]
    ) -> String? {
        guard !resultIDs.isEmpty else { return nil }
        let resolvedIndex = min(max(selectedIndex, 0), resultIDs.count - 1)
        return resultIDs[resolvedIndex]
    }

    static func commandPalettePendingActivationRequestID(
        _ pendingActivation: CommandPalettePendingActivation?
    ) -> UInt64? {
        switch pendingActivation {
        case .selected(let requestID, _, _):
            return requestID
        case .command(let requestID, _):
            return requestID
        case nil:
            return nil
        }
    }

    static func commandPaletteResolvedPendingActivation(
        _ pendingActivation: CommandPalettePendingActivation?,
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPaletteResolvedActivation? {
        switch pendingActivation {
        case .selected(let activationRequestID, let fallbackSelectedIndex, let preferredCommandID):
            guard activationRequestID == requestID else { return nil }
            let resolvedIndex = commandPaletteResolvedSelectionIndex(
                preferredCommandID: preferredCommandID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                resultIDs: resultIDs
            )
            return .selected(index: resolvedIndex)
        case .command(let activationRequestID, let commandID):
            guard activationRequestID == requestID, resultIDs.contains(commandID) else { return nil }
            return .command(commandID: commandID)
        case nil:
            return nil
        }
    }

    static func commandPaletteContextFingerprint(
        boolValues: [String: Bool],
        stringValues: [String: String]
    ) -> Int {
        var hasher = Hasher()
        for key in boolValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(boolValues[key] ?? false)
        }
        for key in stringValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(stringValues[key] ?? "")
        }
        return hasher.finalize()
    }

    static func commandPaletteSwitcherFingerprint(
        windowContexts: [CommandPaletteSwitcherFingerprintContext]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(windowContexts.count)
        for context in windowContexts {
            hasher.combine(context.windowId)
            hasher.combine(context.windowLabel)
            hasher.combine(context.selectedWorkspaceId)
            hasher.combine(context.workspaces.count)
            for workspace in context.workspaces {
                hasher.combine(workspace.id)
                hasher.combine(workspace.displayName)
                combineCommandPaletteSwitcherSearchMetadata(workspace.metadata, into: &hasher)
                hasher.combine(workspace.surfaces.count)
                for surface in workspace.surfaces {
                    hasher.combine(surface.id)
                    hasher.combine(surface.displayName)
                    hasher.combine(surface.kindLabel)
                    combineCommandPaletteSwitcherSearchMetadata(surface.metadata, into: &hasher)
                }
            }
        }
        return hasher.finalize()
    }

    static func combineCommandPaletteSwitcherSearchMetadata(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        into hasher: inout Hasher
    ) {
        hasher.combine(metadata.directories.count)
        for directory in metadata.directories {
            hasher.combine(directory)
        }
        hasher.combine(metadata.branches.count)
        for branch in metadata.branches {
            hasher.combine(branch)
        }
        hasher.combine(metadata.ports.count)
        for port in metadata.ports {
            hasher.combine(port)
        }
    }

    static func commandPaletteScrollPositionAnchor(
        selectedIndex: Int,
        resultCount: Int
    ) -> UnitPoint? {
        guard resultCount > 0 else { return nil }
        if selectedIndex <= 0 {
            return UnitPoint.top
        }
        if selectedIndex >= resultCount - 1 {
            return UnitPoint.bottom
        }
        return nil
    }

    private func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        guard resultCount > 0 else {
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            commandPaletteScrollTargetIndex = selectedIndex
        }
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                assignTarget()
            }
        } else {
            assignTarget()
        }
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteSelectionAnchorCommandID = Self.commandPaletteSelectionAnchorCommandID(
            selectedIndex: commandPaletteSelectedResultIndex,
            resultIDs: resultIDs
        )
    }

    private func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: cachedCommandPaletteResults.map(\.id))
    }

    private func syncCommandPaletteSelectionAnchorFromVisibleResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: commandPaletteVisibleResults.map(\.id))
    }

    private func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteVisibleResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        if commandPaletteHasCurrentResolvedResults {
            syncCommandPaletteSelectionAnchorFromCurrentResults()
        } else {
            syncCommandPaletteSelectionAnchorFromVisibleResults()
        }
        syncCommandPaletteDebugStateForObservedWindow()
    }

    static func commandPaletteShouldPopRenameInputOnDelete(
        renameDraft: String,
        modifiers: EventModifiers
    ) -> Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }

    private func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteRenameDraft = editor.string
        } else if !commandPaletteRenameDraft.isEmpty {
            commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private var commandPaletteHasCurrentResolvedResults: Bool {
        !isCommandPaletteSearchPending && commandPaletteResolvedSearchRequestID == commandPaletteSearchRequestID
    }

    private var commandPaletteShouldShowEmptyState: Bool {
        guard commandPaletteVisibleResults.isEmpty else { return false }
        if commandPaletteHasCurrentResolvedResults {
            return true
        }

        return Self.commandPaletteShouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: isCommandPaletteSearchPending,
            visibleResultsScopeMatches: commandPaletteVisibleResultsScope == commandPaletteListScope,
            resolvedSearchScopeMatches: commandPaletteResolvedSearchScope == commandPaletteListScope,
            resolvedSearchFingerprintMatches: commandPaletteResolvedSearchFingerprint == commandPaletteVisibleResultsFingerprint,
            resolvedResultsAreEmpty: cachedCommandPaletteResults.isEmpty,
            currentMatchingQuery: commandPaletteQueryForMatching,
            resolvedMatchingQuery: commandPaletteResolvedMatchingQuery
        )
    }

    private func runCommandPaletteResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        switch activation {
        case .command(let commandID):
            guard let command = cachedCommandPaletteResults.first(where: { $0.id == commandID })?.command else {
                return
            }
            runCommandPaletteCommand(command)
        case .selected(let fallbackIndex):
            guard !cachedCommandPaletteResults.isEmpty else {
                NSSound.beep()
                return
            }
            let resolvedIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: fallbackIndex,
                resultIDs: cachedCommandPaletteResults.map(\.id)
            )
            commandPaletteSelectedResultIndex = resolvedIndex
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            runCommandPaletteCommand(cachedCommandPaletteResults[resolvedIndex].command)
        }
    }

    private func runCommandPaletteResult(commandID: String) {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .command(
                    requestID: commandPaletteSearchRequestID,
                    commandID: commandID
                )
                commandPalettePendingOrigin = SocketCommandContext.adoptForPaletteSession()
            }
            return
        }
        runCommandPaletteResolvedActivation(.command(commandID: commandID))
    }

    private func runSelectedCommandPaletteResult() {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .selected(
                    requestID: commandPaletteSearchRequestID,
                    fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                    preferredCommandID: commandPaletteSelectionAnchorCommandID
                )
                commandPalettePendingOrigin = SocketCommandContext.adoptForPaletteSession()
            }
            return
        }

        runCommandPaletteResolvedActivation(.selected(index: commandPaletteSelectedResultIndex))
    }

    private func handleCommandPaletteSubmitRequest() {
        switch commandPaletteMode {
        case .commands:
            runSelectedCommandPaletteResult()
        case .renameInput(let target):
            continueRenameFlow(target: target)
        case .renameConfirm(let target, let proposedName):
            applyRenameFlow(target: target, proposedName: proposedName)
        }
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
#if DEBUG
        dlog("palette.run commandId=\(command.id) dismissOnRun=\(command.dismissOnRun ? 1 : 0)")
#endif
        recordCommandPaletteUsage(command.id)
        SocketCommandContext.adoptForPaletteSession()
        // C11H-260: a palette command is the operator's, unless a socket drives the session.
        PanelLineage.shared.withOrigin(.operator) { command.action() }
        if command.dismissOnRun {
            dismissCommandPalette(restoreFocus: false)
        }
    }

    private func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
    }

    private func openCommandPaletteCommands() {
        handleCommandPaletteListRequest(scope: .commands)
    }

    private func openCommandPaletteSwitcher() {
        handleCommandPaletteListRequest(scope: .switcher)
    }

    private func handleCommandPaletteListRequest(scope: CommandPaletteListScope) {
        let initialQuery = (scope == .commands) ? Self.commandPaletteCommandsPrefix : ""
        guard isCommandPalettePresented else {
            presentCommandPalette(initialQuery: initialQuery)
            return
        }

        if case .commands = commandPaletteMode,
           commandPaletteListScope == scope {
            dismissCommandPalette()
            return
        }

        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func openCommandPaletteRenamePanelInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenamePanelFlow()
    }

    private func openCommandPaletteRenameWorkspaceInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameWorkspaceFlow()
    }

    private func presentFeedbackComposer() {
        DispatchQueue.main.async {
            isFeedbackComposerPresented = true
        }
    }

    static func shouldHandleCommandPaletteRequest(
        observedWindow: NSWindow?,
        requestedWindow: NSWindow?,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> Bool {
        guard let observedWindow else { return false }
        if let requestedWindow {
            return requestedWindow === observedWindow
        }
        if let keyWindow {
            return keyWindow === observedWindow
        }
        if let mainWindow {
            return mainWindow === observedWindow
        }
        return false
    }

    static func shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
        focusedPanelIsBrowser: Bool,
        focusedBrowserAddressBarPanelId: UUID?,
        focusedPanelId: UUID?
    ) -> Bool {
        focusedPanelIsBrowser && focusedBrowserAddressBarPanelId == focusedPanelId
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteVisibleResults.count
        let selectedIndex = isCommandPalettePresented ? commandPaletteSelectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(commandPaletteDebugSnapshot(), for: window)
    }

    private func commandPaletteDebugSnapshot() -> CommandPaletteDebugSnapshot {
        guard isCommandPalettePresented else { return .empty }

        let mode: String
        switch commandPaletteMode {
        case .commands:
            mode = commandPaletteListScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .renameConfirm:
            mode = "rename_confirm"
        }

        let rows = Array(commandPaletteVisibleResults.prefix(20)).map { result in
            CommandPaletteDebugResultRow(
                commandId: result.command.id,
                title: result.command.title,
                shortcutHint: result.command.shortcutHint,
                trailingLabel: commandPaletteTrailingLabel(for: result.command)?.text,
                score: result.score
            )
        }

        return CommandPaletteDebugSnapshot(
            query: commandPaletteQueryForMatching,
            mode: mode,
            results: rows
        )
    }

    private func presentCommandPalette(initialQuery: String) {
        if let panelContext = focusedPanelContext {
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: panelContext.panel.captureFocusIntent(in: observedWindow)
            )
        } else {
            commandPaletteRestoreFocusTarget = nil
        }
        isCommandPalettePresented = true
        refreshCommandPaletteUsageHistory()
        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteMode = .commands
        commandPaletteQuery = initialQuery
        commandPaletteRenameDraft = ""
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true)
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        dismissCommandPalette(restoreFocus: restoreFocus, preferredFocusTarget: nil)
    }

    private func dismissCommandPalette(
        restoreFocus: Bool,
        preferredFocusTarget: CommandPaletteRestoreFocusTarget?
    ) {
        let focusTarget = preferredFocusTarget ?? commandPaletteRestoreFocusTarget
        cancelCommandPaletteSearch()
        commandPaletteSearchRequestID &+= 1
        isCommandPalettePresented = false
        commandPaletteMode = .commands
        commandPaletteQuery = ""
        commandPaletteRenameDraft = ""
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        commandPaletteRestoreFocusTarget = nil
        commandPaletteSearchCorpus = []
        commandPaletteSearchCorpusByID = [:]
        commandPaletteSearchCommandsByID = [:]
        cachedCommandPaletteResults = []
        commandPaletteVisibleResults = []
        commandPaletteVisibleResultsScope = nil
        commandPaletteVisibleResultsFingerprint = nil
        cachedCommandPaletteScope = nil
        cachedCommandPaletteFingerprint = nil
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteResolvedSearchRequestID = commandPaletteSearchRequestID
        commandPaletteResolvedSearchScope = nil
        commandPaletteResolvedSearchFingerprint = nil
        commandPaletteTerminalOpenTargetAvailability = []
        isCommandPaletteSearchPending = false
        commandPalettePendingActivation = nil; commandPalettePendingOrigin = nil
        commandPaletteResultsRevision &+= 1
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        requestCommandPaletteFocusRestore(target: focusTarget)
    }

    private func handleCommandPaletteBackdropClick(atContentPoint contentPoint: CGPoint) {
        let clickedFocusTarget = commandPaletteBackdropFocusTarget(atContentPoint: contentPoint)
#if DEBUG
        if let clickedFocusTarget {
            dlog(
                "palette.dismiss.backdrop focusTarget panel=\(clickedFocusTarget.panelId.uuidString.prefix(5)) " +
                "workspace=\(clickedFocusTarget.workspaceId.uuidString.prefix(5)) intent=\(debugCommandPaletteFocusIntent(clickedFocusTarget.intent))"
            )
        } else {
            dlog("palette.dismiss.backdrop focusTarget=nil")
        }
#endif
        dismissCommandPalette(restoreFocus: true, preferredFocusTarget: clickedFocusTarget)
    }

    private func commandPaletteBackdropFocusTarget(atContentPoint contentPoint: CGPoint) -> CommandPaletteRestoreFocusTarget? {
        guard let window = observedWindow,
              let contentView = window.contentView else {
            return nil
        }

        let nsContentPoint = NSPoint(x: contentPoint.x, y: contentPoint.y)
        let windowPoint = contentView.convert(nsContentPoint, to: nil)
        return commandPaletteBackdropFocusTarget(atWindowPoint: windowPoint, in: window)
    }

    private func commandPaletteBackdropFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        let overlayController = commandPaletteWindowOverlayController(for: window)
        if let responder = overlayController.underlyingResponder(atWindowPoint: windowPoint),
           let target = commandPaletteBackdropFocusTarget(for: responder) {
            return target
        }

        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.workspaceId,
           let panelId = terminalView.terminalSurface?.id,
           workspaceManager.workspaces.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: window
            )
        }

        return nil
    }

    private func commandPaletteBackdropFocusTarget(for responder: NSResponder) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = cmuxOwningGhosttyView(for: responder),
           let workspaceId = terminalView.workspaceId,
           let panelId = terminalView.terminalSurface?.id,
           workspaceManager.workspaces.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: observedWindow
            )
        }

        if let webView = commandPaletteOwningWebView(for: responder),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(for webView: WKWebView) -> CommandPaletteRestoreFocusTarget? {
        if let selectedWorkspace = workspaceManager.selectedWorkspace,
           let target = commandPaletteBrowserFocusTarget(in: selectedWorkspace, for: webView) {
            return target
        }

        let selectedWorkspaceId = workspaceManager.selectedWorkspaceId
        for workspace in workspaceManager.workspaces where workspace.id != selectedWorkspaceId {
            if let target = commandPaletteBrowserFocusTarget(in: workspace, for: webView) {
                return target
            }
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(
        in workspace: Workspace,
        for webView: WKWebView
    ) -> CommandPaletteRestoreFocusTarget? {
        for (panelId, panel) in workspace.panels {
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.webView === webView else {
                continue
            }

            return commandPaletteRestoreFocusTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                fallbackIntent: .browser(.webView),
                in: observedWindow
            )
        }

        return nil
    }

    private func commandPaletteRestoreFocusTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent,
        in window: NSWindow?
    ) -> CommandPaletteRestoreFocusTarget {
        let intent = workspaceManager.workspaces
            .first(where: { $0.id == workspaceId })?
            .panels[panelId]?
            .captureFocusIntent(in: window) ?? fallbackIntent

        return CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        commandPalettePendingDismissFocusTarget = target
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        let timeoutWork = DispatchWorkItem {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem = nil
        }
        commandPaletteRestoreTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutWork)
        attemptCommandPaletteFocusRestoreIfNeeded()
    }

    private func attemptCommandPaletteFocusRestoreIfNeeded() {
        guard !isCommandPalettePresented else { return }
        guard let target = commandPalettePendingDismissFocusTarget else { return }
        guard workspaceManager.workspaces.contains(where: { $0.id == target.workspaceId }) else {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem?.cancel()
            commandPaletteRestoreTimeoutWorkItem = nil
            return
        }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        workspaceManager.focusWorkspace(target.workspaceId, surfaceId: target.panelId, suppressFlash: true, cause: "palette")

        guard let context = focusedPanelContext,
              context.workspace.id == target.workspaceId,
              context.panelId == target.panelId else {
            return
        }
        guard context.panel.restoreFocusIntent(target.intent) else { return }
        commandPalettePendingDismissFocusTarget = nil
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        commandPaletteRestoreTimeoutWorkItem = nil
    }

#if DEBUG
    private func debugCommandPaletteFocusIntent(_ intent: PanelFocusIntent) -> String {
        switch intent {
        case .panel:
            return "panel"
        case .terminal(.surface):
            return "terminal.surface"
        case .terminal(.findField):
            return "terminal.findField"
        case .browser(.webView):
            return "browser.webView"
        case .browser(.addressBar):
            return "browser.addressBar"
        case .browser(.findField):
            return "browser.findField"
        }
    }
#endif

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func handleCommandPaletteRenameInputInteraction() {
        guard isCommandPalettePresented else { return }
        guard case .renameInput = commandPaletteMode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        let selectAllOnFocus = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        let selectionBehavior: CommandPaletteTextSelectionBehavior = selectAllOnFocus
            ? .selectAll
            : .caretAtEnd
        return CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: selectionBehavior
        )
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(_ behavior: CommandPaletteTextSelectionBehavior) {
        commandPalettePendingTextSelectionBehavior = behavior
        attemptCommandPaletteTextSelectionIfNeeded()
    }

    private func attemptCommandPaletteTextSelectionIfNeeded() {
        guard isCommandPalettePresented else {
            commandPalettePendingTextSelectionBehavior = nil
            return
        }
        guard let behavior = commandPalettePendingTextSelectionBehavior else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteMode {
            case .commands, .renameInput:
                break
            case .renameConfirm:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else {
            return
        }
        let length = (editor.string as NSString).length
        switch behavior {
        case .selectAll:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .caretAtEnd:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        commandPalettePendingTextSelectionBehavior = nil
    }

    private func refreshCommandPaletteUsageHistory() {
        commandPaletteUsageHistoryByCommandId = loadCommandPaletteUsageHistory()
    }

    private func loadCommandPaletteUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.commandPaletteUsageDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistCommandPaletteUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandPaletteUsageDefaultsKey)
    }

    private func recordCommandPaletteUsage(_ commandId: String) {
        var history = commandPaletteUsageHistoryByCommandId
        var entry = history[commandId] ?? CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        history[commandId] = entry
        commandPaletteUsageHistoryByCommandId = history
        persistCommandPaletteUsageHistory(history)
    }

    nonisolated private static func commandPaletteHistoryBoost(
        for commandId: String,
        queryIsEmpty: Bool,
        history: [String: CommandPaletteUsageEntry],
        now: TimeInterval
    ) -> Int {
        guard let entry = history[commandId] else { return 0 }

        let ageDays = max(0, now - entry.lastUsedAt) / 86_400
        let recencyBoost = max(0, 320 - Int(ageDays * 20))
        let countBoost = min(180, entry.useCount * 12)
        let totalBoost = recencyBoost + countBoost

        return queryIsEmpty ? totalBoost : max(0, totalBoost / 3)
    }

    private func commandPaletteHistoryBoost(for commandId: String, queryIsEmpty: Bool) -> Int {
        Self.commandPaletteHistoryBoost(
            for: commandId,
            queryIsEmpty: queryIsEmpty,
            history: commandPaletteUsageHistoryByCommandId,
            now: Date().timeIntervalSince1970
        )
    }

    /// C11H-342: one sidebar step, as the menu, the row and the socket take.
    private func moveSelectedWorkspace(commandId: String) {
        guard let id = WorkspaceSidebarStepPalette.perform(commandId, on: workspaceManager),
              let workspace = workspaceManager.workspaces.first(where: { $0.id == id }) else { return }
        SocketCommandContext.withContext(nil) { workspaceManager.selectWorkspace(workspace, cause: "sidebar") }
    }

    private func syncSidebarSelectedWorkspaceIds() {
        workspaceManager.setSidebarSelectedWorkspaceIds(selectedWorkspaceIds)
    }

    private func applyUITestSidebarSelectionIfNeeded(workspaces: [Workspace]) {
#if DEBUG
        guard !didApplyUITestSidebarSelection else { return }
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return
        }

        var indices: [Int] = []
        for token in rawValue.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = Int(trimmed), index >= 0 else { return }
            if !indices.contains(index) {
                indices.append(index)
            }
        }

        guard let lastIndex = indices.last, !indices.isEmpty, lastIndex < workspaces.count else { return }

        let selectedIds = Set(indices.map { workspaces[$0].id })
        selectedWorkspaceIds = selectedIds
        lastSidebarSelectionIndex = lastIndex
        workspaceManager.selectWorkspace(workspaces[lastIndex])
        sidebarSelectionState.selection = .tabs
        didApplyUITestSidebarSelection = true
#endif
    }

    private func beginRenameWorkspaceFlow() {
        guard let workspace = workspaceManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        startRenameFlow(target)
    }

    private func beginRenamePanelFlow() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        let target = CommandPaletteRenameTarget(
            kind: .panel(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
        startRenameFlow(target)
    }

    private func startRenameFlow(_ target: CommandPaletteRenameTarget) {
        commandPaletteRenameDraft = target.currentName
        commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func continueRenameFlow(target: CommandPaletteRenameTarget) {
        guard case .renameInput(let activeTarget) = commandPaletteMode,
              activeTarget == target else { return }
        applyRenameFlow(target: target, proposedName: commandPaletteRenameDraft)
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            workspaceManager.setCustomTitle(workspaceId: workspaceId, title: normalizedName)
        case .panel(let workspaceId, let panelId):
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalizedName)
        }

        dismissCommandPalette()
    }

    private func focusFocusedBrowserAddressBar() -> Bool {
        guard let panel = workspaceManager.focusedBrowserPanel else { return false }
        _ = panel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        return true
    }

    private func openFocusedBrowserInDefaultBrowser() -> Bool {
        guard let panel = workspaceManager.focusedBrowserPanel,
              let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openWorkspacePullRequestsInConfiguredBrowser() -> Bool {
        guard let workspace = workspaceManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }

        var openedCount = 0
        if openSidebarPullRequestLinksInCmuxBrowser {
            for pullRequest in pullRequests {
                if workspaceManager.openBrowser(url: pullRequest.url, insertAtEnd: true) != nil {
                    openedCount += 1
                } else if NSWorkspace.shared.open(pullRequest.url) {
                    openedCount += 1
                }
            }
            return openedCount > 0
        }

        for pullRequest in pullRequests {
            if NSWorkspace.shared.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    private func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        case .vscodeInline:
            return openFocusedDirectoryInInlineVSCode(directoryURL)
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func openFocusedDirectoryInInlineVSCode(_ directoryURL: URL) -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL(),
              let workspace = workspaceManager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId else {
            return false
        }
        let sourceTabId = workspace.id
        let workspaceManager = workspaceManager
        VSCodeServeWebController.shared.ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            guard let serveWebURL,
                  let openFolderURL = VSCodeServeWebURLBuilder.openFolderURL(
                      baseWebUIURL: serveWebURL,
                      directoryPath: directoryURL.path
                  ) else {
                NSSound.beep()
                return
            }
            guard workspaceManager.newBrowserSplit(
                workspaceId: sourceTabId,
                fromPanelId: sourcePanelId,
                orientation: SplitDirection.right.orientation,
                insertFirst: SplitDirection.right.insertFirst,
                url: openFolderURL,
                focus: true
            ) != nil else {
                NSSound.beep()
                return
            }
        }
        return true
    }

    private func stopInlineVSCodeServeWeb() {
        VSCodeServeWebController.shared.stop()
    }

    private func restartInlineVSCodeServeWeb() -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }
        VSCodeServeWebController.shared.restart(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            if serveWebURL == nil {
                NSSound.beep()
            }
        }
        return true
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = workspaceManager.selectedWorkspace,
              let trimmed = workspace.localFolderDirectory() else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

#if DEBUG
    private func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif
}

struct CommandPaletteSwitcherSearchMetadata: Equatable, Sendable {
    let directories: [String]
    let branches: [String]
    let ports: [Int]

    init(
        directories: [String] = [],
        branches: [String] = [],
        ports: [Int] = []
    ) {
        self.directories = directories
        self.branches = branches
        self.ports = ports
    }
}

enum CommandPaletteSwitcherSearchIndexer {
    enum MetadataDetail {
        case workspace
        case surface
    }

    private static let metadataDelimiters = CharacterSet(charactersIn: "/\\.:_- ")

    static func keywords(
        baseKeywords: [String],
        metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail = .surface
    ) -> [String] {
        let metadataKeywords = metadataKeywordsForSearch(metadata, detail: detail)
        return uniqueNormalizedPreservingOrder(baseKeywords + metadataKeywords)
    }

    private static func metadataKeywordsForSearch(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail
    ) -> [String] {
        let directoryTokens = metadata.directories.flatMap { directoryTokensForSearch($0, detail: detail) }
        let branchTokens = metadata.branches.flatMap { branchTokensForSearch($0, detail: detail) }
        let portTokens = metadata.ports.flatMap(portTokensForSearch)

        var contextKeywords: [String] = []
        if !directoryTokens.isEmpty {
            contextKeywords.append(contentsOf: ["directory", "dir", "cwd", "path"])
        }
        if !branchTokens.isEmpty {
            contextKeywords.append(contentsOf: ["branch", "git"])
        }
        if !portTokens.isEmpty {
            contextKeywords.append(contentsOf: ["port", "ports"])
        }

        return contextKeywords + directoryTokens + branchTokens + portTokens
    }

    private static func directoryTokensForSearch(
        _ rawDirectory: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let standardized = (trimmed as NSString).standardizingPath
        let canonical = standardized.isEmpty ? trimmed : standardized
        let abbreviated = (canonical as NSString).abbreviatingWithTildeInPath
        switch detail {
        case .workspace:
            return uniqueNormalizedPreservingOrder([trimmed, canonical, abbreviated])
        case .surface:
            let basename = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent
            let components = canonical.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder(
                [trimmed, canonical, abbreviated, basename] + components
            )
        }
    }

    private static func branchTokensForSearch(
        _ rawBranch: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch detail {
        case .workspace:
            return [trimmed]
        case .surface:
            let components = trimmed.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder([trimmed] + components)
        }
    }

    private static func portTokensForSearch(_ port: Int) -> [String] {
        guard (1...65535).contains(port) else { return [] }
        let portText = String(port)
        return [portText, ":\(portText)"]
    }

    private static func uniqueNormalizedPreservingOrder(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(values.count)

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalizedKey = trimmed
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            guard seen.insert(normalizedKey).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

enum CommandPaletteFuzzyMatcher {
    private static let tokenBoundaryChars: Set<Character> = [" ", "-", "_", "/", ".", ":"]

    private enum SingleEditWordPrefixEditKind {
        case candidateExtraCharacter
        case tokenExtraCharacter
        case substitutedCharacter
        case transposedCharacters

        var basePenalty: Int {
            switch self {
            case .candidateExtraCharacter:
                return 0
            case .tokenExtraCharacter:
                return 10
            case .transposedCharacters:
                return 24
            case .substitutedCharacter:
                return 40
            }
        }
    }

    private struct SingleEditWordPrefixMatch {
        let matchedIndices: Set<Int>
        let segmentStart: Int
        let segmentLength: Int
        let prefixLength: Int
        let editPosition: Int
        let editKind: SingleEditWordPrefixEditKind
    }

    struct PreparedQuery {
        let normalizedText: String
        let tokens: [String]

        var isEmpty: Bool {
            tokens.isEmpty
        }
    }

    static func preparedQuery(_ query: String) -> PreparedQuery {
        let normalizedQuery = normalizeForSearch(query)
        return PreparedQuery(
            normalizedText: normalizedQuery,
            tokens: normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        )
    }

    static func normalizeForSearch(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func score(query: String, candidate: String) -> Int? {
        score(query: query, candidates: [candidate])
    }

    static func score(query: String, candidates: [String]) -> Int? {
        score(
            preparedQuery: preparedQuery(query),
            normalizedCandidates: candidates
                .map(normalizeForSearch)
                .filter { !$0.isEmpty }
        )
    }

    static func score(preparedQuery: PreparedQuery, normalizedCandidates: [String]) -> Int? {
        guard !preparedQuery.isEmpty else { return 0 }
        guard !normalizedCandidates.isEmpty else { return nil }

        var totalScore = 0
        for token in preparedQuery.tokens {
            var bestTokenScore: Int?
            for candidate in normalizedCandidates {
                guard let candidateScore = scoreToken(token, in: candidate) else { continue }
                bestTokenScore = max(bestTokenScore ?? candidateScore, candidateScore)
            }
            guard let bestTokenScore else { return nil }
            totalScore += bestTokenScore
        }
        return totalScore
    }

    static func matchCharacterIndices(query: String, candidate: String) -> Set<Int> {
        matchCharacterIndices(preparedQuery: preparedQuery(query), candidate: candidate)
    }

    static func matchCharacterIndices(preparedQuery: PreparedQuery, candidate: String) -> Set<Int> {
        guard !preparedQuery.isEmpty else { return [] }

        let loweredCandidate = normalizeForSearch(candidate)
        guard !loweredCandidate.isEmpty else { return [] }

        let candidateChars = Array(loweredCandidate)
        var matched: Set<Int> = []

        for token in preparedQuery.tokens {
            if token == loweredCandidate {
                matched.formUnion(0..<candidateChars.count)
                continue
            }

            if loweredCandidate.hasPrefix(token) {
                matched.formUnion(0..<min(token.count, candidateChars.count))
                continue
            }

            if let range = loweredCandidate.range(of: token) {
                let start = loweredCandidate.distance(from: loweredCandidate.startIndex, to: range.lowerBound)
                let end = min(candidateChars.count, start + token.count)
                matched.formUnion(start..<end)
                continue
            }

            if let singleEditPrefix = singleEditWordPrefixMatch(token: token, candidate: loweredCandidate) {
                matched.formUnion(singleEditPrefix.matchedIndices)
                continue
            }

            if let initialism = initialismMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(initialism)
                continue
            }

            if let stitched = stitchedWordPrefixMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(stitched)
                continue
            }

            guard token.count <= 3 else { continue }
            if let subsequence = subsequenceMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(subsequence)
            }
        }

        return matched
    }

    private static func scoreToken(_ token: String, in candidate: String) -> Int? {
        guard !token.isEmpty else { return 0 }

        let candidateChars = Array(candidate)
        let tokenChars = Array(token)
        guard tokenChars.count <= candidateChars.count else { return nil }

        if token == candidate {
            return 8000
        }
        if candidate.hasPrefix(token) {
            return 6800 - max(0, candidate.count - token.count)
        }

        var bestScore: Int?
        if let wordExactScore = bestWordScore(tokenChars: tokenChars, candidateChars: candidateChars, requireExactWord: true) {
            bestScore = max(bestScore ?? wordExactScore, wordExactScore)
        }
        if let wordPrefixScore = bestWordScore(tokenChars: tokenChars, candidateChars: candidateChars, requireExactWord: false) {
            bestScore = max(bestScore ?? wordPrefixScore, wordPrefixScore)
        }
        if let singleEditPrefixScore = singleEditWordPrefixScore(
            tokenChars: tokenChars,
            candidateChars: candidateChars
        ) {
            bestScore = max(bestScore ?? singleEditPrefixScore, singleEditPrefixScore)
        }

        if let range = candidate.range(of: token) {
            let distance = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let lengthPenalty = max(0, candidate.count - token.count)
            let boundaryBoost: Int = {
                guard distance > 0 else { return 220 }
                let prior = candidateChars[distance - 1]
                return tokenBoundaryChars.contains(prior) ? 180 : 0
            }()
            let containsScore = 4200 + boundaryBoost - (distance * 9) - lengthPenalty
            bestScore = max(bestScore ?? containsScore, containsScore)
        }

        if let initialismScore = initialismScore(tokenChars: tokenChars, candidateChars: candidateChars) {
            bestScore = max(bestScore ?? initialismScore, initialismScore)
        }

        if let stitchedScore = stitchedWordPrefixScore(tokenChars: tokenChars, candidateChars: candidateChars) {
            bestScore = max(bestScore ?? stitchedScore, stitchedScore)
        }

        if tokenChars.count <= 3, let subsequence = subsequenceScore(token: token, candidate: candidate) {
            bestScore = max(bestScore ?? subsequence, subsequence)
        }

        guard let bestScore else { return nil }
        return max(1, bestScore)
    }

    private static func bestWordScore(
        tokenChars: [Character],
        candidateChars: [Character],
        requireExactWord: Bool
    ) -> Int? {
        guard !tokenChars.isEmpty else { return nil }

        var best: Int?
        for segment in wordSegments(candidateChars) {
            let wordLength = segment.end - segment.start
            guard tokenChars.count <= wordLength else { continue }

            var matchesPrefix = true
            for offset in 0..<tokenChars.count where candidateChars[segment.start + offset] != tokenChars[offset] {
                matchesPrefix = false
                break
            }
            guard matchesPrefix else { continue }
            if requireExactWord && tokenChars.count != wordLength { continue }

            let lengthPenalty = max(0, wordLength - tokenChars.count) * 6
            let distancePenalty = segment.start * 8
            let trailingPenalty = max(0, candidateChars.count - wordLength)
            let scoreBase = requireExactWord ? 6200 : 5600
            let score = scoreBase - distancePenalty - lengthPenalty - trailingPenalty
            best = max(best ?? score, score)
        }

        return best
    }

    private static func singleEditWordPrefixScore(
        tokenChars: [Character],
        candidateChars: [Character]
    ) -> Int? {
        guard let match = singleEditWordPrefixMatch(
            tokenChars: tokenChars,
            candidateChars: candidateChars
        ) else {
            return nil
        }
        return singleEditWordPrefixScore(match: match, candidateLength: candidateChars.count)
    }

    private static func singleEditWordPrefixScore(
        match: SingleEditWordPrefixMatch,
        candidateLength: Int
    ) -> Int {
        let lengthPenalty = max(0, match.segmentLength - match.prefixLength) * 6
        let distancePenalty = match.segmentStart * 8
        let trailingPenalty = max(0, candidateLength - match.segmentLength)
        let editPositionPenalty = max(0, match.editPosition - match.segmentStart) * 10
        return 5000
            - match.editKind.basePenalty
            - distancePenalty
            - lengthPenalty
            - trailingPenalty
            - editPositionPenalty
    }

    private static func initialismScore(tokenChars: [Character], candidateChars: [Character]) -> Int? {
        guard !tokenChars.isEmpty else { return nil }
        let segments = wordSegments(candidateChars)
        guard tokenChars.count <= segments.count else { return nil }

        var matchedStarts: [Int] = []
        var searchWordIndex = 0

        for tokenChar in tokenChars {
            var found = false
            while searchWordIndex < segments.count {
                let segment = segments[searchWordIndex]
                searchWordIndex += 1
                if candidateChars[segment.start] == tokenChar {
                    matchedStarts.append(segment.start)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        let firstStart = matchedStarts.first ?? 0
        let skippedWords = max(0, segments.count - tokenChars.count)
        return 3000 + (tokenChars.count * 160) - (firstStart * 5) - (skippedWords * 30)
    }

    private static func tokenPrefixMatches(
        tokenChars: [Character],
        tokenStart: Int,
        length: Int,
        candidateChars: [Character],
        candidateStart: Int
    ) -> Bool {
        guard length >= 0 else { return false }
        guard tokenStart + length <= tokenChars.count else { return false }
        guard candidateStart + length <= candidateChars.count else { return false }
        guard length > 0 else { return true }

        for offset in 0..<length where tokenChars[tokenStart + offset] != candidateChars[candidateStart + offset] {
            return false
        }
        return true
    }

    private static func stitchedWordPrefixScore(tokenChars: [Character], candidateChars: [Character]) -> Int? {
        guard tokenChars.count >= 4 else { return nil }
        let segments = wordSegments(candidateChars)
        guard segments.count >= 2 else { return nil }

        struct StitchState: Hashable {
            let tokenIndex: Int
            let wordIndex: Int
            let usedWords: Int
        }

        var memo: [StitchState: Int?] = [:]

        func dfs(tokenIndex: Int, wordIndex: Int, usedWords: Int) -> Int? {
            if tokenIndex == tokenChars.count {
                return usedWords >= 2 ? 0 : nil
            }
            guard wordIndex < segments.count else { return nil }

            let state = StitchState(tokenIndex: tokenIndex, wordIndex: wordIndex, usedWords: usedWords)
            if let cached = memo[state] {
                return cached
            }

            var best: Int?
            let remainingChars = tokenChars.count - tokenIndex
            for segmentIndex in wordIndex..<segments.count {
                let segment = segments[segmentIndex]
                let segmentLength = segment.end - segment.start
                let maxChunk = min(segmentLength, remainingChars)
                guard maxChunk > 0 else { continue }

                let skippedWords = max(0, segmentIndex - wordIndex)
                let skipPenalty = skippedWords * 120
                for chunkLength in stride(from: maxChunk, through: 1, by: -1) {
                    guard tokenPrefixMatches(
                        tokenChars: tokenChars,
                        tokenStart: tokenIndex,
                        length: chunkLength,
                        candidateChars: candidateChars,
                        candidateStart: segment.start
                    ) else {
                        continue
                    }
                    guard let suffixScore = dfs(
                        tokenIndex: tokenIndex + chunkLength,
                        wordIndex: segmentIndex + 1,
                        usedWords: min(2, usedWords + 1)
                    ) else {
                        continue
                    }

                    let chunkCoverage = chunkLength * 220
                    let contiguityBonus = segmentIndex == wordIndex ? 80 : 0
                    let segmentRemainderPenalty = max(0, segmentLength - chunkLength) * 9
                    let distancePenalty = segment.start * 4
                    let chunkScore = chunkCoverage + contiguityBonus - segmentRemainderPenalty - distancePenalty - skipPenalty
                    let totalScore = suffixScore + chunkScore
                    best = max(best ?? totalScore, totalScore)
                }
            }

            memo[state] = best
            return best
        }

        guard let stitchedScore = dfs(tokenIndex: 0, wordIndex: 0, usedWords: 0) else { return nil }
        let lengthPenalty = max(0, candidateChars.count - tokenChars.count)
        return 3500 + stitchedScore - lengthPenalty
    }

    private static func stitchedWordPrefixMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count >= 4 else { return nil }

        let segments = wordSegments(candidateChars)
        guard segments.count >= 2 else { return nil }

        var tokenIndex = 0
        var nextWordIndex = 0
        var usedWords = 0
        var matchedIndices: Set<Int> = []

        while tokenIndex < tokenChars.count {
            let remainingChars = tokenChars.count - tokenIndex
            var foundMatch = false

            for segmentIndex in nextWordIndex..<segments.count {
                let segment = segments[segmentIndex]
                let segmentLength = segment.end - segment.start
                let maxChunk = min(segmentLength, remainingChars)
                guard maxChunk > 0 else { continue }

                for chunkLength in stride(from: maxChunk, through: 1, by: -1) {
                    guard tokenPrefixMatches(
                        tokenChars: tokenChars,
                        tokenStart: tokenIndex,
                        length: chunkLength,
                        candidateChars: candidateChars,
                        candidateStart: segment.start
                    ) else {
                        continue
                    }

                    matchedIndices.formUnion(segment.start..<(segment.start + chunkLength))
                    tokenIndex += chunkLength
                    nextWordIndex = segmentIndex + 1
                    usedWords += 1
                    foundMatch = true
                    break
                }

                if foundMatch { break }
            }

            if !foundMatch { return nil }
        }

        guard usedWords >= 2 else { return nil }
        return matchedIndices
    }

    private static func singleEditWordPrefixMatch(
        token: String,
        candidate: String
    ) -> SingleEditWordPrefixMatch? {
        singleEditWordPrefixMatch(
            tokenChars: Array(token),
            candidateChars: Array(candidate)
        )
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character]
    ) -> SingleEditWordPrefixMatch? {
        guard tokenChars.count >= 4 else { return nil }

        var bestMatch: SingleEditWordPrefixMatch?
        var bestScore: Int?

        for segment in wordSegments(candidateChars) {
            guard let match = singleEditWordPrefixMatch(
                tokenChars: tokenChars,
                candidateChars: candidateChars,
                segment: segment
            ) else {
                continue
            }

            let score = singleEditWordPrefixScore(match: match, candidateLength: candidateChars.count)
            if let bestScore, score <= bestScore {
                continue
            }
            bestScore = score
            bestMatch = match
        }

        return bestMatch
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character],
        segment: (start: Int, end: Int)
    ) -> SingleEditWordPrefixMatch? {
        guard tokenChars.count >= 4 else { return nil }

        let segmentLength = segment.end - segment.start
        guard segmentLength + 1 >= tokenChars.count else { return nil }

        let exactPrefixLength = min(tokenChars.count, segmentLength)
        var mismatchOffset = 0
        while mismatchOffset < exactPrefixLength,
            candidateChars[segment.start + mismatchOffset] == tokenChars[mismatchOffset]
        {
            mismatchOffset += 1
        }

        if mismatchOffset == tokenChars.count {
            let prefixLength = tokenChars.count + 1
            guard segmentLength >= prefixLength else { return nil }
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: prefixLength,
                editPosition: segment.start + tokenChars.count,
                editKind: .candidateExtraCharacter
            )
        }

        if mismatchOffset == segmentLength {
            let prefixLength = tokenChars.count - 1
            guard prefixLength > 0 else { return nil }
            guard tokenChars.count == segmentLength + 1 else { return nil }
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + prefixLength)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: prefixLength,
                editPosition: segment.start + prefixLength,
                editKind: .tokenExtraCharacter
            )
        }

        let mismatchCandidateIndex = segment.start + mismatchOffset

        if segmentLength >= tokenChars.count + 1,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset,
                length: tokenChars.count - mismatchOffset,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 1
            )
        {
            var matchedIndices = Set(segment.start..<(segment.start + tokenChars.count + 1))
            matchedIndices.remove(mismatchCandidateIndex)
            return SingleEditWordPrefixMatch(
                matchedIndices: matchedIndices,
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count + 1,
                editPosition: mismatchCandidateIndex,
                editKind: .candidateExtraCharacter
            )
        }

        if tokenChars.count >= 2,
            segmentLength >= tokenChars.count - 1,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 1,
                length: tokenChars.count - mismatchOffset - 1,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex
            )
        {
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count - 1)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count - 1,
                editPosition: mismatchCandidateIndex,
                editKind: .tokenExtraCharacter
            )
        }

        if segmentLength >= tokenChars.count,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 1,
                length: tokenChars.count - mismatchOffset - 1,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 1
            )
        {
            var matchedIndices = Set(segment.start..<(segment.start + tokenChars.count))
            matchedIndices.remove(mismatchCandidateIndex)
            return SingleEditWordPrefixMatch(
                matchedIndices: matchedIndices,
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count,
                editPosition: mismatchCandidateIndex,
                editKind: .substitutedCharacter
            )
        }

        if segmentLength >= tokenChars.count,
            mismatchOffset + 1 < tokenChars.count,
            mismatchCandidateIndex + 1 < segment.end,
            tokenChars[mismatchOffset] == candidateChars[mismatchCandidateIndex + 1],
            tokenChars[mismatchOffset + 1] == candidateChars[mismatchCandidateIndex],
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 2,
                length: tokenChars.count - mismatchOffset - 2,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 2
            )
        {
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count,
                editPosition: mismatchCandidateIndex,
                editKind: .transposedCharacters
            )
        }

        return nil
    }

    private static func wordSegments(_ candidateChars: [Character]) -> [(start: Int, end: Int)] {
        var segments: [(start: Int, end: Int)] = []
        var index = 0

        while index < candidateChars.count {
            while index < candidateChars.count, tokenBoundaryChars.contains(candidateChars[index]) {
                index += 1
            }
            guard index < candidateChars.count else { break }
            let start = index
            while index < candidateChars.count, !tokenBoundaryChars.contains(candidateChars[index]) {
                index += 1
            }
            segments.append((start: start, end: index))
        }

        return segments
    }

    private static func subsequenceScore(token: String, candidate: String) -> Int? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count <= candidateChars.count else { return nil }

        var searchIndex = 0
        var previousMatch = -1
        var consecutiveRun = 0
        var score = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchedIndex = foundIndex else { return nil }

            score += 90
            if matchedIndex == 0 || tokenBoundaryChars.contains(candidateChars[matchedIndex - 1]) {
                score += 140
            }
            if matchedIndex == previousMatch + 1 {
                consecutiveRun += 1
                score += min(200, consecutiveRun * 45)
            } else {
                consecutiveRun = 0
                score -= min(120, max(0, matchedIndex - previousMatch - 1) * 4)
            }

            previousMatch = matchedIndex
            searchIndex = matchedIndex + 1
        }

        score -= max(0, candidateChars.count - tokenChars.count)
        return max(1, score)
    }

    private static func subsequenceMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count <= candidateChars.count else { return nil }

        var indices: Set<Int> = []
        var searchIndex = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchIndex = foundIndex else { return nil }
            indices.insert(matchIndex)
            searchIndex = matchIndex + 1
        }

        return indices
    }

    private static func initialismMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard !tokenChars.isEmpty else { return nil }

        let segments = wordSegments(candidateChars)
        guard tokenChars.count <= segments.count else { return nil }

        var matched: Set<Int> = []
        var searchWordIndex = 0

        for tokenChar in tokenChars {
            var found = false
            while searchWordIndex < segments.count {
                let segment = segments[searchWordIndex]
                searchWordIndex += 1
                if candidateChars[segment.start] == tokenChar {
                    matched.insert(segment.start)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        return matched
    }
}

struct CommandPaletteSearchCorpusEntry<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let normalizedTitle: String
    let normalizedSearchableTexts: [String]

    init(payload: Payload, rank: Int, title: String, searchableTexts: [String]) {
        self.payload = payload
        self.rank = rank
        self.title = title
        self.normalizedTitle = CommandPaletteFuzzyMatcher.normalizeForSearch(title)
        self.normalizedSearchableTexts = searchableTexts
            .map(CommandPaletteFuzzyMatcher.normalizeForSearch)
            .filter { !$0.isEmpty }
    }
}

struct CommandPaletteSearchCorpusResult<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let score: Int
    let titleMatchIndices: Set<Int>
}

enum CommandPaletteSearchEngine {
    private static let titleMatchBonus = 2000

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            historyBoost: historyBoost,
            shouldCancel: nil
        )
    }

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: @escaping () -> Bool
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            historyBoost: historyBoost,
            shouldCancel: Optional(shouldCancel)
        )
    }

    private static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: (() -> Bool)?
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        var results: [CommandPaletteSearchCorpusResult<Payload>] = []
        results.reserveCapacity(entries.count)

        func shouldCancelSearch(at index: Int) -> Bool {
            guard let shouldCancel else { return false }
            return index % 16 == 0 && shouldCancel()
        }

        if queryIsEmpty {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                results.append(
                    CommandPaletteSearchCorpusResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: historyBoost(entry.payload, true),
                    titleMatchIndices: []
                )
                )
            }
        } else {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                guard let fuzzyScore = weightedScore(
                    preparedQuery: preparedQuery,
                    entry: entry
                ) else {
                    continue
                }
                results.append(
                    CommandPaletteSearchCorpusResult(
                        payload: entry.payload,
                        rank: entry.rank,
                        title: entry.title,
                        score: fuzzyScore + historyBoost(entry.payload, false),
                        titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                            preparedQuery: preparedQuery,
                            candidate: entry.title
                        )
                    )
                )
            }
        }

        if shouldCancel?() == true { return [] }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func weightedScore<Payload: Sendable>(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        entry: CommandPaletteSearchCorpusEntry<Payload>
    ) -> Int? {
        guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
                    preparedQuery: preparedQuery,
                    normalizedCandidates: entry.normalizedSearchableTexts
                ) else {
            return nil
        }
        guard !entry.normalizedTitle.isEmpty,
              let titleScore = CommandPaletteFuzzyMatcher.score(
                preparedQuery: preparedQuery,
                normalizedCandidates: [entry.normalizedTitle]
              ) else {
            return fuzzyScore
        }
        return max(fuzzyScore, titleScore + titleMatchBonus)
    }
}

private struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    // C11-25: the CPU/RSS sampler is deliberately NOT observed here. Its
    // 2 Hz revision bump is subscribed inside `SidebarSurfaceMetricsReadout`,
    // the leaf that renders the numbers, so a sample tick no longer walks
    // the whole sidebar (workspace pulse projection, worktree chips, per-row
    // Equatable compares) twice a second.
    let onSendFeedback: () -> Void
    var width: CGFloat = 0
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    /// c11 (C11H-197): the hosting window's theme override.
    @Environment(\.c11WindowThemeName) private var windowThemeName
    @Binding var selection: SidebarSelection
    @Binding var selectedWorkspaceIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @AppStorage(WorkspaceOrdinalDisplaySettings.showWorkspaceIdsKey)
    private var showWorkspaceIds = WorkspaceOrdinalDisplaySettings.defaultShowWorkspaceIds
    @StateObject private var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @StateObject private var horizontalScrollMonitor = SidebarHorizontalScrollWorkspaceMonitor()
    @StateObject private var groupCoordinator = WorkspaceGroupSidebarCoordinator()
    @State private var showingNewGroup = false
    @State private var newGroupFocusTarget: WorkspaceGroupEditorFocusTarget?
    @State private var draggedGroupId: UUID?
    @State private var draggedWorkspaceId: UUID?
    @State private var dropIndicator: SidebarDropIndicator?
    @State private var panelDropTargetWorkspaceId: UUID?
    /// C11H-221: full cards while every workspace fits, compact cards once
    /// they would scroll. Measurements live in a plain reference so a card
    /// growing by a point never re-evaluates this body; only a flip does.
    @AppStorage(SidebarDensitySetting.key)
    private var sidebarDensityRaw = SidebarDensitySetting.defaultValue.rawValue
    @State private var sidebarDensity: SidebarDensity = SidebarDensityTracker.startDensity
    @State private var densityTracker = SidebarDensityTracker()
    @AppStorage(SidebarWorkspaceDetailSettings.hideAllDetailsKey)
    private var sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
    @AppStorage(SidebarWorkspaceDetailSettings.showNotificationMessageKey)
    private var sidebarShowNotificationMessage = SidebarWorkspaceDetailSettings.defaultShowNotificationMessage
    @AppStorage(SidebarActiveWorkspaceIndicatorSettings.styleKey)
    private var activeWorkspaceIndicatorStyleRaw = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
    @AppStorage(ThemeAppStorage.Keys.m1bSidebarTabItemMigrated, store: ThemeAppStorage.defaults)
    private var m1bSidebarTabItemMigrated = false
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(ChromeScaleSettings.presetKey)
    private var chromeScalePresetRaw = ChromeScaleSettings.defaultPreset.rawValue
    @AppStorage(ChromeScaleSettings.customMultiplierKey)
    private var chromeScaleCustomMultiplier = Double(ChromeScaleSettings.defaultCustomMultiplier)
    /// Tile columns at this width and chrome scale; the footer follows them.
    private var tileColumns: Int {
        SidebarLayoutPolicy.columns(width: Double(width), scale: Double(ChromeScaleSettings.multiplier(
            presetRaw: chromeScalePresetRaw, customMultiplier: chromeScaleCustomMultiplier)))
    }
    /// Width alone picks Tiles: two columns whenever they fit at the tile scale.
    private var compact: Bool { tileColumns >= 2 }
    /// C11-104 v2 — chip row is gated by the preserved
    /// `sidebarShowBranchDirectory` key (existing user prefs survive
    /// the legacy-row → chip-row migration).
    @AppStorage("sidebarShowBranchDirectory")
    private var sidebarShowBranchDirectory = true

    /// Space at top of sidebar for traffic light buttons
    private let trafficLightPadding: CGFloat = 28
    private let tabRowSpacing: CGFloat = 4
    /// Extra clearance between the traffic-light strip and the first
    /// workspace row so the row's selection highlight clears the
    /// `SidebarTopScrim` gradient. The scrim is `trafficLightPadding + 20`
    /// tall and its bottom 20pt is the soft fade; we need the first row
    /// to begin at least ~12pt past the scrim's center to keep the
    /// rounded top corners legible.
    private let firstRowTopInset: CGFloat = 12
    @AppStorage("titlebarControlsStyle") private var minimalControlsStyleRaw = TitlebarControlsStyle.classic.rawValue

    private var sidebarTopReservedHeight: CGFloat {
        let controls = (TitlebarControlsStyle(rawValue: minimalControlsStyleRaw) ?? .classic).config
        return trafficLightPadding + (isMinimalMode ? controls.sidebarRowsHeight + 2 : 0)
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var showsSidebarNotificationMessage: Bool {
        SidebarWorkspaceDetailSettings.resolvedNotificationMessageVisibility(
            showNotificationMessage: sidebarShowNotificationMessage,
            hideAllDetails: sidebarHideAllDetails
        )
    }

    private var activeWorkspaceIndicatorStyle: SidebarActiveWorkspaceIndicatorStyle {
        SidebarActiveWorkspaceIndicatorSettings.resolvedStyle(rawValue: activeWorkspaceIndicatorStyleRaw)
    }

    private var useThemeM1bSidebarTabItemPath: Bool {
        themeManager.themedPathLive(flag: m1bSidebarTabItemMigrated, windowThemeName: windowThemeName)
    }

    /// True when `role` resolves to a colour built from the workspace's own
    /// colour (Stage 11's `$workspaceColor`), false for a fixed theme colour
    /// (Nocturne's `#0F1115`). Two sample workspace colours that resolve to the
    /// same fill mean the fill does not carry the workspace's colour.
    private func themedFillDerivesFromWorkspaceColor(_ role: ThemeRole) -> Bool {
        func sample(_ hex: String) -> NSColor? {
            themeManager.resolve(role, context: themeManager.makeContext(
                workspaceColor: hex,
                colorScheme: colorScheme,
                forceBright: false,
                windowThemeName: windowThemeName
            ))
        }
        return sample("#000000") != sample("#FFFFFF")
    }

    private func themedSidebarWorkspaceColors(
        workspace: Workspace,
        isActive: Bool,
        isMultiSelected: Bool
    ) -> (background: NSColor?, rail: NSColor?, fillCarriesWorkspaceColor: Bool) {
        guard useThemeM1bSidebarTabItemPath else { return (nil, nil, false) }

        let context = themeManager.makeContext(
            workspaceColor: workspace.customColor,
            colorScheme: colorScheme,
            forceBright: activeWorkspaceIndicatorStyle == .leftRail,
            windowThemeName: windowThemeName
        )

        switch activeWorkspaceIndicatorStyle {
        case .leftRail:
            guard isActive else { return (nil, nil, false) }

            let role: ThemeRole = workspace.customColor == nil ? .sidebar_activeTabRailFallback : .sidebar_activeTabRail
            guard let baseColor: NSColor = themeManager.resolve(role, context: context) else {
                return (nil, nil, false)
            }
            let opacity = (themeManager.resolve(.sidebar_activeTabRailOpacity, context: context) as Double?) ?? 0.95
            return (nil, baseColor.withAlphaComponent(CGFloat(opacity)), false)

        case .solidFill:
            if isActive {
                let role: ThemeRole = workspace.customColor == nil ? .sidebar_activeTabFillFallback : .sidebar_activeTabFill
                guard let fill: NSColor = themeManager.resolve(role, context: context) else {
                    return (nil, nil, false)
                }
                let carries = workspace.customColor != nil && themedFillDerivesFromWorkspaceColor(role)
                return (fill, nil, carries)
            }

            guard workspace.customColor != nil,
                  let fill: NSColor = themeManager.resolve(.sidebar_activeTabFill, context: context)
            else {
                return (nil, nil, false)
            }

            let opacityRole: ThemeRole = isMultiSelected
                ? .sidebar_inactiveTabMultiSelectOpacity
                : .sidebar_inactiveTabCustomOpacity
            let opacity = (themeManager.resolve(opacityRole, context: context) as Double?)
                ?? (isMultiSelected ? 0.35 : 0.7)
            return (
                fill.withAlphaComponent(CGFloat(opacity)),
                nil,
                themedFillDerivesFromWorkspaceColor(.sidebar_activeTabFill)
            )
        }
    }

    /// Runs on every stack, scroll or footer measurement; writes state only
    /// when the density flips, so ordinary card growth costs no sidebar body.
    private func updateSidebarDensity() {
        let tracker = densityTracker
        guard let stack = tracker.stack, let footer = tracker.footer, footer.frame.minY > 0 else { return }
        let isCompact = sidebarDensity == .compact
        // A measurement from the other density is a frame in flight; wait for ours.
        guard stack.density == sidebarDensity, footer.dense == isCompact else { return }
        let kinds = PanelAttentionIndex.shared.flagKindSummary.groups.count
        let scale = compact
            ? ChromeScaleSettings.multiplier(presetRaw: chromeScalePresetRaw, customMultiplier: chromeScaleCustomMultiplier)
            : ChromeScaleSettings.multiplier(for: ChromeScaleSettings.preset(for: chromeScalePresetRaw))
        let columns = compact
            ? SidebarLayoutPolicy.columns(width: Double(stack.frame.width), scale: Double(scale)) : 1
        // Only one column has a dense footer; in Tiles both densities share one.
        if !footer.dense, columns == 1 {
            tracker.fullFooterHeight = Double(footer.frame.height)
            tracker.fullFooterKinds = kinds
        }
        let denseHeight = Double(footer.frame.height)
        let fullFooter: Double = {
            guard columns == 1 else { return denseHeight }
            if let measured = tracker.fullFooterHeight {
                return SidebarDensityPolicy.fullFooterHeight(measuredHeight: measured, measuredKinds: tracker.fullFooterKinds,
                                                             kinds: kinds, denseHeight: denseHeight)
            }
            let remembered = SidebarDensityTracker.rememberedFullFooter()
            return SidebarDensityPolicy.fullFooterHeight(measuredHeight: remembered?.height,
                                                         measuredKinds: remembered?.kinds ?? 0,
                                                         kinds: kinds, denseHeight: denseHeight)
        }()
        let available = Double(footer.frame.minY - tracker.scrollTop - stack.frame.minY)
        let cardsAvailable = isCompact
            ? SidebarDensityPolicy.cardsAvailable(compactAvailable: available, denseFooterHeight: denseHeight,
                                                  fullFooterHeight: fullFooter)
            : available

        // The stack's lines exactly as the view draws them: one per row in a
        // column, and in Tiles a new run at every folder header and group change.
        // Rows whose workspace is already gone draw nothing; count them as the view does.
        let liveIds = Set(workspaceManager.workspaces.map(\.id))
        let rows = groupCoordinator.projection.rows.filter { row in
            guard case .workspace(let item) = row else { return true }
            return liveIds.contains(item.workspaceId)
        }
        var lines: [SidebarDensityLine] = []
        var shownIds = Set<UUID>()
        for run in WorkspaceSidebarTileRun.pack(rows) {
            if case .group = run.rows[0] {
                lines.append(.header)
                continue
            }
            for line in run.lines(columns: columns) {
                lines.append(.cards(line.rows.map { row -> Double? in
                    guard case .workspace(let item) = row else { return nil }
                    shownIds.insert(item.workspaceId)
                    return tracker.cardHeights[item.workspaceId]
                }))
            }
        }
        // Forget closed workspaces; a hidden one is measured again when shown.
        if tracker.cardHeights.count > shownIds.count * 2 + 8 {
            tracker.cardHeights = tracker.cardHeights.filter { shownIds.contains($0.key) }
        }
        let estimate = SidebarDensityPolicy.estimatedCardsHeight(
            lines: lines, headerHeight: Double(WorkspaceGroupHeaderView.height(scale: CGFloat(scale))),
            spacing: Double(tabRowSpacing), padding: 16,
            fallbackCardHeight: SidebarDensityTracker.rememberedCardHeight())
        let next = SidebarDensityPolicy.density(
            setting: .resolve(sidebarDensityRaw), current: sidebarDensity,
            available: available, cardsAvailable: cardsAvailable,
            shownHeight: Double(stack.frame.height), estimatedCardsHeight: estimate)
        sidebarState.shownDensity = next
        guard next != sidebarDensity else { return }
#if DEBUG
        dlog("sidebar.density \(sidebarDensity.rawValue)->\(next.rawValue) available=\(Int(available)) cardsAvailable=\(Int(cardsAvailable)) stack=\(Int(stack.frame.height)) estimate=\(Int(estimate ?? -1))")
#endif
        SidebarDensityTracker.remember(density: next, cardHeights: tracker.cardHeights,
                                       fullFooterHeight: tracker.fullFooterHeight,
                                       fullFooterKinds: tracker.fullFooterKinds)
        sidebarDensity = next
    }

    /// Centers the workspace's card, or its folder header when the folder is collapsed.
    private func revealInSidebar(workspaceId: UUID, using scrollProxy: ScrollViewProxy) {
        let rows = groupCoordinator.projection.rows
        let rowId: WorkspaceGroupSidebarRow.ID
        if rows.contains(where: { $0.id == .workspace(workspaceId) }) {
            rowId = .workspace(workspaceId)
        } else if let groupId = workspaceManager.workspaces.first(where: { $0.id == workspaceId })?.groupId,
                  rows.contains(where: { $0.id == .group(groupId) }) {
            rowId = .group(groupId)
        } else {
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollProxy.scrollTo(rowId, anchor: .center)
        }
    }

    var body: some View {
        // C11H-238 meter: name what invalidated this body (stdout, meter runs only).
        let _ = GraphChurnMeter.printsChanges ? Self._printChanges() : ()
        let _ = GraphChurnMeter.note(.sidebarListBody)
        let workspacesById = Dictionary(uniqueKeysWithValues: workspaceManager.workspaces.map { ($0.id, $0) })
        // Compute chrome-scale tokens once per parent eval. Threaded as a
        // precomputed `let` to TabItemView so its typing-latency hot-path
        // == comparison stays a single multiplier compare. (C11-6)
        let chromeTokens = ChromeScaleTokens(
            multiplier: compact ? ChromeScaleSettings.multiplier(
                presetRaw: chromeScalePresetRaw,
                customMultiplier: chromeScaleCustomMultiplier
            ) : ChromeScaleSettings.multiplier(
                for: ChromeScaleSettings.preset(for: chromeScalePresetRaw)
            )
        )
        // Shared by every folder header in this projection evaluation.
        let groupPalette = WorkspaceColorSettings.palette()
        // Schema-2 sidebar values, resolved once per theme version (C11H-144..148).
        let sidebarStyle = SidebarThemeStyleCache.current(themeManager, colorScheme: colorScheme, windowThemeName: windowThemeName)

        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            // Space for traffic lights / fullscreen controls.
                            // Includes `firstRowTopInset` so the first row's
                            // highlight rounded-rect clears the `SidebarTopScrim`
                            // gradient below — without it the scrim is still
                            // ~40% opaque where the top corner lands and the
                            // highlight reads as if the corner is cut off.
                            Spacer()
                                .frame(height: sidebarTopReservedHeight + firstRowTopInset)

                            groupControls(style: sidebarStyle, compact: sidebarDensity == .compact)

                            // Eager stacks, never LazyVStack. Cards differ widely in
                            // height, and a lazy stack estimates the unbuilt ones:
                            // building a card corrects the estimate, the content
                            // height changes, the scroll view clamps its offset, a
                            // different set of cards becomes visible, and the
                            // estimates move again. When the cards nearly fill the
                            // sidebar that cycle never settles and the main thread
                            // spins inside one SwiftUI transaction (2026-11-02,
                            // 14 workspaces in a 1410 pt window). Eager stacks
                            // measure every card exactly. `.equatable()` skips the
                            // row bodies, but `workspaceRow`'s input work now runs
                            // for every card on each sidebar evaluation.
                            Group {
                                if compact {
                                    VStack(spacing: tabRowSpacing) {
                                        let columns = SidebarLayoutPolicy.columns(width: Double(proxy.size.width),
                                                                                  scale: Double(chromeTokens.multiplier))
                                        ForEach(WorkspaceSidebarTileRun.pack(groupCoordinator.projection.rows)) { run in
                                            if case .group = run.rows[0] {
                                                tileRows(run.rows, workspacesById: workspacesById,
                                                         chromeTokens: chromeTokens, palette: groupPalette,
                                                         style: sidebarStyle, sidebarWidth: proxy.size.width)
                                            } else {
                                                // Every tile is the full card. A fixed-height row
                                                // proposes its tallest card's height to each cell,
                                                // so the cards in one row share top and bottom edges.
                                                ForEach(run.lines(columns: columns)) { line in
                                                    HStack(alignment: .top, spacing: 0) {
                                                        tileRows(line.rows, workspacesById: workspacesById,
                                                                 chromeTokens: chromeTokens, palette: groupPalette,
                                                                 style: sidebarStyle, sidebarWidth: proxy.size.width)
                                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                                        ForEach(line.rows.count..<columns, id: \.self) { _ in
                                                            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                                                        }
                                                    }
                                                    .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }
                                        }
                                    }
                                } else {
                            VStack(spacing: tabRowSpacing) {
                                ForEach(groupCoordinator.projection.rows) { row in
                                    switch row {
                                    case .group(let header):
                                        groupHeader(header, chromeTokens: chromeTokens, palette: groupPalette,
                                                    style: sidebarStyle, sidebarWidth: proxy.size.width)
                                            .overlay(alignment: .topLeading) {
                                                groupColorBar(
                                                    groupId: header.group.id,
                                                    continuesBelow: !header.group.isCollapsed && header.summary.memberCount > 0
                                                )
                                            }
                                    case .workspace(let item):
                                        if let ws = workspacesById[item.workspaceId] {
                                            workspaceRow(ws, item: item, chromeTokens: chromeTokens, style: sidebarStyle)
                                                .anchorPreference(key: SidebarWorkspaceRowAnchorKey.self, value: .bounds) { [ws.id: $0] }
                                                .padding(.leading, item.groupId == nil ? 0 : 12)
                                                .overlay(alignment: .topLeading) {
                                                    groupColorBar(
                                                        groupId: item.groupId,
                                                        continuesBelow: !item.isLastGroupMember
                                                    )
                                                }
                                                .overlay(alignment: .bottom) {
                                                    if item.isLastGroupMember,
                                                       dropIndicator?.groupId == item.groupId,
                                                       dropIndicator?.isGroupBody == false, dropIndicator?.edge == .bottom {
                                                        Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.horizontal, 6)
                                                    }
                                                }
                                        }
                                    }
                                }
                            }
                                }
                            }
                            // Natural height only. The column below has a minimum
                            // height of the viewport, and an eager stack would hand
                            // that spare height to the cards (each holds a Spacer)
                            // instead of leaving it to SidebarEmptyArea.
                            .fixedSize(horizontal: false, vertical: true)
                            .overlayPreferenceValue(SidebarWorkspaceRowAnchorKey.self) { anchors in
                                panelDropOverlay(rowAnchors: anchors, cardRadius: sidebarStyle.cardRadius ?? 12)
                            }
                            // Each full card's height, so the compact sidebar knows
                            // when the cards would fit again (C11H-221).
                            .backgroundPreferenceValue(SidebarWorkspaceRowAnchorKey.self) { anchors in
                                GeometryReader { rows in
                                    Color.clear.preference(
                                        key: SidebarCardHeightsKey.self,
                                        value: SidebarCardHeights(density: sidebarDensity,
                                                                  heights: anchors.mapValues { rows[$0].height }))
                                }
                            }
                            .padding(.vertical, 8)
                            .background {
                                GeometryReader { stack in
                                    Color.clear.preference(
                                        key: SidebarStackMetricsKey.self,
                                        value: SidebarStackMetrics(
                                            frame: stack.frame(in: .named(SidebarDensityTracker.contentSpace)),
                                            density: sidebarDensity)
                                    )
                                }
                            }
                            // Structural guarantee for the card metaphor.
                            //
                            // A vertical ScrollView does not clamp its rows to the
                            // viewport. Any descendant whose *minimum* width beats
                            // the sidebar — a fixed-slot row, a `fixedSize` label,
                            // anything that cannot truncate — widens the whole
                            // stack, and centre alignment then shifts every card
                            // left until its border, its inset, and the first
                            // characters of every line are outside the window.
                            //
                            // Individual offenders get fixed where they live (the
                            // pulse mark row measures and compresses). This is the
                            // backstop that keeps the next one from breaking the
                            // card at all: pinned to the viewport and leading
                            // aligned, an over-wide row can only clip its own
                            // right edge.
                            .frame(width: proxy.size.width, alignment: .leading)
                            .clipped()

                            SidebarEmptyArea(
                                rowSpacing: tabRowSpacing,
                                selection: $selection,
                                selectedWorkspaceIds: $selectedWorkspaceIds,
                                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                dragAutoScrollController: dragAutoScrollController,
                                draggedWorkspaceId: $draggedWorkspaceId,
                                draggedGroupId: $draggedGroupId,
                                dropIndicator: $dropIndicator
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(minHeight: proxy.size.height, alignment: .top)
                        .coordinateSpace(name: SidebarDensityTracker.contentSpace)
                    }
                    .background {
                        GeometryReader { scroll in
                            Color.clear.preference(key: SidebarScrollTopKey.self,
                                                   value: scroll.frame(in: .named(SidebarDensityTracker.rootSpace)).minY)
                        }
                    }
                    // The sidebar is a card rail, not a document; the overlay
                    // scroller renders as a grey bar over the cards (and the
                    // traffic-light strip) whenever the workspace list overflows.
                    .scrollIndicators(.never)
                    .background(SidebarHorizontalScrollAnchor(monitor: horizontalScrollMonitor))
                    .background(
                        SidebarScrollViewResolver { scrollView in
                            dragAutoScrollController.attach(scrollView: scrollView)
                            // Backstop for the .scrollIndicators modifier: SwiftUI's
                            // ScrollView is NSScrollView-backed here, and AppKit can
                            // still materialize an overlay scroller on scroll.
                            scrollView?.hasVerticalScroller = false
                            scrollView?.hasHorizontalScroller = false
                            scrollView?.verticalScroller = nil
                            scrollView?.horizontalScroller = nil
                        }
                        .frame(width: 0, height: 0)
                    )
                    .overlay(alignment: .top) {
                        SidebarTopScrim(height: sidebarTopReservedHeight + 20)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .top) {
                        // Match native titlebar behavior in the sidebar top strip:
                        // drag-to-move and double-click action (zoom/minimize).
                        WindowDragHandleView()
                            .frame(height: trafficLightPadding)
                    }
                    .overlay(alignment: .topLeading) {
                        if isMinimalMode {
                            HiddenTitlebarSidebarControlsView(notificationStore: notificationStore, sidebarState: sidebarState)
                                .padding(.leading, 8)
                                .padding(.top, trafficLightPadding + 2)
                        }
                    }
                    .background(Color.clear)
                    .modifier(ClearScrollBackground())
                    .onReceive(NotificationCenter.default.publisher(for: .sidebarRevealWorkspaceRequested)) { note in
                        guard (note.object as AnyObject?) === workspaceManager,
                              let workspaceId = note.userInfo?["workspaceId"] as? UUID else { return }
                        // Next turn: let the selection change land in the projection first.
                        DispatchQueue.main.async {
                            revealInSidebar(workspaceId: workspaceId, using: scrollProxy)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The footer floats over the scroll area: cards slide beneath
                // it and dissolve in its scrim instead of hard-clipping at a
                // structural boundary.
                SidebarFooter(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback,
                              columns: tileColumns, dense: sidebarDensity == .compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        GeometryReader { footer in
                            Color.clear.preference(
                                key: SidebarFooterMetricsKey.self,
                                value: SidebarFooterMetrics(
                                    frame: footer.frame(in: .named(SidebarDensityTracker.rootSpace)),
                                    dense: sidebarDensity == .compact))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // Terminal Grid's legend: one line floating in the scrim
                        // above the foot, so the footer keeps its height.
                        if sidebarStyle.sidebarLegend {
                            SidebarThemeLegend(style: sidebarStyle)
                                .padding(.horizontal, 12)
                                .offset(y: -16)
                                .allowsHitTesting(false)
                        }
                    }
                    .background {
                        // Solid blur under the controls, fading out over the
                        // cards above. Extends past the footer's top edge via
                        // the negative padding.
                        VStack(spacing: 0) {
                            SidebarBottomScrim(height: 28)
                            SidebarTopBlurEffect().opacity(0.95)
                        }
                        .padding(.top, -28)
                        .allowsHitTesting(false)
                    }
            }
        }
        .accessibilityIdentifier("Sidebar")
        .coordinateSpace(name: SidebarDensityTracker.rootSpace)
        .onPreferenceChange(SidebarStackMetricsKey.self) { metrics in
            densityTracker.stack = metrics
            updateSidebarDensity()
        }
        .onPreferenceChange(SidebarScrollTopKey.self) { top in
            densityTracker.scrollTop = top
            updateSidebarDensity()
        }
        .onPreferenceChange(SidebarFooterMetricsKey.self) { footer in
            densityTracker.footer = footer
            updateSidebarDensity()
        }
        .onPreferenceChange(SidebarCardHeightsKey.self) { cards in
            guard let cards, cards.density == .cards else { return }
            for (id, height) in cards.heights { densityTracker.cardHeights[id] = Double(height) }
        }
        .onChange(of: sidebarDensityRaw) { _ in updateSidebarDensity() }
        // Clearing the last flag can leave every frame where it was; decide again.
        .onReceive(SidebarDensityTracker.flagKindCounts) { kinds in
            guard kinds != densityTracker.flagKinds else { return }
            densityTracker.flagKinds = kinds
            updateSidebarDensity()
        }
        // The row list can settle after the stack already shrank; decide again then.
        .onChange(of: groupCoordinator.projection.visibleWorkspaceIds) { _ in updateSidebarDensity() }
        .ignoresSafeArea()
        .background(SidebarBackdrop().themeScanlines().ignoresSafeArea())
        .onAppear {
            groupCoordinator.attach(manager: workspaceManager, notificationStore: notificationStore)
            horizontalScrollMonitor.start { [workspaceManager] step in
                if step > 0 {
                    workspaceManager.selectNextWorkspace(cause: "shortcut")
                } else {
                    workspaceManager.selectPreviousWorkspace(cause: "shortcut")
                }
                workspaceManager.acknowledgeOperatorOpen(workspaceId: workspaceManager.selectedWorkspaceId)
            }
            draggedWorkspaceId = nil
            draggedGroupId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                workspaceId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            groupCoordinator.detach()
            horizontalScrollMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            draggedWorkspaceId = nil
            draggedGroupId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                workspaceId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: draggedWorkspaceId) { newDraggedWorkspaceId in
            SidebarDragLifecycleNotification.postStateDidChange(
                workspaceId: newDraggedWorkspaceId,
                reason: "drag_state_change"
            )
#if DEBUG
            dlog("sidebar.dragState.sidebar tab=\(debugShortSidebarWorkspaceId(newDraggedWorkspaceId))")
#endif
            if newDraggedWorkspaceId != nil {
                dragFailsafeMonitor.start {
                    SidebarDragLifecycleNotification.postClearRequest(reason: $0)
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dropIndicator = nil
        }
        .onChange(of: draggedGroupId) { groupId in
            if groupId != nil {
                dragFailsafeMonitor.start {
                    SidebarDragLifecycleNotification.postClearRequest(reason: $0)
                }
            } else if draggedWorkspaceId == nil {
                dragFailsafeMonitor.stop()
                dragAutoScrollController.stop()
                dropIndicator = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard draggedWorkspaceId != nil || draggedGroupId != nil else {
                // A drag from another window (C11H-207) may have lit an
                // indicator here with no local drag state.
                if dropIndicator != nil { dropIndicator = nil }
                return
            }
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
#if DEBUG
            dlog("sidebar.dragClear tab=\(debugShortSidebarWorkspaceId(draggedWorkspaceId)) reason=\(reason)")
#endif
            draggedWorkspaceId = nil
            draggedGroupId = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// New Group. A schema-2 theme sets its radius (`geometry.controlRadius`),
    /// type (`cardLabel`) and, through its card colours, fill, edge and ink.
    private func groupControls(style: SidebarThemeStyle, compact: Bool = false) -> some View {
        let radius = style.controlRadius ?? 5
        let title = draggedWorkspaceId == nil
            ? String(localized: "workspaceGroup.new", defaultValue: "New Group")
            : String(localized: "workspaceGroup.drop.ungroup", defaultValue: "Move to Ungrouped")
        return Button {
            newGroupFocusTarget = WorkspaceGroupEditorFocusTarget.capture()
            showingNewGroup = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: draggedWorkspaceId == nil ? "folder.badge.plus" : "tray.and.arrow.down")
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(verbatim: style.cardLabel.apply(title))
                    .chromeStyle(style.cardLabel, size: 12)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .themedForeground(style.cardText)
            .padding(.horizontal, 12)
            .frame(height: compact ? 22 : 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("WorkspaceGroupNew")
        .background(style.cardFill ?? Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
        .overlay {
            if let edge = style.cardBorder {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(edge, lineWidth: style.cardBorderPt ?? 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let indicator = dropIndicator,
               indicator.workspaceId == nil && indicator.groupId == nil {
                RoundedRectangle(cornerRadius: radius).stroke(cmuxAccentColor(), lineWidth: 2)
            }
        }
        .onDrop(of: SidebarWorkspaceDragPayload.dropContentTypes, delegate: SidebarWorkspaceDropDelegate(
            targetWorkspaceId: nil, workspaceManager: workspaceManager,
            draggedWorkspaceId: $draggedWorkspaceId, draggedGroupId: $draggedGroupId,
            selectedWorkspaceIds: $selectedWorkspaceIds, lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: nil, dragAutoScrollController: dragAutoScrollController, dropIndicator: $dropIndicator
        ))
        .contextMenu {
            Button(String(localized: "workspaceGroup.new", defaultValue: "New Group")) {
                newGroupFocusTarget = WorkspaceGroupEditorFocusTarget.capture()
                showingNewGroup = true
            }
        }
        .popover(isPresented: $showingNewGroup) {
            WorkspaceGroupNameEditor(
                initialName: "",
                title: String(localized: "workspaceGroup.new", defaultValue: "New Group"),
                submitTitle: String(localized: "workspaceGroup.create", defaultValue: "Create"),
                focusTarget: newGroupFocusTarget,
                onSubmit: { name in _ = try workspaceManager.createWorkspaceGroup(name: name) },
                onDismiss: { showingNewGroup = false }
            )
        }
        .padding(.horizontal, 6)
    }

    /// Thin bar in the group's color down the leading edge of the group's block
    /// (header plus member rows). Drawn as an overlay so no row content moves;
    /// `continuesBelow` extends it through the inter-row gap so the bar reads as
    /// one stroke. Groups without a color draw nothing.
    @ViewBuilder
    private func groupColorBar(groupId: UUID?, continuesBelow: Bool) -> some View {
        if let groupId,
           let hex = groupCoordinator.projection.headersById[groupId]?.group.color,
           let color = WorkspaceColorSettings.displayColor(hex: hex, colorScheme: colorScheme) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
                .padding(.leading, 1)
                .padding(.bottom, continuesBelow ? -tabRowSpacing : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// `sidebarWidth` is the stack's width; the header is 6pt in from each side.
    private func groupHeader(_ header: WorkspaceGroupSidebarHeader, chromeTokens: ChromeScaleTokens,
                             palette: [WorkspaceColorEntry], style: SidebarThemeStyle,
                             sidebarWidth: CGFloat) -> some View {
        WorkspaceGroupHeaderView(
            group: header.group, summary: header.summary, isActive: header.isActive,
            scale: chromeTokens.multiplier, colorScheme: colorScheme, palette: palette,
            compact: sidebarDensity == .compact, captain: header.captain, states: style.statePalette,
            style: style, availableWidth: max(0, sidebarWidth - 12),
            onToggleCollapse: { id in
                guard let group = workspaceManager.workspaceGroups.first(where: { $0.id == id }) else { return }
                try? workspaceManager.setWorkspaceGroupCollapsed(id: id, collapsed: !group.isCollapsed)
            },
            onFocus: { id in
                guard let selected = try? SocketCommandContext.withContext(nil, { try workspaceManager.withWorkspaceSelectionCause("sidebar") { try workspaceManager.focusWorkspaceGroup(id: id) } }) else { return }
                // C11H-246: a group-name click opens the panel its workspace shows.
                workspaceManager.acknowledgeOperatorOpen(workspaceId: selected)
                selectedWorkspaceIds = [selected]
                lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == selected }
                selection = .tabs
            },
            onRename: { try workspaceManager.renameWorkspaceGroup(id: $0, name: $1) },
            onSetColor: { try workspaceManager.setWorkspaceGroupColor(id: $0, color: $1) },
            onSetIcon: { try workspaceManager.setWorkspaceGroupIcon(id: $0, icon: $1) },
            onTogglePin: { id in
                guard let group = workspaceManager.workspaceGroups.first(where: { $0.id == id }) else { return }
                try? workspaceManager.setWorkspaceGroupPinned(id: id, pinned: !group.isPinned)
            },
            onUngroup: { try? workspaceManager.deleteWorkspaceGroup(id: $0) },
            onDelete: { try? workspaceManager.deleteWorkspaceGroup(id: $0) }
        )
        .equatable()
        .opacity(draggedGroupId == header.group.id ? 0.6 : 1)
        .overlay {
            if dropIndicator?.groupId == header.group.id && dropIndicator?.isGroupBody == true {
                RoundedRectangle(cornerRadius: 6).stroke(cmuxAccentColor(), lineWidth: 2)
            }
        }
        .overlay(alignment: .top) {
            if dropIndicator?.groupId == header.group.id && dropIndicator?.isGroupBody == false && dropIndicator?.edge == .top {
                Rectangle().fill(cmuxAccentColor()).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if dropIndicator?.groupId == header.group.id && dropIndicator?.isGroupBody == false && dropIndicator?.edge == .bottom
                && (header.group.isCollapsed || header.summary.memberCount == 0) {
                Rectangle().fill(cmuxAccentColor()).frame(height: 2)
            }
        }
        .onDrag {
            draggedWorkspaceId = nil
            draggedGroupId = header.group.id
            dropIndicator = nil
            return SidebarGroupDragPayload.provider(for: header.group.id)
        }
        .internalOnlyPanelDrag()
        .onDrop(of: SidebarWorkspaceDragPayload.dropContentTypes + SidebarGroupDragPayload.dropContentTypes,
                delegate: SidebarWorkspaceDropDelegate(
                    targetWorkspaceId: nil, targetGroupId: header.group.id, workspaceManager: workspaceManager,
                    draggedWorkspaceId: $draggedWorkspaceId, draggedGroupId: $draggedGroupId,
                    selectedWorkspaceIds: $selectedWorkspaceIds, lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    targetRowHeight: WorkspaceGroupHeaderView.height(scale: chromeTokens.multiplier,
                                                                     compact: sidebarDensity == .compact),
                    dragAutoScrollController: dragAutoScrollController, dropIndicator: $dropIndicator
                ))
        .padding(.horizontal, 6)
    }

    /// Drop target for a panel dragged out of a panel strip: the card under
    /// the cursor turns gold, and releasing moves the panel into that
    /// workspace's focused area. The operator stays where they are, so several
    /// panels can be moved in a row.
    private func panelDropOverlay(rowAnchors: [UUID: Anchor<CGRect>], cardRadius: CGFloat) -> some View {
        GeometryReader { proxy in
            let rows = rowAnchors.map { SidebarPanelDropView.Row(workspaceId: $0.key, frame: proxy[$0.value]) }
            ZStack {
                if let targetId = panelDropTargetWorkspaceId,
                   let row = rows.first(where: { $0.workspaceId == targetId }) {
                    // The card sits inside the row's 6pt horizontal inset.
                    let card = row.frame.insetBy(dx: 6, dy: 0)
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .fill(BrandColors.goldSwiftUI.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                                .strokeBorder(BrandColors.goldSwiftUI, lineWidth: 2)
                        )
                        .frame(width: card.width, height: card.height)
                        .position(x: card.midX, y: card.midY)
                        .allowsHitTesting(false)
                }
                SidebarPanelDropOverlay(
                    rows: rows,
                    targetWorkspaceId: $panelDropTargetWorkspaceId
                )
            }
        }
    }

    private func workspaceRow(_ ws: Workspace, item: WorkspaceGroupSidebarWorkspaceRow, chromeTokens: ChromeScaleTokens,
                              style: SidebarThemeStyle) -> some View {
        let index = item.canonicalIndex
        let workspaceCount = workspaceManager.workspaces.count
        let canCloseWorkspace = workspaceCount > 1
        let selectedContextIds: Set<UUID> = selectedWorkspaceIds.contains(ws.id) ? selectedWorkspaceIds : [ws.id]
        let contextTargetIds = workspaceManager.workspaces.compactMap { workspace in
            selectedContextIds.contains(workspace.id) ? workspace.id : nil
        }
        let remoteContextMenuTargets = workspaceManager.workspaces.filter { workspace in
            contextTargetIds.contains(workspace.id) && workspace.isRemoteWorkspace
        }
        let isActive = workspaceManager.selectedWorkspaceId == ws.id
        let isMultiSelected = selectedWorkspaceIds.contains(ws.id)
        let themedColors = themedSidebarWorkspaceColors(
            workspace: ws,
            isActive: isActive,
            isMultiSelected: isMultiSelected
        )
        // C11-104 v2: precompute worktree+branch
        // chips for the focused surface. Reads the
        // resolver output directly from the
        // workspace's `panelGitContexts` (populated
        // by the off-main probe in TabManager).
        // Branch chip's dirty marker comes from the
        // existing `panelGitBranches[surfaceId].isDirty`
        // signal so the legacy UX is preserved.
        let worktreeChipRows: [WorktreeChipRow] = {
            guard sidebarShowBranchDirectory,
                  let focusedId = ws.focusedPanelId else {
                return []
            }
            let context = ws.panelGitContexts[focusedId] ?? nil
            let isDirty = ws.panelGitBranches[focusedId]?.isDirty ?? false
            return WorktreeChipProjector.project(
                context,
                settingsEnabled: true,
                isDirty: isDirty
            )
        }()
        // Workspace Pulse preview: project existing exact
        // notification + agent liveness truth once in the
        // parent. TabItemView receives an immutable value so
        // its typing-hot body does no metadata/store work.
        let unreadCount = notificationStore.unreadCount(forWorkspaceId: ws.id)
        let pulseRoster: (
            agents: [WorkspacePulseAgent],
            terminalCount: Int,
            browserCount: Int,
            documentCount: Int
        ) = {
            var agents: [WorkspacePulseAgent] = []
            var terminalCount = 0
            var browserCount = 0
            var documentCount = 0
            for panelId in ws.sidebarOrderedPanelIds() {
                let terminalKind = ws.surfaceActivityTerminalKind(panelId: panelId)
                guard AreaSizePolicy.isAgentKind(terminalKind) else {
                    switch ws.panels[panelId]?.panelType {
                    case .terminal: terminalCount += 1
                    case .browser: browserCount += 1
                    case .markdown: documentCount += 1
                    case nil: break
                    }
                    continue
                }
                let resolved = ws.resolvedSurfacePanelActivityState(
                    panelId: panelId,
                    hasExactSurfaceNotification: notificationStore.hasUnreadNotification(
                        forWorkspaceId: ws.id,
                        surfaceId: panelId
                    ),
                    terminalKind: .some(terminalKind)
                )
                let pulseState: WorkspacePulseState
                switch resolved {
                case .waiting: pulseState = .waiting
                case .running: pulseState = .working
                case .idle: pulseState = .idle
                case .cold: pulseState = .cold
                case nil: continue
                }
                let titleBarState = ws.panelTitleBarState(panelId: panelId)
                let reportedTitle = titleBarState.title?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let context = WorkspacePulseAgentContextProjector.project(
                    title: reportedTitle?.isEmpty == false
                        ? titleBarState.title
                        : ws.panels[panelId]?.displayTitle,
                    subtitle: showsSidebarNotificationMessage
                        ? titleBarState.description
                        : nil,
                    descriptionUpdatedAt: titleBarState.descriptionUpdatedAt
                )
                let attention = ws.attentionSnapshot(panelId: panelId)
                let activityHelp = ws.resolvedAgentActivityHelp(
                    panelId: panelId,
                    activityState: resolved
                )
                agents.append(
                    WorkspacePulseAgent(
                        surfaceId: panelId,
                        state: pulseState,
                        context: context,
                        flagged: attention.isFlagged,
                        suppressed: attention.suppressed,
                        flagReason: attention.flagReason,
                        flagKind: attention.flagKind,
                        activityHelp: activityHelp,
                        lineageDepth: attention.delegated ? ws.delegationDepth(panelId: panelId) : 0
                    )
                )
            }
            return (agents, terminalCount, browserCount, documentCount)
        }()
        let workspacePulse = WorkspacePulseProjector.project(
            hasWorkspaceDemand: unreadCount > 0,
            agents: pulseRoster.agents,
            terminalCount: pulseRoster.terminalCount,
            browserCount: pulseRoster.browserCount,
            documentCount: pulseRoster.documentCount
        )
        return WorkspaceRowView(
            workspaceManager: workspaceManager,
            notificationStore: notificationStore,
            workspace: ws,
            index: index,
            visibleWorkspaceIds: groupCoordinator.projection.visibleWorkspaceIds,
            availableGroups: workspaceManager.workspaceGroups,
            isActive: isActive,
            worktreeChipRows: worktreeChipRows,
            missionSnapshot: ws.mission,
            captainSnapshot: ws.captainSummary,
            canCloseWorkspace: canCloseWorkspace,
            accessibilityWorkspaceCount: workspaceCount,
            unreadCount: unreadCount,
            workspacePulse: workspacePulse,
            rowSpacing: tabRowSpacing,
            setSelectionToTabs: { selection = .tabs },
            selectedWorkspaceIds: $selectedWorkspaceIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            showsWorkspaceId: showWorkspaceIds,
            dragAutoScrollController: dragAutoScrollController,
            draggedWorkspaceId: $draggedWorkspaceId,
            draggedGroupId: $draggedGroupId,
            dropIndicator: $dropIndicator,
            themedBackgroundColor: themedColors.background,
            themedRailColor: themedColors.rail,
            themedFillCarriesWorkspaceColor: themedColors.fillCarriesWorkspaceColor,
            remoteContextMenuWorkspaceIds: remoteContextMenuTargets.map(\.id),
            allRemoteContextMenuTargetsConnecting: !remoteContextMenuTargets.isEmpty && remoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .connecting },
            allRemoteContextMenuTargetsDisconnected: !remoteContextMenuTargets.isEmpty && remoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected },
            sidebarFlashSnapshot: ws.sidebarFlashRequest,
            chromeTokens: chromeTokens,
            tiled: compact,
            themeStyle: style,
            density: sidebarDensity
        )
        .equatable()
    }

    @ViewBuilder
    private func tileRows(_ rows: [WorkspaceGroupSidebarRow], workspacesById: [UUID: Workspace],
                          chromeTokens: ChromeScaleTokens, palette: [WorkspaceColorEntry],
                          style: SidebarThemeStyle, sidebarWidth: CGFloat) -> some View {
        ForEach(rows) { row in
            Group {
                switch row {
                case .group(let header):
                    groupHeader(header, chromeTokens: chromeTokens, palette: palette, style: style,
                                sidebarWidth: sidebarWidth)
                        .overlay(alignment: .topLeading) {
                            groupColorBar(
                                groupId: header.group.id,
                                continuesBelow: !header.group.isCollapsed && header.summary.memberCount > 0
                            )
                        }
                case .workspace(let item):
                    if let ws = workspacesById[item.workspaceId] {
                        workspaceRow(ws, item: item, chromeTokens: chromeTokens, style: style)
                            .anchorPreference(key: SidebarWorkspaceRowAnchorKey.self, value: .bounds) { [ws.id: $0] }
                            .padding(.leading, item.groupId == nil ? 0 : 12)
                            .overlay(alignment: .topLeading) {
                                groupColorBar(
                                    groupId: item.groupId,
                                    continuesBelow: !item.isLastGroupMember
                                )
                            }
                            .overlay(alignment: .bottom) {
                                if item.isLastGroupMember,
                                   dropIndicator?.groupId == item.groupId,
                                   dropIndicator?.isGroupBody == false, dropIndicator?.edge == .bottom {
                                    Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.horizontal, 6)
                                }
                            }
                    }
                }

            }
            .id(row.id)
        }
    }

    private func debugShortSidebarWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

enum ShortcutHintModifierPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard normalized == [.command] else {
            return false
        }
        return ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(defaults: defaults)
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldShowHints(for: modifierFlags, defaults: defaults) &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

enum ShortcutHintDebugSettings {
    static let titlebarHintXKey = "shortcutHintTitlebarXOffset"
    static let titlebarHintYKey = "shortcutHintTitlebarYOffset"
    static let paneHintXKey = "shortcutHintPaneTabXOffset"
    static let paneHintYKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowHintsKey = "shortcutHintAlwaysShow"
    static let showHintsOnCommandHoldKey = "shortcutHintShowOnCommandHold"

    static let defaultTitlebarHintX = 4.0
    static let defaultTitlebarHintY = 0.0
    static let defaultPaneHintX = 0.0
    static let defaultPaneHintY = 0.0
    static let defaultAlwaysShowHints = false
    static let defaultShowHintsOnCommandHold = true

    static let offsetRange: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnCommandHoldKey) != nil else {
            return defaultShowHintsOnCommandHold
        }
        return defaults.bool(forKey: showHintsOnCommandHoldKey)
    }

    static func resetVisibilityDefaults(defaults: UserDefaults = .standard) {
        defaults.set(defaultAlwaysShowHints, forKey: alwaysShowHintsKey)
        defaults.set(defaultShowHintsOnCommandHold, forKey: showHintsOnCommandHoldKey)
    }
}

enum DevBuildBannerDebugSettings {
    static let sidebarBannerVisibleKey = "showSidebarDevBuildBanner"
    static let defaultShowSidebarBanner = true

    static func showSidebarBanner(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: sidebarBannerVisibleKey) != nil else {
            return defaultShowSidebarBanner
        }
        return defaults.bool(forKey: sidebarBannerVisibleKey)
    }
}

private enum FeedbackComposerSettings {
    static let storedEmailKey = "sidebarHelpFeedbackEmail"
    static let endpointEnvironmentKey = "CMUX_FEEDBACK_API_URL"
    // Empty default no-ops the feedback POST unless CMUX_FEEDBACK_API_URL is
    // set. Pending: stand up a Stage 11-owned feedback endpoint and wire it
    // here. UI already renders a "Feedback is unavailable" fallback when
    // endpointURL() returns nil.
    static let defaultEndpoint = ""
    static let foundersEmail = "hello@stage11.ai"
    static let maxMessageLength = 4_000
    static let maxAttachmentCount = 10
    // Keep the multipart body below Vercel's 4.5 MB request limit.
    static let maxTotalAttachmentBytes = 4 * 1_024 * 1_024
    static let targetTotalAttachmentUploadBytes = 3_500_000

    static func endpointURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env[endpointEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: defaultEndpoint)
    }
}

private struct FeedbackComposerAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64
    let mimeType: String

    var standardizedPath: String {
        url.standardizedFileURL.path
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    init(url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .nameKey,
        ])
        guard resourceValues.isRegularFile != false else {
            throw CocoaError(.fileReadUnknown)
        }

        self.url = url
        self.fileName = resourceValues.name ?? url.lastPathComponent
        self.fileSize = Int64(resourceValues.fileSize ?? 0)
        self.mimeType = resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream"
    }
}

private struct PreparedFeedbackComposerAttachment {
    let fileName: String
    let mimeType: String
    let data: Data
}

private struct FeedbackComposerAppMetadata {
    let appVersion: String
    let appBuild: String
    let appCommit: String
    let bundleIdentifier: String
    let osVersion: String
    let localeIdentifier: String
    let hardwareModel: String
    let chip: String
    let memoryGB: String
    let architecture: String
    let displayInfo: String

    static var current: FeedbackComposerAppMetadata {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let commit = C11BuildIdentity.resolveCommit(info: infoDictionary, environment: env)

        return FeedbackComposerAppMetadata(
            appVersion: infoDictionary["CFBundleShortVersionString"] as? String ?? "",
            appBuild: infoDictionary["CFBundleVersion"] as? String ?? "",
            appCommit: commit ?? "",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hardwareModel: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            memoryGB: formatMemoryGB(),
            architecture: currentArchitecture(),
            displayInfo: currentDisplayInfo()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMemoryGB() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return "\(Int(gb)) GB"
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func currentDisplayInfo() -> String {
        let screens = NSScreen.screens
        let descriptions = screens.map { screen -> String in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return "\(Int(frame.width))x\(Int(frame.height)) @\(Int(scale))x"
        }
        let count = screens.count
        let prefix = "\(count) display\(count == 1 ? "" : "s")"
        return "\(prefix), \(descriptions.joined(separator: "; "))"
    }
}

private enum FeedbackComposerSubmissionError: Error {
    case invalidEndpoint
    case invalidResponse
    case rejected(statusCode: Int)
    case attachmentReadFailed
    case attachmentPreparationFailed
    case transport(URLError)
}

private enum FeedbackComposerClient {
    private static let passthroughAttachmentMIMETypes: Set<String> = [
        "image/gif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/png",
        "image/tiff",
        "image/webp",
    ]
    private static let optimizedAttachmentDimensions: [Int] = [2800, 2400, 2000, 1600, 1280, 1024, 768, 640, 512]
    private static let optimizedAttachmentQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]
    private static let optimizedAttachmentMIMEType = "image/jpeg"

    static func submit(
        email: String,
        message: String,
        attachments: [FeedbackComposerAttachment]
    ) async throws {
        guard let endpointURL = FeedbackComposerSettings.endpointURL() else {
            throw FeedbackComposerSubmissionError.invalidEndpoint
        }

        let metadata = FeedbackComposerAppMetadata.current
        let boundary = "Boundary-\(UUID().uuidString)"
        let preparedAttachments = try prepareAttachmentsForUpload(attachments)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        appendField("email", value: email, to: &body, boundary: boundary)
        appendField("message", value: message, to: &body, boundary: boundary)
        appendField("appVersion", value: metadata.appVersion, to: &body, boundary: boundary)
        appendField("appBuild", value: metadata.appBuild, to: &body, boundary: boundary)
        appendField("appCommit", value: metadata.appCommit, to: &body, boundary: boundary)
        appendField("bundleIdentifier", value: metadata.bundleIdentifier, to: &body, boundary: boundary)
        appendField("osVersion", value: metadata.osVersion, to: &body, boundary: boundary)
        appendField("locale", value: metadata.localeIdentifier, to: &body, boundary: boundary)
        appendField("hardwareModel", value: metadata.hardwareModel, to: &body, boundary: boundary)
        appendField("chip", value: metadata.chip, to: &body, boundary: boundary)
        appendField("memoryGB", value: metadata.memoryGB, to: &body, boundary: boundary)
        appendField("architecture", value: metadata.architecture, to: &body, boundary: boundary)
        appendField("displayInfo", value: metadata.displayInfo, to: &body, boundary: boundary)

        for attachment in preparedAttachments {
            appendFile(
                named: "attachments",
                attachment: attachment,
                to: &body,
                boundary: boundary
            )
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw FeedbackComposerSubmissionError.transport(error)
        } catch {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackComposerSubmissionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = payload["error"] as? String,
               errorMessage.isEmpty == false {
                NSLog("feedback.submit.rejected status=%@ error=%@", String(httpResponse.statusCode), errorMessage)
            }
            throw FeedbackComposerSubmissionError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private static func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private static func prepareAttachmentsForUpload(
        _ attachments: [FeedbackComposerAttachment]
    ) throws -> [PreparedFeedbackComposerAttachment] {
        guard attachments.isEmpty == false else { return [] }

        struct IndexedAttachment {
            let index: Int
            let attachment: FeedbackComposerAttachment
        }

        let sortedAttachments = attachments.enumerated()
            .map { IndexedAttachment(index: $0.offset, attachment: $0.element) }
            .sorted { lhs, rhs in
                lhs.attachment.fileSize > rhs.attachment.fileSize
            }

        var preparedByIndex: [Int: PreparedFeedbackComposerAttachment] = [:]
        var remainingBudget = FeedbackComposerSettings.targetTotalAttachmentUploadBytes
        var remainingCount = sortedAttachments.count

        for item in sortedAttachments {
            let perAttachmentBudget = max(1, remainingBudget / max(remainingCount, 1))
            let preparedAttachment = try prepareAttachmentForUpload(
                item.attachment,
                maximumByteCount: perAttachmentBudget
            )
            preparedByIndex[item.index] = preparedAttachment
            remainingBudget -= preparedAttachment.data.count
            remainingCount -= 1
        }

        let preparedAttachments = attachments.indices.compactMap { preparedByIndex[$0] }
        let totalBytes = preparedAttachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= FeedbackComposerSettings.targetTotalAttachmentUploadBytes else {
            throw FeedbackComposerSubmissionError.attachmentPreparationFailed
        }
        return preparedAttachments
    }

    private static func prepareAttachmentForUpload(
        _ attachment: FeedbackComposerAttachment,
        maximumByteCount: Int
    ) throws -> PreparedFeedbackComposerAttachment {
        if attachment.fileSize > 0,
           attachment.fileSize <= Int64(maximumByteCount),
           passthroughAttachmentMIMETypes.contains(attachment.mimeType),
           let fileData = try? Data(contentsOf: attachment.url, options: .mappedIfSafe) {
            return PreparedFeedbackComposerAttachment(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: fileData
            )
        }

        guard let imageSource = CGImageSourceCreateWithURL(attachment.url as CFURL, nil) else {
            throw FeedbackComposerSubmissionError.attachmentReadFailed
        }

        for maxPixelDimension in optimizedAttachmentDimensions {
            guard let cgImage = downsampledImage(
                from: imageSource,
                maxPixelDimension: maxPixelDimension
            ) else { continue }

            for compressionQuality in optimizedAttachmentQualities {
                guard let jpegData = jpegData(
                    from: cgImage,
                    compressionQuality: compressionQuality
                ) else { continue }
                guard jpegData.count <= maximumByteCount else { continue }

                return PreparedFeedbackComposerAttachment(
                    fileName: optimizedFileName(for: attachment),
                    mimeType: optimizedAttachmentMIMEType,
                    data: jpegData
                )
            }
        }

        throw FeedbackComposerSubmissionError.attachmentPreparationFailed
    }

    private static func downsampledImage(
        from imageSource: CGImageSource,
        maxPixelDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            ] as CFDictionary
        )
    }

    private static func jpegData(
        from image: CGImage,
        compressionQuality: CGFloat
    ) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality,
            ]
        )
    }

    private static func optimizedFileName(
        for attachment: FeedbackComposerAttachment
    ) -> String {
        let baseName = (attachment.fileName as NSString).deletingPathExtension
        return "\(baseName.isEmpty ? "feedback-image" : baseName).jpg"
    }

    private static func appendFile(
        named fieldName: String,
        attachment: PreparedFeedbackComposerAttachment,
        to body: inout Data,
        boundary: String
    ) {
        let sanitizedFileName = attachment.fileName.replacingOccurrences(of: "\"", with: "")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(sanitizedFileName)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(attachment.mimeType)\r\n\r\n".utf8))
        body.append(attachment.data)
        body.append(Data("\r\n".utf8))
    }
}

/// C11H-207: watches one drag (a sidebar workspace card or a panel's tab) for
/// a release outside every c11 window, and then runs that drag's tear-off
/// (open it in a new window at that point). It polls the mouse button only
/// while a drag is live, because the drag session swallows the mouse-up an
/// event monitor would see, and is idle otherwise.
@MainActor
final class DragTearOffWatcher {
    static let shared = DragTearOffWatcher()

    private var timer: Timer?
    private var keyMonitor: Any?
    private var action: ((NSPoint) -> Void)?
    private var label = ""
    private var startedAt: TimeInterval = 0
    private var cancelled = false

    /// A newer drag replaces the one being watched.
    func begin(_ label: String, onReleaseOutside action: @escaping (NSPoint) -> Void) {
        stop()
        self.label = label
        self.action = action
        startedAt = ProcessInfo.processInfo.systemUptime
        cancelled = false
        // Escape cancels the drag; a release after it is not a tear-off.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelled = true }
            return event
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let action else { stop(); return }
        // The drag session swallows the Escape a key monitor would see, and a
        // poll can miss a quick tap: any key pressed since the drag began
        // (Escape cancels the drag) means the release is not a tear-off.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if sinceKey < ProcessInfo.processInfo.systemUptime - startedAt
            || CGEventSource.keyState(.combinedSessionState, key: 53) {
            cancelled = true
        }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            // A drag never lasts this long; give up rather than poll forever.
            if ProcessInfo.processInfo.systemUptime - startedAt > 120 { stop() }
            return
        }
        let point = NSEvent.mouseLocation
        let wasCancelled = cancelled
        let label = self.label
        stop()
        guard !wasCancelled, !Self.isOverAppWindow(point) else { return }
#if DEBUG
        dlog("drag.tearOff.release kind=\(label) point=\(Int(point.x)),\(Int(point.y))")
#endif
        // Let a drop that did land settle first; each action re-checks that
        // its item is still where the drag found it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action(point) }
    }

    /// Over any c11 window on this Space: titled windows (main windows,
    /// Settings and the rest), child windows such as a folded strip's panel
    /// sheet, and panels. The drag image is none of these.
    static func isOverAppWindow(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && window.alphaValue > 0
                && (window.styleMask.contains(.titled) || window.parent != nil || window is NSPanel)
                && NSMouseInRect(point, window.frame, false)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        action = nil
    }
}

/// C11H-207: the slot another window's sidebar last showed for a dragged card.
/// The window a card is dragged out of can come forward at release (AppKit's
/// deferred window ordering for its mouse-down), over the sidebar the card was
/// shown landing in; its own panels or sidebar then take the drop. The source
/// window commits this record instead, when the window that showed it sat above
/// the source at drag start and the pointer is inside it.
@MainActor
enum SidebarForeignHover {
    struct Record {
        let workspaceId: UUID
        let windowId: UUID
        let groupId: UUID?
        let before: UUID?
        let after: UUID?
    }

    private(set) static var last: Record?
    /// The c11 main windows stacked above the source window when the drag
    /// began. Only one of them can be covered when the source comes forward
    /// at release, so only their records count.
    private static var windowsAboveSource: [UUID: NSRect] = [:]

    static func beginDrag(sourceWindow: NSWindow?) {
        last = nil
        windowsAboveSource = [:]
        guard let sourceWindow, let app = AppDelegate.shared else { return }
        for window in NSApp.orderedWindows {
            if window === sourceWindow { break }
            if window.isVisible, let id = app.mainWindowId(for: window) {
                windowsAboveSource[id] = window.frame
            }
        }
    }

    /// Whether the pointer is over a window that sat above the source when the
    /// drag began: the operator saw that window there, not the source.
    static func pointerWasOverAnotherWindow(_ pointer: NSPoint) -> Bool {
        windowsAboveSource.values.contains { NSMouseInRect(pointer, $0, false) }
    }

    static func note(_ record: Record) { last = record }

    static func reset() { last = nil }

    /// The record for this card, if its window sat above the source when the
    /// drag began (so the source coming forward at release can cover it) and
    /// the pointer is inside that window. No timer: a window that was behind
    /// the source can never qualify, so a drop the operator aimed at the
    /// source itself is never redirected.
    static func pending(workspaceId: UUID, pointer: NSPoint) -> Record? {
        guard let record = last, record.workspaceId == workspaceId else { return nil }
        guard windowsAboveSource[record.windowId] != nil,
              let window = AppDelegate.shared?.mainWindow(for: record.windowId),
              NSMouseInRect(pointer, window.frame, false) else {
#if DEBUG
            dlog(
                "sidebar.foreignHover.decline ws=\(workspaceId.uuidString.prefix(5)) " +
                "window=\(record.windowId.uuidString.prefix(5)) above=\(windowsAboveSource[record.windowId] != nil ? 1 : 0) " +
                "aboveCount=\(windowsAboveSource.count)"
            )
#endif
            return nil
        }
        return record
    }
}

enum SidebarDragLifecycleNotification {
    static let stateDidChange = Notification.Name("cmux.sidebarDragStateDidChange")
    static let requestClear = Notification.Name("cmux.sidebarDragRequestClear")
    static let workspaceIdKey = "tabId"
    static let reasonKey = "reason"

    static func postStateDidChange(workspaceId: UUID?, reason: String) {
        var userInfo: [AnyHashable: Any] = [reasonKey: reason]
        if let workspaceId {
            userInfo[workspaceIdKey] = workspaceId
        }
        NotificationCenter.default.post(
            name: stateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func postClearRequest(reason: String) {
        NotificationCenter.default.post(
            name: requestClear,
            object: nil,
            userInfo: [reasonKey: reason]
        )
    }

    static func workspaceId(from notification: Notification) -> UUID? {
        notification.userInfo?[workspaceIdKey] as? UUID
    }

    static func reason(from notification: Notification) -> String {
        notification.userInfo?[reasonKey] as? String ?? "unknown"
    }
}

enum SidebarOutsideDropResetPolicy {
    static func shouldResetDrag(draggedWorkspaceId: UUID?, hasSidebarDragPayload: Bool) -> Bool {
        draggedWorkspaceId != nil && hasSidebarDragPayload
    }
}

enum SidebarDragFailsafePolicy {
    static let clearDelay: TimeInterval = 0.15

    static func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    static func shouldRequestClearWhenMonitoringStarts(isLeftMouseButtonDown: Bool) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    static func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}

/// Turns horizontal scroll over the sidebar into workspace steps, so a mouse's
/// horizontal wheel (the MX Master thumb wheel) or a two-finger swipe walks the
/// workspace list like Next/Previous Workspace. Vertical scroll passes through
/// untouched. Scrolling right (negative deltaX) steps to the next workspace.
struct SidebarHorizontalScrollWorkspaceStepper {
    enum Outcome: Equatable {
        /// Not a horizontal scroll; the sidebar scrolls as usual.
        case passThrough
        /// A horizontal scroll, swallowed. `step` is 1 (next), -1 (previous) or 0.
        case consume(step: Int)
    }

    /// Precise deltas (trackpads, smooth-scrolling wheels) arrive in points.
    static let preciseThreshold: CGFloat = 36
    /// Line-based wheels report lines; one line is one workspace.
    static let lineThreshold: CGFloat = 1
    /// Minimum spacing between wheel steps, so a fast spin of a free-running
    /// thumb wheel stays countable instead of racing through the list.
    static let minimumWheelStepInterval: TimeInterval = 0.09
    /// A wheel pause this long discards a partial accumulation.
    static let wheelIdleReset: TimeInterval = 0.35

    private var accumulated: CGFloat = 0
    /// Axis a phased gesture (trackpad, Magic Mouse) latched on its first
    /// moving event; its remaining events and momentum follow it.
    private var gestureIsHorizontal: Bool?
    private var gestureHasStepped = false
    private var lastWheelEventTime: TimeInterval?
    private var lastWheelStepTime: TimeInterval?

    mutating func reset() {
        accumulated = 0
        gestureIsHorizontal = nil
        gestureHasStepped = false
        lastWheelEventTime = nil
        lastWheelStepTime = nil
    }

    mutating func handle(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        timestamp: TimeInterval
    ) -> Outcome {
        if !momentumPhase.isEmpty {
            return gestureIsHorizontal == true ? .consume(step: 0) : .passThrough
        }

        if !phase.isEmpty {
            if phase.contains(.began) || phase.contains(.mayBegin) {
                accumulated = 0
                gestureIsHorizontal = nil
                gestureHasStepped = false
            }
            if gestureIsHorizontal == nil, deltaX != 0 || deltaY != 0 {
                gestureIsHorizontal = abs(deltaX) > abs(deltaY)
            }
            guard gestureIsHorizontal == true else { return .passThrough }
            guard !gestureHasStepped else { return .consume(step: 0) }
            accumulated += deltaX
            guard abs(accumulated) >= Self.preciseThreshold else { return .consume(step: 0) }
            gestureHasStepped = true
            return .consume(step: accumulated < 0 ? 1 : -1)
        }

        // Unphased: a mouse wheel, decided event by event.
        gestureIsHorizontal = nil
        guard abs(deltaX) > abs(deltaY) else { return .passThrough }
        if let last = lastWheelEventTime, timestamp - last > Self.wheelIdleReset {
            accumulated = 0
        }
        lastWheelEventTime = timestamp
        if let lastStep = lastWheelStepTime, timestamp - lastStep < Self.minimumWheelStepInterval {
            return .consume(step: 0)
        }
        accumulated += deltaX
        let threshold = hasPreciseDeltas ? Self.preciseThreshold : Self.lineThreshold
        guard abs(accumulated) >= threshold else { return .consume(step: 0) }
        let step = accumulated < 0 ? 1 : -1
        accumulated = 0
        lastWheelStepTime = timestamp
        return .consume(step: step)
    }
}

/// Watches scroll events over the sidebar's workspace list and hands
/// horizontal ones to `SidebarHorizontalScrollWorkspaceStepper`. The list's
/// area is measured from `SidebarHorizontalScrollAnchor`, a view laid out
/// behind the list's ScrollView at the same frame.
@MainActor
private final class SidebarHorizontalScrollWorkspaceMonitor: ObservableObject {
    private weak var anchorView: NSView?
    private var scrollMonitor: Any?
    private var stepper = SidebarHorizontalScrollWorkspaceStepper()
    private var onStep: ((Int) -> Void)?

    func attach(anchorView: NSView) {
        self.anchorView = anchorView
    }

    func start(onStep: @escaping (Int) -> Void) {
        self.onStep = onStep
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
        onStep = nil
        stepper.reset()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let anchorView,
              let window = anchorView.window,
              let pointInWindow = Self.pointInWindow(of: event, window: window),
              anchorView.convert(anchorView.bounds, to: nil).contains(pointInWindow)
        else {
            stepper.reset()
            return event
        }
        let outcome = stepper.handle(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            timestamp: event.timestamp
        )
        switch outcome {
        case .passThrough:
            return event
        case .consume(let step):
#if DEBUG
            dlog(
                "sidebar.hscroll dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) " +
                "precise=\(event.hasPreciseScrollingDeltas ? 1 : 0) phase=\(event.phase.rawValue) " +
                "momentum=\(event.momentumPhase.rawValue) step=\(step)"
            )
#endif
            if step != 0 {
                onStep?(step)
            }
            return nil
        }
    }

    /// Hardware scrolls carry their window. A scroll posted straight to the
    /// process (automation, agents) carries none, and its location is in
    /// screen coordinates; it counts only for the window on top at that point,
    /// so overlapping c11 windows never both step.
    private static func pointInWindow(of event: NSEvent, window: NSWindow) -> NSPoint? {
        if let eventWindow = event.window {
            return eventWindow === window ? event.locationInWindow : nil
        }
        let screenPoint = event.locationInWindow
        guard window.frame.contains(screenPoint),
              NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return nil }
        return window.convertPoint(fromScreen: screenPoint)
    }
}

private struct SidebarHorizontalScrollAnchor: NSViewRepresentable {
    let monitor: SidebarHorizontalScrollWorkspaceMonitor

    func makeNSView(context: Context) -> SidebarHorizontalScrollAnchorView {
        let view = SidebarHorizontalScrollAnchorView()
        monitor.attach(anchorView: view)
        return view
    }

    func updateNSView(_ nsView: SidebarHorizontalScrollAnchorView, context: Context) {
        monitor.attach(anchorView: nsView)
    }
}

private final class SidebarHorizontalScrollAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class SidebarDragFailsafeMonitor: ObservableObject {
    private static let escapeKeyCode: UInt16 = 53
    private var pendingClearWorkItem: DispatchWorkItem?
    private var appResignObserver: NSObjectProtocol?
    private var keyDownMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var onRequestClear: ((String) -> Void)?

    func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if SidebarDragFailsafePolicy.shouldRequestClearWhenMonitoringStarts(
            isLeftMouseButtonDown: CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
        ) {
            requestClearSoon(reason: "mouse_up_failsafe")
        }
        if appResignObserver == nil {
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "app_resign_active")
                }
            }
        }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == Self.escapeKeyCode {
                    self?.requestClearSoon(reason: "escape_cancel")
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) {
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
            }
        }
    }

    func stop() {
        pendingClearWorkItem?.cancel()
        pendingClearWorkItem = nil
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        onRequestClear = nil
    }

    private func requestClearSoon(reason: String) {
        guard pendingClearWorkItem == nil else { return }
#if DEBUG
        dlog("sidebar.dragFailsafe.schedule reason=\(reason)")
#endif
        let workItem = DispatchWorkItem { [weak self] in
#if DEBUG
            dlog("sidebar.dragFailsafe.fire reason=\(reason)")
#endif
            self?.pendingClearWorkItem = nil
            self?.onRequestClear?(reason)
        }
        pendingClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarDragFailsafePolicy.clearDelay, execute: workItem)
    }
}

private struct SidebarExternalDropOverlay: View {
    let draggedWorkspaceId: UUID?
    let workspaceManager: WorkspaceManager

    var body: some View {
        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
            draggedWorkspaceId: draggedWorkspaceId,
            pasteboardTypes: dragPasteboardTypes
        )
        Group {
            if shouldCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .onDrop(
                        of: SidebarWorkspaceDragPayload.dropContentTypes,
                        delegate: SidebarExternalDropDelegate(
                            draggedWorkspaceId: draggedWorkspaceId,
                            workspaceManager: workspaceManager
                        )
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SidebarExternalDropDelegate: DropDelegate {
    let draggedWorkspaceId: UUID?
    let workspaceManager: WorkspaceManager

    func validateDrop(info: DropInfo) -> Bool {
        let hasSidebarPayload = info.hasItemsConforming(to: [SidebarWorkspaceDragPayload.typeIdentifier])
        let shouldReset = SidebarOutsideDropResetPolicy.shouldResetDrag(
            draggedWorkspaceId: draggedWorkspaceId,
            hasSidebarDragPayload: hasSidebarPayload
        )
#if DEBUG
        dlog(
            "sidebar.dropOutside.validate tab=\(debugShortSidebarWorkspaceId(draggedWorkspaceId)) " +
            "hasType=\(hasSidebarPayload) allowed=\(shouldReset)"
        )
#endif
        return shouldReset
    }

    func dropEntered(info: DropInfo) {
#if DEBUG
        dlog("sidebar.dropOutside.entered tab=\(debugShortSidebarWorkspaceId(draggedWorkspaceId))")
#endif
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        dlog("sidebar.dropOutside.exited tab=\(debugShortSidebarWorkspaceId(draggedWorkspaceId))")
#endif
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
#if DEBUG
        dlog("sidebar.dropOutside.updated tab=\(debugShortSidebarWorkspaceId(draggedWorkspaceId)) op=move")
#endif
        // A card from another window over these panels would join this window.
        if let id = SidebarWorkspaceDragPayload.inFlightWorkspaceId,
           !workspaceManager.workspaces.contains(where: { $0.id == id }),
           let windowId = AppDelegate.shared?.windowId(for: workspaceManager) {
            SidebarForeignHover.note(.init(workspaceId: id, windowId: windowId, groupId: nil, before: nil, after: nil))
        }
        // Explicit move proposal avoids AppKit showing a copy (+) cursor.
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
#if DEBUG
        dlog("sidebar.dropOutside.perform tab=\(debugShortSidebarWorkspaceId(draggedWorkspaceId))")
#endif
        SidebarDragLifecycleNotification.postClearRequest(reason: "outside_sidebar_drop")
        commitCrossWindowDropIfAny()
        return true
    }

    /// C11H-207: a card dropped on this window's panels. From another window,
    /// it moves into this one (at the end of its lane). From this window, it
    /// commits the slot another window's sidebar was showing, when this window
    /// came forward at release over that sidebar (`SidebarForeignHover`).
    private func commitCrossWindowDropIfAny() {
        guard let id = SidebarWorkspaceDragPayload.currentId(),
              let app = AppDelegate.shared,
              let thisWindowId = app.windowId(for: workspaceManager) else { return }
        let pointer = NSEvent.mouseLocation
        let target: (windowId: UUID, groupId: UUID?, before: UUID?, after: UUID?)
        if !workspaceManager.workspaces.contains(where: { $0.id == id }) {
            target = (thisWindowId, nil, nil, nil)
        } else if let hover = SidebarForeignHover.pending(workspaceId: id, pointer: pointer),
                  hover.windowId != thisWindowId {
            target = (hover.windowId, hover.groupId, hover.before, hover.after)
        } else {
            return
        }
        SidebarForeignHover.reset()
#if DEBUG
        dlog(
            "sidebar.crossWindowDrop.viaPanels ws=\(id.uuidString.prefix(5)) " +
            "from=\(thisWindowId.uuidString.prefix(5)) to=\(target.windowId.uuidString.prefix(5))"
        )
#endif
        DispatchQueue.main.async {
            _ = app.moveWorkspaceToWindow(
                workspaceId: id, windowId: target.windowId,
                groupId: target.groupId, before: target.before, after: target.after
            )
        }
    }

    private func debugShortSidebarWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

private struct SidebarFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let onSendFeedback: () -> Void
    /// Sidebar tile columns; the attention buttons take one column each.
    let columns: Int
    /// Compact cards (C11H-221): one column puts Waiting and Flagged side by side.
    var dense: Bool = false

    var body: some View {
#if DEBUG
        SidebarDevFooter(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback, columns: columns, dense: dense)
#else
        SidebarFooterButtons(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback, columns: columns, dense: dense)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
#endif
    }
}

private struct SidebarFooterButtons: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let onSendFeedback: () -> Void
    let columns: Int
    var dense: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarWaitingAgentCluster(columns: columns, dense: dense)
            HStack(spacing: 4) {
                // c11h: the bottom-left corner fills the screen too.
                WindowMaximizeButton(
                    foregroundColor: Color(nsColor: .secondaryLabelColor),
                    iconSize: 11,
                    buttonSize: 22,
                    accessibilityIdentifier: "WindowMaximizeButton.sidebar"
                )
                .buttonStyle(SidebarFooterIconButtonStyle())
                SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
                UpdatePill(model: updateViewModel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FeedbackComposerMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedbackComposerMessageEditorView {
        let view = FeedbackComposerMessageEditorView()
        view.placeholder = placeholder
        view.textView.string = text
        view.textView.delegate = context.coordinator
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        return view
    }

    func updateNSView(_ nsView: FeedbackComposerMessageEditorView, context: Context) {
        if nsView.textView.string != text {
            nsView.textView.string = text
        }
        nsView.placeholder = placeholder
        nsView.textView.setAccessibilityLabel(accessibilityLabel)
        nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackComposerMessageEditor

        init(parent: FeedbackComposerMessageEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class FeedbackComposerPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FeedbackComposerMessageScrollView: NSScrollView {
    weak var focusTextView: NSTextView?

    override func mouseDown(with event: NSEvent) {
        if let focusTextView {
            _ = window?.makeFirstResponder(focusTextView)
        }
        super.mouseDown(with: event)
    }
}

private final class FeedbackComposerMessageEditorView: NSView {
    private static let textInset = NSSize(width: 10, height: 10)

    let scrollView = FeedbackComposerMessageScrollView()
    let textView = NSTextView()
    private let placeholderField = FeedbackComposerPassthroughLabel(labelWithString: "")

    var placeholder: String = "" {
        didSet {
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.focusTextView = textView

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        addSubview(scrollView)

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = .systemFont(ofSize: 12)
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        scrollView.contentView.addSubview(placeholderField)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            placeholderField.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor,
                constant: Self.textInset.height
            ),
            placeholderField.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor,
                constant: Self.textInset.width
            ),
            placeholderField.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentView.trailingAnchor,
                constant: -Self.textInset.width
            ),
        ])

        updatePlaceholderVisibility()
    }

    override func layout() {
        super.layout()
        syncTextViewFrameToContentSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }

    private func syncTextViewFrameToContentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        let targetSize = NSSize(
            width: contentSize.width,
            height: max(textView.frame.height, contentSize.height)
        )
        if textView.frame.size != targetSize {
            textView.frame = NSRect(origin: .zero, size: targetSize)
        }
    }
}

private enum SidebarHelpMenuAction {
    case importBrowserData
    case keyboardShortcuts
    case docs
    case changelog
    case github
    case checkForUpdates
    case sendFeedback
    case welcome
    case reEnableSkillPrompts
}

private struct SidebarFeedbackComposerSheet: View {
    @AppStorage(FeedbackComposerSettings.storedEmailKey) private var email = ""
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var attachments: [FeedbackComposerAttachment] = []
    @State private var isSubmitting = false
    @State private var submissionErrorMessage: String?
    @State private var didSend = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isValidEmail(email) &&
            !trimmedMessage.isEmpty &&
            message.count <= FeedbackComposerSettings.maxMessageLength &&
            !isSubmitting &&
            !didSend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "sidebar.help.feedback.title", defaultValue: "Send Feedback"))
                .font(.title3.weight(.semibold))

            if didSend {
                successView
            } else {
                formView
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier("SidebarFeedbackDialog")
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "sidebar.help.feedback.successTitle", defaultValue: "Thanks for the feedback."))
                .font(.headline)
            Text(
                String(
                    localized: "sidebar.help.feedback.successBody",
                    defaultValue: "You can also reach us at hello@stage11.ai."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.done", defaultValue: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                String(
                    localized: "sidebar.help.feedback.note",
                    defaultValue: "A human will read this! You can also reach us at hello@stage11.ai."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email"))
                    .font(.system(size: 12, weight: .medium))
                TextField(
                    String(localized: "sidebar.help.feedback.emailPlaceholder", defaultValue: "you@example.com"),
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email"))
                .accessibilityIdentifier("SidebarFeedbackEmailField")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "sidebar.help.feedback.message", defaultValue: "Message"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(message.count)/\(FeedbackComposerSettings.maxMessageLength)")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            message.count > FeedbackComposerSettings.maxMessageLength
                                ? Color.red
                                : Color.secondary
                        )
                }

                FeedbackComposerMessageEditor(
                    text: $message,
                    placeholder: String(
                        localized: "sidebar.help.feedback.messagePlaceholder",
                        defaultValue: "Share feedback, feature requests, or issues."
                    ),
                    accessibilityLabel: String(localized: "sidebar.help.feedback.message", defaultValue: "Message"),
                    accessibilityIdentifier: "SidebarFeedbackMessageEditor"
                )
                .frame(minHeight: 180)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        chooseAttachments()
                    } label: {
                        Label(
                            String(localized: "sidebar.help.feedback.attachImages", defaultValue: "Attach Images"),
                            systemImage: "paperclip"
                        )
                    }
                    .accessibilityIdentifier("SidebarFeedbackAttachButton")

                    Text(
                        String(
                            localized: "sidebar.help.feedback.attachmentsHint",
                            defaultValue: "Up to 10 images."
                        )
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                if attachments.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                Text(attachment.fileName)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(attachment.displaySize)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Button(
                                    String(localized: "sidebar.help.feedback.removeAttachment", defaultValue: "Remove")
                                ) {
                                    removeAttachment(attachment)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            if let submissionErrorMessage, submissionErrorMessage.isEmpty == false {
                Text(submissionErrorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await submitFeedback() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "sidebar.help.feedback.send", defaultValue: "Send"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("SidebarFeedbackSendButton")
            }
        }
    }

    private func chooseAttachments() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.image]
        openPanel.title = String(
            localized: "sidebar.help.feedback.attachImages.title",
            defaultValue: "Attach Images"
        )
        openPanel.prompt = String(
            localized: "sidebar.help.feedback.attachImages.prompt",
            defaultValue: "Attach"
        )

        guard openPanel.runModal() == .OK else { return }

        var updatedAttachments = attachments
        var knownPaths = Set(updatedAttachments.map(\.standardizedPath))
        var firstIssue: String?

        for url in openPanel.urls {
            let normalizedPath = url.standardizedFileURL.path
            if knownPaths.contains(normalizedPath) {
                continue
            }
            if updatedAttachments.count >= FeedbackComposerSettings.maxAttachmentCount {
                firstIssue = String(
                    localized: "sidebar.help.feedback.tooManyImages",
                    defaultValue: "You can attach up to 10 images."
                )
                break
            }

            guard let attachment = try? FeedbackComposerAttachment(url: url) else {
                firstIssue = String(
                    localized: "sidebar.help.feedback.invalidImageSelection",
                    defaultValue: "Couldn't attach one of the selected files."
                )
                continue
            }
            updatedAttachments.append(attachment)
            knownPaths.insert(normalizedPath)
        }

        attachments = updatedAttachments
        submissionErrorMessage = firstIssue
    }

    private func removeAttachment(_ attachment: FeedbackComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        submissionErrorMessage = nil
    }

    private func submitFeedback() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = trimmedMessage

        guard isValidEmail(trimmedEmail) else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.invalidEmail",
                defaultValue: "Enter a valid email address."
            )
            return
        }

        guard normalizedMessage.isEmpty == false else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.emptyMessage",
                defaultValue: "Enter a message before sending."
            )
            return
        }

        guard message.count <= FeedbackComposerSettings.maxMessageLength else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.messageTooLong",
                defaultValue: "Your message is too long."
            )
            return
        }

        await MainActor.run {
            email = trimmedEmail
            submissionErrorMessage = nil
            isSubmitting = true
        }

        do {
            try await FeedbackComposerClient.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
            await MainActor.run {
                isSubmitting = false
                didSend = true
                attachments = []
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                submissionErrorMessage = userFacingErrorMessage(for: error)
            }
        }
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Try again."
            )
        }

        switch submissionError {
        case .invalidEndpoint:
            return String(
                localized: "sidebar.help.feedback.endpointError",
                defaultValue: "Feedback is unavailable right now. Email hello@stage11.ai instead."
            )
        case .invalidResponse:
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Try again."
            )
        case .attachmentReadFailed:
            return String(
                localized: "sidebar.help.feedback.invalidImageSelection",
                defaultValue: "Couldn't attach one of the selected files."
            )
        case .attachmentPreparationFailed:
            return String(
                localized: "sidebar.help.feedback.totalImagesTooLarge",
                defaultValue: "These images are too large to send together. Remove a few and try again."
            )
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return String(
                    localized: "sidebar.help.feedback.connectionError",
                    defaultValue: "Couldn't send feedback. Check your connection and try again."
                )
            }
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Try again."
            )
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return String(
                    localized: "sidebar.help.feedback.validationError",
                    defaultValue: "Check your message and attachments, then try again."
                )
            case 429:
                return String(
                    localized: "sidebar.help.feedback.rateLimited",
                    defaultValue: "Too many feedback attempts. Try again later."
                )
            case 500...599:
                return String(
                    localized: "sidebar.help.feedback.endpointError",
                    defaultValue: "Feedback is unavailable right now. Email hello@stage11.ai instead."
                )
            default:
                return String(
                    localized: "sidebar.help.feedback.genericError",
                    defaultValue: "Couldn't send feedback. Please try again."
                )
            }
        }
    }
}

enum FeedbackComposerBridgeError: LocalizedError {
    case invalidEmail
    case emptyMessage
    case messageTooLong
    case tooManyImages
    case invalidImagePath(String)
    case submissionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Enter a valid email address."
        case .emptyMessage:
            return "Enter a message before sending."
        case .messageTooLong:
            return "Your message is too long."
        case .tooManyImages:
            return "You can attach up to 10 images."
        case .invalidImagePath(let path):
            return "Could not attach image: \(path)"
        case .submissionFailed(let message):
            return message
        }
    }
}

enum FeedbackComposerBridge {
    static func openComposer(in window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        NotificationCenter.default.post(name: .feedbackComposerRequested, object: window)
    }

    static func submit(
        email: String,
        message: String,
        imagePaths: [String]
    ) async throws -> Int {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidEmail(trimmedEmail) else {
            throw FeedbackComposerBridgeError.invalidEmail
        }
        guard normalizedMessage.isEmpty == false else {
            throw FeedbackComposerBridgeError.emptyMessage
        }
        guard message.count <= FeedbackComposerSettings.maxMessageLength else {
            throw FeedbackComposerBridgeError.messageTooLong
        }
        guard imagePaths.count <= FeedbackComposerSettings.maxAttachmentCount else {
            throw FeedbackComposerBridgeError.tooManyImages
        }

        let attachments = try imagePaths.map { rawPath in
            let resolvedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            do {
                return try FeedbackComposerAttachment(url: resolvedURL)
            } catch {
                throw FeedbackComposerBridgeError.invalidImagePath(resolvedURL.path)
            }
        }

        do {
            try await FeedbackComposerClient.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
        } catch {
            throw FeedbackComposerBridgeError.submissionFailed(userFacingMessage(for: error))
        }

        UserDefaults.standard.set(trimmedEmail, forKey: FeedbackComposerSettings.storedEmailKey)
        return attachments.count
    }

    private static func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private static func userFacingMessage(for error: Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return "Couldn't send feedback. Please try again."
        }

        switch submissionError {
        case .invalidEndpoint:
            return "Feedback is unavailable right now. Email hello@stage11.ai instead."
        case .invalidResponse:
            return "Couldn't send feedback. Please try again."
        case .attachmentReadFailed:
            return "One of the selected files could not be attached."
        case .attachmentPreparationFailed:
            return "These images are too large to send together. Remove a few and try again."
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return "Couldn't send feedback. Check your connection and try again."
            }
            return "Couldn't send feedback. Please try again."
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return "Check your message and attachments, then try again."
            case 429:
                return "Too many feedback attempts. Please try again later."
            case 500...599:
                return "Feedback is unavailable right now. Email hello@stage11.ai instead."
            default:
                return "Couldn't send feedback. Please try again."
            }
        }
    }
}

private struct SidebarHelpMenuButton: View {
    private let docsURL = URL(string: "https://github.com/Stage-11-Agentics/c11/tree/main/docs")
    private let changelogURL = URL(string: "https://github.com/Stage-11-Agentics/c11/blob/main/CHANGELOG.md")
    private let githubURL = URL(string: "https://github.com/Stage-11-Agentics/c11")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11
    @AppStorage(KeyboardShortcutSettings.Action.sendFeedback.defaultsKey) private var sendFeedbackShortcutData = Data()

    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private var sendFeedbackShortcutHint: String {
        decodeShortcut(
            from: sendFeedbackShortcutData,
            fallback: KeyboardShortcutSettings.Action.sendFeedback.defaultShortcut
        ).displayString
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            helpOptionButton(
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to c11."),
                action: .welcome,
                accessibilityIdentifier: "SidebarHelpMenuOptionWelcome",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                action: .sendFeedback,
                accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right"
            )
            helpOptionButton(
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                action: .keyboardShortcuts,
                accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
                action: .importBrowserData,
                accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData",
                isExternalLink: false
            )
            if docsURL != nil {
                helpOptionButton(
                    title: String(localized: "about.docs", defaultValue: "Docs"),
                    action: .docs,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDocs",
                    isExternalLink: true
                )
            }
            if changelogURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                    action: .changelog,
                    accessibilityIdentifier: "SidebarHelpMenuOptionChangelog",
                    isExternalLink: true
                )
            }
            if githubURL != nil {
                helpOptionButton(
                    title: String(localized: "about.github", defaultValue: "GitHub"),
                    action: .github,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHub",
                    isExternalLink: true
                )
            }
            helpOptionButton(
                title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                action: .checkForUpdates,
                accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                isExternalLink: false
            )
            // Visible only when the operator has either explicitly opted
            // out of the agent-skills sheet ("Don't ask again") or has
            // dismissed individual (target, skill) rows. No clutter for
            // operators who have never silenced anything.
            if AgentSkillsOnboarding.hasSilencedState() {
                helpOptionButton(
                    title: String(localized: "sidebar.help.reEnableSkillPrompts", defaultValue: "Re-enable agent skills install prompts"),
                    action: .reEnableSkillPrompts,
                    accessibilityIdentifier: "SidebarHelpMenuOptionReEnableSkillPrompts",
                    isExternalLink: false
                )
            }
        }
        .padding(8)
        .frame(minWidth: 200)
    }

    private func helpOptionButton(
        title: String,
        action: SidebarHelpMenuAction,
        accessibilityIdentifier: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        Button {
            isPopoverPresented = false
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                if let shortcutHint {
                    helpOptionShortcutHint(text: shortcutHint)
                }
                if let trailingSystemImage {
                    helpOptionTrailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    helpOptionTrailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func helpOptionShortcutHint(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func helpOptionTrailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func perform(_ action: SidebarHelpMenuAction) {
        switch action {
        case .importBrowserData:
            isPopoverPresented = false
            DispatchQueue.main.async {
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        case .keyboardShortcuts:
            isPopoverPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openPreferencesWindow(
                            debugSource: "sidebarHelpMenu.keyboardShortcuts",
                            navigationTarget: .keyboardShortcuts
                        )
                    } else {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                    }
                }
            }
        case .docs:
            guard let docsURL else { return }
            NSWorkspace.shared.open(docsURL)
        case .changelog:
            guard let changelogURL else { return }
            NSWorkspace.shared.open(changelogURL)
        case .github:
            guard let githubURL else { return }
            NSWorkspace.shared.open(githubURL)
        case .checkForUpdates:
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        case .sendFeedback:
            isPopoverPresented = false
            onSendFeedback()
        case .welcome:
            isPopoverPresented = false
            Task { @MainActor in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openWelcomeWorkspace()
                }
            }
        case .reEnableSkillPrompts:
            isPopoverPresented = false
            AgentSkillsOnboarding.clearAllSilencing()
            Task { @MainActor in
                // Unconditional present (not the IfNeeded variant): when
                // everything is current, the celebratory branch renders
                // confirmation instead of leaving the operator with a
                // silent no-op.
                AppDelegate.shared?.presentAgentSkillsOnboarding(onCompletion: nil)
            }
        }
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
    }
}

// MARK: - Waiting Agent Cluster

/// One column of cards stacks Flagged over Waiting at full width. In Tiles
/// each button is one tile column wide, on the tiles' grid (6 pt edge, 12 pt
/// gutter): Waiting first, then Flagged, then Chaos (C11H-199). With two
/// columns, Flagged and Chaos share the second slot: Flagged while any flag is
/// up (attention outranks play), Chaos otherwise. Later columns stay empty.
/// Done (C11H-261) sits directly under Waiting in every layout while its
/// setting is on, lit or not, so turning a count on or off never moves a row.
private struct SidebarWaitingAgentCluster: View {
    @EnvironmentObject private var notificationStore: TerminalNotificationStore
    @ObservedObject private var attentionIndex = PanelAttentionIndex.shared
    /// C11H-261: both keys default on, matching `WaitingCheckSettings`.
    @AppStorage(WaitingCheckSettings.enabledKey) private var waitingCheckEnabled = true
    @AppStorage(WaitingCheckSettings.showDoneButtonKey) private var showDoneButtonSetting = true
    @Environment(\.colorScheme) private var colorScheme
    /// c11 (C11H-197): the hosting window's theme override.
    @Environment(\.c11WindowThemeName) private var windowThemeName
    /// The sidebar style's content stamp. Theme versions churn (a Ghostty
    /// background change bumps one at up to 30 Hz), so the pills follow this
    /// instead of observing the theme manager, and redraw only when their
    /// style's content changes.
    @State private var styleStamp: UInt64 = 0
    let columns: Int
    var dense: Bool = false

    private var display: StatusBarButtonDisplay {
        StatusBarButtonDisplay(unreadCount: notificationStore.unreadCount)
    }

    private var showsDone: Bool { waitingCheckEnabled && showDoneButtonSetting }

    private var doneDisplay: StatusBarButtonDisplay {
        StatusBarButtonDisplay(unreadCount: notificationStore.doneCount)
    }

    /// The oldest finished agent's deciding line, read only while Done is lit.
    private func doneQuote(_ display: StatusBarButtonDisplay) -> String? {
        guard display.isEnabled,
              let oldest = notificationStore.oldestDoneNotification() else { return nil }
        return WaitingCheckJudge.verdict(forNotificationID: oldest.id)?.quote
    }

    private func doneRow(style: SidebarThemeStyle, dense: Bool = false) -> some View {
        let done = doneDisplay
        return DoneAgentRow(display: done, quote: doneQuote(done), style: style, onJump: jumpToDone, dense: dense)
    }

    var body: some View {
        let _ = styleStamp
        cluster(style: SidebarThemeStyleCache.current(ThemeManager.shared, colorScheme: colorScheme, windowThemeName: windowThemeName))
            .onReceive(ThemeManager.shared.$version.receive(on: DispatchQueue.main)) { _ in
                let stamp = SidebarThemeStyleCache.current(
                    ThemeManager.shared,
                    colorScheme: colorScheme,
                    windowThemeName: windowThemeName
                ).stamp
                if stamp != styleStamp { styleStamp = stamp }
            }
    }

    /// Named kinds by id, then the generic (purple) button: one button per
    /// kind with flags up, stacked above the generic one (C11H-224).
    @ViewBuilder
    private func flagButtons(style: SidebarThemeStyle, dense: Bool = false) -> some View {
        VStack(spacing: dense ? 4 : 6) {
            ForEach(attentionIndex.flagKindSummary.stackOrder) { group in
                FlaggedAgentsRow(group: group, style: style, onJump: { jumpToNext(of: group) }, dense: dense)
            }
        }
    }

    @ViewBuilder
    private func cluster(style: SidebarThemeStyle) -> some View {
        if columns >= 2 {
            // Several kind buttons stack in the Flagged tile; the other tiles
            // keep their own height rather than stretching to the stack.
            // Done stacks under Waiting in Waiting's tile, so the other tiles
            // keep their own height then too.
            let stretch: CGFloat? = (attentionIndex.flagKindSummary.groups.count > 1 || showsDone) ? nil : .infinity
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if showsDone {
                        VStack(spacing: 6) {
                            WaitingAgentRow(display: display, style: style, onJump: jump)
                            doneRow(style: style)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        WaitingAgentRow(display: display, style: style, onJump: jump)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: stretch)
                Group {
                    if attentionIndex.flaggedCount > 0 {
                        flagButtons(style: style)
                    } else if columns == 2 {
                        ChaosWizardButton(style: style)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: stretch)
                if columns >= 3 {
                    ChaosWizardButton(style: style)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: stretch)
                }
                ForEach(min(columns, 3)..<columns, id: \.self) { _ in
                    Color.clear.frame(minWidth: 0, maxWidth: .infinity, maxHeight: 0)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // The footer insets 10 pt; tile cards sit 6 pt from the edge.
            .padding(.horizontal, -4)
        } else if dense {
            // Compact cards (C11H-221): Waiting and Flagged share one line
            // when both labels fit, else they stack as thin rows. Done takes
            // its own thin row under that line (C11H-261).
            VStack(spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        WaitingAgentRow(display: display, style: style, onJump: jump, dense: true)
                            .frame(maxWidth: .infinity)
                        if attentionIndex.flaggedCount > 0 {
                            flagButtons(style: style, dense: true)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    VStack(spacing: 4) {
                        if attentionIndex.flaggedCount > 0 {
                            flagButtons(style: style, dense: true)
                        }
                        WaitingAgentRow(display: display, style: style, onJump: jump, dense: true)
                    }
                }
                if showsDone {
                    doneRow(style: style, dense: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                if attentionIndex.flaggedCount > 0 {
                    flagButtons(style: style)
                }
                WaitingAgentRow(display: display, style: style, onJump: jump)
                if showsDone {
                    doneRow(style: style)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func jump() {
        DispatchQueue.main.async {
            AppDelegate.shared?.operatorJumpToLatestUnread()
        }
    }

    /// C11H-261: Done opens the oldest finished agent.
    private func jumpToDone() {
        DispatchQueue.main.async {
            AppDelegate.shared?.operatorJumpToOldestDone()
        }
    }

    /// A flag button opens its own kind's next flag, chosen at click time in
    /// the operator's jump order (C11H-262).
    private func jumpToNext(of group: FlagKindGroup) {
        let kindID = group.id
        DispatchQueue.main.async {
            AppDelegate.shared?.operatorJumpToFlag(kindID: kindID)
        }
    }
}

/// One flag kind's button (C11H-224). The generic flag keeps the "Flagged
/// Agents" title and the theme's flag colour; a named kind shows its name in
/// its registry colour, with black or white ink by contrast. Kinds are flat:
/// the stack is ordered by kind id, never by priority.
private struct FlaggedAgentsRow: View {
    let group: FlagKindGroup
    let style: SidebarThemeStyle
    let onJump: () -> Void
    /// Half a line beside Waiting in compact mode (C11H-221).
    var dense: Bool = false

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private let violet = Color(
        red: 157.0 / 255.0,
        green: 138.0 / 255.0,
        blue: 217.0 / 255.0
    )

    private var kindHex: String? {
        group.kind?.colorHex(lightBackground: colorScheme == .light)
    }

    /// Flag colour: a named kind's token, else the theme's `states.flag`, else violet.
    private var flagColor: Color {
        if let kindHex, let color = NSColor(hex: kindHex) { return Color(nsColor: color) }
        return style.stateFlag ?? violet
    }

    /// An outline pill theme draws the flag as an outline too (C11H-145).
    private var outlined: Bool { style.effectivePillStyle == .outline }

    /// Ink on the filled colour: a named kind picks black or white by contrast.
    private var fillInk: Color {
        if let kindHex { return FlagKindInk.prefersDarkInk(hex: kindHex) ? BrandColors.blackSwiftUI : .white }
        return style.effectivePillStyle == nil ? BrandColors.blackSwiftUI : (style.pillInk ?? BrandColors.blackSwiftUI)
    }

    private var ink: Color { outlined ? flagColor : fillInk }

    /// An outline theme fills the badge with the flag colour.
    private var badgeOutlineInk: Color {
        kindHex == nil ? (style.stateWaitingInk ?? BrandColors.blackSwiftUI) : fillInk
    }

    private var title: String {
        if let label = group.kind?.displayLabel { return label }
        return dense
            ? String(localized: "statusBar.flaggedAgents.short", defaultValue: "Flagged")
            : String(localized: "statusBar.flaggedAgents.title", defaultValue: "Flagged Agents")
    }

    private var jumpText: String {
        guard let name = group.kind?.name else {
            return String(localized: "statusBar.flaggedAgents.next", defaultValue: "Jump to next flagged agent")
        }
        return String(localized: "statusBar.flaggedAgents.kindNext", defaultValue: "Jump to next \(name) flag")
    }

    var body: some View {
        let radius = style.pillRadius ?? 6
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: onJump) {
            HStack(spacing: 6) {
                Text(verbatim: style.pill.apply(title))
                    .chromeStyle(style.pill, size: 11, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(verbatim: String(group.count))
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        SidebarPillBadgeShape(radius: style.pillRadius)
                            .fill(outlined ? flagColor : ink.opacity(0.18))
                    )
                    .foregroundColor(outlined ? badgeOutlineInk : ink)
                    .accessibilityHidden(true)

                Spacer(minLength: 4)
                if !dense {
                    Text(verbatim: "\u{2192}")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, dense ? 6 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                shape
                    .fill(outlined ? (style.pillFillFirst ?? Color.clear) : flagColor)
            )
            .overlay(
                shape
                    .stroke(flagColor, lineWidth: outlined ? (style.cardBorderPt ?? 1) : 0.75)
            )
            .foregroundColor(ink)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay {
            if style.hoverBrackets, isHovering {
                SidebarHoverBrackets(color: (style.cardBorderActive ?? style.cardText ?? .primary).opacity(0.78))
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(group.kind.map { "SidebarFlaggedAgentsButton.\($0.id)" } ?? "SidebarFlaggedAgentsButton")
        .accessibilityLabel(Text(verbatim: jumpText))
        .accessibilityValue(Text(verbatim: String(group.count)))
        .safeHelp(jumpText)
    }
}

private struct WaitingAgentRow: View {
    let display: StatusBarButtonDisplay
    let style: SidebarThemeStyle
    let onJump: () -> Void
    /// Half a line beside Flagged in compact mode (C11H-221).
    var dense: Bool = false

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var isLit: Bool { display.isEnabled }

    /// The theme's pill (C11H-145): filled (a colour or gradient behind dark
    /// ink) or outline (ink-coloured edge and text). nil draws c11's own pill,
    /// lit in the waiting colour (C11H-344: waiting is white).
    private var pillStyle: SidebarThemeStyle.PillStyle? { style.effectivePillStyle }

    /// The lit fill, ink and edge, resolved once per body.
    private struct LitColors {
        let fill: Color
        let ink: Color
        let edge: Color
        /// Ink on the outline pill's filled count badge.
        let badgeInk: Color
    }

    private func litColors() -> LitColors {
        let waiting = SidebarWaitingPillColors.resolve(
            states: style.statePalette,
            lightSlot: colorScheme == .light,
            themedPill: pillStyle != nil
        )
        let ink: Color
        switch pillStyle {
        case nil: ink = waiting.ink
        case .filled?: ink = style.pillInk ?? waiting.ink
        case .outline?: ink = style.pillInk ?? waiting.fill
        }
        let edge: Color
        switch pillStyle {
        case nil: edge = waiting.edge
        case .filled?: edge = style.pillBorder ?? style.pillFillFirst ?? waiting.fill
        case .outline?: edge = style.pillBorder ?? ink
        }
        return LitColors(fill: waiting.fill, ink: ink, edge: edge, badgeInk: waiting.ink)
    }

    @ViewBuilder
    private func pillFill(_ shape: RoundedRectangle, litFill: Color) -> some View {
        if !isLit {
            shape.fill(pillStyle == nil ? BrandColors.surfaceSwiftUI : (style.cardFill ?? BrandColors.surfaceSwiftUI))
        } else if let gradient = style.pillFill, pillStyle != nil {
            shape.fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
        } else if pillStyle == .outline {
            shape.fill(Color.clear)
        } else {
            shape.fill(litFill)
        }
    }

    private var label: String {
        dense
            ? String(localized: "statusBar.waitingAgent.short", defaultValue: "Waiting")
            : String(localized: "statusBar.waitingAgent.title", defaultValue: "Waiting Agent")
    }

    private var shortcutText: String {
        KeyboardShortcutSettings.shortcut(for: .jumpToUnread).displayString
    }

    private var accessibilityLabel: String {
        String(localized: "statusBar.jumpToUnread.accessibility", defaultValue: "Jump to next unread notification")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.pillRadius ?? 6, style: .continuous)
        let outlined = pillStyle == .outline
        let lit = litColors()
        Button(action: onJump) {
            HStack(spacing: 6) {
                Text(verbatim: style.pill.apply(label))
                    .chromeStyle(style.pill, size: 11, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let badge = display.badgeText {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            SidebarPillBadgeShape(radius: style.pillRadius)
                                .fill(outlined ? lit.ink : lit.ink.opacity(0.18))
                        )
                        .foregroundColor(outlined ? lit.badgeInk : lit.ink)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 4)

                if !dense {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\u{2192}")
                            .font(.system(size: 13, weight: .medium))
                        Text(shortcutText)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .opacity(isLit ? 0.6 : 0.5)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, dense ? 6 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Sustained "agent is waiting" lit state is a solid fill in the
            // waiting colour (white, C11H-344) with its ink. Deliberately no
            // motion; the inversion from the void rest does the attention
            // work. Rest state stays paper-white-on-void with a rule outline.
            // A theme's pill replaces the fill (C11H-145); Outrun's bust rises
            // behind the text (C11H-148).
            .background {
                pillFill(shape, litFill: lit.fill)
                    .overlay {
                        if style.bust, isLit {
                            SidebarWaitingPillBust()
                                .clipShape(shape)
                        }
                    }
            }
            .overlay(
                shape
                    .stroke(
                        isLit ? lit.edge : (pillStyle == nil ? BrandColors.ruleSwiftUI : (style.cardBorder ?? BrandColors.ruleSwiftUI)),
                        lineWidth: isLit ? (outlined ? (style.cardBorderPt ?? 1) : 0.75) : 1
                    )
            )
            .foregroundColor(isLit
                ? lit.ink
                : (pillStyle == nil ? BrandColors.whiteSwiftUI.opacity(0.4) : (style.cardTextDim ?? BrandColors.whiteSwiftUI.opacity(0.4))))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isLit)
        .overlay {
            if style.hoverBrackets, isHovering {
                SidebarHoverBrackets(color: (style.cardBorderActive ?? style.cardText ?? .primary).opacity(0.78))
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("SidebarWaitingAgentButton")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(display.badgeText ?? "")
        .safeHelp(
            KeyboardShortcutSettings.Action.jumpToUnread.tooltip(label)
        )
    }
}

/// C11H-261: agents whose latest turn needs nothing from the operator. Low
/// priority by design: lit is a grey wash and edge in the theme's card
/// colours, never gold or the waiting colour; unlit matches Waiting's rest.
private struct DoneAgentRow: View {
    let display: StatusBarButtonDisplay
    /// The oldest done notification's deciding line, when lit.
    let quote: String?
    let style: SidebarThemeStyle
    let onJump: () -> Void
    /// A thin row under the Waiting line in compact mode (C11H-221).
    var dense: Bool = false

    @State private var isHovering = false

    private var isLit: Bool { display.isEnabled }

    private var themed: Bool { style.effectivePillStyle != nil }
    private var outlined: Bool { style.effectivePillStyle == .outline }

    private static let neutralGrey = Color(white: 0.55)

    private var restFill: Color {
        themed ? (style.cardFill ?? BrandColors.surfaceSwiftUI) : BrandColors.surfaceSwiftUI
    }

    private var restEdge: Color {
        themed ? (style.cardBorder ?? BrandColors.ruleSwiftUI) : BrandColors.ruleSwiftUI
    }

    private var restInk: Color {
        themed ? (style.cardTextDim ?? BrandColors.whiteSwiftUI.opacity(0.4)) : BrandColors.whiteSwiftUI.opacity(0.4)
    }

    /// Lit ink: the theme's secondary card text, else a soft grey.
    private var litInk: Color {
        themed
            ? (style.cardTextSecondary ?? style.cardTextDim ?? Self.neutralGrey)
            : BrandColors.whiteSwiftUI.opacity(0.72)
    }

    /// Lit edge: the dim text colour reads as grey in every theme.
    private var litEdge: Color {
        themed ? (style.cardTextDim ?? style.cardBorder ?? Self.neutralGrey) : BrandColors.dimSwiftUI
    }

    private var label: String {
        dense
            ? String(localized: "statusBar.doneAgent.short", defaultValue: "Done")
            : String(localized: "statusBar.doneAgent.title", defaultValue: "Done Agent")
    }

    private var accessibilityLabel: String {
        String(localized: "statusBar.doneAgent.accessibility", defaultValue: "Jump to oldest finished agent")
    }

    private var helpText: String {
        guard isLit else { return label }
        guard let quote, !quote.isEmpty else { return accessibilityLabel }
        return String(localized: "statusBar.doneAgent.quoteHelp", defaultValue: "Done: \(quote)")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.pillRadius ?? 6, style: .continuous)
        let ink = isLit ? litInk : restInk
        Button(action: onJump) {
            HStack(spacing: 6) {
                Text(verbatim: style.pill.apply(label))
                    .chromeStyle(style.pill, size: 11, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let badge = display.badgeText {
                    Text(verbatim: badge)
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            SidebarPillBadgeShape(radius: style.pillRadius)
                                .fill(litInk.opacity(0.18))
                        )
                        .foregroundColor(litInk)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 4)

                if !dense {
                    Text(verbatim: "\u{2192}")
                        .font(.system(size: 13, weight: .medium))
                        .opacity(isLit ? 0.8 : 1)
                }
            }
            .padding(.horizontal, 10)
            // Low priority: a slim row in every layout, under Waiting's full height.
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(restFill)
                    .overlay {
                        if isLit, !outlined {
                            shape.fill(litInk.opacity(0.12))
                        }
                    }
            }
            .overlay(
                shape.stroke(
                    isLit ? litEdge : restEdge,
                    lineWidth: isLit && outlined ? (style.cardBorderPt ?? 1) : 1
                )
            )
            .foregroundColor(ink)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isLit)
        .overlay {
            if style.hoverBrackets, isHovering {
                SidebarHoverBrackets(color: (style.cardBorderActive ?? style.cardText ?? .primary).opacity(0.78))
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("SidebarDoneAgentButton")
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(Text(verbatim: display.badgeText ?? ""))
        .safeHelp(helpText)
    }
}

private struct ArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let detachedGap: CGFloat
    @ViewBuilder let content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.updateRootView(AnyView(content()))

        if isPresented {
            context.coordinator.present(
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        } else {
            context.coordinator.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            hostingController.rootView = AnyView(rootView.fixedSize())
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
        }

        func present(preferredEdge: NSRectEdge, detachedGap: CGFloat) {
            guard let anchorView else {
                isPresented = false
                dismiss()
                return
            }

            let popover = popover ?? makePopover()
            if popover.isShown {
                return
            }

            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                popover.contentSize = NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                )
            }

            popover.show(
                relativeTo: positioningRect(
                    for: anchorView.bounds,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap
                ),
                of: anchorView,
                preferredEdge: preferredEdge
            )
        }

        func dismiss() {
            popover?.performClose(nil)
            popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.setValue(true, forKeyPath: "shouldHideAnchor")
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func positioningRect(
            for bounds: CGRect,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) -> CGRect {
            let hiddenArrowInset: CGFloat = 13
            let compensation = max(hiddenArrowInset - detachedGap, 0)

            switch preferredEdge {
            case .maxY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.maxY - compensation,
                    width: bounds.width,
                    height: compensation
                )
            case .minY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: compensation
                )
            case .maxX:
                return NSRect(
                    x: bounds.maxX - compensation,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            case .minX:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            @unknown default:
                return bounds
            }
        }
    }
}

private struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
private struct SidebarDevFooter: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let onSendFeedback: () -> Void
    let columns: Int
    var dense: Bool = false
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback, columns: columns, dense: dense)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}
#endif

private struct SidebarTopScrim: View {
    let height: CGFloat

    var body: some View {
        SidebarTopBlurEffect()
            .frame(height: height)
            .mask(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.95),
                        Color.black.opacity(0.75),
                        Color.black.opacity(0.35),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private struct SidebarBottomScrim: View {
    let height: CGFloat

    var body: some View {
        SidebarTopBlurEffect()
            .frame(height: height)
            .mask(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.35),
                        Color.black.opacity(0.75),
                        Color.black.opacity(0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private struct SidebarTopBlurEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> SidebarScrollViewResolverView {
        let view = SidebarScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SidebarScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }
}

private final class SidebarScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    func resolveScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onResolve?(self.enclosingScrollView)
        }
    }
}

private struct SidebarEmptyArea: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedWorkspaceIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedWorkspaceId: UUID?
    @Binding var draggedGroupId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                PanelLineage.shared.withOrigin(.operator) {
                    _ = workspaceManager.addWorkspace(placementOverride: .end)
                }
                if let selectedId = workspaceManager.selectedWorkspaceId {
                    selectedWorkspaceIds = [selectedId]
                    lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
            .onDrop(of: SidebarWorkspaceDragPayload.dropContentTypes + SidebarGroupDragPayload.dropContentTypes,
                    delegate: SidebarWorkspaceDropDelegate(
                targetWorkspaceId: nil,
                workspaceManager: workspaceManager,
                draggedWorkspaceId: $draggedWorkspaceId,
                draggedGroupId: $draggedGroupId,
                selectedWorkspaceIds: $selectedWorkspaceIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                targetRowHeight: nil,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        // Set only by a workspace drag, from this window or another (C11H-207).
        guard let indicator = dropIndicator else { return false }
        return indicator.workspaceId == nil && indicator.groupId == nil
    }
}

enum SidebarPathFormatter {
    static let homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path

    static func shortenedPath(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == homeDirectoryPath {
            return "~"
        }
        if trimmed.hasPrefix(homeDirectoryPath + "/") {
            return "~" + trimmed.dropFirst(homeDirectoryPath.count)
        }
        return trimmed
    }
}

/// Sizing for the workspace-pulse per-agent mark row.
///
/// The row is trailing-aligned inside the card and every mark is a
/// fixed-width slot, so its minimum width grows linearly with the agent
/// count. Past roughly nine agents that minimum exceeds the sidebar, and
/// SwiftUI answers an oversized child by growing the whole row and
/// centre-clipping it: the card loses its rounded edges and every line of
/// text in it shifts off the left edge of the window. Measuring the real
/// width and compressing here is what keeps the card inside the sidebar.
///
/// Compression order: gaps first (they carry no information), then the row
/// drops marks in favour of a leading `+N` count. The 9pt marks themselves
/// never shrink — the signal is the element this layout protects.
enum WorkspacePulseMarkRowMetrics {
    static let preferredSlot: CGFloat = 14
    static let preferredSpacing: CGFloat = 7
    static let minimumSlot: CGFloat = 9
    static let minimumSpacing: CGFloat = 2
    /// Room held back for the `+N` overflow count when marks get dropped.
    static let overflowLabelWidth: CGFloat = 24

    struct Layout: Equatable {
        var slot: CGFloat
        var spacing: CGFloat
        var visibleCount: Int
        var hiddenCount: Int

        /// Square side for a mark in this layout. The slot may yield its
        /// breathing room, but the mark itself stays at the contractual 9pt.
        var markSide: CGFloat {
            9
        }
    }

    static func width(count: Int, slot: CGFloat, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return slot * CGFloat(count) + spacing * CGFloat(count - 1)
    }

    static func layout(count: Int, availableWidth: CGFloat) -> Layout {
        guard count > 0 else {
            return Layout(
                slot: preferredSlot,
                spacing: preferredSpacing,
                visibleCount: 0,
                hiddenCount: 0
            )
        }

        // A width of zero is the first layout pass before the geometry
        // resolves; render at preferred metrics rather than collapsing to a
        // `+N` count that would flash on every appearance.
        guard availableWidth > 0 else {
            return Layout(
                slot: preferredSlot,
                spacing: preferredSpacing,
                visibleCount: count,
                hiddenCount: 0
            )
        }

        if width(count: count, slot: preferredSlot, spacing: preferredSpacing) <= availableWidth {
            return Layout(
                slot: preferredSlot,
                spacing: preferredSpacing,
                visibleCount: count,
                hiddenCount: 0
            )
        }

        if count > 1 {
            let fittedSpacing = (availableWidth - preferredSlot * CGFloat(count)) / CGFloat(count - 1)
            if fittedSpacing >= minimumSpacing {
                return Layout(
                    slot: preferredSlot,
                    spacing: min(preferredSpacing, fittedSpacing),
                    visibleCount: count,
                    hiddenCount: 0
                )
            }
        }

        let gaps = minimumSpacing * CGFloat(count - 1)
        let fittedSlot = (availableWidth - gaps) / CGFloat(count)
        if fittedSlot >= minimumSlot {
            return Layout(
                slot: min(preferredSlot, fittedSlot),
                spacing: minimumSpacing,
                visibleCount: count,
                hiddenCount: 0
            )
        }

        let widthForMarks = availableWidth - overflowLabelWidth - minimumSpacing
        let stride = minimumSlot + minimumSpacing
        let fitCount = widthForMarks > 0
            ? Int(((widthForMarks + minimumSpacing) / stride).rounded(.down))
            : 0
        let visible = max(0, min(count - 1, fitCount))
        return Layout(
            slot: minimumSlot,
            spacing: minimumSpacing,
            visibleCount: visible,
            hiddenCount: count - visible
        )
    }
}

enum ActivityMarkSettings {
    static let staticMarksKey = "staticActivityMarks"
    static let defaultStaticMarks = false

    /// What the tab strip may animate: default lifecycle motion stops for
    /// Static marks; explicit (flag) motion stops only for Reduce Motion.
    /// A sidebar mark's motion from its state and the settings. Reduce Motion
    /// stops every mark, flags included; Static marks stops unflagged marks
    /// only (flags keep moving, as Settings says).
    static func sidebarMotion(state: WorkspacePulseState, flagged: Bool, suppressed: Bool,
                              animationEligible: Bool, sceneActive: Bool, reduceMotion: Bool,
                              staticMarks: Bool) -> BonsplitActivityMarkMotion? {
        guard animationEligible, sceneActive, !reduceMotion else { return nil }
        if flagged {
            switch state {
            case .working, .idle, .cold: return .breathe
            case .waiting: return .binaryFlash
            }
        }
        guard !suppressed, !staticMarks else { return nil }
        switch state {
        case .working: return .steppedFill
        case .waiting: return .easedDip
        case .idle, .cold: return nil
        }
    }

    static func motionPermissions(inputActive: Bool, sceneActive: Bool, reduceMotion: Bool,
                                  staticMarks: Bool) -> (defaultMotion: Bool, explicitMotion: Bool) {
        let live = inputActive && sceneActive && !reduceMotion
        return (live && !staticMarks, live)
    }
}

/// Native tooltip/accessibility leaf for an individual sidebar mark.
///
/// Elapsed text is refreshed on appearance and hover entry, so no per-agent
/// timer or date formatting reaches the typing-hot workspace row body.
private struct WorkspacePulseActivityHelpTarget<Content: View>: View {
    let activityHelp: AgentActivityHelpProjection
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    @State private var tooltipText: String
    @State private var accessibilityText: String

    init(
        activityHelp: AgentActivityHelpProjection,
        accessibilityLabel: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.activityHelp = activityHelp
        self.accessibilityLabel = accessibilityLabel
        self.content = content
        _tooltipText = State(
            initialValue: ([activityHelp.help.stateLabel] + activityHelp.help.detailLines)
                .joined(separator: "\n")
        )
        _accessibilityText = State(initialValue: activityHelp.accessibilityValue)
    }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .onAppear { refreshHelp() }
            .onHover { hovering in
                guard hovering else { return }
                refreshHelp()
            }
            .help(tooltipText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(accessibilityText))
    }

    private func refreshHelp() {
        let now = Date()
        tooltipText = activityHelp.text(at: now)
        accessibilityText = BonsplitTabActivityHelpFormatter.accessibilityValue(
            for: activityHelp.help,
            at: now
        )
    }
}

/// Leaf-isolated workspace-pulse mark. This is the c11 renderer half of the
/// shared 9pt vocabulary; its clock and phase sampling are the same Bonsplit
/// primitives used by surface-tab marks.
private struct WorkspacePulseMark: View {
    private static let flaggedColor = Color(
        nsColor: NSColor(
            srgbRed: 0x9D / 255,
            green: 0x8A / 255,
            blue: 0xD9 / 255,
            alpha: 1
        )
    )

    let state: WorkspacePulseState
    let lifecycleColor: Color
    let flagColor: Color?
    let phaseId: UUID
    let flagged: Bool
    let suppressed: Bool
    /// Delegate hops; draws one baseline rule per hop, capped at two.
    let lineageDepth: Int
    let animationEligible: Bool
    /// The theme's `states.flag` for an unnamed flag; nil is today's violet.
    var genericFlagColor: Color? = nil
    /// The theme's `geometry.markRadius` for the mark's cell; nil is square.
    var markRadius: CGFloat? = nil

    @AppStorage(ActivityMarkSettings.staticMarksKey)
    private var staticMarks = ActivityMarkSettings.defaultStaticMarks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var presentedState: WorkspacePulseState {
        suppressed && !flagged && state == .waiting ? .idle : state
    }

    /// A named flag token or generic violet, else the caller's lifecycle color
    /// (already cache blue for a cache-cold mark). Delegation never recolors;
    /// it draws the baseline.
    private var color: Color {
        flagged ? (flagColor ?? genericFlagColor ?? Self.flaggedColor) : lifecycleColor
    }

    private var displayedLineageDepth: Int {
        BonsplitActivityMarkLineage.displayedDepth(lineageDepth)
    }

    private var motion: BonsplitActivityMarkMotion? {
        ActivityMarkSettings.sidebarMotion(state: presentedState, flagged: flagged, suppressed: suppressed,
                                           animationEligible: animationEligible,
                                           sceneActive: scenePhase == .active,
                                           reduceMotion: reduceMotion, staticMarks: staticMarks)
    }

    /// C11H-238: dots, cores and the flagged flash move in Core Animation;
    /// a breathing mark is hosted in `BonsplitActivityMarkBreathe`. No tick
    /// writes this view's state.
    private var layerMotion: BonsplitActivityMarkMotion? {
        motion == .breathe ? nil : motion
    }

    var body: some View {
        if motion == .breathe {
            BonsplitActivityMarkBreathe(phaseId: phaseId) {
                markShape.frame(width: 9, height: 9)
            }
            .frame(width: 9, height: 9)
        } else {
            markShape
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var markShape: some View {
        if displayedLineageDepth > 0 {
            lineageMarkShape
        } else {
            fullCellMarkShape
        }
    }

    /// A delegate's mark: the lifecycle shape shortened above one 1pt rule per
    /// delegate hop, the same whole-point geometry as Bonsplit's tab mark.
    private var lineageMarkShape: some View {
        let depth = displayedLineageDepth
        let height = BonsplitActivityMarkLineage.markHeight(depth: depth)
        return ZStack(alignment: .topLeading) {
            lineageLifecycleShape(depth: depth, height: height)
                .frame(width: 9, height: height)
            ForEach(BonsplitActivityMarkLineage.ruleOffsets(depth: depth), id: \.self) { y in
                Rectangle()
                    .fill(color)
                    .frame(width: 9, height: BonsplitActivityMarkLineage.ruleThickness)
                    .offset(y: y)
            }
        }
        .frame(width: 9, height: 9, alignment: .topLeading)
    }

    @ViewBuilder
    private func lineageLifecycleShape(depth: Int, height: CGFloat) -> some View {
        switch presentedState {
        case .working:
            let rows = BonsplitActivityMarkLineage.workingDotRows(depth: depth)
            ZStack {
                cell
                    .fill(color.opacity(0.25))
                BonsplitActivityMarkMotionOverlay(
                    part: .workingDots(rows: rows), color: color, motion: layerMotion, phaseId: phaseId
                )
            }

        case .waiting:
            let coreHeight = BonsplitActivityMarkLineage.waitingCoreHeight(depth: depth)
            ZStack {
                cell
                    .strokeBorder(color, lineWidth: 1.5)
                BonsplitActivityMarkMotionOverlay(
                    part: .waitingCore(height: coreHeight), color: color,
                    alternateColor: flagged ? Color.white : nil, motion: layerMotion, phaseId: phaseId
                )
            }

        case .idle:
            cell
                .strokeBorder(color, lineWidth: 1)

        case .cold:
            Rectangle()
                .fill(color)
                .frame(width: 9, height: 2)
                .frame(width: 9, height: height)
        }
    }

    @ViewBuilder
    private var fullCellMarkShape: some View {
        switch presentedState {
        case .working:
            ZStack {
                cell
                    .fill(color.opacity(0.25))
                    .frame(width: 9, height: 9)
                BonsplitActivityMarkMotionOverlay(
                    part: .workingDots(rows: 3), color: color, motion: layerMotion, phaseId: phaseId
                )
                .frame(width: 9, height: 9)
            }

        case .waiting:
            ZStack {
                cell
                    .strokeBorder(color, lineWidth: 1.5)
                BonsplitActivityMarkMotionOverlay(
                    part: .waitingCore(height: 4), color: color,
                    alternateColor: flagged ? Color.white : nil, motion: layerMotion, phaseId: phaseId
                )
                .frame(width: 9, height: 9)
            }

        case .idle:
            cell
                .strokeBorder(color, lineWidth: 1)

        case .cold:
            Rectangle()
                .fill(color)
                .frame(width: 9, height: 2)
        }
    }

    /// The mark's 9pt cell: square, or rounded by the theme.
    private var cell: WorkspacePulseMarkCell {
        WorkspacePulseMarkCell(radius: markRadius)
    }

}

/// Joins the workspace pulse card's surface census.
///
/// Absent kinds are dropped rather than reported as zero: a card that spends
/// its one census line on "0 browsers" has nothing left for the kinds the
/// workspace actually holds, and the sidebar is narrow enough that the line
/// truncates when every kind is listed.
enum WorkspacePulseCensus {
    static func line(
        parts: [(count: Int, label: String)],
        separator: String,
        empty: String
    ) -> String {
        let present = parts.filter { $0.count > 0 }.map(\.label)
        return present.isEmpty ? empty : present.joined(separator: separator)
    }
}

enum WorkspacePulseDividerColorResolver {
    static func resolve(
        customHex: String?,
        colorScheme: ColorScheme
    ) -> NSColor {
        guard let customHex else { return BrandColors.gold }
        return WorkspaceColorSettings.displayNSColor(
            hex: customHex,
            colorScheme: colorScheme
        ) ?? BrandColors.gold
    }
}

/// C11-25: the focused surface's CPU/RSS readout inside a workspace card.
///
/// The sampler's 2 Hz `revision` is observed HERE and never inside
/// `TabItemView`'s Equatable body — the same containment discipline
/// `SidebarProgressIndicator` uses for the decay clock. Two consequences
/// the sidebar depends on:
///
/// 1. The slot always occupies its line. A workspace whose focused surface
///    has no sample yet (terminal still resolving its PID, browser between
///    WebContent processes) shows a dimmed placeholder in the same font and
///    on the same baseline, so real values fade in without the card
///    restructuring underneath them.
/// 2. `TabItemView`'s body no longer re-evaluates twice a second just
///    because a digit moved, which is what tore down an open workspace
///    context menu while the operator was still reading it.
private struct SidebarPanelMetricsReadout: View {
    @ObservedObject private var sampler = PanelMetricsSampler.shared

    /// Focused surface for the workspace, or nil when the workspace has no
    /// focused panel. Either way the slot renders.
    let surfaceId: UUID?
    let valueColor: Color
    let placeholderColor: Color
    /// The theme's `cardLabel` style; unset draws today's 9pt mono.
    var labelStyle: ThemeTextStyle = .unset

    /// Null state. Holds the shape of a real reading ("12% 340MB") without
    /// asserting a number. Glyph-only, so it needs no localization.
    static let placeholder = "–% –MB"

    /// Render a Sample as a compact "<cpu>% <mem>" string.
    /// CPU is integer percent (0%–800% on multi-core spikes); memory is
    /// integer MB up to 1024, otherwise 1-decimal GB.
    nonisolated static func format(_ sample: PanelMetricsSampler.Sample) -> String {
        let cpu = "\(Int(sample.cpuPct.rounded()))%"
        let mem: String
        if sample.rssMb >= 1024 {
            mem = String(format: "%.1fGB", sample.rssMb / 1024)
        } else {
            mem = "\(Int(sample.rssMb.rounded()))MB"
        }
        return "\(cpu) \(mem)"
    }

    var body: some View {
        let sample = surfaceId.flatMap { sampler.sample(forSurfaceId: $0) }
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(verbatim: labelStyle.apply(sample.map(Self.format) ?? Self.placeholder))
                .chromeStyle(labelStyle, size: 9, design: .monospaced)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(sample == nil ? placeholderColor : valueColor)
                // Trailing-aligned against a floor width so a value growing
                // from "0% 1MB" to "104% 1.2GB" never nudges the line.
                .frame(minWidth: 52, alignment: .trailing)
                .accessibilityIdentifier(
                    sample == nil
                        ? "SidebarTabSurfaceMetricsPlaceholder"
                        : "SidebarTabSurfaceMetrics"
                )
        }
        .padding(.top, 1)
    }
}

// PERF: TabItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every TabManager
// or NotificationStore publish causes ALL tab items to re-evaluate (~18% of
// main thread during typing). If you add new properties, update == below.
// Do NOT add @EnvironmentObject or new @Binding without updating ==.
// Do NOT remove .equatable() from the ForEach call site in VerticalTabsSidebar.
//
// The flash snapshot participates in parent equality. Delivery observes the
// workspace directly: a flash does not change the parent's group projection.
#if DEBUG
private let sidebarRowProbeEnabled = ProcessInfo.processInfo.environment["C11_SIDEBAR_ROW_PROBE"] == "1"
#endif

private struct WorkspaceRowView: View, Equatable {
    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    nonisolated static func == (lhs: WorkspaceRowView, rhs: WorkspaceRowView) -> Bool {
        lhs.workspace === rhs.workspace &&
        lhs.index == rhs.index &&
        lhs.visibleWorkspaceIds == rhs.visibleWorkspaceIds &&
        lhs.availableGroups == rhs.availableGroups &&
        lhs.isActive == rhs.isActive &&
        lhs.worktreeChipRows == rhs.worktreeChipRows &&
        lhs.missionSnapshot == rhs.missionSnapshot &&
        lhs.captainSnapshot == rhs.captainSnapshot &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.workspacePulse == rhs.workspacePulse &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsWorkspaceId == rhs.showsWorkspaceId &&
        // NSColor equality compares colour space and components without
        // formatting a string per row on every parent evaluation.
        lhs.themedBackgroundColor == rhs.themedBackgroundColor &&
        lhs.themedRailColor == rhs.themedRailColor &&
        lhs.themedFillCarriesWorkspaceColor == rhs.themedFillCarriesWorkspaceColor &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.sidebarFlashSnapshot == rhs.sidebarFlashSnapshot &&
        lhs.chromeTokens == rhs.chromeTokens &&
        lhs.tiled == rhs.tiled &&
        lhs.themeStyle == rhs.themeStyle &&
        lhs.density == rhs.density
    }

    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let workspaceManager: WorkspaceManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var workspace: Workspace
    let index: Int
    let visibleWorkspaceIds: [UUID]
    let availableGroups: [WorkspaceGroup]
    let isActive: Bool
    /// C11-104: precomputed worktree/branch chip rows for the focused
    /// surface. Empty when the setting is disabled or the surface is
    /// not in a git directory. Keeping the projection upstream means
    /// the TabItemView body does zero IO/git work.
    let worktreeChipRows: [WorktreeChipRow]
    /// Equality snapshot for parent updates. The already-observed workspace
    /// also publishes file edits directly; the body reads its precomputed value.
    let missionSnapshot: WorkspaceMission?
    let captainSnapshot: WorkspaceCaptainSummary
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    /// Cheap, value-typed rollup of the workspace's existing notification and
    /// agent-liveness truth. Precomputed by VerticalTabsSidebar.
    let workspacePulse: WorkspacePulseSummary
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    @Binding var selectedWorkspaceIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    /// Show the workspace's `workspace:N` number in the title row's trailing
    /// slot. Passed in (not @AppStorage) so `==` sees the toggle.
    let showsWorkspaceId: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedWorkspaceId: UUID?
    @Binding var draggedGroupId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let themedBackgroundColor: NSColor?
    let themedRailColor: NSColor?
    /// The themed Solid Fill is built from this workspace's own colour, so the
    /// card fill already shows it and the identity notch is left off.
    let themedFillCarriesWorkspaceColor: Bool
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let sidebarFlashSnapshot: FocusFlashRequest?
    @State private var activeSidebarFlash: FocusFlashRequest?
    /// Value-typed scale remains part of the row equality contract.
    let chromeTokens: ChromeScaleTokens
    /// In the Tiles grid the card stretches to its row's tallest card.
    var tiled: Bool = false
    /// Schema-2 sidebar values; `.unset` fields keep today's drawing. Compared by
    /// its theme stamp in `==`.
    let themeStyle: SidebarThemeStyle
    /// C11H-221: the full card, or the two-line compact card.
    var density: SidebarDensity = .cards
    @State private var isHovering = false
    @State private var rowHeight: CGFloat = 1
    /// The icon picker's popover, opened from the context menu (C11H-343).
    @State private var iconPickerRequest: SidebarIconPickerRequest?

    @AppStorage("sidebarShowGitBranch") private var sidebarShowGitBranch = true
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage("sidebarShowBranchDirectory") private var sidebarShowBranchDirectory = true
    @AppStorage("sidebarShowGitBranchIcon") private var sidebarShowGitBranchIcon = false
    @AppStorage("sidebarShowPullRequest") private var sidebarShowPullRequest = true
    @AppStorage(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
    private var openSidebarPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser
    @AppStorage("sidebarShowSSH") private var sidebarShowSSH = true
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = true
    @AppStorage("sidebarShowLog") private var sidebarShowLog = true
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = true
    @AppStorage("sidebarShowStatusPills") private var sidebarShowMetadata = true
    @AppStorage(SidebarWorkspaceDetailSettings.hideAllDetailsKey)
    private var sidebarHideAllDetails = SidebarWorkspaceDetailSettings.defaultHideAllDetails
    @AppStorage(SidebarActiveWorkspaceIndicatorSettings.styleKey)
    private var activeWorkspaceIndicatorStyleRaw = SidebarActiveWorkspaceIndicatorSettings.defaultStyle.rawValue
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var isMultiSelected: Bool {
        selectedWorkspaceIds.contains(workspace.id)
    }

    private var isBeingDragged: Bool {
        draggedWorkspaceId == workspace.id
    }

    private var activeWorkspaceIndicatorStyle: SidebarActiveWorkspaceIndicatorStyle {
        SidebarActiveWorkspaceIndicatorSettings.resolvedStyle(rawValue: activeWorkspaceIndicatorStyleRaw)
    }

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var usesInvertedActiveForeground: Bool {
        false
    }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? BrandColors.goldSwiftUI
            : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.8) : cmuxAccentColor()
    }

    private var showCloseButton: Bool {
        isHovering && canCloseWorkspace
    }

    /// Gold on the selected card, like the visible panel's number in the
    /// panel bar; muted elsewhere. A custom-tinted selected card keeps its
    /// inverted foreground so the number stays legible on the tint.
    private var workspaceIdColor: Color {
        guard isActive else { return themeStyle.cardTextSecondary ?? activeSecondaryColor(0.55) }
        return usesInvertedActiveForeground
            ? activePrimaryTextColor
            : (themeStyle.cardAccent ?? Color(nsColor: BrandColors.gold))
    }

    /// The workspace name in the card's title style. Terminal Grid prefixes the
    /// tree's root (`┌`) and draws the selected name in its accent.
    private var workspaceTitleText: Text {
        workspaceTitleText(size: chromeTokens.sidebarWorkspaceTitle + 1.5)
    }

    private func workspaceTitleText(size: CGFloat) -> Text {
        let style = themeStyle.cardTitle
        let boxDrawing = themeStyle.cardHeader == .boxDrawing
        let titleColor = boxDrawing && isActive
            ? (themeStyle.cardAccent ?? themeStyle.cardText ?? .primary)
            : (themeStyle.cardText ?? .primary)
        let title = Text(verbatim: style.apply(workspace.title)).foregroundColor(titleColor)
        let line = boxDrawing
            ? Text(verbatim: "\u{250C} ")
                .fontWeight(.regular)
                .foregroundColor(themeStyle.cardTextDim ?? .secondary)
                + title
            : title
        return line.chromeStyle(style, size: size, weight: titleFontWeight)
    }

    private var remoteWorkspaceSidebarText: String? {
        guard workspace.hasActiveRemoteTerminalSessions else { return nil }
        let trimmedTarget = workspace.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "SSH workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.remoteConnectionState == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = workspace.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch workspace.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        }
    }

    private var workspacePulseColors: BonsplitConfiguration.Appearance.TabActivityColors {
        Workspace.resolvedSurfaceTabActivityColors(
            from: colorScheme == .light
                ? NSColor(calibratedWhite: 0.96, alpha: 1)
                : NSColor(calibratedWhite: 0.06, alpha: 1),
            states: themeStyle.statePalette
        )
    }

    private func workspacePulseColor(for state: WorkspacePulseState) -> Color {
        let hex: String?
        switch state {
        case .waiting: hex = workspacePulseColors.waitingHex
        case .working: hex = workspacePulseColors.runningHex
        case .idle: hex = workspacePulseColors.idleHex
        case .cold: hex = workspacePulseColors.coldHex
        }
        return Color(nsColor: hex.flatMap(NSColor.init(hex:)) ?? .secondaryLabelColor)
    }

    private func workspacePulseLabel(for state: WorkspacePulseState) -> String {
        switch state {
        case .waiting:
            return String(localized: "sidebar.workspacePulse.needsYou", defaultValue: "Needs you")
        case .working:
            return SidebarActivityProjector.derivedText(.working)
        case .idle:
            return SidebarActivityProjector.derivedText(.idle)
        case .cold:
            return String(localized: "sidebar.workspacePulse.cold", defaultValue: "Cold")
        }
    }

    /// Leaf-isolated 9pt mark matching the Bonsplit surface-tab vocabulary.
    private func workspacePulseMark(for agent: WorkspacePulseAgent, animated: Bool = true) -> some View {
        WorkspacePulseMark(
            state: agent.state,
            lifecycleColor: agent.markTint == .usageLimit ? (themeStyle.stateUsageLimit ?? .red) : agent.showsPromptCacheColor
                ? Color(nsColor: NSColor(hex: Workspace.promptCacheColdHex(lightBackground: colorScheme == .light, states: themeStyle.statePalette))
                    ?? .secondaryLabelColor)
                : workspacePulseColor(for: agent.presentedState),
            flagColor: agent.flagKind.map {
                Color(nsColor: NSColor(hex: $0.colorHex(lightBackground: colorScheme == .light))
                    ?? .secondaryLabelColor)
            },
            phaseId: agent.surfaceId,
            flagged: agent.flagged,
            suppressed: agent.suppressed,
            lineageDepth: agent.lineageDepth,
            animationEligible: animated && isActive,
            genericFlagColor: themeStyle.stateFlag,
            markRadius: themeStyle.markRadius
        )
    }

    @ViewBuilder
    private func workspacePulseMarkTarget(
        for agent: WorkspacePulseAgent,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        workspacePulseHelpTarget(for: agent) {
            workspacePulseMark(for: agent)
                .frame(width: width, height: height)
        }
    }

    /// The tooltip and accessibility of an agent's state, around whatever draws
    /// it: the mark, a theme's tree glyph, or its LIVE/HOLD tag.
    @ViewBuilder
    private func workspacePulseHelpTarget<Content: View>(
        for agent: WorkspacePulseAgent,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let lead = content()
        if let activityHelp = agent.activityHelp {
            WorkspacePulseActivityHelpTarget(
                activityHelp: activityHelp,
                accessibilityLabel: workspacePulseMarkAccessibilityLabel(agent)
            ) {
                lead
            }
        } else {
            lead
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(workspacePulseMarkAccessibilityLabel(agent)))
                .accessibilityValue(Text(workspacePulseLabel(for: agent.presentedState)))
        }
    }

    /// What leads an agent row: the 16pt state mark, or a theme ornament in its
    /// place (C11H-148). Terminal Grid draws its tree glyph in the mark's slot;
    /// Big Board's LIVE and HOLD tags take a fixed slot of their own.
    @ViewBuilder
    private func workspacePulseRowLead(for agent: WorkspacePulseAgent, index: Int) -> some View {
        if themeStyle.cardHeader == .boxDrawing {
            let isLast = index == workspacePulseVisibleAgents.count - 1
            workspacePulseHelpTarget(for: agent) {
                Text(verbatim: isLast ? "\u{2514}\u{2500}" : "\u{251C}\u{2500}")
                    .font(ThemeFontFamily.font(
                        named: themeStyle.monoFamily ?? "system-mono",
                        size: chromeTokens.sidebarWorkspaceDetail + 1,
                        weight: .regular,
                        defaultDesign: .monospaced
                    ))
                    .foregroundColor(themeStyle.cardTextDim ?? Color.secondary.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 16, height: 16, alignment: .leading)
            }
        } else if themeStyle.stateTags {
            workspacePulseStateTag(for: agent)
        } else {
            workspacePulseMarkTarget(for: agent, width: 16, height: 16)
        }
    }

    /// Big Board: LIVE for a working agent, HOLD for one waiting on the operator,
    /// the mark for every other state (flags keep their mark and colour).
    @ViewBuilder
    private func workspacePulseStateTag(for agent: WorkspacePulseAgent) -> some View {
        let live = String(localized: "sidebar.workspacePulse.stateTag.live", defaultValue: "LIVE")
        let hold = String(localized: "sidebar.workspacePulse.stateTag.hold", defaultValue: "HOLD")
        let size = chromeTokens.sidebarWorkspaceAccessory - 1
        let tag: String? = {
            guard !agent.flagged else { return nil }
            switch agent.presentedState {
            case .working: return live
            case .waiting: return hold
            case .idle, .cold: return nil
            }
        }()
        // One slot for every row, as wide as the wider tag in this language, so
        // a row's text never moves when its agent changes state.
        let slot = SidebarStateTagMetrics.slotWidth(
            family: themeStyle.monoFamily, size: size, tracking: size * 0.14, tags: [live, hold])
        Group {
            if let tag {
                let color = workspacePulseColor(for: agent.presentedState)
                workspacePulseHelpTarget(for: agent) {
                    Text(verbatim: tag)
                        .font(ThemeFontFamily.font(
                            named: themeStyle.monoFamily ?? "system-mono",
                            size: size,
                            weight: .semibold,
                            defaultDesign: .monospaced
                        ))
                        .tracking(size * 0.14)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(color)
                        .padding(.horizontal, SidebarStateTagMetrics.horizontalPadding)
                        .padding(.vertical, 1)
                        .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
                }
            } else {
                workspacePulseMarkTarget(for: agent, width: 16, height: 16)
            }
        }
        .frame(width: slot, alignment: .leading)
        .frame(minHeight: 16)
    }

    private var workspacePulseVisibleAgents: [WorkspacePulseAgent] {
        Array(workspacePulse.relevantAgents.prefix(2))
    }

    private var workspacePulseWaitingOverflow: Int {
        workspacePulse.visibleWaitingOverflow(visibleAgents: workspacePulseVisibleAgents)
    }

    private func workspacePulseMarkAccessibilityLabel(_ agent: WorkspacePulseAgent) -> String {
        let label = agent.context?.title
            ?? String(localized: "surfaceManifest.detail.activity", defaultValue: "Activity")
        guard agent.flagged, let kind = agent.flagKind else { return label }
        return String.localizedStringWithFormat(
            String(
                localized: "sidebar.workspacePulse.namedFlagAccessibility",
                defaultValue: "%@, flagged %@"
            ),
            label,
            kind.displayLabel
        )
    }

    private func openWorkspacePulseAgent(_ agent: WorkspacePulseAgent) {
        guard agent.flagged || agent.presentedState == .waiting else { return }
        _ = AppDelegate.shared?.operatorOpenNotification(
            workspaceId: workspace.id,
            surfaceId: agent.surfaceId,
            notificationId: nil
        )
    }

    @ViewBuilder
    private func workspacePulseSummaryRow(
        _ agent: WorkspacePulseAgent,
        index: Int
    ) -> some View {
        let context = agent.context
        let rowStyle = themeStyle.agentRow
        let rowSize = chromeTokens.sidebarWorkspaceDetail + 1
        let content = HStack(spacing: 7) {
            workspacePulseRowLead(for: agent, index: index)

            Group {
                if agent.flagged, let reason = agent.flagReason {
                    Text(verbatim: rowStyle.apply(agent.flagKind?.displayText(reason: reason) ?? reason))
                        .fontWeight(rowStyle.fontWeight ?? .medium)
                } else if let context {
                    (
                        Text(verbatim: rowStyle.apply(context.title)).fontWeight(rowStyle.fontWeight ?? .medium)
                        + Text(verbatim: context.subtitle.map { rowStyle.apply(" · \($0)") } ?? "")
                    )
                } else {
                    Text(verbatim: rowStyle.apply(workspacePulseLabel(for: agent.presentedState)))
                }
            }
            .chromeTextStyle(rowStyle, size: rowSize)
            .foregroundColor(index == 0
                ? (themeStyle.cardText ?? Color.primary.opacity(0.86))
                : (themeStyle.cardTextSecondary ?? Color.secondary.opacity(0.72)))
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)

            // C11H-278: how long ago the shown description was edited, in a
            // fixed column every agent row reserves. A child view: it listens
            // to the coarse clock itself, so this Equatable row never does.
            DescriptionAgeLabel(
                updatedAt: agent.flagged && agent.flagReason != nil ? nil : context?.descriptionUpdatedAt,
                style: .compact,
                fontSize: chromeTokens.sidebarWorkspaceMetadata,
                color: themeStyle.cardTextDim ?? .secondary.opacity(0.65)
            )
        }

        if agent.flagged || agent.presentedState == .waiting {
            Button(action: { openWorkspacePulseAgent(agent) }) {
                content
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                agent.context?.title ?? workspacePulseMarkAccessibilityLabel(agent)
            ))
            .accessibilityValue(Text(
                agent.activityHelp?.accessibilityValue
                    ?? workspacePulseLabel(for: agent.presentedState)
            ))
        } else {
            content
        }
    }

    @ViewBuilder
    private var workspacePulseSummaries: some View {
        VStack(alignment: .leading, spacing: 5) {
            if workspacePulseVisibleAgents.isEmpty {
                Text(verbatim: themeStyle.cardLabel.apply(String(
                    localized: "sidebar.workspacePulse.terminalsOnly",
                    defaultValue: "Terminals only · no agent panels"
                )))
                .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceMetadata, design: .monospaced)
                .foregroundColor(themeStyle.cardTextDim ?? .secondary.opacity(0.65))
                .lineLimit(1)
            } else {
                ForEach(Array(workspacePulseVisibleAgents.enumerated()), id: \.element.id) { index, agent in
                    workspacePulseSummaryRow(agent, index: index)
                }
                if workspacePulseWaitingOverflow > 0 {
                    Text(verbatim: themeStyle.cardLabel.apply(String(
                        localized: "sidebar.workspacePulse.moreWaiting",
                        defaultValue: "… and \(workspacePulseWaitingOverflow) more"
                    )))
                    .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceMetadata, design: .monospaced)
                    .foregroundColor(themeStyle.cardTextDim ?? .secondary.opacity(0.62))
                    .padding(.leading, 23)
                }
            }
        }
        .padding(.top, 9)
    }

    private var workspacePulseAgentCountText: String {
        if workspacePulse.agents.count == 1 {
            return String(
                localized: "sidebar.workspacePulse.agentCount.one",
                defaultValue: "1 agent"
            )
        }
        return String(
            localized: "sidebar.workspacePulse.agentCount.other",
            defaultValue: "\(workspacePulse.agents.count) agents"
        )
    }

    private var workspacePulseTerminalCountText: String {
        if workspacePulse.terminalCount == 1 {
            return String(
                localized: "sidebar.workspacePulse.terminalCount.one",
                defaultValue: "1 terminal"
            )
        }
        return String(
            localized: "sidebar.workspacePulse.terminalCount.other",
            defaultValue: "\(workspacePulse.terminalCount) terminals"
        )
    }

    private var workspacePulseBrowserCountText: String {
        if workspacePulse.browserCount == 1 {
            return String(
                localized: "sidebar.workspacePulse.browserCount.one",
                defaultValue: "1 browser"
            )
        }
        return String(
            localized: "sidebar.workspacePulse.browserCount.other",
            defaultValue: "\(workspacePulse.browserCount) browsers"
        )
    }

    private var workspacePulseDocumentCountText: String {
        if workspacePulse.documentCount == 1 {
            return String(
                localized: "sidebar.workspacePulse.documentCount.one",
                defaultValue: "1 doc"
            )
        }
        return String(
            localized: "sidebar.workspacePulse.documentCount.other",
            defaultValue: "\(workspacePulse.documentCount) docs"
        )
    }

    /// The workspace's whole surface census on one line, every kind it
    /// actually holds: "13 agents, 2 browsers, 1 doc".
    private var workspacePulseCensusText: String {
        WorkspacePulseCensus.line(
            parts: [
                (workspacePulse.agents.count, workspacePulseAgentCountText),
                (workspacePulse.terminalCount, workspacePulseTerminalCountText),
                (workspacePulse.browserCount, workspacePulseBrowserCountText),
                (workspacePulse.documentCount, workspacePulseDocumentCountText)
            ],
            separator: String(
                localized: "sidebar.workspacePulse.censusSeparator",
                defaultValue: ", "
            ),
            empty: String(
                localized: "sidebar.workspacePulse.censusEmpty",
                defaultValue: "No panels"
            )
        )
    }

    /// Trailing-aligned census of per-agent state marks.
    ///
    /// Sized against measured geometry rather than a fixed slot per agent so
    /// a busy workspace cannot push the card wider than the sidebar. When
    /// even the compressed metrics run out of room the row keeps the marks
    /// nearest the trailing edge and counts the rest in a leading `+N`; the
    /// composition rail at the foot of the card still carries the full
    /// state distribution.
    @ViewBuilder
    private func workspacePulseMarkRow() -> some View {
        let agents = workspacePulse.agents
        GeometryReader { proxy in
            let layout = WorkspacePulseMarkRowMetrics.layout(count: agents.count, availableWidth: proxy.size.width)
            let visible = Array(agents.suffix(layout.visibleCount))
            // Trailing alignment comes from the outer frame rather than a
            // leading Spacer: a Spacer would add one more `layout.spacing`
            // gap on top of the width the metrics just fitted.
            HStack(spacing: layout.spacing) {
                if layout.hiddenCount > 0 {
                    Text(verbatim: "+\(layout.hiddenCount)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel(Text(String(
                            localized: "sidebar.workspacePulse.markOverflow",
                            defaultValue: "\(layout.hiddenCount) more agents"
                        )))
                }

                ForEach(visible) { agent in
                    workspacePulseMarkTarget(
                        for: agent,
                        width: layout.slot,
                        height: 14
                    )
                }
            }
            .frame(width: proxy.size.width, height: 14, alignment: .trailing)
        }
        .frame(height: 14)
    }

    private var workspacePulseFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                // Three or four kinds on a ~160pt card outruns the line.
                // Shrinking the census is a better trade than cutting the
                // last kind off it: the counts stay readable, and a card
                // that lists browsers is exactly the card that needed the
                // extra room.
                Text(verbatim: themeStyle.cardLabel.apply(workspacePulseCensusText))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                captainSlot(captain: workspace.captainSummary, ink: nil, scale: chromeTokens.multiplier, width: 76)
            }

            workspacePulseMarkRow()
        }
        .chromeTextStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceMetadata - 0.5, design: .monospaced)
        .foregroundColor(themeStyle.cardTextDim ?? .secondary.opacity(0.68))
        .padding(.top, 8)
        .overlay(alignment: .top) {
            workspacePulseRule(color: themeStyle.cardRule ?? workspacePulseDividerColor.opacity(0.42))
        }
        .padding(.top, 10)
    }

    /// The card's horizontal rule; dotted in Terminal Grid's box-drawing cards.
    @ViewBuilder
    private func workspacePulseRule(color: Color) -> some View {
        if themeStyle.cardHeader == .boxDrawing {
            WorkspaceCardDottedRule(color: color)
                .frame(height: 1)
        } else {
            Rectangle()
                .fill(color)
                .frame(height: 1)
        }
    }

    private func workspacePulseCompositionRail(scale: CGFloat = 1, topPadding: CGFloat = 9) -> some View {
        let shape = WorkspaceCardBarShape(radius: themeStyle.progressRadius)
        return GeometryReader { proxy in
            let populatedStates = WorkspacePulseState.allCases.filter {
                workspacePulse.agentCount(for: $0) > 0
            }
            let gap: CGFloat = 2 * scale
            let totalGaps = gap * CGFloat(max(0, populatedStates.count - 1))
            let availableWidth = max(0, proxy.size.width - totalGaps)
            HStack(spacing: gap) {
                ForEach(populatedStates, id: \.self) { state in
                    Rectangle()
                        .fill(workspacePulseColor(for: state))
                        .frame(
                            width: availableWidth
                                * CGFloat(workspacePulse.agentCount(for: state))
                                / CGFloat(max(1, workspacePulse.agents.count))
                        )
                }
            }
        }
        .frame(height: (themeStyle.progressHeightPt ?? 4) * scale)
        .background(
            shape
                .fill(themeStyle.cardProgressTrack ?? BrandColors.ruleSwiftUI.opacity(workspacePulse.agents.isEmpty ? 0.55 : 0.35))
        )
        .clipShape(shape)
        .padding(.top, topPadding)
        .accessibilityHidden(true)
    }

    private var workspacePulseIdentityColor: Color {
        if let themedRailColor {
            return Color(nsColor: themedRailColor)
        }
        if let resolvedCustomWorkspaceColor {
            return resolvedCustomWorkspaceColor
        }
        return Color(nsColor: NSColor(
            srgbRed: 0.44,
            green: 0.51,
            blue: 0.57,
            alpha: 1
        ))
    }

    private var workspacePulseDividerColor: Color {
        Color(nsColor: WorkspacePulseDividerColorResolver.resolve(
            customHex: workspace.customColor,
            colorScheme: colorScheme
        ))
    }

    private var workspacePulseBaseColor: Color {
        // A schema-2 active fill wins over the Solid Fill indicator's tint.
        if usesThemedActiveFill, let fillActive = themeStyle.cardFillActive {
            return fillActive
        }
        if let themedBackgroundColor {
            return Color(nsColor: themedBackgroundColor)
        }
        if let fill = themeStyle.cardFill {
            return fill
        }
        if colorScheme == .light {
            return Color(nsColor: NSColor(
                srgbRed: 0.96,
                green: 0.95,
                blue: 0.93,
                alpha: 1
            ))
        }
        return Color(nsColor: NSColor(
            srgbRed: 0.067,
            green: 0.075,
            blue: 0.09,
            alpha: 1
        ))
    }

    /// True when the card fill already *is* the workspace color: the
    /// `.solidFill` indicator style with a custom color, in a theme whose fill
    /// is built from that color (Stage 11, c11). A fixed theme fill (Nocturne,
    /// Big Board) does not carry it, so the notch stays. The notch would only
    /// repeat the fill otherwise, so it is left off.
    private var cardFillCarriesIdentityColor: Bool {
        workspace.customColor != nil
            && themedBackgroundColor != nil
            && themedFillCarriesWorkspaceColor
            && !usesThemedActiveFill
    }

    /// The selected card draws the theme's `chrome.card.fillActive`.
    private var usesThemedActiveFill: Bool {
        isActive && themeStyle.cardFillActive != nil
    }

    // MARK: Beacon selection
    //
    // The card edge has one grammar in every theme. Only the selected card
    // carries a heavy edge: a 3pt outline, an 8pt bar on the trailing edge
    // with a pointer into the gutter, a soft glow, and (dark appearance only)
    // a wash of the same ink over the fill. All of it is drawn in the theme's
    // selection ink. A workspace's own color never outlines a card; it is a
    // 4pt notch on the leading edge of every card that has one, selected or
    // not. Waiting keeps its thin 1.5pt edge. Shape, not hue, says
    // "selected", so a workspace color can never be mistaken for it.

    /// The theme's selection ink (`chrome.card.borderActive`), else white on
    /// dark and near-black on light.
    private var cardSelectionInk: Color {
        if let themed = themeStyle.cardBorderActive { return themed }
        return colorScheme == .light
            ? BrandColors.blackSwiftUI.opacity(0.92)
            : BrandColors.whiteSwiftUI
    }

    static let beaconBarWidth: CGFloat = 8
    static let beaconNotchWidth: CGFloat = 4
    static let beaconPointerSize = CGSize(width: 5, height: 12)
    /// The selected card's corners never round past this.
    static let beaconMaxCornerRadius: CGFloat = 3

    /// Trailing space every card reserves so content clears the selection
    /// bar by at least 4pt. Constant per theme and density, never per
    /// selection, so text does not reflow when the selection moves.
    var beaconTrailingReserve: CGFloat {
        let horizontalPadding = density == .compact ? 8 : themeStyle.cardPadding.horizontal
        return max(0, Self.beaconBarWidth + 4 - horizontalPadding)
    }

    /// The workspace's own color as the leading notch, or nil when it has
    /// none or the card fill already carries it.
    private var workspaceIdentityNotchColor: Color? {
        guard !cardFillCarriesIdentityColor, let hex = workspace.customColor else { return nil }
        return WorkspaceColorSettings.displayColor(hex: hex, colorScheme: colorScheme)
    }

    /// Edge color. A theme that draws the card edge (C11H-145) supplies its
    /// own waiting and plain edges; selection is always the selection ink.
    private var workspacePulseBorderColor: Color {
        if isActive {
            return cardSelectionInk
        }
        if edgeShowsWaiting {
            if themeStyle.ownsCardEdge, let waiting = themeStyle.cardBorderWaiting { return waiting }
            return workspacePulseColor(for: .waiting).opacity(0.7)
        }
        if themeStyle.ownsCardEdge, let border = themeStyle.cardBorder { return border }
        return workspacePulseIdentityColor.opacity(0.32)
    }

    /// Edge widths: selection is at least 3pt in every theme; otherwise the
    /// theme's `geometry.cardBorderPt`, waiting's 1.5pt, or a 1pt hairline.
    private var workspacePulseBorderLineWidth: CGFloat {
        if isActive { return max(3, themeStyle.cardActiveBorderPt ?? 3) }
        if let width = themeStyle.cardBorderPt { return width }
        if edgeShowsWaiting { return 1.5 }
        return 1
    }

    private var workspacePulseCardOpacity: Double {
        1
    }

    /// Card corner radius: today's 12, or the theme's `geometry.cardRadius`;
    /// the selected card squares off to at most 3pt.
    private var cardCornerRadius: CGFloat {
        let base = density == .compact ? min(themeStyle.cardRadius ?? 12, 6) : (themeStyle.cardRadius ?? 12)
        return isActive ? min(base, Self.beaconMaxCornerRadius) : base
    }

    /// The selected card's glow: the theme's own (`chrome.card.glow`), else
    /// the selection ink, softer on the light card base.
    private var beaconGlowColor: Color? {
        guard isActive else { return nil }
        if let themed = themeStyle.cardGlow { return themed }
        return cardSelectionInk.opacity(colorScheme == .light ? 0.36 : 0.68)
    }

    /// The notch, bar and pointer sit above the card's content, so a header
    /// band or rule that runs to the card edge passes under them.
    @ViewBuilder
    private func workspaceBeaconOverlay() -> some View {
        let shape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        ZStack {
            if let notch = workspaceIdentityNotchColor {
                if isActive {
                    // Inside the selection edge, so the outline does not cover it.
                    let inset = workspacePulseBorderLineWidth
                    Rectangle()
                        .fill(notch)
                        .frame(width: Self.beaconNotchWidth)
                        .padding(.vertical, inset)
                        .padding(.leading, inset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    Rectangle()
                        .fill(notch)
                        .frame(width: Self.beaconNotchWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .clipShape(shape)
                }
            }
            if isActive {
                Rectangle()
                    .fill(cardSelectionInk)
                    .frame(width: Self.beaconBarWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipShape(shape)
                // The pointer sits in the row's 6pt gutter, aimed at the content.
                WorkspaceCardBeaconPointer()
                    .fill(cardSelectionInk)
                    .frame(width: Self.beaconPointerSize.width, height: Self.beaconPointerSize.height)
                    .offset(x: Self.beaconPointerSize.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func workspacePulseCardBackground() -> some View {
        let radius = cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let sheen = themeStyle.cardSheen ?? true
        shape
            .fill(workspacePulseBaseColor)
            .modifier(WorkspaceCardGlow(color: beaconGlowColor))
            .overlay {
                if sheen {
                    RadialGradient(
                        colors: [
                            workspacePulseIdentityColor.opacity(colorScheme == .light ? 0.07 : 0.09),
                            workspacePulseIdentityColor.opacity(0)
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 180
                    )
                    .clipShape(shape)
                }
            }
            .overlay {
                if sheen {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .light ? 0.22 : 0.025),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(shape)
                }
            }
            .overlay {
                // The wash: dark appearance only; on the light base the ink
                // would grey the card rather than light it.
                if isActive, colorScheme != .light {
                    shape.fill(cardSelectionInk.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.strokeBorder(
                    workspacePulseBorderColor,
                    lineWidth: workspacePulseBorderLineWidth
                )
            }
            .overlay {
                // Outrun's active glow: a one-point ring outside the edge over the bloom.
                if isActive, let glow = themeStyle.cardGlow {
                    RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                        .strokeBorder(glow, lineWidth: 1)
                        .padding(-1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let request = activeSidebarFlash {
                    SidebarFlashOverlay(request: request)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var remoteWorkspaceSection: some View {
        if sidebarShowSSH, let remoteWorkspaceSidebarText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: themeStyle.cardLabel.apply(remoteWorkspaceSidebarText))
                        .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceMetadata, design: .monospaced)
                        .foregroundColor(themeStyle.cardTextSecondary ?? activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Text(verbatim: themeStyle.cardLabel.apply(remoteConnectionStatusText))
                        .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceAccessory, weight: .medium)
                        .foregroundColor(themeStyle.cardTextDim ?? activeSecondaryColor(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
            .safeHelp(remoteStateHelpText)
        }
    }

    private func copyTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyWorkspaceLink() {
        // Copy always targets this row, independently of sidebar multi-selection.
        let link = PanelLinkFormat.url(kind: .workspace, id: workspace.id)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        pasteboard.setString(link, forType: .URL)
        CopyConfirmationHUD.show(message: String(localized: "copyHUD.linkCopied", defaultValue: "Link Copied"))
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: sidebarShowMetadata,
            showLog: sidebarShowLog,
            showProgress: sidebarShowProgress,
            showBranchDirectory: sidebarShowBranchDirectory,
            showPullRequests: sidebarShowPullRequest,
            showPorts: sidebarShowPorts,
            hideAllDetails: sidebarHideAllDetails
        )
    }

    private var cardContents: some View {
        let mission = workspace.mission
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let detailVisibility = visibleAuxiliaryDetails
        // C11-104 v2 — branch+directory text-line precomputes retired.
        // The new chip render (precomputed upstream in
        // `VerticalTabsSidebar`, passed in via `worktreeChipRows`)
        // replaces them.
        let orderedPanelIds: [UUID]? = detailVisibility.showsPullRequests
            ? workspace.sidebarOrderedPanelIds()
            : nil
        let pullRequestRows: [PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // Spacing and the trailing accessory slot are both held back from
            // the title on every card, so anything reserved here is title the
            // operator never gets to read in a narrow sidebar. Keep the pin
            // inline (an empty container still claims spacing on both sides)
            // and keep the gaps tight.
            HStack(alignment: .center, spacing: 5) {
                if let icon = workspaceIconGlyph {
                    workspaceIconSlot(icon, titleSize: chromeTokens.sidebarWorkspaceTitle + 1.5)
                }
                workspaceTitleText
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 2)

                if workspace.isPinned {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: chromeTokens.sidebarWorkspaceAccessory + 1, weight: .semibold))
                        .foregroundColor(themeStyle.cardTextSecondary ?? .secondary.opacity(0.7))
                }

                // One fixed slot: the workspace number at rest, the close X
                // on hover. The slot keeps its width across the swap so the
                // title never shifts.
                ZStack(alignment: .trailing) {
                    if showsWorkspaceId {
                        // "WS" is a fixed technical label for the
                        // `workspace:N` ref (like the ref itself, not
                        // localized); it keeps the number from reading as a
                        // count or a ⌘-digit.
                        (
                            Text(verbatim: "WS ").foregroundColor(workspaceIdColor.opacity(0.6))
                            + Text(verbatim: "\(workspace.displayOrdinal)").foregroundColor(workspaceIdColor)
                        )
                            .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceDetail, weight: .medium, design: .monospaced)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .opacity(showCloseButton ? 0 : 1)
                            .accessibilityHidden(true)
                    }

                    Button(action: {
                        #if DEBUG
                        dlog("sidebar.close workspace=\(workspace.id.uuidString.prefix(5)) method=button")
                        #endif
                        workspaceManager.closeWorkspaceWithConfirmation(workspace)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: chromeTokens.sidebarWorkspaceAccessory, weight: .medium))
                            .foregroundColor(themeStyle.cardTextSecondary ?? activeSecondaryColor(0.7))
                    }
                    .buttonStyle(.plain)
                    .safeHelp(KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip))
                    .frame(width: 16, height: 16, alignment: .center)
                    .opacity(showCloseButton ? 1 : 0)
                    .allowsHitTesting(showCloseButton)
                }
                .frame(minWidth: 18, minHeight: 19, alignment: .trailing)
            }
            .modifier(WorkspaceCardHeaderOrnament(
                header: themeStyle.cardHeader,
                padding: themeStyle.cardPadding,
                borderWidth: workspacePulseBorderLineWidth,
                cornerRadius: cardCornerRadius,
                rule: themeStyle.cardRule ?? workspacePulseDividerColor.opacity(0.42),
                band: isActive
                    ? (themeStyle.cardBorderActive ?? themeStyle.cardAccent ?? BrandColors.goldSwiftUI).opacity(0.08)
                    : (themeStyle.cardText ?? .primary).opacity(0.025)
            ))

            if !sidebarHideAllDetails, !isMinimalMode, let mission {
                Text(verbatim: mission.summary)
                    .font(.system(size: chromeTokens.sidebarWorkspaceDetail))
                    .foregroundColor(themeStyle.cardTextSecondary ?? activeSecondaryColor())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .safeHelp(mission.tooltip)
                    .accessibilityLabel(String(localized: "sidebar.mission.label", defaultValue: "Mission"))
                    .accessibilityValue(mission.paragraph)
            }
            workspacePulseSummaries

            workspacePulseFooter

            // C11-25: preserve the focused surface's CPU/RSS reading without
            // the legacy focused-agent identity badge. Workspace Pulse owns
            // agent state and identity in this card.
            //
            // Rendered unconditionally: the readout owns its own null state
            // and its own observation of the sampler, so the card's structure
            // is identical whether or not a sample exists. See
            // `SidebarSurfaceMetricsReadout`.
            SidebarPanelMetricsReadout(
                surfaceId: workspace.focusedPanelId,
                valueColor: themeStyle.cardTextDim ?? activeSecondaryColor(0.55),
                // `activeSecondaryColor` collapses to `.secondary` on the
                // non-inverted path, so the null state's dimming has to be
                // applied explicitly rather than through its opacity arg.
                placeholderColor: (themeStyle.cardTextDim ?? activeSecondaryColor(0.55)).opacity(0.45),
                labelStyle: themeStyle.cardLabel
            )

            // C11-104 — worktree + branch chips. Renders when the master
            // toggle is on AND the resolver returned context for this
            // surface. The projection is precomputed upstream so the
            // body stays cheap.
            if !worktreeChipRows.isEmpty {
                WorktreeChipsRow(
                    rows: worktreeChipRows,
                    foreground: themeStyle.cardTextSecondary ?? activeSecondaryColor(0.85),
                    secondary: themeStyle.cardTextSecondary ?? activeSecondaryColor(0.7),
                    labelStyle: themeStyle.cardLabel
                )
                .padding(.top, 1)
            }

            remoteWorkspaceSection

            if detailVisibility.showsMetadata {
                let metadataBlocks = workspace.sidebarMetadataBlocksInDisplayOrder()
                // TEL-2/TEL-4: the status section owns the decay-clock observation
                // and renders either the explicit status rows (with age decay) or,
                // once they expire, the single derived-activity takeover pill.
                SidebarStatusSection(
                    workspace: workspace,
                    isActive: usesInvertedActiveForeground,
                    onFocus: { updateSelection() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                if !metadataBlocks.isEmpty {
                    SidebarMetadataMarkdownBlocks(
                        blocks: metadataBlocks,
                        isActive: usesInvertedActiveForeground,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Latest log entry
            if detailVisibility.showsLog, let latestLog = workspace.logEntries.last {
                HStack(spacing: 4) {
                    Image(systemName: logLevelIcon(latestLog.level))
                        .font(.system(size: chromeTokens.sidebarWorkspaceLogIcon))
                        .foregroundColor(logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(.system(size: chromeTokens.sidebarWorkspaceMetadata))
                        .foregroundColor(themeStyle.cardTextSecondary ?? activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Progress bar. TEL-2: rendered by a dedicated child subview so
            // the age-decay clock is observed there — never in TabItemView's
            // Equatable body — letting the bar dim/gray as it goes stale
            // without invalidating the whole row on every clock tick.
            if detailVisibility.showsProgress, let progress = workspace.progress {
                SidebarProgressIndicator(
                    progress: progress,
                    trackColor: themeStyle.cardProgressTrack ?? activeProgressTrackColor,
                    fillColor: activeProgressFillColor,
                    labelColor: themeStyle.cardTextDim ?? activeSecondaryColor(0.6),
                    labelFontSize: chromeTokens.sidebarWorkspaceProgressLabel,
                    fillGradient: themeStyle.cardProgress,
                    barHeight: themeStyle.progressHeightPt,
                    barRadius: themeStyle.progressRadius,
                    labelStyle: themeStyle.cardLabel
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // C11-104 v2 — Branch + Directory row retired. The
            // worktree+branch chip row above replaces it. The toggle
            // key `sidebarShowBranchDirectory` is preserved (existing
            // user prefs survive) and now gates the chip row.

            // Pull request rows
            if detailVisibility.showsPullRequests, !pullRequestRows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(pullRequestRows) { pullRequest in
                        Button(action: {
                            openPullRequestLink(pullRequest.url)
                        }) {
                            HStack(spacing: 4) {
                                PullRequestStatusIcon(
                                    status: pullRequest.status,
                                    color: pullRequestForegroundColor
                                )
                                Text("\(pullRequest.label) #\(pullRequest.number)")
                                    .underline()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(pullRequestStatusLabel(pullRequest.status, checks: pullRequest.checks))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: chromeTokens.sidebarWorkspaceMetadata, weight: .semibold))
                            .foregroundColor(pullRequestForegroundColor)
                        }
                        .buttonStyle(.plain)
                        .safeHelp(String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(pullRequest.label) #\(pullRequest.number)"))
                    }
                }
            }

            // Ports row
            if detailVisibility.showsPorts, !workspace.listeningPorts.isEmpty {
                Text(verbatim: workspace.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
                    .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceMetadata, design: .monospaced)
                    .foregroundColor(themeStyle.cardTextSecondary ?? activeSecondaryColor(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Holds the rail on the card's bottom edge when a Tiles row
            // stretches this card to its taller neighbour; zero otherwise.
            Spacer(minLength: 0)
            workspacePulseCompositionRail()
        }
        .animation(.easeInOut(duration: 0.2), value: workspace.logEntries.count)
        .animation(.easeInOut(duration: 0.2), value: workspace.progress != nil)
        .animation(.easeInOut(duration: 0.2), value: workspace.metadataBlocks.count)
        .padding(.horizontal, themeStyle.cardPadding.horizontal)
        // A console header takes half the top padding into its band, so the
        // card keeps its height (WorkspaceCardHeaderOrnament).
        .padding(.top, themeStyle.cardHeader == .console ? themeStyle.cardPadding.top / 2 : themeStyle.cardPadding.top)
        .padding(.bottom, themeStyle.cardPadding.bottom)
    }

    var body: some View {
#if DEBUG
        let _ = sidebarRowProbeEnabled ? dlog("sidebar.row.body workspace=\(workspace.id.uuidString)") : ()
#endif
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        densityContents
        .padding(.trailing, beaconTrailingReserve)
        .frame(maxHeight: tiled ? .infinity : nil, alignment: .top)
        .background(workspacePulseCardBackground())
        .overlay { workspaceBeaconOverlay() }
        .overlay {
            if themeStyle.hoverBrackets, isHovering {
                SidebarHoverBrackets(color: (themeStyle.cardBorderActive ?? themeStyle.cardText ?? .primary).opacity(0.78))
            }
        }
        .onChange(of: workspace.sidebarFlashRequest) { _, request in
            guard let request, request.remainingDuration > 0 else { return }
            activeSidebarFlash = request
            DispatchQueue.main.asyncAfter(deadline: .now() + request.remainingDuration) {
                guard activeSidebarFlash?.id == request.id else { return }
                activeSidebarFlash = nil
            }
        }
        .onDisappear { activeSidebarFlash = nil }
        .padding(.horizontal, 6)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        rowHeight = max(proxy.size.height, 1)
                    }
                    .onChange(of: proxy.size.height) { newHeight in
                        rowHeight = max(newHeight, 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .opacity((isBeingDragged ? 0.6 : 1) * workspacePulseCardOpacity)
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                dlog("sidebar.close workspace=\(workspace.id.uuidString.prefix(5)) method=middleClick")
                #endif
                workspaceManager.closeWorkspaceWithConfirmation(workspace)
            }
        }
        .overlay(alignment: .top) {
            if showsCenteredTopDropIndicator {
                Rectangle()
                    .fill(cmuxAccentColor())
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .offset(y: index == 0 ? 0 : -(rowSpacing / 2))
            }
        }
        .overlay(alignment: .bottom) {
            if dropIndicator?.workspaceId == workspace.id && dropIndicator?.edge == .bottom {
                Rectangle().fill(cmuxAccentColor()).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .onDrag {
            #if DEBUG
            dlog("sidebar.onDrag tab=\(workspace.id.uuidString.prefix(5))")
            #endif
            draggedGroupId = nil
            draggedWorkspaceId = workspace.id
            dropIndicator = nil
            WorkspaceHoverCardController.shared.dismiss()
            SidebarForeignHover.beginDrag(sourceWindow: AppDelegate.shared?.mainWindow(for: workspaceManager))
            let draggedId = workspace.id
            DragTearOffWatcher.shared.begin("workspace") { point in
                // Released outside every window: no drop handler ran to end
                // the source sidebar's drag, so end it here.
                SidebarDragLifecycleNotification.postClearRequest(reason: "released_outside")
                _ = AppDelegate.shared?.tearOffWorkspaceToNewWindow(workspaceId: draggedId, at: point)
            }
            return SidebarWorkspaceDragPayload.provider(for: workspace.id)
        }
        .internalOnlyPanelDrag()
        .onDrop(of: SidebarWorkspaceDragPayload.dropContentTypes + SidebarGroupDragPayload.dropContentTypes,
                delegate: SidebarWorkspaceDropDelegate(
            targetWorkspaceId: workspace.id,
            workspaceManager: workspaceManager,
            draggedWorkspaceId: $draggedWorkspaceId,
            draggedGroupId: $draggedGroupId,
            selectedWorkspaceIds: $selectedWorkspaceIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: rowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: $dropIndicator
        ))
        .onTapGesture {
            // CMUX-10: clicking the workspace row dismisses any persistent
            // flash inside it (across all panels). The operator clicked,
            // they're acknowledging — give them the surface clean.
            workspace.cancelAllPersistentFlashes()
            WorkspaceHoverCardController.shared.dismiss()
            updateSelection()
        }
        .onHover(perform: handleRowHover)
        .onDisappear(perform: dismissRowHoverCard)
        .onChange(of: density) { _, newDensity in
            if newDensity != .compact { dismissRowHoverCard() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.workspace.\(workspace.id.uuidString)")
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(workspace.mission?.paragraph ?? ""))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityActions {
            if density == .compact {
                Button(String(localized: "sidebar.summaryCard.toggle",
                              defaultValue: "Show or hide workspace summary")) {
                    toggleSummaryCard()
                }
            }
        }
        .accessibilityAction(named: Text(moveUpActionText)) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text(moveDownActionText)) {
            moveBy(1)
        }
        .contextMenu { workspaceContextMenu }
        .popover(item: $iconPickerRequest, arrowEdge: .trailing) { request in
            SidebarIconPicker(
                title: String(localized: "sidebarIcon.picker.workspaceTitle", defaultValue: "Workspace Icon"),
                current: workspaceIconGlyph,
                focusTarget: request.focusTarget,
                onSubmit: { try applyWorkspaceIcon($0, targetIds: request.targetIds) },
                onDismiss: { iconPickerRequest = nil }
            )
        }
    }

    /// The workspace's `icon` metadata (`set-workspace-icon`), as drawn.
    private var workspaceIconGlyph: SidebarIconGlyph? {
        SidebarIconGlyph.forWorkspaceIcon(workspace.metadata[WorkspaceMetadataKey.icon])
    }

    /// The icon before the title in a slot of fixed width that adds no height:
    /// the glyph is an overlay on a 1 pt strip, so an emoji and a symbol take
    /// the same box and setting one never moves the title or the rows below,
    /// at any chrome scale.
    private func workspaceIconSlot(_ glyph: SidebarIconGlyph, titleSize: CGFloat) -> some View {
        let side = ceil(titleSize * 1.2)
        return Color.clear
            .frame(width: side, height: 1)
            .overlay {
                SidebarIconGlyphView(glyph: glyph, size: titleSize)
                    .foregroundColor(themeStyle.cardText ?? .primary)
                    .frame(width: side, height: side)
            }
            .accessibilityHidden(true)
    }

    /// Writes the same `icon` value `set-workspace-icon` writes, to every target.
    /// Throws, before writing anything, when the store would refuse the value.
    private func applyWorkspaceIcon(_ glyph: SidebarIconGlyph?, targetIds: [UUID]) throws {
        let value = try glyph?.checkedWorkspaceMetadataValue() ?? ""
        for targetId in targetIds {
            workspaceManager.workspaces.first(where: { $0.id == targetId })?
                .setOperatorMetadata([WorkspaceMetadataKey.icon: value])
        }
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            workspaceManager.workspaces.first(where: { $0.id == workspaceId })
        }
    }

    @ViewBuilder
    private var workspaceContextMenu: some View {
        let targetIds = contextTargetIds()
        let isMulti = targetIds.count > 1
        let tabColorPalette = WorkspaceColorSettings.palette()
        let shouldPin = !workspace.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        // C11-563 layout (Atin, 2026-11-01): identity and lifetime, then
        // appearance and grouping, then placement, then state. Reordering
        // stays with drag, the palette, shortcuts and the CLI; an empty
        // rename restores the automatic name.
        Button(pinLabel) {
            for id in targetIds {
                if let workspace = workspaceManager.workspaces.first(where: { $0.id == id }) {
                    workspaceManager.setPinned(workspace, pinned: shouldPin)
                }
            }
            syncSelectionAfterMutation()
        }

        if let key = renameWorkspaceShortcut.keyEquivalent {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
            .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
        } else {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
        }

        // C11-238: root view/edit for minimal mode, where the title-bar info
        // button is hidden. Reads only the already-observed `tab`.
        if !isMulti {
            Menu(String(localized: "contextMenu.workspaceRoot", defaultValue: "Workspace Root")) {
                Button(workspace.rootDirectory.map { WorkspaceRootActions.menuDisplayPath($0) }
                    ?? String(localized: "contextMenu.workspaceRoot.none", defaultValue: "No Root Set")) {}
                    .disabled(true)
                Divider()
                Button(String(localized: "contextMenu.workspaceRoot.change", defaultValue: "Change Root…")) {
                    WorkspaceRootActions.chooseRoot(for: workspace)
                }
                Button(String(localized: "workspaceRoot.useFocused", defaultValue: "Use Focused Directory")) {
                    WorkspaceRootActions.useFocusedDirectory(for: workspace)
                }
                .disabled(!WorkspaceRootActions.mayUseFocusedDirectory(for: workspace))
                Button(String(localized: "contextMenu.workspaceRoot.clear", defaultValue: "Clear Root")) {
                    WorkspaceRootActions.clearRoot(for: workspace)
                }
                .disabled(workspace.rootDirectory == nil)
            }
        }

        if let key = closeWorkspaceShortcut.keyEquivalent {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .disabled(targetIds.isEmpty)
        }

        Divider()

        Menu(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {
            if workspace.customColor != nil {
                Button {
                    applyWorkspaceColor(nil, targetIds: targetIds)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }

            Button {
                promptCustomColor(targetIds: targetIds)
            } label: {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }

            if !tabColorPalette.isEmpty {
                Divider()
            }

            ForEach(tabColorPalette, id: \.id) { entry in
                Button {
                    applyWorkspaceColor(entry.hex, targetIds: targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: coloredCircleImage(color: workspaceColorSwatchColor(for: entry.hex)))
                    }
                }
            }
        }
        .help(String(
            localized: "contextMenu.workspaceColor.tooltip",
            defaultValue: "Per-workspace accent. Chrome theme (Light/Dark) lives in Settings → Theme."
        ))

        Button(String(localized: "contextMenu.setWorkspaceIcon", defaultValue: "Set Icon…")) {
            iconPickerRequest = SidebarIconPickerRequest(
                targetIds: targetIds, focusTarget: WorkspaceGroupEditorFocusTarget.capture())
        }

        Menu(String(localized: "workspaceGroup.moveToGroup", defaultValue: "Move to Group")) {
            Button(String(localized: "workspaceGroup.ungrouped", defaultValue: "Ungrouped")) {
                for id in contextTargetIds() {
                    try? workspaceManager.moveWorkspaceToGroup(workspaceId: id, groupId: nil)
                }
            }
            ForEach(availableGroups) { group in
                Button(group.name) {
                    for id in contextTargetIds() {
                        try? workspaceManager.moveWorkspaceToGroup(workspaceId: id, groupId: group.id)
                    }
                }
            }
        }

        Divider()

        let referenceWindowId = AppDelegate.shared?.windowId(for: workspaceManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveWorkspacesToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveWorkspaces(targetIds, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        if !remoteContextMenuWorkspaceIds.isEmpty {
            Button(reconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.reconnectRemoteConnection()
                }
            }
            .disabled(allRemoteContextMenuTargetsConnecting)

            Button(disconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.disconnectRemoteConnection(clearConfiguration: false)
                }
            }
            .disabled(allRemoteContextMenuTargetsDisconnected)
        }

        if let copyableSidebarSSHError {
            Button(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
                copyTextToPasteboard(copyableSidebarSSHError)
            }
        }

        Divider()

        // C11-25: hibernate / resume the right-clicked workspace. Mirrors
        // the App menu bar's Workspace submenu (`c11App.swift:1394`) so
        // the action is reachable from the sidebar where operators expect
        // it (DoD #6 placement). Browser surfaces snapshot + terminate
        // their WebContent processes and render a placeholder until
        // resume; terminals stay on the auto-throttle path.
        if workspace.isHibernated {
            Button(String(localized: "contextMenu.resumeWorkspace", defaultValue: "Resume Workspace")) {
                workspace.resume()
            }
        } else {
            Button(String(localized: "contextMenu.hibernateWorkspace", defaultValue: "Hibernate Workspace")) {
                workspace.hibernate()
            }
            .help(String(
                localized: "contextMenu.hibernateWorkspaceTooltip",
                defaultValue: "Suspends browser panels in this workspace. Terminals stay on auto-throttle (already low-CPU when the workspace isn't focused)."
            ))
        }

        Button(markReadLabel) {
            markTabsRead(targetIds)
        }
        .disabled(!hasUnreadNotifications(in: targetIds))

        Button(markUnreadLabel) {
            markTabsUnread(targetIds)
        }
        .disabled(!hasReadNotifications(in: targetIds))

        Button(String(localized: "contextMenu.copyLink", defaultValue: "Copy Link")) {
            copyWorkspaceLink()
        }
    }

    private var resolvedCustomWorkspaceColor: Color? {
        guard let hex = workspace.customColor else { return nil }
        return WorkspaceColorSettings.displayColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeWorkspaceIndicatorStyle == .leftRail
        )
    }

    private func workspaceColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeWorkspaceIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    /// A workspace-edge indicator only comes from a workspace drag, from this
    /// window or another one (C11H-207), so the indicator alone decides.
    private var showsCenteredTopDropIndicator: Bool {
        dropIndicator?.workspaceId == workspace.id && dropIndicator?.edge == .top
    }

    private var accessibilityTitle: String {
        String(localized: "accessibility.workspacePosition", defaultValue: "\(workspace.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)")
    }

    private func moveBy(_ delta: Int) {
        // Re-resolves displayed neighbours from current model state, not a stale
        // captured index (C11H-342: at the root a step passes a group too).
        guard workspaceManager.stepWorkspaceInSidebar(workspace.id, by: delta) else { return }
        selectedWorkspaceIds = [workspace.id]
        lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
        SocketCommandContext.withContext(nil) { workspaceManager.selectWorkspace(workspace, cause: "sidebar") }
        setSelectionToTabs()
    }

    private func updateSelection() {
        #if DEBUG
        let mods = NSEvent.modifierFlags
        var modStr = ""
        if mods.contains(.command) { modStr += "cmd " }
        if mods.contains(.shift) { modStr += "shift " }
        if mods.contains(.option) { modStr += "opt " }
        if mods.contains(.control) { modStr += "ctrl " }
        dlog("sidebar.select workspace=\(workspace.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        if isShift, let rangeIds = WorkspaceGroupSidebarProjection.selectionRange(
            anchor: workspaceManager.selectedWorkspaceId, target: workspace.id, visibleWorkspaceIds: visibleWorkspaceIds
        ) {
            if isCommand {
                selectedWorkspaceIds.formUnion(rangeIds)
            } else {
                selectedWorkspaceIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedWorkspaceIds.contains(workspace.id) {
                selectedWorkspaceIds.remove(workspace.id)
            } else {
                selectedWorkspaceIds.insert(workspace.id)
            }
        } else {
            selectedWorkspaceIds = [workspace.id]
        }

        lastSidebarSelectionIndex = index
        workspaceManager.selectWorkspaceFromSidebarCard(workspace, isCommand: isCommand, isShift: isShift)
        setSelectionToTabs()
    }

    private func contextTargetIds() -> [UUID] {
        let baseIds: Set<UUID> = selectedWorkspaceIds.contains(workspace.id) ? selectedWorkspaceIds : [workspace.id]
        return workspaceManager.workspaces.compactMap { baseIds.contains($0.id) ? $0.id : nil }
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        workspaceManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forWorkspaceId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forWorkspaceId: id)
        }
    }

    private func hasUnreadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.workspaceId) && !$0.isRead }
    }

    private func hasReadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.workspaceId) && $0.isRead }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(workspaceManager.workspaces.map { $0.id })
        selectedWorkspaceIds = selectedWorkspaceIds.filter { existingIds.contains($0) }
        if selectedWorkspaceIds.isEmpty, let selectedId = workspaceManager.selectedWorkspaceId {
            selectedWorkspaceIds = [selectedId]
        }
        if let selectedId = workspaceManager.selectedWorkspaceId {
            lastSidebarSelectionIndex = workspaceManager.workspaces.firstIndex { $0.id == selectedId }
        }
    }

    private var remoteStateHelpText: String {
        let target = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workspace.remoteConnectionState {
        case .connected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connected",
                    defaultValue: "SSH connected to %@"
                ),
                locale: .current,
                target
            )
        case .connecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connecting",
                    defaultValue: "SSH connecting to %@"
                ),
                locale: .current,
                target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "SSH error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return String(
                format: String(
                    localized: "sidebar.remote.help.error",
                    defaultValue: "SSH error for %@"
                ),
                locale: .current,
                target
            )
        case .disconnected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.disconnected",
                    defaultValue: "SSH disconnected from %@"
                ),
                locale: .current,
                target
            )
        }
    }
    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = workspaceManager.workspaces.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }

        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }

        selectedWorkspaceIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = workspaceManager.workspaces.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }

        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }

        if orderedWorkspaceIds.count > 1 {
            for workspaceId in orderedWorkspaceIds.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: false)
            }
            if let finalWorkspaceId = orderedWorkspaceIds.last {
                _ = app.moveWorkspaceToWindow(workspaceId: finalWorkspaceId, windowId: newWindowId, focus: true)
            }
        }

        selectedWorkspaceIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    // latestNotificationText is now passed as a parameter from the parent view
    // to avoid subscribing to notificationStore changes in every TabItemView.

    // C11-104 v2 — retired:
    //   branchDirectoryRow, gitBranchSummaryText, gitBranchSummaryLines,
    //   VerticalBranchDirectoryLine, verticalBranchDirectoryLines,
    //   directorySummaryText
    // The chip render in `WorktreeChipsRow` (precomputed upstream in
    // `VerticalTabsSidebar`) replaces these.

    private struct PullRequestDisplay: Identifiable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let checks: SidebarPullRequestChecksStatus?
    }

    private func pullRequestDisplays(orderedPanelIds: [UUID]) -> [PullRequestDisplay] {
        workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                checks: pullRequest.checks
            )
        }
    }

    private var pullRequestForegroundColor: Color {
        usesInvertedActiveForeground ? BrandColors.whiteSwiftUI.opacity(0.85) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInCmuxBrowser {
            if workspaceManager.openBrowser(
                inWorkspace: workspace.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func pullRequestStatusLabel(
        _ status: SidebarPullRequestStatus,
        checks _: SidebarPullRequestChecksStatus?
    ) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.5))
            case .progress:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.8))
            case .success:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            case .warning:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            case .error:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private struct PullRequestStatusIcon: View {
        let status: SidebarPullRequestStatus
        let color: Color
        private static let frameSize: CGFloat = 12

        var body: some View {
            switch status {
            case .open:
                PullRequestOpenIcon(color: color)
            case .merged:
                PullRequestMergedIcon(color: color)
            case .closed:
                Image(systemName: "xmark.circle")
                    .font(.system(size: 7, weight: .regular))
                    .foregroundColor(color)
                    .frame(width: Self.frameSize, height: Self.frameSize)
            }
        }
    }

    private struct PullRequestOpenIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3.0, y: 4.8))
                    path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                    path.move(to: CGPoint(x: 4.8, y: 3.0))
                    path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                    path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.0, y: 9.2))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 11.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private struct PullRequestMergedIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4.6, y: 4.6))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                    path.addLine(to: CGPoint(x: 9.2, y: 7.0))

                    path.move(to: CGPoint(x: 4.6, y: 9.4))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 7.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private func applyWorkspaceColor(_ hex: String?, targetIds: [UUID]) {
        for targetId in targetIds {
            workspaceManager.setWorkspaceColor(workspaceId: targetId, color: hex)
        }
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let seed = workspace.customColor ?? WorkspaceColorSettings.customColors().first ?? ""

        // Anchor on the first target workspace's focused panel. Plan §4.12.
        // Falls back to NSAlert when no anchor is resolvable (rare: targets
        // include only workspaces with no focused panel yet).
        //
        // Synthesis-standard §1.2: prefer the currently selected workspace
        // when it is in the target set — presenting the overlay on a non-
        // visible background workspace produces an invisible prompt. When
        // the anchor isn't the selected workspace, fall back to NSAlert so
        // the user actually sees the dialog.
        let anchorWorkspace: Workspace? = targetIds.lazy.compactMap { id in
            workspaceManager.workspaces.first(where: { $0.id == id })
        }.first(where: { $0.focusedPanelId != nil })
        let anchorIsSelected = anchorWorkspace.map { $0.id == workspaceManager.selectedWorkspaceId } ?? false

        if AreaInteractionFeatureFlag.isEnabled,
           anchorIsSelected,
           let workspace = anchorWorkspace,
           let panelId = workspace.focusedPanelId {
            Task { @MainActor in
                let value = await workspace.presentTextInput(
                    panelId: panelId,
                    title: String(
                        localized: "alert.customColor.title",
                        defaultValue: "Custom Workspace Color"
                    ),
                    message: String(
                        localized: "alert.customColor.message",
                        defaultValue: "Enter a hex color in the format #RRGGBB."
                    ),
                    defaultValue: seed,
                    placeholder: "#1565C0",
                    confirmLabel: String(
                        localized: "alert.customColor.apply",
                        defaultValue: "Apply"
                    ),
                    cancelLabel: String(
                        localized: "alert.customColor.cancel",
                        defaultValue: "Cancel"
                    ),
                    validate: { candidate in
                        // Mirror showInvalidColorAlert's two-message distinction:
                        // empty vs invalid hex, both surfaced inline instead of
                        // triggering a second alert (plan §4.12).
                        if WorkspaceColorSettings.normalizedHex(candidate) != nil {
                            return nil
                        }
                        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            return String(
                                localized: "alert.invalidColor.emptyMessage",
                                defaultValue: "Enter a hex color in the format #RRGGBB."
                            )
                        }
                        return String(
                            localized: "alert.invalidColor.invalidMessage",
                            defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB."
                        )
                    }
                )
                guard let value else { return }
                // Acceptance-time revalidation: the candidate passed validation at
                // submit time but state may have drifted; addCustomColor re-validates
                // and returns nil on failure.
                guard let normalized = WorkspaceColorSettings.addCustomColor(value) else { return }
                applyWorkspaceColor(normalized, targetIds: targetIds)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyWorkspaceColor(normalized, targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptRename() {
        // C11-563: the field holds the custom name (empty when none) and its
        // placeholder is the automatic name; saving it empty clears the
        // custom name, which replaces "Remove Custom Workspace Name".
        let form = WorkspaceRenameForm(workspace: workspace)

        // Anchor the overlay on the workspace's focused panel so the card visually
        // sits over the pane the user is renaming "from". If the workspace has
        // no focused panel resolvable right now (edge case — empty workspace,
        // detached state), fall back to the legacy NSAlert so the rename still
        // works. Feature flag also routes to NSAlert when explicitly disabled.
        //
        // Synthesis-standard §1.2 / synthesis-critical side-effect: renaming
        // via the sidebar context menu can target a non-selected workspace.
        // Presenting the overlay on a background workspace produces an
        // invisible prompt, so when `tab` isn't the selected workspace, fall
        // back to the NSAlert path.
        let isSelectedWorkspace = workspaceManager.selectedWorkspaceId == workspace.id
        if AreaInteractionFeatureFlag.isEnabled, isSelectedWorkspace, let panelId = self.workspace.focusedPanelId {
            let workspaceId = self.workspace.id
            let manager = workspaceManager
            let workspace = self.workspace
            Task { @MainActor in
                let value = await workspace.presentTextInput(
                    panelId: panelId,
                    title: String(
                        localized: "alert.renameWorkspace.title",
                        defaultValue: "Rename Workspace"
                    ),
                    message: String(
                        localized: "alert.renameWorkspace.message",
                        defaultValue: "Enter a custom name for this workspace."
                    ) + " " + WorkspaceRenameForm.message,
                    defaultValue: form.initialText,
                    placeholder: form.placeholder,
                    confirmLabel: String(
                        localized: "alert.renameWorkspace.rename",
                        defaultValue: "Rename"
                    ),
                    cancelLabel: String(
                        localized: "alert.renameWorkspace.cancel",
                        defaultValue: "Cancel"
                    ),
                    validate: { _ in nil }
                )
                guard let value else { return }
                // Acceptance-time revalidation: the workspace may have been torn
                // down between present and submit.
                guard manager.workspaces.contains(where: { $0.id == workspaceId }) else { return }
                manager.setCustomTitle(workspaceId: workspaceId, title: value)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Any text works. Workspace names show in the sidebar.")
            + " " + WorkspaceRenameForm.message
        let input = NSTextField(string: form.initialText)
        input.placeholderString = form.placeholder
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        workspaceManager.setCustomTitle(workspaceId: workspace.id, title: input.stringValue)
    }
}

private struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let onFocus: () -> Void

    @Environment(\.chromeScaleTokens) private var chromeTokens
    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(entry: entry, isActive: isActive, onFocus: onFocus)
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: chromeTokens.sidebarWorkspaceMetadata, weight: .semibold))
                .foregroundColor(isActive ? activeSecondaryTextColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var activeSecondaryTextColor: Color {
        Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65))
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}

private struct SidebarMetadataEntryRow: View {
    let entry: SidebarStatusEntry
    let isActive: Bool
    let onFocus: () -> Void

    @Environment(\.chromeScaleTokens) private var chromeTokens
    // TEL-2: observe the coarse decay clock here in the CHILD subview (never
    // in TabItemView's Equatable body) so the pill can age visually even when
    // the parent row does not re-evaluate. The two @AppStorage thresholds are
    // declared for reactive redraw when the operator retunes them in Settings;
    // resolution goes through the static (which also honors env overrides).
    @ObservedObject private var decayClock = SidebarDecayClock.shared
    @AppStorage(SidebarStalenessSettings.staleThresholdKey)
    private var staleThresholdRaw = SidebarStalenessSettings.defaultStaleSeconds
    @AppStorage(SidebarStalenessSettings.expiryThresholdKey)
    private var expiryThresholdRaw = SidebarStalenessSettings.defaultExpirySeconds

    private var ageSeconds: Double {
        decayClock.now.timeIntervalSince(entry.timestamp)
    }

    private var decayStage: SidebarDecayStage {
        // C11-162 (m5): touch the two @AppStorage thresholds so this view
        // re-renders when the operator retunes them live. The values are
        // resolved through the SidebarStalenessSettings statics (env-aware +
        // ordering-clamped), so these bindings exist only for invalidation —
        // do not remove them as "unused".
        _ = (staleThresholdRaw, expiryThresholdRaw)
        return SidebarStalenessSettings.stage(
            ageSeconds: ageSeconds,
            staleSeconds: SidebarStalenessSettings.staleSeconds(),
            expirySeconds: SidebarStalenessSettings.expirySeconds()
        )
    }

    /// Small trailing relative-age hint shown once a pill goes stale.
    private var ageIndicatorText: String? {
        guard decayStage != .fresh else { return nil }
        let secs = Int(ageSeconds)
        if secs >= 3600 {
            let hours = secs / 3600
            return String(localized: "sidebar.decay.ageHours", defaultValue: "\(hours)h")
        }
        let minutes = max(1, secs / 60)
        return String(localized: "sidebar.decay.ageMinutes", defaultValue: "\(minutes)m")
    }

    private var decayOpacity: Double {
        switch decayStage {
        case .fresh: return entry.staleFromRestart ? 0.55 : 1.0
        case .stale: return 0.6
        case .expired: return 0.5
        }
    }

    private var decayIsItalic: Bool {
        entry.staleFromRestart || decayStage != .fresh
    }

    var body: some View {
        Group {
            if let url = entry.url {
                Button {
                    onFocus()
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = iconView {
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            metadataText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            if let ageIndicatorText {
                Text(ageIndicatorText)
                    .font(.system(size: chromeTokens.sidebarWorkspaceProgressLabel, weight: .medium))
                    .foregroundColor(foregroundColor.opacity(0.7))
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .font(decayIsItalic
            ? .system(size: chromeTokens.sidebarWorkspaceMetadata, weight: .regular).italic()
            : .system(size: chromeTokens.sidebarWorkspaceMetadata, weight: .regular))
        .opacity(decayOpacity)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        // TEL-2: an expired pill grays out entirely regardless of its
        // author-supplied color, signalling the writer has gone silent.
        if decayStage == .expired {
            return BrandColors.dimSwiftUI
        }
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.95))
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? .white.opacity(0.8) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: chromeTokens.sidebarWorkspaceAccessory)))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: chromeTokens.sidebarWorkspaceLogIcon, weight: .semibold)))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(Image(systemName: symbolName).font(.system(size: chromeTokens.sidebarWorkspaceLogIcon, weight: .medium)))
    }

    @ViewBuilder
    private func metadataText(underlined: Bool) -> some View {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? entry.key : trimmed
        if entry.format == .markdown,
           let attributed = try? AttributedString(
                markdown: display,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
                // C11H-365 (N4): any agent, including one on a linked machine,
                // can write this text; its links follow the mail drawer's rule.
                .environment(\.openURL, OpenURLAction { SidebarStatusLinkRule.open($0) })
        } else {
            Text(display)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }
}

/// C11H-365 (N4): a markdown status pill's link follows the mail drawer's
/// rule (`MailboxDrawerLinkOpener`): a c11 panel link opens in c11, an http(s)
/// link opens in the default browser, and any other scheme opens nothing. Any
/// agent can write a pill, including one on a linked machine through the relay.
@MainActor
enum SidebarStatusLinkRule {
    enum Decision: Equatable { case panelLink, web, refused }

    nonisolated static func decision(for url: URL) -> Decision {
        if PanelLinkTarget.usesScheme(url) { return .panelLink }
        return MailboxBodyLinks.linkURL(url.absoluteString) == nil ? .refused : .web
    }

    static func open(_ url: URL) -> OpenURLAction.Result {
        let href = url.absoluteString
        switch decision(for: url) {
        case .panelLink:
            guard let target = PanelLinkTarget(href) else {
                PanelLinkActivation.log(target: href, origin: "sidebar_status", activation: "native_click", result: "invalid_target")
                return .handled
            }
            let opened = AppDelegate.shared?.openPanelLink(target) == true
            PanelLinkActivation.log(target: href, origin: "sidebar_status", activation: "native_click",
                                    result: opened ? "opened" : "unavailable")
            return .handled
        case .web:
            NSWorkspace.shared.open(url)
            return .handled
        case .refused:
            PanelLinkActivation.log(target: url.scheme.map { $0 + ":" } ?? "", origin: "sidebar_status",
                                    activation: "native_click", result: "refused_scheme")
            return .discarded
        }
    }
}

/// TEL-2: the workspace progress bar, extracted into its own child subview so
/// it can observe the coarse `SidebarDecayClock` (never done in TabItemView's
/// Equatable body). As the progress write ages it dims; once expired the fill
/// grays to `BrandColors.dim`, signalling the reporter has gone silent.
private struct SidebarProgressIndicator: View {
    let progress: SidebarProgressState
    let trackColor: Color
    let fillColor: Color
    let labelColor: Color
    let labelFontSize: CGFloat
    /// Schema-2 overrides (C11H-145); nil keeps the 3pt gold capsule.
    var fillGradient: Gradient? = nil
    var barHeight: CGFloat? = nil
    var barRadius: CGFloat? = nil
    var labelStyle: ThemeTextStyle = .unset

    @ObservedObject private var decayClock = SidebarDecayClock.shared
    @AppStorage(SidebarStalenessSettings.staleThresholdKey)
    private var staleThresholdRaw = SidebarStalenessSettings.defaultStaleSeconds
    @AppStorage(SidebarStalenessSettings.expiryThresholdKey)
    private var expiryThresholdRaw = SidebarStalenessSettings.defaultExpirySeconds

    private var ageSeconds: Double {
        decayClock.now.timeIntervalSince(progress.timestamp)
    }

    private var decayStage: SidebarDecayStage {
        // C11-162 (m5): touch the two @AppStorage thresholds so this view
        // re-renders when the operator retunes them live. The values are
        // resolved through the SidebarStalenessSettings statics (env-aware +
        // ordering-clamped), so these bindings exist only for invalidation —
        // do not remove them as "unused".
        _ = (staleThresholdRaw, expiryThresholdRaw)
        return SidebarStalenessSettings.stage(
            ageSeconds: ageSeconds,
            staleSeconds: SidebarStalenessSettings.staleSeconds(),
            expirySeconds: SidebarStalenessSettings.expirySeconds()
        )
    }

    private var decayOpacity: Double {
        switch decayStage {
        case .fresh: return 1.0
        case .stale: return 0.6
        case .expired: return 0.4
        }
    }

    private var effectiveFillColor: Color {
        decayStage == .expired ? BrandColors.dimSwiftUI : fillColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                if barRadius == nil {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(trackColor)
                        fillBar(Capsule(), width: max(0, geo.size.width * CGFloat(progress.value)))
                    }
                } else {
                    let shape = WorkspaceCardBarShape(radius: barRadius)
                    ZStack(alignment: .leading) {
                        shape
                            .fill(trackColor)
                        fillBar(shape, width: max(0, geo.size.width * CGFloat(progress.value)))
                    }
                }
            }
            .frame(height: barHeight ?? 3)

            if let label = progress.label {
                Text(verbatim: labelStyle.apply(label))
                    .chromeStyle(labelStyle, size: labelFontSize)
                    .foregroundColor(labelColor)
                    .lineLimit(1)
            }
        }
        .opacity(decayOpacity)
    }

    /// The filled part: the theme's gradient while fresh, else the plain fill.
    @ViewBuilder
    private func fillBar<S: Shape>(_ shape: S, width: CGFloat) -> some View {
        if let fillGradient, decayStage != .expired {
            shape
                .fill(LinearGradient(gradient: fillGradient, startPoint: .leading, endPoint: .trailing))
                .frame(width: width)
        } else {
            shape
                .fill(effectiveFillColor)
                .frame(width: width)
        }
    }
}

/// Agent-authored status region. Workspace Pulse now owns derived activity, so
/// this section renders fresh/stale explicit status rows only. When explicit
/// status expires and the projector hands off to derived truth, this row goes
/// quiet instead of duplicating the pulse with a second Idle/Working pill.
private struct SidebarStatusSection: View {
    @ObservedObject var workspace: Workspace
    let isActive: Bool
    let onFocus: () -> Void

    @ObservedObject private var decayClock = SidebarDecayClock.shared
    // These invalidation-only bindings force a re-render when the operator
    // retunes the thresholds live; resolution itself goes through the
    // `SidebarStalenessSettings` statics (which also honor the env overrides).
    // Do not remove as "unused" — see also SidebarMetadataEntryRow.
    @AppStorage(SidebarStalenessSettings.staleThresholdKey)
    private var staleThresholdRaw = SidebarStalenessSettings.defaultStaleSeconds
    @AppStorage(SidebarStalenessSettings.expiryThresholdKey)
    private var expiryThresholdRaw = SidebarStalenessSettings.defaultExpirySeconds

    private var entries: [SidebarStatusEntry] { workspace.sidebarStatusEntriesInDisplayOrder() }

    /// The representative explicit status (most recently written) — the one the
    /// derived takeover is decided against. If it has expired, every other
    /// status entry is at least as old, so the whole block yields to derived.
    private var takeoverActive: Bool {
        _ = (staleThresholdRaw, expiryThresholdRaw)
        guard let entry = entries.max(by: { $0.timestamp < $1.timestamp }) else {
            // No explicit status at all: a bare derived reading (if any) shows.
            return workspace.aggregatedDerivedActivity != nil
        }
        let text = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pill = SidebarActivityProjector.project(
            explicitText: text,
            explicitAgeSeconds: decayClock.now.timeIntervalSince(entry.timestamp),
            derived: workspace.aggregatedDerivedActivity,
            staleSeconds: SidebarStalenessSettings.staleSeconds(),
            expirySeconds: SidebarStalenessSettings.expirySeconds()
        )
        return pill?.isDerived == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !takeoverActive, !entries.isEmpty {
                SidebarMetadataRows(entries: entries, isActive: isActive, onFocus: onFocus)
            }
        }
    }
}

private struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let onFocus: () -> Void

    @Environment(\.chromeScaleTokens) private var chromeTokens
    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details") : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: chromeTokens.sidebarWorkspaceMetadata, weight: .semibold))
                .foregroundColor(isActive ? .white.opacity(0.65) : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleBlocks: [SidebarMetadataBlock] {
        guard !isExpanded, blocks.count > collapsedBlockLimit else { return blocks }
        return Array(blocks.prefix(collapsedBlockLimit))
    }

    private var shouldShowToggle: Bool {
        blocks.count > collapsedBlockLimit
    }
}

private struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let onFocus: () -> Void

    @Environment(\.chromeScaleTokens) private var chromeTokens
    @State private var renderedMarkdown: AttributedString?

    var body: some View {
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(block.markdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .font(.system(size: chromeTokens.sidebarWorkspaceMetadata))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onAppear(perform: renderMarkdown)
        .onChange(of: block.markdown) { _ in
            renderMarkdown()
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.8) : .secondary
    }

    private func renderMarkdown() {
        renderedMarkdown = try? AttributedString(
            markdown: block.markdown,
            options: .init(interpretedSyntax: .full)
        )
    }
}

enum SidebarDropEdge {
    case top
    case bottom
}

struct SidebarDropIndicator {
    let workspaceId: UUID?
    let edge: SidebarDropEdge
    var groupId: UUID? = nil
    var isGroupBody: Bool = false
}

enum SidebarDropPlanner {
    static func edgeForPointer(locationY: CGFloat, targetHeight: CGFloat) -> SidebarDropEdge {
        guard targetHeight > 0 else { return .top }
        let clampedY = min(max(locationY, 0), targetHeight)
        return clampedY < (targetHeight / 2) ? .top : .bottom
    }

}

enum SidebarAutoScrollDirection: Equatable {
    case up
    case down
}

struct SidebarAutoScrollPlan: Equatable {
    let direction: SidebarAutoScrollDirection
    let pointsPerTick: CGFloat
}

enum SidebarDragAutoScrollPlanner {
    static let edgeInset: CGFloat = 44
    static let minStep: CGFloat = 2
    static let maxStep: CGFloat = 12

    static func plan(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        edgeInset: CGFloat = SidebarDragAutoScrollPlanner.edgeInset,
        minStep: CGFloat = SidebarDragAutoScrollPlanner.minStep,
        maxStep: CGFloat = SidebarDragAutoScrollPlanner.maxStep
    ) -> SidebarAutoScrollPlan? {
        guard edgeInset > 0, maxStep >= minStep else { return nil }
        if distanceToTop <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToTop) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .up, pointsPerTick: step)
        }
        if distanceToBottom <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToBottom) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .down, pointsPerTick: step)
        }
        return nil
    }
}

@MainActor
private final class SidebarDragAutoScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var activePlan: SidebarAutoScrollPlan?

    func attach(scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    func updateFromDragLocation() {
        guard let scrollView else {
            stop()
            return
        }
        guard let plan = plan(for: scrollView) else {
            stop()
            return
        }
        activePlan = plan
        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activePlan = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons != 0 else {
            stop()
            return
        }
        guard let scrollView else {
            stop()
            return
        }

        // AppKit drag/drop autoscroll guidance recommends autoscroll(with:)
        // when periodic drag updates are available; use it first.
        if applyNativeAutoscroll(to: scrollView) {
            activePlan = plan(for: scrollView)
            if activePlan == nil {
                stop()
            }
            return
        }

        activePlan = self.plan(for: scrollView)
        guard let plan = activePlan else {
            stop()
            return
        }
        _ = apply(plan: plan, to: scrollView)
    }

    private func applyNativeAutoscroll(to scrollView: NSScrollView) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return false
        }

        let clipView = scrollView.contentView
        let didScroll = clipView.autoscroll(with: event)
        if didScroll {
            scrollView.reflectScrolledClipView(clipView)
        }
        return didScroll
    }

    private func distancesToEdges(mousePoint: CGPoint, viewportHeight: CGFloat, isFlipped: Bool) -> (top: CGFloat, bottom: CGFloat) {
        if isFlipped {
            return (top: mousePoint.y, bottom: viewportHeight - mousePoint.y)
        }
        return (top: viewportHeight - mousePoint.y, bottom: mousePoint.y)
    }

    private func planForMousePoint(_ mousePoint: CGPoint, in clipView: NSClipView) -> SidebarAutoScrollPlan? {
        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return nil }

        let distances = distancesToEdges(mousePoint: mousePoint, viewportHeight: viewportHeight, isFlipped: clipView.isFlipped)
        return SidebarDragAutoScrollPlanner.plan(distanceToTop: distances.top, distanceToBottom: distances.bottom)
    }

    private func mousePoint(in clipView: NSClipView) -> CGPoint {
        let mouseInWindow = clipView.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        return clipView.convert(mouseInWindow, from: nil)
    }

    private func currentPlan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        let clipView = scrollView.contentView
        let mouse = mousePoint(in: clipView)
        return planForMousePoint(mouse, in: clipView)
    }

    private func plan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        currentPlan(for: scrollView)
    }

    private func apply(plan: SidebarAutoScrollPlan, to scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        let maxOriginY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard maxOriginY > 0 else { return false }

        let directionMultiplier: CGFloat = (plan.direction == .down) ? 1 : -1
        let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
        let delta = directionMultiplier * flippedMultiplier * plan.pointsPerTick
        let currentY = clipView.bounds.origin.y
        let targetY = min(max(currentY + delta, 0), maxOriginY)
        guard abs(targetY - currentY) > 0.01 else { return false }

        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

private enum SidebarWorkspaceDragPayload {
    static let typeIdentifier = "com.stage11.c11.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let prefix = "cmux.sidebar-tab."

    /// C11H-207: the workspace of the sidebar drag most recently started in
    /// any window, so another window's sidebar can plan a drop for it. Preview
    /// only; a drop confirms against the drag pasteboard (`currentId`).
    @MainActor static var inFlightWorkspaceId: UUID?

    @MainActor
    static func provider(for workspaceId: UUID) -> NSItemProvider {
        inFlightWorkspaceId = workspaceId
        let provider = NSItemProvider()
        let payload = "\(prefix)\(workspaceId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
    static func currentId() -> UUID? {
        let board = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(typeIdentifier)
        guard let data = board.data(forType: type),
              let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix)
        else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }

}

private enum SidebarGroupDragPayload {
    static let typeIdentifier = "com.stage11.c11.sidebar-group-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let prefix = "c11.sidebar-group."

    static func provider(for workspaceId: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(prefix)\(workspaceId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
    static func currentId() -> UUID? {
        let board = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(typeIdentifier)
        guard let data = board.data(forType: type),
              let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix)
        else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }

}

private enum BonsplitTabDragPayload {
    static let typeIdentifier = BonsplitDragTypes.tabTransferIdentifier
    private static let currentProcessId = Int32(ProcessInfo.processInfo.processIdentifier)

    struct Transfer: Decodable {
        struct TabInfo: Decodable {
            let id: UUID
        }

        let bonsplitTab: TabInfo
        let sourcePaneId: UUID
        let sourceProcessId: Int32

        private enum CodingKeys: String, CodingKey {
            case tab
            case sourcePaneId
            case sourceProcessId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.bonsplitTab = try container.decode(TabInfo.self, forKey: .tab)
            self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
            // Legacy payloads won't include this field. Treat as foreign process.
            self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
        }
    }

    private static func isCurrentProcessTransfer(_ transfer: Transfer) -> Bool {
        transfer.sourceProcessId == currentProcessId
    }

    static func currentTransfer() -> Transfer? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(typeIdentifier)

        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        return nil
    }
}

/// Card frames of the sidebar's workspace rows, for the panel drop overlay.
private struct SidebarWorkspaceRowAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SidebarPanelDropOverlay: NSViewRepresentable {
    let rows: [SidebarPanelDropView.Row]
    @Binding var targetWorkspaceId: UUID?

    func makeNSView(context: Context) -> SidebarPanelDropView {
        SidebarPanelDropView()
    }

    func updateNSView(_ view: SidebarPanelDropView, context: Context) {
        view.rows = rows
        view.setTargetWorkspaceId = { id in
            if targetWorkspaceId != id { targetWorkspaceId = id }
        }
    }
}

/// Receives Bonsplit's AppKit panel drag over the sidebar. SwiftUI's per-row
/// `.onDrop` never sees that drag, so this view registers for it directly. It
/// takes hit tests only while a panel drag is in flight, so clicks, hovers and
/// workspace reorder drags reach the rows beneath it.
private final class SidebarPanelDropView: NSView {
    struct Row: Equatable {
        let workspaceId: UUID
        let frame: CGRect
    }

    var rows: [Row] = []
    var setTargetWorkspaceId: (UUID?) -> Void = { _ in }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([DragOverlayRoutingPolicy.bonsplitTabTransferType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard DragOverlayRoutingPolicy.isPanelDragInFlight() else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setTargetWorkspaceId(nil) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
#if DEBUG
        dlog("sidebar.panelDrop.exited")
#endif
        setTargetWorkspaceId(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setTargetWorkspaceId(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        target(for: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setTargetWorkspaceId(nil) }
        guard let (workspaceId, transfer) = target(for: sender),
              let app = AppDelegate.shared else {
#if DEBUG
            dlog("sidebar.panelDrop.perform moved=0 reason=noTarget")
#endif
            return false
        }
        // The operator stays put, unless the panel is the last one in the
        // workspace they are on: that workspace closes, so they follow the panel.
        let source = app.locateBonsplitSurface(bonsplitTabId: transfer.bonsplitTab.id)
        let followsPanel = source.map { source in
            source.workspaceManager.selectedWorkspaceId == source.workspaceId
                && source.workspaceManager.workspaces.first { $0.id == source.workspaceId }?.panels.count == 1
        } ?? false
        let moved = app.moveBonsplitTab(
            bonsplitTabId: transfer.bonsplitTab.id,
            toWorkspace: workspaceId,
            focus: followsPanel,
            focusWindow: followsPanel
        )
#if DEBUG
        dlog(
            "sidebar.panelDrop.perform moved=\(moved ? 1 : 0) targetWs=\(workspaceId.uuidString.prefix(5)) " +
            "follow=\(followsPanel ? 1 : 0)"
        )
#endif
        return moved
    }

    private func updateTarget(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let workspaceId = target(for: sender)?.workspaceId
#if DEBUG
        if phase == "entered" || workspaceId != lastLoggedTargetId {
            dlog(
                "sidebar.panelDrop.\(phase) targetWs=\(workspaceId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
                "rows=\(rows.count)"
            )
        }
        lastLoggedTargetId = workspaceId
#endif
        setTargetWorkspaceId(workspaceId)
        return workspaceId == nil ? [] : .move
    }

#if DEBUG
    private var lastLoggedTargetId: UUID?
#endif

    /// The drag's panel and its workspace, read once per drag session rather
    /// than on every pointer move.
    private var currentDrag: (sequence: Int, transfer: BonsplitTabDragPayload.Transfer, sourceWorkspaceId: UUID?)?

    /// Half the sidebar's row spacing, so the target holds across the gap
    /// between two cards instead of flickering off.
    private static let rowHitSlop: CGFloat = 2

    /// The workspace under the cursor and the drag's panel, or nil when the
    /// drag is foreign or the card is the panel's own workspace.
    private func target(for sender: any NSDraggingInfo) -> (workspaceId: UUID, transfer: BonsplitTabDragPayload.Transfer)? {
        if currentDrag?.sequence != sender.draggingSequenceNumber {
            currentDrag = BonsplitTabDragPayload.currentTransfer().map { transfer in
                let source = AppDelegate.shared?.locateBonsplitSurface(bonsplitTabId: transfer.bonsplitTab.id)
                return (sender.draggingSequenceNumber, transfer, source?.workspaceId)
            }
        }
        guard let drag = currentDrag else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard let row = rows.first(where: { $0.frame.insetBy(dx: 0, dy: -Self.rowHitSlop).contains(point) }) else {
            return nil
        }
        guard drag.sourceWorkspaceId != row.workspaceId else { return nil }
        return (row.workspaceId, drag.transfer)
    }
}

private struct SidebarWorkspaceDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID?
    var targetGroupId: UUID? = nil
    let workspaceManager: WorkspaceManager
    @Binding var draggedWorkspaceId: UUID?
    @Binding var draggedGroupId: UUID?
    @Binding var selectedWorkspaceIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?

    func validateDrop(info: DropInfo) -> Bool { plan(for: info) != nil }

    func dropEntered(info: DropInfo) { updatePreview(info) }

    func dropExited(info: DropInfo) {
        // A preview belongs to the current target, even when pin-clamping puts
        // the indicator somewhere else. The next target computes its own plan.
        dropIndicator = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard plan(for: info) != nil else {
            dropIndicator = nil
            return DropProposal(operation: .forbidden)
        }
        updatePreview(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedWorkspaceId = nil
            draggedGroupId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        // Resolve the current model and payload again; never commit hover state.
        guard let plan = plan(for: info) else { return false }
        if case .moveWorkspace(let id, let groupId, let before, let after) = plan.command,
           !workspaceManager.workspaces.contains(where: { $0.id == id }) {
            // C11H-207: a card from another window. Confirm it against the drag
            // pasteboard, then move it once this drop returns, so its source
            // row is not removed under the live drag session.
            guard SidebarWorkspaceDragPayload.currentId() == id,
                  let windowId = AppDelegate.shared?.windowId(for: workspaceManager) else { return false }
#if DEBUG
            dlog("sidebar.crossWindowDrop.perform ws=\(id.uuidString.prefix(5)) to=\(windowId.uuidString.prefix(5))")
#endif
            SidebarDragLifecycleNotification.postClearRequest(reason: "cross_window_drop")
            SidebarForeignHover.reset()
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.moveWorkspaceToWindow(
                    workspaceId: id, windowId: windowId, groupId: groupId, before: before, after: after
                )
            }
            return true
        }
        guard validPasteboardSource else { return false }
        if case .moveWorkspace(let id, _, _, _) = plan.command,
           let windowId = AppDelegate.shared?.windowId(for: workspaceManager),
           let hover = SidebarForeignHover.pending(workspaceId: id, pointer: NSEvent.mouseLocation),
           hover.windowId != windowId {
            // This window came forward at release over the sidebar of the
            // window the card was shown landing in: land it there.
#if DEBUG
            dlog("sidebar.crossWindowDrop.viaSourceSidebar ws=\(id.uuidString.prefix(5)) to=\(hover.windowId.uuidString.prefix(5))")
#endif
            SidebarForeignHover.reset()
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.moveWorkspaceToWindow(
                    workspaceId: id, windowId: hover.windowId,
                    groupId: hover.groupId, before: hover.before, after: hover.after
                )
            }
            return true
        }
        if case .moveWorkspace = plan.command,
           SidebarForeignHover.pointerWasOverAnotherWindow(NSEvent.mouseLocation) {
            // This window came forward at release; the operator saw another
            // window here, so do not reorder in this one.
            return false
        }
        do {
            switch plan.command {
            case .moveWorkspace(let id, let groupId, let before, let after):
                try workspaceManager.moveWorkspaceToGroup(workspaceId: id, groupId: groupId, before: before, after: after)
            case .moveGroup(let id, let before, let after):
                try workspaceManager.reorderWorkspaceGroup(id: id, before: before, after: after)
            }
#if DEBUG
            dlog("sidebar.drop \(Self.debugCommand(plan.command)) changed=\(plan.changed)")
#endif
            // Dragging is structural, not focus intent. Retain multi-selection
            // and refresh its canonical anchor without selecting a workspace.
            selectedWorkspaceIds.formIntersection(Set(workspaceManager.workspaces.map(\.id)))
            lastSidebarSelectionIndex = workspaceManager.selectedWorkspaceId.flatMap { selected in
                workspaceManager.workspaces.firstIndex { $0.id == selected }
            }
            return true
        } catch {
            return false
        }
    }

#if DEBUG
    private static func debugCommand(_ command: WorkspaceGroupDropPlanner.Command) -> String {
        func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(5)) } ?? "-" }
        switch command {
        case .moveWorkspace(let id, let groupId, let before, let after):
            return "ws=\(short(id)) group=\(short(groupId)) before=\(short(before)) after=\(short(after))"
        case .moveGroup(let id, let before, let after):
            return "group=\(short(id)) before=\(short(before)) after=\(short(after))"
        }
    }
#endif

    private var validPasteboardSource: Bool {
        if let id = draggedGroupId { return SidebarGroupDragPayload.currentId() == id }
        if let id = draggedWorkspaceId { return SidebarWorkspaceDragPayload.currentId() == id }
        return false
    }

    /// C11H-207: a workspace card dragged in from another window's sidebar,
    /// read from the process-wide in-flight record and confirmed by the drag's
    /// type. Never written into this window's `draggedWorkspaceId`: that
    /// change is broadcast, and would clear the source window's drag mid-flight.
    private func foreignWorkspace(_ info: DropInfo) -> WorkspaceOrderEntry? {
        guard draggedWorkspaceId == nil, draggedGroupId == nil,
              info.hasItemsConforming(to: [SidebarWorkspaceDragPayload.typeIdentifier]),
              let id = SidebarWorkspaceDragPayload.inFlightWorkspaceId,
              !workspaceManager.workspaces.contains(where: { $0.id == id }),
              let owner = AppDelegate.shared?.workspaceManagerFor(workspaceId: id),
              owner !== workspaceManager,
              let workspace = owner.workspaces.first(where: { $0.id == id }) else { return nil }
        return WorkspaceOrderEntry(id: id, isPinned: workspace.isPinned)
    }

    private func plan(for info: DropInfo) -> WorkspaceGroupDropPlanner.Plan? {
        guard let windowId = AppDelegate.shared?.windowId(for: workspaceManager) else { return nil }
        let source: WorkspaceGroupDropPlanner.Source
        var entries = workspaceManager.workspaceOrderEntries
        if let id = draggedGroupId {
            guard info.hasItemsConforming(to: [SidebarGroupDragPayload.typeIdentifier]) else { return nil }
            source = .group(id: id, windowId: windowId)
        } else if let id = draggedWorkspaceId {
            guard info.hasItemsConforming(to: [SidebarWorkspaceDragPayload.typeIdentifier]) else { return nil }
            source = .workspace(id: id, windowId: windowId)
        } else if let foreign = foreignWorkspace(info) {
            // Plan as if it already sat where attach puts it (the end of its
            // pin segment, ungrouped); the commit attaches it there first.
            entries = WorkspaceGroupDropPlanner.entries(entries, attaching: foreign)
            source = .workspace(id: foreign.id, windowId: windowId)
        } else { return nil }
        let edge: WorkspaceGroupDropPlanner.Edge = SidebarDropPlanner.edgeForPointer(
            locationY: info.location.y, targetHeight: targetRowHeight ?? 1
        ) == .top ? .top : .bottom
        let target: WorkspaceGroupDropPlanner.Target
        if let id = targetGroupId {
            if draggedGroupId == nil {
                // C11H-342: a header's top and (when nothing shows below it)
                // bottom thirds place the workspace beside the group; the rest joins.
                let showsMembers = workspaceManager.workspaceGroups.first { $0.id == id }?.isCollapsed == false
                    && workspaceManager.workspaces.contains { $0.groupId == id }
                target = WorkspaceGroupDropPlanner.headerTarget(
                    groupId: id, locationY: info.location.y, height: targetRowHeight ?? 0, showsMembers: showsMembers)
            } else {
                target = .groupEdge(groupId: id, edge: edge)
            }
        } else if let id = targetWorkspaceId {
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == id }) else { return nil }
            target = workspace.groupId == nil
                ? .ungroupedEdge(workspaceId: id, edge: edge)
                : .memberEdge(workspaceId: id, edge: edge)
        } else {
            target = .ungroupedEdge(workspaceId: nil, edge: .bottom)
        }
        return try? WorkspaceGroupDropPlanner.plan(
            windowId: windowId, groups: workspaceManager.workspaceGroups,
            workspaces: entries, rootOrder: workspaceManager.workspaceRootOrder, source: source, target: target
        )
    }

    private func updatePreview(_ info: DropInfo) {
        guard let plan = plan(for: info) else { dropIndicator = nil; return }
        if case .moveWorkspace(let id, let groupId, let before, let after) = plan.command,
           !workspaceManager.workspaces.contains(where: { $0.id == id }),
           let windowId = AppDelegate.shared?.windowId(for: workspaceManager) {
            SidebarForeignHover.note(.init(
                workspaceId: id, windowId: windowId, groupId: groupId, before: before, after: after
            ))
        }
        dragAutoScrollController.updateFromDragLocation()
        switch plan.indicator {
        case .groupBody(let id):
            dropIndicator = SidebarDropIndicator(workspaceId: nil, edge: .bottom, groupId: id, isGroupBody: true)
        case .groupEdge(let id, let edge):
            dropIndicator = SidebarDropIndicator(workspaceId: nil, edge: edge == .top ? .top : .bottom, groupId: id)
        case .memberEdge(let id, let edge):
            dropIndicator = SidebarDropIndicator(workspaceId: id, edge: edge == .top ? .top : .bottom)
        case .ungroupedEdge(let id, let edge):
            dropIndicator = SidebarDropIndicator(workspaceId: id, edge: edge == .top ? .top : .bottom)
        }
    }
}

private struct MiddleClickCapture: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCaptureView {
        let view = MiddleClickCaptureView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

private final class MiddleClickCaptureView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept middle-click so left-click selection and right-click context menus
        // continue to hit-test through to SwiftUI/AppKit normally.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else {
            return nil
        }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}

private struct ClearScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(ScrollBackgroundClearer())
        } else {
            content
                .background(ScrollBackgroundClearer())
        }
    }
}

private struct ScrollBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = findScrollView(startingAt: nsView) else { return }
            // Clear all backgrounds and mark as non-opaque for transparency
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.wantsLayer = true
            scrollView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.layer?.isOpaque = false

            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.contentView.layer?.isOpaque = false

            if let docView = scrollView.documentView {
                docView.wantsLayer = true
                docView.layer?.backgroundColor = NSColor.clear.cgColor
                docView.layer?.isOpaque = false
            }
        }
    }

    private func findScrollView(startingAt view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }
}

private struct DraggableFolderIcon: View {
    let directory: String

    var body: some View {
        DraggableFolderIconRepresentable(directory: directory)
            .frame(width: 16, height: 16)
            .safeHelp(String(localized: "sidebar.folderIcon.dragHint", defaultValue: "Drag to open in Finder or another app"))
            .onTapGesture(count: 2) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
            }
    }
}

private struct DraggableFolderIconRepresentable: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ nsView: DraggableFolderNSView, context: Context) {
        // C11-196: this fires on every SwiftUI update pass for the sidebar, and
        // the icon lookup underneath is a synchronous LaunchServices/IconServices
        // XPC round trip. Only re-resolve when the path actually changed.
        nsView.setDirectory(directory)
    }
}

/// C11-196: `NSWorkspace.icon(forFile:)` reaches IconServices/LaunchServices over
/// synchronous XPC. The sidebar asked for the same handful of directory icons on
/// every render pass, on every path-menu popup, and again on every drag start.
/// Memoize by path so one lookup serves them all.
///
/// Entries expire so an operator who assigns a custom folder icon sees it without
/// relaunching; `NSCache` additionally evicts under memory pressure.
enum FolderIconCache {
    static let entryTTL: TimeInterval = 300

    private final class Entry {
        let image: NSImage
        let storedAt: TimeInterval

        init(image: NSImage, storedAt: TimeInterval) {
            self.image = image
            self.storedAt = storedAt
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    /// A correctly sized icon for `path`, reusing a cached lookup when possible.
    ///
    /// The returned image is a copy: callers set `size` on it, and the cached
    /// base image must not be resized out from under other callers.
    static func icon(forPath path: String, size: CGFloat) -> NSImage {
        let key = path as NSString
        let now = ProcessInfo.processInfo.systemUptime
        let base: NSImage
        if let entry = cache.object(forKey: key), now - entry.storedAt < entryTTL {
            base = entry.image
        } else {
            base = NSWorkspace.shared.icon(forFile: path)
            cache.setObject(Entry(image: base, storedAt: now), forKey: key)
        }
        let sized = (base.copy() as? NSImage) ?? base
        sized.size = NSSize(width: size, height: size)
        return sized
    }
}

final class DraggableFolderNSView: NSView, NSDraggingSource {
    private final class FolderIconImageView: NSImageView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    private(set) var directory: String
    private var iconDirectory: String?
    private var imageView: FolderIconImageView!
    private var previousWindowMovableState: Bool?
    private weak var suppressedWindow: NSWindow?
    private var hasActiveDragSession = false
    private var didArmWindowDragSuppression = false

    private func formatPoint(_ point: NSPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setupImageView() {
        imageView = FolderIconImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateIcon()
    }

    /// Point the view at a new directory, refreshing the icon only when the path
    /// actually changed. SwiftUI calls this on every update pass.
    func setDirectory(_ newDirectory: String) {
        guard newDirectory != directory else { return }
        directory = newDirectory
        updateIcon()
    }

    func updateIcon() {
        guard iconDirectory != directory || imageView.image == nil else { return }
        imageView.image = FolderIconCache.icon(forPath: directory, size: 16)
        iconDirectory = directory
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasActiveDragSession = false
        restoreWindowMovableStateIfNeeded()
        #if DEBUG
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.dragEnd dir=\(directory) operation=\(operation.rawValue) screen=\(formatPoint(screenPoint)) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let hit = super.hitTest(point)
        #if DEBUG
        let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let imageHit = (hit === imageView)
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        dlog("folder.hitTest point=\(formatPoint(point)) hit=\(hitDesc) imageViewHit=\(imageHit) returning=DraggableFolderNSView wasMovable=\(wasMovable) nowMovable=\(nowMovable)")
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        maybeDisableWindowDraggingEarly(trigger: "mouseDown")
        hasActiveDragSession = false
        #if DEBUG
        let localPoint = convert(event.locationInWindow, from: nil)
        let responderDesc = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.mouseDown dir=\(directory) point=\(formatPoint(localPoint)) firstResponder=\(responderDesc) wasMovable=\(wasMovable) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
        let fileURL = URL(fileURLWithPath: directory)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)

        let iconImage = FolderIconCache.icon(forPath: directory, size: 32)
        draggingItem.setDraggingFrame(bounds, contents: iconImage)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        hasActiveDragSession = true
        #if DEBUG
        let itemCount = session.draggingPasteboard.pasteboardItems?.count ?? 0
        dlog("folder.dragStart dir=\(directory) pasteboardItems=\(itemCount)")
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Always restore suppression on mouse-up; drag-session callbacks can be
        // skipped for non-started drags, which would otherwise leave suppression stuck.
        restoreWindowMovableStateIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = buildPathMenu()
        // Pop up menu at bottom-left of icon (like native proxy icon)
        let menuLocation = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func buildPathMenu() -> NSMenu {
        let menu = NSMenu()
        let url = URL(fileURLWithPath: directory).standardized
        var pathComponents: [URL] = []

        // Build path from current directory up to root
        var current = url
        while current.path != "/" {
            pathComponents.append(current)
            current = current.deletingLastPathComponent()
        }
        pathComponents.append(URL(fileURLWithPath: "/"))

        // Add path components (current dir at top, root at bottom - matches native macOS)
        for pathURL in pathComponents {
            let icon = FolderIconCache.icon(forPath: pathURL.path, size: 16)

            let displayName: String
            if pathURL.path == "/" {
                // Use the volume name for root
                if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
                    displayName = volumeName
                } else {
                    displayName = String(localized: "sidebar.pathMenu.macintoshHD", defaultValue: "Macintosh HD")
                }
            } else {
                displayName = FileManager.default.displayName(atPath: pathURL.path)
            }

            let item = NSMenuItem(title: displayName, action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.image = icon
            item.representedObject = pathURL
            menu.addItem(item)
        }

        // Add computer name at the bottom (like native proxy icon)
        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let computerIcon = NSImage(named: NSImage.computerName) ?? NSImage()
        computerIcon.size = NSSize(width: 16, height: 16)

        let computerItem = NSMenuItem(title: computerName, action: #selector(openComputer(_:)), keyEquivalent: "")
        computerItem.target = self
        computerItem.image = computerIcon
        menu.addItem(computerItem)

        return menu
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func openComputer(_ sender: NSMenuItem) {
        // Open "Computer" view in Finder (shows all volumes)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func restoreWindowMovableStateIfNeeded() {
        guard didArmWindowDragSuppression || previousWindowMovableState != nil else { return }
        let targetWindow = suppressedWindow ?? window
        let depthAfter = endWindowDragSuppression(window: targetWindow)
        restoreWindowDragging(window: targetWindow, previousMovableState: previousWindowMovableState)
        self.previousWindowMovableState = nil
        self.suppressedWindow = nil
        self.didArmWindowDragSuppression = false
        #if DEBUG
        let nowMovable = targetWindow.map { String($0.isMovable) } ?? "nil"
        dlog("folder.dragSuppression restore depth=\(depthAfter) nowMovable=\(nowMovable)")
        #endif
    }

    private func maybeDisableWindowDraggingEarly(trigger: String) {
        guard !didArmWindowDragSuppression else { return }
        guard let eventType = NSApp.currentEvent?.type,
              eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return
        }
        guard let currentWindow = window else { return }

        didArmWindowDragSuppression = true
        suppressedWindow = currentWindow
        let suppressionDepth = beginWindowDragSuppression(window: currentWindow) ?? 0
        if currentWindow.isMovable {
            previousWindowMovableState = temporarilyDisableWindowDragging(window: currentWindow)
        } else {
            previousWindowMovableState = nil
        }
        #if DEBUG
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = String(currentWindow.isMovable)
        dlog(
            "folder.dragSuppression trigger=\(trigger) event=\(eventType) depth=\(suppressionDepth) wasMovable=\(wasMovable) nowMovable=\(nowMovable)"
        )
        #endif
    }
}

func temporarilyDisableWindowDragging(window: NSWindow?) -> Bool? {
    guard let window else { return nil }
    let wasMovable = window.isMovable
    if wasMovable {
        window.isMovable = false
    }
    return wasMovable
}

func restoreWindowDragging(window: NSWindow?, previousMovableState: Bool?) {
    guard let window, let previousMovableState else { return }
    window.isMovable = previousMovableState
}

/// Wrapper view that tries NSGlassEffectView (macOS 26+) when available or requested
private struct SidebarVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor?
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1.0,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
    }

    static var liquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    func makeNSView(context: Context) -> NSView {
        // Try NSGlassEffectView if preferred or if we want to test availability
        if preferLiquidGlass, let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.autoresizingMask = [.width, .height]
            glass.wantsLayer = true
            return glass
        }

        // Use NSVisualEffectView
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Configure based on view type
        if nsView.className == "NSGlassEffectView" {
            // NSGlassEffectView configuration via private API
            nsView.alphaValue = max(0.0, min(1.0, opacity))
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.masksToBounds = cornerRadius > 0

            // Try to set tint color via private selector
            if let color = tintColor {
                let selector = NSSelectorFromString("setTintColor:")
                if nsView.responds(to: selector) {
                    nsView.perform(selector, with: color)
                }
            }
        } else if let visualEffect = nsView as? NSVisualEffectView {
            // NSVisualEffectView configuration
            visualEffect.material = material
            visualEffect.blendingMode = blendingMode
            visualEffect.state = state
            visualEffect.alphaValue = max(0.0, min(1.0, opacity))
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = cornerRadius > 0
            visualEffect.needsDisplay = true
        }
    }
}


private struct SidebarBackdrop: View {
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(C11SidebarBackground.storageKey) private var c11SidebarBackgroundDark = C11SidebarBackground.defaultValue.rawValue
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    /// c11 (C11H-197): the hosting window's theme override.
    @Environment(\.c11WindowThemeName) private var windowThemeName

    var body: some View {
        let materialOption = SidebarMaterialOption(rawValue: sidebarMaterial)
        let blendingMode = SidebarBlendModeOption(rawValue: sidebarBlendMode)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: sidebarState)?.state ?? .active
        // One tint in both appearances. An older per-mode value in defaults is ignored.
        let tintColor = (NSColor(hex: sidebarTintHex) ?? .black).withAlphaComponent(sidebarTintOpacity)
        let cornerRadius = CGFloat(max(0, sidebarCornerRadius))
        let useLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let useWindowLevelGlass = useLiquidGlass && blendingMode == .behindWindow
        let themeTintOverlay = resolveThemeTintOverlay()

        return ZStack {
            if let material = materialOption?.material {
                // When using liquidGlass + behindWindow, window handles glass + tint
                // Sidebar is fully transparent
                if !useWindowLevelGlass {
                    SidebarVisualEffectBackground(
                        material: material,
                        blendingMode: blendingMode,
                        state: state,
                        opacity: sidebarBlurOpacity,
                        tintColor: tintColor,
                        cornerRadius: cornerRadius,
                        preferLiquidGlass: useLiquidGlass
                    )
                    // Tint overlay for NSVisualEffectView fallback
                    if !useLiquidGlass {
                        Color(nsColor: tintColor)
                    }
                }
            }
            // Theme-resolved tint layered atop the existing tint. Sidebar backdrop
            // is neutral workspace chrome, so it intentionally resolves without
            // the selected workspace color; workspace identity stays on tab/card chrome.
            if let themeTintOverlay {
                Color(nsColor: themeTintOverlay)
            }
            // When material is none or useWindowLevelGlass, render nothing
            // c11's backdrop (C11H-32, C11H-146): the theme's `[backdrop]` or a
            // fixed Dark-slot style. An opaque fill sits on top, so the imported
            // c11 material, tint and theme overlay don't show through.
            if let backdrop = C11SidebarBackground.backdrop(
                raw: c11SidebarBackgroundDark,
                colorScheme: colorScheme,
                theme: SidebarThemeStyleCache.backdrop(themeManager, colorScheme: colorScheme, windowThemeName: windowThemeName)
            ) {
                SidebarBackdropView(style: backdrop)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func resolveThemeTintOverlay() -> NSColor? {
        guard themeManager.isEnabled else { return nil }
        let themeColorScheme: ThemeContext.ColorScheme = colorScheme == .dark ? .dark : .light
        let context = themeManager.makeContext(
            workspaceColor: nil,
            colorScheme: themeColorScheme,
            windowThemeName: windowThemeName
        )
        return themeManager.resolve(.sidebar_tintOverlay, context: context)
    }
}

enum SidebarMaterialOption: String, CaseIterable, Identifiable {
    case none
    case liquidGlass  // macOS 26+ NSGlassEffectView
    case sidebar
    case hudWindow
    case menu
    case popover
    case underWindowBackground
    case windowBackground
    case contentBackground
    case fullScreenUI
    case sheet
    case headerView
    case toolTip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "settings.material.none", defaultValue: "None")
        case .liquidGlass: return String(localized: "settings.material.liquidGlass", defaultValue: "Liquid Glass (macOS 26+)")
        case .sidebar: return String(localized: "settings.material.sidebar", defaultValue: "Sidebar")
        case .hudWindow: return String(localized: "settings.material.hudWindow", defaultValue: "HUD Window")
        case .menu: return String(localized: "settings.material.menu", defaultValue: "Menu")
        case .popover: return String(localized: "settings.material.popover", defaultValue: "Popover")
        case .underWindowBackground: return String(localized: "settings.material.underWindow", defaultValue: "Under Window")
        case .windowBackground: return String(localized: "settings.material.windowBackground", defaultValue: "Window Background")
        case .contentBackground: return String(localized: "settings.material.contentBackground", defaultValue: "Content Background")
        case .fullScreenUI: return String(localized: "settings.material.fullScreenUI", defaultValue: "Full Screen UI")
        case .sheet: return String(localized: "settings.material.sheet", defaultValue: "Sheet")
        case .headerView: return String(localized: "settings.material.headerView", defaultValue: "Header View")
        case .toolTip: return String(localized: "settings.material.toolTip", defaultValue: "Tool Tip")
        }
    }

    /// Returns true if this option should use NSGlassEffectView (macOS 26+)
    var usesLiquidGlass: Bool {
        self == .liquidGlass
    }

    var material: NSVisualEffectView.Material? {
        switch self {
        case .none: return nil
        case .liquidGlass: return .underWindowBackground  // Fallback material
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .popover: return .popover
        case .underWindowBackground: return .underWindowBackground
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .fullScreenUI: return .fullScreenUI
        case .sheet: return .sheet
        case .headerView: return .headerView
        case .toolTip: return .toolTip
        }
    }
}

enum SidebarBlendModeOption: String, CaseIterable, Identifiable {
    case behindWindow
    case withinWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .behindWindow: return String(localized: "settings.blendMode.behindWindow", defaultValue: "Behind Window")
        case .withinWindow: return String(localized: "settings.blendMode.withinWindow", defaultValue: "Within Window")
        }
    }

    var mode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
}

enum SidebarStateOption: String, CaseIterable, Identifiable {
    case active
    case inactive
    case followWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return String(localized: "settings.state.active", defaultValue: "Active")
        case .inactive: return String(localized: "settings.state.inactive", defaultValue: "Inactive")
        case .followWindow: return String(localized: "settings.state.followWindow", defaultValue: "Follow Window")
        }
    }

    var state: NSVisualEffectView.State {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .followWindow: return .followsWindowActiveState
        }
    }
}

enum SidebarTintDefaults {
    static let hex = "#000000"
    static let opacity = 0.18
}

enum SidebarPresetOption: String, CaseIterable, Identifiable {
    case nativeSidebar
    case glassBehind
    case softBlur
    case popoverGlass
    case hudGlass
    case underWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeSidebar: return String(localized: "settings.preset.nativeSidebar", defaultValue: "Native Sidebar")
        case .glassBehind: return String(localized: "settings.preset.raycastGray", defaultValue: "Raycast Gray")
        case .softBlur: return String(localized: "settings.preset.softBlur", defaultValue: "Soft Blur")
        case .popoverGlass: return String(localized: "settings.preset.popoverGlass", defaultValue: "Popover Glass")
        case .hudGlass: return String(localized: "settings.preset.hudGlass", defaultValue: "HUD Glass")
        case .underWindow: return String(localized: "settings.preset.underWindow", defaultValue: "Under Window")
        }
    }

    var material: SidebarMaterialOption {
        switch self {
        case .nativeSidebar: return .sidebar
        case .glassBehind: return .sidebar
        case .softBlur: return .sidebar
        case .popoverGlass: return .popover
        case .hudGlass: return .hudWindow
        case .underWindow: return .underWindowBackground
        }
    }

    var blendMode: SidebarBlendModeOption {
        switch self {
        case .nativeSidebar: return .withinWindow
        case .glassBehind: return .behindWindow
        case .softBlur: return .behindWindow
        case .popoverGlass: return .behindWindow
        case .hudGlass: return .withinWindow
        case .underWindow: return .withinWindow
        }
    }

    var state: SidebarStateOption {
        switch self {
        case .nativeSidebar: return .followWindow
        case .glassBehind: return .active
        case .softBlur: return .active
        case .popoverGlass: return .active
        case .hudGlass: return .active
        case .underWindow: return .followWindow
        }
    }

    var tintHex: String {
        switch self {
        case .nativeSidebar: return "#000000"
        case .glassBehind: return "#000000"
        case .softBlur: return "#000000"
        case .popoverGlass: return "#000000"
        case .hudGlass: return "#000000"
        case .underWindow: return "#000000"
        }
    }

    var tintOpacity: Double {
        switch self {
        case .nativeSidebar: return 0.18
        case .glassBehind: return 0.36
        case .softBlur: return 0.28
        case .popoverGlass: return 0.10
        case .hudGlass: return 0.62
        case .underWindow: return 0.14
        }
    }

    var cornerRadius: Double {
        switch self {
        case .nativeSidebar: return 0.0
        case .glassBehind: return 0.0
        case .softBlur: return 0.0
        case .popoverGlass: return 10.0
        case .hudGlass: return 10.0
        case .underWindow: return 6.0
        }
    }

    var blurOpacity: Double {
        switch self {
        case .nativeSidebar: return 1.0
        case .glassBehind: return 0.6
        case .softBlur: return 0.45
        case .popoverGlass: return 0.9
        case .hudGlass: return 0.98
        case .underWindow: return 0.9
        }
    }
}

extension NSColor {
    func hexString(includeAlpha: Bool = false) -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = min(255, max(0, Int(red * 255)))
        let greenByte = min(255, max(0, Int(green * 255)))
        let blueByte = min(255, max(0, Int(blue * 255)))
        if includeAlpha {
            let alphaByte = min(255, max(0, Int(alpha * 255)))
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }
}


// MARK: - Compact workspace card (C11H-221)
//
// Design: design/minimal-sidebar/DESIGN.md. The sidebar draws today's full
// cards while every workspace fits, and this two-line card the moment they
// would scroll. Everything here reads theme roles; nothing is compact-only.

/// Measurements behind the density decision. A plain reference, so a card
/// growing by a point updates it without re-evaluating the sidebar body.
final class SidebarDensityTracker {
    static let rootSpace = "c11.sidebar.root"
    static let contentSpace = "c11.sidebar.content"
    static let lastShownKey = "sidebarDensity.lastShown"
    static let lastCardHeightKey = "sidebarDensity.lastCardHeight"
    static let lastFullFooterKey = "sidebarDensity.lastFullFooterHeight"
    static let lastFullFooterKindsKey = "sidebarDensity.lastFullFooterKinds"

    var stack: SidebarStackMetrics?
    var scrollTop: CGFloat = 0
    var footer: SidebarFooterMetrics?
    /// The full-card footer as last measured, and the flag kinds it held.
    var fullFooterHeight: Double?
    var fullFooterKinds = 0
    /// Each workspace's full-card height when last drawn full.
    var cardHeights: [UUID: Double] = [:]

    /// A new sidebar starts in the density the last one settled on, so a
    /// laptop window opens compact instead of drawing one frame of full cards.
    /// Read from defaults once; every flip updates it.
    static var startDensity: SidebarDensity = initialDensity()

    static func initialDensity(defaults: UserDefaults = .standard) -> SidebarDensity {
        switch SidebarDensitySetting.resolve(defaults.string(forKey: SidebarDensitySetting.key)) {
        case .compact: return .compact
        case .cards: return .cards
        case .automatic:
            return defaults.string(forKey: lastShownKey).flatMap(SidebarDensity.init(rawValue:)) ?? .cards
        }
    }

    /// The mean full-card height last seen, for cards a new sidebar never drew.
    static func rememberedCardHeight(defaults: UserDefaults = .standard) -> Double? {
        let height = defaults.double(forKey: lastCardHeightKey)
        return height > 0 ? height : nil
    }

    /// The one-column full footer as last measured, and the flag kinds it held.
    static func rememberedFullFooter(defaults: UserDefaults = .standard) -> (height: Double, kinds: Int)? {
        let height = defaults.double(forKey: lastFullFooterKey)
        return height > 0 ? (height, defaults.integer(forKey: lastFullFooterKindsKey)) : nil
    }

    /// Written on a density flip only, from the main thread.
    static func remember(density: SidebarDensity, cardHeights: [UUID: Double],
                         fullFooterHeight: Double?, fullFooterKinds: Int,
                         defaults: UserDefaults = .standard) {
        startDensity = density
        defaults.set(density.rawValue, forKey: lastShownKey)
        if !cardHeights.isEmpty {
            defaults.set(cardHeights.values.reduce(0, +) / Double(cardHeights.count), forKey: lastCardHeightKey)
        }
        if let fullFooterHeight {
            defaults.set(fullFooterHeight, forKey: lastFullFooterKey)
            defaults.set(fullFooterKinds, forKey: lastFullFooterKindsKey)
        }
    }

    /// Flag kinds up, on main, from one shared subscription.
    @MainActor
    static let flagKindCounts: AnyPublisher<Int, Never> = PanelAttentionIndex.shared.$snapshots
        .receive(on: DispatchQueue.main)
        .map { _ in MainActor.assumeIsolated { PanelAttentionIndex.shared.flagKindSummary.groups.count } }
        .removeDuplicates()
        .eraseToAnyPublisher()
    var flagKinds = -1
}

/// The footer's frame, tagged with whether it was drawn dense.
struct SidebarFooterMetrics: Equatable {
    var frame: CGRect
    var dense: Bool
}

struct SidebarFooterMetricsKey: PreferenceKey {
    static let defaultValue: SidebarFooterMetrics? = nil
    static func reduce(value: inout SidebarFooterMetrics?, nextValue: () -> SidebarFooterMetrics?) {
        value = nextValue() ?? value
    }
}

/// Every full card's height, tagged with the density it was drawn in.
struct SidebarCardHeights: Equatable {
    var density: SidebarDensity
    var heights: [UUID: CGFloat]
}

struct SidebarCardHeightsKey: PreferenceKey {
    static let defaultValue: SidebarCardHeights? = nil
    static func reduce(value: inout SidebarCardHeights?, nextValue: () -> SidebarCardHeights?) {
        value = nextValue() ?? value
    }
}

/// The workspace stack as drawn, tagged with the density it was drawn in.
struct SidebarStackMetrics: Equatable {
    var frame: CGRect
    var density: SidebarDensity
}

struct SidebarStackMetricsKey: PreferenceKey {
    static let defaultValue: SidebarStackMetrics? = nil
    static func reduce(value: inout SidebarStackMetrics?, nextValue: () -> SidebarStackMetrics?) {
        value = nextValue() ?? value
    }
}

struct SidebarScrollTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


/// Each compact row's own AppKit view, by workspace, so the hover card can sit
/// beside it. Held weakly; rows carry no per-row state for it.
enum SidebarHoverAnchors {
    private final class WeakView { weak var view: NSView? }
    private static var views: [UUID: WeakView] = [:]

    static func set(_ view: NSView, for workspaceId: UUID) {
        let box = views[workspaceId] ?? WeakView()
        box.view = view
        views[workspaceId] = box
        if views.count > 64 { views = views.filter { $0.value.view != nil } }
    }

    static func view(for workspaceId: UUID) -> NSView? { views[workspaceId]?.view }
}

private final class SidebarHoverAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SidebarHoverAnchorView: NSViewRepresentable {
    let workspaceId: UUID

    func makeNSView(context: Context) -> NSView {
        let view = SidebarHoverAnchorNSView()
        SidebarHoverAnchors.set(view, for: workspaceId)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        SidebarHoverAnchors.set(nsView, for: workspaceId)
    }
}

extension WorkspaceRowView {
    /// The full card, or the compact card with its summary-card anchor. While
    /// this workspace's summary card is open, it follows the row's live state.
    @ViewBuilder
    var densityContents: some View {
        if density == .compact {
            compactCardContents
                .background(SidebarHoverAnchorView(workspaceId: workspace.id))
                .onChange(of: workspacePulse) { refreshSummaryCard() }
                .onChange(of: missionSnapshot) { refreshSummaryCard() }
                .onChange(of: workspace.captainSummary) { refreshSummaryCard() }
                .onChange(of: workspace.title) { refreshSummaryCard() }
                .onChange(of: colorScheme) { refreshSummaryCard() }
                .onChange(of: themeStyle) { refreshSummaryCard() }
                .onChange(of: chromeTokens) { refreshSummaryCard() }
                .onChange(of: isActive) { refreshSummaryCard() }
        } else {
            cardContents
        }
    }

    func handleRowHover(_ hovering: Bool) {
        isHovering = hovering
    }

    /// The info button: opens this workspace's summary card beside the row,
    /// or closes it when it is already open.
    func toggleSummaryCard() {
        WorkspaceHoverCardController.shared.toggle(
            workspaceId: workspace.id,
            anchor: SidebarHoverAnchors.view(for: workspace.id),
            liveKey: summaryLiveKey
        ) { maxListHeight in AnyView(hoverCardContent(maxListHeight: maxListHeight)) }
    }

    func refreshSummaryCard() {
        guard WorkspaceSummaryCardState.shared.shownWorkspaceId == workspace.id else { return }
        WorkspaceHoverCardController.shared.refresh(workspaceId: workspace.id, liveKey: summaryLiveKey) { maxListHeight in
            AnyView(hoverCardContent(maxListHeight: maxListHeight))
        }
    }

    /// An agent's title and subtitle read now from its panel, not from the
    /// row's pulse, which follows a description change only after the
    /// sidebar coordinator's card-context window (C11H-296); the open card
    /// shows the current one.
    func liveSummaryContext(_ agent: WorkspacePulseAgent) -> WorkspacePulseAgentContext? {
        let state = workspace.panelTitleBarState(panelId: agent.surfaceId)
        let reported = state.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspacePulseAgentContextProjector.project(
            title: reported?.isEmpty == false ? state.title : workspace.panels[agent.surfaceId]?.displayTitle,
            subtitle: state.description,
            descriptionUpdatedAt: state.descriptionUpdatedAt
        ) ?? agent.context
    }

    /// Changes whenever the open card's text would: the controller checks it
    /// once a second and rebuilds the card only when it moves.
    func summaryLiveKey() -> Int {
        var hasher = Hasher()
        hasher.combine(workspace.title)
        for agent in workspacePulse.signalAgents.prefix(WorkspaceHoverCard.maximumRows) {
            let context = liveSummaryContext(agent)
            hasher.combine(agent.surfaceId)
            hasher.combine(context?.title)
            hasher.combine(context?.subtitle)
            hasher.combine(context?.descriptionUpdatedAt)
            hasher.combine(PanelAllocationRegistry.shared.record(for: agent.surfaceId)?.number)
        }
        return hasher.finalize()
    }

    func dismissRowHoverCard() {
        WorkspaceHoverCardController.shared.rowGone(workspaceId: workspace.id)
    }

    /// Waiting claims the card edge only on the full card; on the compact card
    /// the number and the marks carry it, so a column of rows stays calm.
    var edgeShowsWaiting: Bool {
        density == .cards && workspacePulse.waitingCount > 0
    }

    var compactCardContents: some View {
        let scale = chromeTokens.multiplier
        let signal = workspacePulse.signalAgents
        let flagAgent = signal.first(where: \.flagged)
        return VStack(alignment: .leading, spacing: 2 * scale) {
            HStack(alignment: .center, spacing: 5) {
                if let icon = workspaceIconGlyph {
                    workspaceIconSlot(icon, titleSize: chromeTokens.sidebarWorkspaceTitle - 1)
                }
                workspaceTitleText(size: chromeTokens.sidebarWorkspaceTitle - 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                if workspace.isPinned {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: chromeTokens.sidebarWorkspaceAccessory, weight: .semibold))
                        .foregroundColor(themeStyle.cardTextSecondary ?? .secondary.opacity(0.7))
                }
                if showsWorkspaceId {
                    compactWorkspaceNumber(flagAgent: flagAgent)
                }
            }
            .frame(height: 15 * scale)

            compactSignalLine(scale: scale, signal: signal, flagAgent: flagAgent)
                .frame(height: 13 * scale)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3 * scale)
    }

    /// `WS N`: the flag's colour while a flag is up, the waiting colour while an
    /// agent waits on the operator, otherwise the full card's number colour.
    private func compactWorkspaceNumber(flagAgent: WorkspacePulseAgent?) -> some View {
        let color: Color = {
            if let agent = flagAgent { return compactFlagColor(agent) }
            if workspacePulse.waitingOnOperatorCount > 0 { return workspacePulseColor(for: .waiting) }
            return workspaceIdColor
        }()
        return (
            Text(verbatim: "WS ").foregroundColor(color.opacity(0.6))
            + Text(verbatim: "\(workspace.displayOrdinal)").foregroundColor(color)
        )
            .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceDetail, weight: .medium, design: .monospaced)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    /// A named kind's registry colour, else the theme's `states.flag`, else violet.
    func compactFlagColor(_ agent: WorkspacePulseAgent) -> Color {
        if let kind = agent.flagKind,
           let color = NSColor(hex: kind.colorHex(lightBackground: colorScheme == .light)) {
            return Color(nsColor: color)
        }
        return themeStyle.stateFlag ?? Color(nsColor: NSColor(srgbRed: 0x9D / 255, green: 0x8A / 255,
                                                              blue: 0xD9 / 255, alpha: 1))
    }

    /// Ink on the band: a named kind picks black or white by contrast; the
    /// generic flag uses the theme's ink for filled attention colours.
    private func compactBandInk(_ agent: WorkspacePulseAgent) -> Color {
        if let kind = agent.flagKind {
            return FlagKindInk.prefersDarkInk(hex: kind.colorHex(lightBackground: colorScheme == .light))
                ? BrandColors.blackSwiftUI : .white
        }
        return themeStyle.stateWaitingInk ?? BrandColors.blackSwiftUI
    }

    /// The second line: marks and counts, or, while a flag is up, the same in
    /// ink on a band of the flag's colour. Same height either way.
    @ViewBuilder
    private func compactSignalLine(scale: CGFloat, signal: [WorkspacePulseAgent],
                                   flagAgent: WorkspacePulseAgent?) -> some View {
        if let agent = flagAgent {
            let ink = compactBandInk(agent)
            HStack(spacing: 5) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8 * scale, weight: .bold))
                    .foregroundColor(ink)
                    .accessibilityHidden(true)
                compactAgentCount(ink: ink, scale: scale)
                captainSlot(captain: workspace.captainSummary, ink: ink, scale: scale, width: 54)
                compactMarks(ink: ink, agents: signal)
                compactInfoButton(ink: ink, scale: scale)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: (themeStyle.markRadius ?? 1) + 1, style: .continuous)
                    .fill(compactFlagColor(agent))
            )
            .padding(.horizontal, -5)
        } else {
            HStack(spacing: 5) {
                compactAgentCount(ink: nil, scale: scale)
                captainSlot(captain: workspace.captainSummary, ink: nil, scale: scale, width: 54)
                compactMarks(ink: nil, agents: signal)
                compactInfoButton(ink: nil, scale: scale)
            }
        }
    }

    /// A fixed slot in the existing signal/footer line. Presence changes ink
    /// and text only, never the card height or its count/info/flag controls.
    private func captainSlot(captain: WorkspaceCaptainSummary, ink: Color?, scale: CGFloat, width: CGFloat) -> some View {
        let description = captain.accessibilityDescription
        let label = captain.title ?? captain.address ?? ""
        let color = ink ?? themeStyle.cardAccent ?? Color(nsColor: .controlAccentColor)
        return HStack(spacing: 3) {
            Group {
                if captain.state == .ambiguous {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(color)
                } else {
                    WorkspaceCaptainHat()
                        .fill(captain.present ? color : Color.clear)
                        .overlay(WorkspaceCaptainHat().stroke(color, lineWidth: 1))
                }
            }
            .frame(width: 12 * scale, height: 10 * scale)
            .accessibilityHidden(true)
            Text(verbatim: label)
                .font(.system(size: chromeTokens.sidebarWorkspaceMetadata - 0.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(ink ?? themeStyle.cardTextSecondary ?? .secondary)
        }
        .frame(width: width * scale, alignment: .leading)
        // The slot stays reserved but empty when the group header already
        // shows this Captain: one mark per group, never one per member.
        .opacity(captain.cardShowsMark ? 1 : 0)
        .help(captain.cardShowsMark ? description : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: description))
        .accessibilityHidden(!captain.cardShowsMark)
    }

    /// The agent total, first on the line, in a two-digit slot so the marks
    /// after it hold still from 0 to 99.
    private func compactAgentCount(ink: Color?, scale: CGFloat) -> some View {
        let agents = workspacePulse.agents.count
        let label = String(localized: "sidebar.compact.agentCount.accessibility",
                           defaultValue: "\(agents) agents")
        return Text(verbatim: WorkspacePulseSignalLayout.countText(agents))
            .chromeStyle(themeStyle.cardLabel, size: chromeTokens.sidebarWorkspaceMetadata,
                         weight: .semibold, design: .monospaced)
            .monospacedDigit()
            .foregroundColor(ink ?? themeStyle.cardTextSecondary ?? .secondary)
            .opacity(agents == 0 && ink == nil ? 0.5 : 1)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 14 * scale, alignment: .leading)
            .accessibilityLabel(Text(verbatim: label))
            .help(label)
    }

    /// Bottom right: opens the workspace summary card, and closes it again.
    private func compactInfoButton(ink: Color?, scale: CGFloat) -> some View {
        WorkspaceSummaryInfoButton(
            workspaceId: workspace.id,
            ink: ink,
            idle: themeStyle.cardTextDim ?? .secondary.opacity(0.65),
            active: themeStyle.cardText ?? .primary,
            size: 11 * scale,
            action: toggleSummaryCard
        )
    }

    /// Every agent as a mark, flagged and waiting first; overflow drops from
    /// the quiet end into a `+N` tail.
    private func compactMarks(ink: Color?, agents: [WorkspacePulseAgent]) -> some View {
        GeometryReader { proxy in
            let visible = WorkspacePulseSignalLayout.visibleCount(total: agents.count,
                                                                  availableWidth: proxy.size.width)
            HStack(spacing: WorkspacePulseSignalLayout.markGap) {
                if agents.isEmpty {
                    Text(verbatim: "\u{2014}")
                        .font(.system(size: chromeTokens.sidebarWorkspaceMetadata, design: .monospaced))
                        .foregroundColor(ink ?? themeStyle.cardTextDim ?? .secondary.opacity(0.65))
                }
                ForEach(Array(agents.prefix(visible))) { agent in
                    if let ink {
                        WorkspacePulseMark(
                            state: agent.state, lifecycleColor: ink, flagColor: ink,
                            phaseId: agent.surfaceId, flagged: agent.flagged,
                            suppressed: agent.suppressed, lineageDepth: agent.lineageDepth,
                            animationEligible: false, genericFlagColor: ink,
                            markRadius: themeStyle.markRadius
                        )
                        .frame(width: WorkspacePulseSignalLayout.markSlot, height: 9)
                    } else {
                        workspacePulseMarkTarget(for: agent, width: WorkspacePulseSignalLayout.markSlot, height: 9)
                    }
                }
                if visible < agents.count {
                    Text(verbatim: "+\(agents.count - visible)")
                        .font(.system(size: chromeTokens.sidebarWorkspaceAccessory, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(ink?.opacity(0.75) ?? themeStyle.cardTextDim ?? .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    /// The workspace summary card: the workspace, its whole mission, and up to
    /// forty agents in signal order with their full subtitles; a click on one
    /// jumps to its panel the way a `c11://panel` link does. `maxListHeight`
    /// is set only when the card would not fit the screen; the list scrolls.
    func hoverCardContent(maxListHeight: CGFloat?) -> some View {
        let agents = Array(workspacePulse.signalAgents.prefix(WorkspaceHoverCard.maximumRows))
        let rows = agents.map { agent in
            let context = liveSummaryContext(agent)
            return WorkspaceHoverCard.Row(
                id: agent.surfaceId,
                number: PanelAllocationRegistry.shared.record(for: agent.surfaceId)?.number,
                title: context?.title ?? workspacePulseLabel(for: agent.presentedState),
                subtitle: context?.subtitle,
                descriptionUpdatedAt: context?.descriptionUpdatedAt,
                state: workspacePulseLabel(for: agent.presentedState),
                flagReason: agent.flagged
                    ? (agent.flagReason.map { agent.flagKind?.displayText(reason: $0) ?? $0 }
                        ?? agent.flagKind?.displayLabel)
                    : nil,
                flagColor: agent.flagged ? compactFlagColor(agent) : nil,
                mark: AnyView(workspacePulseMark(for: agent, animated: false).frame(width: 9, height: 9))
            )
        }
        return WorkspaceHoverCard(
            title: workspace.title,
            number: workspace.displayOrdinal,
            mission: workspace.mission?.paragraph,
            captain: workspace.captainSummary,
            census: workspacePulseCensusText,
            rows: rows,
            more: workspacePulse.agents.count - rows.count,
            fill: workspacePulseBaseColor,
            style: themeStyle,
            tokens: chromeTokens,
            maxListHeight: maxListHeight,
            onJump: { panelId in
                WorkspaceHoverCardController.shared.dismiss()
                _ = AppDelegate.shared?.openPanelLink(.panel(panelId), cause: "sidebar_summary_card")
            },
            onClose: { WorkspaceHoverCardController.shared.dismiss() }
        )
    }
}

/// Which workspace's summary card is open, so each row's info button can show
/// it. Changes only when a card opens or closes.
@MainActor
final class WorkspaceSummaryCardState: ObservableObject {
    static let shared = WorkspaceSummaryCardState()
    @Published private(set) var shownWorkspaceId: UUID?

    fileprivate func set(_ workspaceId: UUID?) {
        if shownWorkspaceId != workspaceId { shownWorkspaceId = workspaceId }
    }
}

/// The compact card's bottom-right info button. Filled while its card is open.
private struct WorkspaceSummaryInfoButton: View {
    let workspaceId: UUID
    let ink: Color?
    let idle: Color
    let active: Color
    let size: CGFloat
    let action: () -> Void
    @ObservedObject private var state = WorkspaceSummaryCardState.shared
    @State private var hovering = false

    var body: some View {
        let open = state.shownWorkspaceId == workspaceId
        let help = open
            ? String(localized: "sidebar.summaryCard.hide", defaultValue: "Hide workspace summary")
            : String(localized: "sidebar.summaryCard.show", defaultValue: "Show workspace summary")
        Button(action: action) {
            Image(systemName: open ? "info.circle.fill" : "info.circle")
                .font(.system(size: size, weight: .medium))
                .foregroundColor(ink ?? (open || hovering ? active : idle))
                .frame(width: size + 6, height: size + 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
        .accessibilityIdentifier("sidebar.workspace.info.\(workspaceId.uuidString)")
    }
}

/// A captain's cap, filled for a held address and outlined for an absent one.
/// Shared by workspace cards and workspace-group headers.
struct WorkspaceCaptainHat: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY + rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.68))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.68))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY + rect.height * 0.68),
                         control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1))
        return path
    }
}

private struct WorkspaceHoverCard: View {
    static let maximumRows = 40
    static let width: CGFloat = 480

    struct Row: Identifiable {
        let id: UUID
        let number: Int?
        let title: String
        let subtitle: String?
        /// C11H-278: when the subtitle (the description) was last edited.
        var descriptionUpdatedAt: Date? = nil
        let state: String
        let flagReason: String?
        let flagColor: Color?
        let mark: AnyView
    }

    let title: String
    let number: Int
    let mission: String?
    let captain: WorkspaceCaptainSummary
    let census: String
    let rows: [Row]
    let more: Int
    let fill: Color
    let style: SidebarThemeStyle
    let tokens: ChromeScaleTokens
    let maxListHeight: CGFloat?
    let onJump: (UUID) -> Void
    let onClose: () -> Void

    @State private var hovered: UUID?

    var body: some View {
        let radius = style.cardRadius ?? 8
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: style.cardTitle.apply(title))
                    .chromeStyle(style.cardTitle, size: tokens.sidebarWorkspaceTitle + 1.5, weight: .semibold)
                    .foregroundColor(style.cardText ?? .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(verbatim: "WS \(number)")
                    .chromeStyle(style.cardLabel, size: tokens.sidebarWorkspaceDetail, weight: .medium, design: .monospaced)
                    .monospacedDigit()
                    .foregroundColor(style.cardTextDim ?? .secondary)
                closeButton
            }
            if let mission {
                Text(verbatim: mission)
                    .font(.system(size: tokens.sidebarWorkspaceDetail + 1))
                    .foregroundColor(style.cardTextSecondary ?? .secondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if captain.address != nil {
                Text(verbatim: captain.accessibilityDescription)
                    .font(.system(size: tokens.sidebarWorkspaceDetail, design: .monospaced))
                    .foregroundColor(style.cardTextSecondary ?? .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: style.cardLabel.apply(census))
                .chromeStyle(style.cardLabel, size: tokens.sidebarWorkspaceMetadata, design: .monospaced)
                .foregroundColor(style.cardTextDim ?? .secondary)
                .lineLimit(1)
            Rectangle()
                .fill(style.cardRule ?? Color.secondary.opacity(0.25))
                .frame(height: 1)
            if let maxListHeight {
                ScrollView(.vertical) { list }
                    .frame(height: maxListHeight)
            } else {
                list
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
        // A translucent card fill (Solid Fill, a theme alpha) must not show the terminal through.
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(style.cardBorder ?? Color.secondary.opacity(0.35), lineWidth: style.cardBorderPt ?? 1)
        )
    }

    private var closeButton: some View {
        let help = String(localized: "sidebar.summaryCard.close", defaultValue: "Close")
        return Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: tokens.sidebarWorkspaceDetail - 1, weight: .semibold))
                .foregroundColor(style.cardTextDim ?? .secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Text(verbatim: style.cardLabel.apply(String(
                    localized: "sidebar.workspacePulse.terminalsOnly",
                    defaultValue: "Terminals only · no agent panels"
                )))
                .chromeStyle(style.cardLabel, size: tokens.sidebarWorkspaceMetadata, design: .monospaced)
                .foregroundColor(style.cardTextDim ?? .secondary)
            }
            ForEach(rows) { row in
                rowView(row)
            }
            if more > 0 {
                Text(verbatim: String(localized: "sidebar.hoverCard.more", defaultValue: "… and \(more) more"))
                    .font(.system(size: tokens.sidebarWorkspaceDetail))
                    .foregroundColor(style.cardTextDim ?? .secondary)
                    .padding(.leading, 21 + numberColumnWidth + 7)
                    .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Five digits of the panel-number font: panel numbers never truncate.
    private var numberColumnWidth: CGFloat { Self.numberColumnWidth(size: tokens.sidebarWorkspaceMetadata) }

    @MainActor private static var numberColumnWidths: [CGFloat: CGFloat] = [:]

    @MainActor private static func numberColumnWidth(size: CGFloat) -> CGFloat {
        if let width = numberColumnWidths[size] { return width }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let width = ceil(("00000" as NSString).size(withAttributes: [.font: font]).width) + 2
        numberColumnWidths[size] = width
        return width
    }

    private func rowView(_ row: Row) -> some View {
        let jumpHelp = String(localized: "sidebar.hoverCard.jump", defaultValue: "Jump to this agent's panel")
        let bodySize = tokens.sidebarWorkspaceDetail + 1
        return Button { onJump(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                row.mark
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(verbatim: row.number.map(String.init) ?? "\u{2014}")
                    .font(.system(size: tokens.sidebarWorkspaceMetadata, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(style.cardTextDim ?? .secondary)
                    .lineLimit(1)
                    .frame(width: numberColumnWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: row.title)
                            .font(.system(size: bodySize, weight: .medium))
                            .foregroundColor(style.cardText ?? .primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        // C11H-278: the description's age, a fixed slot
                        // every row keeps so the state column lines up.
                        DescriptionAgeLabel(
                            updatedAt: row.descriptionUpdatedAt,
                            style: .full,
                            fontSize: tokens.sidebarWorkspaceMetadata,
                            color: style.cardTextDim ?? .secondary
                        )
                        Text(verbatim: row.state)
                            .font(.system(size: tokens.sidebarWorkspaceMetadata, design: .monospaced))
                            .foregroundColor(style.cardTextDim ?? .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let reason = row.flagReason {
                        Text(verbatim: reason)
                            .font(.system(size: bodySize, weight: .medium))
                            .foregroundColor(row.flagColor ?? style.stateFlag ?? .purple)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle = row.subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: bodySize - 0.5))
                            .foregroundColor(style.cardTextSecondary ?? .secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((style.cardText ?? .primary).opacity(hovered == row.id ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .help(jumpHelp)
        .accessibilityLabel(Text(verbatim: [row.title, row.flagReason, row.subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text(verbatim: jumpHelp))
        .padding(.horizontal, -6)
    }
}

/// A borderless panel that never becomes key, so the open card never takes a
/// keystroke away from a terminal.
private final class WorkspaceHoverCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click without activating.
private final class WorkspaceHoverCardHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One workspace summary card for the whole app. A compact card's info button
/// opens it beside that row, and it stays until the same button, its close
/// button, Escape, a click anywhere outside it and its row, a jump, a drag,
/// its row scrolling out of view, its window closing, or c11 losing focus
/// closes it. While open it follows its row and the workspace's live state.
@MainActor
final class WorkspaceHoverCardController {
    static let shared = WorkspaceHoverCardController()
    static let rowGap: CGFloat = 12
    static let screenMargin: CGFloat = 8
    /// Live state rebuilds the card at most this often.
    static let refreshInterval: TimeInterval = 0.25

    private var panel: NSPanel?
    private var host: WorkspaceHoverCardHostingView?
    private weak var anchor: NSView?
    private var shownWorkspaceId: UUID?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var anchorObservers: [NSObjectProtocol] = []
    private var pendingRefresh: ((CGFloat?) -> AnyView)?
    private var refreshScheduled = false
    private var lastRefresh: TimeInterval = 0
    /// The open card's current content and its text key, polled once a second
    /// for what the sidebar does not republish (a panel's description).
    private var currentContent: ((CGFloat?) -> AnyView)?
    private var liveKey: (() -> Int)?
    private var lastLiveKey: Int?
    private var liveTimer: Timer?
    /// Bumped on every dismiss, so work queued for an earlier card is dropped.
    private var generation = 0
    private weak var observedClip: NSClipView?
    private var clipPostedBounds = false

    func toggle(workspaceId: UUID, anchor: NSView?, liveKey: @escaping () -> Int,
                content: @escaping (CGFloat?) -> AnyView) {
        if shownWorkspaceId == workspaceId {
            dismiss()
            return
        }
        guard let anchor else { return }
        if shownWorkspaceId != nil { dismiss() }
        self.liveKey = liveKey
        present(workspaceId: workspaceId, anchor: anchor, content: content)
    }

    /// Rebuilds the open card from the row's current state, coalesced so a
    /// busy workspace updates it a few times a second at most.
    func refresh(workspaceId: UUID, liveKey: @escaping () -> Int, content: @escaping (CGFloat?) -> AnyView) {
        guard shownWorkspaceId == workspaceId else { return }
        self.liveKey = liveKey
        pendingRefresh = content
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let wait = max(0, lastRefresh + Self.refreshInterval - ProcessInfo.processInfo.systemUptime)
        let generation = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.refreshScheduled = false
                guard let content = self.pendingRefresh, let workspaceId = self.shownWorkspaceId,
                      let anchor = self.anchor else { return }
                self.pendingRefresh = nil
                self.present(workspaceId: workspaceId, anchor: anchor, content: content)
            }
        }
    }

    /// Only the row whose card is open can close it by going away.
    func rowGone(workspaceId: UUID) {
        if workspaceId == shownWorkspaceId { dismiss() }
    }

    func dismiss() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        anchorObservers.forEach(NotificationCenter.default.removeObserver)
        anchorObservers = []
        if clipPostedBounds { observedClip?.postsBoundsChangedNotifications = false }
        observedClip = nil
        clipPostedBounds = false
        generation += 1
        refreshScheduled = false
        pendingRefresh = nil
        liveTimer?.invalidate()
        liveTimer = nil
        currentContent = nil
        liveKey = nil
        lastLiveKey = nil
        shownWorkspaceId = nil
        anchor = nil
        WorkspaceSummaryCardState.shared.set(nil)
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Release the card's views, so nothing hidden keeps observing or
        // animating; on the next turn, because a click in the card itself may
        // be what dismissed it, and its hosting view is still on the stack.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.isVisible, self.shownWorkspaceId == nil else { return }
            panel.contentView = nil
            self.host = nil
        }
    }

    /// Opens the card, or updates the open one in place: the same hosting view
    /// takes the new content, so its scroll position, row highlight and a
    /// click in progress survive a live update.
    private func present(workspaceId: UUID, anchor: NSView, content: @escaping (CGFloat?) -> AnyView) {
        guard let window = anchor.window, window.isVisible, !anchor.visibleRect.isEmpty else {
            dismiss()
            return
        }
        lastRefresh = ProcessInfo.processInfo.systemUptime
        currentContent = content
        lastLiveKey = liveKey?()
        let panel = self.panel ?? makePanel()
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let maxHeight = (visible?.height ?? 900) - 2 * Self.screenMargin

        // Too tall for the screen: measure the card without its list, and let
        // the list scroll in what remains. Measured off screen, so the live
        // card is replaced once.
        var cap: CGFloat?
        if WorkspaceHoverCardHostingView(rootView: content(nil)).fittingSize.height > maxHeight {
            let chrome = WorkspaceHoverCardHostingView(rootView: content(0)).fittingSize.height
            cap = max(0, maxHeight - chrome)
        }
        let host: WorkspaceHoverCardHostingView
        if let existing = self.host, shownWorkspaceId == workspaceId, panel.contentView === existing {
            existing.rootView = content(cap)
            host = existing
        } else {
            host = WorkspaceHoverCardHostingView(rootView: content(cap))
            panel.contentView = host
            self.host = host
        }
        panel.appearance = window.effectiveAppearance
        let size = host.fittingSize
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.level = window.level
        let isNew = shownWorkspaceId != workspaceId || self.anchor !== anchor
        self.anchor = anchor
        shownWorkspaceId = workspaceId
        position(size: size)
        panel.orderFront(nil)
        WorkspaceSummaryCardState.shared.set(workspaceId)
        installEventMonitor()
        if isNew { observeAnchor(anchor, window: window) }
        startLiveTimer()
    }

    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLiveKey() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func checkLiveKey() {
        guard let workspaceId = shownWorkspaceId, let anchor, let content = pendingRefresh ?? currentContent,
              let key = liveKey?(), key != lastLiveKey, !refreshScheduled else { return }
        pendingRefresh = nil
        present(workspaceId: workspaceId, anchor: anchor, content: content)
    }

    /// Beside the row, top edges level, inside the screen.
    private func position(size: NSSize? = nil) {
        guard let panel, let anchor, let window = anchor.window else { return }
        if anchor.visibleRect.isEmpty {
            // A reflow can hide the row for one layout pass; close only if it
            // is still hidden once layout settles, and never inside that pass.
            let generation = self.generation
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, let anchor = self.anchor else { return }
                    if anchor.window == nil || anchor.visibleRect.isEmpty {
                        self.dismiss()
                    } else {
                        self.position()
                    }
                }
            }
            return
        }
        let size = size ?? panel.frame.size
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = NSPoint(x: row.maxX + Self.rowGap, y: row.maxY - size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(origin.x, visible.maxX - size.width - Self.screenMargin)
            origin.y = max(min(origin.y, visible.maxY - size.height - Self.screenMargin),
                           visible.minY + Self.screenMargin)
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The card follows its row while the sidebar scrolls or the window moves
    /// or resizes, closes when the row scrolls out of view, and closes with
    /// its window.
    private func observeAnchor(_ anchor: NSView, window: NSWindow) {
        anchorObservers.forEach(NotificationCenter.default.removeObserver)
        anchorObservers = []
        if clipPostedBounds { observedClip?.postsBoundsChangedNotifications = false }
        observedClip = nil
        clipPostedBounds = false
        let center = NotificationCenter.default
        let follow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        if let clip = anchor.enclosingScrollView?.contentView {
            if !clip.postsBoundsChangedNotifications {
                clip.postsBoundsChangedNotifications = true
                clipPostedBounds = true
            }
            observedClip = clip
            anchorObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                      object: clip, queue: .main, using: follow))
        }
        anchor.postsFrameChangedNotifications = true
        anchorObservers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                  object: anchor, queue: .main, using: follow))
        anchorObservers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                  object: window, queue: .main, using: follow))
        anchorObservers.append(center.addObserver(forName: NSWindow.didMoveNotification,
                                                  object: window, queue: .main, using: follow))
        anchorObservers.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    /// A click outside the card and its own row closes it; the row's clicks
    /// belong to the row (its info button toggles the card, selecting the
    /// workspace closes it). Escape in the card's window closes it, and the
    /// key still reaches the terminal unless the pointer is over the card or
    /// its row, so Escape typed at an agent keeps its meaning. Escape while
    /// composing text (IME) is left alone.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, panel.isVisible else { return false }
                if event.type == .keyDown {
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    guard event.keyCode == 53, modifiers.isEmpty,
                          let parent = panel.parent, event.window === parent else { return false }
                    if let input = parent.firstResponder as? NSTextInputClient, input.hasMarkedText() {
                        return false
                    }
                    let pointer = NSEvent.mouseLocation
                    let overCard = panel.frame.contains(pointer) || self.anchorScreenRect()?.contains(pointer) == true
                    self.dismiss()
                    return overCard
                }
                if event.window === panel { return false }
                if let anchor = self.anchor, event.window === anchor.window {
                    let point = anchor.convert(event.locationInWindow, from: nil)
                    if anchor.visibleRect.contains(point) { return false }
                }
                self.dismiss()
                return false
            }
            return swallow ? nil : event
        }
    }

    private func anchorScreenRect() -> NSRect? {
        guard let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.visibleRect, to: nil))
    }

    private func makePanel() -> NSPanel {
        let panel = WorkspaceHoverCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: WorkspaceHoverCard.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityIdentifier("SidebarWorkspaceSummaryCard")
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        self.panel = panel
        return panel
    }
}
