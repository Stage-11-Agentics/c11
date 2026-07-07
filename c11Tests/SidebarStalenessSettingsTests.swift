import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `SidebarStalenessSettings` — the pure age→stage classifier
/// and the clamped threshold resolvers (stored value, default, env override).
/// C11-162 (Telemetry truth).
final class SidebarStalenessSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SidebarStalenessSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - stage(ageSeconds:staleSeconds:expirySeconds:)

    func testStageFreshBelowStale() {
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: 0, staleSeconds: 300, expirySeconds: 900), .fresh)
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: 299.9, staleSeconds: 300, expirySeconds: 900), .fresh)
    }

    func testStageNegativeAgeTreatedFresh() {
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: -50, staleSeconds: 300, expirySeconds: 900), .fresh)
    }

    func testStageStaleAtAndAboveStaleBoundary() {
        // Upper boundary is inclusive into the next stage.
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: 300, staleSeconds: 300, expirySeconds: 900), .stale)
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: 899.9, staleSeconds: 300, expirySeconds: 900), .stale)
    }

    func testStageExpiredAtAndAboveExpiryBoundary() {
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: 900, staleSeconds: 300, expirySeconds: 900), .expired)
        XCTAssertEqual(SidebarStalenessSettings.stage(ageSeconds: 100_000, staleSeconds: 300, expirySeconds: 900), .expired)
    }

    // MARK: - staleSeconds / expirySeconds resolution

    func testDefaultsWhenUnsetAndNoEnv() {
        let defaults = makeDefaults()
        XCTAssertEqual(SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: [:]),
                       SidebarStalenessSettings.defaultStaleSeconds)
        XCTAssertEqual(SidebarStalenessSettings.expirySeconds(defaults: defaults, environment: [:]),
                       SidebarStalenessSettings.defaultExpirySeconds)
    }

    func testStoredValueUsedWhenPresent() {
        let defaults = makeDefaults()
        defaults.set(120.0, forKey: SidebarStalenessSettings.staleThresholdKey)
        defaults.set(600.0, forKey: SidebarStalenessSettings.expiryThresholdKey)
        XCTAssertEqual(SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: [:]), 120)
        XCTAssertEqual(SidebarStalenessSettings.expirySeconds(defaults: defaults, environment: [:]), 600)
    }

    func testStoredValueClampedToRange() {
        let defaults = makeDefaults()
        defaults.set(1.0, forKey: SidebarStalenessSettings.staleThresholdKey)   // below min
        defaults.set(999_999.0, forKey: SidebarStalenessSettings.expiryThresholdKey) // above max
        XCTAssertEqual(SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: [:]),
                       SidebarStalenessSettings.minSeconds)
        XCTAssertEqual(SidebarStalenessSettings.expirySeconds(defaults: defaults, environment: [:]),
                       SidebarStalenessSettings.maxSeconds)
    }

    func testEnvOverrideWinsOverStored() {
        let defaults = makeDefaults()
        defaults.set(120.0, forKey: SidebarStalenessSettings.staleThresholdKey)
        defaults.set(600.0, forKey: SidebarStalenessSettings.expiryThresholdKey)
        let env = [
            SidebarStalenessSettings.staleEnvKey: "77",
            SidebarStalenessSettings.expiryEnvKey: "888",
        ]
        XCTAssertEqual(SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: env), 77)
        XCTAssertEqual(SidebarStalenessSettings.expirySeconds(defaults: defaults, environment: env), 888)
    }

    func testEnvOverrideIsClamped() {
        let defaults = makeDefaults()
        let env = [
            SidebarStalenessSettings.staleEnvKey: "0",       // below min
            SidebarStalenessSettings.expiryEnvKey: "50000",  // above max
        ]
        XCTAssertEqual(SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: env),
                       SidebarStalenessSettings.minSeconds)
        XCTAssertEqual(SidebarStalenessSettings.expirySeconds(defaults: defaults, environment: env),
                       SidebarStalenessSettings.maxSeconds)
    }

    func testInvalidEnvFallsBackToStored() {
        let defaults = makeDefaults()
        defaults.set(200.0, forKey: SidebarStalenessSettings.staleThresholdKey)
        let env = [SidebarStalenessSettings.staleEnvKey: "not-a-number"]
        XCTAssertEqual(SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: env), 200)
    }

    // C11-162 (m3): expiry must never resolve below stale. Otherwise an age
    // between the (too-low) expiry and stale would report `.fresh` — a value the
    // operator thinks is dead reads as live. Flooring expiry at stale keeps
    // staging monotonic (fresh → expired, no premature expiry).
    func testExpiryIsFlooredAtStale() {
        let defaults = makeDefaults()
        defaults.set(300.0, forKey: SidebarStalenessSettings.staleThresholdKey)   // 5m
        defaults.set(100.0, forKey: SidebarStalenessSettings.expiryThresholdKey)  // 100s (inverted, < stale)
        let env: [String: String] = [:]
        let stale = SidebarStalenessSettings.staleSeconds(defaults: defaults, environment: env)
        let expiry = SidebarStalenessSettings.expirySeconds(defaults: defaults, environment: env)
        XCTAssertEqual(stale, 300)
        XCTAssertGreaterThanOrEqual(expiry, stale, "expiry must be floored at stale")
        // Effective expiry is now 300, so an age of 200s (past the bogus 100s
        // stored expiry but below stale) is fresh — NOT prematurely expired.
        XCTAssertEqual(
            SidebarStalenessSettings.stage(ageSeconds: 200, staleSeconds: stale, expirySeconds: expiry),
            .fresh
        )
        XCTAssertEqual(
            SidebarStalenessSettings.stage(ageSeconds: 350, staleSeconds: stale, expirySeconds: expiry),
            .expired
        )
    }
}
