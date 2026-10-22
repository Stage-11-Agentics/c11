import XCTest
@testable import c11

/// Exercise the real command router with a focused panel available: a stale
/// explicit target must fail before any read can resolve that focused panel.
@MainActor
final class PanelReadTargetRoutingTests: XCTestCase {
    private func call(_ controller: TerminalController, _ method: String,
                      _ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": 478, "method": method, "params": params])
        let command = String(decoding: data, as: UTF8.self)
        let response = await Task.detached {
            controller.processCommandUsingSocketExecutionPolicy(command)
        }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func checkFocusedRead(_ method: String) async throws {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        let panelID = try XCTUnwrap(workspace.focusedPanelId)
        let controller = TerminalController.makeForTesting()
        controller.setActiveWorkspaceManager(manager)
        let ordinal = controller.surfaceOrdinal(forSurfaceUUID: panelID)
        for valid in [panelID.uuidString, "panel:\(ordinal)"] {
            let before = try await call(controller, method, ["panel_id": valid])
            XCTAssertEqual(before["ok"] as? Bool, true, "\(method): \(before)")
            let result = try XCTUnwrap(before["result"] as? [String: Any])
            XCTAssertEqual(result["panel_id"] as? String, panelID.uuidString)
            for key in ["panel_id", "surface_id", "tab_id"] {
                for stale in ["panel:999999999", UUID().uuidString] {
                    let response = try await call(controller, method, [key: stale])
                    XCTAssertEqual(response["ok"] as? Bool, false, "\(method) \(key): \(response)")
                    XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "not_found")
                    XCTAssertNil(response["result"], "Stale target exposed another panel's data")
                }
            }
            let after = try await call(controller, method, ["panel_id": valid])
            XCTAssertEqual(after["ok"] as? Bool, true)
            XCTAssertEqual((after["result"] as? [String: Any])?["panel_id"] as? String, panelID.uuidString)
        }
    }

    func testMetadataStaleTargetNeverReadsFocusedPanel() async throws {
        try await checkFocusedRead("panel.get_metadata")
    }

    func testTitlebarStaleTargetNeverReadsFocusedPanel() async throws {
        try await checkFocusedRead("panel.get_titlebar_state")
    }

    func testWorkerReadsRejectStaleTargetsThroughCommandRouter() async throws {
        let controller = TerminalController.makeForTesting()
        let missingPanelID = UUID()
        let knownOrdinal = controller.surfaceOrdinal(forSurfaceUUID: missingPanelID)
        for method in ["panel.read_text", "panel.read_selection", "panel.input_state"] {
            for key in ["panel_id", "surface_id", "tab_id"] {
                for stale in ["panel:999999999", missingPanelID.uuidString, "panel:\(knownOrdinal)"] {
                    let response = try await call(controller, method, [key: stale])
                    XCTAssertEqual(response["ok"] as? Bool, false, "\(method) \(key): \(response)")
                    XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "not_found", "\(method) \(key): \(response)")
                    XCTAssertNil(response["result"])
                }
            }
        }
    }
}

/// C11-165 COR-1 — empty/absent surface-ref rejection (the logic-suite half
/// of COR-4). `SocketSurfaceRefValidator` is the pure seam the v2/v1 write
/// handlers invoke (`v2RejectInvalidSurfaceRef`, `v1RejectMissingTabRef`), so
/// the rejection contract is exercised here in `c11LogicTests` — no socket
/// frame loop, no `TerminalController.shared` (which would unlink the prod
/// socket, per CLAUDE.md / C11-105). This file is a `c11LogicTests` member;
/// the *wiring* proof (that a real handler calls this seam) lives in the
/// host-target `SocketSurfaceRefRejectionWiringTests`.
final class SocketPanelRefValidatorTests: XCTestCase {

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
