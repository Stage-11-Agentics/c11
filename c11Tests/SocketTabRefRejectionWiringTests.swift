import XCTest
import Darwin
import GhosttyKit
@testable import c11

/// C11-165 COR-1 — the *wiring* half of COR-4. The pure seam
/// (`SocketSurfaceRefValidator`) is covered in `c11LogicTests`; this
/// host-target test proves a real v2 write handler actually INVOKES that
/// seam, so a future handler that forgets the guard is caught in CI (the
/// `c11-unit` scheme runs host tests). It drives `processV2Command`
/// end-to-end (dispatch → per-domain handler → validator) — the same entry
/// the socket accept loop calls. An empty/absent `surface_id` is rejected by
/// the validator *before* any surface resolution, so no live surface is
/// required.
///
/// Host target (not `c11LogicTests`): `processV2Command` is a
/// `@MainActor` method on the app's `TerminalController`; per CLAUDE.md /
/// C11-105 the shared controller must not be touched from a `c11LogicTests`
/// member. This test never calls `stop()`, so it does not disturb the
/// per-PID host socket.
@MainActor
final class SocketTabRefRejectionWiringTests: XCTestCase {

    private func responseCode(for json: String) -> String {
        let response = TerminalController.shared.processV2Command(json)
        guard let data = response.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let code = error["code"] as? String else {
            return "<no-error:\(response)>"
        }
        return code
    }

    func testSurfaceSetMetadataRejectsEmptySurfaceRef() {
        // Valid metadata/mode/source so dispatch reaches the ref guard, then an
        // explicitly-empty surface_id → empty_ref (never the focused surface).
        let code = responseCode(for: """
        {"method":"surface.set_metadata","params":{"metadata":{"k":"v"},"surface_id":""}}
        """)
        XCTAssertEqual(code, "empty_ref",
                       "surface.set_metadata with an empty surface_id must be rejected, not defaulted to focus")
    }

    func testSurfaceSetMetadataRejectsAbsentSurfaceRef() {
        let code = responseCode(for: """
        {"method":"surface.set_metadata","params":{"metadata":{"k":"v"}}}
        """)
        XCTAssertEqual(code, "missing_ref",
                       "surface.set_metadata with no surface target must be rejected, not defaulted to focus")
    }

    func testSurfaceTriggerFlashRejectsEmptySurfaceRef() {
        let code = responseCode(for: """
        {"method":"surface.trigger_flash","params":{"surface_id":"  "}}
        """)
        XCTAssertEqual(code, "empty_ref",
                       "trigger-flash with a whitespace surface_id must be rejected")
    }

    func testPaneSetMetadataRejectsAbsentPaneRef() {
        let code = responseCode(for: """
        {"method":"pane.set_metadata","params":{"metadata":{"k":"v"}}}
        """)
        XCTAssertEqual(code, "missing_ref",
                       "pane.set_metadata with no pane target must be rejected")
    }

    func testRenameRejectsEmptyRef() {
        let code = responseCode(for: """
        {"method":"surface.action","params":{"action":"rename","title":"x","surface_id":""}}
        """)
        XCTAssertEqual(code, "empty_ref",
                       "rename with an empty surface_id must be rejected")
    }
}

@MainActor
final class TerminalReadCaptureTests: XCTestCase {
    func testQueuedMainHopReturnsAtCallerDeadline() {
        // Deliberately hold main while the actual socket worker queues its first
        // hop. The worker must finish without running the main callback.
        let done = DispatchSemaphore(value: 0)
        let result = TerminalReadCompletion<TerminalController.V2CallResult>(deadline: .now() + 1)
        Thread.detachNewThread {
            result.complete(TerminalController.shared.v2SurfaceReadText(params: [:], timeout: 0.03))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.5), .success)
        guard case .err(let code, _, _) = result.wait() else { return XCTFail("expected timeout") }
        XCTAssertEqual(code, "timeout")
    }

    func testBusyRegionRejectsWholeReadAndFreesEarlierOKExactlyOnce() {
        let controller = TerminalController.shared
        let surface = UnsafeMutableRawPointer(bitPattern: 1)!
        let source = Array("owned λ雪".utf8)
        var allocations = 0
        var frees = 0
        var reads = 0
        let result = controller.captureTerminalReadBytes(
            surface: surface, includeScrollback: true, isAbandoned: { false },
            read: { _, _, output in
                reads += 1
                output.pointee = ghostty_text_s()
                if reads == 2 { return GHOSTTY_TEXT_READ_BUSY }
                let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: source.count)
                for (index, byte) in source.enumerated() { pointer[index] = CChar(bitPattern: byte) }
                output.pointee.text = UnsafePointer(pointer)
                output.pointee.text_len = UInt(source.count)
                allocations += 1
                return GHOSTTY_TEXT_READ_OK
            },
            free: { _, output in
                frees += 1
                UnsafeMutablePointer(mutating: output.pointee.text)?.deallocate()
                output.pointee = ghostty_text_s()
            }
        )
        guard case .failure(.err(let code, _, _)) = result else { return XCTFail("Expected typed busy error") }
        XCTAssertEqual(code, "busy")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(allocations, 1)
        XCTAssertEqual(frees, 1)
    }

    func testOKCopiesBeforeFreeEvenWhenCallerAbandonsDuringNativeRead() {
        let controller = TerminalController.shared
        let surface = UnsafeMutableRawPointer(bitPattern: 1)!
        var abandoned = false
        var frees = 0
        let result = controller.captureTerminalReadBytes(
            surface: surface, includeScrollback: false, isAbandoned: { abandoned },
            read: { _, _, output in
                let pointer = strdup("owned bytes")!
                output.pointee = ghostty_text_s()
                output.pointee.text = UnsafePointer(pointer)
                output.pointee.text_len = 11
                abandoned = true // Native work outlived the caller.
                return GHOSTTY_TEXT_READ_OK
            },
            free: { _, output in
                frees += 1
                Darwin.free(UnsafeMutableRawPointer(mutating: output.pointee.text))
                output.pointee = ghostty_text_s()
            }
        )
        guard case .success(let bytes) = result else { return XCTFail("Expected independently owned capture") }
        XCTAssertEqual(bytes.viewport, Data("owned bytes".utf8))
        XCTAssertEqual(frees, 1)
        let completion = TerminalReadCompletion<TerminalReadBytes>(deadline: .now())
        XCTAssertFalse(completion.complete(bytes))
    }

    func testAbandonedCaptureDoesNotCallNativeReader() {
        let result = TerminalController.shared.captureTerminalReadBytes(
            surface: UnsafeMutableRawPointer(bitPattern: 1)!,
            includeScrollback: true, isAbandoned: { true },
            read: { _, _, _ in XCTFail("Late native capture ran"); return GHOSTTY_TEXT_READ_FAILED },
            free: { _, _ in XCTFail("Non-OK read freed unowned allocation") }
        )
        guard case .failure(.err(let code, _, _)) = result else { return XCTFail("Expected timeout") }
        XCTAssertEqual(code, "timeout")
    }

    func testExplicitStaleSplitAndReadNeverFallBackToFocus() async {
        let params: [String: Any] = ["surface_id": "tab:999999999", "direction": "right"]
        let split = TerminalController.shared.v2SurfaceSplit(params: params)
        guard case .err(let splitCode, _, _) = split else { return XCTFail("Stale split succeeded") }
        XCTAssertEqual(splitCode, "not_found")
        let read = await Task.detached {
            TerminalController.shared.v2SurfaceReadText(params: ["surface_id": "tab:999999999"])
        }.value
        guard case .err(let readCode, _, _) = read else { return XCTFail("Stale read succeeded") }
        XCTAssertEqual(readCode, "not_found")
    }
}
