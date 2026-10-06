import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-243: behavior of the per-tab "last seen" state machine and its
/// snapshot persistence. Drives the pure `SurfaceSeenClock`, so no AppKit
/// focus state is needed.
final class TabSeenClockTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + s) }

    func testNeverSeenPanelReportsNil() {
        var clock = PanelSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertNil(clock.lastSeenAt(b, now: t(5)))
    }

    func testBeingSeenReportsNow() {
        var clock = PanelSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(42)), t(42))
    }

    func testStampedWhenTabSwitchedAway() {
        var clock = PanelSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertTrue(clock.observe(seen: b, at: t(10)))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(99)), t(10))
        XCTAssertEqual(clock.lastSeenAt(b, now: t(99)), t(99))
    }

    func testStampedWhenNothingSeenAnymore() {
        // App deactivated, window resigned key, screen locked: seen becomes nil.
        var clock = PanelSeenClock()
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
        var clock = PanelSeenClock()
        clock.observe(seen: a, at: t(0))
        XCTAssertFalse(clock.observe(seen: a, at: t(5)))
        clock.observe(seen: nil, at: t(9))
        XCTAssertEqual(clock.lastSeenAt(a, now: t(20)), t(9))
    }

    func testNoStampWhenNothingWasSeen() {
        // Background/programmatic focus change while c11 is inactive: seen stays nil.
        var clock = PanelSeenClock()
        XCTAssertFalse(clock.observe(seen: nil, at: t(1)))
        XCTAssertNil(clock.lastSeenAt(a, now: t(2)))
    }

    func testSeedRestoresStampButNeverOverridesLiveState() {
        var clock = PanelSeenClock()
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
        var clock = PanelSeenClock()
        clock.observe(seen: a, at: t(0))
        clock.observe(seen: b, at: t(1))
        clock.forget(a)
        XCTAssertNil(clock.lastSeenAt(a, now: t(5)))
        clock.forget(b)
        XCTAssertNil(clock.current)
    }

    func testLastSeenAtRoundTripsThroughTabSnapshot() throws {
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

    // MARK: - Tracker (injected seen provider and clock)

    @MainActor
    private final class Harness {
        var seen: UUID?
        var time = Date(timeIntervalSince1970: 5_000)
        lazy var tracker = PanelSeenTracker(seenProvider: { [unowned self] in self.seen }, now: { [unowned self] in self.time }, screenLockedProvider: { false })
        func advance(_ s: TimeInterval) { time = time.addingTimeInterval(s) }
    }

    @MainActor
    func testTrackerStampsOnSwitchAndReportsBeingSeen() {
        let h = Harness()
        h.seen = a
        h.tracker.refresh()
        XCTAssertTrue(h.tracker.isBeingSeen(panelId: a))
        h.advance(10)
        h.seen = b
        h.tracker.refresh()
        XCTAssertFalse(h.tracker.isBeingSeen(panelId: a))
        XCTAssertTrue(h.tracker.isBeingSeen(panelId: b))
        XCTAssertEqual(h.tracker.lastSeenAt(panelId: a), Date(timeIntervalSince1970: 5_010))
    }

    @MainActor
    func testWakeWhileStillLockedStaysInterrupted() {
        let h = Harness()
        h.seen = a
        h.tracker.refresh()
        h.advance(5)
        h.tracker.setInterruption(.locked, active: true)
        h.tracker.setInterruption(.displaysAsleep, active: true)
        XCTAssertFalse(h.tracker.isBeingSeen(panelId: a))
        let stamp = h.tracker.lastSeenAt(panelId: a)
        XCTAssertEqual(stamp, Date(timeIntervalSince1970: 5_005))

        // Display wakes but the lock screen is still up: still not seen, no restamp.
        h.advance(30)
        h.tracker.setInterruption(.displaysAsleep, active: false)
        XCTAssertFalse(h.tracker.isBeingSeen(panelId: a))
        XCTAssertEqual(h.tracker.lastSeenAt(panelId: a), stamp)

        // Unlock lifts the last reason: seen again.
        h.tracker.setInterruption(.locked, active: false)
        XCTAssertTrue(h.tracker.isBeingSeen(panelId: a))
    }

    @MainActor
    func testInterruptionWithNothingSeenStampsNothing() {
        let h = Harness()
        h.tracker.setInterruption(.systemAsleep, active: true)
        h.tracker.setInterruption(.systemAsleep, active: false)
        XCTAssertNil(h.tracker.lastSeenAt(panelId: a))
    }

    @MainActor
    func testCloseThenForgetDropsStamp() {
        let h = Harness()
        h.seen = a
        h.tracker.refresh()
        h.seen = b
        h.tracker.refresh()
        XCTAssertNotNil(h.tracker.lastSeenAt(panelId: a))
        h.tracker.forget(panelId: a)
        XCTAssertNil(h.tracker.lastSeenAt(panelId: a))
    }

    @MainActor
    func testSeedThenSwitchOverridesRestoredStamp() {
        let h = Harness()
        h.tracker.seed(panelId: a, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(h.tracker.lastSeenAt(panelId: a), Date(timeIntervalSince1970: 100))
        h.seen = a
        h.tracker.refresh()
        h.advance(4)
        h.seen = nil
        h.tracker.refresh()
        XCTAssertEqual(h.tracker.lastSeenAt(panelId: a), Date(timeIntervalSince1970: 5_004))
    }

    @MainActor
    func testScreensaverWithoutStopIsHealedByAppActivation() {
        let h = Harness()
        h.seen = a
        h.tracker.refresh()
        h.tracker.setInterruption(.screensaver, active: true)
        h.tracker.setInterruption(.systemAsleep, active: true)
        XCTAssertFalse(h.tracker.isBeingSeen(panelId: a))
        // No didstop / didWake ever arrives; the app coming to the front proves both stale.
        h.tracker.appBecameActive()
        XCTAssertTrue(h.tracker.interruptions.isEmpty)
        XCTAssertTrue(h.tracker.isBeingSeen(panelId: a))
    }

    @MainActor
    func testActivationRederivesLockFromWindowServer() {
        var locked = true
        let seen = a
        let tracker = PanelSeenTracker(seenProvider: { seen }, now: { Date() }, screenLockedProvider: { locked })
        tracker.appBecameActive()
        XCTAssertEqual(tracker.interruptions, [.locked])
        XCTAssertFalse(tracker.isBeingSeen(panelId: a))
        // Unlock notification was missed; the window server says unlocked.
        locked = false
        tracker.appBecameActive()
        XCTAssertTrue(tracker.interruptions.isEmpty)
        XCTAssertTrue(tracker.isBeingSeen(panelId: a))
    }

    @MainActor
    func testStoredStampIsRawNotNow() {
        let h = Harness()
        h.seen = a
        h.tracker.refresh()
        XCTAssertNil(h.tracker.storedLastSeenAt(panelId: a))
        XCTAssertEqual(h.tracker.lastSeenAt(panelId: a), h.time)
        h.advance(8)
        h.seen = b
        h.tracker.refresh()
        h.advance(20)
        XCTAssertEqual(h.tracker.storedLastSeenAt(panelId: a), Date(timeIntervalSince1970: 5_008))
        XCTAssertNil(h.tracker.storedLastSeenAt(panelId: b))
        XCTAssertTrue(h.tracker.isBeingSeen(panelId: b))
    }
}
