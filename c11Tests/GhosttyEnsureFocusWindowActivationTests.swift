import XCTest
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class GhosttyEnsureFocusWindowActivationTests: XCTestCase {
    func testAllowsActivationForActiveManager() {
        let activeManager = TabManager()
        let otherManager = TabManager()
        let targetWindow = NSWindow()
        let otherWindow = NSWindow()

        XCTAssertTrue(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: activeManager,
                targetTabManager: activeManager,
                keyWindow: targetWindow,
                mainWindow: targetWindow,
                targetWindow: targetWindow
            )
        )
        XCTAssertFalse(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: activeManager,
                targetTabManager: otherManager,
                keyWindow: otherWindow,
                mainWindow: otherWindow,
                targetWindow: targetWindow
            )
        )
    }

    func testAllowsActivationWhenAppHasNoKeyAndNoMainWindow() {
        let targetManager = TabManager()
        let targetWindow = NSWindow()

        XCTAssertTrue(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: nil,
                mainWindow: nil,
                targetWindow: targetWindow
            )
        )
        XCTAssertFalse(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: NSWindow(),
                mainWindow: nil,
                targetWindow: targetWindow
            )
        )
        XCTAssertFalse(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: nil,
                mainWindow: NSWindow(),
                targetWindow: targetWindow
            )
        )
    }
}

final class IdleSpinDebounceTests: XCTestCase {
    func testCoalescingGuardReducesCallsToConstant() {
        // Models the coalescing guard behavior used in scheduleAutomaticFirstResponderApply
        // and the palette overlay update path. Firing N pending-check requests through
        // a boolean guard must produce O(1) actual work items, not O(N).
        var pendingFlag = false
        var actualCallCount = 0
        let expectedCallCount = 1
        let iterations = 1000

        let expectation = XCTestExpectation(description: "coalesced work item fires once")

        for _ in 0..<iterations {
            guard !pendingFlag else { continue }
            pendingFlag = true
            DispatchQueue.main.async {
                pendingFlag = false
                actualCallCount += 1
                if actualCallCount == expectedCallCount {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(actualCallCount, expectedCallCount, "Coalescing guard must reduce \(iterations) requests to exactly 1 actual call")
    }
}

final class ScrollbarRightEdgeInsetTests: XCTestCase {
    func testLegacyScrollerWidthIsNonZero() {
        // The Pick 9 fix subtracts NSScroller.scrollerWidth(for:.regular, scrollerStyle:.legacy)
        // from the surface width when the scroll view is in legacy mode. This test verifies
        // that the AppKit API returns a positive value so the inset arithmetic makes sense.
        let gutterWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        XCTAssertGreaterThan(gutterWidth, 0, "Legacy scroller gutter width must be positive")
    }

    func testOverlayScrollerWidthIsZero() {
        // The fix must NOT subtract anything in overlay mode (prior deliberate decision).
        // Overlay scrollers have zero width (they float over content).
        let overlayWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        XCTAssertEqual(overlayWidth, 0, "Overlay scroller width must be zero — it floats over content")
    }
}
