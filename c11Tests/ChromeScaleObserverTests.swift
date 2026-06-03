import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `ChromeScaleObserver` — the small NSObject KVO helper each
/// `Workspace` holds. KVO callbacks fire on the writer's thread; the observer
/// hops to MainActor before invoking the closure. (C11-6 / MAJOR #4)
final class ChromeScaleObserverTests: XCTestCase {

    func testObserverFiresOnUserDefaultsChange() {
        let suite = "ChromeScaleObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let expectation = expectation(description: "onChange fires")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = false

        let observer = ChromeScaleObserver(defaults: defaults) {
            expectation.fulfill()
        }
        defer { _ = observer } // keep alive until end of test scope

        defaults.set("large", forKey: ChromeScaleSettings.presetKey)

        wait(for: [expectation], timeout: 2.0)
    }

    func testObserverFiresMultipleTimesOnRepeatedWrites() {
        let suite = "ChromeScaleObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let expectation = expectation(description: "onChange fires multiple times")
        expectation.expectedFulfillmentCount = 3
        expectation.assertForOverFulfill = false

        let observer = ChromeScaleObserver(defaults: defaults) {
            expectation.fulfill()
        }
        defer { _ = observer }

        defaults.set("compact",    forKey: ChromeScaleSettings.presetKey)
        defaults.set("large",      forKey: ChromeScaleSettings.presetKey)
        defaults.set("extraLarge", forKey: ChromeScaleSettings.presetKey)

        wait(for: [expectation], timeout: 2.0)
    }

    func testObserverFiresOnCustomMultiplierChange() {
        let suite = "ChromeScaleObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let expectation = expectation(description: "onChange fires for custom multiplier")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = false

        let observer = ChromeScaleObserver(defaults: defaults) {
            expectation.fulfill()
        }
        defer { _ = observer }

        defaults.set(1.75, forKey: ChromeScaleSettings.customMultiplierKey)

        wait(for: [expectation], timeout: 2.0)
    }

    func testObserverDeinitDoesNotCrashOnSubsequentMutation() {
        // After the observer is released, KVO is removed in deinit. Subsequent
        // mutations to the same defaults must not crash (which they would if the
        // observer had not removed itself and was sent observeValue after dealloc).
        let suite = "ChromeScaleObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        autoreleasepool {
            let observer = ChromeScaleObserver(defaults: defaults) { /* discarded */ }
            _ = observer // suppress unused warning
        }

        // Observer is now deallocated. This should not crash.
        defaults.set("large", forKey: ChromeScaleSettings.presetKey)
    }
}
