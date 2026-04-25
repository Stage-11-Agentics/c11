import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure string-predicate tests for the claude-hook advisory path. The CLI's
/// `isAdvisoryHookConnectivityError(_:)` delegates here after unwrapping the
/// CLIError message; verifying the predicate is enough to cover the
/// runtime decision.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class CLIAdvisoryConnectivityTests: XCTestCase {

    // MARK: - Existing shapes (regression guards)

    func testSocketNotFoundIsAdvisory() {
        XCTAssertTrue(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "Socket not found at /tmp/c11-debug.sock"
        ))
    }

    func testConnectionRefusedIsAdvisory() {
        XCTAssertTrue(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "Failed to connect: Connection refused"
        ))
    }

    func testNoSuchFileOrDirectoryIsAdvisory() {
        XCTAssertTrue(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "connect: No such file or directory"
        ))
    }

    // MARK: - P6 additions: orphan-socket / wrong-owner shapes

    /// EPERM/EACCES from connecting to a socket owned by another uid, or a
    /// socket directory we can't traverse. Single-user assumption — treat
    /// as "no live c11 for me on this machine."
    func testPermissionDeniedIsAdvisory() {
        XCTAssertTrue(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "Failed to connect to /private/tmp/c11-debug-other.sock: Permission denied"
        ))
    }

    /// EPERM from stat/unlink of the socket path.
    func testOperationNotPermittedIsAdvisory() {
        XCTAssertTrue(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "unlink failed: Operation not permitted"
        ))
    }

    /// EAGAIN variant on some macOS paths when an orphaned socket file
    /// exists but no listener accepts.
    func testResourceTemporarilyUnavailableIsAdvisory() {
        XCTAssertTrue(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "accept failed: Resource temporarily unavailable"
        ))
    }

    // MARK: - Negative — non-connectivity errors remain `failed`

    func testGenericTimeoutIsNotAdvisory() {
        XCTAssertFalse(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "timed out waiting for response"
        ))
    }

    func testUnexpectedProtocolErrorIsNotAdvisory() {
        XCTAssertFalse(CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(
            message: "v2 error code=invalid_params message=\"snapshot_id required\""
        ))
    }
}
