import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral unit tests for `FullDiskAccessProbe`. These exercise the timer,
/// backoff, and lifecycle observable through the public API; the static
/// `readsTCCDb()` is smoke-checked since its return value depends on whether
/// the host running the tests already has FDA granted.
final class FullDiskAccessProbeTests: XCTestCase {

    /// Lock-guarded counter for cross-thread tallying. Probe callbacks may
    /// run on the probe's private background queue, while assertions run on
    /// the test thread; `NSLock` keeps the read/write sides honest without
    /// pulling in any actor machinery.
    private final class Counter {
        private let lock = NSLock()
        private var _value: Int = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _value += 1
        }
    }

    // 1. Granted callback fires exactly once when probe returns true.
    func testProbeInvokesGrantedCallbackOnceWhenProbeReturnsTrue() {
        let counter = Counter()
        let granted = expectation(description: "onGranted invoked")
        let probe = FullDiskAccessProbe(
            probe: { true },
            schedule: [0.02],
            onGranted: {
                counter.increment()
                granted.fulfill()
            }
        )
        probe.start()
        wait(for: [granted], timeout: 5.0)
        XCTAssertEqual(counter.value, 1, "Granted should fire exactly once")
    }

    // 2. Granted is not invoked when the probe never returns true.
    func testProbeDoesNotInvokeGrantedWhenProbeReturnsFalse() {
        let counter = Counter()
        let probe = FullDiskAccessProbe(
            probe: { false },
            schedule: [0.02, 0.02, 0.02],
            onGranted: { counter.increment() }
        )
        probe.start()
        Thread.sleep(forTimeInterval: 0.2)
        probe.stop()
        XCTAssertEqual(counter.value, 0)
    }

    // 3. stop() cancels a pending tick before it fires.
    func testProbeStopCancelsPendingTick() {
        let probeCount = Counter()
        let granted = Counter()
        let probe = FullDiskAccessProbe(
            probe: { probeCount.increment(); return false },
            schedule: [0.5],
            onGranted: { granted.increment() }
        )
        probe.start()
        probe.stop()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(probeCount.value, 0, "No probe should run after immediate stop")
        XCTAssertEqual(granted.value, 0)
    }

    // 4. stop() is safe to call multiple times.
    func testProbeStopIsIdempotent() {
        let probe = FullDiskAccessProbe(
            probe: { false },
            schedule: [10.0],
            onGranted: { }
        )
        probe.start()
        probe.stop()
        probe.stop()
        probe.stop()
        // Smoke: no crash. Brief sleep lets queued operations drain so
        // the probe isn't deallocated mid-flight.
        Thread.sleep(forTimeInterval: 0.05)
    }

    // 5. start() is idempotent — repeated calls do not double-arm.
    func testProbeStartIsIdempotent() {
        let counter = Counter()
        let probe = FullDiskAccessProbe(
            probe: { counter.increment(); return false },
            schedule: [0.05],
            onGranted: { }
        )
        probe.start()
        probe.start()
        probe.start()
        Thread.sleep(forTimeInterval: 0.5)
        probe.stop()
        // Single timer at 0.05s over ~0.5s yields ~10 ticks. Double-armed
        // would be ~20. Generous bounds account for CI timing jitter.
        XCTAssertLessThan(counter.value, 16,
            "Repeated start() must not double-arm the timer (got \(counter.value) ticks)"
        )
        XCTAssertGreaterThan(counter.value, 2,
            "Expected the timer to fire at all (got \(counter.value) ticks)"
        )
    }

    // 6. kick() runs an extra probe attempt without resetting backoff.
    func testProbeKickRunsExtraAttemptOutOfBand() {
        // schedule[0]=0.05 ensures the initial scheduled tick fires fast;
        // schedule[1]=10 keeps the next scheduled tick out of the test
        // window. The kick is the only additional probe attempt.
        let counter = Counter()
        let probe = FullDiskAccessProbe(
            probe: { counter.increment(); return false },
            schedule: [0.05, 10.0],
            onGranted: { }
        )
        probe.start()
        Thread.sleep(forTimeInterval: 0.1)  // initial scheduled tick fires
        probe.kick()                         // out-of-band extra attempt
        Thread.sleep(forTimeInterval: 0.1)
        probe.stop()
        XCTAssertEqual(counter.value, 2,
            "Expected initial scheduled tick + kick = 2 probe attempts"
        )
    }

    // 7. nextDelay produces the expected backoff sequence with last-repeat.
    func testBackoffScheduleProducesExpectedDelays() {
        let schedule: [TimeInterval] = [0.5, 1, 2, 4, 8, 10]
        var observed: [TimeInterval] = []
        for index in 0..<7 {
            observed.append(
                FullDiskAccessProbe.nextDelay(forAttempt: index, schedule: schedule)
            )
        }
        XCTAssertEqual(observed, [0.5, 1, 2, 4, 8, 10, 10])
    }

    // 8. readsTCCDb is a guarded boolean — never crashes regardless of FDA state.
    func testTCCDbProbeReturnsBoolWithoutCrashing() {
        _ = FullDiskAccessProbe.readsTCCDb()
        // No crash = pass; we don't assert the value (host may or may not have FDA).
    }
}
