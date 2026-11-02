import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif

private var cmuxWindowTerminalPortalKey: UInt8 = 0
private var cmuxWindowTerminalPortalCloseObserverKey: UInt8 = 0

// MARK: - C11-18 portal diagnostics
//
// Env-var-gated structured logger for portal lifecycle events. Off by default
// (zero work in shipped builds when the gate is unset). Enable with
// C11_PORTAL_DEBUG=1 (CMUX_PORTAL_DEBUG=1 also accepted, for parity with the
// existing CMUX_DEBUG_* family) to capture state during reproduction of
// C11-18 (Ghostty surface duplicated/overdraws above pane bounds during
// portal sync).
//
// Default sink: /tmp/c11-portal.log. Override with C11_PORTAL_LOG=<path>.
// First call after process start truncates the log; subsequent calls append.
// Pattern mirrors `logBackground` at Sources/GhosttyTerminalView.swift:2470-2492
// (NSLock + monotonic UInt64 sequence + open/seek-to-end/close per write).
//
// Hot-path safety: emit sites must NOT include WindowTerminalHostView.hitTest(),
// TerminalSurface.forceRefresh(), or TabItemView body. Portal lifecycle paths
// (bind / detach / hideEntry / synchronizeHostedView / external geometry sync /
// orphan hide) are off the typing/per-frame hot paths and are the only call sites.

enum C11PortalDebug {
    static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        let truthy: (String?) -> Bool = { value in
            guard let value, !value.isEmpty else { return false }
            let lowered = value.lowercased()
            return lowered != "0" && lowered != "false" && lowered != "no" && lowered != "off"
        }
        return truthy(env["C11_PORTAL_DEBUG"]) || truthy(env["CMUX_PORTAL_DEBUG"])
    }()

    static let logPath: String = {
        if let override = ProcessInfo.processInfo.environment["C11_PORTAL_LOG"], !override.isEmpty {
            return override
        }
        return "/tmp/c11-portal.log"
    }()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var sequence: UInt64 = 0
    private nonisolated(unsafe) static var hasTruncated = false
    private static let startUptime = ProcessInfo.processInfo.systemUptime
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    fileprivate static func write(event: String, fields: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        let threadLabel = Thread.isMainThread ? "main" : "bg"
        let suffix = fields.isEmpty ? "" : " \(fields)"

        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        let seq = sequence
        let line =
            "\(timestamp) seq=\(seq) t+\(String(format: "%.3f", uptimeMs))ms " +
            "thread=\(threadLabel) portal: \(event)\(suffix)\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = URL(fileURLWithPath: logPath)
        if !hasTruncated {
            hasTruncated = true
            // Truncate-on-first-call so each cold start gives the operator a clean
            // log corresponding to one repro run (avoids unbounded growth across
            // repeated `repro-c11-18.sh` invocations).
            try? Data().write(to: url)
        } else if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

/// Emit a structured portal lifecycle event when `C11_PORTAL_DEBUG` is set.
///
/// The `fields` autoclosure is only evaluated when the env-var gate is on, so
/// shipped builds pay nothing beyond the boolean check. Callers should pass a
/// pre-formatted "k=v k=v" string for the event-specific fields.
@inline(__always)
func portalLog(_ event: String, _ fields: @autoclosure () -> String = "") {
    guard C11PortalDebug.isEnabled else { return }
    C11PortalDebug.write(event: event, fields: fields())
}

/// Compact pointer token (NSView opaque pointer) for diagnostics. Stable
/// across calls for the same object instance, and empty/`nil` for missing
/// references. Available from release builds (not gated on `#if DEBUG` like
/// `portalDebugToken`).
@inline(__always)
func portalLogToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

/// Hashed handle (NOT a real pointer) for `ObjectIdentifier` diagnostics.
/// Returns a hex rendering of `id.hashValue`; comparable across log lines that
/// share the same `ObjectIdentifier` namespace, but not directly comparable to
/// the NSView pointer overload above even when both reference the same
/// underlying view.
@inline(__always)
func portalLogToken(_ id: ObjectIdentifier?) -> String {
    guard let id else { return "nil" }
    return "0x" + String(UInt(bitPattern: id.hashValue), radix: 16)
}

@inline(__always)
func portalLogFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

#if DEBUG
private func portalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

private func portalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

private func portalDebugFrameInWindow(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    guard view.window != nil else { return "no-window" }
    return portalDebugFrame(view.convert(view.bounds, to: nil))
}
#endif

final class WindowTerminalHostView: NSView {
    private struct DividerRegion {
        let rectInWindow: NSRect
        let isVertical: Bool
    }

    private enum DividerCursorKind: Equatable {
        case vertical
        case horizontal

        var cursor: NSCursor {
            switch self {
            case .vertical: return .resizeLeftRight
            case .horizontal: return .resizeUpDown
            }
        }
    }

    override var isOpaque: Bool { false }
    private static let sidebarLeadingEdgeEpsilon: CGFloat = 1
    private static let minimumVisibleLeadingContentWidth: CGFloat = 24
    private var cachedSidebarDividerX: CGFloat?
    private var sidebarDividerMissCount = 0
    private var trackingArea: NSTrackingArea?
    private var activeDividerCursorKind: DividerCursorKind?
#if DEBUG
    private var lastDragRouteSignature: String?
#endif

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        clearActiveDividerCursor(restoreArrow: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearActiveDividerCursor(restoreArrow: false)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window, let rootView = window.contentView else { return }
        var regions: [DividerRegion] = []
        Self.collectSplitDividerRegions(in: rootView, into: &regions)
        let expansion: CGFloat = 4
        for region in regions {
            var rectInHost = convert(region.rectInWindow, from: nil)
            rectInHost = rectInHost.insetBy(
                dx: region.isVertical ? -expansion : 0,
                dy: region.isVertical ? 0 : -expansion
            )
            let clipped = rectInHost.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            addCursorRect(clipped, cursor: region.isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .inVisibleRect,
            .activeAlways,
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
        ]
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateDividerCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        clearActiveDividerCursor(restoreArrow: true)
    }

    // PERF: hitTest is called on EVERY event including keyboard. Keep non-pointer
    // path minimal. Do not add work outside the isPointerEvent guard.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let currentEvent = NSApp.currentEvent
        let isPointerEvent: Bool
        switch currentEvent?.type {
        case .mouseMoved, .mouseEntered, .mouseExited,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel, .cursorUpdate:
            isPointerEvent = true
        default:
            isPointerEvent = false
        }

        if isPointerEvent {
            if shouldPassThroughToSidebarResizer(at: point) {
                clearActiveDividerCursor(restoreArrow: false)
                return nil
            }

            // Compute divider hit once and reuse for both cursor update and pass-through.
            if let kind = splitDividerCursorKind(at: point) {
                activeDividerCursorKind = kind
                kind.cursor.set()
                return nil
            }

            clearActiveDividerCursor(restoreArrow: true)

            let dragPasteboardTypes = NSPasteboard(name: .drag).types
            let eventType = currentEvent?.type
            let shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
                pasteboardTypes: dragPasteboardTypes,
                eventType: eventType
            )
            if shouldPassThrough {
#if DEBUG
                logDragRouteDecision(
                    passThrough: true,
                    eventType: eventType,
                    pasteboardTypes: dragPasteboardTypes,
                    hitView: nil
                )
#endif
                return nil
            }

            let hitView = super.hitTest(point)
#if DEBUG
            logDragRouteDecision(
                passThrough: false,
                eventType: currentEvent?.type,
                pasteboardTypes: dragPasteboardTypes,
                hitView: hitView
            )
#endif
            return hitView === self ? nil : hitView
        }

        // Non-pointer event: skip divider/drag routing, just do standard hit testing.
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }

    private func shouldPassThroughToSidebarResizer(at point: NSPoint) -> Bool {
        // The sidebar resizer handle is implemented in SwiftUI. When terminals
        // are portal-hosted, this AppKit host can otherwise sit above the handle
        // and steal hover/mouse events.
        let visibleHostedViews = subviews.compactMap { $0 as? GhosttySurfaceScrollView }
            .filter { !$0.isHidden && $0.window != nil && $0.frame.width > 1 && $0.frame.height > 1 }

        // If content is flush to the leading edge, sidebar is effectively hidden.
        // In that state, treating any internal split edge as a sidebar divider
        // steals split-divider cursor/drag behavior.
        let hasLeadingContent = visibleHostedViews.contains {
            $0.frame.minX <= Self.sidebarLeadingEdgeEpsilon
                && $0.frame.maxX > Self.minimumVisibleLeadingContentWidth
        }
        if hasLeadingContent {
            if cachedSidebarDividerX != nil {
                sidebarDividerMissCount += 1
                if sidebarDividerMissCount >= 2 {
                    cachedSidebarDividerX = nil
                    sidebarDividerMissCount = 0
                }
            }
            return false
        }

        // Ignore transient 0-origin hosts while layouts churn (e.g. workspace
        // creation/switching). They can temporarily report minX=0 and would
        // otherwise clear divider pass-through, causing hover flicker.
        let dividerCandidates = visibleHostedViews
            .map(\.frame.minX)
            .filter { $0 > Self.sidebarLeadingEdgeEpsilon }
        if let leftMostEdge = dividerCandidates.min() {
            cachedSidebarDividerX = leftMostEdge
            sidebarDividerMissCount = 0
        } else if cachedSidebarDividerX != nil {
            // Keep cache briefly for layout churn, but clear if we miss repeatedly
            // so stale divider positions don't steal pointer routing.
            sidebarDividerMissCount += 1
            if sidebarDividerMissCount >= 4 {
                cachedSidebarDividerX = nil
                sidebarDividerMissCount = 0
            }
        }

        guard let dividerX = cachedSidebarDividerX else {
            return false
        }

        let regionMinX = dividerX - SidebarResizeInteraction.hitWidthPerSide
        let regionMaxX = dividerX + SidebarResizeInteraction.hitWidthPerSide
        return point.x >= regionMinX && point.x <= regionMaxX
    }

    private func updateDividerCursor(at point: NSPoint) {
        if shouldPassThroughToSidebarResizer(at: point) {
            clearActiveDividerCursor(restoreArrow: false)
            return
        }

        guard let nextKind = splitDividerCursorKind(at: point) else {
            clearActiveDividerCursor(restoreArrow: true)
            return
        }
        activeDividerCursorKind = nextKind
        nextKind.cursor.set()
    }

    private func clearActiveDividerCursor(restoreArrow: Bool) {
        guard activeDividerCursorKind != nil else { return }
        window?.invalidateCursorRects(for: self)
        activeDividerCursorKind = nil
        if restoreArrow {
            NSCursor.arrow.set()
        }
    }

    private func splitDividerCursorKind(at point: NSPoint) -> DividerCursorKind? {
        guard let window else { return nil }
        let windowPoint = convert(point, to: nil)
        guard let rootView = window.contentView else { return nil }
        return Self.dividerCursorKind(at: windowPoint, in: rootView)
    }

    private func shouldPassThroughToSplitDivider(at point: NSPoint) -> Bool {
        splitDividerCursorKind(at: point) != nil
    }

    private static func dividerCursorKind(at windowPoint: NSPoint, in view: NSView) -> DividerCursorKind? {
        guard !view.isHidden else { return nil }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
                // Keep divider interactions reliable even when portal-hosted terminal frames
                // temporarily overlap divider edges during rapid layout churn.
                let expansion: CGFloat = 5
                let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
                for dividerIndex in 0..<dividerCount {
                    let first = splitView.arrangedSubviews[dividerIndex].frame
                    let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                    let thickness = splitView.dividerThickness
                    let dividerRect: NSRect
                    if splitView.isVertical {
                        // Keep divider hit-testing active even when one side is nearly collapsed,
                        // so users can drag the divider back out from the border.
                        // But ignore transient states where both panes are effectively 0-width.
                        guard first.width > 1 || second.width > 1 else { continue }
                        let x = max(0, first.maxX)
                        dividerRect = NSRect(
                            x: x,
                            y: 0,
                            width: thickness,
                            height: splitView.bounds.height
                        )
                    } else {
                        // Same behavior for horizontal splits with a near-zero-height pane.
                        guard first.height > 1 || second.height > 1 else { continue }
                        let y = max(0, first.maxY)
                        dividerRect = NSRect(
                            x: 0,
                            y: y,
                            width: splitView.bounds.width,
                            height: thickness
                        )
                    }
                    let expandedDividerRect = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expandedDividerRect.contains(pointInSplit) {
                        return splitView.isVertical ? .vertical : .horizontal
                    }
                }
            }
        }

        for subview in view.subviews.reversed() {
            if let kind = dividerCursorKind(at: windowPoint, in: subview) {
                return kind
            }
        }

        return nil
    }

    private static func collectSplitDividerRegions(in view: NSView, into result: inout [DividerRegion]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                let thickness = splitView.dividerThickness
                let dividerRect: NSRect
                if splitView.isVertical {
                    guard first.width > 1 || second.width > 1 else { continue }
                    let x = max(0, first.maxX)
                    dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
                } else {
                    guard first.height > 1 || second.height > 1 else { continue }
                    let y = max(0, first.maxY)
                    dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
                }
                let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
                guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
                result.append(
                    DividerRegion(
                        rectInWindow: dividerRectInWindow,
                        isVertical: splitView.isVertical
                    )
                )
            }
        }

        for subview in view.subviews {
            collectSplitDividerRegions(in: subview, into: &result)
        }
    }

#if DEBUG
    private func logDragRouteDecision(
        passThrough: Bool,
        eventType: NSEvent.EventType?,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        hitView: NSView?
    ) {
        let hasRelevantTypes = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarWorkspaceReorder(pasteboardTypes)
        guard passThrough || hasRelevantTypes else { return }

        let targetClass = hitView.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let signature = [
            passThrough ? "1" : "0",
            debugEventName(eventType),
            debugPasteboardTypes(pasteboardTypes),
            targetClass,
        ].joined(separator: "|")
        guard lastDragRouteSignature != signature else { return }
        lastDragRouteSignature = signature

        dlog(
            "portal.dragRoute passThrough=\(passThrough ? 1 : 0) " +
            "event=\(debugEventName(eventType)) target=\(targetClass) " +
            "types=\(debugPasteboardTypes(pasteboardTypes))"
        )
    }

    private func debugPasteboardTypes(_ types: [NSPasteboard.PasteboardType]?) -> String {
        guard let types, !types.isEmpty else { return "-" }
        return types.map(\.rawValue).joined(separator: ",")
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
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDragged: return "otherMouseDragged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        default: return "other(\(eventType.rawValue))"
        }
    }
#endif
}

struct PortalChromeOverlaySegment {
    let rect: NSRect
    let color: NSColor
    /// A rounded frame corner. When set, the overlay fills this path instead
    /// of `rect`, which then only bounds it for dirty-rect checks.
    var path: NSBezierPath? = nil
}

/// The rounded corners of the window that hosts a portal, in the portal
/// host's coordinates.
struct PortalWindowCorners {
    let bounds: NSRect
    let radius: CGFloat

    init(bounds: NSRect, radius: CGFloat) {
        self.bounds = bounds
        self.radius = radius
    }

    init?(window: NSWindow?, hostView: NSView) {
        guard let window, let contentView = window.contentView else { return nil }
        let radius = WindowCornerRadius.resolve(for: window)
        guard radius > 0 else { return nil }
        self.bounds = hostView.convert(contentView.bounds, from: contentView)
        self.radius = radius
    }
}

struct PortalChromeOverlayDividerSegment {
    let rect: NSRect
    let isVertical: Bool
}

struct PortalWorkspaceFrameEdges: Equatable {
    let leading: Bool
    let trailing: Bool
    let bottom: Bool
    let top: Bool

    init(
        leading: Bool = true,
        trailing: Bool = true,
        bottom: Bool = true,
        top: Bool = true
    ) {
        self.leading = leading
        self.trailing = trailing
        self.bottom = bottom
        self.top = top
    }

    static let all = PortalWorkspaceFrameEdges()
}

struct PortalWorkspaceFrameStyle: Equatable {
    let colorHex: String
    let thicknessPt: CGFloat
    let opacity: Double
    let edges: PortalWorkspaceFrameEdges

    init(
        colorHex: String,
        thicknessPt: CGFloat,
        opacity: Double,
        edges: PortalWorkspaceFrameEdges = .all
    ) {
        self.colorHex = colorHex
        self.thicknessPt = thicknessPt
        self.opacity = opacity
        self.edges = edges
    }
}

enum PortalWorkspaceFrameOverlay {
    static func color(from style: PortalWorkspaceFrameStyle) -> NSColor? {
        guard let base = NSColor(hex: style.colorHex) else { return nil }
        let alpha = base.alphaComponent * CGFloat(max(0, min(1, style.opacity)))
        return base.withAlphaComponent(alpha)
    }

    static func appendWorkspaceFrameSegments(
        for frame: NSRect,
        hostBounds: NSRect,
        style: PortalWorkspaceFrameStyle,
        color: NSColor,
        dividerSegments: [PortalChromeOverlayDividerSegment],
        windowCorners: PortalWindowCorners? = nil,
        into segments: inout [PortalChromeOverlaySegment]
    ) {
        let visibleFrame = frame.intersection(hostBounds)
        guard !visibleFrame.isNull,
              visibleFrame.width > 1,
              visibleFrame.height > 1 else {
            return
        }

        // The overlay fills strips pixel-aligned (whole points). Align here
        // too, so corner arcs, which are filled as paths, meet the strips
        // with the same thickness and no seam.
        let thickness = max(1, style.thicknessPt.rounded())
        let edgeFrame = NSRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.maxX.rounded() - frame.minX.rounded(),
            height: frame.maxY.rounded() - frame.minY.rounded()
        )

        func appendClipped(_ rect: NSRect) {
            let clipped = rect.intersection(hostBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            segments.append(PortalChromeOverlaySegment(rect: clipped, color: color))
        }

        let drawsLeading = style.edges.leading
            && !edgeTouchesDivider(.leading, frame: frame, dividerSegments: dividerSegments)
        let drawsTrailing = style.edges.trailing
            && !edgeTouchesDivider(.trailing, frame: frame, dividerSegments: dividerSegments)
        let drawsBottom = style.edges.bottom
            && !edgeTouchesDivider(.bottom, frame: frame, dividerSegments: dividerSegments)
        let drawsTop = style.edges.top
            && !edgeTouchesDivider(.top, frame: frame, dividerSegments: dividerSegments)

        // Where the frame meets a rounded window corner, straight strips run
        // into the window's corner mask and get shaved away at the diagonal.
        // Draw that corner as an arc concentric with the window instead.
        let radius = windowCorners.map { min($0.radius, edgeFrame.width / 2, edgeFrame.height / 2) } ?? 0
        func roundsCorner(_ corner: Corner, _ firstEdge: Bool, _ secondEdge: Bool) -> Bool {
            guard let windowCorners, radius > thickness, firstEdge, secondEdge else { return false }
            return cornerMatchesWindow(corner, frame: edgeFrame, windowBounds: windowCorners.bounds)
        }
        let roundsMinXMinY = roundsCorner(.minXMinY, drawsLeading, drawsBottom)
        let roundsMaxXMinY = roundsCorner(.maxXMinY, drawsTrailing, drawsBottom)
        let roundsMinXMaxY = roundsCorner(.minXMaxY, drawsLeading, drawsTop)
        let roundsMaxXMaxY = roundsCorner(.maxXMaxY, drawsTrailing, drawsTop)

        if drawsLeading {
            let minY = edgeFrame.minY + (roundsMinXMinY ? radius : 0)
            let maxY = edgeFrame.maxY - (roundsMinXMaxY ? radius : 0)
            appendClipped(NSRect(x: edgeFrame.minX, y: minY, width: thickness, height: maxY - minY))
        }
        if drawsTrailing {
            let minY = edgeFrame.minY + (roundsMaxXMinY ? radius : 0)
            let maxY = edgeFrame.maxY - (roundsMaxXMaxY ? radius : 0)
            appendClipped(NSRect(x: edgeFrame.maxX - thickness, y: minY, width: thickness, height: maxY - minY))
        }
        if drawsBottom {
            let minX = edgeFrame.minX + (roundsMinXMinY ? radius : 0)
            let maxX = edgeFrame.maxX - (roundsMaxXMinY ? radius : 0)
            appendClipped(NSRect(x: minX, y: edgeFrame.minY, width: maxX - minX, height: thickness))
        }
        if drawsTop {
            let minX = edgeFrame.minX + (roundsMinXMaxY ? radius : 0)
            let maxX = edgeFrame.maxX - (roundsMaxXMaxY ? radius : 0)
            appendClipped(NSRect(x: minX, y: edgeFrame.maxY - thickness, width: maxX - minX, height: thickness))
        }

        for (corner, rounds) in [
            (Corner.minXMinY, roundsMinXMinY),
            (.maxXMinY, roundsMaxXMinY),
            (.minXMaxY, roundsMinXMaxY),
            (.maxXMaxY, roundsMaxXMaxY),
        ] where rounds {
            let segment = cornerArcSegment(corner, frame: edgeFrame, radius: radius, thickness: thickness, color: color)
            if segment.rect.intersects(hostBounds) {
                segments.append(segment)
            }
        }
    }

    enum Corner {
        case minXMinY
        case maxXMinY
        case minXMaxY
        case maxXMaxY
    }

    private static func cornerMatchesWindow(
        _ corner: Corner,
        frame: NSRect,
        windowBounds: NSRect,
        epsilon: CGFloat = 1.5
    ) -> Bool {
        let (frameX, frameY, windowX, windowY): (CGFloat, CGFloat, CGFloat, CGFloat)
        switch corner {
        case .minXMinY: (frameX, frameY, windowX, windowY) = (frame.minX, frame.minY, windowBounds.minX, windowBounds.minY)
        case .maxXMinY: (frameX, frameY, windowX, windowY) = (frame.maxX, frame.minY, windowBounds.maxX, windowBounds.minY)
        case .minXMaxY: (frameX, frameY, windowX, windowY) = (frame.minX, frame.maxY, windowBounds.minX, windowBounds.maxY)
        case .maxXMaxY: (frameX, frameY, windowX, windowY) = (frame.maxX, frame.maxY, windowBounds.maxX, windowBounds.maxY)
        }
        return abs(frameX - windowX) <= epsilon && abs(frameY - windowY) <= epsilon
    }

    /// A quarter ring hugging the window's corner: outer radius `radius`,
    /// inner radius `radius - thickness`, joining the shortened edge strips.
    static func cornerArcSegment(
        _ corner: Corner,
        frame: NSRect,
        radius: CGFloat,
        thickness: CGFloat,
        color: NSColor
    ) -> PortalChromeOverlaySegment {
        let center: NSPoint
        let startAngle: CGFloat
        let box: NSRect
        switch corner {
        case .minXMinY:
            center = NSPoint(x: frame.minX + radius, y: frame.minY + radius)
            startAngle = 180
            box = NSRect(x: frame.minX, y: frame.minY, width: radius, height: radius)
        case .maxXMinY:
            center = NSPoint(x: frame.maxX - radius, y: frame.minY + radius)
            startAngle = 270
            box = NSRect(x: frame.maxX - radius, y: frame.minY, width: radius, height: radius)
        case .minXMaxY:
            center = NSPoint(x: frame.minX + radius, y: frame.maxY - radius)
            startAngle = 90
            box = NSRect(x: frame.minX, y: frame.maxY - radius, width: radius, height: radius)
        case .maxXMaxY:
            center = NSPoint(x: frame.maxX - radius, y: frame.maxY - radius)
            startAngle = 0
            box = NSRect(x: frame.maxX - radius, y: frame.maxY - radius, width: radius, height: radius)
        }
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle + 90)
        path.appendArc(
            withCenter: center,
            radius: radius - thickness,
            startAngle: startAngle + 90,
            endAngle: startAngle,
            clockwise: true
        )
        path.close()
        return PortalChromeOverlaySegment(rect: box, color: color, path: path)
    }

    enum Edge {
        case leading
        case trailing
        case bottom
        case top
    }

    static func edgeTouchesDivider(
        _ edge: Edge,
        frame: NSRect,
        dividerSegments: [PortalChromeOverlayDividerSegment],
        epsilon: CGFloat = 1.5
    ) -> Bool {
        switch edge {
        case .leading, .trailing:
            let x = edge == .leading ? frame.minX : frame.maxX
            return dividerSegments.contains { segment in
                guard segment.isVertical else { return false }
                guard rangesOverlap(
                    frame.minY...frame.maxY,
                    segment.rect.minY...segment.rect.maxY,
                    epsilon: epsilon
                ) else { return false }
                return x >= segment.rect.minX - epsilon && x <= segment.rect.maxX + epsilon
            }
        case .bottom, .top:
            let y = edge == .bottom ? frame.minY : frame.maxY
            return dividerSegments.contains { segment in
                guard !segment.isVertical else { return false }
                guard rangesOverlap(
                    frame.minX...frame.maxX,
                    segment.rect.minX...segment.rect.maxX,
                    epsilon: epsilon
                ) else { return false }
                return y >= segment.rect.minY - epsilon && y <= segment.rect.maxY + epsilon
            }
        }
    }

    private static func rangesOverlap(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>,
        epsilon: CGFloat
    ) -> Bool {
        lhs.upperBound >= rhs.lowerBound - epsilon &&
            lhs.lowerBound <= rhs.upperBound + epsilon
    }
}

final class PortalSplitDividerOverlayView: NSView {
    enum OcclusionPolicy {
        case crossingCenterline
        case touchingSegment
    }

    private struct DividerSegment {
        let rect: NSRect
        let color: NSColor
        let isVertical: Bool
    }

    var hostedFrameProvider: ((NSView) -> [NSRect])?
    var chromeSegmentProvider: ((NSView, [PortalChromeOverlayDividerSegment]) -> [PortalChromeOverlaySegment])?

    private let occlusionPolicy: OcclusionPolicy

    init(frame frameRect: NSRect, occlusionPolicy: OcclusionPolicy = .crossingCenterline) {
        self.occlusionPolicy = occlusionPolicy
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window, let rootView = window.contentView else { return }

        var dividerSegments: [DividerSegment] = []
        collectDividerSegments(in: rootView, into: &dividerSegments)
        let chromeDividerSegments = dividerSegments.map {
            PortalChromeOverlayDividerSegment(rect: $0.rect, isVertical: $0.isVertical)
        }
        let chromeSegments = superview.map {
            chromeSegmentProvider?($0, chromeDividerSegments) ?? []
        } ?? []
        let visibleSegments: [DividerSegment]
        if dividerSegments.isEmpty {
            visibleSegments = []
        } else {
            let hostedFrames = hostedFramesLikelyToOccludeDividers()
            visibleSegments = dividerSegments.filter { shouldRenderOverlay(for: $0, hostedFrames: hostedFrames) }
        }
        guard !visibleSegments.isEmpty || !chromeSegments.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Keep separators visible above portal-hosted surfaces while matching each split view's
        // native divider color (avoids visible color shifts at tiny pane sizes).
        for segment in visibleSegments where segment.rect.intersects(dirtyRect) {
            segment.color.setFill()
            NSBezierPath(rect: Self.pixelAligned(segment.rect)).fill()
        }

        for segment in chromeSegments where segment.rect.intersects(dirtyRect) {
            segment.color.setFill()
            if let path = segment.path {
                path.fill()
            } else {
                NSBezierPath(rect: Self.pixelAligned(segment.rect)).fill()
            }
        }
    }

    private func collectDividerSegments(in view: NSView, into result: inout [DividerSegment]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            let dividerColor = Self.overlayDividerColor(for: splitView)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let thickness = max(splitView.dividerThickness, 1)
                let dividerRectInSplit: NSRect
                if splitView.isVertical {
                    dividerRectInSplit = NSRect(
                        x: first.maxX,
                        y: 0,
                        width: thickness,
                        height: splitView.bounds.height
                    )
                } else {
                    dividerRectInSplit = NSRect(
                        x: 0,
                        y: first.maxY,
                        width: splitView.bounds.width,
                        height: thickness
                    )
                }

                let dividerRectInWindow = splitView.convert(dividerRectInSplit, to: nil)
                let dividerRectInOverlay = convert(dividerRectInWindow, from: nil)
                if dividerRectInOverlay.intersects(bounds) {
                    result.append(
                        DividerSegment(
                            rect: dividerRectInOverlay,
                            color: dividerColor,
                            isVertical: splitView.isVertical
                        )
                    )
                }
            }
        }

        for subview in view.subviews {
            collectDividerSegments(in: subview, into: &result)
        }
    }

    private func hostedFramesLikelyToOccludeDividers() -> [NSRect] {
        guard let hostView = superview else { return [] }
        if let hostedFrameProvider {
            return hostedFrameProvider(hostView)
        }
        return hostView.subviews.compactMap { subview -> NSRect? in
            guard let hosted = subview as? GhosttySurfaceScrollView else { return nil }
            guard !hosted.isHidden, hosted.window != nil else { return nil }
            return hosted.frame
        }
    }

    private func shouldRenderOverlay(for segment: DividerSegment, hostedFrames: [NSRect]) -> Bool {
        switch occlusionPolicy {
        case .crossingCenterline:
            return hostedFrames.contains { hostedFrameCrossesDividerCenterline($0, segment: segment) }
        case .touchingSegment:
            let expanded = segment.rect.insetBy(
                dx: segment.isVertical ? -1 : 0,
                dy: segment.isVertical ? 0 : -1
            )
            return hostedFrames.contains { Self.rect($0, touches: expanded) }
        }
    }

    private func hostedFrameCrossesDividerCenterline(_ frame: NSRect, segment: DividerSegment) -> Bool {
        // Draw only when a hosted surface actually intrudes across the divider centerline.
        // This preserves tiny-pane visibility fixes without darkening regular dividers.
        let axisEpsilon: CGFloat = 0.01
        let axis = segment.isVertical ? segment.rect.midX : segment.rect.midY
        let extentRect = segment.rect.insetBy(
            dx: segment.isVertical ? 0 : -1,
            dy: segment.isVertical ? -1 : 0
        )

        guard frame.intersects(extentRect) else { return false }
        if segment.isVertical {
            if frame.minX < axis - axisEpsilon && frame.maxX > axis + axisEpsilon {
                return true
            }
        } else if frame.minY < axis - axisEpsilon && frame.maxY > axis + axisEpsilon {
            return true
        }
        return false
    }

    fileprivate static func overlayDividerColor(for splitView: NSSplitView) -> NSColor {
        let divider = splitView.dividerColor.usingColorSpace(.deviceRGB) ?? splitView.dividerColor
        let alpha = divider.alphaComponent
        guard alpha < 0.999 else { return divider }

        guard let bgColor = splitView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
              let bgRGB = bgColor.usingColorSpace(.deviceRGB) else {
            return divider
        }

        let opaqueBG = bgRGB.withAlphaComponent(1)
        let opaqueDivider = divider.withAlphaComponent(1)
        return opaqueBG.blended(withFraction: alpha, of: opaqueDivider) ?? divider
    }

    fileprivate static func pixelAligned(_ rect: NSRect) -> NSRect {
        NSRect(
            x: floor(rect.origin.x),
            y: floor(rect.origin.y),
            width: max(1, round(rect.size.width)),
            height: max(1, round(rect.size.height))
        )
    }

    private static func rect(_ lhs: NSRect, touches rhs: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        lhs.maxX >= rhs.minX - epsilon &&
            lhs.minX <= rhs.maxX + epsilon &&
            lhs.maxY >= rhs.minY - epsilon &&
            lhs.minY <= rhs.maxY + epsilon
    }
}

@MainActor
final class WindowTerminalPortal: NSObject {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    private static let tinyHideThreshold: CGFloat = 1
    private static let minimumRevealWidth: CGFloat = 24
    private static let minimumRevealHeight: CGFloat = 18
    private static let transientRecoveryRetryBudget: Int = 12
#if CMUX_ISSUE_483_PORTAL_RECOVERY
    private static let transientRecoveryEnabled = true
#else
    private static let transientRecoveryEnabled = false
#endif

    private(set) weak var window: NSWindow?
    private let hostView = WindowTerminalHostView(frame: .zero)
    private let dividerOverlayView = PortalSplitDividerOverlayView(frame: .zero)
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var installConstraints: [NSLayoutConstraint] = []
    private var hasDeferredFullSyncScheduled = false
    private var hasExternalGeometrySyncScheduled = false
    // Per-entry dirty set consumed by scheduleDeferredFullSynchronizeAll's deferred body.
    // Each schedule caller marks the hosted ids it touched; the deferred body iterates only
    // those entries (skipping entirely when nothing's dirty) instead of sweeping all entries.
    private var dirtyHostedIds: Set<ObjectIdentifier> = []
    private var geometryObservers: [NSObjectProtocol] = []
#if DEBUG
    private var lastLoggedBonsplitContainerSignature: String?
#endif

    private struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var workspaceFrameStyle: PortalWorkspaceFrameStyle?
        var transientRecoveryRetriesRemaining: Int
    }

    private var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.postsFrameChangedNotifications = true
        hostView.postsBoundsChangedNotifications = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        dividerOverlayView.translatesAutoresizingMaskIntoConstraints = true
        dividerOverlayView.autoresizingMask = [.width, .height]
        dividerOverlayView.hostedFrameProvider = { [weak self] hostView in
            self?.hostedFramesForChromeOverlay(in: hostView) ?? []
        }
        dividerOverlayView.chromeSegmentProvider = { [weak self] hostView, dividerSegments in
            self?.workspaceFrameSegmentsForChromeOverlay(
                in: hostView,
                dividerSegments: dividerSegments
            ) ?? []
        }
        installGeometryObservers(for: window)
        _ = ensureInstalled()
    }

    private func installGeometryObservers(for window: NSWindow) {
        guard geometryObservers.isEmpty else { return }

        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize(trigger: "windowResize")
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize(trigger: "windowEndLiveResize")
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      splitView.window === window else { return }
                self.scheduleExternalGeometrySynchronize(trigger: "splitViewResize")
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize(trigger: "frameDidChange")
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize(trigger: "boundsDidChange")
            }
        })
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    fileprivate func scheduleExternalGeometrySynchronize(trigger: String) {
        guard !hasExternalGeometrySyncScheduled else { return }
        hasExternalGeometrySyncScheduled = true
        let isDragEvent = TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
        let requiresSettledLayout = !(hostView.inLiveResize || window?.inLiveResize == true || isDragEvent)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let performSync = {
                self.hasExternalGeometrySyncScheduled = false
                self.synchronizeAllEntriesFromExternalGeometryChange(trigger: trigger)
            }
            if requiresSettledLayout {
                DispatchQueue.main.async(execute: performSync)
            } else {
                performSync()
            }
        }
    }

    private func synchronizeLayoutHierarchy() {
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        _ = synchronizeHostFrameToReference()
    }

    @discardableResult
    private func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostView.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostView.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            dlog(
                "portal.hostFrame.update host=\(portalDebugToken(hostView)) " +
                "frame=\(portalDebugFrame(frameInContainer))"
            )
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

    fileprivate func synchronizeAllEntriesFromExternalGeometryChange(trigger: String) {
        guard ensureInstalled() else { return }
        portalLog("geom.external",
            "windowNumber=\(window?.windowNumber ?? -1) " +
            "trigger=\(trigger) " +
            "entryCount=\(entriesByHostedId.count)"
        )
        synchronizeLayoutHierarchy()
        // An orphan entry is one whose anchor is no longer attached to this window:
        // either the weak reference deallocated, or the AppKit view was detached
        // (e.g., bonsplit's _ConditionalContent flipped between EmptyPanelView and
        // PanelContentView between bind and settle, leaving the original anchor
        // out of the live tree). Without this pass, the orphan keeps its hostedView
        // mounted at a stale frame and contributes phantom chrome segments and
        // (sometimes) an EmptyPanelView SwiftUI subtree on top of the live
        // workspace. See notes/launch-white-line-artifact.md.
        let didHideOrphan = hideOrphanEntriesIfNeeded()
        synchronizeAllHostedViews(excluding: nil)

        // During live resize, AppKit can deliver frame churn where host/container geometry
        // settles a tick before the terminal's own scroll/surface hierarchy. Only force an
        // in-place surface refresh when reconciliation actually changed terminal geometry.
        for entry in entriesByHostedId.values {
            guard let hostedView = entry.hostedView, !hostedView.isHidden else { continue }
            if hostedView.reconcileGeometryNow() {
                hostedView.refreshSurfaceNow(reason: "portal.externalGeometrySync")
            }
        }

        if didHideOrphan {
            dividerOverlayView.needsDisplay = true
        }
    }

    /// Walk the registry once and hide any entry whose anchor has definitively
    /// left this window's view tree. Returns true if at least one entry was
    /// hidden so the caller can invalidate the overlay.
    ///
    /// "Definitively" means one of:
    ///   - the anchor's weak reference deallocated (`anchor == nil`), which
    ///     happens when the SwiftUI representable that owned it was dismantled,
    ///   - the anchor is in some other window (`anchor.window !== window`).
    ///
    /// We deliberately don't hide on `anchor != nil && anchor.window == nil`:
    /// that's a momentary window-less limbo state during attach/detach
    /// transitions, and synchronizeHostedView's existing transient-recovery
    /// path handles it. Hiding aggressively there would cause a flash during
    /// legitimate workspace remounts.
    @discardableResult
    private func hideOrphanEntriesIfNeeded() -> Bool {
        var didHide = false
        for hostedId in entriesByHostedId.keys {
            guard var entry = entriesByHostedId[hostedId] else { continue }
            let anchor = entry.anchorView
            let isOrphan: Bool
            if anchor == nil {
                isOrphan = true
            } else if let anchorWindow = anchor?.window, anchorWindow !== window {
                isOrphan = true
            } else {
                isOrphan = false
            }
            guard isOrphan else { continue }
            let wasContributing = entry.visibleInUI || (entry.hostedView?.isHidden == false)
            guard wasContributing else { continue }

            entry.visibleInUI = false
            entriesByHostedId[hostedId] = entry
            entry.hostedView?.isHidden = true
            didHide = true
            let anchorWindowDesc: String
            if anchor == nil {
                anchorWindowDesc = "deallocated"
            } else if anchor?.window === nil {
                anchorWindowDesc = "nil"
            } else if anchor?.window === window {
                anchorWindowDesc = "self"
            } else {
                anchorWindowDesc = "other"
            }
#if DEBUG
            dlog(
                "portal.orphan.hide hosted=\(portalDebugToken(entry.hostedView)) " +
                "anchor=\(portalDebugToken(anchor)) anchorWindow=\(anchorWindowDesc)"
            )
#endif
            portalLog("orphan.hide",
                "hostedId=\(portalLogToken(hostedId)) " +
                "anchorId=\(portalLogToken(anchor.map { ObjectIdentifier($0) })) " +
                "anchor=\(anchorWindowDesc) " +
                "frame=\(portalLogFrame(entry.hostedView?.frame ?? .zero)) " +
                "entryCount=\(entriesByHostedId.count)"
            )
            // C11-134: orphaned portal entries signal teardown/remount churn —
            // the shape we need visible in Sentry hang reports.
            sentryBreadcrumb("portal.orphan.hide", category: "portal", data: [
                "layer": "terminal",
                "anchor": anchorWindowDesc,
                "entryCount": entriesByHostedId.count,
            ])
        }
        return didHide
    }

    private func ensureDividerOverlayOnTop() {
        if dividerOverlayView.superview !== hostView {
            dividerOverlayView.frame = hostView.bounds
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        } else if hostView.subviews.last !== dividerOverlayView {
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        }

        if !Self.rectApproximatelyEqual(dividerOverlayView.frame, hostView.bounds) {
            dividerOverlayView.frame = hostView.bounds
        }
        dividerOverlayView.needsDisplay = true
    }

    private func hostedFramesForChromeOverlay(in hostView: NSView) -> [NSRect] {
        entriesByHostedId.values.compactMap { entry in
            guard entry.visibleInUI,
                  let hostedView = entry.hostedView,
                  !hostedView.isHidden,
                  hostedView.superview === hostView else {
                return nil
            }
            return hostedView.frame
        }
    }

    private func workspaceFrameSegmentsForChromeOverlay(
        in hostView: NSView,
        dividerSegments: [PortalChromeOverlayDividerSegment]
    ) -> [PortalChromeOverlaySegment] {
        let hostBounds = hostView.bounds
        guard hostBounds.width > 1, hostBounds.height > 1 else { return [] }

        let windowCorners = PortalWindowCorners(window: window, hostView: hostView)
        var segments: [PortalChromeOverlaySegment] = []
        for entry in entriesByHostedId.values {
            guard entry.visibleInUI,
                  let style = entry.workspaceFrameStyle,
                  let hostedView = entry.hostedView,
                  !hostedView.isHidden,
                  hostedView.superview === hostView,
                  // Belt-and-suspenders: even if hideOrphanEntriesIfNeeded
                  // hasn't run yet on this redraw cycle, suppress chrome
                  // segments derived from an entry whose anchor has left
                  // this window. See notes/launch-white-line-artifact.md.
                  let anchor = entry.anchorView,
                  anchor.window === window,
                  let color = PortalWorkspaceFrameOverlay.color(from: style) else {
                continue
            }

            PortalWorkspaceFrameOverlay.appendWorkspaceFrameSegments(
                for: hostedView.frame,
                hostBounds: hostBounds,
                style: style,
                color: color,
                dividerSegments: dividerSegments,
                windowCorners: windowCorners,
                into: &segments
            )
        }
        return segments
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installedTargetIfStillValid(for: window) ?? installationTarget(for: window)
        else { return false }
        let browserHost = preferredBrowserHost(in: container)

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()

            hostView.removeFromSuperview()
            if let browserHost {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            } else {
                container.addSubview(hostView, positioned: .above, relativeTo: reference)
            }

            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = container
            installedReferenceView = reference
        } else if let browserHost {
            if !Self.isView(browserHost, above: hostView, in: container) {
                container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
            }
        } else if !Self.isView(hostView, above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
        }

        // Keep the drag/mouse forwarding overlay above portal-hosted terminal views.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container,
           !Self.isView(overlay, above: hostView, in: container) {
            container.addSubview(overlay, positioned: .above, relativeTo: hostView)
        }

        synchronizeLayoutHierarchy()
        _ = synchronizeHostFrameToReference()
        ensureDividerOverlayOnTop()

        return true
    }

    private func installedTargetIfStillValid(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return nil
        }

        guard hostView.superview === container,
              container.window === window,
              reference.window === window,
              reference.superview === container else {
            return nil
        }

        return (container, reference)
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let contentView = window.contentView else { return nil }

        // If NSGlassEffectView wraps the original content view, install inside the glass view
        // so terminals are above the glass background but below SwiftUI content.
        if contentView.className == "NSGlassEffectView",
           let foreground = contentView.subviews.first(where: { $0 !== hostView }) {
            return (contentView, foreground)
        }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }

    private static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    private func preferredBrowserHost(in container: NSView) -> WindowBrowserHostView? {
        container.subviews.last(where: { $0 is WindowBrowserHostView }) as? WindowBrowserHostView
    }

#if DEBUG
    private func nearestBonsplitContainer(from anchorView: NSView) -> NSView? {
        var current: NSView? = anchorView
        while let view = current {
            let className = NSStringFromClass(type(of: view))
            if className.contains("PaneDragContainerView") || className.contains("Bonsplit") {
                return view
            }
            current = view.superview
        }
        return installedReferenceView
    }

    private func logBonsplitContainerFrameIfNeeded(anchorView: NSView, hostedView: GhosttySurfaceScrollView) {
        guard let container = nearestBonsplitContainer(from: anchorView) else { return }
        let containerFrame = container.convert(container.bounds, to: nil)
        let signature = "\(ObjectIdentifier(container)):\(portalDebugFrame(containerFrame))"
        guard signature != lastLoggedBonsplitContainerSignature else { return }
        lastLoggedBonsplitContainerSignature = signature

        let containerClass = NSStringFromClass(type(of: container))
        dlog(
            "portal.bonsplit.container hosted=\(portalDebugToken(hostedView)) " +
            "class=\(containerClass) frame=\(portalDebugFrame(containerFrame)) " +
            "host=\(portalDebugFrameInWindow(hostView)) anchor=\(portalDebugFrameInWindow(anchorView))"
        )
    }
#endif

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor clipping.
    /// SwiftUI/AppKit hosting layers can report an anchor bounds wider than its split pane when
    /// intrinsic-size content overflows; intersecting through ancestor bounds gives the effective
    /// visible rect that should drive portal geometry.
    private func effectiveAnchorFrameInWindow(for anchorView: NSView) -> NSRect {
        var frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        var current = anchorView.superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds =
                ancestorBoundsInWindow.origin.x.isFinite &&
                ancestorBoundsInWindow.origin.y.isFinite &&
                ancestorBoundsInWindow.size.width.isFinite &&
                ancestorBoundsInWindow.size.height.isFinite
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === installedReferenceView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }

    private func seededFrameInHost(for anchorView: NSView) -> NSRect? {
        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        guard hasFiniteFrame else { return nil }

        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        if hasFiniteHostBounds {
            let clampedFrame = frameInHost.intersection(hostBounds)
            if !clampedFrame.isNull, clampedFrame.width > 1, clampedFrame.height > 1 {
                return clampedFrame
            }
        }

        return frameInHost
    }

    func detachHostedView(withId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
        if let anchor = entry.anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
        let hadSuperview = (entry.hostedView?.superview === hostView) ? 1 : 0
#if DEBUG
        dlog(
            "portal.detach hosted=\(portalDebugToken(entry.hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) hadSuperview=\(hadSuperview)"
        )
#endif
        portalLog("detach",
            "hostedId=\(portalLogToken(hostedId)) " +
            "anchorId=\(portalLogToken(entry.anchorView.map { ObjectIdentifier($0) })) " +
            "hadSuperview=\(hadSuperview) " +
            "entryCount=\(entriesByHostedId.count)"
        )
        if let hostedView = entry.hostedView, hostedView.superview === hostView {
            hostedView.removeFromSuperview()
        }
    }

    /// Hide a portal entry without detaching it. Updates visibleInUI to false and
    /// sets isHidden = true so subsequent synchronizeHostedView calls keep it hidden.
    /// Used when a workspace is permanently unmounted (vs. transient bonsplit dismantles).
    func hideEntry(forHostedId hostedId: ObjectIdentifier) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard entry.visibleInUI else { return }
        entry.visibleInUI = false
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
        entry.hostedView?.isHidden = true
        dividerOverlayView.needsDisplay = true
#if DEBUG
        dlog("portal.hideEntry hosted=\(portalDebugToken(entry.hostedView)) reason=workspaceUnmount")
#endif
        portalLog("hideEntry",
            "hostedId=\(portalLogToken(hostedId)) " +
            "anchorId=\(portalLogToken(entry.anchorView.map { ObjectIdentifier($0) })) " +
            "entryCount=\(entriesByHostedId.count)"
        )
    }

    /// Update the visibleInUI flag on an existing entry without rebinding.
    /// Used when a deferred bind is pending — this ensures synchronizeHostedView
    /// won't hide a view that updateNSView has already marked as visible.
    func updateEntryVisibility(forHostedId hostedId: ObjectIdentifier, visibleInUI: Bool) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = visibleInUI
        if !visibleInUI {
            entry.transientRecoveryRetriesRemaining = 0
        }
        entriesByHostedId[hostedId] = entry
        dividerOverlayView.needsDisplay = true
    }

    func isHostedViewBoundToAnchor(withId hostedId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByHostedId[hostedId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func bind(
        hostedView: GhosttySurfaceScrollView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        workspaceFrameStyle: PortalWorkspaceFrameStyle? = nil
    ) {
        guard ensureInstalled() else { return }

        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByHostedId[hostedId]

        if C11PortalDebug.isEnabled {
            let prevHostedAtAnchor = hostedByAnchorId[anchorId]
            let prevEntryHostedAtAnchor: NSView? = prevHostedAtAnchor.flatMap {
                entriesByHostedId[$0]?.hostedView
            }
            let anchorWindowNumber = anchorView.window?.windowNumber ?? -1
            let anchorSuperviewToken = portalLogToken(anchorView.superview)
            portalLog("bind.before",
                "hostedId=\(portalLogToken(hostedId)) " +
                "anchorId=\(portalLogToken(anchorId)) " +
                "anchorWindowNumber=\(anchorWindowNumber) " +
                "anchorSuperviewPtr=\(anchorSuperviewToken) " +
                "visibleInUI=\(visibleInUI ? 1 : 0) " +
                "prevHostedIdForAnchor=\(portalLogToken(prevHostedAtAnchor)) " +
                "prevEntryHostedViewPtr=\(portalLogToken(prevEntryHostedAtAnchor)) " +
                "entryCount=\(entriesByHostedId.count)"
            )
        }

        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
#if DEBUG
            let previousToken = entriesByHostedId[previousHostedId]
                .map { portalDebugToken($0.hostedView) }
                ?? String(describing: previousHostedId)
            dlog(
                "portal.bind.replace anchor=\(portalDebugToken(anchorView)) " +
                "oldHosted=\(previousToken) newHosted=\(portalDebugToken(hostedView))"
            )
#endif
            detachHostedView(withId: previousHostedId)
        }

        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            workspaceFrameStyle: workspaceFrameStyle,
            transientRecoveryRetriesRemaining: 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil || didChangeAnchor || becameVisible || priorityIncreased || hostedView.superview !== hostView {
            dlog(
                "portal.bind hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) prevAnchor=\(portalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        _ = synchronizeHostFrameToReference()

        // Seed frame/bounds before entering the window so a freshly reparented
        // surface doesn't do a transient 800x600 size update on viewDidMoveToWindow.
        if let seededFrame = seededFrameInHost(for: anchorView),
           seededFrame.width > 0,
           seededFrame.height > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = seededFrame
            hostedView.bounds = NSRect(origin: .zero, size: seededFrame.size)
            CATransaction.commit()
        } else {
            // If anchor geometry is still unsettled, keep this hidden/zero-sized until
            // synchronizeHostedView resolves a valid target frame on the next layout tick.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = .zero
            hostedView.bounds = .zero
            CATransaction.commit()
            hostedView.isHidden = true
        }
        // Keep inner scroll/surface geometry in sync with the seeded outer frame
        // before the hosted view enters a window.
        hostedView.reconcileGeometryNow()

        if hostedView.superview !== hostView {
#if DEBUG
            dlog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) " +
                "reason=attach super=\(portalDebugToken(hostedView.superview))"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== hostedView {
            // Refresh z-order only when a view becomes visible or gets a higher priority.
            // Anchor-only churn is common during split tree updates; forcing remove/add there
            // causes transient inWindow=0 -> 1 bounces that can flash black.
#if DEBUG
            dlog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        }

        ensureDividerOverlayOnTop()

        synchronizeHostedView(withId: hostedId)
        // Re-check this hosted view on the next tick — the bind just reparented/resized it
        // and ancestor layout may still settle. Other entries are unaffected by this bind.
        dirtyHostedIds.insert(hostedId)
        scheduleDeferredFullSynchronizeAll()
        pruneDeadEntries()

        portalLog("bind.after",
            "hostedId=\(portalLogToken(hostedId)) " +
            "anchorId=\(portalLogToken(anchorId)) " +
            "seededFrame=\(portalLogFrame(hostedView.frame)) " +
            "superviewIsHostView=\(hostedView.superview === hostView ? 1 : 0) " +
            "entryCount=\(entriesByHostedId.count)"
        )
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView) {
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]
        if let primaryHostedId {
            synchronizeHostedView(withId: primaryHostedId)
        }

        // Failsafe: during aggressive divider drags/structural churn, one anchor can miss a
        // geometry callback while another fires. Reconcile all mapped hosted views so no stale
        // frame remains "stuck" onscreen until the next interaction.
        synchronizeAllHostedViews(excluding: primaryHostedId)
        // Only the primary hosted view (whose anchor moved) needs a deferred re-check after
        // layout settles. Other entries were just synchronized inline above. When primaryHostedId
        // is nil (anchor not bound to any hosted view), there's nothing to defer — the deferred
        // body will skip cleanly.
        if let primaryHostedId {
            dirtyHostedIds.insert(primaryHostedId)
        }
        scheduleDeferredFullSynchronizeAll()
    }

    /// C11-527: discard whatever the divider overlay last painted. Its draw
    /// recomputes segments from the live view tree, so a full redraw can never
    /// keep a divider whose split view has gone.
    func invalidateDividerOverlay() {
#if DEBUG
        overlayInvalidationCountForTesting += 1
#endif
        dividerOverlayView.needsDisplay = true
    }

#if DEBUG
    @discardableResult
    func ensureInstalledForTesting() -> Bool { ensureInstalled() }

    private(set) var overlayInvalidationCountForTesting = 0
#endif

    func updateWorkspaceFrameStyle(
        forHostedId hostedId: ObjectIdentifier,
        style: PortalWorkspaceFrameStyle?
    ) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard entry.workspaceFrameStyle != style else { return }
        entry.workspaceFrameStyle = style
        entriesByHostedId[hostedId] = entry
        dividerOverlayView.needsDisplay = true
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            self.runDeferredHostedSync()
        }
    }

    /// Body of the deferred sync. Iterates only entries marked dirty since the schedule
    /// call; skips entirely when nothing's dirty. Re-entrant marks added during iteration
    /// (e.g., transient-recovery retries) re-arm a fresh deferred via the schedule call,
    /// so they're handled on the next tick rather than in the current sweep.
    private func runDeferredHostedSync() {
        guard ensureInstalled() else {
            dirtyHostedIds.removeAll(keepingCapacity: true)
            return
        }
        let snapshot = dirtyHostedIds
        dirtyHostedIds.removeAll(keepingCapacity: true)
        guard !snapshot.isEmpty else {
#if DEBUG
            dlog("portal.deferredSync.skip count=0")
#endif
            return
        }
#if DEBUG
        dlog("portal.deferredSync.run count=\(snapshot.count) full=0")
#endif
        synchronizeLayoutHierarchy()
        pruneDeadEntries()
        for hostedId in snapshot {
            // Skip ids that no longer correspond to a live entry (detached/unbound between
            // schedule and run). synchronizeHostedView would no-op anyway, but skipping here
            // avoids the lookup churn.
            guard entriesByHostedId[hostedId] != nil else { continue }
            synchronizeHostedView(withId: hostedId)
        }
    }

    private func synchronizeAllHostedViews(excluding hostedIdToSkip: ObjectIdentifier?) {
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        pruneDeadEntries()
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds {
            if hostedId == hostedIdToSkip { continue }
            synchronizeHostedView(withId: hostedId)
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forHostedId hostedId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 else { return }
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forHostedId hostedId: ObjectIdentifier,
        entry: inout Entry,
        hostedView: GhosttySurfaceScrollView,
        reason: String
    ) -> Bool {
        guard Self.transientRecoveryEnabled else { return false }
        if entry.transientRecoveryRetriesRemaining == 0 {
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        entriesByHostedId[hostedId] = entry
#if DEBUG
        dlog(
            "portal.sync.deferRecover hosted=\(portalDebugToken(hostedView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            // Retry only the entry whose recovery is in flight; other entries aren't
            // affected by this transient-recovery cycle.
            dirtyHostedIds.insert(hostedId)
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    private func synchronizeHostedView(withId hostedId: ObjectIdentifier) {
        guard ensureInstalled() else { return }
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView, let window else {
            portalLog("sync.skip.orphan",
                "hostedId=\(portalLogToken(hostedId)) " +
                "anchorWindow=\(entry.anchorView == nil ? "anchorNil" : "windowNil") " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) " +
                "frame=\(portalLogFrame(hostedView.frame)) " +
                "reason=missingAnchorOrWindow"
            )
            // Only hide if the entry is not marked visibleInUI. When a workspace is
            // remounting, updateNSView sets visibleInUI=true before the deferred bind
            // provides an anchor — hiding here would race with that and cause a flash.
            if !entry.visibleInUI {
#if DEBUG
                if !hostedView.isHidden {
                    dlog("portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 reason=missingAnchorOrWindow")
                }
#endif
                hostedView.isHidden = true
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            } else {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: "missingAnchorOrWindow"
                )
            }
            return
        }
        guard anchorView.window === window else {
            let anchorWindowDesc: String = (anchorView.window == nil) ? "nil" : "other"
            portalLog("sync.skip.orphan",
                "hostedId=\(portalLogToken(hostedId)) " +
                "anchorWindow=\(anchorWindowDesc) " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) " +
                "frame=\(portalLogFrame(hostedView.frame)) " +
                "reason=anchorWindowMismatch"
            )
#if DEBUG
            if !hostedView.isHidden {
                dlog(
                    "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(portalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "anchorWindowMismatch"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    dlog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=anchorWindowMismatch frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
            hostedView.isHidden = true
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: "anchorWindowMismatch"
                )
            }
            return
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
#if DEBUG
        logBonsplitContainerFrameIfNeeded(anchorView: anchorView, hostedView: hostedView)
#endif
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            dlog(
                "portal.sync.defer hosted=\(portalDebugToken(hostedView)) " +
                "reason=hostBoundsNotReady host=\(portalDebugFrame(hostBounds)) " +
                "anchor=\(portalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "hostBoundsNotReady"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    dlog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=hostBoundsNotReady frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
            hostedView.isHidden = true
            if entry.visibleInUI {
                if Self.transientRecoveryEnabled {
                    _ = scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "hostBoundsNotReady"
                    )
                } else {
                    // Legacy fallback (transient recovery disabled): retry only this hosted
                    // view on the next tick once host bounds settle.
                    dirtyHostedIds.insert(hostedId)
                    scheduleDeferredFullSynchronizeAll()
                }
            }
            return
        }
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        let clampedFrame = frameInHost.intersection(hostBounds)
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame =
            targetFrame.width <= Self.tinyHideThreshold ||
            targetFrame.height <= Self.tinyHideThreshold
        let revealReadyForDisplay =
            targetFrame.width >= Self.minimumRevealWidth &&
            targetFrame.height >= Self.minimumRevealHeight
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let shouldDeferReveal = !shouldHide && hostedView.isHidden && !revealReadyForDisplay
        let transientRecoveryReason: String? = {
            guard Self.transientRecoveryEnabled else { return nil }
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            if shouldDeferReveal { return "deferReveal" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forHostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !hostedView.isHidden

        let oldFrame = hostedView.frame
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            dlog(
                "portal.frame.clamp hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) " +
                "raw=\(portalDebugFrame(frameInHost)) clamped=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            dlog(
                "portal.frame.collapse hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            dlog(
                "portal.frame.restore hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        }
#endif

        // Hide before updating the frame when this entry should not be visible.
        // This avoids a one-frame flash of unrendered terminal background when a portal
        // briefly transitions through offscreen/tiny geometry during rapid split churn.
        if shouldHide, !hostedView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            dlog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = true
        }
        if shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            dlog(
                "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(portalDebugFrame(hostedView.frame))"
            )
#endif
        }

        if hasFiniteFrame {
            let expectedBounds = NSRect(origin: .zero, size: targetFrame.size)
            var geometryChanged = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
                hostedView.frame = targetFrame
                geometryChanged = true
            }
            if !Self.rectApproximatelyEqual(hostedView.bounds, expectedBounds) {
                hostedView.bounds = expectedBounds
                geometryChanged = true
            }
            CATransaction.commit()
            if geometryChanged {
                hostedView.reconcileGeometryNow()
                hostedView.refreshSurfaceNow(reason: "portal.frameChange")
            }
        }

        if shouldDeferReveal {
#if DEBUG
            if !Self.rectApproximatelyEqual(oldFrame, frameInHost) {
                dlog(
                    "portal.hidden.deferReveal hosted=\(portalDebugToken(hostedView)) " +
                    "frame=\(portalDebugFrame(frameInHost)) min=\(Int(Self.minimumRevealWidth))x\(Int(Self.minimumRevealHeight))"
                )
            }
#endif
        }

        if !shouldHide, hostedView.isHidden, revealReadyForDisplay {
#if DEBUG
            dlog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = false
            // A reveal can happen without any frame delta (same targetFrame), which means the
            // normal frame-change refresh path won't run. Nudge geometry + redraw so newly
            // revealed terminals don't sit on a stale/blank IOSurface until later focus churn.
            hostedView.reconcileGeometryNow()
            hostedView.refreshSurfaceNow(reason: "portal.reveal")
        }

        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
        }

#if DEBUG
        dlog(
            "portal.sync.result hosted=\(portalDebugToken(hostedView)) " +
            "anchor=\(portalDebugToken(anchorView)) host=\(portalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(portalDebugFrame(oldFrame)) raw=\(portalDebugFrame(frameInHost)) " +
            "target=\(portalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
            "hostBounds=\(portalDebugFrame(hostBounds))"
        )
#endif

        portalLog("sync.result",
            "hostedId=\(portalLogToken(hostedId)) " +
            "oldFrame=\(portalLogFrame(oldFrame)) " +
            "targetFrame=\(portalLogFrame(targetFrame)) " +
            "shouldHide=\(shouldHide ? 1 : 0) " +
            "revealReady=\(revealReadyForDisplay ? 1 : 0) " +
            "hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
            "entryCount=\(entriesByHostedId.count)"
        )

        ensureDividerOverlayOnTop()
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadHostedIds = entriesByHostedId.compactMap { hostedId, entry -> ObjectIdentifier? in
            guard entry.hostedView != nil else { return hostedId }
            guard let anchor = entry.anchorView else {
                return entry.visibleInUI ? nil : hostedId
            }

            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // During aggressive tab drag/reorder churn, SwiftUI/AppKit can briefly
                // detach/rehome anchor hosts while the terminal should stay visible.
                // Avoid pruning those visible entries so sync/bind recovery can reattach.
                return entry.visibleInUI ? nil : hostedId
            }
            return nil
        }

        for hostedId in deadHostedIds {
            detachHostedView(withId: hostedId)
        }

        let validAnchorIds = Set(entriesByHostedId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        hostedByAnchorId = hostedByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for hostedId in Array(entriesByHostedId.keys) {
            detachHostedView(withId: hostedId)
        }
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    struct DebugStats {
        let windowNumber: Int
        let entryCount: Int
        let hostSubviewCount: Int
        let terminalSubviewCount: Int
        let mappedTerminalSubviewCount: Int
        let orphanTerminalSubviewCount: Int
        let visibleOrphanTerminalSubviewCount: Int
        let staleEntryCount: Int
    }

    func debugStats() -> DebugStats {
        let terminalSubviews = hostView.subviews.compactMap { $0 as? GhosttySurfaceScrollView }
        var mappedTerminalSubviewCount = 0
        var orphanTerminalSubviewCount = 0
        var visibleOrphanTerminalSubviewCount = 0

        for hostedView in terminalSubviews {
            let hostedId = ObjectIdentifier(hostedView)
            if entriesByHostedId[hostedId] != nil {
                mappedTerminalSubviewCount += 1
            } else {
                orphanTerminalSubviewCount += 1
                if hostedView.window != nil,
                   !hostedView.isHidden,
                   hostedView.frame.width > Self.tinyHideThreshold,
                   hostedView.frame.height > Self.tinyHideThreshold {
                    visibleOrphanTerminalSubviewCount += 1
                }
            }
        }

        let staleEntryCount = entriesByHostedId.values.reduce(0) { partialResult, entry in
            guard let hostedView = entry.hostedView else { return partialResult + 1 }
            return hostedView.superview === hostView ? partialResult : partialResult + 1
        }

        return DebugStats(
            windowNumber: window?.windowNumber ?? -1,
            entryCount: entriesByHostedId.count,
            hostSubviewCount: hostView.subviews.count,
            terminalSubviewCount: terminalSubviews.count,
            mappedTerminalSubviewCount: mappedTerminalSubviewCount,
            orphanTerminalSubviewCount: orphanTerminalSubviewCount,
            visibleOrphanTerminalSubviewCount: visibleOrphanTerminalSubviewCount,
            staleEntryCount: staleEntryCount
        )
    }

    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
#endif

    func viewAtWindowPoint(_ windowPoint: NSPoint) -> NSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        // Restrict hit-testing to currently mapped entries so stale detached views
        // can't steal file-drop/mouse routing.
        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            return hostedView.hitTest(localPoint) ?? hostedView
        }

        return nil
    }

    func terminalViewAtWindowPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            if let terminal = hostedView.terminalViewForDrop(at: localPoint) {
                return terminal
            }
        }

        return nil
    }
}

@MainActor
enum TerminalWindowPortalRegistry {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    private static var portalsByWindowId: [ObjectIdentifier: WindowTerminalPortal] = [:]
    private static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var hasPendingExternalGeometrySyncForAllWindows = false
    private static var interactiveGeometryResizeCount = 0
#if DEBUG
    private static var blockedBindCount: Int = 0
    private static var blockedBindReasons: [String: Int] = [:]
#endif

    static var isInteractiveGeometryResizeActive: Bool {
#if DEBUG
        if Self.isPointerDragActiveForTesting { return true }
#endif
        return Self.interactiveGeometryResizeCount > 0
    }

    private static func bindBlockReason(
        expectedSurfaceId: UUID?,
        expectedGeneration: UInt64?,
        actual: (surfaceId: UUID?, generation: UInt64?, state: String)
    ) -> String {
        if actual.surfaceId == nil {
            return "missingSurface"
        }
        if actual.state != "live" {
            return "state_\(actual.state)"
        }
        if let expectedSurfaceId, actual.surfaceId != expectedSurfaceId {
            return "surfaceMismatch"
        }
        if let expectedGeneration, actual.generation != expectedGeneration {
            return "generationMismatch"
        }
        return "guardRejected"
    }

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &cmuxWindowTerminalPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        hostedToWindowId = hostedToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneHostedMappings(for windowId: ObjectIdentifier, validHostedIds: Set<ObjectIdentifier>) {
        hostedToWindowId = hostedToWindowId.filter { hostedId, mappedWindowId in
            mappedWindowId != windowId || validHostedIds.contains(hostedId)
        }
    }

    private static func portal(for window: NSWindow) -> WindowTerminalPortal {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowTerminalPortal(window: window)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    private static func existingPortal(for window: NSWindow) -> WindowTerminalPortal? {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }
        return portalsByWindowId[ObjectIdentifier(window)]
    }

    static func bind(
        hostedView: GhosttySurfaceScrollView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        workspaceFrameStyle: PortalWorkspaceFrameStyle? = nil,
        expectedSurfaceId: UUID? = nil,
        expectedGeneration: UInt64? = nil
    ) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let hostedId = ObjectIdentifier(hostedView)
        let guardState = hostedView.portalBindingGuardState()
        guard hostedView.canAcceptPortalBinding(
            expectedSurfaceId: expectedSurfaceId,
            expectedGeneration: expectedGeneration
        ) else {
            if let oldWindowId = hostedToWindowId.removeValue(forKey: hostedId) {
                portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
            }
#if DEBUG
            let reason = bindBlockReason(
                expectedSurfaceId: expectedSurfaceId,
                expectedGeneration: expectedGeneration,
                actual: guardState
            )
            blockedBindCount += 1
            blockedBindReasons[reason, default: 0] += 1
            dlog(
                "portal.bind.blocked hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(reason) expectedSurface=\(expectedSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                "expectedGeneration=\(expectedGeneration.map { String($0) } ?? "nil") " +
                "actualSurface=\(guardState.surfaceId?.uuidString.prefix(5) ?? "nil") " +
                "actualGeneration=\(guardState.generation.map { String($0) } ?? "nil") " +
                "actualState=\(guardState.state)"
            )
#endif
            return
        }

        let nextPortal = portal(for: window)

        if let oldWindowId = hostedToWindowId[hostedId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
        }
#if DEBUG
        let bindStart = CACurrentMediaTime()
#endif
        nextPortal.bind(
            hostedView: hostedView,
            to: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            workspaceFrameStyle: workspaceFrameStyle
        )
        hostedToWindowId[hostedId] = windowId
        pruneHostedMappings(for: windowId, validHostedIds: nextPortal.hostedIds())
#if DEBUG
        let bindMs = (CACurrentMediaTime() - bindStart) * 1000
        if bindMs > 5 {
            dlog(
                "portal.bind.timing hosted=\(portalDebugToken(hostedView)) " +
                "bindMs=\(String(format: "%.2f", bindMs))"
            )
        }
#endif
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window)
        portal.synchronizeHostedViewForAnchor(anchorView)
    }

    static func invalidateDividerOverlay(for window: NSWindow) {
        existingPortal(for: window)?.invalidateDividerOverlay()
    }

    static func windowsWithPortals() -> [NSWindow] {
        portalsByWindowId.values.compactMap { $0.window }
    }

#if DEBUG
    static func portalForTesting(window: NSWindow) -> WindowTerminalPortal? {
        existingPortal(for: window)
    }

    static func ensurePortalForTesting(window: NSWindow) -> WindowTerminalPortal {
        portal(for: window)
    }
#endif

    static func scheduleExternalGeometrySynchronize(for window: NSWindow, trigger: String) {
        existingPortal(for: window)?.scheduleExternalGeometrySynchronize(trigger: trigger)
    }

    static func beginInteractiveGeometryResize() {
        interactiveGeometryResizeCount += 1
    }

    static func endInteractiveGeometryResize() {
        interactiveGeometryResizeCount = max(0, interactiveGeometryResizeCount - 1)
    }

    static func scheduleExternalGeometrySynchronizeForAllWindows(trigger: String) {
        guard !Self.hasPendingExternalGeometrySyncForAllWindows else { return }
        Self.hasPendingExternalGeometrySyncForAllWindows = true
        let isDragEvent = Self.isInteractiveGeometryResizeActive
        DispatchQueue.main.async {
            let performSync = {
                Self.hasPendingExternalGeometrySyncForAllWindows = false
                for portal in Self.portalsByWindowId.values {
                    portal.synchronizeAllEntriesFromExternalGeometryChange(trigger: trigger)
                }
            }
            if isDragEvent {
                performSync()
            } else {
                DispatchQueue.main.async(execute: performSync)
            }
        }
    }

    static func hideHostedView(_ hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideEntry(forHostedId: hostedId)
    }

    /// Permanently detach a hosted terminal view from the window-level portal.
    /// Use this when a terminal panel is actually closing (not transient SwiftUI dismantle).
    static func detach(hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId.removeValue(forKey: hostedId) else { return }
        portalsByWindowId[windowId]?.detachHostedView(withId: hostedId)
    }

    /// Update the visibleInUI flag on an existing portal entry without rebinding.
    /// Called when a bind is deferred (host not yet in window) to prevent stale
    /// portal syncs from hiding a view that is about to become visible.
    static func updateEntryVisibility(for hostedView: GhosttySurfaceScrollView, visibleInUI: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: visibleInUI)
    }

    static func updateWorkspaceFrameStyle(
        for hostedView: GhosttySurfaceScrollView,
        style: PortalWorkspaceFrameStyle?
    ) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateWorkspaceFrameStyle(forHostedId: hostedId, style: style)
    }

    static func isHostedView(_ hostedView: GhosttySurfaceScrollView, boundTo anchorView: NSView) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard hostedToWindowId[hostedId] == windowId,
              let portal = portalsByWindowId[windowId] else { return false }
        return portal.isHostedViewBoundToAnchor(withId: hostedId, anchorView: anchorView)
    }

    static func viewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        let portal = portal(for: window)
        return portal.viewAtWindowPoint(windowPoint)
    }

    static func terminalViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> GhosttyNSView? {
        let portal = portal(for: window)
        return portal.terminalViewAtWindowPoint(windowPoint)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }

    static func debugPortalStats() -> [String: Any] {
        var portals: [[String: Any]] = []
        var totals: [String: Int] = [
            "entry_count": 0,
            "host_subview_count": 0,
            "terminal_subview_count": 0,
            "mapped_terminal_subview_count": 0,
            "orphan_terminal_subview_count": 0,
            "visible_orphan_terminal_subview_count": 0,
            "stale_entry_count": 0,
            "mapped_hosted_count": 0,
        ]

        for (windowId, portal) in portalsByWindowId {
            let stats = portal.debugStats()
            let mappedHostedCount = hostedToWindowId.values.reduce(0) { partialResult, mappedWindowId in
                partialResult + (mappedWindowId == windowId ? 1 : 0)
            }
            let integrityOK =
                stats.orphanTerminalSubviewCount == 0 &&
                stats.visibleOrphanTerminalSubviewCount == 0 &&
                stats.staleEntryCount == 0 &&
                mappedHostedCount == stats.entryCount

            portals.append([
                "window_number": stats.windowNumber,
                "entry_count": stats.entryCount,
                "mapped_hosted_count": mappedHostedCount,
                "host_subview_count": stats.hostSubviewCount,
                "terminal_subview_count": stats.terminalSubviewCount,
                "mapped_terminal_subview_count": stats.mappedTerminalSubviewCount,
                "orphan_terminal_subview_count": stats.orphanTerminalSubviewCount,
                "visible_orphan_terminal_subview_count": stats.visibleOrphanTerminalSubviewCount,
                "stale_entry_count": stats.staleEntryCount,
                "integrity_ok": integrityOK,
            ])

            totals["entry_count", default: 0] += stats.entryCount
            totals["host_subview_count", default: 0] += stats.hostSubviewCount
            totals["terminal_subview_count", default: 0] += stats.terminalSubviewCount
            totals["mapped_terminal_subview_count", default: 0] += stats.mappedTerminalSubviewCount
            totals["orphan_terminal_subview_count", default: 0] += stats.orphanTerminalSubviewCount
            totals["visible_orphan_terminal_subview_count", default: 0] += stats.visibleOrphanTerminalSubviewCount
            totals["stale_entry_count", default: 0] += stats.staleEntryCount
            totals["mapped_hosted_count", default: 0] += mappedHostedCount
        }

        portals.sort {
            let lhs = ($0["window_number"] as? Int) ?? Int.min
            let rhs = ($1["window_number"] as? Int) ?? Int.min
            return lhs < rhs
        }

        return [
            "portal_count": portals.count,
            "hosted_mapping_count": hostedToWindowId.count,
            "guarded_bind_blocked_count": blockedBindCount,
            "guarded_bind_blocked_reasons": blockedBindReasons,
            "portals": portals,
            "totals": totals,
        ]
    }
#endif
}

// Value wrappers keep object-address, UUID and class-name formatting off main.
// A metatype carries class identity only; no live view escapes the copy.
enum PortalSnapshotEncoding {
    struct Source { let address: UInt }
    struct ClassName { let type: AnyClass }

    static func json(_ value: Any) -> Any {
        if let source = value as? Source { return "object:\(String(source.address, radix: 16))" }
        if let name = value as? ClassName { return String(describing: name.type) }
        if let id = value as? UUID { return id.uuidString }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(json) }
        if let array = value as? [Any] { return array.map(json) }
        return value
    }
}

// C11-530: one-shot diagnostics only. These helpers never install, synchronize,
// prune or draw a portal. NSView/NSColor references stay inside the main copy;
// the returned dictionaries contain values and formatting wrappers only.
@MainActor
struct PortalSnapshotGeometry {
    static let entryLimit = 512
    static let viewLimit = 2048
    static let dividerLimit = 256

    struct Divider {
        let source: PortalSnapshotEncoding.Source
        let index: Int
        let rect: NSRect // Window base coordinates, in points.
        let color: NSColor
        let vertical: Bool
        let hidden: Bool
    }

    let dividers: [Divider]
    let visitedViews: Int
    let skippedHiddenSubtrees: Int
    let truncated: Bool

    init(window: NSWindow) {
        var rows: [Divider] = []
        var visited = 0
        var skippedHidden = 0
        var cut = false
        func visit(_ view: NSView, ancestorHidden: Bool) {
            guard visited < Self.viewLimit else { cut = true; return }
            visited += 1
            let hidden = ancestorHidden || view.isHidden
            if let split = view as? NSSplitView {
                let children = split.arrangedSubviews
                for index in 0..<max(0, children.count - 1) {
                    guard rows.count < Self.dividerLimit else { cut = true; break }
                    let first = children[index].frame
                    let thickness = max(1, split.dividerThickness)
                    let rect = split.isVertical
                        ? NSRect(x: first.maxX, y: 0, width: thickness, height: split.bounds.height)
                        : NSRect(x: 0, y: first.maxY, width: split.bounds.width, height: thickness)
                    rows.append(Divider(source: Self.token(split), index: index,
                        rect: split.convert(rect, to: nil),
                        color: PortalSplitDividerOverlayView.overlayDividerColor(for: split),
                        vertical: split.isVertical, hidden: hidden))
                }
            }
            let children = view.subviews
            if children.count > Self.viewLimit { cut = true }
            for child in children.prefix(Self.viewLimit) {
                // draw() skips hidden branches entirely. Retain immediate split
                // geometry, but do not spend the visible-geometry budget walking
                // hidden WebKit/terminal internals or other non-split branches.
                if hidden && !(child is NSSplitView) { skippedHidden += 1; continue }
                guard visited < Self.viewLimit else { cut = true; break }
                visit(child, ancestorHidden: hidden)
            }
        }
        if let root = window.contentView { visit(root, ancestorHidden: false) }
        dividers = rows
        visitedViews = visited
        skippedHiddenSubtrees = skippedHidden
        truncated = cut
    }

    static func token(_ object: AnyObject) -> PortalSnapshotEncoding.Source {
        PortalSnapshotEncoding.Source(address: UInt(bitPattern: ObjectIdentifier(object)))
    }
    static func number(_ value: CGFloat) -> Any { value.isFinite ? Double(value) : NSNull() }
    static func rect(_ value: NSRect) -> [String: Any] {
        ["x": number(value.origin.x), "y": number(value.origin.y),
         "width": number(value.width), "height": number(value.height)]
    }
    static func color(_ value: NSColor?) -> Any {
        guard let rgb = value?.usingColorSpace(.deviceRGB) else { return NSNull() }
        return ["red": number(rgb.redComponent), "green": number(rgb.greenComponent),
                "blue": number(rgb.blueComponent), "alpha": number(rgb.alphaComponent)]
    }
    static func view(_ view: NSView?) -> Any {
        guard let view else { return NSNull() }
        return ["source_id": token(view), "class": PortalSnapshotEncoding.ClassName(type: type(of: view)),
                "frame": rect(view.frame), "bounds": rect(view.bounds),
                "frame_in_window": view.window == nil ? NSNull() : rect(view.convert(view.bounds, to: nil)),
                "window_source_id": view.window.map(token) as Any? ?? NSNull(),
                "superview_source_id": view.superview.map(token) as Any? ?? NSNull(),
                "hidden": view.isHidden, "hidden_by_ancestor": view.isHiddenOrHasHiddenAncestor,
                "alpha": number(view.alphaValue)] as [String: Any]
    }
    var payload: [String: Any] {
        ["visited_views": visitedViews, "hidden_non_split_subtrees_skipped": skippedHiddenSubtrees, "truncated": truncated,
         "dividers": dividers.map { row in
             ["source_id": row.source, "divider_index": row.index,
              "rect_in_window": Self.rect(row.rect), "color": Self.color(row.color),
              "vertical": row.vertical, "hidden_by_ancestor": row.hidden] as [String: Any]
         }]
    }

    static func entry(
        source: ObjectIdentifier, content: NSView?, hosted: NSView?, anchor: NSView?,
        host: NSView, overlay: NSView, window: NSWindow?, visible: Bool, priority: Int,
        style: PortalWorkspaceFrameStyle?, dividers: [PortalChromeOverlayDividerSegment],
        identity: [String: UUID]?, geometryComplete: Bool
    ) -> [String: Any] {
        var reasons: [String] = []
        if !visible { reasons.append("not_visible_in_ui") }
        if hosted == nil { reasons.append("missing_hosted_view") }
        if hosted?.isHidden == true { reasons.append("hosted_view_hidden") }
        if hosted?.superview !== host { reasons.append("hosted_view_not_in_host") }
        let occlusionEligible = reasons.isEmpty
        if anchor == nil { reasons.append("missing_anchor") }
        if anchor?.window == nil || anchor?.window !== window { reasons.append("anchor_not_in_window") }
        if host.bounds.width <= 1 || host.bounds.height <= 1 { reasons.append("host_too_small") }
        if style == nil { reasons.append("no_frame_style") }
        let resolvedColor = style.flatMap(PortalWorkspaceFrameOverlay.color)
        if style != nil && resolvedColor == nil { reasons.append("invalid_frame_color") }
        var candidates: [[String: Any]] = []
        if let style, let hosted {
            let frame = hosted.frame
            let thickness = max(1, style.thicknessPt)
            let edges: [(String, PortalWorkspaceFrameOverlay.Edge, Bool, NSRect)] = [
                ("leading", .leading, style.edges.leading, NSRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)),
                ("trailing", .trailing, style.edges.trailing, NSRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)),
                ("bottom", .bottom, style.edges.bottom, NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)),
                ("top", .top, style.edges.top, NSRect(x: frame.minX, y: frame.maxY - thickness, width: frame.width, height: thickness))
            ]
            for (name, edge, enabled, raw) in edges {
                var guards = reasons
                let visibleFrame = frame.intersection(host.bounds)
                if visibleFrame.isNull || visibleFrame.width <= 1 || visibleFrame.height <= 1 { guards.append("frame_outside_host_or_too_small") }
                if !enabled { guards.append("edge_disabled") }
                // Invalid geometry cannot safely form ClosedRanges in the shared guard.
                if frame.minX.isFinite && frame.maxX.isFinite && frame.minY.isFinite && frame.maxY.isFinite {
                    if PortalWorkspaceFrameOverlay.edgeTouchesDivider(edge, frame: frame, dividerSegments: dividers) { guards.append("touches_native_divider") }
                } else { guards.append("nonfinite_frame") }
                let clipped = raw.intersection(host.bounds)
                if clipped.isNull || clipped.width <= 0 || clipped.height <= 0 { guards.append("empty_clipped_rect") }
                candidates.append(["edge": name, "rect_in_host": rect(clipped),
                    "rect_in_overlay": rect(clipped),
                    "pixel_aligned_rect_in_overlay": rect(PortalSplitDividerOverlayView.pixelAligned(clipped)),
                    "rect_in_window": overlay.window == nil || clipped.isNull ? NSNull() : rect(overlay.convert(clipped, to: nil)),
                    "color": color(resolvedColor), "admitted": guards.isEmpty,
                    "guard_rejections": guards, "complete": geometryComplete])
            }
        }
        return ["source_id": PortalSnapshotEncoding.Source(address: UInt(bitPattern: source)), "identity": identity as Any? ?? NSNull(),
                "content": view(content), "hosted": view(hosted), "anchor": view(anchor),
                "visible_in_ui": visible, "z_priority": priority,
                "orphan": anchor == nil || anchor?.window !== window || content == nil,
                "divider_occlusion_eligible": occlusionEligible,
                "chrome_guard_rejections": reasons, "chrome_candidates": candidates,
                "frame_style": style.map { style in
                    ["color": color(resolvedColor), "thickness": number(style.thicknessPt),
                     "opacity": number(CGFloat(style.opacity)), "edges": ["leading": style.edges.leading,
                     "trailing": style.edges.trailing, "top": style.edges.top, "bottom": style.edges.bottom]] as [String: Any]
                } as Any? ?? NSNull()]
    }
}

extension PortalSplitDividerOverlayView {
    func diagnosticDividers(_ geometry: PortalSnapshotGeometry) -> [PortalChromeOverlayDividerSegment] {
        geometry.dividers.compactMap { row in
            let rect = convert(row.rect, from: nil)
            guard !row.hidden, rect.intersects(bounds) else { return nil }
            return PortalChromeOverlayDividerSegment(rect: rect, isVertical: row.vertical)
        }
    }

    func diagnosticSnapshot(_ geometry: PortalSnapshotGeometry, hostedFrames: [NSRect], entriesComplete: Bool) -> [String: Any] {
        let candidates: [[String: Any]] = geometry.dividers.map { row in
            let rect = convert(row.rect, from: nil)
            let segment = DividerSegment(rect: rect, color: row.color, isVertical: row.vertical)
            var reasons: [String] = []
            if row.hidden { reasons.append("native_split_hidden") }
            if !rect.intersects(bounds) { reasons.append("outside_overlay") }
            if !shouldRenderOverlay(for: segment, hostedFrames: hostedFrames) { reasons.append("no_hosted_frame_occlusion") }
            return ["source_id": row.source, "divider_index": row.index,
                    "rect_in_overlay": PortalSnapshotGeometry.rect(rect),
                    "rect_in_window": PortalSnapshotGeometry.rect(row.rect),
                    "pixel_aligned_rect_in_overlay": PortalSnapshotGeometry.rect(Self.pixelAligned(rect)),
                    "color": PortalSnapshotGeometry.color(row.color), "admitted": reasons.isEmpty,
                    "guard_rejections": reasons, "complete": !geometry.truncated && entriesComplete]
        }
        return ["view": PortalSnapshotGeometry.view(self),
                "occlusion_policy": occlusionPolicy == .crossingCenterline ? "crossing_centerline" : "touching_segment",
                "divider_candidates": candidates]
    }
}

extension WindowTerminalPortal {
    func diagnosticSnapshot(_ geometry: PortalSnapshotGeometry, identities: [ObjectIdentifier: [String: UUID]]) -> [String: Any] {
        let entriesComplete = entriesByHostedId.count <= PortalSnapshotGeometry.entryLimit
        let dividers = dividerOverlayView.diagnosticDividers(geometry)
        var frames: [NSRect] = []
        let entries = entriesByHostedId.prefix(PortalSnapshotGeometry.entryLimit).map { key, entry -> [String: Any] in
            if entry.visibleInUI, let hosted = entry.hostedView, !hosted.isHidden, hosted.superview === hostView { frames.append(hosted.frame) }
            var row = PortalSnapshotGeometry.entry(source: key, content: entry.hostedView, hosted: entry.hostedView,
                anchor: entry.anchorView, host: hostView, overlay: dividerOverlayView, window: window, visible: entry.visibleInUI,
                priority: entry.zPriority, style: entry.workspaceFrameStyle, dividers: dividers,
                identity: identities[key], geometryComplete: !geometry.truncated)
            row["recovery_retries_remaining"] = entry.transientRecoveryRetriesRemaining
            return row
        }
        let children = hostView.subviews
        let unmatched = children.prefix(PortalSnapshotGeometry.entryLimit).compactMap { child -> Any? in
            guard child is GhosttySurfaceScrollView, entriesByHostedId[ObjectIdentifier(child)] == nil else { return nil }
            return PortalSnapshotGeometry.view(child)
        }
        return ["present": true, "host": PortalSnapshotGeometry.view(hostView), "entries": entries,
                "entry_count": entriesByHostedId.count, "entries_truncated": !entriesComplete,
                "anchor_mapping_count": hostedByAnchorId.count,
                "unmatched_hosted_views": unmatched, "unmatched_classification_complete": true, "host_subviews_truncated": children.count > PortalSnapshotGeometry.entryLimit,
                "overlay": dividerOverlayView.diagnosticSnapshot(geometry, hostedFrames: frames, entriesComplete: entriesComplete)]
    }
}

extension TerminalWindowPortalRegistry {
    static func diagnosticSnapshot(window: NSWindow, geometry: PortalSnapshotGeometry, identities: [ObjectIdentifier: [String: UUID]]) -> [String: Any] {
        // Lookup only: portal(for:) installs views and is forbidden on this path.
        portalsByWindowId[ObjectIdentifier(window)]?.diagnosticSnapshot(geometry, identities: identities) ?? ["present": false]
    }
}

/// C11-527: one place that tells both window portals to repaint their divider
/// overlays. Each overlay caches its last paint, and the browser overlay sits above
/// the terminals, so a divider painted while a split existed could stay on screen
/// after the split view left the window, until some unrelated browser event
/// repainted it. Every structural change that can remove, add, hide or move a
/// divider routes here: area split, close and geometry changes, and the visible
/// workspace changing.
///
/// Repaint is a full invalidation now, then once more on the next main-loop turn
/// so the draw sees the tree after SwiftUI and AppKit have settled. Requests for a
/// window coalesce until that turn runs. Nothing here runs per keystroke.
@MainActor
enum PortalOverlayRepaint {
    private static var pendingWindowIds: Set<ObjectIdentifier> = []
    private static var pendingAllWindows = false

#if DEBUG
    struct RequestRecord: Equatable {
        let windowId: ObjectIdentifier?
        let reason: String
    }
    static var requestsForTesting: [RequestRecord] = []
    static var deferredPassCountForTesting = 0
    static var deferredWindowPassesForTesting: [ObjectIdentifier] = []
    /// When set, every invalidation records how many split views its window
    /// still holds, so a test can prove the last repaint saw the settled tree.
    static var recordsSplitPresenceForTesting = false
    static var invalidationSplitCountsForTesting: [(windowId: ObjectIdentifier, splitViews: Int)] = []

    private static func splitViewCount(in view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is NSSplitView ? 1 : 0) + view.subviews.reduce(0) { $0 + splitViewCount(in: $1) }
    }
#endif

    /// Repaint the overlays of one window.
    static func request(for window: NSWindow, reason: String) {
#if DEBUG
        requestsForTesting.append(RequestRecord(windowId: ObjectIdentifier(window), reason: reason))
#endif
        invalidate(window)
        let windowId = ObjectIdentifier(window)
        guard pendingWindowIds.insert(windowId).inserted else { return }
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated {
                Self.pendingWindowIds.remove(windowId)
#if DEBUG
                Self.deferredPassCountForTesting += 1
                Self.deferredWindowPassesForTesting.append(windowId)
#endif
                if let window { Self.invalidate(window) }
            }
        }
    }

    /// Repaint every window's overlays. For callers that do not know their window
    /// (a workspace's area tree, the selected workspace changing).
    static func requestAllWindows(reason: String) {
#if DEBUG
        requestsForTesting.append(RequestRecord(windowId: nil, reason: reason))
#endif
        for window in allWindows() { invalidate(window) }
        guard !pendingAllWindows else { return }
        pendingAllWindows = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Self.pendingAllWindows = false
#if DEBUG
                Self.deferredPassCountForTesting += 1
#endif
                for window in Self.allWindows() { Self.invalidate(window) }
            }
        }
    }

    private static func allWindows() -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return (TerminalWindowPortalRegistry.windowsWithPortals() + BrowserWindowPortalRegistry.windowsWithPortals())
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private static func invalidate(_ window: NSWindow) {
#if DEBUG
        if recordsSplitPresenceForTesting {
            invalidationSplitCountsForTesting.append((ObjectIdentifier(window), splitViewCount(in: window.contentView)))
        }
#endif
        TerminalWindowPortalRegistry.invalidateDividerOverlay(for: window)
        BrowserWindowPortalRegistry.invalidateChromeOverlay(for: window)
    }
}
