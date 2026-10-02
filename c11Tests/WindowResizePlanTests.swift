import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// cmux #9826: hand-sized windows made repeated computer-use runs incomparable.
final class WindowResizePlanTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    func testLargerFramePreservesTopLeft() {
        let result = WindowResizePlan.decide(frame: frame, width: 1200, height: 800,
                                             minSize: CGSize(width: 400, height: 300), visibleFrame: visible)
        XCTAssertEqual(result.frame, CGRect(x: 100, y: -100, width: 1200, height: 800))
        XCTAssertEqual(result.frame.maxY, frame.maxY)
        XCTAssertFalse(result.clamped)
        XCTAssertTrue(result.write)
    }

    func testTinyFrameClampsToWindowMinimum() {
        let result = WindowResizePlan.decide(frame: frame, width: 100, height: 100,
                                             minSize: CGSize(width: 480, height: 360), visibleFrame: visible)
        XCTAssertEqual(result.frame.size, CGSize(width: 480, height: 360))
        XCTAssertEqual(result.frame.maxY, frame.maxY)
        XCTAssertTrue(result.clamped)
    }

    func testOversizeClampsWithoutSlidingWindow() {
        let result = WindowResizePlan.decide(frame: frame, width: 5000, height: nil,
                                             minSize: CGSize(width: 400, height: 300),
                                             visibleFrame: CGRect(x: -1440, y: 500, width: 1440, height: 900))
        XCTAssertEqual(result.frame.width, 1440)
        XCTAssertEqual(result.frame.origin, frame.origin)
        XCTAssertTrue(result.clamped)
    }

    func testReadReturnsExactFrameWithoutWrite() {
        let result = WindowResizePlan.decide(frame: frame, width: nil, height: nil,
                                             minSize: CGSize(width: 900, height: 900), visibleFrame: .zero)
        XCTAssertEqual(result.frame, frame)
        XCTAssertFalse(result.clamped)
        XCTAssertFalse(result.write)
    }

    func testHeightOnlyKeepsWidthAndTop() {
        let result = WindowResizePlan.decide(frame: frame, width: nil, height: 900,
                                             minSize: CGSize(width: 900, height: 300), visibleFrame: visible)
        XCTAssertEqual(result.frame.size, CGSize(width: 800, height: 900))
        XCTAssertEqual(result.frame.maxY, frame.maxY)
        XCTAssertFalse(result.clamped)
    }

    func testMinimumWinsWhenScreenIsSmaller() {
        let result = WindowResizePlan.decide(frame: frame, width: 5000, height: 5000,
                                             minSize: CGSize(width: 480, height: 360),
                                             visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(result.frame.size, CGSize(width: 480, height: 360))
        XCTAssertTrue(result.clamped)
    }

    func testScreenlessWindowUsesOnlyMinimum() {
        let result = WindowResizePlan.decide(frame: frame, width: 5000, height: -1,
                                             minSize: CGSize(width: 480, height: 360), visibleFrame: nil)
        XCTAssertEqual(result.frame.size, CGSize(width: 5000, height: 360))
        XCTAssertTrue(result.clamped)
    }
}
