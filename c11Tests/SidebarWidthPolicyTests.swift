import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testContentViewClampAllowsNarrowSidebarBelowLegacyMinimum() {
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            184,
            accuracy: 0.001
        )
    }
}

final class SidebarScrollIndicatorMetricsTests: XCTestCase {
    func testNonScrollableContentFillsIndicatorTrack() {
        let metrics = SidebarScrollIndicatorMetrics.resolve(
            documentHeight: 400,
            visibleHeight: 500,
            offsetFromTop: 100
        )

        XCTAssertFalse(metrics.isScrollable)
        XCTAssertEqual(metrics.position, 0)
        XCTAssertEqual(metrics.knobProportion, 1)
    }

    func testScrollableContentReportsViewportAndPosition() {
        let metrics = SidebarScrollIndicatorMetrics.resolve(
            documentHeight: 1_000,
            visibleHeight: 250,
            offsetFromTop: 375
        )

        XCTAssertTrue(metrics.isScrollable)
        XCTAssertEqual(metrics.position, 0.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.knobProportion, 0.25, accuracy: 0.0001)
    }

    func testOverscrollPositionIsClampedToTrack() {
        let aboveTop = SidebarScrollIndicatorMetrics.resolve(
            documentHeight: 1_000,
            visibleHeight: 250,
            offsetFromTop: -80
        )
        let belowBottom = SidebarScrollIndicatorMetrics.resolve(
            documentHeight: 1_000,
            visibleHeight: 250,
            offsetFromTop: 900
        )

        XCTAssertEqual(aboveTop.position, 0)
        XCTAssertEqual(belowBottom.position, 1)
    }

    func testDocumentOriginMapsTopAndBottomForBothCoordinateDirections() {
        let bounds = CGRect(x: 0, y: 20, width: 400, height: 1_000)

        XCTAssertEqual(
            SidebarScrollIndicatorMetrics.documentOriginY(
                position: 0,
                documentBounds: bounds,
                visibleHeight: 250,
                isFlipped: true
            ),
            20
        )
        XCTAssertEqual(
            SidebarScrollIndicatorMetrics.documentOriginY(
                position: 1,
                documentBounds: bounds,
                visibleHeight: 250,
                isFlipped: true
            ),
            770
        )
        XCTAssertEqual(
            SidebarScrollIndicatorMetrics.documentOriginY(
                position: 0,
                documentBounds: bounds,
                visibleHeight: 250,
                isFlipped: false
            ),
            770
        )
        XCTAssertEqual(
            SidebarScrollIndicatorMetrics.documentOriginY(
                position: 1,
                documentBounds: bounds,
                visibleHeight: 250,
                isFlipped: false
            ),
            20
        )
    }

    @MainActor
    func testControllerReclaimsStockScrollerAfterConfigurationRestoresIt() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 250))
        scrollView.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 1_000))
        scrollView.hasVerticalScroller = true

        let controller = SidebarScrollIndicatorController()
        controller.attach(scrollView: scrollView)
        XCTAssertFalse(scrollView.hasVerticalScroller)

        // Model SwiftUI restoring its edge scroller after the initial attach.
        scrollView.hasVerticalScroller = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertFalse(scrollView.hasVerticalScroller)
    }

    @MainActor
    func testControllerReclaimsStockScrollerDuringScrollSynchronization() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 250))
        scrollView.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 1_000))

        let controller = SidebarScrollIndicatorController()
        controller.attach(scrollView: scrollView)
        scrollView.hasVerticalScroller = true
        controller.scroll(to: 0.5)

        XCTAssertFalse(scrollView.hasVerticalScroller)
    }
}
