import XCTest
@testable import cmux

final class StatusBarButtonDisplayTests: XCTestCase {
    func testZeroCount_buttonDisabledAndNoBadge() {
        let display = StatusBarButtonDisplay(unreadCount: 0)
        XCTAssertFalse(display.isEnabled)
        XCTAssertNil(display.badgeText)
        XCTAssertEqual(display.unreadCount, 0)
    }

    func testSingleUnread_buttonEnabledAndBadgeOne() {
        let display = StatusBarButtonDisplay(unreadCount: 1)
        XCTAssertTrue(display.isEnabled)
        XCTAssertEqual(display.badgeText, "1")
    }

    func testTwoDigitUnread_rendersExactCount() {
        let display = StatusBarButtonDisplay(unreadCount: 99)
        XCTAssertTrue(display.isEnabled)
        XCTAssertEqual(display.badgeText, "99")
    }

    func testThreeDigitUnread_capsAtNinetyNinePlus() {
        let display = StatusBarButtonDisplay(unreadCount: 100)
        XCTAssertTrue(display.isEnabled)
        XCTAssertEqual(display.badgeText, "99+")
    }

    func testLargeUnread_stillCapsAtNinetyNinePlus() {
        let display = StatusBarButtonDisplay(unreadCount: 5000)
        XCTAssertTrue(display.isEnabled)
        XCTAssertEqual(display.badgeText, "99+")
    }

    func testNegativeCount_clampedToZero() {
        // Defensive: notification counts should never be negative, but if a
        // caller passes one, we clamp to the disabled/no-badge state rather
        // than render "-3" or crash.
        let display = StatusBarButtonDisplay(unreadCount: -3)
        XCTAssertFalse(display.isEnabled)
        XCTAssertNil(display.badgeText)
        XCTAssertEqual(display.unreadCount, 0)
    }
}
