import XCTest
@testable import c11

/// C11-165 COR-1 — empty/absent surface-ref rejection (the logic-suite half
/// of COR-4). `SocketSurfaceRefValidator` is the pure seam the v2/v1 write
/// handlers invoke (`v2RejectInvalidSurfaceRef`, `v1RejectMissingTabRef`), so
/// the rejection contract is exercised here in `c11LogicTests` — no socket
/// frame loop, no `TerminalController.shared` (which would unlink the prod
/// socket, per CLAUDE.md / C11-105). This file is a `c11LogicTests` member;
/// the *wiring* proof (that a real handler calls this seam) lives in the
/// host-target `SocketSurfaceRefRejectionWiringTests`.
final class SocketTabRefValidatorTests: XCTestCase {

    // MARK: - classify(): the three raw states

    func testClassifyDistinguishesAbsentEmptyPresent() {
        // Missing key → absent.
        XCTAssertEqual(SocketPanelRefValidator.classify(([String: Any]())["surface_id"]), .absent)
        // Explicit JSON null → absent.
        XCTAssertEqual(SocketPanelRefValidator.classify(NSNull()), .absent)
        // Empty / whitespace-only string → empty.
        XCTAssertEqual(SocketPanelRefValidator.classify(""), .empty)
        XCTAssertEqual(SocketPanelRefValidator.classify("   "), .empty)
        XCTAssertEqual(SocketPanelRefValidator.classify("\t\n"), .empty)
        // Non-string, non-null (malformed ref) → empty.
        XCTAssertEqual(SocketPanelRefValidator.classify(42), .empty)
        // Valid string → present, trimmed.
        XCTAssertEqual(SocketPanelRefValidator.classify("  surface:3  "), .present("surface:3"))
        XCTAssertEqual(SocketPanelRefValidator.classify("6E7C…"), .present("6E7C…"))
    }

    // MARK: - rejection(): empty_ref

    func testPresentButEmptyPinnedRefIsEmptyRef() {
        let r = SocketPanelRefValidator.rejection(
            params: ["surface_id": ""],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.emptyRefCode)
    }

    func testWhitespaceOnlyRefIsEmptyRef() {
        let r = SocketPanelRefValidator.rejection(
            params: ["surface_id": "   "],
            targetKeys: ["surface_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.emptyRefCode)
    }

    func testEmptyNonRequiredTargetKeyStillRejects() {
        // An explicitly-empty ref is always a bug even if it is not the
        // required/pinning key — the caller clearly meant to target something.
        let r = SocketPanelRefValidator.rejection(
            params: ["surface_id": "surface:3", "workspace_id": ""],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.emptyRefCode)
    }

    // MARK: - rejection(): missing_ref (no focused fallback)

    func testAbsentPinnedRefIsMissingRef() {
        let r = SocketPanelRefValidator.rejection(
            params: [:],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.missingRefCode)
    }

    func testExplicitNullPinnedRefIsMissingRef() {
        let r = SocketPanelRefValidator.rejection(
            params: ["surface_id": NSNull()],
            targetKeys: ["surface_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.missingRefCode)
    }

    func testCoarserRefDoesNotSatisfyPinnedRequirement() {
        // The audit's escape hatch: a `--workspace`-only write must NOT pass,
        // because the resolver still falls to `workspace.focusedPanelId`.
        // `requiredAnyOf` is the granularity-pinning key (surface_id), so a
        // workspace_id-only call is missing_ref.
        let r = SocketPanelRefValidator.rejection(
            params: ["workspace_id": "workspace:2"],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.missingRefCode)
    }

    // MARK: - rejection(): accept

    func testValidPinnedRefIsAccepted() {
        XCTAssertNil(SocketPanelRefValidator.rejection(
            params: ["surface_id": "surface:3"],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        ))
    }

    func testRenameAcceptsEitherSurfaceOrTabId() {
        // rename pins on surface_id OR tab_id (both resolve to a surface id).
        XCTAssertNil(SocketPanelRefValidator.rejection(
            params: ["tab_id": "tab:5"],
            targetKeys: ["surface_id", "tab_id", "workspace_id"],
            requiredAnyOf: ["surface_id", "tab_id"]
        ))
    }

    func testMixedValidAndEmptyIsRejectedNotIgnored() {
        // A valid surface_id present alongside an empty tab_id must still be
        // rejected — an empty ref is never silently ignored.
        let r = SocketPanelRefValidator.rejection(
            params: ["surface_id": "surface:3", "tab_id": ""],
            targetKeys: ["surface_id", "tab_id", "workspace_id"],
            requiredAnyOf: ["surface_id", "tab_id"]
        )
        XCTAssertEqual(r?.code, SocketPanelRefValidator.emptyRefCode)
    }

    // MARK: - v1 tab-scoped shape (set_status / set_progress / log)

    func testV1TabWriteRequiresTab() {
        // v1 sidebar-metadata writes are tab-scoped; the pinning key is `tab`.
        XCTAssertEqual(
            SocketPanelRefValidator.rejection(
                params: [:], targetKeys: ["tab"], requiredAnyOf: ["tab"]
            )?.code,
            SocketPanelRefValidator.missingRefCode
        )
        XCTAssertEqual(
            SocketPanelRefValidator.rejection(
                params: ["tab": ""], targetKeys: ["tab"], requiredAnyOf: ["tab"]
            )?.code,
            SocketPanelRefValidator.emptyRefCode
        )
        XCTAssertNil(
            SocketPanelRefValidator.rejection(
                params: ["tab": "tab:2"], targetKeys: ["tab"], requiredAnyOf: ["tab"]
            )
        )
    }
}

final class TerminalReadCompletionTests: XCTestCase {
    func testFirstCompletionWins() {
        let completion = TerminalReadCompletion<String>(deadline: .now() + 1)
        XCTAssertTrue(completion.complete("first"))
        XCTAssertFalse(completion.complete("second"))
        XCTAssertEqual(completion.wait(), "first")
    }

    func testCallerReturnsAndLateProducerCannotPublish() {
        let completion = TerminalReadCompletion<String>(deadline: .now() + 0.03)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(completion.wait())
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        XCTAssertTrue(completion.isAbandoned)
        XCTAssertFalse(completion.complete("late result"))
    }

    func testSecondHopSharesOriginalDeadline() {
        let deadline = DispatchTime.now() + 0.03
        let first = TerminalReadCompletion<Int>(deadline: deadline)
        XCTAssertTrue(first.complete(1))
        XCTAssertEqual(first.wait(), 1)
        Thread.sleep(forTimeInterval: 0.04)
        let second = TerminalReadCompletion<Int>(deadline: deadline)
        XCTAssertTrue(second.isAbandoned)
        XCTAssertFalse(second.complete(2))
        XCTAssertNil(second.wait())
    }
}

final class TerminalReadBytesTests: XCTestCase {
    func testViewportUnicodeAndLineTailParity() {
        var bytes = TerminalReadBytes()
        bytes.viewport = Data("one\nλ雪\nthree\n".utf8)
        XCTAssertEqual(bytes.formatted(includeScrollback: false, lineLimit: nil), "one\nλ雪\nthree\n")
        XCTAssertEqual(bytes.formatted(includeScrollback: false, lineLimit: 2), "three\n")
    }

    func testScrollbackUsesMostCompleteCandidateAndPreservesEmptyRegion() {
        var bytes = TerminalReadBytes()
        bytes.screen = Data("screen\n".utf8)
        bytes.history = Data("history1\nhistory2".utf8)
        bytes.active = Data("active".utf8)
        XCTAssertEqual(bytes.formatted(includeScrollback: true, lineLimit: nil), "history1\nhistory2\nactive")
        XCTAssertEqual(bytes.formatted(includeScrollback: true, lineLimit: 2), "history2\nactive")
        bytes = TerminalReadBytes()
        XCTAssertNil(bytes.formatted(includeScrollback: true, lineLimit: nil))
        bytes.screen = Data()
        XCTAssertEqual(bytes.formatted(includeScrollback: true, lineLimit: nil), "")
    }
}
