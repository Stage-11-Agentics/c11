import XCTest
import AppKit
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-24 (T3.9): explicit close ends hc sessions by exact key, keeps every
/// end hc has not confirmed, and never reports pending as ended.
final class HCExplicitEndCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private let key = HCTerminalKey(owningCoreID: "core-1", localAddress: "t7")

    private func ready(_ sequence: UInt64, generation: UInt64 = 1) -> HCInventorySnapshot {
        HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: generation, sequence: sequence)),
            revision: HCRevision(connectionGeneration: generation, sequence: sequence)
        )
    }

    private func evidence(_ key: HCTerminalKey, creation: UUID? = nil) -> HCEndEvidence {
        HCEndEvidence(id: UUID(), key: key, creationID: creation, revision: HCRevision(connectionGeneration: 1, sequence: 9),
                      kind: .observedRemoval, hcReason: "killed")
    }

    private func outcome(_ coordinator: HCExplicitEndCoordinator, _ panelID: UUID, timeout: TimeInterval = 2) async -> HCPanelEndOutcome? {
        await coordinator.outcomes(for: [panelID], timeout: timeout)[panelID]
    }

    /// Spin until `condition` holds (fake work hops through tasks and queues).
    private func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Tests

    func testExactKeyEndsThatKeyOnceWithoutLookup() async {
        let session = HCEndFakeSession()
        session.scriptEnd(key, .confirmed(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        let panel = UUID()

        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .panelClose)

        let result = await outcome(coordinator, panel)
        XCTAssertEqual(result, .ended)
        XCTAssertEqual(session.ends, [key])
        XCTAssertTrue(session.resolves.isEmpty, "an exact key needs no lookup")
        XCTAssertFalse(coordinator.isEndPending(panelID: panel))
    }

    /// C11H-308: a panel closed while its terminal is being created: the end
    /// waits through creationPending until the creation is listed, then ends it.
    func testACloseDuringCreationWaitsForTheCreationThenEndsIt() async {
        let session = HCEndFakeSession()
        let panel = UUID(), creation = UUID()
        let closing = HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)
        session.scriptResolve(panel, .unresolved(closing, .creationPending),
            .live(HCTerminalRecord(key: key, state: .running, labels: ["c11.panel": panel.uuidString, "c11.creation": creation.uuidString])))
        // The end confirms this very creation's terminal, so nothing else is looked up.
        session.scriptEnd(key, .confirmed(evidence(key, creation: creation)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([closing], origin: .panelClose)
        await eventually { session.resolves.count == 1 }
        XCTAssertTrue(session.ends.isEmpty, "nothing to end while the creation is unlisted")
        XCTAssertTrue(coordinator.isEndPending(panelID: panel))
        session.emit(ready(1))

        let result = await outcome(coordinator, panel)
        XCTAssertEqual(result, .ended)
        XCTAssertEqual(session.ends, [key])
    }

    /// C11H-308: a panel replacing a terminal that already finished keeps the
    /// old key while the replacement is created. Its close ends the old key,
    /// finds it finished, and keeps the end open, whatever the first lookup of
    /// the replacement says (still unlisted, an inventory resnapshotting after a
    /// run, a lost link, or the previous creation's end, which is not this
    /// creation's), until the replacement is listed and ended.
    func testAReplacementBeingCreatedIsEndedWhenItsPanelClosesWhateverItsFirstLookupSays() async {
        let earlier = UUID()
        let firstLookups: [(String, (HCPanelIdentity) -> HCLifecycle)] = [
            ("creationPending", { .unresolved($0, .creationPending) }),
            ("inventoryPending", { .unresolved($0, .inventoryPending) }),
            ("connectionLost", { .unresolved($0, .connectionLost) }),
            ("an earlier creation's end", { _ in .ended(self.evidence(self.key, creation: earlier)) }),
        ]
        for (first, lookup) in firstLookups {
            let session = HCEndFakeSession()
            let panel = UUID(), replacement = UUID()
            let newKey = HCTerminalKey(owningCoreID: "core-1", localAddress: "t9")
            let closing = HCPanelIdentity(panelID: panel, key: key, creationID: replacement, origin: .fresh)
            session.scriptEnd(key, .confirmed(evidence(key, creation: earlier)), .confirmed(evidence(key, creation: earlier)))
            session.scriptResolve(panel, lookup(closing),
                .live(HCTerminalRecord(key: newKey, state: .running, labels: ["c11.panel": panel.uuidString, "c11.creation": replacement.uuidString])))
            session.scriptEnd(newKey, .confirmed(evidence(newKey)))
            let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

            coordinator.requestEnd([closing], origin: .panelClose)
            await eventually { session.resolves.count == 1 }
            XCTAssertEqual(session.ends, [key], "\(first)")
            XCTAssertTrue(coordinator.isEndPending(panelID: panel), "\(first): the replacement in flight keeps the end open")
            session.emit(ready(1))

            let result = await outcome(coordinator, panel)
            XCTAssertEqual(result, .ended, "\(first)")
            XCTAssertEqual(session.ends, [key, key, newKey], "\(first)")
        }
    }

    func testKeylessLiveTerminalEndsTheResolvedRecordKey() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        session.scriptResolve(panel, .live(HCTerminalRecord(key: key, state: .running, labels: ["c11.panel": panel.uuidString])))
        session.scriptEnd(key, .confirmed(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([HCPanelIdentity(panelID: panel)], origin: .panelClose)

        let result = await outcome(coordinator, panel)
        XCTAssertEqual(result, .ended)
        XCTAssertEqual(session.ends, [key])
    }

    func testNewAndEndedLookupsEndNothing() async {
        let session = HCEndFakeSession()
        let fresh = UUID()
        let finished = UUID()
        session.scriptResolve(fresh, .new)
        session.scriptResolve(finished, .ended(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([HCPanelIdentity(panelID: fresh), HCPanelIdentity(panelID: finished)], origin: .workspaceClose)

        let results = await coordinator.outcomes(for: [fresh, finished], timeout: 2)
        XCTAssertEqual(results[fresh], HCPanelEndOutcome.none)
        XCTAssertEqual(results[finished], .alreadyEnded)
        XCTAssertTrue(session.ends.isEmpty)
    }

    func testAcceptedEndStaysPendingUntilResolverProvesIt() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        session.scriptEnd(key, .pending(key))
        // First evidence check: still live. Second: ended.
        session.scriptResolve(panel, .live(HCTerminalRecord(key: key, state: .running)), .ended(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .panelClose)
        let early = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(early, .pending(nil), "acceptance alone is not death")
        XCTAssertTrue(coordinator.isEndPending(panelID: panel))
        XCTAssertEqual(coordinator.pendingEndKeys(), [key])

        session.emit(ready(1))
        let mid = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(mid, .pending(nil), "a resolver that still sees it live keeps it pending")

        session.emit(ready(2))
        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.ends, [key], "an accepted end is never sent twice")
        XCTAssertFalse(coordinator.isEndPending(panelID: panel))
    }

    func testUnresolvedLookupRetriesOnNextReadyRevisionAndEndsOnce() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        let identity = HCPanelIdentity(panelID: panel)
        session.scriptResolve(panel, .unresolved(identity, .inventoryPending), .live(HCTerminalRecord(key: key, state: .running)))
        session.scriptEnd(key, .confirmed(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([identity], origin: .panelClose)
        let early = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(early, .pending(.inventoryPending))
        XCTAssertTrue(session.ends.isEmpty, "an unresolved lookup never ends by label")

        // An unready snapshot is not a retry trigger.
        session.emit(HCInventorySnapshot(readiness: .pending(.connectionLost), revision: HCRevision(connectionGeneration: 1, sequence: 1)))
        let stillPending = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(stillPending, .pending(.inventoryPending))
        XCTAssertEqual(session.resolves.count, 1)

        session.emit(ready(2))
        session.emit(ready(2)) // duplicate revision
        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.ends, [key])
    }

    /// The once-per-ready-revision rule: an unresolved end retries on a newer
    /// ready revision, never again on one it already used.
    func testSameReadyRevisionDoesNotRetryAgainAfterTheAttemptCompleted() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        let identity = HCPanelIdentity(panelID: panel)
        session.scriptResolve(
            panel,
            .unresolved(identity, .inventoryPending),
            .unresolved(identity, .inventoryPending),
            .live(HCTerminalRecord(key: key, state: .running))
        )
        session.scriptEnd(key, .confirmed(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([identity], origin: .panelClose)
        await eventually { session.resolves.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000) // let the attempt complete

        session.emit(ready(1))
        await eventually { session.resolves.count == 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterFirstRevision = await outcome(coordinator, panel, timeout: 0)
        XCTAssertEqual(afterFirstRevision, .pending(.inventoryPending))

        // The same ready revision again, after its attempt completed: no retry.
        session.emit(ready(1))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.resolves.count, 2, "a consumed ready revision must not trigger another attempt")
        XCTAssertTrue(session.ends.isEmpty)

        // A newer ready revision: exactly one retry, which ends it.
        session.emit(ready(2))
        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.resolves.count, 3)
        XCTAssertEqual(session.ends, [key])
    }

    func testUnresolvedEndRetriesTheSameExactKey() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        session.scriptEnd(key, .unresolved(key, .connectionLost), .confirmed(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())

        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .windowClose)
        let early = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(early, .pending(.connectionLost))

        session.emit(ready(1, generation: 2))
        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.ends, [key, key])
    }

    func testRepeatedRequestForAPendingPanelDoesNotEndTwice() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        session.scriptEnd(key, .pending(key))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        let identity = HCPanelIdentity(panelID: panel, key: key)

        coordinator.requestEnd([identity], origin: .panelClose)
        coordinator.requestEnd([identity], origin: .workspaceClose)
        _ = await outcome(coordinator, panel, timeout: 0.2)

        XCTAssertEqual(session.ends, [key])
    }

    func testPendingEndIsPersistedAndFinishedAfterRestart() async {
        let store = HCEndMemoryStore()
        let panel = UUID()
        let identity = HCPanelIdentity(panelID: panel)
        do {
            let session = HCEndFakeSession()
            session.scriptResolve(panel, .unresolved(identity, .coreUnreachable))
            let coordinator = HCExplicitEndCoordinator(session: session, store: store)
            coordinator.requestEnd([identity], origin: .panelClose)
            let early = await outcome(coordinator, panel, timeout: 0.2)
            XCTAssertEqual(early, .pending(.coreUnreachable))
        }
        XCTAssertEqual(store.saved.map(\.identity.panelID), [panel], "an unconfirmed end survives the app")

        // Next launch: the terminal is still live. The owed end finishes; it is
        // never handed to Recovered as an orphan.
        let session = HCEndFakeSession()
        session.scriptResolve(panel, .live(HCTerminalRecord(key: key, state: .running)))
        session.scriptEnd(key, .confirmed(evidence(key)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: store)
        await eventually { coordinator.isEndPending(panelID: panel) || !session.ends.isEmpty }

        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.ends, [key])
        XCTAssertTrue(store.saved.isEmpty)
    }

    /// Recovered reads the pending sets without waiting, right after install.
    func testPersistedPendingEndsAreVisibleBeforeInitReturns() {
        let panel = UUID()
        let record = HCPendingEndRecord(identity: HCPanelIdentity(panelID: panel, key: key), key: key, origin: .panelClose)
        let coordinator = HCExplicitEndCoordinator(session: HCEndFakeSession(), store: HCEndMemoryStore([record]))
        // No await, no wait: visible as soon as init returns.
        XCTAssertEqual(coordinator.pendingEndPanelIDs(), [panel])
        XCTAssertEqual(coordinator.pendingEndKeys(), [key])
        XCTAssertTrue(coordinator.isEndPending(panelID: panel))
    }

    @MainActor
    private func resetComposition() {
        HCSessionEnd.resetForTesting()
        HCRecoveredTerminalController.pendingEndPanelIDs = { [] }
        HCRecoveredTerminalController.pendingEndKeys = { [] }
    }

    @MainActor
    func testComposedActivationInstallsExplicitEnd() {
        resetComposition()
        defer { resetComposition() }
        let composition = HCBackendComposition()
        HCSessionEnd.compose(into: composition, store: { HCEndMemoryStore() })
        XCTAssertNil(HCSessionEnd.coordinator, "composing alone installs nothing")

        composition.activate(session: HCEndFakeSession(), inventory: HCUnavailableRuntime()) { _ in }

        XCTAssertNotNil(HCSessionEnd.coordinator, "activation installs explicit end")
    }

    @MainActor
    func testComposedRecoveryReadsTheInstalledCoordinatorsPendingEnds() {
        resetComposition()
        defer { resetComposition() }
        let panel = UUID()
        let record = HCPendingEndRecord(identity: HCPanelIdentity(panelID: panel, key: key), key: key, origin: .endAll)
        HCSessionEnd.compose(into: HCBackendComposition())
        XCTAssertEqual(HCRecoveredTerminalController.pendingEndPanelIDs(), [], "nothing installed yet")

        HCSessionEnd.install(session: HCEndFakeSession(), store: HCEndMemoryStore([record]))

        // Startup recovery must see the persisted pending end before it runs.
        XCTAssertEqual(HCRecoveredTerminalController.pendingEndPanelIDs(), [panel])
        XCTAssertEqual(HCRecoveredTerminalController.pendingEndKeys(), [key])
    }

    func testUnknownPanelReportsNone() async {
        let coordinator = HCExplicitEndCoordinator(session: HCEndFakeSession(), store: HCEndMemoryStore())
        let panel = UUID()
        let result = await outcome(coordinator, panel, timeout: 0.1)
        XCTAssertEqual(result, HCPanelEndOutcome.none)
    }

    // MARK: - End status with repeated ids

    func testEndStatusWithRepeatedIdsAndNoCoordinatorAnswersOncePerPanel() {
        HCSessionEnd.resetForTesting()
        let panel = UUID()
        let other = UUID()
        let done = expectation(description: "status")
        var result: [UUID: HCPanelEndOutcome] = [:]
        // waitForOutcomes is socket-worker only; never call it on main.
        DispatchQueue.global().async {
            result = HCSessionEnd.waitForOutcomes(panelIds: [panel, other, panel], timeout: 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[panel], HCPanelEndOutcome.none)
        XCTAssertEqual(result[other], HCPanelEndOutcome.none)
    }

    func testTimeoutFallbackOutcomesTolerateRepeatedIds() {
        let panel = UUID()
        let other = UUID()
        let result = HCSessionEnd.uniformOutcomes([panel, panel, other], .pending(.deadlineExceeded))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[panel], .pending(.deadlineExceeded))
    }

    func testStatusIdsAreDedupedInRequestOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(HCSessionEnd.uniquePanelIds([b, a, b, c, a]), [b, a, c])
        let rows = HCSessionEnd.wireOutcomes(panelIds: HCSessionEnd.uniquePanelIds([a, a]), outcomes: [a: .ended])
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Pending-end file store

    func testFileStoreRoundTripsAndRemovesWhenEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hc-end-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("runtime/\(HCPendingEndFileStore.fileName)")
        let store = HCPendingEndFileStore(url: url)
        let record = HCPendingEndRecord(identity: HCPanelIdentity(panelID: UUID(), key: key), key: key, origin: .areaClose)

        store.save([record])
        XCTAssertEqual(HCPendingEndFileStore(url: url).load(), [record])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDefaultStoreLivesUnderTheAppStateRoot() throws {
        let url = try XCTUnwrap(HCPendingEndFileStore.defaultURL())
        let root = try MailboxLayout.defaultStateURL()
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    // MARK: - Copy and clear-history result

    func testEndSessionCopyNamesWhatEnds() {
        XCTAssertEqual(HCCloseCopy.panelTitle, "End session?")
        XCTAssertEqual(HCCloseCopy.panelConfirmLabel, "End Session")
        for needle in ["ends its terminal session", "every process it started", "background", "nohup"] {
            XCTAssertTrue(HCCloseCopy.panelMessage.contains(needle), needle)
        }
        let group = HCCloseCopy.groupMessage("This will close the workspace.", endsSession: true)
        XCTAssertTrue(group.hasPrefix("This will close the workspace."))
        XCTAssertTrue(group.contains("nohup"))
        XCTAssertEqual(HCCloseCopy.groupMessage("Plain.", endsSession: false), "Plain.")
    }

    func testClearHistoryOnHCTerminalSaysHistoryReturns() {
        let fields = HCClearHistoryResult.fields(isHCTerminal: true)
        XCTAssertEqual(fields["history_durable"] as? Bool, false)
        XCTAssertEqual(fields["history_returns_after_restart"] as? Bool, true)
        let warning = fields["warning"] as? String ?? ""
        XCTAssertTrue(warning.contains("returns after c11 restarts or reconnects"), warning)
        XCTAssertTrue(HCClearHistoryResult.fields(isHCTerminal: false).isEmpty)
    }

    // MARK: C11H-46: never end a terminal another live panel shows

    private final class Holders: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        private(set) var asked: [HCTerminalKey] = []
        init(_ value: Bool?) { self.value = value }
        func set(_ value: Bool?) { lock.lock(); self.value = value; lock.unlock() }
        func ask(_ key: HCTerminalKey) -> HCHolderAnswer {
            lock.lock(); defer { lock.unlock() }; asked.append(key)
            switch value {
            case nil: return .unknown
            case false?: return .none
            case true?: return .held(HCExplicitEndCoordinatorTests.holder)
            }
        }
    }

    static let holder = HCEndHolder(panelID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, panelRef: "panel:12",
                                    title: "T-8 Review", workspaceID: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
                                    workspaceTitle: "Glass V2")

    /// C11H-103 root cause: a close removes its panel at once, and Recovered
    /// can reconcile before the coordinator's queue runs. The closing panel's
    /// id and key are pending from the moment the close is requested.
    func testAClosingPanelIsPendingBeforeTheCoordinatorQueueRuns() async {
        let session = HCEndFakeSession()
        session.scriptEnd(key, .confirmed(evidence(key)))
        let queue = DispatchQueue(label: "test.explicit-end")
        queue.suspend()
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), queue: queue)
        let panel = UUID()
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .panelClose)
        XCTAssertTrue(coordinator.pendingEndPanelIDs().contains(panel))
        XCTAssertTrue(coordinator.pendingEndKeys().contains(key))
        XCTAssertTrue(coordinator.isEndPending(panelID: panel))
        queue.resume()
        let result = await outcome(coordinator, panel)
        XCTAssertEqual(result, .ended)
        XCTAssertEqual(session.ends, [key])
        XCTAssertFalse(coordinator.pendingEndPanelIDs().contains(panel), "settled ends stop being pending")
    }

    /// C11H-103: the app's holder lookup names the live panel that shows the
    /// terminal (its ref, title and workspace), skips one being closed, and
    /// answers none when no live panel shows it.
    @MainActor
    func testTheHolderLookupNamesTheLivePanelThatShowsTheTerminal() throws {
        let workspace = Workspace()
        workspace.setCustomTitle("Glass V2")
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t2v")
        HCPanelRestoreState.shared.seed(HCPanelIdentity(panelID: panel, key: key, origin: .restored))
        defer { HCPanelRestoreState.shared.remove(panelID: panel) }
        workspace.setPanelCustomTitle(panelId: panel, title: "T-8 Review")
        let answer = Workspace.hcHolder(of: key, in: [workspace]) { $0 == panel ? "panel:12" : nil }
        XCTAssertEqual(answer, .held(HCEndHolder(panelID: panel, panelRef: "panel:12", title: "T-8 Review",
                                                 workspaceID: workspace.id, workspaceTitle: "Glass V2")))
        XCTAssertEqual(Workspace.hcHolder(of: HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t9"),
                                          in: [workspace]) { _ in nil }, .none)
        (workspace.panels[panel] as? TerminalPanel)?.hcClosingForEnd = true
        XCTAssertEqual(Workspace.hcHolder(of: key, in: [workspace]) { _ in nil }, .none,
                       "a panel being closed is not a holder")
    }

    /// C11H-103: the refusal names the other panel: its ref, title and
    /// workspace, in the CLI line and in `panel.end_status`'s `held_by`.
    func testTheKeptMessageNamesThePanelThatStillShowsTheTerminal() {
        let panel = UUID()
        let row = HCSessionEnd.wireOutcomes(panelIds: [panel], outcomes: [panel: .kept(Self.holder)]).first
        XCTAssertEqual(row?["outcome"] as? String, "kept")
        XCTAssertEqual(row?["message"] as? String,
            "Session kept: panel panel:12 (\u{201C}T-8 Review\u{201D}) in workspace \u{201C}Glass V2\u{201D} still shows this terminal, so it was not ended.")
        let heldBy = row?["held_by"] as? [String: Any]
        XCTAssertEqual(heldBy?["panel_id"] as? String, Self.holder.panelID.uuidString)
        XCTAssertEqual(heldBy?["panel_ref"] as? String, "panel:12")
        XCTAssertEqual(heldBy?["title"] as? String, "T-8 Review")
        XCTAssertEqual(heldBy?["workspace_id"] as? String, Self.holder.workspaceID.uuidString)
        XCTAssertEqual(heldBy?["workspace_title"] as? String, "Glass V2")
        let unnamed = HCSessionEnd.wireOutcomes(panelIds: [panel], outcomes: [panel: .kept(nil)]).first
        XCTAssertNil(unnamed?["held_by"])
    }

    /// Closing the Workspace 1 copy while its Recovered twin still shows
    /// studio/t1: the close detaches, the terminal is not killed.
    func testACloseNeverEndsATerminalAnotherLivePanelShows() async {
        let session = HCEndFakeSession()
        session.scriptEnd(key, .confirmed(evidence(key)))
        let holders = Holders(true)
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(),
            heldElsewhere: { holders.ask($0) })
        let panel = UUID()

        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .panelClose)

        let result = await outcome(coordinator, panel)
        XCTAssertEqual(result, .kept(Self.holder))
        XCTAssertTrue(session.ends.isEmpty, "no terminal.kill reached hc")
        XCTAssertEqual(holders.asked, [key])
        XCTAssertFalse(coordinator.isEndPending(panelID: panel), "a refusal is settled, not retried")
    }

    /// A keyless close resolves first, then asks about the key it resolved.
    func testTheBackstopAsksAboutTheResolvedKey() async {
        let session = HCEndFakeSession()
        let panel = UUID()
        session.scriptResolve(panel, .live(HCTerminalRecord(key: key, state: .running)))
        let holders = Holders(true)
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(),
            heldElsewhere: { holders.ask($0) })

        coordinator.requestEnd([HCPanelIdentity(panelID: panel)], origin: .areaClose)

        let result = await outcome(coordinator, panel)
        XCTAssertEqual(result, .kept(Self.holder))
        XCTAssertTrue(session.ends.isEmpty)
    }

    /// Until the app can tell (its panels not restored yet), an owed end waits.
    func testAnEndWaitsWhileTheAppCannotTellAndEndsOnceItCan() async {
        let session = HCEndFakeSession()
        session.scriptEnd(key, .confirmed(evidence(key)))
        let holders = Holders(nil)
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(),
            heldElsewhere: { holders.ask($0) })
        let panel = UUID()

        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .panelClose)
        let early = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(early, .pending(.inventoryPending))
        XCTAssertTrue(session.ends.isEmpty)

        // A quiet inventory: no new revision ever comes. The app's graph
        // completing wakes the owed end by itself (sol review 1, item 3).
        holders.set(false)
        coordinator.holdersChanged()
        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.ends, [key])
    }

    /// Setting the app's holder lookup is what wakes them in production.
    @MainActor
    func testInstallingTheHolderLookupWakesDeferredEnds() async {
        let session = HCEndFakeSession()
        session.scriptEnd(key, .confirmed(evidence(key)))
        HCSessionEnd.keyShownByLivePanel = { _ in .unknown }
        HCSessionEnd.install(session: session, store: HCEndMemoryStore())
        defer {
            HCSessionEnd.keyShownByLivePanel = { _ in .unknown }
            HCSessionEnd.resetForTesting()
        }
        let panel = UUID()
        guard let coordinator = HCSessionEnd.coordinator else { return XCTFail("no coordinator") }
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .panelClose)
        let early = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(early, .pending(.inventoryPending))
        XCTAssertTrue(session.ends.isEmpty)

        HCSessionEnd.keyShownByLivePanel = { _ in .none }
        let final = await outcome(coordinator, panel)
        XCTAssertEqual(final, .ended)
        XCTAssertEqual(session.ends, [key])
    }

    /// With no other holder, the close ends its terminal as before. End All
    /// ends every terminal by design and never asks.
    func testNoOtherHolderEndsAndEndAllNeverAsks() async {
        let session = HCEndFakeSession()
        let other = HCTerminalKey(owningCoreID: "core-1", localAddress: "t8")
        session.scriptEnd(key, .confirmed(evidence(key)))
        session.scriptEnd(other, .confirmed(evidence(other)))
        let free = Holders(false)
        let closing = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), heldElsewhere: { free.ask($0) })
        let panel = UUID()
        closing.requestEnd([HCPanelIdentity(panelID: panel, key: key)], origin: .workspaceClose)
        let closed = await outcome(closing, panel)
        XCTAssertEqual(closed, .ended)

        let held = Holders(true)
        let endAll = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), heldElsewhere: { held.ask($0) })
        let retained = UUID()
        endAll.requestEnd([HCPanelIdentity(panelID: retained, key: other)], origin: .endAll)
        let ended = await outcome(endAll, retained)
        XCTAssertEqual(ended, .ended)
        XCTAssertTrue(held.asked.isEmpty)
        XCTAssertEqual(session.ends, [key, other])
    }

    func testKeptOutcomeSaysTheTerminalWasNotEnded() {
        let panel = UUID()
        let kept = HCSessionEnd.wireOutcomes(panelIds: [panel], outcomes: [panel: .kept(nil)])
        XCTAssertEqual(kept.first?["outcome"] as? String, "kept")
        XCTAssertTrue((kept.first?["message"] as? String ?? "").contains("another panel"))
        XCTAssertTrue(HCPanelEndOutcome.kept(nil).isSettled)
    }

    // MARK: C11H-46: which panels count as holders

    func testAPanelBeingClosedOrEndedIsNotAHolder() {
        let live = HCLifecycle.live(HCTerminalRecord(key: key, state: .running))
        XCTAssertTrue(HCLiveBinding.shows(key, boundKeys: [key], lifecycle: live, closing: false))
        XCTAssertFalse(HCLiveBinding.shows(key, boundKeys: [key], lifecycle: live, closing: true))
        XCTAssertFalse(HCLiveBinding.shows(key, boundKeys: [key], lifecycle: .ended(evidence(key)), closing: false))
        XCTAssertFalse(HCLiveBinding.shows(key, boundKeys: [], lifecycle: live, closing: false))
    }

    /// A panel whose session has not registered still holds the key restore
    /// seeded for it, and a live record's key counts too.
    func testBoundKeysIncludeTheRestoredAndTheLiveKey() {
        let restored = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t1")
        XCTAssertEqual(HCLiveBinding.boundKeys(identityKey: nil, lifecycle: nil, restoredKey: restored), [restored])
        XCTAssertEqual(HCLiveBinding.boundKeys(identityKey: nil,
            lifecycle: .live(HCTerminalRecord(key: key, state: .running)), restoredKey: nil), [key])
        XCTAssertEqual(HCLiveBinding.boundKeys(identityKey: key, lifecycle: .new, restoredKey: restored), [key, restored])
    }

    // MARK: - C11H-313: the creation channel

    /// A close declines its panel's creations before `requestEnd` returns, so
    /// the decline lands ahead of the teardown's cancel in the same turn: every
    /// creation under way for the panel, and the one the identity carries.
    func testACloseDeclinesItsPanelsCreationsBeforeRequestEndReturns() {
        let session = HCSettlingFakeSession()
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        let (fresh, keyed, creation) = (UUID(), UUID(), UUID())
        coordinator.requestEnd([HCPanelIdentity(panelID: fresh, creationID: creation, origin: .fresh),
                                HCPanelIdentity(panelID: keyed, key: key)], origin: .panelClose)
        XCTAssertEqual(session.declined.map(\.panel), [fresh, keyed], "every closing panel, at once")
        XCTAssertEqual(session.declined.map(\.creation), [creation, nil])
    }

    /// Repair 1 (Astra 1): a replacement's close carries the old key. When the
    /// replacement is recorded never run over that key's recorded end, the end
    /// settles from durable state without asking hc for the old key, which a
    /// catch-up, a lost core or a dropped record would keep from answering.
    func testAReplacementRecordedNeverRunSettlesWithoutLookingUpTheOldKey() async {
        let session = HCSettlingFakeSession()
        let panel = UUID(), replacement = UUID()
        let closing = HCPanelIdentity(panelID: panel, key: key, creationID: replacement, origin: .fresh)
        session.recordNeverRun(closing, rejected(replacement))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        coordinator.requestEnd([closing], origin: .panelClose)
        let result = await outcome(coordinator, panel, timeout: 1)
        XCTAssertEqual(result, .ended)
        XCTAssertTrue(session.inner.ends.isEmpty, "the old key needed no lookup")
    }

    /// A decline of a creation still under way is never pushed out by later
    /// closes; only declines of creations not yet started are bounded.
    func testADeclineOfACreationUnderWayOutlastsAnyNumberOfLaterCloses() {
        let settlements = HCCreationSettlements()
        let (panel, held) = (UUID(), UUID())
        settlements.begin(held, panelID: panel)
        settlements.decline(panelID: panel, carrying: nil)
        for _ in 0...HCCreationSettlements.declineMemory { settlements.decline(panelID: UUID(), carrying: UUID()) }
        XCTAssertTrue(settlements.isDeclined(held), "a held preparation must still decline")
        let ahead = UUID()
        settlements.decline(panelID: UUID(), carrying: ahead)
        settlements.begin(ahead, panelID: UUID())
        for _ in 0...HCCreationSettlements.declineMemory { settlements.decline(panelID: UUID(), carrying: UUID()) }
        XCTAssertTrue(settlements.isDeclined(ahead), "declined before it started, then under way: kept")
        settlements.end(held)
        XCTAssertFalse(settlements.isDeclined(held), "an ended creation's decline is let go")
    }

    /// A creation recorded as never run produces no hc event: its settlement
    /// alone retries the pending end, with no new inventory revision.
    func testANoRunSettlementWakesAPendingEndWithoutARevision() async {
        let session = HCSettlingFakeSession()
        let panel = UUID(), creation = UUID()
        let closing = HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)
        session.inner.scriptResolve(panel, .unresolved(closing, .creationPending), .ended(rejected(creation)))
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        coordinator.requestEnd([closing], origin: .panelClose)
        await eventually { session.inner.resolves.count == 1 }
        let waiting = await outcome(coordinator, panel, timeout: 0.2)
        XCTAssertEqual(waiting, .pending(.creationPending))
        session.settle(panel)
        let result = await outcome(coordinator, panel, timeout: 1)
        XCTAssertEqual(result, .alreadyEnded)
        XCTAssertFalse(coordinator.isEndPending(panelID: panel))
    }

    /// A settlement that arrives while the end's attempt is still looking
    /// retries as that attempt completes, rather than waiting for a revision.
    func testASettlementDuringAnAttemptRetriesWhenItCompletes() async {
        let session = HCSettlingFakeSession()
        let panel = UUID(), creation = UUID()
        let closing = HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)
        session.inner.scriptResolve(panel, .unresolved(closing, .creationPending), .ended(rejected(creation)))
        session.holdResolves()
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore())
        coordinator.requestEnd([closing], origin: .panelClose)
        await eventually { session.heldResolves == 1 }
        XCTAssertEqual(session.heldResolves, 1, "the first attempt must be in flight")
        session.settle(panel)
        try? await Task.sleep(nanoseconds: 50_000_000)
        session.releaseResolves()
        let result = await outcome(coordinator, panel, timeout: 1)
        XCTAssertEqual(result, .alreadyEnded)
        XCTAssertEqual(session.inner.resolves.count, 2)
    }

    /// C11H-329: an end loaded from the store over a session that is already
    /// ready is attempted by the feed's first delivery, before the rest of the
    /// coordinator's setup runs. A no-run settlement published while that
    /// attempt looks still retries the end: the coordinator subscribes to
    /// settlements before the feed, so none falls between the two.
    func testASettlementDuringALoadedEndsFirstAttemptIsNotLost() async {
        let session = HCSettlingFakeSession()
        let panel = UUID(), creation = UUID()
        let closing = HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)
        session.inner.scriptResolve(panel, .unresolved(closing, .creationPending), .ended(rejected(creation)))
        session.deliverReadyThenHoldQueue()
        defer { session.releaseQueue() }
        let coordinator = HCExplicitEndCoordinator(
            session: session, store: HCEndMemoryStore([HCPendingEndRecord(identity: closing, key: nil, origin: .panelClose)]))
        await eventually { session.inner.resolves.count == 1 }
        XCTAssertEqual(session.inner.resolves.count, 1, "the first delivery must have attempted the loaded end")
        session.settle(panel)
        session.releaseQueue()
        let result = await outcome(coordinator, panel, timeout: 1)
        XCTAssertEqual(result, .alreadyEnded, "the settlement was lost")
        XCTAssertEqual(session.inner.resolves.count, 2)
    }

    private func rejected(_ creation: UUID) -> HCEndEvidence {
        HCEndEvidence(id: UUID(), creationID: creation, revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .createRejected)
    }

    func testWireOutcomesCarryMessagesAndReasons() {
        let ended = UUID()
        let pending = UUID()
        let rows = HCSessionEnd.wireOutcomes(
            panelIds: [ended, pending],
            outcomes: [ended: .ended, pending: .pending(.connectionLost)]
        )
        XCTAssertEqual(rows.map { $0["outcome"] as? String }, ["ended", "pending"])
        XCTAssertEqual(rows[1]["reason"] as? String, "connectionLost")
        XCTAssertTrue((rows[0]["message"] as? String ?? "").contains("nohup"))
        XCTAssertTrue((rows[1]["message"] as? String ?? "").contains("not yet confirmed"))
    }
}

/// C11H-313: a session with the creation channel. It records declines,
/// publishes a no-run settlement on demand, and can hold resolves in flight.
private final class HCSettlingFakeSession: HCSession, HCCreationSettling, @unchecked Sendable {
    let inner = HCEndFakeSession()
    private let lock = NSLock()
    private var declinedIDs: [(panel: UUID, creation: UUID?)] = []
    private var neverRun: [UUID: (identity: HCPanelIdentity, proof: HCEndEvidence)] = [:]
    private let settlements = HCCreationSettlements()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldCount = 0
    private var queueHold: DispatchSemaphore?

    var declined: [(panel: UUID, creation: UUID?)] { lock.lock(); defer { lock.unlock() }; return declinedIDs }
    /// What `recordedNeverRun` answers for exactly this identity.
    func recordNeverRun(_ identity: HCPanelIdentity, _ proof: HCEndEvidence) {
        lock.lock(); neverRun[identity.panelID] = (identity, proof); lock.unlock()
    }
    var heldResolves: Int { lock.lock(); defer { lock.unlock() }; return heldCount }
    func settle(_ panelID: UUID) { settlements.publish(panelID: panelID) }
    func holdResolves() { lock.lock(); holding = true; lock.unlock() }
    func releaseResolves() {
        lock.lock(); holding = false; let waiting = held; held.removeAll(); lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    func declineCreations(panelID: UUID, carrying creationID: UUID?) {
        lock.lock(); declinedIDs.append((panelID, creationID)); lock.unlock()
    }
    func recordedNeverRun(_ identity: HCPanelIdentity) async -> HCEndEvidence? {
        lock.lock(); defer { lock.unlock() }
        guard let recorded = neverRun[identity.panelID], recorded.identity == identity else { return nil }
        return recorded.proof
    }
    func observeCreationSettlements(on queue: DispatchQueue, handler: @escaping @Sendable (UUID) -> Void) -> HCObservation {
        settlements.observe(on: queue, handler: handler)
    }

    /// C11H-329: the next subscriber gets a ready snapshot at once, as the
    /// session feed delivers its current one, and its queue is then held
    /// until `releaseQueue()`.
    func deliverReadyThenHoldQueue() { lock.lock(); queueHold = DispatchSemaphore(value: 0); lock.unlock() }
    func releaseQueue() { lock.lock(); let hold = queueHold; queueHold = nil; lock.unlock(); hold?.signal() }

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        lock.lock(); let hold = queueHold; lock.unlock()
        if let hold {
            let revision = HCRevision(connectionGeneration: 1, sequence: 1)
            queue.async { handler(HCInventorySnapshot(readiness: .ready(revision), revision: revision)) }
            queue.async { _ = hold.wait(timeout: .now() + 5) }
        }
        return inner.observe(on: queue, handler: handler)
    }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if holding { heldCount += 1; held.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
        return await inner.resolve(identity)
    }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { await inner.create(request) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        try await inner.attach(key, sink: sink, display: display)
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { await inner.end(key) }
    func diagnostics() async -> HCDiagnostics { await inner.diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { await inner.recoverSession(reason: reason) }
}

/// C11H-309: the panel bar's Close Others, Close to the Left and Close to the
/// Right over hc terminals ask once for the whole batch, naming how many
/// sessions end, then close it as one lineage batch, through the Area menu's
/// path. Before, each hc terminal scheduled its own confirm card and closed on
/// its own, outside the batch. (c11's simplified panel menu omits these three;
/// the Area menu's Close Other Panels is the operator's path and is tested last.)
@MainActor
final class HCBatchCloseTests: XCTestCase {
    private var session: HCEndFakeSession!
    private var coordinator: HCExplicitEndCoordinator!
    private var batches: [Set<UUID>] = []
    private var prompts: [(title: String, message: String)] = []
    private var observer: UUID?

    override func setUp() {
        super.setUp()
        // Constructing a WorkspaceManager reaches Ghostty setup that reads NSApp.
        _ = NSApplication.shared
        session = HCEndFakeSession()
        // These panels are the only holders of their terminals.
        HCSessionEnd.keyShownByLivePanel = { _ in .none }
        HCSessionEnd.install(session: session, store: HCEndMemoryStore())
        coordinator = HCSessionEnd.coordinator
        batches = []
        prompts = []
        observer = PanelLineage.shared.addPanelClosedForGoodObserver { [weak self] ids in
            self?.batches.append(ids)
        }
    }

    override func tearDown() {
        if let observer { PanelLineage.shared.removePanelClosedForGoodObserver(observer) }
        observer = nil
        HCSessionEnd.keyShownByLivePanel = { _ in .unknown }
        HCSessionEnd.resetForTesting()
        coordinator = nil
        session = nil
        super.tearDown()
    }

    /// One workspace whose first area holds `count` hc terminals, in tab order.
    private func area(of count: Int) throws -> (WorkspaceManager, Workspace, PaneID, [TerminalPanel]) {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        for _ in 1..<count {
            XCTAssertNotNil(workspace.newTerminalSurface(inPane: pane, focus: false))
        }
        let terminals = try workspace.bonsplitController.tabs(inPane: pane).map { tab in
            try XCTUnwrap(workspace.tabIdFromBonsplitTabId(tab.id).flatMap { workspace.terminalPanel(for: $0) })
        }
        XCTAssertEqual(terminals.count, count)
        for terminal in terminals {
            terminal.surface.usePersistentHCForTesting(session: session)
            XCTAssertTrue(workspace.panelAsksBeforeClose(terminal.id), "an hc terminal asks before it closes alone")
        }
        return (manager, workspace, pane, terminals)
    }

    private func answer(_ manager: WorkspaceManager, _ result: Bool) {
        manager.confirmCloseHandler = { [weak self] title, message, _ in
            self?.prompts.append((title, message))
            return result
        }
    }

    private func act(_ action: TabContextAction, on panel: TerminalPanel, in workspace: Workspace, pane: PaneID) throws {
        let tabId = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(panel.id))
        let tab = try XCTUnwrap(workspace.bonsplitController.tabs(inPane: pane).first { $0.id == tabId })
        workspace.splitTabBar(workspace.bonsplitController, didRequestTabContextAction: action, for: tab, inPane: pane)
    }

    /// A per-panel card would be scheduled on the main queue; give one the
    /// chance to appear before asserting that nothing else asked or closed.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testCloseOthersOverHCTerminalsAsksOnceAndClosesThemAsOneBatch() throws {
        let (manager, workspace, pane, terminals) = try area(of: 3)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let anchor = terminals[1]
        let closing = [terminals[0].id, terminals[2].id]
        answer(manager, true)

        try act(.closeOthers, on: anchor, in: workspace, pane: pane)

        XCTAssertEqual(prompts.count, 1, "one card for the whole batch")
        XCTAssertEqual(prompts.first?.title, "Close other panels?")
        XCTAssertTrue(prompts.first?.message.contains("This closes 2 panels in this area:") ?? false)
        XCTAssertTrue(prompts.first?.message.contains("This ends 2 terminal sessions") ?? false,
                      "the card names how many sessions end")
        for id in closing {
            XCTAssertNil(workspace.panels[id], "confirmed: closed at once")
            XCTAssertTrue(coordinator.isEndPending(panelID: id), "confirmed: its session ends")
        }
        XCTAssertNotNil(workspace.panels[anchor.id])
        XCTAssertFalse(coordinator.isEndPending(panelID: anchor.id))
        XCTAssertEqual(batches, [Set(closing)], "one close batch")
        settle()
        XCTAssertEqual(prompts.count, 1, "one ask")
        for terminal in terminals {
            XCTAssertFalse(workspace.paneInteractionRuntime.hasActiveConfirm(panelId: terminal.id),
                           "no per-panel card followed")
        }
    }

    func testDecliningTheBatchCardClosesAndEndsNothing() throws {
        let (manager, workspace, pane, terminals) = try area(of: 3)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        answer(manager, false)

        try act(.closeOthers, on: terminals[0], in: workspace, pane: pane)
        settle()

        XCTAssertEqual(prompts.count, 1)
        for terminal in terminals {
            XCTAssertNotNil(workspace.panels[terminal.id])
            XCTAssertFalse(coordinator.isEndPending(panelID: terminal.id))
        }
        XCTAssertEqual(batches, [])
    }

    func testCloseToTheLeftAndRightCloseOnlyTheirSideAndNeverAPinnedPanel() throws {
        let (manager, workspace, pane, terminals) = try area(of: 4)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let (first, pinned, anchor, last) = (terminals[0], terminals[1], terminals[2], terminals[3])
        workspace.setPanelPinned(panelId: pinned.id, pinned: true)
        answer(manager, true)

        try act(.closeToLeft, on: anchor, in: workspace, pane: pane)

        XCTAssertEqual(prompts.map(\.title), ["Close panels to the left?"])
        XCTAssertTrue(prompts.last?.message.contains("This closes 1 panel in this area:") ?? false)
        XCTAssertTrue(prompts.last?.message.contains("This ends 1 terminal session and") ?? false,
                      "the pinned terminal is neither closed nor counted")
        XCTAssertNil(workspace.panels[first.id])
        XCTAssertNotNil(workspace.panels[pinned.id])
        XCTAssertFalse(coordinator.isEndPending(panelID: pinned.id))
        XCTAssertNotNil(workspace.panels[last.id])

        try act(.closeToRight, on: anchor, in: workspace, pane: pane)

        XCTAssertEqual(prompts.map(\.title), ["Close panels to the left?", "Close panels to the right?"])
        XCTAssertNil(workspace.panels[last.id])
        XCTAssertNotNil(workspace.panels[anchor.id])
        XCTAssertEqual(batches, [[first.id], [last.id]])
        settle()
        XCTAssertEqual(prompts.count, 2)
    }

    /// Nothing in the batch would ask on its own: it closes at once, as before.
    func testCloseOthersOverIdleExecShellsClosesWithoutAsking() throws {
        let manager = WorkspaceManager()
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let anchor = try XCTUnwrap(workspace.focusedTerminalPanel)
        let other = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        for terminal in [anchor, other] {
            terminal.surface.useExecShellForTesting()
            terminal.surface.setNeedsConfirmCloseOverrideForTesting(false)
            XCTAssertFalse(workspace.panelAsksBeforeClose(terminal.id))
        }
        answer(manager, false)

        try act(.closeOthers, on: anchor, in: workspace, pane: pane)

        XCTAssertEqual(prompts.count, 0)
        XCTAssertNil(workspace.panels[other.id])
        XCTAssertEqual(batches, [[other.id]])
    }

    /// The Area menu's Close Other Panels shares the path: one card, one batch.
    func testAreaMenuCloseOtherPanelsClosesAsOneBatch() throws {
        let (manager, workspace, _, terminals) = try area(of: 3)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let anchor = try XCTUnwrap(workspace.focusedPanelId)
        let closing = Set(terminals.map(\.id).filter { $0 != anchor })
        XCTAssertEqual(closing.count, 2)
        answer(manager, true)

        manager.closeOtherPanelsInFocusedPaneWithConfirmation()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.first?.message.contains("This ends 2 terminal sessions") ?? false)
        XCTAssertEqual(batches, [closing])
        XCTAssertNotNil(workspace.panels[anchor])
    }
    /// The Area menu asks every time, even when nothing in the batch would ask alone.
    func testAreaMenuAsksOnceOverIdleExecShells() throws {
        let manager = WorkspaceManager()
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let anchor = try XCTUnwrap(workspace.focusedTerminalPanel)
        let other = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        for terminal in [anchor, other] {
            terminal.surface.useExecShellForTesting()
            terminal.surface.setNeedsConfirmCloseOverrideForTesting(false)
            XCTAssertFalse(workspace.panelAsksBeforeClose(terminal.id))
        }
        answer(manager, true)

        manager.closeOtherPanelsInFocusedPaneWithConfirmation()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(prompts.first?.message.contains("terminal session") ?? true, "no session ends")
        XCTAssertNil(workspace.panels[other.id])
        XCTAssertNotNil(workspace.panels[anchor.id])
    }

    /// A target whose Bonsplit mapping drifted is skipped. `closePanel` would
    /// close the focused area's selected tab in its place, a panel the batch
    /// was never given.
    func testForceCloseSkipsADriftedPanelAndNeverClosesTheSelectedOne() throws {
        let (manager, workspace, _, terminals) = try area(of: 3)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let selected = try XCTUnwrap(workspace.focusedPanelId)
        let others = terminals.map(\.id).filter { $0 != selected }
        let (drifted, other) = (others[0], others[1])
        workspace.forgetBonsplitMappingForTesting(panelId: drifted)
        workspace.firstResponderPanelIdForTesting = drifted

        workspace.forceClosePanels([drifted, other])

        XCTAssertNotNil(workspace.panels[selected], "the selected panel was never asked for")
        XCTAssertNil(workspace.panels[other], "a mapped target still closes")
        XCTAssertEqual(batches, [[other]])
    }

    /// Two panels showing one terminal end one session: the card counts it
    /// once, and its button is singular.
    func testTwoPanelsShowingOneTerminalCountOneSession() throws {
        let manager = WorkspaceManager()
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let anchor = try XCTUnwrap(workspace.focusedTerminalPanel)
        let first = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let twin = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let shared = HCTerminalKey(owningCoreID: "core-test", localAddress: "shared")
        anchor.surface.usePersistentHCForTesting(session: session)
        first.surface.usePersistentHCForTesting(session: session, key: shared)
        twin.surface.usePersistentHCForTesting(session: session, key: shared)
        XCTAssertEqual(workspace.closeEndsHCSessionCount(panelIds: [first.id, twin.id]), 1)
        XCTAssertEqual(HCCloseCopy.batchConfirmLabel(sessionCount: 1), HCCloseCopy.panelConfirmLabel)
        XCTAssertEqual(HCCloseCopy.batchConfirmLabel(sessionCount: 2), HCCloseCopy.groupConfirmLabel)
        XCTAssertNil(HCCloseCopy.batchConfirmLabel(sessionCount: 0))
        answer(manager, true)

        try act(.closeOthers, on: anchor, in: workspace, pane: pane)

        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.first?.message.contains("This closes 2 panels in this area:") ?? false)
        XCTAssertTrue(prompts.first?.message.contains("This ends 1 terminal session and") ?? false,
                      "one terminal, one session")
        XCTAssertNil(workspace.panels[first.id])
        XCTAssertNil(workspace.panels[twin.id])
    }
}
