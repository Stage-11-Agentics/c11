import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PaneInteractionRuntimeTests: XCTestCase {

    // MARK: - Presentation + queueing

    func testPresentOnEmptyPanelBecomesActive() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(
            panelId: panelId,
            interaction: .confirm(makeConfirm { result = $0 })
        )

        XCTAssertTrue(runtime.hasActive(panelId: panelId))
        XCTAssertTrue(runtime.hasAnyActive)
        XCTAssertNil(result, "Completion should not fire on present alone")
    }

    func testSecondPresentOnSamePanelQueues() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var firstResult: ConfirmResult?
        var secondResult: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { firstResult = $0 }))
        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { secondResult = $0 }))

        // First is active; second is queued.
        XCTAssertTrue(runtime.hasActive(panelId: panelId))

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        XCTAssertEqual(firstResult, .confirmed)
        XCTAssertNil(secondResult, "Second should not resolve until third action")

        // Second is now active.
        XCTAssertTrue(runtime.hasActive(panelId: panelId))
        runtime.resolveConfirm(panelId: panelId, result: .cancelled)
        XCTAssertEqual(secondResult, .cancelled)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testDifferentPanelsPresentConcurrently() {
        let runtime = PaneInteractionRuntime()
        let panelA = UUID()
        let panelB = UUID()
        var resultA: ConfirmResult?
        var resultB: ConfirmResult?

        runtime.present(panelId: panelA, interaction: .confirm(makeConfirm { resultA = $0 }))
        runtime.present(panelId: panelB, interaction: .confirm(makeConfirm { resultB = $0 }))

        XCTAssertTrue(runtime.hasActive(panelId: panelA))
        XCTAssertTrue(runtime.hasActive(panelId: panelB))
        XCTAssertEqual(runtime.activePanelIds, [panelA, panelB])

        runtime.resolveConfirm(panelId: panelA, result: .confirmed)
        XCTAssertEqual(resultA, .confirmed)
        XCTAssertNil(resultB, "Resolving A should not affect B")
        XCTAssertTrue(runtime.hasActive(panelId: panelB))
    }

    // MARK: - Cancel + dismiss

    func testCancelActiveInvokesCompletionWithCancelled() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { result = $0 }))
        runtime.cancelActive(panelId: panelId)

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testClearResolvesActiveAndQueuedWithDismissed() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var first: ConfirmResult?
        var second: ConfirmResult?
        var third: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { first = $0 }))
        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { second = $0 }))
        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { third = $0 }))

        runtime.clear(panelId: panelId)

        XCTAssertEqual(first, .dismissed)
        XCTAssertEqual(second, .dismissed)
        XCTAssertEqual(third, .dismissed)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testClearAllResolvesEveryPanelWithDismissed() {
        // Workspace teardown path: `clearAll()` must resolve every pending
        // interaction across every panel with `.dismissed`, matching what
        // `Workspace.teardownAllPanels()` relies on.
        let runtime = PaneInteractionRuntime()
        let panelA = UUID()
        let panelB = UUID()
        var resultA: ConfirmResult?
        var queuedA: ConfirmResult?
        var resultB: TextInputResult?

        runtime.present(panelId: panelA, interaction: .confirm(makeConfirm { resultA = $0 }))
        runtime.present(panelId: panelA, interaction: .confirm(makeConfirm { queuedA = $0 }))
        runtime.present(panelId: panelB, interaction: .textInput(makeTextInput { resultB = $0 }))

        runtime.clearAll()

        XCTAssertEqual(resultA, .dismissed)
        XCTAssertEqual(queuedA, .dismissed)
        XCTAssertEqual(resultB, .dismissed)
        XCTAssertFalse(runtime.hasAnyActive)
    }

    func testDismissedIsDistinctFromCancelled() {
        // Result type distinction — a panel torn down mid-dialog reports .dismissed,
        // not .cancelled. Callers rely on this to distinguish "user said no" from
        // "the state drifted out from under us."
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { result = $0 }))
        runtime.clear(panelId: panelId)

        XCTAssertEqual(result, .dismissed)
        XCTAssertNotEqual(result, .cancelled)
    }

    // MARK: - Dedupe token

    func testDedupedPresentResolvesDuplicateWithDismissed() {
        // A duplicate present (same dedupe token) must not drop the caller's
        // continuation silently. The second caller's completion fires with
        // .dismissed immediately; the in-flight interaction continues.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var first: ConfirmResult?
        var second: ConfirmResult?

        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { first = $0 }),
                        dedupeToken: "close_surface_cb.x")
        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { second = $0 }),
                        dedupeToken: "close_surface_cb.x")

        // Duplicate caller resolved immediately with .dismissed; first is still active.
        XCTAssertEqual(second, .dismissed)
        XCTAssertNil(first, "First present must remain active")
        XCTAssertTrue(runtime.hasActive(panelId: panelId))

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        XCTAssertEqual(first, .confirmed)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testSeenTokensResetAfterPanelBecomesIdle() {
        // Stable per-panel tokens (e.g. `close_surface_cb.<id>`) must not
        // permanently suppress future attempts once the panel is idle.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var first: ConfirmResult?
        var second: ConfirmResult?

        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { first = $0 }),
                        dedupeToken: "close_surface_cb.x")
        runtime.resolveConfirm(panelId: panelId, result: .cancelled)
        XCTAssertEqual(first, .cancelled)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))

        // Same token, panel is idle → should NOT be deduped.
        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { second = $0 }),
                        dedupeToken: "close_surface_cb.x")

        XCTAssertTrue(runtime.hasActive(panelId: panelId),
                      "Panel becoming idle must reset seenTokens so a re-used token presents normally")
        XCTAssertNil(second, "Second present is active, not resolved yet")

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        XCTAssertEqual(second, .confirmed)
    }

    func testDedupeTokenAllowsDifferentTokens() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var first: ConfirmResult?
        var second: ConfirmResult?

        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { first = $0 }),
                        dedupeToken: "token-a")
        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { second = $0 }),
                        dedupeToken: "token-b")

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        runtime.resolveConfirm(panelId: panelId, result: .cancelled)

        XCTAssertEqual(first, .confirmed)
        XCTAssertEqual(second, .cancelled)
    }

    // MARK: - Queue soft cap

    func testQueueSoftCapEvictsOldestQueuedWithDismissed() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        // Soft cap is 4 queued entries (plan §3.2, v3). The currently-active never
        // evicts. A 5th queued entry must evict the oldest queued with .dismissed.
        var activeResult: ConfirmResult?
        var queuedResults: [Int: ConfirmResult] = [:]

        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { activeResult = $0 }))
        for i in 0..<PaneInteractionRuntime.perPanelQueueSoftCap + 1 {
            runtime.present(panelId: panelId,
                            interaction: .confirm(makeConfirm { queuedResults[i] = $0 }))
        }

        // The oldest queued (index 0) should have been evicted with .dismissed.
        XCTAssertEqual(queuedResults[0], .dismissed)
        XCTAssertNil(activeResult, "Active must not be evicted by queue overflow")

        // Draining the queue should deliver the remaining queued confirms in FIFO order.
        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        XCTAssertEqual(activeResult, .confirmed)
        for i in 1...PaneInteractionRuntime.perPanelQueueSoftCap {
            runtime.resolveConfirm(panelId: panelId, result: .confirmed)
            XCTAssertEqual(queuedResults[i], .confirmed, "Queued index \(i) should have resolved")
        }
    }

    // MARK: - Variant mismatch

    func testResolveConfirmOnTextInputDoesNotFire() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var textResult: TextInputResult?

        runtime.present(panelId: panelId, interaction: .textInput(makeTextInput { textResult = $0 }))
        runtime.resolveConfirm(panelId: panelId, result: .confirmed)

        XCTAssertNil(textResult, "resolveConfirm must not fire a textInput completion")
        XCTAssertTrue(runtime.hasActive(panelId: panelId), "active textInput must remain")
    }

    func testResolveTextInputOnConfirmDoesNotFire() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var confirmResult: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { confirmResult = $0 }))
        runtime.resolveTextInput(panelId: panelId, result: .submitted("x"))

        XCTAssertNil(confirmResult)
        XCTAssertTrue(runtime.hasActive(panelId: panelId))
    }

    // MARK: - acceptActive (Cmd+D routing)

    func testAcceptActiveConfirmResolvesConfirmed() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { result = $0 }))
        let accepted = runtime.acceptActive(panelId: panelId)

        XCTAssertTrue(accepted)
        XCTAssertEqual(result, .confirmed)
    }

    func testAcceptActiveTextInputSubmitsValue() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: TextInputResult?

        runtime.present(panelId: panelId,
                        interaction: .textInput(makeTextInput(defaultValue: "hello") { result = $0 }))
        let accepted = runtime.acceptActive(panelId: panelId, textInputValue: "world")

        XCTAssertTrue(accepted)
        XCTAssertEqual(result, .submitted("world"))
    }

    func testAcceptActiveTextInputFailsValidationDoesNotResolve() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: TextInputResult?

        let content = TextInputContent(
            title: "T",
            message: nil,
            placeholder: nil,
            defaultValue: "",
            confirmLabel: "OK",
            cancelLabel: "Cancel",
            validate: { $0.isEmpty ? "required" : nil },
            source: .local,
            completion: { result = $0 }
        )
        runtime.present(panelId: panelId, interaction: .textInput(content))

        let accepted = runtime.acceptActive(panelId: panelId, textInputValue: "")

        XCTAssertFalse(accepted)
        XCTAssertNil(result)
        XCTAssertTrue(runtime.hasActive(panelId: panelId))
    }

    func testAcceptActiveOnEmptyPanelReturnsFalse() {
        let runtime = PaneInteractionRuntime()
        XCTAssertFalse(runtime.acceptActive(panelId: UUID()))
    }

    // MARK: - Fixtures

    private func makeConfirm(completion: @escaping (ConfirmResult) -> Void) -> ConfirmContent {
        ConfirmContent(
            title: "Close?",
            message: nil,
            confirmLabel: "Close",
            cancelLabel: "Cancel",
            role: .destructive,
            source: .local,
            completion: completion
        )
    }

    private func makeTextInput(
        defaultValue: String = "",
        completion: @escaping (TextInputResult) -> Void
    ) -> TextInputContent {
        TextInputContent(
            title: "Rename",
            message: nil,
            placeholder: nil,
            defaultValue: defaultValue,
            confirmLabel: "OK",
            cancelLabel: "Cancel",
            validate: { _ in nil },
            source: .local,
            completion: completion
        )
    }
}
