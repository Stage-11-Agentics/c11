import AppKit
import Foundation
import XCTest
import Bonsplit
@testable import c11

/// Area frames (`[chrome.area]`, docs/c11-theme-schema-2.md): which frame an area
/// draws, what the theme resolves to, and the ring the portal overlays fill.
final class AreaFrameTests: XCTestCase {
    private let dark = ThemeContext(workspaceColor: nil, colorScheme: .dark, ghosttyBackgroundGeneration: 0)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let orange = NSColor(srgbRed: 1, green: 0x4F / 255, blue: 0x1F / 255, alpha: 1)

    private func hex(_ color: NSColor?) -> String? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return "#" + [color.redComponent, color.greenComponent, color.blueComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    private func theme(_ body: String, schema: Int = 2) throws -> C11Theme {
        let source = """
        [identity]
        name = "t"
        display_name = "T"
        author = "test"
        version = "0.01.001"
        schema = \(schema)

        [palette]
        ink = "#101010"
        hot = "#FF4F1F"
        snow = "#FFFFFF"

        [variables]
        background = "$palette.ink"
        accent = "$palette.snow"

        \(body)
        """
        return try C11Theme.fromToml(TomlSubsetParser.parse(file: "t.toml", source: source))
    }

    private func palette(_ body: String, schema: Int = 2) throws -> AreaFramePalette? {
        AreaFramePalette.resolve(snapshot: ResolvedThemeSnapshot(theme: try theme(body, schema: schema)), context: dark)
    }

    // MARK: State

    func testFocusWinsOverWaiting() {
        XCTAssertEqual(AreaFrameState.resolve(isFocusedArea: true, hasWaitingPanel: true), .focused)
        XCTAssertEqual(AreaFrameState.resolve(isFocusedArea: true, hasWaitingPanel: false), .focused)
        XCTAssertEqual(AreaFrameState.resolve(isFocusedArea: false, hasWaitingPanel: true), .waiting)
        XCTAssertEqual(AreaFrameState.resolve(isFocusedArea: false, hasWaitingPanel: false), .plain)
    }

    func testStrokeTakesTheStateColour() {
        let palette = AreaFramePalette(focus: white, waiting: orange, thicknessPt: 1.5, cornerRadius: 3)
        XCTAssertEqual(palette.stroke(isFocusedArea: true, hasWaitingPanel: true),
                       AreaFrameStroke(color: white, thicknessPt: 1.5, cornerRadius: 3))
        XCTAssertEqual(palette.stroke(isFocusedArea: true, hasWaitingPanel: false)?.color, white)
        XCTAssertEqual(palette.stroke(isFocusedArea: false, hasWaitingPanel: true),
                       AreaFrameStroke(color: orange, thicknessPt: 1.5, cornerRadius: 3))
        XCTAssertNil(palette.stroke(isFocusedArea: false, hasWaitingPanel: false))
    }

    func testAnUnsetColourFallsThroughToTheNextStateThatApplies() {
        let waitingOnly = AreaFramePalette(focus: nil, waiting: orange, thicknessPt: 1, cornerRadius: 0)
        XCTAssertEqual(waitingOnly.stroke(isFocusedArea: true, hasWaitingPanel: true)?.color, orange)
        XCTAssertNil(waitingOnly.stroke(isFocusedArea: true, hasWaitingPanel: false))
        XCTAssertEqual(waitingOnly.stroke(isFocusedArea: false, hasWaitingPanel: true)?.color, orange)

        let focusOnly = AreaFramePalette(focus: white, waiting: nil, thicknessPt: 1, cornerRadius: 0)
        XCTAssertEqual(focusOnly.stroke(isFocusedArea: true, hasWaitingPanel: true)?.color, white)
        XCTAssertNil(focusOnly.stroke(isFocusedArea: false, hasWaitingPanel: true))
    }

    // MARK: Theme resolution

    func testAThemeWithoutAreaColoursIsFrameless() throws {
        XCTAssertNil(try palette(""))
        XCTAssertNil(try palette("""
        [chrome.area]
        thicknessPt = 2

        [geometry]
        controlRadius = 4
        """))
    }

    func testSchema1IgnoresTheAreaSection() throws {
        XCTAssertNil(try palette("""
        [chrome.area]
        focusBorder = "$accent"
        """, schema: 1))
    }

    func testAreaSectionResolvesWithControlRadius() throws {
        let resolved = try XCTUnwrap(try palette("""
        [chrome.area]
        focusBorder   = "$accent"
        waitingBorder = "$palette.hot"
        thicknessPt   = 1.5

        [geometry]
        controlRadius = 4
        """))
        XCTAssertEqual(hex(resolved.focus), "#FFFFFF")
        XCTAssertEqual(hex(resolved.waiting), "#FF4F1F")
        XCTAssertEqual(resolved.thicknessPt, 1.5)
        XCTAssertEqual(resolved.cornerRadius, 4)
    }

    func testThicknessDefaultsToOnePointAndZeroTurnsFramesOff() throws {
        let defaults = try XCTUnwrap(try palette("""
        [chrome.area]
        waitingBorder = "$palette.hot"
        """))
        XCTAssertEqual(defaults.thicknessPt, AreaFramePalette.defaultThicknessPt)
        XCTAssertEqual(defaults.cornerRadius, 0, "no controlRadius means square")
        XCTAssertNil(defaults.focus)

        XCTAssertNil(try palette("""
        [chrome.area]
        focusBorder = "$accent"
        thicknessPt = 0
        """))
    }

    func testBundledThemesFrameAsThePrototypeDoes() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/c11-themes")
        func bundled(_ name: String) throws -> AreaFramePalette? {
            let url = dir.appendingPathComponent("\(name).toml")
            let table = try TomlSubsetParser.parse(file: url.path, source: try String(contentsOf: url, encoding: .utf8))
            return AreaFramePalette.resolve(snapshot: ResolvedThemeSnapshot(theme: try C11Theme.fromToml(table)), context: dark)
        }
        // name: focus, waiting, thickness, corner radius
        let expected: [(String, String, String, CGFloat, CGFloat)] = [
            ("datasheet-mono", "#FFFFFF", "#FF4F1F", 1, 0),
            ("nocturne", "#C9D6EA", "#E0B35A", 1, 3),
            ("bigboard", "#3DDC84", "#FFB224", 1, 0),
            ("outrun-horizon", "#2DE2E6", "#FF3F8E", 1.5, 4),
            ("terminal-grid", "#C8C8C4", "#FF6A1F", 1, 0),
        ]
        for (name, focus, waiting, thickness, radius) in expected {
            let resolved = try XCTUnwrap(try bundled(name), name)
            XCTAssertEqual(hex(resolved.focus), focus, name)
            XCTAssertEqual(hex(resolved.waiting), waiting, name)
            XCTAssertEqual(resolved.thicknessPt, thickness, name)
            XCTAssertEqual(resolved.cornerRadius, radius, name)
        }
        XCTAssertNil(try bundled("stage11"), "stage11 stays frameless")
        XCTAssertNil(try bundled("c11"), "c11 stays frameless")
    }

    // MARK: Geometry

    func testACornerOnTheWindowsCornerFollowsTheWindowRadius() {
        let corners = PortalWindowCorners(bounds: NSRect(x: 0, y: 0, width: 1000, height: 800), radius: 16)
        let bottomRight = AreaFrameGeometry.cornerRadii(
            for: NSRect(x: 500, y: 0, width: 500, height: 760), radius: 2, windowCorners: corners
        )
        XCTAssertEqual(bottomRight.maxXMinY, 16)
        XCTAssertEqual(bottomRight.minXMinY, 2)
        XCTAssertEqual(bottomRight.maxXMaxY, 2)
        XCTAssertEqual(bottomRight.minXMaxY, 2)

        let inner = AreaFrameGeometry.cornerRadii(
            for: NSRect(x: 200, y: 0, width: 300, height: 760), radius: 0, windowCorners: corners
        )
        XCTAssertEqual(inner, AreaFrameCornerRadii(0))
        XCTAssertEqual(
            AreaFrameGeometry.cornerRadii(for: NSRect(x: 500, y: 0, width: 500, height: 760), radius: 3, windowCorners: nil),
            AreaFrameCornerRadii(3),
            "full screen has square window corners"
        )
    }

    func testRingCoversOnlyTheBandInsideTheArea() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 50)
        let square = AreaFrameGeometry.ringPath(rect: rect, thickness: 2, radii: AreaFrameCornerRadii(0))
        XCTAssertTrue(square.contains(NSPoint(x: 1, y: 25)), "left edge")
        XCTAssertTrue(square.contains(NSPoint(x: 99, y: 25)), "right edge")
        XCTAssertTrue(square.contains(NSPoint(x: 50, y: 1)), "bottom edge")
        XCTAssertTrue(square.contains(NSPoint(x: 50, y: 49)), "top edge")
        XCTAssertFalse(square.contains(NSPoint(x: 50, y: 25)), "the content is not covered")
        XCTAssertFalse(square.contains(NSPoint(x: 3, y: 25)), "nothing past the thickness")
        XCTAssertFalse(square.contains(NSPoint(x: -1, y: 25)), "nothing outside the area")

        let rounded = AreaFrameGeometry.ringPath(rect: rect, thickness: 2, radii: AreaFrameCornerRadii(10))
        XCTAssertFalse(rounded.contains(NSPoint(x: 1, y: 1)), "outside the corner arc")
        let onArc = 10 - 9 / CGFloat(2).squareRoot()
        XCTAssertTrue(rounded.contains(NSPoint(x: onArc, y: onArc)), "on the corner arc")
        XCTAssertFalse(rounded.contains(NSPoint(x: 50, y: 25)))
    }

    func testRingSnapsToDevicePixels() {
        let snapped = AreaFrameGeometry.snapped(NSRect(x: 10.3, y: 20.26, width: 100.4, height: 50), scale: 2)
        XCTAssertEqual(snapped, NSRect(x: 10.5, y: 20.5, width: 100, height: 50))
        XCTAssertEqual(AreaFrameGeometry.snappedThickness(1.5, scale: 2), 1.5)
        XCTAssertEqual(AreaFrameGeometry.snappedThickness(1.5, scale: 1), 2)
        XCTAssertEqual(AreaFrameGeometry.snappedThickness(0.2, scale: 2), 0.5, "never thinner than one device pixel")
    }

    // MARK: Redraw requests

    /// SwiftUI re-lays the anchor out on every tab title change in its area, and an
    /// agent retitles its terminal often; only a real change may redraw the overlays.
    @MainActor
    func testAnUnchangedStrokeOrFrameAsksForNoRedraw() {
        let anchor = AreaFrameAnchorView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        anchor.stroke = AreaFrameStroke(color: white, thicknessPt: 1, cornerRadius: 0)
        let start = anchor.redrawRequestCount
        XCTAssertEqual(start, 1, "a new stroke asks once")

        // The same values again, the stroke from a freshly resolved colour.
        anchor.stroke = AreaFrameStroke(color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), thicknessPt: 1, cornerRadius: 0)
        anchor.setFrameSize(NSSize(width: 300, height: 200))
        anchor.setFrameOrigin(.zero)
        anchor.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(anchor.redrawRequestCount, start, "same stroke and geometry ask for nothing")

        anchor.setFrameSize(NSSize(width: 320, height: 200))
        XCTAssertEqual(anchor.redrawRequestCount, start + 1, "a resize asks once")
        anchor.setFrameOrigin(NSPoint(x: 12, y: 0))
        XCTAssertEqual(anchor.redrawRequestCount, start + 2, "a move asks once")
        anchor.stroke = AreaFrameStroke(color: orange, thicknessPt: 1, cornerRadius: 0)
        XCTAssertEqual(anchor.redrawRequestCount, start + 3, "a new colour asks once")
        anchor.stroke = nil
        XCTAssertEqual(anchor.redrawRequestCount, start + 4, "clearing the frame asks once, to erase it")
        anchor.setFrameSize(NSSize(width: 400, height: 200))
        XCTAssertEqual(anchor.redrawRequestCount, start + 4, "an unframed area never asks")
    }

    /// The workspace view re-renders on every theme version bump and resolves a new
    /// palette; equal values must leave the anchor's body alone.
    @MainActor
    func testAnchorInputsCompareByValue() {
        let controller = BonsplitController()
        let paneId = PaneID()
        func palette() -> AreaFramePalette {
            AreaFramePalette(
                focus: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                waiting: NSColor(srgbRed: 1, green: 0x4F / 255, blue: 0x1F / 255, alpha: 1),
                thicknessPt: 1,
                cornerRadius: 0
            )
        }
        let anchor = AreaFrameAnchor(palette: palette(), paneId: paneId, controller: controller, isWorkspaceInputActive: true)
        XCTAssertEqual(anchor, AreaFrameAnchor(palette: palette(), paneId: paneId, controller: controller, isWorkspaceInputActive: true))
        XCTAssertNotEqual(anchor, AreaFrameAnchor(palette: palette(), paneId: paneId, controller: controller, isWorkspaceInputActive: false))
        XCTAssertNotEqual(anchor, AreaFrameAnchor(palette: palette(), paneId: PaneID(), controller: controller, isWorkspaceInputActive: true))
        XCTAssertNotEqual(anchor, AreaFrameAnchor(palette: palette(), paneId: paneId, controller: BonsplitController(), isWorkspaceInputActive: true))
        var thicker = palette()
        thicker.thicknessPt = 2
        XCTAssertNotEqual(anchor, AreaFrameAnchor(palette: thicker, paneId: paneId, controller: controller, isWorkspaceInputActive: true))
        XCTAssertEqual(
            AreaFrameAnchorRepresentable(stroke: palette().stroke(isFocusedArea: true, hasWaitingPanel: false)),
            AreaFrameAnchorRepresentable(stroke: palette().stroke(isFocusedArea: true, hasWaitingPanel: false))
        )
    }
}
