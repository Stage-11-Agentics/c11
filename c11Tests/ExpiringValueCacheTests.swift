import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-196: behavioral tests for the memoization seam that keeps repeated
/// LaunchServices lookups off the main thread's synchronous XPC path.
///
/// The clock is injected, so these run in-process with no sleeping and no real
/// `NSWorkspace` traffic. What they assert is the property the fix depends on:
/// N reads produce one recompute, not N.
final class ExpiringValueCacheTests: XCTestCase {

    private final class Clock {
        var now: TimeInterval = 0
        func read() -> TimeInterval { now }
    }

    func testFirstReadComputesAndSubsequentReadsWithinTTLDoNot() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 10, now: clock.read)
        var computeCount = 0

        let first = cache.value(orCompute: { computeCount += 1; return 42 })
        XCTAssertEqual(first, 42)
        XCTAssertEqual(computeCount, 1)

        clock.now = 9.9
        for _ in 0..<100 {
            XCTAssertEqual(cache.value(orCompute: { computeCount += 1; return 42 }), 42)
        }
        XCTAssertEqual(computeCount, 1, "reads inside the TTL window must reuse the stored value")
    }

    func testRecomputesOnceTheTTLWindowElapses() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 10, now: clock.read)
        var computeCount = 0
        let compute: () -> Int = { computeCount += 1; return computeCount }

        XCTAssertEqual(cache.value(orCompute: compute), 1)
        clock.now = 10
        XCTAssertEqual(cache.value(orCompute: compute), 2, "expiry must produce a fresh value")
        XCTAssertEqual(computeCount, 2)
    }

    func testFreshnessTracksTheTTLWindow() {
        let clock = Clock()
        let cache = ExpiringValueCache<String>(ttl: 5, now: clock.read)
        XCTAssertEqual(cache.freshness, .missing)

        cache.store("a")
        XCTAssertEqual(cache.freshness, .fresh)

        clock.now = 4.99
        XCTAssertEqual(cache.freshness, .fresh)

        clock.now = 5
        XCTAssertEqual(cache.freshness, .stale)
        XCTAssertEqual(cache.peek(), "a", "a stale value is still available to serve")
    }

    func testInvalidateForcesTheNextReadToRecompute() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 100, now: clock.read)
        var computeCount = 0
        let compute: () -> Int = { computeCount += 1; return computeCount }

        _ = cache.value(orCompute: compute)
        cache.invalidate()
        XCTAssertEqual(cache.freshness, .missing)
        XCTAssertNil(cache.peek())
        _ = cache.value(orCompute: compute)
        XCTAssertEqual(computeCount, 2)
    }

    func testBackgroundRefreshReturnsNilBeforeAnythingIsStored() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 10, now: clock.read)
        var scheduled: [() -> Void] = []

        let value = cache.valueRefreshingInBackground(
            scheduleRefresh: { scheduled.append($0) },
            refresh: { 7 }
        )

        XCTAssertNil(value, "cold start has nothing to serve")
        XCTAssertEqual(scheduled.count, 1, "cold start must schedule the first refresh")
    }

    func testBackgroundRefreshServesStaleValueWithoutBlocking() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 10, now: clock.read)
        cache.store(1)
        var scheduled: [() -> Void] = []
        var refreshCount = 0

        clock.now = 50
        let served = cache.valueRefreshingInBackground(
            scheduleRefresh: { scheduled.append($0) },
            refresh: { refreshCount += 1; return 2 }
        )

        XCTAssertEqual(served, 1, "the stale value is returned immediately")
        XCTAssertEqual(refreshCount, 0, "the recompute must not run on the caller's thread")
        XCTAssertEqual(scheduled.count, 1)

        scheduled.removeFirst()()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(cache.peek(), 2, "the completed refresh replaces the stored value")
        XCTAssertEqual(cache.freshness, .fresh)
    }

    func testBackgroundRefreshDoesNotStackWhileOneIsInFlight() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 10, now: clock.read)
        cache.store(1)
        var scheduled: [() -> Void] = []

        clock.now = 50
        for _ in 0..<25 {
            _ = cache.valueRefreshingInBackground(
                scheduleRefresh: { scheduled.append($0) },
                refresh: { 2 }
            )
        }

        XCTAssertEqual(scheduled.count, 1, "a burst of stale reads must coalesce into one refresh")

        scheduled.removeFirst()()
        clock.now = 200
        _ = cache.valueRefreshingInBackground(
            scheduleRefresh: { scheduled.append($0) },
            refresh: { 3 }
        )
        XCTAssertEqual(scheduled.count, 1, "a later staleness window can schedule again")
    }

    func testFreshReadsNeverScheduleARefresh() {
        let clock = Clock()
        let cache = ExpiringValueCache<Int>(ttl: 10, now: clock.read)
        cache.store(5)
        var scheduled = 0

        clock.now = 1
        for _ in 0..<10 {
            XCTAssertEqual(
                cache.valueRefreshingInBackground(
                    scheduleRefresh: { _ in scheduled += 1 },
                    refresh: { 6 }
                ),
                5
            )
        }
        XCTAssertEqual(scheduled, 0)
    }
}

/// C11-196: the command palette rebuilt the editor-availability set on every
/// keystroke, and each target it could not find on disk fell back to
/// `NSWorkspace.fullPath(forApplication:)`, an unbounded synchronous XPC wait.
/// These assert the cached accessor collapses that into one probe pass.
final class TerminalDirectoryOpenTargetCacheTests: XCTestCase {

    private final class ProbeCounter {
        private(set) var launchServicesLookups = 0

        func environment(
            existingPaths: Set<String> = [],
            applicationPathsByName: [String: String] = [:]
        ) -> TerminalDirectoryOpenTarget.DetectionEnvironment {
            TerminalDirectoryOpenTarget.DetectionEnvironment(
                homeDirectoryPath: "/Users/tester",
                fileExistsAtPath: { existingPaths.contains($0) },
                isExecutableFileAtPath: { existingPaths.contains($0) },
                applicationPathForName: { [weak self] name in
                    self?.launchServicesLookups += 1
                    return applicationPathsByName[name]
                }
            )
        }
    }

    func testRepeatedPaletteRefreshesIssueOneLaunchServicesProbePass() {
        let counter = ProbeCounter()
        let env = counter.environment(existingPaths: ["/Applications/Visual Studio Code.app"])
        let cache = ExpiringValueCache<Set<TerminalDirectoryOpenTarget>>(ttl: 60, now: { 0 })

        let first = TerminalDirectoryOpenTarget.availableTargetsCached(
            in: env,
            cache: cache,
            scheduleRefresh: { $0() }
        )
        XCTAssertTrue(first.contains(.vscode))
        let lookupsAfterFirst = counter.launchServicesLookups
        XCTAssertGreaterThan(
            lookupsAfterFirst,
            0,
            "the cold probe must actually consult LaunchServices for missing apps"
        )

        // Stand in for a burst of command-palette keystrokes.
        for _ in 0..<50 {
            XCTAssertEqual(
                TerminalDirectoryOpenTarget.availableTargetsCached(
                    in: env,
                    cache: cache,
                    scheduleRefresh: { $0() }
                ),
                first
            )
        }

        XCTAssertEqual(
            counter.launchServicesLookups,
            lookupsAfterFirst,
            "cached reads must not re-enter the LaunchServices lookup"
        )
    }

    func testCachedResultMatchesTheUncachedProbe() {
        let counter = ProbeCounter()
        let paths: Set<String> = [
            "/Applications/Visual Studio Code.app",
            "/System/Library/CoreServices/Finder.app",
        ]
        let env = counter.environment(existingPaths: paths)
        let cache = ExpiringValueCache<Set<TerminalDirectoryOpenTarget>>(ttl: 60, now: { 0 })

        XCTAssertEqual(
            TerminalDirectoryOpenTarget.availableTargetsCached(
                in: env,
                cache: cache,
                scheduleRefresh: { $0() }
            ),
            TerminalDirectoryOpenTarget.availableTargets(in: env),
            "caching must not change which targets are reported available"
        )
    }

    func testStaleCacheServesPreviousAnswerThenPicksUpANewInstall() {
        var installedPaths: Set<String> = []
        let env = TerminalDirectoryOpenTarget.DetectionEnvironment(
            homeDirectoryPath: "/Users/tester",
            fileExistsAtPath: { installedPaths.contains($0) },
            isExecutableFileAtPath: { installedPaths.contains($0) },
            applicationPathForName: { _ in nil }
        )
        var clock: TimeInterval = 0
        let cache = ExpiringValueCache<Set<TerminalDirectoryOpenTarget>>(ttl: 60, now: { clock })
        var pending: [() -> Void] = []

        let cold = TerminalDirectoryOpenTarget.availableTargetsCached(
            in: env,
            cache: cache,
            scheduleRefresh: { pending.append($0) }
        )
        XCTAssertFalse(cold.contains(.vscode))
        XCTAssertTrue(pending.isEmpty, "the cold probe runs inline, not as a background refresh")

        installedPaths.insert("/Applications/Visual Studio Code.app")
        clock = 120

        let stale = TerminalDirectoryOpenTarget.availableTargetsCached(
            in: env,
            cache: cache,
            scheduleRefresh: { pending.append($0) }
        )
        XCTAssertFalse(stale.contains(.vscode), "the stale read is served without blocking")
        XCTAssertEqual(pending.count, 1)

        pending.removeFirst()()
        let refreshed = TerminalDirectoryOpenTarget.availableTargetsCached(
            in: env,
            cache: cache,
            scheduleRefresh: { pending.append($0) }
        )
        XCTAssertTrue(refreshed.contains(.vscode), "the background refresh picks up the new install")
    }
}
