import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
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

    func testDedupeTokenSuppressesDuplicatePresent() {
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

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)

        XCTAssertEqual(first, .confirmed)
        // The dedupe collision must still fire the caller's completion so
        // withCheckedContinuation callers unblock. `.dismissed` (not `.cancelled`)
        // signals "you were absorbed into an in-flight request."
        XCTAssertEqual(second, .dismissed,
                       "Dedupe collision must resolve the new caller with .dismissed, not leave it hanging")
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testDedupeTokenCollisionDoesNotLeakContinuation() {
        // Regression test for the continuation-leak bug (synthesis-critical §1.2):
        // the old behavior returned early without firing the dropped caller's
        // completion, suspending any withCheckedContinuation wrapper forever.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var firedCount = 0

        let firstExpectation = expectation(description: "first completes")
        let secondExpectation = expectation(description: "second completes (dropped)")

        runtime.present(
            panelId: panelId,
            interaction: .confirm(ConfirmContent(
                title: "T", message: nil,
                confirmLabel: "OK", cancelLabel: "Cancel",
                role: .standard, source: .local,
                completion: { _ in firedCount += 1; firstExpectation.fulfill() }
            )),
            dedupeToken: "once"
        )
        runtime.present(
            panelId: panelId,
            interaction: .confirm(ConfirmContent(
                title: "T", message: nil,
                confirmLabel: "OK", cancelLabel: "Cancel",
                role: .standard, source: .local,
                completion: { _ in firedCount += 1; secondExpectation.fulfill() }
            )),
            dedupeToken: "once"
        )

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        wait(for: [firstExpectation, secondExpectation], timeout: 1.0)
        XCTAssertEqual(firedCount, 2, "Both callers must have their completions fire")
    }

    func testDedupeTokenClearedOnResolveAllowsFuturePresent() {
        // Regression test for the permanent-lockout bug: cancelling a
        // close-confirm should NOT block future presents with the same token.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var first: ConfirmResult?
        var second: ConfirmResult?

        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { first = $0 }),
                        dedupeToken: "close_surface_cb.x")
        runtime.cancelActive(panelId: panelId)
        XCTAssertEqual(first, .cancelled)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))

        // A fresh present with the same token after resolution must be
        // admitted — otherwise the user can never re-trigger that action.
        runtime.present(panelId: panelId,
                        interaction: .confirm(makeConfirm { second = $0 }),
                        dedupeToken: "close_surface_cb.x")
        XCTAssertTrue(runtime.hasActive(panelId: panelId),
                      "Second present with same token after resolve must be accepted")
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
        // Real-world Cmd+D path: TextInputCard writes the live text to the
        // runtime via `updatePendingTextInputValue`, and `acceptActive` picks
        // it up. This is what the AppDelegate shortcut gate actually drives —
        // the old test passed an explicit `textInputValue` argument that
        // bypassed the real bridge and hid the data-loss bug.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: TextInputResult?

        let content = TextInputContent(
            title: "Rename", message: nil, placeholder: nil,
            defaultValue: "hello", confirmLabel: "OK", cancelLabel: "Cancel",
            validate: { _ in nil }, source: .local,
            completion: { result = $0 }
        )
        runtime.present(panelId: panelId, interaction: .textInput(content))
        // User types — TextInputCard would call this on every edit.
        runtime.updatePendingTextInputValue(interactionId: content.id, value: "world")
        let accepted = runtime.acceptActive(panelId: panelId)

        XCTAssertTrue(accepted)
        XCTAssertEqual(result, .submitted("world"))
    }

    func testAcceptActiveTextInputFallsBackToDefaultValueWhenBridgeEmpty() {
        // Backstop: if Cmd+D fires before the TextInputCard has bridged any
        // value (race between present → Cmd+D with no text edit), submit the
        // defaultValue per the original contract.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: TextInputResult?

        let content = TextInputContent(
            title: "Rename", message: nil, placeholder: nil,
            defaultValue: "default-name", confirmLabel: "OK", cancelLabel: "Cancel",
            validate: { _ in nil }, source: .local,
            completion: { result = $0 }
        )
        runtime.present(panelId: panelId, interaction: .textInput(content))
        // No bridge write — simulates the pre-onAppear race.
        let accepted = runtime.acceptActive(panelId: panelId)

        XCTAssertTrue(accepted)
        XCTAssertEqual(result, .submitted("default-name"))
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

    // MARK: - Key routing fallback

    func testHandleKeyDownConfirmLeftReturnCancelsSelectedCancel() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { result = $0 }))

        XCTAssertEqual(runtime.confirmSelection[panelId], .confirm)
        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 123)) // left
        XCTAssertEqual(runtime.confirmSelection[panelId], .cancel)
        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 36)) // return

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testHandleKeyDownConfirmUpDownAndReturn() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { result = $0 }))

        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 126)) // up
        XCTAssertEqual(runtime.confirmSelection[panelId], .cancel)
        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 125)) // down
        XCTAssertEqual(runtime.confirmSelection[panelId], .confirm)
        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 36)) // return

        XCTAssertEqual(result, .confirmed)
    }

    func testHandleKeyDownConfirmEscapeCancels() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        runtime.present(panelId: panelId, interaction: .confirm(makeConfirm { result = $0 }))
        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 53)) // escape

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(runtime.hasActive(panelId: panelId))
    }

    func testHandleKeyDownTextInputFieldSelectedDoesNotInterceptReturn() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: TextInputResult?

        runtime.present(
            panelId: panelId,
            interaction: .textInput(makeTextInput(defaultValue: "name") { result = $0 })
        )

        XCTAssertEqual(runtime.textInputSelection[panelId], .field)
        XCTAssertFalse(runtime.handleKeyDown(panelId: panelId, keyCode: 36)) // return
        XCTAssertNil(result)
        XCTAssertTrue(runtime.hasActive(panelId: panelId))
    }

    func testHandleKeyDownTextInputButtonSelectionSubmits() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: TextInputResult?

        runtime.present(
            panelId: panelId,
            interaction: .textInput(makeTextInput(defaultValue: "name") { result = $0 })
        )
        runtime.setTextInputSelection(panelId: panelId, .confirm)

        XCTAssertTrue(runtime.handleKeyDown(panelId: panelId, keyCode: 36)) // return
        XCTAssertEqual(result, .submitted("name"))
    }

    // MARK: - Interaction-ID guard

    func testResolveConfirmWithWrongInteractionIdIsNoOp() {
        // Prevents the "socket timeout cancels newly-advanced successor" race:
        // cancel/resolve with the originally-presented id must no-op if the
        // queue has advanced.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var firstResult: ConfirmResult?
        var secondResult: ConfirmResult?

        let firstContent = ConfirmContent(
            title: "A", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { firstResult = $0 }
        )
        let secondContent = ConfirmContent(
            title: "B", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { secondResult = $0 }
        )
        runtime.present(panelId: panelId, interaction: .confirm(firstContent))
        runtime.present(panelId: panelId, interaction: .confirm(secondContent))

        // Resolve the first — second advances to active.
        runtime.resolveConfirm(panelId: panelId, result: .confirmed, ifInteractionId: firstContent.id)
        XCTAssertEqual(firstResult, .confirmed)
        XCTAssertNil(secondResult)
        XCTAssertTrue(runtime.hasActive(panelId: panelId))

        // Late timeout for first — must NOT touch the advanced second.
        runtime.cancelActive(panelId: panelId, ifInteractionId: firstContent.id)
        XCTAssertNil(secondResult, "Late cancel with stale id must not resolve successor")
        XCTAssertTrue(runtime.hasActive(panelId: panelId))

        // Correct id resolves the second.
        runtime.cancelActive(panelId: panelId, ifInteractionId: secondContent.id)
        XCTAssertEqual(secondResult, .cancelled)
    }

    func testAcceptActiveWithWrongInteractionIdIsNoOp() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var result: ConfirmResult?

        let content = ConfirmContent(
            title: "A", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { result = $0 }
        )
        runtime.present(panelId: panelId, interaction: .confirm(content))

        let accepted = runtime.acceptActive(panelId: panelId, ifInteractionId: UUID())
        XCTAssertFalse(accepted)
        XCTAssertNil(result)
        XCTAssertTrue(runtime.hasActive(panelId: panelId))
    }

    // MARK: - Teardown drain

    func testClearAllDrainsAllPanelsWithDismissed() {
        // Workspace-teardown path: every pending interaction (active + queued)
        // must fire with .dismissed so no withCheckedContinuation is left
        // suspended when the workspace is removed.
        let runtime = PaneInteractionRuntime()
        let panelA = UUID()
        let panelB = UUID()
        var results: [ConfirmResult] = []

        runtime.present(panelId: panelA, interaction: .confirm(makeConfirm { results.append($0) }))
        runtime.present(panelId: panelA, interaction: .confirm(makeConfirm { results.append($0) }))
        runtime.present(panelId: panelB, interaction: .confirm(makeConfirm { results.append($0) }))

        runtime.clearAll()

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0 == .dismissed })
        XCTAssertFalse(runtime.hasAnyActive)
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
