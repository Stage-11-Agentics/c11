import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class FeedQuickViewSelectionTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    func testInsertAndClockRefreshKeepIdentityRemovalChoosesOldIndexThenLast() {
        var selection = FeedQuickViewSelection()
        selection.update([id(1), id(2), id(3)])
        selection.move(1)
        XCTAssertEqual(selection.selectedTabID, id(2))
        selection.update([id(4), id(1), id(2), id(3)])
        XCTAssertEqual(selection.selectedTabID, id(2))
        selection.update([id(4), id(1), id(2), id(3)]) // Clock/display-only change.
        XCTAssertEqual(selection.selectedTabID, id(2))
        selection.update([id(4), id(1), id(3)])
        XCTAssertEqual(selection.selectedTabID, id(3))
        selection.update([id(4), id(1)])
        XCTAssertEqual(selection.selectedTabID, id(1))
        selection.update([])
        XCTAssertNil(selection.selectedTabID)
    }

    func testFilterKeepsSharedIdentityOtherwiseFirstAndArrowsClamp() {
        var selection = FeedQuickViewSelection()
        selection.update([id(1), id(2)])
        selection.select(id(2))
        selection.switchFilter(.turns, tabIDs: [id(3), id(2)])
        XCTAssertEqual(selection.selectedTabID, id(2))
        selection.switchFilter(.asks, tabIDs: [id(4), id(1)])
        XCTAssertEqual(selection.selectedTabID, id(4))
        selection.move(-100)
        XCTAssertEqual(selection.selectedTabID, id(4))
        selection.move(100)
        XCTAssertEqual(selection.selectedTabID, id(1))
        selection.select(id(9))
        XCTAssertEqual(selection.selectedTabID, id(1))
    }
}
