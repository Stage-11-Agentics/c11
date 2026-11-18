import CoreGraphics
import Foundation

// c11 (C11H-349): an operator's jump lands where the operator is looking.
//
// A jump is the operator asking for one panel: a notification click, a
// Flagged or Done button, Feed, the menu-bar list, a panel link. When the
// window holding that panel sits on another display, raising it in place
// changes nothing the operator can see, so the window comes to the display the
// operator is on. Only an operator action moves a window; an agent's socket
// request never does. Geometry follows `WindowPlacement.swift`: global points,
// origin at the main display's top-left, y down.

/// Where a jump puts the window holding its target.
enum OperatorJumpPlacement: Equatable {
    /// Already on the operator's display, or no display is known: raised where it is.
    case inPlace
    /// On another display: moved to this frame on the operator's display.
    case moveToDisplay(CGRect)
    /// In native full screen on another display, which cannot move: raised
    /// there, and the operator is told where it opened.
    case fullScreenElsewhere

    var token: String {
        switch self {
        case .inPlace: return "in_place"
        case .moveToDisplay: return "moved_display"
        case .fullScreenElsewhere: return "fullscreen_elsewhere"
        }
    }

    /// - Parameters:
    ///   - window: the window's frame now.
    ///   - windowDisplay: the display holding most of it.
    ///   - operatorDisplay: the display the operator is on.
    ///   - isFullScreen: the window is in native full screen.
    ///   - minSize: the window's minimum size.
    static func plan(
        window: CGRect,
        windowDisplay: DisplayGeometry?,
        operatorDisplay: DisplayGeometry?,
        isFullScreen: Bool,
        minSize: CGSize
    ) -> OperatorJumpPlacement {
        guard let operatorDisplay, let windowDisplay,
              windowDisplay.displayID != operatorDisplay.displayID else { return .inPlace }
        if isFullScreen { return .fullScreenElsewhere }
        // Same size, shrunk to fit the visible frame, centred where the
        // operator will see it. Never below the window's minimum (c11's is
        // 900x640 of content): on a smaller display the axis that cannot fit
        // keeps its title bar or left edge inside the visible frame.
        let visible = operatorDisplay.visibleFrame
        let width = max(min(window.width, visible.width), min(minSize.width, window.width))
        let height = max(min(window.height, visible.height), min(minSize.height, window.height))
        let x = max(visible.minX, (visible.midX - width / 2).rounded(.down))
        let y = max(visible.minY, (visible.midY - height / 2).rounded(.down))
        return .moveToDisplay(CGRect(x: x, y: y, width: width, height: height))
    }

    /// The display the operator is on: the one holding the c11 window they
    /// were last working in (its key window, else the last active one). A jump
    /// within that display only raises the target's window. With no c11 window
    /// active yet, the pointer's display.
    static func operatorDisplay(
        activeWindowFrame: CGRect?,
        pointer: CGPoint?,
        displays: [DisplayGeometry]
    ) -> DisplayGeometry? {
        if let activeWindowFrame, let display = DisplayArrangement.display(for: activeWindowFrame, in: displays) {
            return display
        }
        if let pointer { return display(containing: pointer, in: displays) }
        return nil
    }

    /// The display under a point; a point on no display (the far edge of the
    /// last one) belongs to the nearest.
    static func display(containing point: CGPoint, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        displays.first { $0.frame.contains(point) }
            ?? DisplayArrangement.display(for: CGRect(origin: point, size: CGSize(width: 1, height: 1)), in: displays)
    }
}

/// What presenting a jump's window did, for its log line.
struct OperatorJumpPresentation: Equatable {
    var placement: OperatorJumpPlacement
    var movedToActiveSpace: Bool
    var windowID: UUID?
    /// CGDirectDisplayIDs: the window's display before, and the operator's.
    var fromDisplay: UInt32?
    var operatorDisplay: UInt32?
    /// The name of the display the window is on, for the full-screen notice.
    var windowDisplayName: String?
}

/// Which operator path asked for the jump.
enum OperatorJumpSource: String {
    /// A macOS notification, the Done button, the notifications list or menu.
    case notification
    /// Flagged buttons, Feed, the menu-bar flag list, jump to latest unread.
    case attention
    /// A panel link: in a terminal, the mailbox drawer, a summary card, a URL.
    case panelLink = "panel_link"
}

/// How a jump ended. Logged as one `operator_jump` line in hc-diagnostics.log.
enum OperatorJumpOutcome: String {
    case opened
    /// A socket request's context refused the workspace switch.
    case refused
    /// The workspace has closed: no window holds it.
    case missingWorkspace = "missing_workspace"
    case missingPanel = "missing_panel"
    /// Its window, or every c11 window, is gone.
    case missingWindow = "missing_window"
    case focusFailed = "focus_failed"

    /// What the operator is told when the jump cannot land; nil when it
    /// landed or the operator did not ask (a refused socket request).
    var operatorMessage: String? {
        switch self {
        case .opened, .refused:
            return nil
        case .missingPanel:
            return String(localized: "operatorJump.hud.panelClosed", defaultValue: "That panel has closed")
        case .missingWorkspace:
            return String(localized: "operatorJump.hud.workspaceClosed", defaultValue: "That workspace has closed")
        case .missingWindow, .focusFailed:
            return String(localized: "operatorJump.hud.couldNotOpen", defaultValue: "c11 couldn't open that panel")
        }
    }
}
