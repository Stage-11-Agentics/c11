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
