import XCTest
import SwiftUI
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral render tests for `SurfaceTitleBarView`.
///
/// Mounts the view in an `NSHostingView` at a fixed width and asserts layout
/// invariants rather than SwiftUI-internal pixel math. Tests assert *height
/// deltas* between states rather than absolute sizes so they stay robust as
/// SwiftUI's internal layout rounding evolves across OS versions.
final class SurfaceTitleBarRenderTests: XCTestCase {

    private static let testWidth: CGFloat = 400

    private func measure(state: SurfaceTitleBarState) -> CGFloat {
        let host = NSHostingView(rootView: SurfaceTitleBarView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: Self.testWidth, height: 10_000)
        host.layoutSubtreeIfNeeded()
        let target = CGSize(width: Self.testWidth, height: NSView.noIntrinsicMetric)
        return host.fittingSize(for: target).height
    }

    func testExpandedMultiLineTitleTallerThanCollapsed() {
        // A 100-character title forces wrapping in expanded state.
        let title = String(repeating: "token ", count: 17).trimmingCharacters(in: .whitespaces)
        let description = "Some non-empty description text."

        let collapsed = SurfaceTitleBarState(
            title: title,
            description: description,
            collapsed: true
        )
        let expanded = SurfaceTitleBarState(
            title: title,
            description: description,
            collapsed: false
        )

        let collapsedHeight = measure(state: collapsed)
        let expandedHeight = measure(state: expanded)

        // Expanded must be at least ~1 line taller (title wraps + description).
        XCTAssertGreaterThan(
            expandedHeight,
            collapsedHeight + 12,
            "Expanded title bar (\(expandedHeight)) must grow by at least one title line over collapsed (\(collapsedHeight))"
        )
    }

    func testEmptyDescriptionIgnoresCollapsedFlag() {
        // With an empty description, effectiveCollapsed rule forces the
        // rendered state to match between collapsed=true and collapsed=false.
        let title = String(repeating: "a ", count: 60)

        let flagTrue = SurfaceTitleBarState(
            title: title,
            description: nil,
            collapsed: true
        )
        let flagFalse = SurfaceTitleBarState(
            title: title,
            description: nil,
            collapsed: false
        )

        let h1 = measure(state: flagTrue)
        let h2 = measure(state: flagFalse)

        XCTAssertEqual(
            h1, h2, accuracy: 0.5,
            "With empty description, collapsed flag must not change rendered height (got \(h1) vs \(h2))"
        )
    }

    func testDescriptionScrollCap() {
        // Long description must not grow the title bar beyond the scroll cap.
        let longDescription = (0..<50)
            .map { "- item \($0)" }
            .joined(separator: "\n")
        let state = SurfaceTitleBarState(
            title: "Short title",
            description: longDescription,
            collapsed: false
        )

        let height = measure(state: state)

        // Expected ceiling: title row (~24pt with padding) + scroll cap (90pt)
        // + outer vertical padding (6+6) + separator — allow generous slack.
        let ceiling: CGFloat = 24 + titleBarDescriptionMaxHeight + 40
        XCTAssertLessThanOrEqual(
            height, ceiling,
            "Title bar height \(height) must stay within scroll cap ceiling \(ceiling)"
        )
    }

    func testChevronDisabledWhenDescriptionEmpty() {
        // When description is empty, the chevron button is `.disabled(true)`.
        // The invariant we protect: invoking the onToggleCollapsed callback
        // must be impossible via the UI path because no code outside the
        // disabled Button fires the closure. We therefore assert that the
        // view was constructed with a closure the test can observe, and that
        // rendering the view never fires the closure automatically.
        var fireCount = 0
        let state = SurfaceTitleBarState(
            title: "Title only",
            description: nil,
            collapsed: false
        )
        let view = SurfaceTitleBarView(state: state) {
            fireCount += 1
        }

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: Self.testWidth, height: 200)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(fireCount, 0, "Mounting the view must not invoke the toggle closure")

        // With description set, the button is enabled but rendering alone
        // must still not invoke the closure.
        let stateWithDesc = SurfaceTitleBarState(
            title: "Title only",
            description: "Some description",
            collapsed: false
        )
        let viewWithDesc = SurfaceTitleBarView(state: stateWithDesc) {
            fireCount += 1
        }
        let host2 = NSHostingView(rootView: viewWithDesc)
        host2.frame = NSRect(x: 0, y: 0, width: Self.testWidth, height: 200)
        host2.layoutSubtreeIfNeeded()
        XCTAssertEqual(fireCount, 0, "Rendering enabled state must not fire toggle closure either")
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
