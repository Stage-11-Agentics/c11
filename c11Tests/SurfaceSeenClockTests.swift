import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-243: behavior of the per-tab "last seen" state machine and its
/// snapshot persistence. Drives the pure `SurfaceSeenClock`, so no AppKit
/// focus state is needed.
final class SurfaceSeenClockTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + s) }

    func testNeverSeenPanelReportsNil() {
        var clock = SurfaceSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertNil(clock.lastSeenAt(b, now: t(5)))
    }

    func testBeingSeenReportsNow() {
        var clock = SurfaceSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(42)), t(42))
    }

    func testStampedWhenTabSwitchedAway() {
        var clock = SurfaceSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertTrue(clock.observe(seen: b, at: t(10)))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(99)), t(10))
        XCTAssertEqual(clock.lastSeenAt(b, now: t(99)), t(99))
    }

    func testStampedWhenNothingSeenAnymore() {
        // App deactivated, window resigned key, screen locked: seen becomes nil.
        var clock = SurfaceSeenClock()
        clock.observe(seen: a, at: t(0))
        clock.observe(seen: nil, at: t(7))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(50)), t(7))
        // Coming back does not rewrite the old stamp until it leaves again.
        clock.observe(seen: a, at: t(60))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(70)), t(70))
        clock.observe(seen: nil, at: t(80))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(90)), t(80))
    }

    func testRepeatedObservationOfSamePanelDoesNotRestamp() {
        var clock = SurfaceSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertFalse(clock.observe(seen: a, at: t(5)))
        clock.observe(seen: nil, at: t(9))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(20)), t(9))
    }

    func testNoStampWhenNothingWasSeen() {
        // Background/programmatic focus change while c11 is inactive: seen stays nil.
        var clock = SurfaceSeenClock()
        XCTAssertFalse(clock.observe(seen: nil, at: t(1)))
        XCTAssertNil(clock.lastSeenAt(a, now: t(2)))
    }

    func testSeedRestoresStampButNeverOverridesLiveState() {
        var clock = SurfaceSeenClock()
        clock.seed(a, at: t(3))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(50)), t(3))
        clock.observe(seen: a, at: t(10))
        clock.seed(a, at: t(1))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(20)), t(20))
        clock.observe(seen: nil, at: t(30))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(40)), t(30))
        // An older seed never rolls a newer stamp back.
        clock.seed(a, at: t(2))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(40)), t(30))
    }

    func testForgetClearsPanel() {
        var clock = SurfaceSeenClock()
        clock.observe(seen: a, at: t(0))
        clock.observe(seen: b, at: t(1))
        clock.forget(a)
        XCTAssertNil(clock.lastSeenAt(a, now: t(5)))
        clock.forget(b)
        XCTAssertNil(clock.current)
    }

    func testLastSeenAtRoundTripsThroughPanelSnapshot() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_123)
        func snapshot(_ lastSeenAt: Date?) -> SessionPanelSnapshot {
            SessionPanelSnapshot(
                id: UUID(), type: .terminal, title: nil, customTitle: nil,
                directory: nil, isPinned: false, isManuallyUnread: false,
                gitBranch: nil, listeningPorts: [], ttyName: nil,
                terminal: nil, browser: nil, markdown: nil,
                metadata: nil, metadataSources: nil, lastSeenAt: lastSeenAt
            )
        }
        let data = try JSONEncoder().encode(snapshot(stamp))
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("\"last_seen_at\""))
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        XCTAssertEqual(decoded.lastSeenAt, stamp)

        let legacy = try JSONEncoder().encode(snapshot(nil))
        XCTAssertNil(try JSONDecoder().decode(SessionPanelSnapshot.self, from: legacy).lastSeenAt)
    }
}
