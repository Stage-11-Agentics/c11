import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-101. Neither type is driven by a real signal or timer here: the
/// scheduler and every effect are fakes, so nothing is raised, quit or waited on.
final class SessionSaveDebouncerTests: XCTestCase {
    private final class Clock {
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduled.append((delay, work))
        }
        /// Runs and clears everything scheduled so far.
        func runAll() {
            let due = scheduled
            scheduled = []
            due.forEach { $0.work() }
        }
    }

    private func makeDebouncer(
        _ clock: Clock, fired: @escaping ([String]) -> Void
    ) -> SessionSaveDebouncer {
        SessionSaveDebouncer(
            schedule: { clock.schedule($0, $1) },
            fire: fired
        )
    }

    func testOneRequestSavesOnceAfterTheTwoSecondDelay() {
        let clock = Clock()
        var saves: [[String]] = []
        let debouncer = makeDebouncer(clock) { saves.append($0) }

        debouncer.request(source: "panels")
        XCTAssertEqual(clock.scheduled.map { $0.delay }, [2], "the delay is about two seconds")
        XCTAssertTrue(saves.isEmpty, "nothing saves before the delay passes")

        clock.runAll()
        XCTAssertEqual(saves, [["panels"]])
        XCTAssertFalse(debouncer.isPending)
    }

    func testABurstCoalescesIntoOneSaveThatNamesEverySource() {
        let clock = Clock()
        var saves: [[String]] = []
        let debouncer = makeDebouncer(clock) { saves.append($0) }

        debouncer.request(source: "panels")
        debouncer.request(source: "panel.title")
        debouncer.request(source: "panels")
        debouncer.request(source: "panel.move")

        XCTAssertEqual(clock.scheduled.count, 1, "one timer for the whole burst")
        clock.runAll()
        XCTAssertEqual(saves, [["panels", "panel.title", "panel.move"]])
    }

    func testTheDelayRunsFromTheFirstRequestSoAStreamCannotStarveTheSave() {
        let clock = Clock()
        var saveCount = 0
        let debouncer = makeDebouncer(clock) { _ in saveCount += 1 }

        debouncer.request(source: "a")
        // A later request must not push the deadline out by arming another timer.
        debouncer.request(source: "b")
        XCTAssertEqual(clock.scheduled.count, 1)
        clock.runAll()
        XCTAssertEqual(saveCount, 1)
    }

    func testARequestAfterASaveStartsANewCycle() {
        let clock = Clock()
        var saves: [[String]] = []
        let debouncer = makeDebouncer(clock) { saves.append($0) }

        debouncer.request(source: "first")
        clock.runAll()
        debouncer.request(source: "second")
        XCTAssertEqual(clock.scheduled.count, 1)
        clock.runAll()
        XCTAssertEqual(saves, [["first"], ["second"]])
    }

    func testRequestingFromInsideTheSaveSchedulesAnotherRatherThanLosingIt() {
        let clock = Clock()
        var saves: [[String]] = []
        var debouncer: SessionSaveDebouncer!
        debouncer = makeDebouncer(clock) { sources in
            saves.append(sources)
            if saves.count == 1 { debouncer.request(source: "retry") }
        }

        debouncer.request(source: "first")
        clock.runAll()
        XCTAssertEqual(clock.scheduled.count, 1, "the in-flight tick's retry is armed")
        clock.runAll()
        XCTAssertEqual(saves, [["first"], ["retry"]])
    }

    func testCancelDropsTheWaitingSaveAndTheStaleTimerDoesNothing() {
        let clock = Clock()
        var saveCount = 0
        let debouncer = makeDebouncer(clock) { _ in saveCount += 1 }

        debouncer.request(source: "panels")
        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)
        clock.runAll()
        XCTAssertEqual(saveCount, 0, "a cancelled save must not race the final snapshot")
    }

    func testRequestAfterCancelWaitsItsOwnDelayAndTheStaleTimerCannotFireItEarly() {
        // A clock with time, so "early" is observable: the stale timer is due at
        // t=2, the live cycle (requested at t=1) is due at t=3.
        var now: TimeInterval = 0
        var queue: [(due: TimeInterval, work: () -> Void)] = []
        var saves: [[String]] = []
        let debouncer = SessionSaveDebouncer(
            schedule: { delay, work in queue.append((now + delay, work)) },
            fire: { saves.append($0) }
        )
        func advance(to time: TimeInterval) {
            now = time
            let due = queue.filter { $0.due <= time }
            queue.removeAll { $0.due <= time }
            due.forEach { $0.work() }
        }

        debouncer.request(source: "before")
        advance(to: 1)
        debouncer.cancel()
        debouncer.request(source: "after")

        advance(to: 2)
        XCTAssertTrue(saves.isEmpty, "the cancelled cycle's timer must not save the new cycle early")
        advance(to: 3)
        XCTAssertEqual(saves, [["after"]], "the live cycle saves once, at its own deadline")
    }
}

final class SessionAutosaveForcedSaveTests: XCTestCase {
    private func skips(forced: Bool, previous: Int?, current: Int?) -> Bool {
        AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint(
            forced: forced,
            isTerminatingApp: false,
            includeScrollback: false,
            previousFingerprint: previous,
            currentFingerprint: current,
            lastPersistedAt: Date(),
            now: Date()
        )
    }

    func testAnUnchangedFingerprintIsSkippedWhenNothingForcedTheSave() {
        XCTAssertTrue(skips(forced: false, previous: 7, current: 7))
    }

    func testAForcedSaveWritesEvenThoughNoHashedValueMoved() {
        // A panel rename changes no count the fingerprint hashes.
        XCTAssertFalse(skips(forced: true, previous: 7, current: 7))
    }

    func testAChangedFingerprintAlwaysWrites() {
        XCTAssertFalse(skips(forced: false, previous: 7, current: 8))
    }
}
