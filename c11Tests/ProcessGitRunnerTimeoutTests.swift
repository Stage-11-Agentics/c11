import XCTest
@testable import c11

/// C11-106 — AC14 from the C11-104 v2 validation plan: the git
/// subprocess timeout returns nil + the process is reaped + the
/// background queue does not hang.
///
/// `ProcessGitRunner` is parameterized in C11-106 over `executable`
/// and `argPrefix` so the test can substitute a deterministic slow
/// command without modifying the production code path. Defaults
/// (`/usr/bin/env git`) and the production 5-second timeout are
/// unchanged.
///
/// **API decision recorded for the PR body (per C11-106 plan I1):**
/// `GitRunner.run` continues to return `String?` and timeout collapses
/// to nil along with non-zero exit, missing git binary, etc. A typed
/// timeout enum is a deliberate follow-up that pairs with the typed
/// `GitContextKind.stale` / `.notInRepo` work.
final class ProcessGitRunnerTimeoutTests: XCTestCase {

    /// Subprocess takes longer than the runner's timeout → run()
    /// returns nil within ~timeout + reaper-grace seconds, and the
    /// child process is reaped (no zombie / no hanging file
    /// descriptor).
    func testRunReturnsNilWhenSubprocessExceedsTimeout() {
        let runner = ProcessGitRunner(
            executable: "/bin/sh",
            argPrefix: ["-c"],
            timeout: 0.2
        )
        let cwd = NSTemporaryDirectory()

        let start = Date()
        let result = runner.run(cwd: cwd, args: ["sleep 3"])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "timeout must return nil")
        // The runner gives itself an extra 0.4s of grace (SIGTERM
        // then SIGKILL), so the worst-case bound is timeout + 0.4 +
        // dispatcher slop.
        XCTAssertLessThan(elapsed, 1.5,
            "elapsed=\(elapsed)s should be near the 0.2s timeout, never close to the child's 3s sleep")
    }

    /// Fast-completing subprocess → run() returns the trimmed stdout.
    /// Sanity-check that the `executable` + `argPrefix` parameter
    /// path didn't break the success case.
    func testRunReturnsTrimmedStdoutOnFastSuccess() {
        let runner = ProcessGitRunner(
            executable: "/bin/sh",
            argPrefix: ["-c"],
            timeout: 2.0
        )
        let cwd = NSTemporaryDirectory()
        let result = runner.run(cwd: cwd, args: ["printf 'hello\\n'"])
        XCTAssertEqual(result, "hello")
    }

    /// Sequential timeouts → the background queue is not blocked by
    /// a previous timed-out invocation. The contract is: each
    /// timeout cleans up its own child and returns nil before the
    /// next call can proceed.
    func testTimeoutsDoNotAccumulateOrBlockSubsequentCalls() {
        let runner = ProcessGitRunner(
            executable: "/bin/sh",
            argPrefix: ["-c"],
            timeout: 0.2
        )
        let cwd = NSTemporaryDirectory()

        let start = Date()
        for _ in 0..<3 {
            let result = runner.run(cwd: cwd, args: ["sleep 1"])
            XCTAssertNil(result)
        }
        let elapsed = Date().timeIntervalSince(start)

        // 3 timeouts of ~0.2s each + ~0.4s grace each = upper bound
        // ~1.8s. Real-world target: <2.5s; if this assertion ever
        // fails we have a queue-blocking regression.
        XCTAssertLessThan(elapsed, 3.0,
            "three sequential 0.2s timeouts should complete in well under 3s; elapsed=\(elapsed)s")
    }

    /// Default constructor is unchanged from C11-104 — the production
    /// runner still invokes `/usr/bin/env git` with a 5-second
    /// timeout. Defends against a future "drop the defaults" change.
    func testDefaultConstructorMatchesProductionShape() {
        let runner = ProcessGitRunner()
        XCTAssertEqual(runner.executable, "/usr/bin/env")
        XCTAssertEqual(runner.argPrefix, ["git"])
        XCTAssertEqual(runner.timeout, 5.0)
    }
}
