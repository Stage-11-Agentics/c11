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

    // MARK: - T1: clearAll() + dedupe-token reset (consensus gap)

    func testClearAllResetsSeenTokensAcrossPanels() {
        // T1 (Trident consensus): `clearAll()` is the workspace-teardown
        // path — it resolves active + queued interactions with `.dismissed`
        // AND must reset each panel's `seenTokens` so a re-used stable
        // token (e.g. `close_surface_cb.<id>`) on the NEXT present after
        // teardown proceeds instead of being silently suppressed.
        //
        // `clear(panelId:)` already nulls seenTokens for one panel. This
        // test locks in that `clearAll()` does it across every panel.
        let runtime = PaneInteractionRuntime()
        let panelA = UUID()
        let panelB = UUID()
        var aFirst: ConfirmResult?
        var aDeduped: ConfirmResult?
        var bFirst: ConfirmResult?
        var bDeduped: ConfirmResult?
        var aPostTeardown: ConfirmResult?
        var bPostTeardown: ConfirmResult?

        // Present with per-panel stable tokens; duplicates must be deduped.
        runtime.present(panelId: panelA,
                        interaction: .confirm(makeConfirm { aFirst = $0 }),
                        dedupeToken: "close.A")
        runtime.present(panelId: panelA,
                        interaction: .confirm(makeConfirm { aDeduped = $0 }),
                        dedupeToken: "close.A")
        runtime.present(panelId: panelB,
                        interaction: .confirm(makeConfirm { bFirst = $0 }),
                        dedupeToken: "close.B")
        runtime.present(panelId: panelB,
                        interaction: .confirm(makeConfirm { bDeduped = $0 }),
                        dedupeToken: "close.B")

        XCTAssertEqual(aDeduped, .dismissed, "Duplicate on A must dedupe")
        XCTAssertEqual(bDeduped, .dismissed, "Duplicate on B must dedupe")
        XCTAssertNil(aFirst)
        XCTAssertNil(bFirst)

        runtime.clearAll()

        XCTAssertEqual(aFirst, .dismissed, "clearAll must dismiss A's active")
        XCTAssertEqual(bFirst, .dismissed, "clearAll must dismiss B's active")
        XCTAssertFalse(runtime.hasAnyActive)

        // Re-present with the SAME tokens on each panel. After teardown,
        // seenTokens must be reset — these presents should become active,
        // not fire immediately with `.dismissed`.
        runtime.present(panelId: panelA,
                        interaction: .confirm(makeConfirm { aPostTeardown = $0 }),
                        dedupeToken: "close.A")
        runtime.present(panelId: panelB,
                        interaction: .confirm(makeConfirm { bPostTeardown = $0 }),
                        dedupeToken: "close.B")

        XCTAssertTrue(runtime.hasActive(panelId: panelA),
                      "A's post-teardown present must become active — token reset")
        XCTAssertTrue(runtime.hasActive(panelId: panelB),
                      "B's post-teardown present must become active — token reset")
        XCTAssertNil(aPostTeardown,
                     "A's post-teardown interaction must NOT be dismissed as duplicate")
        XCTAssertNil(bPostTeardown,
                     "B's post-teardown interaction must NOT be dismissed as duplicate")
    }

    // MARK: - T2: Cross-panel cancelInteraction isolation (consensus gap)

    func testCancelInteractionIsScopedToItsPanelId() {
        // T2 (Trident consensus): cancelInteraction(panelId:interactionId:)
        // scopes the id lookup to the supplied panelId. A caller holding
        // an interaction id from panel B cannot pass it with `panelId: A`
        // and have it resolve B's interaction — that would undermine the
        // per-panel isolation contract the socket layer relies on.
        let runtime = PaneInteractionRuntime()
        let panelA = UUID()
        let panelB = UUID()
        var aResult: ConfirmResult?
        var bResult: ConfirmResult?

        let a = ConfirmContent(
            title: "A", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { aResult = $0 }
        )
        let b = ConfirmContent(
            title: "B", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { bResult = $0 }
        )
        runtime.present(panelId: panelA, interaction: .confirm(a))
        runtime.present(panelId: panelB, interaction: .confirm(b))

        // Ask panel A to cancel panel B's interaction id — must not hit.
        let hit = runtime.cancelInteraction(panelId: panelA, interactionId: b.id)

        XCTAssertFalse(hit, "Panel A must not resolve an interaction id that belongs to panel B")
        XCTAssertNil(aResult, "Panel A's active must not fire")
        XCTAssertNil(bResult, "Panel B's active must not fire")
        XCTAssertTrue(runtime.hasActive(panelId: panelA))
        XCTAssertTrue(runtime.hasActive(panelId: panelB))
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

    // MARK: - cancelInteraction (targeted cancel by id)

    func testCancelInteractionQueuedRemovesQueuedOnly() {
        // Socket `pane.confirm` timeout must cancel ONLY the caller's own
        // interaction. If the caller's interaction is queued behind an
        // active one, the active must not be disturbed.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var activeResult: ConfirmResult?
        var queuedResult: ConfirmResult?

        let activeContent = ConfirmContent(
            title: "A", message: nil,
            confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { activeResult = $0 }
        )
        let queuedContent = ConfirmContent(
            title: "B", message: nil,
            confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { queuedResult = $0 }
        )
        runtime.present(panelId: panelId, interaction: .confirm(activeContent))
        runtime.present(panelId: panelId, interaction: .confirm(queuedContent))

        let hit = runtime.cancelInteraction(panelId: panelId, interactionId: queuedContent.id)

        XCTAssertTrue(hit)
        XCTAssertEqual(queuedResult, .dismissed, "Queued interaction must resolve with .dismissed")
        XCTAssertNil(activeResult, "Active interaction must not be disturbed")
        XCTAssertTrue(runtime.hasActive(panelId: panelId), "Active must stay active")
    }

    func testCancelInteractionActivePromotesNextQueued() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        var activeResult: ConfirmResult?
        var queuedResult: ConfirmResult?

        let activeContent = ConfirmContent(
            title: "A", message: nil,
            confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { activeResult = $0 }
        )
        let queuedContent = ConfirmContent(
            title: "B", message: nil,
            confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { queuedResult = $0 }
        )
        runtime.present(panelId: panelId, interaction: .confirm(activeContent))
        runtime.present(panelId: panelId, interaction: .confirm(queuedContent))

        let hit = runtime.cancelInteraction(panelId: panelId, interactionId: activeContent.id)

        XCTAssertTrue(hit)
        XCTAssertEqual(activeResult, .dismissed)
        XCTAssertNil(queuedResult, "Queued must not yet resolve — it's promoted, not cancelled")
        XCTAssertTrue(runtime.hasActive(panelId: panelId), "Queued was promoted to active")
    }

    func testCancelInteractionMissReturnsFalse() {
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()
        let hit = runtime.cancelInteraction(panelId: panelId, interactionId: UUID())
        XCTAssertFalse(hit)
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

    // MARK: - v2PaneConfirm timeout race (Blocker #1)

    func testV2PaneConfirmTimeoutRaceHonorsLateCompletion() {
        // Blocker #1: `semaphore.wait(timeout:)` returns `.timedOut`, but in the
        // microseconds between that return and the timeout branch's cancel
        // side-effect running on main, the user clicks Confirm. The completion
        // fires on main, sets `holder.value = .confirmed`, and signals the
        // semaphore (no-op — already timed out). The socket thread used to
        // hard-code `"dismissed"` in the timeout branch, discarding the real
        // user answer even though the side-effect tied to `.confirmed` already
        // ran. Agent-facing protocol bug.
        //
        // This test pins the invariant by threading a mutable outcome through
        // the resolver: `onTimeout` flips it to `.confirmed` (simulating the
        // late completion), and the response must reflect `"ok"`, not
        // `"dismissed"`.
        var outcome: ConfirmResult = .dismissed
        let result = TerminalController.v2PaneConfirmResolveOutcomeForTesting(
            wait: { .timedOut },
            onTimeout: {
                // Completion fired in the race window between wait-return
                // and cancel-run; holder was populated.
                outcome = .confirmed
            },
            readOutcome: { outcome }
        )
        XCTAssertEqual(result, "ok",
                       "Timeout branch must honor a late-firing completion's outcome, "
                       + "not hard-code \"dismissed\".")
    }

    func testV2PaneConfirmTimeoutNonRacyReturnsDismissed() {
        // Non-racy timeout: genuine deadline, no completion races in.
        // `onTimeout` runs cancelInteraction which fires .dismissed on
        // the completion, populating the holder with .dismissed. The
        // response is "dismissed" — unchanged from pre-fix behavior.
        var outcome: ConfirmResult = .dismissed
        let result = TerminalController.v2PaneConfirmResolveOutcomeForTesting(
            wait: { .timedOut },
            onTimeout: {
                // cancelInteraction fires .dismissed; holder is already at
                // the default. Represent this by leaving outcome alone.
                outcome = .dismissed
            },
            readOutcome: { outcome }
        )
        XCTAssertEqual(result, "dismissed")
    }

    func testV2PaneConfirmSuccessBranchDoesNotFireTimeout() {
        // Signal arrived before deadline: wait returns `.success`, onTimeout
        // must not run, and the outcome is whatever the completion wrote.
        var timeoutFired = false
        let result = TerminalController.v2PaneConfirmResolveOutcomeForTesting(
            wait: { .success },
            onTimeout: { timeoutFired = true },
            readOutcome: { .cancelled }
        )
        XCTAssertFalse(timeoutFired)
        XCTAssertEqual(result, "cancel")
    }

    // MARK: - Reentrant present (Blocker #2 — advance-before-fire invariant)

    func testResolveConfirmReentrantPresentPreservesQueueHead() {
        // Blocker #2 regression: resolveConfirm must advance queue state BEFORE
        // firing the completion. Otherwise a completion that synchronously
        // calls `present()` installs its own active slot, then `advance()`
        // fires afterwards and silently overwrites it with the queue head.
        // The re-entrant interaction's continuation would never fire.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()

        var aResult: ConfirmResult?
        var bResult: ConfirmResult?
        var cResult: ConfirmResult?

        // C is presented synchronously from inside A's completion.
        let c = ConfirmContent(
            title: "C", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { cResult = $0 }
        )
        let b = ConfirmContent(
            title: "B", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { bResult = $0 }
        )
        let a = ConfirmContent(
            title: "A", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { [weak runtime] result in
                aResult = result
                // Re-enter while active[panelId] is supposedly nil — the bug
                // would allow C to become active here, only to be wiped by
                // a post-completion `advance` promoting B.
                runtime?.present(panelId: panelId, interaction: .confirm(c))
            }
        )

        runtime.present(panelId: panelId, interaction: .confirm(a))
        runtime.present(panelId: panelId, interaction: .confirm(b))

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)

        // A's completion fired.
        XCTAssertEqual(aResult, .confirmed)
        // Neither B nor C's completion has fired yet.
        XCTAssertNil(bResult, "B must still be pending (either active or queued)")
        XCTAssertNil(cResult, "C must still be pending — not overwritten, not lost")
        XCTAssertTrue(runtime.hasActive(panelId: panelId))

        // Drain: B is queue head, should promote before C. Without the fix,
        // C would have been overwritten by B when advance fired after A's
        // completion, so bResult would resolve here but cResult would never.
        runtime.resolveConfirm(panelId: panelId, result: .cancelled)
        XCTAssertEqual(bResult, .cancelled, "Queue head B must have been promoted, not lost")
        XCTAssertNil(cResult)

        runtime.resolveConfirm(panelId: panelId, result: .confirmed)
        XCTAssertEqual(cResult, .confirmed,
                       "C's continuation must fire — the reentrant present cannot be dropped")
    }

    func testResolveConfirmReentrantPresentPreservesDedupeToken() {
        // Blocker #2 (Gemini variant): when the queue is empty at resolve
        // time, advance also wipes `seenTokens[panelId]`. If the completion
        // synchronously presents a new interaction with a dedupe token, the
        // token registration happens BEFORE advance fires — and advance then
        // nukes it. Subsequent duplicate presents would no longer be deduped.
        let runtime = PaneInteractionRuntime()
        let panelId = UUID()

        var aResult: ConfirmResult?
        var bResult: ConfirmResult?
        var cResult: ConfirmResult?

        let b = ConfirmContent(
            title: "B", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { bResult = $0 }
        )
        let a = ConfirmContent(
            title: "A", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { [weak runtime] result in
                aResult = result
                runtime?.present(
                    panelId: panelId,
                    interaction: .confirm(b),
                    dedupeToken: "token-x"
                )
            }
        )

        runtime.present(panelId: panelId, interaction: .confirm(a))
        // No queued entries behind A — advance's "fully idle" branch will run.
        runtime.resolveConfirm(panelId: panelId, result: .confirmed)

        XCTAssertEqual(aResult, .confirmed)
        XCTAssertNil(bResult, "B must be active now, not resolved")
        XCTAssertTrue(runtime.hasActive(panelId: panelId))

        // Fresh present with the same token-x must be deduped — the token
        // registered during the reentrant present inside A's completion must
        // have survived the state transition.
        let c = ConfirmContent(
            title: "C", message: nil, confirmLabel: "OK", cancelLabel: "Cancel",
            role: .standard, source: .local,
            completion: { cResult = $0 }
        )
        runtime.present(panelId: panelId, interaction: .confirm(c), dedupeToken: "token-x")

        XCTAssertEqual(cResult, .dismissed,
                       "token-x must still be registered — advance must not wipe tokens "
                       + "registered during a reentrant present in the completion")
        XCTAssertNil(bResult, "B remains active; it was never disturbed")
        XCTAssertTrue(runtime.hasActive(panelId: panelId))
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
