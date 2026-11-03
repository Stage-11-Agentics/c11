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
            isWindowFocused: isWindowFocused
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
