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
        XCTAssertEqual(SocketTabRefValidator.classify(([String: Any]())["surface_id"]), .absent)
        // Explicit JSON null → absent.
        XCTAssertEqual(SocketTabRefValidator.classify(NSNull()), .absent)
        // Empty / whitespace-only string → empty.
        XCTAssertEqual(SocketTabRefValidator.classify(""), .empty)
        XCTAssertEqual(SocketTabRefValidator.classify("   "), .empty)
        XCTAssertEqual(SocketTabRefValidator.classify("\t\n"), .empty)
        // Non-string, non-null (malformed ref) → empty.
        XCTAssertEqual(SocketTabRefValidator.classify(42), .empty)
        // Valid string → present, trimmed.
        XCTAssertEqual(SocketTabRefValidator.classify("  surface:3  "), .present("surface:3"))
        XCTAssertEqual(SocketTabRefValidator.classify("6E7C…"), .present("6E7C…"))
    }

    // MARK: - rejection(): empty_ref

    func testPresentButEmptyPinnedRefIsEmptyRef() {
        let r = SocketTabRefValidator.rejection(
            params: ["surface_id": ""],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.emptyRefCode)
    }

    func testWhitespaceOnlyRefIsEmptyRef() {
        let r = SocketTabRefValidator.rejection(
            params: ["surface_id": "   "],
            targetKeys: ["surface_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.emptyRefCode)
    }

    func testEmptyNonRequiredTargetKeyStillRejects() {
        // An explicitly-empty ref is always a bug even if it is not the
        // required/pinning key — the caller clearly meant to target something.
        let r = SocketTabRefValidator.rejection(
            params: ["surface_id": "surface:3", "workspace_id": ""],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.emptyRefCode)
    }

    // MARK: - rejection(): missing_ref (no focused fallback)

    func testAbsentPinnedRefIsMissingRef() {
        let r = SocketTabRefValidator.rejection(
            params: [:],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.missingRefCode)
    }

    func testExplicitNullPinnedRefIsMissingRef() {
        let r = SocketTabRefValidator.rejection(
            params: ["surface_id": NSNull()],
            targetKeys: ["surface_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.missingRefCode)
    }

    func testCoarserRefDoesNotSatisfyPinnedRequirement() {
        // The audit's escape hatch: a `--workspace`-only write must NOT pass,
        // because the resolver still falls to `workspace.focusedPanelId`.
        // `requiredAnyOf` is the granularity-pinning key (surface_id), so a
        // workspace_id-only call is missing_ref.
        let r = SocketTabRefValidator.rejection(
            params: ["workspace_id": "workspace:2"],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.missingRefCode)
    }

    // MARK: - rejection(): accept

    func testValidPinnedRefIsAccepted() {
        XCTAssertNil(SocketTabRefValidator.rejection(
            params: ["surface_id": "surface:3"],
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        ))
    }

    func testRenameAcceptsEitherSurfaceOrTabId() {
        // rename pins on surface_id OR tab_id (both resolve to a surface id).
        XCTAssertNil(SocketTabRefValidator.rejection(
            params: ["tab_id": "tab:5"],
            targetKeys: ["surface_id", "tab_id", "workspace_id"],
            requiredAnyOf: ["surface_id", "tab_id"]
        ))
    }

    func testMixedValidAndEmptyIsRejectedNotIgnored() {
        // A valid surface_id present alongside an empty tab_id must still be
        // rejected — an empty ref is never silently ignored.
        let r = SocketTabRefValidator.rejection(
            params: ["surface_id": "surface:3", "tab_id": ""],
            targetKeys: ["surface_id", "tab_id", "workspace_id"],
            requiredAnyOf: ["surface_id", "tab_id"]
        )
        XCTAssertEqual(r?.code, SocketTabRefValidator.emptyRefCode)
    }

    // MARK: - v1 tab-scoped shape (set_status / set_progress / log)

    func testV1TabWriteRequiresTab() {
        // v1 sidebar-metadata writes are tab-scoped; the pinning key is `tab`.
        XCTAssertEqual(
            SocketTabRefValidator.rejection(
                params: [:], targetKeys: ["tab"], requiredAnyOf: ["tab"]
            )?.code,
            SocketTabRefValidator.missingRefCode
        )
        XCTAssertEqual(
            SocketTabRefValidator.rejection(
                params: ["tab": ""], targetKeys: ["tab"], requiredAnyOf: ["tab"]
            )?.code,
            SocketTabRefValidator.emptyRefCode
        )
        XCTAssertNil(
            SocketTabRefValidator.rejection(
                params: ["tab": "tab:2"], targetKeys: ["tab"], requiredAnyOf: ["tab"]
            )
        )
    }
}
