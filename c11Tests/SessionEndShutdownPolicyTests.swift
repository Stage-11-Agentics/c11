import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure-policy tests for the `c11 claude-hook session-end` shutdown guard.
/// The CLI's runtime decision is `SessionEndShutdownPolicy.shouldPreserve`
/// applied to the outcome of a `system.ping` query; verifying both arms of
/// the policy is enough to cover the decision shape.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class SessionEndShutdownPolicyTests: XCTestCase {

    // MARK: - success outcomes

    /// c11 confirmed it is terminating. Preserve metadata — a clear here
    /// would race `applicationShouldTerminate`'s snapshot capture and lose
    /// the per-pane session id.
    func testTerminatingAppIsPreserved() {
        XCTAssertTrue(
            SessionEndShutdownPolicy.shouldPreserve(
                outcome: .success(isTerminating: true)
            )
        )
    }

    /// c11 is alive and not terminating. Run the existing clear path —
    /// SessionEnd of a normal `/exit` should still tear down the metadata.
    func testNotTerminatingAppRunsClear() {
        XCTAssertFalse(
            SessionEndShutdownPolicy.shouldPreserve(
                outcome: .success(isTerminating: false)
            )
        )
    }

    // MARK: - failure outcomes

    /// Socket unreachable, timeout, or malformed response — uncertainty.
    /// Preserve metadata: never tombstone on socket-uncertainty. The worst
    /// case is a stale id that the next SessionStart write overwrites.
    /// The alternative (clear-on-failure) silently reproduces the bug
    /// this fix exists to close.
    func testFailureIsPreserved() {
        XCTAssertTrue(
            SessionEndShutdownPolicy.shouldPreserve(outcome: .failure)
        )
    }
}
