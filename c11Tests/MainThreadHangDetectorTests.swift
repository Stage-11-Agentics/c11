import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure, in-process tests for `MainThreadHangDetector` — the stall/recovery
/// state machine behind `MainThreadHangMonitor`. Timestamps are injected, so
/// these exercise real decision behavior without threads or a wall clock.
final class MainThreadHangDetectorTests: XCTestCase {

    // Decisions carry Doubles derived from subtraction, so compare with
    // tolerance rather than exact equality.
    private func assertCapture(
        _ decision: MainThreadHangDetector.Decision,
        gapMs: Double, recapture: Bool,
        _ file: StaticString = #filePath, _ line: UInt = #line
    ) {
        guard case let .capture(actualGap, actualRecapture) = decision else {
            return XCTFail("expected .capture, got \(decision)", file: file, line: line)
        }
        XCTAssertEqual(actualGap, gapMs, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actualRecapture, recapture, file: file, line: line)
    }

    private func assertRecovered(
        _ decision: MainThreadHangDetector.Decision,
        durationMs: Double,
        _ file: StaticString = #filePath, _ line: UInt = #line
    ) {
        guard case let .recovered(actual) = decision else {
            return XCTFail("expected .recovered, got \(decision)", file: file, line: line)
        }
        XCTAssertEqual(actual, durationMs, accuracy: 0.5, file: file, line: line)
    }

    // MARK: - No hang

    func testHealthyHeartbeatsNeverFire() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // Main acks ~250ms before each tick: gap stays ~250ms, well under threshold.
        var t = 100.0
        for _ in 0..<40 {
            XCTAssertEqual(d.evaluate(nowUptime: t, lastAckUptime: t - 0.25), .none)
            t += 0.25
        }
        XCTAssertFalse(d.isInEpisode)
    }

    func testGapBelowThresholdDoesNotFire() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // 1.9s gap — under the 2s threshold.
        XCTAssertEqual(d.evaluate(nowUptime: 110.0, lastAckUptime: 108.1), .none)
        XCTAssertFalse(d.isInEpisode)
    }

    // MARK: - Hang onset

    func testCrossingThresholdEmitsFirstCapture() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // ack frozen at t=100; by t=102.2 the gap is 2200ms.
        assertCapture(d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0), gapMs: 2200, recapture: false)
        XCTAssertTrue(d.isInEpisode)
    }

    func testFirstCaptureFiresExactlyOncePerEpisode() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        assertCapture(d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0), gapMs: 2200, recapture: false)
        // Still hung, but not yet time to re-snapshot (< 5s since last capture).
        XCTAssertEqual(d.evaluate(nowUptime: 103.0, lastAckUptime: 100.0), .none)
        XCTAssertEqual(d.evaluate(nowUptime: 105.0, lastAckUptime: 100.0), .none)
    }

    // MARK: - Recapture while still hung

    func testRecaptureAfterIntervalWhileStillHung() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        assertCapture(d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0), gapMs: 2200, recapture: false)
        // 5s after the first capture (t=107.2): re-snapshot.
        assertCapture(d.evaluate(nowUptime: 107.2, lastAckUptime: 100.0), gapMs: 7200, recapture: true)
    }

    // MARK: - Recovery

    func testRecoveryEmitsEpisodeDuration() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // Episode starts: ack frozen at 100, detected at 102.2.
        _ = d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0)
        XCTAssertTrue(d.isInEpisode)
        // Main recovers: ack jumps to 104.0 (it drained the queued ping). The
        // episode lasted from 100.0 until now (104.05) ≈ 4050ms.
        assertRecovered(d.evaluate(nowUptime: 104.05, lastAckUptime: 104.0), durationMs: 4050)
        XCTAssertFalse(d.isInEpisode)
    }

    func testRecoveryThenSecondHangIsANewEpisode() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        _ = d.evaluate(nowUptime: 102.2, lastAckUptime: 100.0)          // hang 1 begin
        _ = d.evaluate(nowUptime: 104.05, lastAckUptime: 104.0)         // hang 1 recover
        // New stall starting from a fresh frozen ack at 200.
        assertCapture(d.evaluate(nowUptime: 202.5, lastAckUptime: 200.0), gapMs: 2500, recapture: false)
    }

    func testNoRecoveredEventWithoutAPriorEpisode() {
        var d = MainThreadHangDetector(stallThresholdMs: 2000, recaptureIntervalMs: 5000)
        // Healthy from the start — a small gap must not be reported as recovery.
        XCTAssertEqual(d.evaluate(nowUptime: 100.1, lastAckUptime: 100.0), .none)
    }
}
