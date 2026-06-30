import XCTest
import Darwin

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

// MARK: - C11-155: bind-time socket stomp

/// The incident: a staging/debug build launched from a prod c11 pane inherits
/// prod's `CMUX_SOCKET_PATH` and would bind (unlinking) prod's *live* socket.
/// These tests cover the resolution-layer guard (don't adopt a foreign channel's
/// shared default) and the per-bundle namespacing defense-in-depth.
final class SocketCollisionResolutionTests: XCTestCase {

    func testStagingDoesNotAdoptInheritedProdSocketPath() {
        // The exact incident: staging bundle, ambient CMUX_SOCKET_PATH == prod's
        // shared socket. Must fall through to staging's own default, never prod's.
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath],
            bundleIdentifier: "com.stage11.c11.staging.rel.v0.54.0",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, "/tmp/c11-staging.sock")
        XCTAssertNotEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testDebugDoesNotAdoptInheritedStagingSharedSocketPath() {
        // Cross-channel inheritance the other direction (debug from a staging pane).
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/c11-staging.sock"],
            bundleIdentifier: "com.stage11.c11.debug",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, "/tmp/c11-debug.sock")
    }

    func testExplicitOptInStillAdoptsForeignPath() {
        // CMUX_ALLOW_SOCKET_OVERRIDE is the intentional escape hatch (used by
        // scripts/test-unit-local.sh) and must still win.
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.stage11.c11.staging",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testTaggedStagingOverrideStillHonored() {
        // A tag-specific override path is launch-script intent, not inheritance,
        // and is not a shared default — the tagged-build workflow is unaffected.
        let path = SocketControlSettings.socketPath(
            environment: ["CMUX_SOCKET_PATH": "/tmp/c11-staging-my-tag.sock"],
            bundleIdentifier: "com.stage11.c11.staging.my-tag",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/c11-staging-my-tag.sock")
    }

    func testForeignSharedDefaultDetection() {
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath(
            SocketControlSettings.stableDefaultSocketPath))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-staging.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-debug.sock"))
        XCTAssertTrue(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-nightly.sock"))
        // Tag-specific paths are NOT shared defaults.
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-staging-my-tag.sock"))
        XCTAssertFalse(SocketControlSettings.isForeignSharedDefaultSocketPath("/tmp/c11-debug-feat-x.sock"))
    }

    func testNonProdStableBundleGetsBundleScopedSocket() {
        // A non-prod bundle that still falls through to the stable default (e.g.
        // release-probe) must never resolve to prod's shared path.
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.stage11.c11.release-probe",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertNotEqual(path, SocketControlSettings.stableDefaultSocketPath)
        XCTAssertEqual(
            path,
            SocketControlSettings.bundleScopedStableSocketPath(
                bundleIdentifier: "com.stage11.c11.release-probe"))
        XCTAssertTrue(path.hasSuffix(".sock"))
    }

    func testProdBundleKeepsCanonicalStableSocket() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: SocketControlSettings.prodBundleIdentifier,
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }
}

/// The bind-layer guarantee (C11-155): never unlink a socket a live peer serves.
final class SocketLivenessProbeTests: XCTestCase {

    /// Bind+listen a real unix socket at `path`; caller closes the returned fd.
    private func makeLiveListener(at path: String) -> Int32 {
        Darwin.unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                let dstRaw = UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self)
                strncpy(dstRaw, src, sunPathCapacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed errno=\(errno)")
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        return fd
    }

    func testLiveListenerIsDetected() {
        let path = "/tmp/c11-test-live-\(getpid()).sock"
        let fd = makeLiveListener(at: path)
        defer { Darwin.close(fd); Darwin.unlink(path) }
        XCTAssertTrue(TerminalController.socketHasLiveListener(path: path))
    }

    func testMissingPathIsNotLive() {
        XCTAssertFalse(TerminalController.socketHasLiveListener(
            path: "/tmp/c11-test-absent-\(getpid()).sock"))
    }

    func testRegularFileIsNotLive() {
        let path = "/tmp/c11-test-regular-\(getpid())"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { Darwin.unlink(path) }
        XCTAssertFalse(TerminalController.socketHasLiveListener(path: path))
    }

    func testStaleSocketFileIsNotLive() {
        // A socket file with no live acceptor (closed listener) is replaceable.
        let path = "/tmp/c11-test-stale-\(getpid()).sock"
        let fd = makeLiveListener(at: path)
        Darwin.close(fd) // file remains on disk, but nobody is accepting
        defer { Darwin.unlink(path) }
        XCTAssertFalse(TerminalController.socketHasLiveListener(path: path))
    }

    func testSafeAlternateForProdPathIsUserScoped() {
        XCTAssertEqual(
            TerminalController.safeAlternateSocketPath(
                afterPeerAliveAt: SocketControlSettings.stableDefaultSocketPath,
                currentUserID: 501),
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testSafeAlternateForOtherPathIsPidStampedSibling() {
        let alt = TerminalController.safeAlternateSocketPath(
            afterPeerAliveAt: "/tmp/c11-staging.sock",
            currentUserID: 501,
            processIdentifier: 4242)
        XCTAssertEqual(alt, "/tmp/c11-staging-4242.sock")
    }
}
