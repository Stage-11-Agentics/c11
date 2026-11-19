import CoreGraphics
import Foundation

// c11 (C11H-197): agent-readable displays and window placement.
//
// One coordinate convention for every display and window field c11 reports or
// accepts: global points, origin at the top-left of the main display (the one
// with the menu bar), x to the right, y down. It is the convention of
// CGWindowList, CGDisplayBounds and Accessibility, so `window move --frame`
// takes exactly what `list-windows` returns. AppKit's own bottom-left frames
// are converted at the edge, here.

/// One connected display, in top-left global points.
struct DisplayGeometry: Equatable {
    /// CoreGraphics' display UUID: stable across reboots and reconnects.
    let uuid: String?
    /// CGDirectDisplayID: valid for this login session only.
    let displayID: UInt32
    /// NSScreen.localizedName; macOS numbers identical models ("DELL P2715Q (1)").
    let name: String
    /// The main display: menu bar, and the coordinate origin.
    let isMain: Bool
    let isBuiltin: Bool
    let frame: CGRect
    /// The frame minus the menu bar and Dock.
    let visibleFrame: CGRect
    let scale: CGFloat
    /// 1-based position left to right (then top to bottom); `display:N` names it.
    var index: Int

    var ref: String { "display:\(index)" }
}

enum DisplayArrangement {
    /// Converts an AppKit rect (bottom-left global origin) to top-left global
    /// points. `mainScreenHeight` is the main display's height.
    static func topLeft(fromAppKit rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts top-left global points to an AppKit rect.
    static func appKit(fromTopLeft rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Numbers displays 1...n left to right, then top to bottom, and returns
    /// them in that order.
    static func ordered(_ displays: [DisplayGeometry]) -> [DisplayGeometry] {
        displays
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                return lhs.displayID < rhs.displayID
            }
            .enumerated()
            .map { offset, display in
                var numbered = display
                numbered.index = offset + 1
                return numbered
            }
    }

    enum RefError: Error, Equatable {
        case notFound(String)
        case ambiguous(String, candidates: [String])
    }

    /// Resolves a display ref: `display:N` or a bare N (1-based, left to right),
    /// the display UUID, `main`, `builtin`, or a name (exact, ignoring case).
    static func resolve(_ raw: String, in displays: [DisplayGeometry]) -> Result<DisplayGeometry, RefError> {
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = ref.lowercased()
        func byIndex(_ text: Substring) -> DisplayGeometry? {
            guard let number = Int(text) else { return nil }
            return displays.first { $0.index == number }
        }
        if lowered.hasPrefix("display:") {
            if let match = byIndex(lowered.dropFirst("display:".count)) { return .success(match) }
            return .failure(.notFound(ref))
        }
        if Int(lowered) != nil {
            if let match = byIndex(Substring(lowered)) { return .success(match) }
            return .failure(.notFound(ref))
        }
        if UUID(uuidString: ref) != nil {
            if let match = displays.first(where: { $0.uuid?.caseInsensitiveCompare(ref) == .orderedSame }) {
                return .success(match)
            }
            return .failure(.notFound(ref))
        }
        let named = displays.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return .success(named[0]) }
        if named.count > 1 { return .failure(.ambiguous(ref, candidates: named.map(\.ref))) }
        if lowered == "main", let main = displays.first(where: \.isMain) { return .success(main) }
        if lowered == "builtin" || lowered == "built-in" {
            let builtins = displays.filter(\.isBuiltin)
            if builtins.count == 1 { return .success(builtins[0]) }
            if builtins.count > 1 { return .failure(.ambiguous(ref, candidates: builtins.map(\.ref))) }
        }
        // A model name shared by numbered siblings ("DELL P2715Q") is ambiguous, not missing.
        let prefixed = displays.filter { $0.name.lowercased().hasPrefix(lowered + " (") }
        if prefixed.count > 1 { return .failure(.ambiguous(ref, candidates: prefixed.map(\.ref))) }
        if prefixed.count == 1 { return .success(prefixed[0]) }
        return .failure(.notFound(ref))
    }

    /// The display a window is on: the one holding most of its area, else the
    /// one whose centre is nearest (a window entirely off screen).
    static func display(for windowFrame: CGRect, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        var best: (display: DisplayGeometry, area: CGFloat)?
        for display in displays {
            let overlap = windowFrame.intersection(display.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (display, area) }
        }
        if let best { return best.display }
        let centre = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return displays.min { lhs, rhs in
            distanceSquared(centre, lhs.frame) < distanceSquared(centre, rhs.frame)
        }
    }

    /// The share of the display's visible frame the window covers, 0...1, to 3 places.
    static func visibleFraction(of windowFrame: CGRect, on display: DisplayGeometry) -> Double {
        let visible = display.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return 0 }
        let overlap = windowFrame.intersection(visible)
        guard !overlap.isNull else { return 0 }
        let fraction = Double((overlap.width * overlap.height) / (visible.width * visible.height))
        return (min(1, max(0, fraction)) * 1000).rounded() / 1000
    }

    /// The window frame relative to the display's top-left corner.
    static func frameOnDisplay(_ windowFrame: CGRect, display: DisplayGeometry) -> CGRect {
        windowFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    private static func distanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}

/// Where `window move` puts a window, in top-left global points.
enum WindowPlacementPlan {
    enum Preset: String, CaseIterable {
        case fill
        case leftHalf = "left-half"
        case rightHalf = "right-half"
    }

    enum Failure: Error, Equatable {
        /// Neither a display, a frame nor a preset was given.
        case nothingToDo
        /// A frame and a preset were both given.
        case conflicting
        /// The frame is not finite or has no area.
        case invalidFrame
        /// The window's current display is unknown and the request needs it.
        case noDisplay
    }

    /// - Parameters:
    ///   - current: the window's frame now.
    ///   - currentDisplay: the display it is on now.
    ///   - targetDisplay: `--display`, if given.
    ///   - frame: `--frame`: global without a display, relative to the
    ///     display's top-left corner with one.
    ///   - preset: `--fill`, `--left-half` or `--right-half`.
    ///   - minSize: the window's minimum size.
    static func plan(
        current: CGRect,
        currentDisplay: DisplayGeometry?,
        targetDisplay: DisplayGeometry?,
        frame: CGRect?,
        preset: Preset?,
        minSize: CGSize
    ) -> Result<CGRect, Failure> {
        if frame != nil, preset != nil { return .failure(.conflicting) }
        if let frame {
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else {
                return .failure(.invalidFrame)
            }
            let origin = targetDisplay?.frame.origin ?? .zero
            let placed = frame.offsetBy(dx: origin.x, dy: origin.y)
            return .success(CGRect(
                x: placed.minX,
                y: placed.minY,
                width: max(placed.width, minSize.width),
                height: max(placed.height, minSize.height)
            ))
        }
        if let preset {
            guard let display = targetDisplay ?? currentDisplay else { return .failure(.noDisplay) }
            let visible = display.visibleFrame
            switch preset {
            case .fill:
                return .success(visible)
            case .leftHalf:
                return .success(CGRect(x: visible.minX, y: visible.minY,
                                       width: (visible.width / 2).rounded(.down), height: visible.height))
            case .rightHalf:
                let width = (visible.width / 2).rounded(.down)
                return .success(CGRect(x: visible.maxX - width, y: visible.minY,
                                       width: width, height: visible.height))
            }
        }
        guard let targetDisplay else { return .failure(.nothingToDo) }
        // Display alone: keep the size (shrunk to fit) and the offset from the
        // visible frame's corner, kept inside the new display.
        let visible = targetDisplay.visibleFrame
        let size = CGSize(width: min(current.width, visible.width), height: min(current.height, visible.height))
        let offset: CGPoint
        if let currentDisplay {
            offset = CGPoint(x: current.minX - currentDisplay.visibleFrame.minX,
                             y: current.minY - currentDisplay.visibleFrame.minY)
        } else {
            offset = .zero
        }
        let x = min(max(visible.minX + offset.x, visible.minX), visible.maxX - size.width)
        let y = min(max(visible.minY + offset.y, visible.minY), visible.maxY - size.height)
        return .success(CGRect(x: x, y: y, width: size.width, height: size.height))
    }

}

extension CGRect {
    /// `{x, y, width, height}` for socket payloads, in whole points when exact.
    var c11Payload: [String: Double] {
        ["x": Double(minX), "y": Double(minY), "width": Double(width), "height": Double(height)]
    }
}
