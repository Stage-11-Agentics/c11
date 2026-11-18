import AppKit
import Foundation
import SwiftUI

public struct PanelId: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct WindowId: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum WorkspaceFrameUrgency: String, Sendable, Equatable {
    case low
    case medium
    case high
}

/// Structural state primitive for the outer workspace frame. v1 ships `.idle`
/// only; the remaining cases reserve API surface for M5+ source-attributed
/// expression (drop targets, ambient pulses, cross-window echo) per §7.3 of
/// the theming plan. The view animates all `state` transitions with SwiftUI
/// implicit animation so M5 can light up motion without re-plumbing callers.
public enum WorkspaceFrameState: Sendable, Equatable {
    case idle
    case dropTarget(source: PanelId? = nil)
    case notifying(WorkspaceFrameUrgency, source: PanelId? = nil)
    case mirroring(peer: WindowId? = nil)
}

/// Outer content-area frame. Renders a hairline stroke coloured from
/// `theme.chrome.windowFrame.color` with opacity modulated by
/// workspace/window focus state. A corner is rounded only where it sits on
/// one of the window's own rounded corners; every other corner (beside the
/// sidebar, under the titlebar) is square, so it agrees with the square tab
/// strip and panel edges it frames. Same policy as the portal's copy of the
/// frame (`PortalWorkspaceFrameOverlay`). Attaches as a SwiftUI `.overlay` and is
/// always `allowsHitTesting(false)` — terminal typing-latency paths don't see
/// it, portal-hosted terminals stay above it in z-order, and divider drags
/// route through untouched.
///
/// Read-only dependency on `ThemeManager.shared.version` so theme swaps and
/// workspace-color edits re-resolve without explicit view invalidation.
struct WorkspaceFrame: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var themeManager: ThemeManager
    let isWorkspaceActive: Bool
    let isWindowFocused: Bool
    var state: WorkspaceFrameState = .idle

    /// Kill switch per plan §8.1 — when the operator flips
    /// `theme.workspaceFrame.enabled` off, the overlay collapses to EmptyView
    /// without touching downstream layout.
    @AppStorage(ThemeAppStorage.Keys.workspaceFrameEnabled, store: ThemeAppStorage.defaults)
    private var workspaceFrameEnabled: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    /// c11 (C11H-197): the hosting window's theme override.
    @Environment(\.c11WindowThemeName) private var windowThemeName

    /// Which corners meet the hosting window's rounded corners, measured in
    /// AppKit by `WorkspaceFrameCornerProbe`. Square until the first report.
    @State private var corners: WorkspaceFrameCorners = .square

    var body: some View {
        if workspaceFrameEnabled && themeManager.isEnabled {
            idleFrame
                .allowsHitTesting(false)
                // Read `themeManager.version` so the overlay invalidates on any
                // ThemeManager refresh (theme swap, runtime disable toggle,
                // Ghostty background change). Narrow per-section subscriptions
                // land in M5 per §6.4 if profiling shows over-invalidation.
                .id(themeManager.version)
        } else {
            EmptyView()
        }
    }

    // MARK: - Rendering

    @ViewBuilder
    private var idleFrame: some View {
        let context = themeManager.makeContext(
            workspaceColor: workspace.customColor,
            colorScheme: colorScheme,
            isWindowFocused: isWindowFocused,
            windowThemeName: windowThemeName
        )

        let strokeColor = resolveStrokeColor(context: context)
        let thickness = resolveThickness(context: context)
        let opacity = resolveOpacity(context: context)
        let corners = self.corners

        // Circular, like the window's own corner mask: a continuous curve of
        // the same radius bulges past the mask at the diagonal.
        UnevenRoundedRectangle(
            topLeadingRadius: corners.topLeadingRadius,
            bottomLeadingRadius: corners.bottomLeadingRadius,
            bottomTrailingRadius: corners.bottomTrailingRadius,
            topTrailingRadius: corners.topTrailingRadius,
            style: .circular
        )
            .strokeBorder(Color(nsColor: strokeColor), lineWidth: thickness)
            .opacity(opacity)
            .background(
                WorkspaceFrameCornerProbe { reported in
                    if self.corners != reported { self.corners = reported }
                }
            )
            // v1 ships the decorative baseline with no motion on `state`; M5
            // flips animation on per-case to drive pulse / drop-zone brightening.
            .animation(nil, value: state)
    }

    private func resolveStrokeColor(context: ThemeContext) -> NSColor {
        themeManager.resolve(.windowFrame_color, context: context) ?? NSColor.secondaryLabelColor
    }

    private func resolveThickness(context: ThemeContext) -> CGFloat {
        (themeManager.resolve(.windowFrame_thicknessPt, context: context) as CGFloat?) ?? 1.5
    }

    private func resolveOpacity(context: ThemeContext) -> Double {
        let inactiveOpacity: Double = themeManager.resolve(.windowFrame_inactiveOpacity, context: context) ?? 0.25
        let unfocusedOpacity: Double = themeManager.resolve(.windowFrame_unfocusedOpacity, context: context) ?? 0.6

        if !isWorkspaceActive {
            return inactiveOpacity
        }
        if !isWindowFocused {
            return unfocusedOpacity
        }
        return 1.0
    }

}

/// The corners of the workspace frame that follow the window's rounded
/// corner mask. A corner is rounded, with the window's radius, only when it
/// coincides with a window corner; elsewhere a curve would cut across the
/// square tab strip and leave a wedge of tab fill outside it (C11-578).
struct WorkspaceFrameCorners: Equatable {
    var radius: CGFloat
    var topLeading: Bool
    var topTrailing: Bool
    var bottomLeading: Bool
    var bottomTrailing: Bool

    static let square = WorkspaceFrameCorners(
        radius: 0,
        topLeading: false,
        topTrailing: false,
        bottomLeading: false,
        bottomTrailing: false
    )

    var topLeadingRadius: CGFloat { topLeading ? radius : 0 }
    var topTrailingRadius: CGFloat { topTrailing ? radius : 0 }
    var bottomLeadingRadius: CGFloat { bottomLeading ? radius : 0 }
    var bottomTrailingRadius: CGFloat { bottomTrailing ? radius : 0 }

    /// `frame` and `windowBounds` are in window coordinates (AppKit, y up).
    static func resolve(
        frame: NSRect,
        windowBounds: NSRect,
        windowRadius: CGFloat
    ) -> WorkspaceFrameCorners {
        let radius = min(windowRadius, frame.width / 2, frame.height / 2)
        guard radius > 0 else { return .square }
        func onWindowCorner(_ corner: PortalWorkspaceFrameOverlay.Corner) -> Bool {
            PortalWorkspaceFrameOverlay.cornerMatchesWindow(
                corner,
                frame: frame,
                windowBounds: windowBounds
            )
        }
        let resolved = WorkspaceFrameCorners(
            radius: radius,
            topLeading: onWindowCorner(.minXMaxY),
            topTrailing: onWindowCorner(.maxXMaxY),
            bottomLeading: onWindowCorner(.minXMinY),
            bottomTrailing: onWindowCorner(.maxXMinY)
        )
        guard resolved.topLeading || resolved.topTrailing
            || resolved.bottomLeading || resolved.bottomTrailing else {
            return .square
        }
        return resolved
    }
}

/// Invisible AppKit view behind the workspace frame that measures the frame
/// against its own window (not `NSApp.mainWindow`) and reports which corners
/// sit on the window's rounded corners. Reports only on change, after the
/// current SwiftUI update, so it never mutates state mid-render.
private struct WorkspaceFrameCornerProbe: NSViewRepresentable {
    let onChange: (WorkspaceFrameCorners) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
        nsView.report()
    }

    final class ProbeView: NSView {
        var onChange: ((WorkspaceFrameCorners) -> Void)?
        private var lastReported: WorkspaceFrameCorners?
        private var windowObservers: [NSObjectProtocol] = []

        override var isOpaque: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var frame: NSRect {
            didSet { report() }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            removeWindowObservers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            lastReported = nil
            if let window {
                let center = NotificationCenter.default
                windowObservers = [
                    NSWindow.didResizeNotification,
                    NSWindow.didEnterFullScreenNotification,
                    NSWindow.didExitFullScreenNotification,
                ].map { name in
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.report()
                    }
                }
            }
            report()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            report()
        }

        deinit {
            removeWindowObservers()
        }

        private func removeWindowObservers() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
        }

        func report() {
            guard let window, let contentView = window.contentView else { return }
            let corners = WorkspaceFrameCorners.resolve(
                frame: convert(bounds, to: nil),
                windowBounds: contentView.convert(contentView.bounds, to: nil),
                windowRadius: WindowCornerRadius.resolve(for: window)
            )
            guard corners != lastReported else { return }
            lastReported = corners
            guard let onChange else { return }
            DispatchQueue.main.async { onChange(corners) }
        }
    }
}

/// The radius AppKit rounds a window's corners with. It varies by OS release
/// and window style (16pt for a titled window on macOS 26, 26pt with a
/// unified toolbar, 10pt before macOS 26) and is not on any public API or
/// layer, so it is read from the window when AppKit answers and estimated
/// otherwise. Full-screen windows have square corners.
enum WindowCornerRadius {
    private static let selector = NSSelectorFromString("_cornerRadius")

    static func resolve(for window: NSWindow?) -> CGFloat {
        if let window {
            if window.styleMask.contains(.fullScreen) { return 0 }
            // Zero outside full screen means AppKit has not laid the window
            // out yet, not that it has square corners.
            if window.responds(to: selector),
               let value = window.value(forKey: "_cornerRadius") as? NSNumber,
               CGFloat(truncating: value) > 0 {
                return CGFloat(truncating: value)
            }
        }
        if #available(macOS 26.0, *) { return 16 }
        return 10
    }
}

// MARK: - Area frames

/// Which frame an area draws under a theme's `[chrome.area]`
/// (docs/c11-theme-schema-2.md). Focus wins over waiting.
enum AreaFrameState: Equatable, Sendable {
    /// The focused area of the selected workspace.
    case focused
    /// An area holding a panel whose agent waits on the operator: the state that
    /// draws a waiting mark. A delegate that stops reads idle, so it never counts.
    case waiting
    case plain

    static func resolve(isFocusedArea: Bool, hasWaitingPanel: Bool) -> AreaFrameState {
        if isFocusedArea { return .focused }
        if hasWaitingPanel { return .waiting }
        return .plain
    }
}

/// One area's frame: a ring inside the area's bounds, `thicknessPt` deep.
struct AreaFrameStroke: Equatable {
    let color: NSColor
    let thicknessPt: CGFloat
    let cornerRadius: CGFloat
}

/// The active theme's area-frame colours. Nil from `resolve` when the theme sets
/// neither colour, which is how `stage11` and every schema-1 theme stay frameless.
struct AreaFramePalette: Equatable {
    var focus: NSColor?
    var waiting: NSColor?
    var thicknessPt: CGFloat
    var cornerRadius: CGFloat

    static let defaultThicknessPt: CGFloat = 1

    /// The stroke for an area, or nil to draw nothing. A state whose colour the
    /// theme leaves unset falls through to the next one that applies, so a theme
    /// that colours only waiting areas still frames a focused area that waits.
    func stroke(isFocusedArea: Bool, hasWaitingPanel: Bool) -> AreaFrameStroke? {
        let color: NSColor?
        switch AreaFrameState.resolve(isFocusedArea: isFocusedArea, hasWaitingPanel: hasWaitingPanel) {
        case .focused: color = focus ?? (hasWaitingPanel ? waiting : nil)
        case .waiting: color = waiting
        case .plain: color = nil
        }
        return color.map { AreaFrameStroke(color: $0, thicknessPt: thicknessPt, cornerRadius: cornerRadius) }
    }

    /// `chrome.area.focusBorder` and `waitingBorder`, `chrome.area.thicknessPt`
    /// (1 pt when unset; 0 turns frames off), and `geometry.controlRadius` for the
    /// corners (square when unset).
    static func resolve(snapshot: ResolvedThemeSnapshot, context: ThemeContext) -> AreaFramePalette? {
        let focus = snapshot.resolveStyleColor(.areaFocusBorder, context: context)
        let waiting = snapshot.resolveStyleColor(.areaWaitingBorder, context: context)
        guard focus != nil || waiting != nil else { return nil }
        let thickness = snapshot.resolveStyleNumber(.areaThicknessPt).map { CGFloat($0) } ?? defaultThicknessPt
        guard thickness > 0 else { return nil }
        let radius = snapshot.resolveStyleNumber(.controlRadius).map { CGFloat($0) } ?? 0
        return AreaFramePalette(focus: focus, waiting: waiting, thicknessPt: thickness, cornerRadius: max(0, radius))
    }

    @MainActor
    static func resolve(_ themeManager: ThemeManager, context: ThemeContext) -> AreaFramePalette? {
        guard themeManager.isEnabled else { return nil }
        return resolve(snapshot: themeManager.snapshot(for: context), context: context)
    }
}

struct AreaFrameCornerRadii: Equatable {
    var minXMinY: CGFloat
    var maxXMinY: CGFloat
    var maxXMaxY: CGFloat
    var minXMaxY: CGFloat

    init(_ radius: CGFloat) {
        minXMinY = radius
        maxXMinY = radius
        maxXMaxY = radius
        minXMaxY = radius
    }
}

/// Ring geometry in a non-flipped view's coordinates (the portal hosts').
enum AreaFrameGeometry {
    /// Whole device pixels, like the portal snaps hosted terminals, so the ring
    /// meets the terminal's edge with no seam.
    static func snapped(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let scale = max(1, scale)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return NSRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }

    /// A separate inner ring leaves one point of clear space after the outer
    /// focus/waiting ring. Frameless themes use the same one-point inset.
    static func captainRect(in rect: NSRect, outerThickness: CGFloat) -> NSRect? {
        let inset = max(0, outerThickness) + 1
        let inner = rect.insetBy(dx: inset, dy: inset)
        return inner.width >= 2 && inner.height >= 2 ? inner : nil
    }

    static func snappedThickness(_ thickness: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(1, scale)
        return max(1 / scale, (thickness * scale).rounded() / scale)
    }

    /// The theme's radius on every corner, except a corner that sits on the window's
    /// own rounded corner, which follows the window's radius so the mask cannot shave it.
    static func cornerRadii(
        for rect: NSRect,
        radius: CGFloat,
        windowCorners: PortalWindowCorners?,
        epsilon: CGFloat = 1.5
    ) -> AreaFrameCornerRadii {
        var radii = AreaFrameCornerRadii(radius)
        guard let windowCorners else { return radii }
        let window = windowCorners.bounds
        let windowRadius = max(radius, windowCorners.radius)
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= epsilon }
        if near(rect.minX, window.minX), near(rect.minY, window.minY) { radii.minXMinY = windowRadius }
        if near(rect.maxX, window.maxX), near(rect.minY, window.minY) { radii.maxXMinY = windowRadius }
        if near(rect.maxX, window.maxX), near(rect.maxY, window.maxY) { radii.maxXMaxY = windowRadius }
        if near(rect.minX, window.minX), near(rect.maxY, window.maxY) { radii.minXMaxY = windowRadius }
        return radii
    }

    /// The ring as one even-odd path: the area's outline and the outline inset by
    /// `thickness`, whose corners shrink by the same amount.
    static func ringPath(rect: NSRect, thickness: CGFloat, radii: AreaFrameCornerRadii) -> NSBezierPath {
        let path = roundedRect(rect, radii)
        let inner = rect.insetBy(dx: thickness, dy: thickness)
        if inner.width > 0, inner.height > 0 {
            var innerRadii = radii
            innerRadii.minXMinY = max(0, radii.minXMinY - thickness)
            innerRadii.maxXMinY = max(0, radii.maxXMinY - thickness)
            innerRadii.maxXMaxY = max(0, radii.maxXMaxY - thickness)
            innerRadii.minXMaxY = max(0, radii.minXMaxY - thickness)
            path.append(roundedRect(inner, innerRadii))
        }
        path.windingRule = .evenOdd
        return path
    }

    static func roundedRect(_ rect: NSRect, _ radii: AreaFrameCornerRadii) -> NSBezierPath {
        let limit = min(rect.width, rect.height) / 2
        func clamp(_ value: CGFloat) -> CGFloat { max(0, min(value, limit)) }
        let bl = clamp(radii.minXMinY), br = clamp(radii.maxXMinY)
        let tr = clamp(radii.maxXMaxY), tl = clamp(radii.minXMaxY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + bl, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - br, y: rect.minY))
        if br > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - br, y: rect.minY + br), radius: br, startAngle: 270, endAngle: 360)
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - tr))
        if tr > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - tr, y: rect.maxY - tr), radius: tr, startAngle: 0, endAngle: 90)
        }
        path.line(to: NSPoint(x: rect.minX + tl, y: rect.maxY))
        if tl > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + tl, y: rect.maxY - tl), radius: tl, startAngle: 90, endAngle: 180)
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + bl))
        if bl > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + bl, y: rect.minY + bl), radius: bl, startAngle: 180, endAngle: 270)
        }
        path.close()
        return path
    }
}

/// The AppKit end of an area's frame. It sits behind the area in bonsplit's pane
/// overlay slot, fills the area, draws nothing and takes no events. Terminals and
/// browsers are portal-hosted above all SwiftUI content, so the frame cannot be a
/// SwiftUI stroke: the portal chrome overlays find these anchors when they draw and
/// stroke their bounds above the terminal, the browser and the panel strip.
///
/// Its stroke changes only when the area's focus or waiting state, or the theme,
/// changes; nothing here runs per keystroke.
final class AreaFrameAnchorView: NSView {
    var stroke: AreaFrameStroke? {
        didSet {
            guard stroke != oldValue else { return }
            requestRedraw()
            AreaFrameRegistry.ensureOverlay(for: self)
        }
    }

    var captainStroke: AreaFrameStroke? {
        didSet {
            guard captainStroke != oldValue else { return }
            requestRedraw()
            AreaFrameRegistry.ensureOverlay(for: self)
        }
    }

    var hasFrame: Bool { stroke != nil || captainStroke != nil }

    /// How many times this anchor asked the portal overlays to redraw. SwiftUI
    /// re-lays the anchor out on every tab title change in its area, so an
    /// unchanged stroke or frame must ask for nothing.
    private(set) var redrawRequestCount = 0

    /// The frame at the last geometry check, so a re-assigned frame is a no-op.
    private var checkedFrame: NSRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkedFrame = frame
        AreaFrameRegistry.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var frame: NSRect {
        didSet { frameMayHaveChanged() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        frameMayHaveChanged()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        frameMayHaveChanged()
    }

    private func frameMayHaveChanged() {
        guard frame != checkedFrame else { return }
        checkedFrame = frame
        invalidateIfFramed()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { invalidateIfFramed() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateIfFramed()
        AreaFrameRegistry.ensureOverlay(for: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        invalidateIfFramed()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        invalidateIfFramed()
    }

    private func invalidateIfFramed() {
        guard hasFrame else { return }
        requestRedraw()
    }

    private func requestRedraw() {
        redrawRequestCount += 1
        AreaFrameRegistry.invalidate(window)
    }
}

/// Every live area-frame anchor, and the ring segments the portal overlays draw.
@MainActor
enum AreaFrameRegistry {
    private static let anchors = NSHashTable<AreaFrameAnchorView>.weakObjects()

    static func register(_ anchor: AreaFrameAnchorView) {
        anchors.add(anchor)
    }

    /// False when no area has a frame anchor.
    static var hasAnchors: Bool { anchors.count > 0 }

    /// Redraw the portal overlays of `window`. Both draw the rings: the terminal
    /// overlay all of them, the browser overlay (above it) the parts over web views.
    static func invalidate(_ window: NSWindow?) {
        guard let window else { return }
        TerminalWindowPortalRegistry.invalidateAreaFrames(for: window)
        BrowserWindowPortalRegistry.invalidateAreaFrames(for: window)
    }

    /// The terminal portal draws the rings, and a window gets one only when a
    /// terminal binds there. A framed area in a window that never held a terminal
    /// (markdown only, a browser moved out) creates it, on the next turn so the
    /// view tree is not changed while AppKit is moving the anchor.
    static func ensureOverlay(for anchor: AreaFrameAnchorView) {
        guard anchor.hasFrame, let window = anchor.window,
              !TerminalWindowPortalRegistry.hasPortal(for: window) else { return }
        DispatchQueue.main.async { [weak anchor] in
            guard let anchor, anchor.hasFrame, let window = anchor.window, window.isVisible,
                  !TerminalWindowPortalRegistry.hasPortal(for: window) else { return }
            TerminalWindowPortalRegistry.ensurePortal(for: window)
            invalidate(window)
        }
    }

    /// The anchor's bounds in window coordinates, cut to every ancestor's bounds:
    /// at tiny widths a pane's content can overflow its split slot, and the ring
    /// must stay inside the area the operator sees.
    static func visibleRectInWindow(of anchor: NSView) -> NSRect {
        var rect = anchor.convert(anchor.bounds, to: nil)
        var current = anchor.superview
        let contentView = anchor.window?.contentView
        while let ancestor = current {
            rect = rect.intersection(ancestor.convert(ancestor.bounds, to: nil))
            if rect.isNull { return .zero }
            if ancestor === contentView { break }
            current = ancestor.superview
        }
        return rect
    }

    /// Ring segments, in `host` coordinates, for each framed area visible in
    /// `host`'s window. With `clipRects`, only the parts inside those rects.
    static func segments(in host: NSView, clipRects: [NSRect]? = nil) -> [PortalChromeOverlaySegment] {
        guard let window = host.window, hasAnchors else { return [] }
        if let clipRects, clipRects.isEmpty { return [] }
        let hostBounds = host.bounds
        let scale = window.backingScaleFactor
        let windowCorners = PortalWindowCorners(window: window, hostView: host)
        var segments: [PortalChromeOverlaySegment] = []
        for anchor in anchors.allObjects {
            guard anchor.hasFrame, anchor.window === window,
                  !anchor.isHiddenOrHasHiddenAncestor else { continue }
            let rect = AreaFrameGeometry.snapped(host.convert(visibleRectInWindow(of: anchor), from: nil), scale: scale)
            guard rect.width >= 2, rect.height >= 2, rect.intersects(hostBounds) else { continue }
            let outerThickness = anchor.stroke.map {
                AreaFrameGeometry.snappedThickness($0.thicknessPt, scale: scale)
            } ?? 0
            var rings: [(NSRect, AreaFrameStroke, CGFloat)] = []
            if let stroke = anchor.stroke { rings.append((rect, stroke, 0)) }
            if let stroke = anchor.captainStroke,
               let inner = AreaFrameGeometry.captainRect(in: rect, outerThickness: outerThickness) {
                rings.append((inner, stroke, outerThickness + 1))
            }
            for (ringRect, stroke, inset) in rings {
                var radii = AreaFrameGeometry.cornerRadii(for: rect, radius: stroke.cornerRadius, windowCorners: windowCorners)
                radii.minXMinY = max(0, radii.minXMinY - inset)
                radii.maxXMinY = max(0, radii.maxXMinY - inset)
                radii.maxXMaxY = max(0, radii.maxXMaxY - inset)
                radii.minXMaxY = max(0, radii.minXMaxY - inset)
                let path = AreaFrameGeometry.ringPath(
                    rect: ringRect,
                    thickness: AreaFrameGeometry.snappedThickness(stroke.thicknessPt, scale: scale),
                    radii: radii
                )
                if let clipRects {
                    for clip in clipRects where clip.intersects(ringRect) {
                        segments.append(PortalChromeOverlaySegment(rect: ringRect.intersection(clip), color: stroke.color, path: path, clip: clip))
                    }
                } else {
                    segments.append(PortalChromeOverlaySegment(rect: ringRect, color: stroke.color, path: path))
                }
            }
        }
        return segments
    }
}
