import Foundation
import Combine
import AppKit

/// Type of panel content
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
}

public enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
}

public enum BrowserPanelFocusIntent: Equatable {
    case webView
    case addressBar
    case findField
}

public enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
    case browser(BrowserPanelFocusIntent)
}

enum FocusFlashCurve: Equatable {
    case easeIn
    case easeOut
}

struct FocusFlashSegment: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
    let targetOpacity: Double
    let curve: FocusFlashCurve
}

enum FocusFlashPattern {
    static let values: [Double] = [0, 1, 0, 1, 0]
    static let keyTimes: [Double] = [0, 0.25, 0.5, 0.75, 1]
    /// CMUX-10: total duration of one flash pulse, sourced from the
    /// configurable `NotificationFlashDurationSettings` (500–4000ms, default
    /// 1500ms). Both pane and sidebar segments scale with this.
    static var duration: TimeInterval {
        Double(NotificationFlashDurationSettings.currentMs()) / 1000.0
    }
    static let curves: [FocusFlashCurve] = [.easeOut, .easeIn, .easeOut, .easeIn]
    static let ringInset: Double = 6
    static let ringCornerRadius: Double = 10

    static var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }
}

// CMUX-10: the historical `SidebarFlashPattern` (single-peak, 0.6s, peak 0.18)
// was retired in favor of a single unified envelope shared across the pane
// ring and the sidebar workspace row. The sidebar now reuses
// `FocusFlashPattern` with `FlashEnvelope.sidebarFill.peakScale` (0.6) applied
// at render time, so a flash signal is a single recognizable shape across
// surfaces rather than two visually-distinct treatments.

/// Protocol for all panel types (terminal, browser, etc.)
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    /// Unique identifier for this panel
    var id: UUID { get }

    /// The type of panel
    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    /// Unfocus the panel
    func unfocus()

    /// Trigger a focus flash animation for this panel.
    func triggerFlash()

    /// Trigger a focus flash animation with a specific appearance (color +
    /// envelope). Default impl falls back to the no-arg `triggerFlash()` so
    /// existing call sites keep working — panels that want to honor a per-
    /// call color override implement this directly.
    func triggerFlash(appearance: FlashAppearance)

    /// Capture the panel-local focus target that should be restored later.
    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent

    /// Return the best focus target to restore when this panel becomes active again.
    func preferredFocusIntentForActivation() -> PanelFocusIntent

    /// Prime panel-local focus state before activation side effects run.
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent)

    /// Restore a previously captured focus target.
    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool

    /// Return the semantic focus target currently owned by this panel, if any.
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent?

    /// Explicitly yield a previously owned focus target before another panel restores focus.
    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool
}

/// Extension providing default implementations
extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }

    /// Default impl: panels that don't yet honor per-call appearance fall
    /// through to the legacy `triggerFlash()` path.
    func triggerFlash(appearance: FlashAppearance) {
        _ = appearance
        triggerFlash()
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        _ = window
        return preferredFocusIntentForActivation()
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .panel
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard intent == .panel else { return false }
        focus()
        return true
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = responder
        _ = window
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }
}
