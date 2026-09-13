import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure, in-process tests for `HangPrecursorTracker` — the cross-episode memory
/// that turns a run of short same-cause stalls into one warning before the wedge
/// they predict arrives. Uptimes are injected, so these exercise real policy
/// without threads or a wall clock.
final class HangPrecursorTrackerTests: XCTestCase {

    private let xpcFingerprint = ["main-thread-hang", "xpc-sync-wait"]
    private let swiftUIFingerprint = ["main-thread-hang", "swiftui-update", "hosting-layout"]

    /// Feed one episode. Defaults match a short stall of the kind that used to
    /// vanish into the local log unreported.
    @discardableResult
    private func record(
        _ tracker: inout HangPrecursorTracker,
        fingerprint: [String]? = nil,
        cause: String? = nil,
        culprit: String? = nil,
        durationMs: Double = 2500,
        at uptime: Double
    ) -> HangPrecursorTracker.Precursor? {
        let fp = fingerprint ?? xpcFingerprint
        return tracker.record(
            fingerprint: fp,
            cause: cause ?? fp[1],
            culprit: culprit,
            durationMs: durationMs,
            nowUptime: uptime
        )
    }

    // MARK: Firing threshold

    func testFewerThanThresholdInWindowDoesNotFire() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        XCTAssertNil(record(&tracker, at: 1000))
        XCTAssertNil(record(&tracker, at: 1100))
    }

    func testThresholdInWindowFiresOnceWithTheRunDetail() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        XCTAssertNil(record(&tracker, durationMs: 2400, at: 1000))
        XCTAssertNil(record(&tracker, durationMs: 6180, at: 1120))

        let precursor = record(
            &tracker, culprit: "$s3c1113BrowserPanelC6reloadyyF", durationMs: 10740, at: 1300
        )
        XCTAssertEqual(
            precursor,
            HangPrecursorTracker.Precursor(
                fingerprint: xpcFingerprint,
                cause: "xpc-sync-wait",
                culprit: "$s3c1113BrowserPanelC6reloadyyF",
                count: 3,
                windowMs: 600_000,
                durationsMs: [2400, 6180, 10740],
                spanMs: 300_000
            )
        )
    }

    /// The whole point of the ticket: the C11-209 shape — short same-cause
    /// stalls, each individually below the Sentry threshold — has to produce a
    /// signal before the long one lands.
    func testShortSubThresholdEpisodesStillProduceAWarning() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        XCTAssertNil(record(&tracker, durationMs: 2400, at: 100))
        XCTAssertNil(record(&tracker, durationMs: 2600, at: 200))
        let precursor = record(&tracker, durationMs: 3100, at: 300)
        XCTAssertNotNil(precursor)
        XCTAssertEqual(precursor?.durationsMs, [2400, 2600, 3100])
    }

    // MARK: Re-arm

    func testDoesNotFireAgainWhileTheWindowStillCoversTheLastWarning() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        for uptime in [1000.0, 1100.0] { XCTAssertNil(record(&tracker, at: uptime)) }
        XCTAssertNotNil(record(&tracker, at: 1200))

        // Three more of the same, all inside the window that follows the fire.
        for uptime in [1250.0, 1300.0, 1350.0, 1400.0] {
            XCTAssertNil(record(&tracker, at: uptime), "re-fired at \(uptime)")
        }
    }

    func testFiresAgainOnceTheWindowHasSlidPastTheLastWarning() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        for uptime in [1000.0, 1100.0] { XCTAssertNil(record(&tracker, at: uptime)) }
        XCTAssertNotNil(record(&tracker, at: 1200))

        // A fresh run, far enough out that the window no longer covers the fire.
        XCTAssertNil(record(&tracker, at: 1810))
        XCTAssertNil(record(&tracker, at: 1850))
        let second = record(&tracker, at: 1900)
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.count, 3)
    }

    // MARK: Independence

    func testDifferentFingerprintsAccumulateAndFireIndependently() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)

        // Interleave two causes; neither should borrow the other's episodes.
        XCTAssertNil(record(&tracker, fingerprint: xpcFingerprint, at: 1000))
        XCTAssertNil(record(&tracker, fingerprint: swiftUIFingerprint, at: 1010))
        XCTAssertNil(record(&tracker, fingerprint: xpcFingerprint, at: 1020))
        XCTAssertNil(record(&tracker, fingerprint: swiftUIFingerprint, at: 1030))

        let xpc = record(&tracker, fingerprint: xpcFingerprint, at: 1040)
        XCTAssertEqual(xpc?.fingerprint, xpcFingerprint)
        XCTAssertEqual(xpc?.count, 3)

        // The other fingerprint is unaffected by the fire and fires on its own
        // third episode.
        let swiftUI = record(&tracker, fingerprint: swiftUIFingerprint, at: 1050)
        XCTAssertEqual(swiftUI?.fingerprint, swiftUIFingerprint)
        XCTAssertEqual(swiftUI?.cause, "swiftui-update")
        XCTAssertEqual(swiftUI?.count, 3)
    }

    // MARK: Excluded causes

    func testRunLoopIdleNeverFiresHoweverOftenItRepeats() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        let idle = ["main-thread-hang", MainThreadHangSignature.runLoopIdleCause]
        for uptime in stride(from: 1000.0, through: 1200.0, by: 10.0) {
            XCTAssertNil(
                record(&tracker, fingerprint: idle, cause: MainThreadHangSignature.runLoopIdleCause, at: uptime)
            )
        }
        // Excluded episodes are not retained either — they cannot crowd a real
        // run out of the bounded ring.
        XCTAssertEqual(tracker.retainedCount, 0)
    }

    func testExcludedCauseDoesNotContributeToAnotherFingerprintsRun() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        let idle = ["main-thread-hang", MainThreadHangSignature.runLoopIdleCause]
        XCTAssertNil(record(&tracker, fingerprint: xpcFingerprint, at: 1000))
        XCTAssertNil(record(&tracker, fingerprint: idle, cause: MainThreadHangSignature.runLoopIdleCause, at: 1010))
        XCTAssertNil(record(&tracker, fingerprint: xpcFingerprint, at: 1020))
        XCTAssertNotNil(record(&tracker, fingerprint: xpcFingerprint, at: 1030))
    }

    func testEmptyFingerprintIsIgnored() {
        var tracker = HangPrecursorTracker(threshold: 2, windowSeconds: 600)
        XCTAssertNil(tracker.record(
            fingerprint: [], cause: "other", culprit: nil, durationMs: 3000, nowUptime: 1000
        ))
        XCTAssertNil(tracker.record(
            fingerprint: [], cause: "other", culprit: nil, durationMs: 3000, nowUptime: 1010
        ))
        XCTAssertEqual(tracker.retainedCount, 0)
    }

    // MARK: Aging

    func testEpisodesSpreadWiderThanTheWindowNeverAccumulate() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        // One every eleven minutes: a chronic annoyance, not a wedge forming.
        for uptime in stride(from: 1000.0, through: 5000.0, by: 660.0) {
            XCTAssertNil(record(&tracker, at: uptime), "fired at \(uptime)")
        }
    }

    func testOldEntriesAgeOutOfTheWindow() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        XCTAssertNil(record(&tracker, at: 1000))
        XCTAssertNil(record(&tracker, at: 1010))
        XCTAssertEqual(tracker.retainedCount, 2)

        // Both are now outside the window; the third episode stands alone.
        XCTAssertNil(record(&tracker, at: 2000))
        XCTAssertEqual(tracker.retainedCount, 1)
    }

    func testAgedOutEpisodesCannotCompleteALaterRun() {
        var tracker = HangPrecursorTracker(threshold: 3, windowSeconds: 600)
        XCTAssertNil(record(&tracker, at: 1000))
        XCTAssertNil(record(&tracker, at: 1010))
        // 1000 and 1010 have expired by 1700; these two are a run of two.
        XCTAssertNil(record(&tracker, at: 1700))
        XCTAssertNil(record(&tracker, at: 1710))
        // The third live one completes the run.
        XCTAssertEqual(record(&tracker, at: 1720)?.count, 3)
    }

    // MARK: Bounded cost

    func testRingIsCappedAndEvictsOldestFirst() {
        var tracker = HangPrecursorTracker(threshold: 100, windowSeconds: 100_000, maxEntries: 8)
        for i in 0..<50 {
            XCTAssertNil(record(&tracker, at: 1000 + Double(i)))
        }
        XCTAssertEqual(tracker.retainedCount, 8)

        // The cap, not the window, is what limits the run: only the retained
        // eight can ever be counted.
        var capped = HangPrecursorTracker(threshold: 9, windowSeconds: 100_000, maxEntries: 8)
        for i in 0..<50 {
            XCTAssertNil(record(&capped, at: 1000 + Double(i)), "fired at index \(i)")
        }
    }
}
