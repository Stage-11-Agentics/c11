import XCTest
import SwiftUI
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral render tests for `SurfaceTitleBarView`.
///
/// Mounts the view in an `NSHostingView` at a fixed width and asserts layout
/// invariants rather than SwiftUI-internal pixel math. Tests assert *height
/// deltas* between states rather than absolute sizes so they stay robust as
/// SwiftUI's internal layout rounding evolves across OS versions.
final class TabTitleBarRenderTests: XCTestCase {

    private static let testWidth: CGFloat = 400

    private func measure(state: PanelTitleBarState) -> CGFloat {
        let host = NSHostingView(rootView: PanelTitleBarView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: Self.testWidth, height: 10_000)
        host.layoutSubtreeIfNeeded()
        let target = CGSize(width: Self.testWidth, height: NSView.noIntrinsicMetric)
        return host.fittingSize(for: target).height
    }

    func testExpandedMultiLineDescriptionTallerThanCollapsed() {
        let description = "First line of the description.\n\nSecond paragraph that adds height."

        let collapsed = PanelTitleBarState(title: "Ignored", description: description, collapsed: true)
        let expanded = PanelTitleBarState(title: "Ignored", description: description, collapsed: false)

        let collapsedHeight = measure(state: collapsed)
        let expandedHeight = measure(state: expanded)

        XCTAssertGreaterThan(
            expandedHeight,
            collapsedHeight + 8,
            "Expanded bar (\(expandedHeight)) must grow over the one-line collapsed bar (\(collapsedHeight))"
        )
    }

    func testNoDescriptionTakesNoHeight() {
        for collapsed in [true, false] {
            for description in [nil, "", "   \n "] as [String?] {
                let state = PanelTitleBarState(
                    title: "A perfectly good title",
                    description: description,
                    collapsed: collapsed
                )
                XCTAssertFalse(state.rendersBar)
                XCTAssertEqual(
                    measure(state: state), 0, accuracy: 0.5,
                    "A surface without a description must not reserve any bar height"
                )
            }
        }
    }

    func testTitleIsNeverRepeatedInTheBar() {
        // The bar shows only the description: a long title must not change its height.
        let description = "Short live description."
        let shortTitle = PanelTitleBarState(title: "zsh", description: description, collapsed: true)
        let longTitle = PanelTitleBarState(
            title: String(repeating: "very long title ", count: 20),
            description: description,
            collapsed: true
        )
        XCTAssertEqual(measure(state: shortTitle), measure(state: longTitle), accuracy: 0.5)
    }

    func testHiddenTitleBarNeverRenders() {
        let state = PanelTitleBarState(title: "t", description: "d", visible: false, collapsed: true)
        XCTAssertFalse(state.rendersBar)
        XCTAssertEqual(measure(state: state), 0, accuracy: 0.5)
    }

    func testDescriptionScrollCap() {
        // Long description must not grow the bar beyond the scroll cap.
        let longDescription = (0..<50)
            .map { "- item \($0)" }
            .joined(separator: "\n")
        let state = PanelTitleBarState(
            title: "Short title",
            description: longDescription,
            collapsed: false
        )

        let height = measure(state: state)

        // Scroll cap (90pt) + outer vertical padding (6+6) + separator, with slack.
        let ceiling: CGFloat = titleBarDescriptionMaxHeight + 40
        XCTAssertLessThanOrEqual(
            height, ceiling,
            "Title bar height \(height) must stay within scroll cap ceiling \(ceiling)"
        )
    }

    func testSingleLineFlattensNewlinesAndBlankRuns() {
        XCTAssertEqual(
            PanelTitleBarView.singleLine("Working on it.\n\n  Next: verify.  \n"),
            "Working on it. Next: verify."
        )
    }

    func testRenderingNeverFiresTheToggle() {
        var fireCount = 0
        let state = PanelTitleBarState(title: "t", description: "Some description", collapsed: false)
        let host = NSHostingView(rootView: PanelTitleBarView(state: state) { fireCount += 1 })
        host.frame = NSRect(x: 0, y: 0, width: Self.testWidth, height: 200)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(fireCount, 0, "Mounting the view must not invoke the toggle closure")
    }
}

private extension NSHostingView {
    /// Compute the view's fitting size at a target width. Falls back to
    /// `fittingSize` when the layout does not honor a fixed width.
    func fittingSize(for target: CGSize) -> CGSize {
        let fit = fittingSize
        if target.width.isFinite && target.width > 0 {
            frame = NSRect(x: 0, y: 0, width: target.width, height: fit.height)
            layoutSubtreeIfNeeded()
            return CGSize(width: target.width, height: fittingSize.height)
        }
        return fit
    }
}
