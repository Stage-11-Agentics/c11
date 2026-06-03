import AppKit
import SwiftUI

// CMUX-10: Single seam for flash visuals (color + envelope) used by both the
// pane ring renderer (`GhosttySurfaceScrollView`) and the sidebar workspace row
// fill (`TabItemView`). Lifting these behind one type lets later commits swap
// the default color, accept a per-call override, and unify the temporal
// envelope across surfaces without touching every renderer.
//
// Commit 1 (this file's introduction) is a pure refactor: `FlashAppearance.current()`
// still returns the existing gold accent and the existing two-pattern envelope
// pair (`.paneRing` / `.sidebarFill`). Later commits in CMUX-10 swap the
// default color (#F5C518) and unify the envelope.

public enum FlashEnvelope: Equatable {
    /// Pane ring channel: drives the ring overlay around the focused pane at
    /// full peak amplitude (1.0).
    case paneRing

    /// Sidebar workspace-row channel: same temporal pattern as `.paneRing` but
    /// with peak amplitude scaled to 0.6 so the row tint reads as a signal
    /// without overpowering the rest of the sidebar.
    case sidebarFill

    /// Per-channel amplitude scalar applied to the unified envelope's
    /// `targetOpacity` values. CMUX-10 retired the historical "polite ambient
    /// nudge" sidebar envelope in favor of this single shared envelope.
    public var peakScale: Double {
        switch self {
        case .paneRing: return 1.0
        case .sidebarFill: return 0.6
        }
    }

    /// Duration of one flash pulse in seconds. Sourced from the user-tunable
    /// Flash Duration setting (Notifications panel, 500–4000ms, default 1500ms).
    /// Pane and sidebar share this duration; the sidebar applies `peakScale`
    /// to amplitude only, not time. Goes through `FocusFlashPattern.duration`
    /// so every renderer (pane ring, sidebar fill, Browser/Markdown overlays)
    /// scales together.
    public var duration: TimeInterval {
        FocusFlashPattern.duration
    }
}

public struct FlashAppearance: Equatable {
    public let color: NSColor
    public let envelope: FlashEnvelope

    public init(color: NSColor, envelope: FlashEnvelope) {
        self.color = color
        self.envelope = envelope
    }

    /// SwiftUI-compatible projection of `color`. SwiftUI's sidebar fill needs a
    /// `Color`, not an `NSColor`; pane renderer needs the `NSColor` directly.
    public var swiftUIColor: Color {
        Color(nsColor: color)
    }

    /// The default flash color used when no per-call override is provided.
    /// Resolved by the CMUX-10 ticket: a warm yellow distinct from the gold
    /// accent so the flash reads as a *signal*, not just chrome.
    ///
    /// `static let` (not `var`) so the `NSColor` is allocated once at class
    /// initialization, not on every read. Sidebar overlay reads this on each
    /// pulse animation tick; a computed accessor would build a fresh
    /// `NSColor` per tick per row.
    ///
    /// TODO(theme-engine, CMUX-9): read `flash.color` from the active theme
    /// when the theme engine ships; until then this constant is the source of
    /// truth and per-call overrides come through `--color`.
    public static let defaultColor: NSColor = NSColor(
        srgbRed: 0xF5 / 255.0,
        green: 0xC5 / 255.0,
        blue: 0x18 / 255.0,
        alpha: 1.0
    )

    /// Parse a hex color string of the form `#RRGGBB` or `#RRGGBBAA`
    /// (case-insensitive, optional leading `#`). Returns `nil` for any other
    /// shape so callers can surface a clear error message rather than rendering
    /// garbage. Used by both the CLI parser and the socket handler.
    public static func parseHex(_ raw: String) -> NSColor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard stripped.count == 6 || stripped.count == 8 else { return nil }
        guard stripped.allSatisfy({ $0.isHexDigit }) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: stripped).scanHexInt64(&value) else { return nil }
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        if stripped.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255.0
            g = CGFloat((value >> 16) & 0xFF) / 255.0
            b = CGFloat((value >> 8) & 0xFF) / 255.0
            a = CGFloat(value & 0xFF) / 255.0
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
            a = 1.0
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Snapshot of the current default appearance for the given envelope.
    /// Call sites that don't yet know which envelope they want pick `.paneRing`
    /// (the historical pane behavior) so the refactor stays a no-op.
    public static func current(envelope: FlashEnvelope = .paneRing) -> FlashAppearance {
        FlashAppearance(color: defaultColor, envelope: envelope)
    }
}
