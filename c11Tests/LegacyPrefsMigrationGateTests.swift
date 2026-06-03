import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for `AppDelegate.legacyMigrationShouldSkip(bundleId:env:)`.
///
/// The gate exists to keep dev/test runs from inheriting `cmuxWelcomeShown=1`
/// (and friends) from a pre-existing `com.cmuxterm.app` install on the same
/// machine. Without the gate, the legacy migration cross-contaminates the
/// debug bundle, which masks the TCC primer (and any other first-run UX
/// gated on `WelcomeSettings.shownKey`) on every dev launch.
///
/// Discovered while validating C11-16 (PR #138) against a tagged build.
final class LegacyPrefsMigrationGateTests: XCTestCase {

    // MARK: - Bundle id gate

    func testReleaseBundleRunsMigration() {
        let env: [String: String] = [:]
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11", env: env),
            "Release bundle id must run the legacy migration so cmuxterm users keep their welcome/primer state on upgrade."
        )
    }

    func testDebugBundleSkipsMigration() {
        let env: [String: String] = [:]
        XCTAssertTrue(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11.debug", env: env),
            "DEV bundle id must skip the legacy migration to keep first-run UX testable."
        )
    }

    func testTaggedDebugBundleSkipsMigration() {
        let env: [String: String] = [:]
        XCTAssertTrue(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11.debug.tag1", env: env),
            "Future tagged debug bundle ids (.debug.<tag>) must also skip the migration."
        )
        XCTAssertTrue(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11.debug.long.tag.name", env: env),
            "Multi-segment .debug.<…> bundle ids must also skip the migration."
        )
    }

    func testEmptyBundleIdDoesNotSkip() {
        let env: [String: String] = [:]
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "", env: env),
            "Unknown bundle id (empty string) defaults to running the migration; the wrong call here is to silently strand release users."
        )
    }

    func testFalsePositiveResistance() {
        let env: [String: String] = [:]
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.debugcorp.app", env: env),
            "A bundle id containing 'debug' as part of an unrelated word must not match."
        )
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11.debugger", env: env),
            "A trailing 'debugger' must not match — only '.debug' as a terminal segment or '.debug.' as a separator."
        )
    }

    // MARK: - Env-var escape hatch

    func testEnvVarOneForcesSkipOnReleaseBundle() {
        let env = ["CMUX_DISABLE_LEGACY_MIGRATION": "1"]
        XCTAssertTrue(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11", env: env),
            "CMUX_DISABLE_LEGACY_MIGRATION=1 must force-skip even on a release bundle (CI / clean-install validation use case)."
        )
    }

    func testEnvVarZeroDoesNotForceSkip() {
        let env = ["CMUX_DISABLE_LEGACY_MIGRATION": "0"]
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11", env: env),
            "CMUX_DISABLE_LEGACY_MIGRATION=0 must NOT force skip — only the literal value \"1\" disables migration."
        )
    }

    func testEnvVarOtherValuesIgnored() {
        let env = ["CMUX_DISABLE_LEGACY_MIGRATION": "true"]
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11", env: env),
            "Only literal \"1\" disables migration; \"true\" / empty / other values are ignored to keep the contract narrow."
        )
    }

    func testEnvVarUnsetWithReleaseBundleRunsMigration() {
        // Composite: env-var unset + release bundle = run migration.
        let env: [String: String] = [:]
        XCTAssertFalse(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11", env: env),
            "Default Release behavior (no env var override) must run the migration."
        )
    }

    func testEnvVarOverridesEvenOnDebugBundle() {
        // Composite: env-var=1 + debug bundle = skip (already skipping; env var is redundant
        // here but we don't want it to flip the answer).
        let env = ["CMUX_DISABLE_LEGACY_MIGRATION": "1"]
        XCTAssertTrue(
            AppDelegate.legacyMigrationShouldSkip(bundleId: "com.stage11.c11.debug", env: env),
            "Debug bundle + env-var=1 must still skip (no contradiction between gates)."
        )
    }
}
