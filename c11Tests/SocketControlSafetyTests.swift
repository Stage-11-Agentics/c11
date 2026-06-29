import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-105 regressions. Both checks are host-less and run inside the
/// `c11LogicTests` target so they can guard fast local iteration without
/// touching real sockets or the prod c11's bind file.
@MainActor
final class SocketControlSafetyTests: XCTestCase {

    /// Production bug: a fresh `TerminalController` defaulted `socketPath` to
    /// `SocketControlSettings.stableDefaultSocketPath`. A test whose setUp
    /// called `TerminalController.shared.stop()` would then `unlink()` the
    /// prod c11's bind path while its FD stayed live in-kernel, leaving every
    /// `c11 <cmd>` reporting "Socket not found". The fix initializes the
    /// field to "" and gates `stop()`'s unlink on a non-empty path.
    func testFreshControllerHasEmptySocketPath() {
        let controller = TerminalController.makeForTesting()
        XCTAssertEqual(
            controller.socketPathSnapshot,
            "",
            "A never-started TerminalController must not carry a shared "
            + "default socket path — stop() would unlink it. See C11-105."
        )
    }

    /// Rename hygiene: `.cmuxOnly` was renamed to `.c11Only`. Persisted
    /// `UserDefaults` values from pre-rename builds must still migrate
    /// forward, and the new canonical raw value must parse as well. The
    /// `migrateMode` normalizer is case-insensitive and strips `-`/`_`.
    func testParseAcceptsLegacyAndCanonicalC11OnlyValues() {
        // New canonical raw value (what migrateMode writes back).
        XCTAssertEqual(SocketControlSettings.migrateMode("c11Only"), .c11Only)
        XCTAssertEqual(SocketControlSettings.migrateMode("c11-only"), .c11Only)
        XCTAssertEqual(SocketControlSettings.migrateMode("c11_only"), .c11Only)

        // Legacy raw value persisted by pre-rename builds.
        XCTAssertEqual(SocketControlSettings.migrateMode("cmuxOnly"), .c11Only)
        XCTAssertEqual(SocketControlSettings.migrateMode("cmux-only"), .c11Only)
    }
}

/// Shared "is this a local dev build?" gate used to suppress launch-time
/// auto-dialogs (Agent Skills onboarding, resume picker) for the person
/// rebuilding c11. `isDebugBuild` is injected so the env branch is exercised
/// even though the logic-test target itself compiles DEBUG.
final class SocketControlIsLocalDevBuildTests: XCTestCase {
    func testTaggedReleaseBuildIsDev() {
        XCTAssertTrue(SocketControlSettings.isLocalDevBuild(
            environment: ["CMUX_TAG": "feat-foo"], isDebugBuild: false))
    }

    func testUntaggedReleaseBuildIsNotDev() {
        XCTAssertFalse(SocketControlSettings.isLocalDevBuild(
            environment: [:], isDebugBuild: false))
    }

    func testWhitespaceTagIsNotDev() {
        XCTAssertFalse(SocketControlSettings.isLocalDevBuild(
            environment: ["CMUX_TAG": "   "], isDebugBuild: false))
    }

    func testDebugBuildIsAlwaysDev() {
        XCTAssertTrue(SocketControlSettings.isLocalDevBuild(
            environment: [:], isDebugBuild: true))
    }
}

/// `LaunchResumePicker.resolveEffectivePolicy` — QA launch overrides win; a
/// local dev build replaces the default `.ask` picker with silent `.always`
/// restore; an explicit operator policy is always honored.
final class LaunchResumeGateTests: XCTestCase {
    func testQAResumeForcesAlways() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .on(.resume), persisted: .ask, isLocalDevBuild: false),
            .always)
    }

    func testQAFreshForcesNever() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .on(.fresh), persisted: .ask, isLocalDevBuild: false),
            .never)
    }

    func testDevBuildTurnsAskIntoSilentAlways() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .ask, isLocalDevBuild: true),
            .always)
    }

    func testReleaseBuildKeepsAskPicker() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .ask, isLocalDevBuild: false),
            .ask)
    }

    func testExplicitNeverHonoredEvenOnDevBuild() {
        // A dev build must not resurrect a session the operator opted out of.
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .never, isLocalDevBuild: true),
            .never)
    }

    func testExplicitAlwaysHonored() {
        XCTAssertEqual(
            LaunchResumePicker.resolveEffectivePolicy(qa: .off, persisted: .always, isLocalDevBuild: false),
            .always)
    }
}
