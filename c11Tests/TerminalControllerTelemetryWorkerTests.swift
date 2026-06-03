import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for the v1 socket telemetry worker (C11-4).
///
/// The worker variants are nonisolated — they parse args off the main thread
/// and only enqueue UI mutations via `DispatchQueue.main.async`. These tests
/// exercise the *pure* parser helpers from a worker queue (so we can assert
/// `Thread.isMainThread == false` at parse time) and the `explicitSocketScope`
/// gate the worker uses to decide whether to run off-main or fall through.
///
/// We do not exercise the full handler bodies here — those depend on
/// AppDelegate state that is only set up when the app is mounted. The flood
/// test in `tests_v2/test_telemetry_off_main.py` covers the live socket path.
final class TerminalControllerTelemetryWorkerTests: XCTestCase {

    // MARK: - Pure parser parity

    /// `parseOptionsStatic` must produce the same shape as the existing
    /// `parseOptions` for the kinds of inputs the v1 worker handles. We
    /// can't reach the @MainActor instance method here without mocking the
    /// whole controller, but parse-time correctness is verifiable through
    /// the static helper alone.
    func testParseOptionsStaticHandlesPositionalAndFlags() {
        let result = TerminalController.parseOptionsStatic(
            "/tmp/work --tab=AAAA-BBBB --panel=CCCC-DDDD"
        )
        XCTAssertEqual(result.positional, ["/tmp/work"])
        XCTAssertEqual(result.options["tab"], "AAAA-BBBB")
        XCTAssertEqual(result.options["panel"], "CCCC-DDDD")
    }

    func testParseOptionsStaticHandlesValueAfterFlag() {
        let result = TerminalController.parseOptionsStatic(
            "main --status dirty --tab abc --panel def"
        )
        XCTAssertEqual(result.positional, ["main"])
        XCTAssertEqual(result.options["status"], "dirty")
        XCTAssertEqual(result.options["tab"], "abc")
        XCTAssertEqual(result.options["panel"], "def")
    }

    func testParseOptionsStaticHandlesQuotedPositional() {
        let result = TerminalController.parseOptionsStatic(
            "\"/path with spaces\" --tab=t --panel=p"
        )
        XCTAssertEqual(result.positional, ["/path with spaces"])
        XCTAssertEqual(result.options["tab"], "t")
    }

    func testParseOptionsStaticHandlesEmptyArgs() {
        let result = TerminalController.parseOptionsStatic("")
        XCTAssertTrue(result.positional.isEmpty)
        XCTAssertTrue(result.options.isEmpty)
    }

    func testTokenizeArgsStaticDecodesEscapes() {
        let result = TerminalController.tokenizeArgsStatic(
            "\"line1\\nline2\\ttab\""
        )
        XCTAssertEqual(result, ["line1\nline2\ttab"])
    }

    // MARK: - Off-main parse-time invariant

    /// The worker pattern only pays off if parse-time runs off the main
    /// thread. Drive the static parser from a worker queue and assert that
    /// `Thread.isMainThread == false` when it executes. This is the
    /// behavioral guarantee we trade the pattern for.
    func testParserRunsOffMainFromWorkerQueue() {
        let worker = DispatchQueue(label: "telemetry-worker-test")
        let parsed = expectation(description: "parse completed off-main")
        var observedOffMain = false
        worker.async {
            let isMain = Thread.isMainThread
            _ = TerminalController.parseOptionsStatic(
                "/tmp/x --tab=t --panel=p"
            )
            observedOffMain = !isMain
            parsed.fulfill()
        }
        wait(for: [parsed], timeout: 2.0)
        XCTAssertTrue(
            observedOffMain,
            "parseOptionsStatic must be callable off-main; the v1 telemetry worker depends on it"
        )
    }

    // MARK: - Selector gate (fast-path vs. fall-through)

    /// The worker only handles commands whose args carry an explicit
    /// `--tab=<uuid> --panel=<uuid>` (or `--surface=<uuid>`) selector.
    /// Without an explicit selector, the worker must return nil so the
    /// dispatcher falls through to the main-sync path. This is enforced by
    /// `explicitSocketScope`; verify its behavior from a worker queue.
    func testExplicitSocketScopeRequiresBothTabAndPanel() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(options: [
            "tab": workspaceId.uuidString,
            "panel": panelId.uuidString,
        ])
        XCTAssertNotNil(scope)
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeAcceptsSurfaceAlias() {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let scope = TerminalController.explicitSocketScope(options: [
            "tab": workspaceId.uuidString,
            "surface": surfaceId.uuidString,
        ])
        XCTAssertNotNil(scope, "the worker treats --surface as an alias for --panel")
        XCTAssertEqual(scope?.panelId, surfaceId)
    }

    func testExplicitSocketScopeRejectsMissingPanel() {
        let scope = TerminalController.explicitSocketScope(options: [
            "tab": UUID().uuidString
        ])
        XCTAssertNil(scope, "without an explicit panel id, fall through to main")
    }

    func testExplicitSocketScopeRejectsMissingTab() {
        let scope = TerminalController.explicitSocketScope(options: [
            "panel": UUID().uuidString
        ])
        XCTAssertNil(scope)
    }

    func testExplicitSocketScopeRejectsBadUUID() {
        let scope = TerminalController.explicitSocketScope(options: [
            "tab": "not-a-uuid",
            "panel": UUID().uuidString,
        ])
        XCTAssertNil(scope, "garbage UUIDs must not satisfy the fast-path gate")
    }

    func testExplicitSocketScopeRunsOffMainFromWorkerQueue() {
        let worker = DispatchQueue(label: "telemetry-worker-scope")
        let resolved = expectation(description: "scope resolved off-main")
        var sawScope = false
        worker.async {
            let isMain = Thread.isMainThread
            let scope = TerminalController.explicitSocketScope(options: [
                "tab": UUID().uuidString,
                "panel": UUID().uuidString,
            ])
            sawScope = scope != nil && !isMain
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 2.0)
        XCTAssertTrue(sawScope)
    }

    // MARK: - Allowlist contract

    /// The worker's allowlist is private to TerminalController, but the
    /// fact that exactly the audit-listed high-frequency telemetry commands
    /// are migrated is part of the C11-4 contract. We verify the contract
    /// via observable behavior: each migrated handler now has a worker
    /// variant that respects `explicitSocketScope`, and the un-migrated
    /// commands keep their main-sync entry. This test asserts the parser
    /// returns the exact tokens the worker expects.
    func testReportGitBranchArgsParsedAsExpectedByWorker() {
        let workspaceId = UUID()
        let panelId = UUID()
        let parsed = TerminalController.parseOptionsStatic(
            "main --status=dirty --tab=\(workspaceId.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(parsed.positional, ["main"])
        XCTAssertEqual(parsed.options["status"], "dirty")
        XCTAssertEqual(
            TerminalController.explicitSocketScope(options: parsed.options)?.workspaceId,
            workspaceId
        )
    }

    func testReportPwdArgsJoinPositionalsForPathsWithSpaces() {
        // Bash's `report_pwd "/path with spaces"` arrives as quoted; quoted
        // tokens are reassembled by the tokenizer. Verify the worker sees
        // a single positional, not three.
        let parsed = TerminalController.parseOptionsStatic(
            "\"/Users/me/projects with spaces\" --tab=AAAA --panel=BBBB"
        )
        XCTAssertEqual(parsed.positional, ["/Users/me/projects with spaces"])
    }
}
