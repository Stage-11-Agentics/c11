import AppKit
import Foundation
import SwiftUI

public struct SurfaceId: Hashable, Sendable {
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
    case dropTarget(source: SurfaceId? = nil)
    case notifying(WorkspaceFrameUrgency, source: SurfaceId? = nil)
    case mirroring(peer: WindowId? = nil)
}

/// Outer content-area frame. Renders a hairline `RoundedRectangle` stroke
/// coloured from `theme.chrome.windowFrame.color` with opacity modulated by
/// workspace/window focus state. Attaches as a SwiftUI `.overlay` and is
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
        let cornerRadius = hostingWindowCornerRadius()

        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color(nsColor: strokeColor), lineWidth: thickness)
            .opacity(opacity)
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

    /// Matches the hosting window's rounded-corner radius so the stroke sits
    /// flush with the `NSWindow` content layer. Falls back to 10pt — macOS
    /// 14+'s default — when the window radius is unreadable (pre-mount, no
    /// content layer yet).
    private func hostingWindowCornerRadius() -> CGFloat {
        if let layer = NSApp.mainWindow?.contentView?.layer, layer.cornerRadius > 0 {
            return layer.cornerRadius
        }
        return 10
    }
}
