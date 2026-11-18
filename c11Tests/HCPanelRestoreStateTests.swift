import XCTest
import AppKit
import Combine

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCPanelRestoreStateTests: XCTestCase {
    private let panelID = UUID()
    private let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t1")
    private let revision = HCRevision(connectionGeneration: 1, sequence: 10)

    private func record(_ key: HCTerminalKey, attempt: UUID? = nil) -> HCTerminalRecord {
        var labels = ["c11.panel": panelID.uuidString]
        if let attempt { labels["c11.creation"] = attempt.uuidString }
        return HCTerminalRecord(key: key, state: .running, labels: labels, pid: 123)
    }

    func testSurvivingAttachedOrHiddenTerminalNeverPermitsResume() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key))
        state.receive(.live(record(key)))
        XCTAssertFalse(state.permitsConversationResume)
        XCTAssertEqual(state.snapshotIdentity.key, key)
        state.receive(.unresolved(HCPanelIdentity(panelID: panelID), .coreUnreachable))
        XCTAssertEqual(state.snapshotIdentity.key, key)
        XCTAssertFalse(state.permitsConversationResume)
        XCTAssertFalse(state.willCreate(UUID()))
        state.receive(.live(record(key)))
        XCTAssertFalse(state.permitsConversationResume)
    }

    func testFailedOrSlowLookupRetainsIdentityAndCannotCreate() {
        let attempt = UUID()
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key, creationID: attempt))
        for reason in [HCUnavailableReason.inventoryPending, .connectionLost, .deadlineExceeded, .creationUncertain] {
            state.receive(.unresolved(HCPanelIdentity(panelID: panelID), reason))
            XCTAssertEqual(state.snapshotIdentity.key, key)
            XCTAssertEqual(state.snapshotIdentity.creationID, attempt)
            XCTAssertFalse(state.willCreate(UUID()))
            XCTAssertFalse(state.permitsConversationResume)
        }
        state.receive(.new)
        XCTAssertFalse(state.willCreate(UUID()), "an existing identity cannot become new")
        XCTAssertEqual(state.snapshotIdentity.key, key)
    }

    func testEndedReplacementCanResumeOnlyAfterItsOwnLiveCreation() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key))
        let proof = HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .finished, hcReason: "holder_lost")
        state.receive(.ended(proof))
        XCTAssertFalse(state.permitsConversationResume)
        let attempt = UUID()
        XCTAssertTrue(state.willCreate(attempt))
        XCTAssertFalse(state.willCreate(UUID()), "an unresolved creation never admits a second request")
        let replacement = HCTerminalKey(owningCoreID: "owned", localAddress: "t2")
        state.didCreate(.bound(record(replacement, attempt: attempt)), creationID: attempt)
        XCTAssertEqual(state.snapshotIdentity.key, replacement)
        XCTAssertTrue(state.permitsConversationResume)
        state.receive(.unresolved(state.identity, .connectionLost))
        XCTAssertFalse(state.permitsConversationResume)
        state.receive(.live(record(replacement, attempt: attempt)))
        XCTAssertTrue(state.permitsConversationResume)
    }

    func testLostReplacementReplyReconcilesItsAttemptWithoutAnotherCreate() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key))
        state.receive(.ended(HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .observedRemoval)))
        let attempt = UUID()
        XCTAssertTrue(state.willCreate(attempt))
        state.didCreate(.unresolved(state.identity, .connectionLost), creationID: attempt)
        XCTAssertFalse(state.willCreate(UUID()))
        let replacement = HCTerminalKey(owningCoreID: "owned", localAddress: "t2")
        state.receive(.live(record(replacement, attempt: UUID())))
        XCTAssertEqual(state.identity.key, key, "a superseded attempt cannot take the panel")
        XCTAssertFalse(state.permitsConversationResume)
        state.receive(.live(record(replacement, attempt: attempt)))
        XCTAssertEqual(state.identity.key, replacement)
        XCTAssertTrue(state.permitsConversationResume)
    }

    func testSavedNewWithPendingIntentWaitsAndSerializesAsRestored() throws {
        let attempt = UUID()
        let original = HCPanelIdentity(panelID: panelID, creationID: attempt, origin: .fresh)
        var state = HCRestoreLifecycleProjection(identity: original)
        state.receive(.unresolved(original, .creationPending))
        XCTAssertFalse(state.willCreate(UUID()))
        state.receive(.live(record(key, attempt: attempt)))
        XCTAssertEqual(state.identity.key, key)
        XCTAssertFalse(state.permitsConversationResume)
        let decoded = try JSONDecoder().decode(HCPanelIdentity.self, from: JSONEncoder().encode(state.snapshotIdentity))
        XCTAssertEqual(decoded.origin, .restored)
        XCTAssertEqual(decoded.key, key)
        XCTAssertEqual(decoded.creationID, attempt)
    }

    func testUnidentifiedProofAndLateCreateReplyCannotReplaceIdentity() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key))
        let foreign = HCTerminalKey(owningCoreID: "default", localAddress: "t1")
        state.receive(.ended(HCEndEvidence(id: UUID(), revision: revision, kind: .finished)))
        XCTAssertFalse(state.willCreate(UUID()))
        let attempt = UUID()
        state.didCreate(.bound(record(foreign, attempt: attempt)), creationID: attempt)
        XCTAssertEqual(state.identity.key, key)
        XCTAssertFalse(state.permitsConversationResume)
    }

    func testNewerDurableBindingAfterRestartUpdatesOldSavedKeyWithoutResume() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key))
        let survivingReplacement = HCTerminalKey(owningCoreID: "owned", localAddress: "t2")
        state.receive(.live(record(survivingReplacement, attempt: UUID())))
        XCTAssertEqual(state.identity.key, survivingReplacement)
        XCTAssertFalse(state.permitsConversationResume, "the session's durable intent already created it before this launch")
    }

    func testKeylessRestoreAcceptsSessionEndEvidenceBeforeReplacement() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID))
        state.receive(.ended(HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .finished)))
        XCTAssertEqual(state.identity.key, key)
        XCTAssertTrue(state.willCreate(UUID()))
        XCTAssertFalse(state.permitsConversationResume)
    }

    func testNewCreationDoesNotMasqueradeAsEndedReplacement() {
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, origin: .fresh))
        state.receive(.new)
        let attempt = UUID()
        XCTAssertTrue(state.willCreate(attempt))
        state.didCreate(.bound(record(key, attempt: attempt)), creationID: attempt)
        XCTAssertEqual(state.identity.key, key)
        XCTAssertFalse(state.permitsConversationResume)
    }

    func testPersistentSnapshotNeverCapturesOrReplaysAndKeepsUnresolvedIdentity() throws {
        let identity = HCPanelIdentity(panelID: panelID, key: key, creationID: UUID(), origin: .fresh)
        var captureCount = 0
        let captured = SessionTerminalPanelSnapshot.capture(workingDirectory: "/fixture", hcIdentity: identity) {
            captureCount += 1
            return "unique-history-marker"
        }
        XCTAssertEqual(captureCount, 0)
        XCTAssertNil(captured.scrollback)
        XCTAssertEqual(captured.hcIdentity?.key, key)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: JSONEncoder().encode(captured))
        XCTAssertEqual(try decoded.restoredHCIdentity(panelID: panelID, backendActive: true)?.origin, .restored)
        XCTAssertEqual(decoded.hcIdentity?.creationID, identity.creationID)
        var legacyHC = captured
        legacyHC.scrollback = "old-captured-history"
        XCTAssertNil(legacyHC.replayableScrollback)
    }

    func testLegacyAndNonpersistentHistoryRemainUsable() throws {
        let oldJSON = Data(#"{"workingDirectory":"/fixture","scrollback":"legacy"}"#.utf8)
        let legacy = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: oldJSON)
        XCTAssertNil(try legacy.restoredHCIdentity(panelID: panelID, backendActive: false))
        XCTAssertEqual(try legacy.restoredHCIdentity(panelID: panelID, backendActive: true)?.origin, .restored)
        XCTAssertEqual(legacy.replayableScrollback, "legacy")
        var captureCount = 0
        let fallback = SessionTerminalPanelSnapshot.capture(workingDirectory: nil,
            hcIdentity: HCPanelIdentity(panelID: panelID, persistence: .nonpersistent)) {
            captureCount += 1
            return "fallback"
        }
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(fallback.replayableScrollback, "fallback")
    }

    func testMismatchedPersistedIdentityCannotAttachAnotherPanelsTerminal() {
        let snapshot = SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil,
            hcIdentity: HCPanelIdentity(panelID: UUID(), key: key))
        XCTAssertThrowsError(try snapshot.restoredHCIdentity(panelID: panelID, backendActive: true))
    }

    @MainActor
    func testRuntimeObservationFollowsLifecycleButRejectsRetiredGraphCallbacks() {
        let store = HCRestoreLifecycleStore()
        let identity = HCPanelIdentity(panelID: panelID, key: key)
        let old = HCPanelSession(identity: identity, session: HCUnavailableRuntime(), registrar: { _, _ in })
        old.diagnosticSink = { _ in }
        store.observe(old)
        old.publish(.live(record(key)))
        XCTAssertFalse(store.permitsResume(old))
        old.publish(.ended(HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .finished)))
        let attempt = UUID()
        store.willCreate(attempt, in: old)
        let replacement = HCTerminalKey(owningCoreID: "owned", localAddress: "replacement")
        old.publish(.live(record(key))) // an old-key publication during creation
        store.didCreate(.bound(record(replacement, attempt: attempt)), creationID: attempt, in: old)
        XCTAssertFalse(store.permitsResume(old), "the runtime must publish the same live binding before input")
        old.publish(.live(record(replacement, attempt: attempt)))
        XCTAssertTrue(store.permitsResume(old))
        old.publish(.unresolved(identity, .connectionLost))
        XCTAssertFalse(store.permitsResume(old))

        let restored = HCPanelSession(identity: identity, session: HCUnavailableRuntime(), registrar: { _, _ in })
        restored.diagnosticSink = { _ in }
        store.observe(restored)
        let restoredEnd = HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .finished)
        restored.publish(.ended(restoredEnd))
        store.willCreate(attempt, replacing: restoredEnd, in: old)
        store.didCreate(.bound(record(replacement, attempt: attempt)), creationID: attempt, in: old)
        store.forget(old)
        restored.publish(.live(record(replacement, attempt: attempt)))
        XCTAssertFalse(store.permitsResume(restored),
            "retired callbacks cannot authorize the new UI graph's surviving replacement")
        store.forget(restored)
    }

    func testHolderLossExplainsTheEndAndWaitsForConfirmedReplacement() {
        let lost = HCLifecycle.ended(HCEndEvidence(id: UUID(), key: key, revision: revision,
            kind: .finished, hcReason: "holder_lost"))
        XCTAssertNotNil(HCRestoreLifecycleProjection.notice(for: lost))
        XCTAssertNil(HCRestoreLifecycleProjection.notice(for: .ended(HCEndEvidence(
            id: UUID(), key: key, revision: revision, kind: .finished, hcReason: "exited"))))
        var state = HCRestoreLifecycleProjection(identity: HCPanelIdentity(panelID: panelID, key: key))
        state.receive(lost)
        XCTAssertEqual(state.identity.panelID, panelID)
        XCTAssertEqual(state.identity.key, key)
        XCTAssertFalse(state.permitsConversationResume)
        let attempt = UUID()
        XCTAssertTrue(state.willCreate(attempt))
        XCTAssertFalse(state.permitsConversationResume)
        state.didCreate(.bound(record(HCTerminalKey(owningCoreID: "owned", localAddress: "fresh"),
            attempt: attempt)), creationID: attempt)
        XCTAssertTrue(state.permitsConversationResume)
    }

    func testResourceExhaustionIsVisibleUntilRuntimeRecovers() {
        let unavailable = HCLifecycle.unresolved(HCPanelIdentity(panelID: panelID), .fileDescriptorLimit)
        XCTAssertEqual(HCRestoreLifecycleProjection.notice(for: unavailable), .resourceExhausted)
        XCTAssertNil(HCRestoreLifecycleProjection.notice(for: .live(record(key)), retaining: .resourceExhausted))
        // C11H-196: a live terminal after a host end is its replacement; the
        // host-stopped notice no longer sits on a working panel.
        XCTAssertNil(HCRestoreLifecycleProjection.notice(for: .live(record(key)), retaining: .holderLost))
    }

    @MainActor
    func testCreationCallbackCarriesEndProofAcrossPendingPublication() {
        let identity = HCPanelIdentity(panelID: panelID, key: key)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        let store = HCRestoreLifecycleStore()
        store.observe(runtime)
        let proof = HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .finished, hcReason: "holder_lost")
        runtime.publish(.ended(proof))
        let attempt = UUID()
        runtime.publish(.unresolved(HCPanelIdentity(panelID: panelID, key: key, creationID: attempt), .creationPending))
        runtime.onWillCreate?(attempt, proof)
        let replacement = record(HCTerminalKey(owningCoreID: "owned", localAddress: "replacement"), attempt: attempt)
        runtime.onCreationOutcome?(attempt, .bound(replacement))
        XCTAssertFalse(store.permitsResume(runtime))
        runtime.publish(.live(replacement))
        XCTAssertTrue(store.permitsResume(runtime))
        store.forget(runtime)
    }


    @MainActor
    func testMigrationEndProjectsOnlyAProvenFreshResolutionAndSurvivesPendingRelaunch() throws {
        let id = UUID()
        defer { HCPanelRestoreState.shared.remove(panelID: id) }
        let proof = SessionTerminalPanelSnapshot.migrationEnd(panelID: id, endedKey: key)
        let snapshot = SessionTerminalPanelSnapshot(workingDirectory: "/fixture", hcMigrationEnd: proof)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: JSONEncoder().encode(snapshot))
        let identity = try XCTUnwrap(decoded.seedHCRestore(panelID: id, backendActive: true))
        XCTAssertNil(identity.key, "the dead core key is never an active identity")
        XCTAssertNil(identity.creationID)
        let runtime = HCPanelSession(identity: identity, session: HCUnavailableRuntime(), registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        let projection = HCRestoreLifecycleStore()
        projection.observe(runtime)
        runtime.publish(.unresolved(identity, .connectionLost))
        if case .unresolved = runtime.lifecycle {} else { XCTFail("uncertainty is not death") }
        runtime.publish(.new)
        XCTAssertEqual(HCRecoveryEndedProof.source(lifecycle: runtime.lifecycle, creation: nil),
                       .init(key: key, replacementStarted: false))
        XCTAssertNil(runtime.identity.key)
        XCTAssertFalse(projection.permitsResume(runtime))
        let attempt = UUID()
        let newKey = HCTerminalKey(owningCoreID: "new-core", localAddress: "new-terminal")
        let newIdentity = HCPanelIdentity(panelID: id, key: newKey, creationID: attempt, origin: .restored)
        let pending = SessionTerminalPanelSnapshot.capture(workingDirectory: "/fixture", hcIdentity: newIdentity,
            hcMigrationEnd: proof, scrollback: { nil })
        runtime.detachSurface()
        projection.forget(runtime)
        let reloaded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: JSONEncoder().encode(pending))
        let restored = try XCTUnwrap(reloaded.seedHCRestore(panelID: id, backendActive: true))
        let next = HCPanelSession(identity: restored, session: HCUnavailableRuntime(), registrar: { _, _ in })
        next.diagnosticSink = { _ in }
        let nextProjection = HCRestoreLifecycleStore()
        nextProjection.observe(next)
        next.publish(.unresolved(restored, .inventoryPending))
        XCTAssertFalse(nextProjection.permitsResume(next))
        let record = HCTerminalRecord(key: newKey, state: .running,
            labels: ["c11.panel": id.uuidString, "c11.creation": attempt.uuidString], pid: 123)
        next.publish(.live(record))
        XCTAssertTrue(nextProjection.permitsResume(next), "a pending fresh shell keeps replacement provenance across relaunch")
        XCTAssertEqual(HCRecoveryEndedProof.source(lifecycle: next.lifecycle,
            creation: HCPanelRestoreState.shared.entry(for: id)?.creation),
            .init(key: key, replacementStarted: true))
        XCTAssertFalse(HCConversationRecoveryPolicy.permitsDeadProcessRecovery(
            surfaceID: id.uuidString, savedPersistentPanels: [id]), "the replacement itself is alive")
        XCTAssertTrue(HCConversationRecoveryPolicy.permitsRecoveryCommit(
            surfaceID: id.uuidString, savedPersistentPanels: [id]), "the old conversation's audit may finish")
        let laterEnd = HCEndEvidence(id: UUID(), key: newKey, revision: revision,
                                     kind: .finished, hcReason: "holder_lost")
        HCPanelRestoreState.shared.recordCreation(panelID: id, creationID: UUID(), replacing: laterEnd)
        XCTAssertNil(HCPanelRestoreState.shared.entry(for: id)?.migrationEnd,
                     "a later terminal loss must not persist the original migration end as its source")
        next.detachSurface()
        nextProjection.forget(next)
    }

    func testMigrationEndIsStableAndCannotBeSeededIntoAnotherPanelOrAnActiveDeadKey() throws {
        let id = UUID()
        let proof = SessionTerminalPanelSnapshot.migrationEnd(panelID: id, endedKey: nil)
        XCTAssertEqual(proof, SessionTerminalPanelSnapshot.migrationEnd(panelID: id, endedKey: nil))
        let state = HCPanelRestoreState()
        let snapshot = SessionTerminalPanelSnapshot(hcMigrationEnd: proof)
        XCTAssertThrowsError(try snapshot.seedHCRestore(panelID: UUID(), backendActive: true, state: state))
        var invalid = snapshot
        invalid.hcIdentity = HCPanelIdentity(panelID: id, key: proof.key)
        XCTAssertThrowsError(try invalid.seedHCRestore(panelID: id, backendActive: true, state: state))
        invalid.hcIdentity = HCPanelIdentity(panelID: id, persistence: .nonpersistent)
        XCTAssertThrowsError(try invalid.seedHCRestore(panelID: id, backendActive: true, state: state))
        let restored = try XCTUnwrap(snapshot.seedHCRestore(panelID: id, backendActive: false, state: state))
        XCTAssertEqual(restored.persistence, .persistent, "a missing backend cannot turn migration into an exec fallback")
        XCTAssertNil(restored.key)
    }

    func testConvergenceLeavesNonpersistentFallbackIdentityAndHistoryUnchanged() throws {
        let id = UUID()
        for savedSession in [nil, "c11h-s3"] as [String?] { // c11-2.0:legacy (source-world fixture)
            let fallback = SessionTerminalPanelSnapshot(workingDirectory: "/fixture", scrollback: "saved fallback history",
                hcIdentity: HCPanelIdentity(panelID: id, persistence: .nonpersistent), hcSession: savedSession)
            let terminal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback))
            let bytes = try JSONSerialization.data(withJSONObject: ["panels": [["id": id.uuidString, "terminal": terminal]]])
            let (converted, count) = try C11MigrationExecutor.settleDeadTerminals(bytes, legacyBase: "c11h") // c11-2.0:legacy (source-world fixture)
            XCTAssertEqual(count, 0)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: converted) as? [String: Any])
            let panels = try XCTUnwrap(root["panels"] as? [[String: Any]])
            let savedTerminal = try XCTUnwrap(panels.first?["terminal"])
            let restored = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self,
                from: JSONSerialization.data(withJSONObject: savedTerminal))
            XCTAssertEqual(restored.hcIdentity, fallback.hcIdentity)
            XCTAssertEqual(restored.hcSession, savedSession)
            XCTAssertNil(restored.hcMigrationEnd)
            XCTAssertEqual(restored.replayableScrollback, fallback.scrollback)
            XCTAssertEqual(try restored.seedHCRestore(panelID: id, backendActive: true,
                state: HCPanelRestoreState())?.persistence, .nonpersistent)
        }
    }

    /// C11H-114: an entry leaves with its panel. A close for good keeps it
    /// through the close's own turn, where the end request may still read it,
    /// and drops it on the next. A move keeps it. A workspace teardown closes
    /// all its panels in one batch, and every entry in it leaves.
    @MainActor
    func testClosingForGoodDropsTheEntryAfterTheClosesTurnAndAMoveKeepsIt() {
        let state = HCPanelRestoreState()
        let lineage = PanelLineage()
        HCPanelRestoreState.installCloseObserver(lineage: lineage, state: state, diagnostics: { _ in })
        let (closed, sibling, moved, tornA, tornB) = (UUID(), UUID(), UUID(), UUID(), UUID())
        for id in [closed, sibling, moved, tornA, tornB] {
            state.seed(HCPanelIdentity(panelID: id, key: HCTerminalKey(owningCoreID: "owned", localAddress: id.uuidString)))
        }
        func nextMainTurn() {
            let turn = expectation(description: "next main turn")
            DispatchQueue.main.async { turn.fulfill() }
            wait(for: [turn], timeout: 5)
        }
        lineage.panelsClosedForGood([moved], isDetaching: true)
        lineage.panelsClosedForGood([closed])
        XCTAssertNotNil(state.entry(for: closed), "the close's end request can still read it")
        nextMainTurn()
        XCTAssertNil(state.entry(for: closed))
        XCTAssertNotNil(state.entry(for: sibling), "a sibling keeps its entry")
        XCTAssertNotNil(state.entry(for: moved), "a move is not a close")
        lineage.withCloseBatch { lineage.panelsClosedForGood([tornA]); lineage.panelsClosedForGood([tornB]) }
        nextMainTurn()
        XCTAssertNil(state.entry(for: tornA))
        XCTAssertNil(state.entry(for: tornB))
        XCTAssertEqual(Set(state.identities().map(\.panelID)), [sibling, moved])
    }
}

final class HCWorkspaceRestoreTests: XCTestCase {
    @MainActor
    func testExecFallbackClassificationSurvivesTheNextSnapshot() throws {
        _ = NSApplication.shared
        let id = UUID()
        let panel = SessionPanelSnapshot(id: id, type: .terminal, title: "Fallback", customTitle: nil,
            directory: "/fixture", isPinned: false, isManuallyUnread: false,
            gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/fixture", scrollback: nil,
                hcIdentity: HCPanelIdentity(panelID: id, persistence: .nonpersistent)),
            browser: nil, markdown: nil)
        let snapshot = SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil,
            customColor: nil, isPinned: false, currentDirectory: "/fixture", focusedPanelId: id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [id], selectedPanelId: id)),
            panels: [panel], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let workspace = Workspace(restoringSession: true)
        defer {
            workspace.retireForSessionRestore()
            HCPanelRestoreState.shared.remove(panelID: id)
        }
        workspace.restoreSessionSnapshot(snapshot)
        XCTAssertNil((workspace.panels[id] as? TerminalPanel)?.hcSession)
        let saved = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(saved.panels.first?.terminal?.hcIdentity?.persistence, .nonpersistent)
        XCTAssertEqual(saved.panels.first?.terminal?.hcIdentity?.panelID, id)
    }

    @MainActor
    func testHiddenRestoreKeepsIdentityWithoutPlaceholderHistoryOrResumeInput() async throws {
        _ = NSApplication.shared
        let ids = (0..<3).map { _ in UUID() }
        let records = ids.enumerated().map { index, id in
            HCTerminalRecord(key: HCTerminalKey(owningCoreID: "owned", localAddress: "t\(index)"),
                state: .running, labels: ["c11.panel": id.uuidString], pid: Int32(300 + index))
        }
        let snapshots = zip(ids, records).map { id, record in
            SessionPanelSnapshot(id: id, type: .terminal, title: "Fixture", customTitle: nil,
                directory: "/fixture", isPinned: false, isManuallyUnread: false,
                gitBranch: nil, listeningPorts: [], ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(workingDirectory: "/fixture", scrollback: "must-not-replay",
                    hcIdentity: HCPanelIdentity(panelID: id, key: record.key)),
                browser: nil, markdown: nil)
        }
        let snapshot = SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil,
            customColor: nil, isPinned: false, currentDirectory: "/fixture", focusedPanelId: ids[0],
            layout: .split(SessionSplitLayoutSnapshot(orientation: .horizontal, dividerPosition: 0.5,
                first: .pane(SessionAreaLayoutSnapshot(panelIds: [ids[0], ids[1]], selectedPanelId: ids[0])),
                second: .pane(SessionAreaLayoutSnapshot(panelIds: [ids[2]], selectedPanelId: ids[2])))),
            panels: snapshots, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let workspace = Workspace(restoringSession: true)
        defer {
            workspace.retireForSessionRestore()
            ids.forEach { HCPanelRestoreState.shared.remove(panelID: $0) }
        }
        XCTAssertTrue(workspace.panels.isEmpty, "restore must not create an unrelated terminal first")
        workspace.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(Set(workspace.panels.keys), Set(ids))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        for (id, record) in zip(ids, records) {
            let panel = try XCTUnwrap(workspace.panels[id] as? TerminalPanel)
            let runtime = try XCTUnwrap(panel.hcSession)
            XCTAssertEqual(panel.hcIdentity?.key, record.key)
            XCTAssertEqual(panel.hcIdentity?.origin, .restored)
            XCTAssertNil(panel.surface.surface, "the fixture is hidden and has no native surface")
            runtime.publish(.live(record))
            await workspace.executeResumeAction(.typeCommand(text: "forbidden-resume", submitWithReturn: true), on: id)
            XCTAssertEqual(panel.surface.pendingInitialInputForTests, "")
            XCTAssertFalse(panel.surface.pendingSubmitOnFlushForTests)
            XCTAssertNotEqual(workspace.launchResumeOutcomes[id], .resumed)
        }
        let saved = workspace.sessionSnapshot(includeScrollback: true)
        XCTAssertEqual(saved.panels.count, 3)
        for panel in saved.panels {
            XCTAssertEqual(panel.terminal?.hcIdentity?.key, records[ids.firstIndex(of: panel.id)!].key)
            XCTAssertNil(panel.terminal?.scrollback)
        }
        let panel = try XCTUnwrap(workspace.panels[ids[0]] as? TerminalPanel)
        let lost = HCLifecycle.ended(HCEndEvidence(id: UUID(), key: records[0].key,
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .finished, hcReason: "holder_lost"))
        panel.hcSession?.publish(lost)
        XCTAssertEqual(panel.hcRestoreNotice, .holderLost)
        XCTAssertEqual(workspace.panels.count, 3)
        panel.dismissHCRestoreNotice()
        panel.hcSession?.publish(lost)
        XCTAssertNil(panel.hcRestoreNotice, "an unchanged inventory must not undo the operator's dismissal")
        panel.hcSession?.publish(.live(records[0]))
        panel.hcSession?.publish(lost)
        XCTAssertEqual(panel.hcRestoreNotice, .holderLost, "a later terminal end is a new notice")
        panel.detachForSessionRestore()
        XCTAssertEqual(HCPanelRestoreState.shared.entry(for: ids[0])?.identity.key, records[0].key)
    }
}

final class HCRecoveredTerminalPlannerTests: XCTestCase {
    private let revision = HCRevision(connectionGeneration: 1, sequence: 10)
    private var build: HCBuildIdentity {
        HCBuildIdentity(pin: .current, executablePath: "/owned/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5),
            process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 6), coreID: "owned", protocolGeneration: 1)
    }
    private func record(_ address: String, panel: UUID? = nil, attempt: UUID? = nil, core: String = "owned") -> HCTerminalRecord {
        var labels: [String: String] = [:]
        if let panel { labels["c11.panel"] = panel.uuidString }
        if let attempt { labels["c11.creation"] = attempt.uuidString }
        return HCTerminalRecord(key: HCTerminalKey(owningCoreID: core, localAddress: address), state: .running, labels: labels, pid: 123)
    }
    private func snapshot(_ records: [HCTerminalRecord], ready: Bool = true) -> HCInventorySnapshot {
        HCInventorySnapshot(readiness: ready ? .ready(revision) : .pending(.inventoryPending), revision: revision,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }), buildIdentity: build)
    }

    func testWaitsForAllWindowsAndAuthoritativeInventory() {
        let orphan = record("t1", panel: UUID())
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([orphan]), identities: [], restoreComplete: false).isEmpty)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([orphan], ready: false), identities: [], restoreComplete: true).isEmpty)
        let mismatched = HCInventorySnapshot(readiness: .ready(HCRevision(connectionGeneration: 0, sequence: 10)),
            revision: revision, records: [orphan.key: orphan], buildIdentity: build)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: mismatched, identities: [], restoreComplete: true).isEmpty)
    }

    func testOrphanKeepsUUIDAndKeyAndDefaultSessionIsExcluded() {
        let id = UUID()
        let orphan = record("t1", panel: id)
        let foreign = record("t2", panel: UUID(), core: "default")
        let result = HCRecoveredTerminalPlanner.recoveries(from: snapshot([orphan, foreign]), identities: [], restoreComplete: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.identity.panelID, id)
        XCTAssertEqual(result.first?.identity.key, orphan.key)
        XCTAssertEqual(result.first?.record.pid, orphan.pid)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([orphan]), identities: result.map(\.identity), restoreComplete: true).isEmpty)
    }

    func testUnlabeledAndDuplicateLabelTerminalsAllKeepDistinctBindings() {
        let id = UUID()
        let records = [record("t1", panel: id), record("t2", panel: id), record("t3")]
        let result = HCRecoveredTerminalPlanner.recoveries(from: snapshot(records), identities: [], restoreComplete: true)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map(\.identity.panelID)).count, 3)
        XCTAssertEqual(Set(result.compactMap(\.identity.key)), Set(records.map(\.key)))
        XCTAssertEqual(result.first?.identity.panelID, id)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot(records), identities: result.map(\.identity), restoreComplete: true).isEmpty)
    }

    func testInventoryBindingWithoutUIPanelStillRecoversOriginalIdentity() {
        let id = UUID(), orphan = record("t1")
        let labeled = record("t2", panel: id)
        let inventory = HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [orphan.key: orphan, labeled.key: labeled], buildIdentity: build,
            panelBindings: [id: labeled.key])
        let result = HCRecoveredTerminalPlanner.recoveries(from: inventory, identities: [], restoreComplete: true)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first(where: { $0.record.key == labeled.key })?.identity.panelID, id)
    }

    func testActiveAttemptWaitsAndLateSupersededAttemptIsRecovered() {
        let id = UUID(), active = UUID()
        let current = record("t1", panel: id, attempt: active)
        let late = record("t2", panel: id, attempt: UUID())
        let identity = HCPanelIdentity(panelID: id, creationID: active)
        let result = HCRecoveredTerminalPlanner.recoveries(from: snapshot([current, late]), identities: [identity], restoreComplete: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.identity.key, late.key)
        XCTAssertNotEqual(result.first?.identity.panelID, id)
    }

    func testPendingCloseAndSavedClaimsAreNotRecovered() {
        let id = UUID()
        let saved = record("t1", panel: id), closing = record("t2")
        let result = HCRecoveredTerminalPlanner.recoveries(from: snapshot([saved, closing]),
            identities: [HCPanelIdentity(panelID: id)], restoreComplete: true, closingKeys: [closing.key])
        XCTAssertTrue(result.isEmpty)
    }

    func testNewerDurableAttemptWaitsForOldSnapshotIdentityToResolve() {
        let id = UUID(), attempt = UUID()
        let old = record("old", panel: id)
        let newer = record("newer", panel: id, attempt: attempt)
        let saved = HCPanelIdentity(panelID: id, key: old.key)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([newer]),
            identities: [saved], restoreComplete: true, unresolvedPanelIDs: [id]).isEmpty)
        let bound = HCPanelIdentity(panelID: id, key: newer.key, creationID: attempt)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([newer]),
            identities: [bound], restoreComplete: true).isEmpty)
        // Once resolve binds the saved panel elsewhere, a superseded record is
        // a real orphan and keeps its exact key under a separate UI identity.
        let orphan = HCRecoveredTerminalPlanner.recoveries(from: snapshot([newer]),
            identities: [saved], restoreComplete: true)
        XCTAssertEqual(orphan.first?.identity.key, newer.key)
        XCTAssertNotEqual(orphan.first?.identity.panelID, id)
    }

    func testPendingCloseBeforeKeyResolutionIsNotResurrected() {
        let closingID = UUID(), remainingID = UUID()
        let closing = record("t1", panel: closingID), remaining = record("t2", panel: remainingID)
        let result = HCRecoveredTerminalPlanner.recoveries(from: snapshot([closing, remaining]),
            identities: [], restoreComplete: true, closingPanelIDs: [closingID])
        XCTAssertEqual(result.map(\.identity.panelID), [remainingID])
    }

    @MainActor
    func testControllerReadsDurablePendingEndProvidersAtEachReconciliation() {
        let previousIDs = HCRecoveredTerminalController.pendingEndPanelIDs
        let previousKeys = HCRecoveredTerminalController.pendingEndKeys
        defer {
            HCRecoveredTerminalController.pendingEndPanelIDs = previousIDs
            HCRecoveredTerminalController.pendingEndKeys = previousKeys
        }
        let id = UUID(), byID = record("t1", panel: id), byKey = record("t2")
        var pendingIDs: Set<UUID> = [id]
        var pendingKeys: Set<HCTerminalKey> = [byKey.key]
        HCRecoveredTerminalController.pendingEndPanelIDs = { pendingIDs }
        HCRecoveredTerminalController.pendingEndKeys = { pendingKeys }
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { adopted.map(\.identity) }, adopt: { adopted.append($0) })
        controller.finishRestoring()
        controller.receive(snapshot([byID, byKey]))
        XCTAssertTrue(adopted.isEmpty)
        pendingIDs = []
        pendingKeys = []
        controller.panelClaimsChanged()
        XCTAssertEqual(Set(adopted.map(\.record.key)), [byID.key, byKey.key])
        controller.panelClaimsChanged()
        XCTAssertEqual(adopted.count, 2)
    }

    // MARK: C11H-46: a panel that has not registered still holds its terminal

    private func studio(_ address: String, panel: UUID, install: String? = HCOwnerLabels.appInstallID,
                        creation: UUID = UUID()) -> HCTerminalRecord {
        var labels = ["c11.panel": panel.uuidString, "c11.creation": creation.uuidString]
        labels[HCOwnerLabels.app] = install
        return HCTerminalRecord(key: HCTerminalKey(owningCoreID: "atlas-core", localAddress: address), state: .running,
            labels: labels, machineName: "studio", machineAvailability: .connected, pid: 81572)
    }

    /// C11H-359 (M4): this Mac's creation record for each linked-machine
    /// terminal, as the store holds it while the terminal runs.
    private func vouching(_ records: [HCTerminalRecord], phase: HCCreationPhase = .bound,
                          machine: String? = "studio", bound: Bool = true) -> [UUID: HCStoredCreation] {
        var creations: [UUID: HCStoredCreation] = [:]
        for record in records {
            guard let panel = record.labels["c11.panel"].flatMap(UUID.init(uuidString:)),
                  let creation = record.labels["c11.creation"].flatMap(UUID.init(uuidString:)) else { continue }
            creations[panel] = HCStoredCreation(panelID: panel, creationID: creation, coreID: "owned",
                coreProcess: HCProcessIdentity(pid: 42, startTimeMicroseconds: 6), phase: phase,
                key: bound ? record.key : nil, endEvidence: nil, initialInput: .none, machine: machine)
        }
        return creations
    }

    /// C11H-363: a linked terminal that comes back through Recovered ("Start
    /// fresh", or a panel the last autosave missed) keeps the machine this
    /// Mac's creation record vouched for, on every adoption path. The drop and
    /// titlebar checks then read it as remote, and its target is saved.
    @MainActor
    func testARecoveredLinkedTerminalKeepsItsMachineOnEveryAdoptionPath() throws {
        let homeRecord = studio("t7", panel: UUID())
        let joinRecord = studio("t8", panel: UUID())
        let newRecord = studio("t9", panel: UUID())
        let localRecord = record("t1", panel: UUID())
        let recoveries = HCRecoveredTerminalPlanner.recoveries(
            from: snapshot([homeRecord, joinRecord, newRecord, localRecord]), identities: [], restoreComplete: true,
            appInstallID: HCOwnerLabels.appInstallID, creations: vouching([homeRecord, joinRecord, newRecord]))
        func recovery(_ record: HCTerminalRecord) throws -> HCRecoveredTerminalPlanner.Recovery {
            try XCTUnwrap(recoveries.first { $0.record.key == record.key })
        }

        // The three paths the adoption takes: home, an existing Recovered
        // workspace, and a new Recovered workspace.
        let home = Workspace()
        let returning = try XCTUnwrap(home.addReturningTerminal(try recovery(homeRecord), title: nil))
        let recovered = Workspace()
        let area = try XCTUnwrap(recovered.bonsplitController.allPaneIds.first)
        let joined = try XCTUnwrap(recovered.addRecoveredTerminal(try recovery(joinRecord), inPane: area))
        let created = WorkspaceManager().addRecoveredWorkspace(try recovery(newRecord))
        let first = try XCTUnwrap(created.panels[try recovery(newRecord).identity.panelID] as? TerminalPanel)

        for (workspace, panel) in [(home, returning), (recovered, joined), (created, first)] {
            XCTAssertEqual(panel.hcRemoteTarget?.machine, "studio", "a recovered linked terminal stays on its machine")
            XCTAssertTrue(workspace.isRemoteTerminalPanel(panel.id))
            workspace.focusPanel(panel.id)
            workspace.updatePanelDirectory(panelId: panel.id, directory: "/Users/demo/.ssh/id_ed25519")
            XCTAssertNil(workspace.localFolderDirectory(), "its reported directory is never a local folder")
            let canary = URL(fileURLWithPath: "/Users/demo/.ssh/id_ed25519")
            XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [canary], targetIsRemote: panel.hcRemoteTarget != nil,
                                                         startedInsideC11: true), .refuse)
            XCTAssertEqual(TerminalFileDropPolicy.decide(urls: [canary], targetIsRemote: panel.hcRemoteTarget != nil,
                                                         startedInsideC11: false), .ask([canary]))
            let saved = workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panel.id }
            XCTAssertEqual(saved?.terminal?.hcRemoteTarget?.machine, "studio", "the next autosave keeps the target")
        }

        // Control: a terminal on this Mac comes back local.
        let local = try recovery(localRecord)
        XCTAssertNil(local.remoteTarget)
        let control = Workspace()
        let controlArea = try XCTUnwrap(control.bonsplitController.allPaneIds.first)
        let localPanel = try XCTUnwrap(control.addRecoveredTerminal(local, inPane: controlArea))
        XCTAssertNil(localPanel.hcRemoteTarget)
        XCTAssertFalse(control.isRemoteTerminalPanel(localPanel.id))
    }

    /// C11H-196: Studio's core also holds terminals other c11 installs made
    /// (another Mac, a tagged build). Recovered adopts only this install's.
    func testRecoveredAdoptsOnlyRemoteTerminalsThisInstallCreated() {
        let ours = studio("t1", panel: UUID())
        let foreign = studio("t2", panel: UUID(), install: UUID().uuidString)
        let unlabelled = studio("t3", panel: UUID(), install: nil)
        let adopted = HCRecoveredTerminalPlanner.recoveries(from: snapshot([ours, foreign, unlabelled]), identities: [],
            restoreComplete: true, appInstallID: HCOwnerLabels.appInstallID, creations: vouching([ours, foreign, unlabelled]))
        XCTAssertEqual(adopted.map(\.record.key), [ours.key])
    }

    /// C11H-205: release, staging, nightly and the untagged Debug build share
    /// this Mac's hc session. On 2026-11-05 h10's Recovered held four shells a
    /// staging build had opened. A local terminal another install labelled is
    /// never ours; an unlabelled one predates the label and still is.
    func testRecoveredSkipsALocalTerminalAnotherInstallLabelled() {
        func local(_ address: String, install: String?) -> HCTerminalRecord {
            var labels = ["c11.panel": UUID().uuidString]
            labels[HCOwnerLabels.app] = install
            return HCTerminalRecord(key: HCTerminalKey(owningCoreID: "owned", localAddress: address), state: .running,
                                    labels: labels, pid: 123)
        }
        let ours = local("t1", install: HCOwnerLabels.appInstallID)
        let staging = local("t2", install: UUID().uuidString)
        let legacy = local("t3", install: nil)
        let adopted = HCRecoveredTerminalPlanner.recoveries(from: snapshot([ours, staging, legacy]), identities: [],
            restoreComplete: true, appInstallID: HCOwnerLabels.appInstallID)
        XCTAssertEqual(Set(adopted.map(\.record.key)), [ours.key, legacy.key])
    }

    /// The controller is what the app runs: it filters by this install, and
    /// (C11H-359) adopts a linked machine's terminal only once this Mac's
    /// creation records, read off main, vouch for it.
    @MainActor
    func testRecoveredControllerSkipsAnotherInstallsAtlasTerminal() async throws {
        let ours = studio("t1", panel: UUID()), foreign = studio("t2", panel: UUID(), install: UUID().uuidString)
        let records = Array(vouching([ours, foreign]).values)
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { [] }, readCreations: { records }) { adopted.append($0) }
        controller.finishRestoring()
        controller.receive(snapshot([ours, foreign]))
        XCTAssertTrue(adopted.isEmpty, "nothing is adopted before the creation records are read")
        for _ in 0..<200 where adopted.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(adopted.map(\.record.key), [ours.key])
        controller.stop()
    }

    /// REPAIR-1 (B2): a store the test changes, counting its reads.
    private final class CreationsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [HCStoredCreation]? = []
        private var count = 0
        private var failures = 0
        func set(_ records: [HCStoredCreation]) { lock.lock(); value = records; lock.unlock() }
        func failNext() { lock.lock(); failures += 1; lock.unlock() }
        func read() -> [HCStoredCreation]? {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if failures > 0 { failures -= 1; return nil }
            return value
        }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @MainActor
    private func settle(until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    /// REPAIR-1 (B2): a read of the creation records speaks only for the
    /// linked terminals it was made for. (a) Once none is left, the same labels
    /// coming back are read again; (b) the same panel and creation under
    /// another key is read again. Either way an ended creation never vouches.
    @MainActor
    func testARecoveryReadNeverOutlivesTheLinkedTerminalsItWasMadeFor() async throws {
        for emptyBetween in [true, false] {
            let panel = UUID(), creation = UUID()
            let k1 = studio("t1", panel: panel, creation: creation)
            let k2 = studio("t2", panel: panel, creation: creation)
            let box = CreationsBox()
            box.set(Array(vouching([k1], bound: false).values))
            var claims = HCPanelClaims(panelIDs: [panel])
            var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
            let controller = HCRecoveredTerminalController(identities: { [] }, claims: { claims },
                                                           readCreations: { box.read() }) { adopted.append($0) }
            controller.finishRestoring()
            controller.receive(snapshot([k1]))
            try await settle { box.reads == 1 }
            XCTAssertTrue(adopted.isEmpty, "its panel still holds it")
            // The creation ends, its panel closes and its terminal leaves.
            box.set([])
            claims = HCPanelClaims()
            if emptyBetween { controller.receive(snapshot([])) }
            // A terminal on the linked machine now carries that panel's and creation's labels.
            controller.receive(snapshot([emptyBetween ? k1 : k2]))
            try await settle { box.reads == 2 }
            XCTAssertEqual(box.reads, 2, "emptyBetween=\(emptyBetween): read again")
            XCTAssertTrue(adopted.isEmpty, "emptyBetween=\(emptyBetween): an ended creation vouches for nothing")
            controller.stop()
        }
    }

    /// Opus nb5: a store that can't be read now is read again, and the
    /// orphan its record vouches for is adopted then.
    @MainActor
    func testAnUnreadableCreationStoreIsReadAgain() async throws {
        let t1 = studio("t1", panel: UUID())
        let box = CreationsBox()
        box.set(Array(vouching([t1]).values))
        box.failNext()
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { [] }, readCreations: { box.read() }) { adopted.append($0) }
        controller.finishRestoring()
        controller.receive(snapshot([t1]))
        try await settle { box.reads == 1 }
        XCTAssertTrue(adopted.isEmpty, "nothing is judged from a failed read")
        controller.panelClaimsChanged()
        try await settle { !adopted.isEmpty }
        XCTAssertEqual(adopted.map(\.record.key), [t1.key])
        XCTAssertEqual(box.reads, 2)
        controller.stop()
    }

    /// C11H-359 (M4): with no way to read this Mac's creation records, a
    /// linked machine's terminal is never adopted, whatever its labels say.
    @MainActor
    func testRecoveredControllerWithoutCreationRecordsAdoptsNoLinkedTerminal() async throws {
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { [] }) { adopted.append($0) }
        controller.finishRestoring()
        controller.receive(snapshot([studio("t1", panel: UUID())]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(adopted.isEmpty)
        controller.stop()
    }

    /// C11H-359 (M4): labels a linked machine can write (this install's id,
    /// a workspace, a title, a panel UUID and a creation id) never make one of
    /// its terminals this Mac's. Only an active creation record that made
    /// that terminal does: same creation, same machine, same key once bound.
    func testALinkedMachinesLabelsAloneNeverAdoptATerminal() {
        let panel = UUID(), workspace = UUID()
        var forged = studio("t1", panel: panel)
        forged = HCTerminalRecord(key: forged.key, state: .running,
            labels: forged.labels.merging([HCOwnerLabels.workspace: workspace.uuidString, HCOwnerLabels.title: "zsh"]) { $1 },
            machineName: "studio", machineAvailability: .connected, pid: 81572)
        func adopted(_ creations: [UUID: HCStoredCreation]?) -> [HCTerminalKey] {
            HCRecoveredTerminalPlanner.recoveries(from: snapshot([forged]), identities: [], restoreComplete: true,
                appInstallID: HCOwnerLabels.appInstallID, creations: creations).map(\.record.key)
        }
        XCTAssertEqual(adopted(nil), [], "creation records not read")
        XCTAssertEqual(adopted([:]), [], "no creation record for the panel")
        let genuine = vouching([forged])
        XCTAssertEqual(adopted(genuine), [forged.key], "this Mac's own record vouches for it")
        let made = genuine[panel]!
        func altered(_ change: (inout HCStoredCreation) -> Void) -> [UUID: HCStoredCreation] {
            var creation = made; change(&creation); return [panel: creation]
        }
        XCTAssertEqual(adopted(altered { _ in }), [forged.key])
        XCTAssertEqual(adopted([panel: HCStoredCreation(panelID: panel, creationID: UUID(), coreID: made.coreID,
            coreProcess: made.coreProcess, phase: .bound, key: made.key, endEvidence: nil, initialInput: .none,
            machine: "studio")]), [], "another creation")
        XCTAssertEqual(adopted(altered { $0.machine = "rigel" }), [], "another machine")
        XCTAssertEqual(adopted(altered { $0.machine = nil }), [], "a local creation")
        XCTAssertEqual(adopted(altered { $0.key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t9") }), [], "another key")
        XCTAssertEqual(adopted(altered { $0.phase = .ended }), [], "an ended creation")
        XCTAssertEqual(adopted(vouching([forged], bound: false)), [forged.key], "an unbound creation of that terminal")
    }

    /// C11H-359 (M4): a vouched terminal is still not adopted when a panel
    /// already holds its UUID or another terminal carries it.
    func testAVouchedLinkedTerminalWhoseUUIDIsHeldOrSharedIsNotAdopted() {
        let panel = UUID()
        let t1 = studio("t1", panel: panel)
        let creations = vouching([t1])
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1]), identities: [], restoreComplete: true,
            claims: HCPanelClaims(panelIDs: [panel]), appInstallID: HCOwnerLabels.appInstallID, creations: creations).isEmpty)
        let twin = studio("t2", panel: panel)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1, twin]), identities: [], restoreComplete: true,
            appInstallID: HCOwnerLabels.appInstallID, creations: creations).isEmpty)
    }

    /// The laptop's replay: the ticker and shell are live in Workspace 1, but
    /// their sessions had not published a persistent identity when the
    /// reconcile ran, so `identities` misses them. Their bound keys and UUIDs
    /// still claim the terminals; nothing is adopted, no duplicate is made.
    func testAPanelThatHasNotRegisteredStillHoldsItsAtlasTerminal() {
        let ticker = UUID(), shell = UUID()
        let t1 = studio("t1", panel: ticker), t5 = studio("t5", panel: shell)
        let claims = HCPanelClaims(panelIDs: [ticker, shell], keys: [t1.key, t5.key])
        XCTAssertEqual(HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1, t5]), identities: [],
            restoreComplete: true, creations: vouching([t1, t5])).count, 2, "the precondition: unclaimed, both would be adopted")
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1, t5]), identities: [],
            restoreComplete: true, claims: claims, creations: vouching([t1, t5])).isEmpty)
    }

    /// A bound key alone claims the terminal even when the panel's UUID is
    /// some other one (a replacement panel, or a moved one).
    func testABoundKeyAloneClaimsTheTerminal() {
        let t1 = studio("t1", panel: UUID())
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1]), identities: [],
            restoreComplete: true, claims: HCPanelClaims(keys: [t1.key])).isEmpty)
    }

    /// A terminal panel that exists but has no key yet owns the terminal
    /// labelled with its UUID: it is that panel's to resolve.
    func testAKeylessPanelOwnsTheTerminalLabelledWithItsUUID() {
        let panel = UUID()
        let t1 = studio("t1", panel: panel)
        XCTAssertTrue(HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1]), identities: [],
            restoreComplete: true, claims: HCPanelClaims(panelIDs: [panel], keylessPanelIDs: [panel])).isEmpty)
    }

    /// A UUID any panel has, of any kind, is never given to a second panel.
    /// (A linked machine's terminal whose UUID is held is never adopted at all, C11H-359.)
    func testALabelNeverReusesAUUIDAnyPanelAlreadyHas() {
        let browser = UUID()
        let t1 = record("t1", panel: browser)
        let result = HCRecoveredTerminalPlanner.recoveries(from: snapshot([t1]), identities: [],
            restoreComplete: true, claims: HCPanelClaims(panelIDs: [browser]))
        XCTAssertEqual(result.map(\.record.key), [t1.key], "an orphan still recovers")
        XCTAssertNotEqual(result.first?.identity.panelID, browser)
    }

    @MainActor
    func testControllerReadsTheFullClaimsOnEveryReconcile() {
        let ticker = UUID()
        let t1 = record("t1", panel: ticker)
        var claims = HCPanelClaims(panelIDs: [ticker], keys: [t1.key])
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { [] }, claims: { claims }) { adopted.append($0) }
        controller.finishRestoring()
        controller.receive(snapshot([t1]))
        XCTAssertTrue(adopted.isEmpty, "a held terminal is never adopted")
        claims = HCPanelClaims()
        controller.panelClaimsChanged()
        XCTAssertEqual(adopted.map(\.identity.panelID), [ticker], "a real orphan keeps its UUID")
        controller.stop()
    }

    /// C11H-103 (the laptop, four closes in Glass V2): closing a panel must end
    /// its terminal, never re-create the closed panel in Recovered. Recovery
    /// reconciles in the gap between the panel leaving the workspace and the
    /// end coordinator's queue running; the coordinator's queue is held here
    /// to make that gap certain.
    @MainActor
    func testClosingAPanelEndsItsTerminalAndNothingReappearsInRecovered() async {
        let panel = UUID()
        let t2v = record("t2v", panel: panel)
        let orphan = record("t9", panel: UUID())
        let session = HCEndFakeSession()
        session.scriptEnd(t2v.key, .confirmed(HCEndEvidence(id: UUID(), key: t2v.key,
            revision: HCRevision(connectionGeneration: 1, sequence: 9), kind: .observedRemoval, hcReason: "killed")))
        let queue = DispatchQueue(label: "test.explicit-end")
        queue.suspend()
        final class Adopted: @unchecked Sendable { var recoveries: [HCRecoveredTerminalPlanner.Recovery] = [] }
        let adopted = Adopted()
        // The holder check sees exactly the panels Recovered created.
        let coordinator = HCExplicitEndCoordinator(session: session, store: HCEndMemoryStore(), heldElsewhere: { key in
            await MainActor.run { adopted.recoveries.contains { $0.record.key == key } ? .held(HCEndHolder(panelID: panel,
                panelRef: nil, title: "Terminal", workspaceID: UUID(), workspaceTitle: "Recovered")) : .none }
        }, queue: queue)
        // The panel has already left its workspace: nothing claims t2v any more.
        let controller = HCRecoveredTerminalController(identities: { [] },
            closingPanelIDs: { coordinator.pendingEndPanelIDs() }, closingKeys: { coordinator.pendingEndKeys() },
            claims: { HCPanelClaims() }) { adopted.recoveries.append($0) }
        controller.finishRestoring()
        coordinator.requestEnd([HCPanelIdentity(panelID: panel, key: t2v.key)], origin: .panelClose)
        controller.receive(snapshot([t2v, orphan]))
        XCTAssertEqual(adopted.recoveries.map(\.record.key), [orphan.key], "the closed panel's terminal is never re-adopted")
        queue.resume()
        let result = await coordinator.outcomes(for: [panel], timeout: 2)[panel]
        XCTAssertEqual(result, .ended, "its terminal ends; a re-created twin would make this .kept")
        XCTAssertEqual(session.ends, [t2v.key])
        controller.stop()
    }

    /// C11H-103: a closed id is tombstoned for the run. Even when its terminal
    /// is still running and nothing claims it (its end was refused, or is
    /// stuck), Recovered never adopts it and never reuses the id.
    @MainActor
    func testAClosedIdIsNeverReadoptedEvenIfItsTerminalStillRuns() {
        let closed = UUID()
        let stillRunning = record("t2v", panel: closed)
        let orphan = record("t9", panel: UUID())
        let tombstones = HCCloseTombstones()
        tombstones.noteClosedForGood([closed])
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { [] },
            closingPanelIDs: { tombstones.closingPanelIDs(pending: []) }, claims: { HCPanelClaims() }) { adopted.append($0) }
        controller.finishRestoring()
        controller.receive(snapshot([stillRunning, orphan]))
        XCTAssertEqual(adopted.map(\.record.key), [orphan.key])
        XCTAssertFalse(adopted.contains { $0.identity.panelID == closed })
        controller.stop()
    }

    @MainActor
    func testCloseTombstonesKeepClosedIdsClosingAndRecoveredPanelsFromReplacing() {
        let tombstones = HCCloseTombstones()
        let adopted = UUID(), closed = UUID(), ordinary = UUID()
        tombstones.noteAdopted(adopted)
        XCTAssertFalse(tombstones.mayReplaceMissingTerminal(panelID: adopted, inRecoveredWorkspace: false))
        XCTAssertFalse(tombstones.mayReplaceMissingTerminal(panelID: ordinary, inRecoveredWorkspace: true))
        XCTAssertTrue(tombstones.mayReplaceMissingTerminal(panelID: ordinary, inRecoveredWorkspace: false))
        tombstones.noteClosedForGood([closed, adopted])
        XCTAssertEqual(tombstones.closingPanelIDs(pending: [ordinary]), [ordinary, closed, adopted])
        XCTAssertTrue(tombstones.mayReplaceMissingTerminal(panelID: adopted, inRecoveredWorkspace: false),
                      "a closed id is no longer an adopted panel")
    }

    /// C11H-103 (L4 amendment, conditions 1-3): an orphan goes home only to
    /// a workspace in the restored session, never after a fresh start, and only
    /// as its own panel's terminal with an unshared label; else Recovered.
    func testAnOrphanGoesHomeOnlyUnderTheAmendmentsConditions() {
        let panel = UUID(), home = UUID(), recovered = UUID()
        func record(_ labels: [String: String]) -> HCTerminalRecord {
            HCTerminalRecord(key: HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t2v"), state: .running,
                             labels: labels, machineName: "studio", machineAvailability: .connected, pid: 9)
        }
        func place(_ r: HCTerminalRecord, panelID: UUID? = nil, eligible: Bool = true, fresh: Bool = false,
                   workspaces: [(id: UUID, isRecovered: Bool)]? = nil) -> HCRecoveredPlacement {
            HCRecoveredPlacement.destination(record: r, panelID: panelID ?? panel, homeEligible: eligible,
                startedFresh: fresh, workspaces: workspaces ?? [(home, false), (recovered, true)])
        }
        let full = record(["c11.panel": panel.uuidString, HCOwnerLabels.workspace: home.uuidString,
                           HCOwnerLabels.title: "T-8 Review"])
        XCTAssertEqual(place(full), .home(workspaceID: home, title: "T-8 Review"))
        // (1) the workspace must be in the restored session.
        XCTAssertEqual(place(full, workspaces: [(recovered, true)]), .recovered)
        XCTAssertEqual(place(record(["c11.panel": panel.uuidString, HCOwnerLabels.workspace: recovered.uuidString])),
                       .recovered, "never 'home' into Recovered itself")
        // (2) Start fresh sends every live terminal to Recovered.
        XCTAssertEqual(place(full, fresh: true), .recovered)
        // (3) a superseded creation (fresh id) or a shared label stays in Recovered.
        XCTAssertEqual(place(full, panelID: UUID()), .recovered)
        XCTAssertEqual(place(full, eligible: false), .recovered)
        XCTAssertEqual(place(record(["c11.panel": panel.uuidString])), .recovered, "no workspace label")
        XCTAssertEqual(place(record(["c11.panel": panel.uuidString, HCOwnerLabels.workspace: home.uuidString,
                                     HCOwnerLabels.title: ""])), .home(workspaceID: home, title: nil))
    }

    /// (3): only a record that kept its own label UUID, and whose label no
    /// other candidate shares, is eligible to go home.
    func testOnlyAnOwnUnsharedLabelIsHomeEligible() {
        let free = UUID(), occupied = UUID(), shared = UUID()
        let own = record("t1", panel: free)
        let superseded = record("t2", panel: occupied)
        let twinA = record("t3", panel: shared), twinB = record("t4", panel: shared)
        let recoveries = HCRecoveredTerminalPlanner.recoveries(from: snapshot([own, superseded, twinA, twinB]),
            identities: [], restoreComplete: true, claims: HCPanelClaims(panelIDs: [occupied], keys: []))
        let eligible = Dictionary(uniqueKeysWithValues: recoveries.map { ($0.record.key, $0.homeEligible) })
        XCTAssertEqual(eligible[own.key], true)
        XCTAssertEqual(eligible[superseded.key], false, "its id is taken: it gets a fresh one and stays in Recovered")
        XCTAssertEqual(eligible[twinA.key], false)
        XCTAssertEqual(eligible[twinB.key], false, "two orphans claim one panel: neither goes home")
    }

    /// (4): a returning panel is a NEW panel at the end of the workspace's last
    /// area, with its title; no split, and the saved panes and tabs keep their order.
    @MainActor
    func testAReturningPanelIsAppendedToTheLastAreaWithoutTouchingTheLayout() throws {
        let workspace = Workspace()
        let first = try XCTUnwrap(workspace.focusedPanelId)
        let right = try XCTUnwrap(workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false))
        _ = workspace.newTerminalSurface(inPane: try XCTUnwrap(workspace.bonsplitController.allPaneIds.last), focus: false)
        let panes = workspace.bonsplitController.allPaneIds
        let before = panes.map { workspace.bonsplitController.tabs(inPane: $0).map(\.id) }
        let returning = UUID()
        XCTAssertNotNil(workspace.addReturningTerminal(panelID: returning, title: "T-8 Review"))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds, panes, "no split, no new area")
        let after = panes.map { workspace.bonsplitController.tabs(inPane: $0).map(\.id) }
        XCTAssertEqual(after.dropLast(), before.dropLast(), "other areas untouched")
        XCTAssertEqual(Array(after.last!.dropLast()), before.last!, "the last area keeps its tabs in order")
        XCTAssertEqual(workspace.tabIdFromBonsplitTabId(after.last!.last!), returning, "the new panel is last")
        XCTAssertEqual(workspace.panelTitle(panelId: returning), "T-8 Review")
        _ = right
    }

    func testTitleLabelsAreTrimmedAndClipped() {
        XCTAssertEqual(HCOwnerLabels.titleValue("  T-8 Review \n"), "T-8 Review")
        XCTAssertEqual(HCOwnerLabels.titleValue(nil), "")
        XCTAssertEqual(HCOwnerLabels.titleValue(String(repeating: "x", count: 500)).count, HCOwnerLabels.maximumTitleCharacters)
    }

    /// Renames and moves within one window become one label write with the
    /// latest values; a panel with no live terminal sends nothing.
    @MainActor
    func testOwnerLabelWritesAreDebouncedAndMerged() async throws {
        let labels = RecordingLabels()
        let sync = HCOwnerLabelSync()
        sync.delay = 0.05
        let panel = UUID(), nobody = UUID(), key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t2v")
        sync.target = { $0 == panel ? .ready(key, labels) : .gone }
        sync.note(panelID: panel, labels: [HCOwnerLabels.title: "one"])
        sync.note(panelID: panel, labels: [HCOwnerLabels.workspace: "W"])
        sync.note(panelID: panel, labels: [HCOwnerLabels.title: "two"])
        sync.note(panelID: nobody, labels: [HCOwnerLabels.title: "lost"])
        let calls = await labels.settled()
        XCTAssertEqual(calls, [[HCOwnerLabels.title: "two", HCOwnerLabels.workspace: "W"]])
    }

    /// Review 1 (Grok, blocking 1): a title noted while the terminal has no
    /// key yet (its creation is in flight) is kept, and written once it does.
    @MainActor
    func testALabelNotedBeforeTheTerminalHasAKeyIsWrittenOnceItHasOne() async throws {
        let labels = RecordingLabels()
        let sync = HCOwnerLabelSync()
        sync.delay = 0.02
        let panel = UUID(), key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t2v")
        var asked = 0
        sync.target = { _ in
            asked += 1
            return asked < 4 ? .notYet : .ready(key, labels)
        }
        sync.note(panelID: panel, labels: [HCOwnerLabels.title: "T-8 Review"])
        let calls = await labels.settled()
        XCTAssertEqual(calls, [[HCOwnerLabels.title: "T-8 Review"]])
        XCTAssertGreaterThanOrEqual(asked, 4)
    }

    /// Review 1 (Grok, blocking 1): a write hc refuses is kept and sent again;
    /// a newer note made meanwhile wins over the refused batch.
    @MainActor
    func testARefusedLabelWriteIsRetriedUntilHCAcceptsIt() async throws {
        let labels = RecordingLabels(refuseFirst: 1)
        let sync = HCOwnerLabelSync()
        sync.delay = 0.02
        let panel = UUID(), key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t2v")
        sync.target = { _ in .ready(key, labels) }
        sync.note(panelID: panel, labels: [HCOwnerLabels.workspace: "B"])
        let calls = await labels.settled()
        XCTAssertEqual(calls, [[HCOwnerLabels.workspace: "B"], [HCOwnerLabels.workspace: "B"]],
                       "the refused write, then the same labels again")
        let accepted = await labels.accepted
        XCTAssertEqual(accepted, [[HCOwnerLabels.workspace: "B"]])
        // A panel that is gone is never retried.
        let gone = RecordingLabels()
        let stop = HCOwnerLabelSync()
        stop.delay = 0.02
        stop.target = { _ in .gone }
        stop.note(panelID: UUID(), labels: [HCOwnerLabels.title: "x"])
        let none = await gone.settled(timeout: 0.3)
        XCTAssertTrue(none.isEmpty)
    }

    /// Review 1 (Grok, blocking 2): the production notes. A rename through
    /// `setPanelCustomTitle` sends the clipped title, and a move into another
    /// workspace through `attachDetachedPanel` sends that workspace's id.
    @MainActor
    func testARenameAndAMoveSendTheTerminalsTitleAndNewWorkspace() async throws {
        let labels = RecordingLabels()
        let shared = HCOwnerLabelSync.shared
        let savedDelay = shared.delay, savedTarget = shared.target
        defer { shared.delay = savedDelay; shared.target = savedTarget }
        let source = Workspace(), destination = Workspace()
        let panel = try XCTUnwrap(source.focusedPanelId)
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t2v")
        shared.delay = 0.02
        shared.target = { $0 == panel ? .ready(key, labels) : .gone }
        source.setPanelCustomTitle(panelId: panel, title: "  " + String(repeating: "T", count: 130) + " ")
        let renamed = await labels.settled()
        XCTAssertEqual(renamed, [[HCOwnerLabels.title: String(repeating: "T", count: HCOwnerLabels.maximumTitleCharacters)]])
        let detached = try XCTUnwrap(source.detachPanel(panelId: panel))
        let area = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        XCTAssertNotNil(destination.attachDetachedPanel(detached, inPane: area, focus: false))
        let moved = await labels.settled(after: renamed.count)
        XCTAssertEqual(moved.last, [HCOwnerLabels.workspace: destination.id.uuidString])
    }

    @MainActor
    func testControllerWaitsForSecondWindowClaimsAndDoesNotDuplicateAdoption() {
        let savedInSecondWindow = record("t1", panel: UUID())
        let orphan = record("t2", panel: UUID())
        var identities: [HCPanelIdentity] = []
        var adopted: [HCRecoveredTerminalPlanner.Recovery] = []
        let controller = HCRecoveredTerminalController(identities: { identities }) { recovery in
            adopted.append(recovery)
            identities.append(recovery.identity)
        }
        controller.receive(snapshot([savedInSecondWindow, orphan]))
        XCTAssertTrue(adopted.isEmpty)
        identities.append(HCPanelIdentity(panelID: UUID(), key: savedInSecondWindow.key))
        controller.finishRestoring()
        XCTAssertEqual(adopted.map(\.record.key), [orphan.key])
        controller.receive(snapshot([savedInSecondWindow, orphan]))
        XCTAssertEqual(adopted.count, 1)
        controller.stop()
    }
}

/// C11H-46: the one-time launch cleanup of twins: one panel per terminal and
/// per UUID; the rest are dropped by detaching, never ending.
final class HCDuplicateBindingCleanupTests: XCTestCase {
    private func key(_ address: String) -> HCTerminalKey { HCTerminalKey(owningCoreID: "atlas-core", localAddress: address) }
    private func panel(_ token: Int, _ id: UUID, _ keys: Set<HCTerminalKey>, recovered: Bool = false) -> HCDuplicateBindingCleanup.Panel {
        HCDuplicateBindingCleanup.Panel(token: token, panelID: id, keys: keys, inRecovered: recovered)
    }

    func testRecoveredTwinIsDroppedAndTheOriginalKept() {
        let ticker = UUID(), shell = UUID()
        let panels = [
            panel(0, ticker, [key("t1")], recovered: true),
            panel(1, ticker, [key("t1")]),
            panel(2, shell, [key("t5")]),
            panel(3, shell, [key("t5")], recovered: true),
        ]
        XCTAssertEqual(HCDuplicateBindingCleanup.drops(panels).map(\.token), [0, 3])
    }

    func testTwoUUIDsOnOneTerminalKeepTheFirst() {
        let panels = [panel(0, UUID(), [key("t1")]), panel(1, UUID(), [key("t1")])]
        XCTAssertEqual(HCDuplicateBindingCleanup.drops(panels).map(\.token), [1])
    }

    func testOneUUIDOnTwoTerminalsKeepsOnePanel() {
        let id = UUID()
        let panels = [panel(0, id, [key("t1")], recovered: true), panel(1, id, [key("t2")])]
        XCTAssertEqual(HCDuplicateBindingCleanup.drops(panels).map(\.token), [0])
    }

    func testDistinctPanelsAndKeylessPanelsAreKept() {
        let panels = [panel(0, UUID(), [key("t1")]), panel(1, UUID(), [key("t2")]), panel(2, UUID(), []),
                      panel(3, UUID(), [])]
        XCTAssertTrue(HCDuplicateBindingCleanup.drops(panels).isEmpty)
    }

    func testAChainOfSharedKeysIsOneGroup() {
        let panels = [panel(0, UUID(), [key("t1")]), panel(1, UUID(), [key("t1"), key("t2")]),
                      panel(2, UUID(), [key("t2")])]
        XCTAssertEqual(HCDuplicateBindingCleanup.drops(panels).map(\.token), [1, 2])
    }
}

/// Records label writes; can refuse the first N. `settled()` waits until the
/// writes stop arriving.
actor RecordingLabels: HCTerminalLabeling {
    private(set) var calls: [[String: String]] = []
    private(set) var accepted: [[String: String]] = []
    private var refuse: Int
    init(refuseFirst: Int = 0) { refuse = refuseFirst }
    func setLabels(_ labels: [String: String], on key: HCTerminalKey) async -> Bool {
        calls.append(labels)
        if refuse > 0 { refuse -= 1; return false }
        accepted.append(labels)
        return true
    }
    func settled(after count: Int = 0, timeout: TimeInterval = 2) async -> [[String: String]] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = calls.count, quietSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if calls.count != last { last = calls.count; quietSince = Date() }
            if calls.count > count, Date().timeIntervalSince(quietSince) > 0.2 { break }
        }
        return calls
    }
}

/// C11H-238 (F1): a shard's revision moves when any of its terminals changes.
/// A panel whose own record did not change publishes nothing; the current
/// lifecycle decides, so an equal record still ends Reconnecting or a pending
/// state, and every field an observer reads is part of the comparison.
final class HCInventoryRepublishTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t7")
    private var sequence: UInt64 = 0

    private func base(_ panel: UUID) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: .running, labels: ["c11.panel": panel.uuidString], pid: 321,
            foreground: HCForeground(pid: 400, name: "claude"), title: "a", status: "idle", turn: 3,
            grid: HCGridSize(columns: 80, rows: 24), tty: "/dev/ttys009")
    }

    private func snapshot(_ records: [HCTerminalRecord], generation: UInt64 = 1,
                          pending: HCUnavailableReason? = nil) -> HCInventorySnapshot {
        sequence += 1
        let revision = HCRevision(connectionGeneration: generation, sequence: sequence)
        return HCInventorySnapshot(readiness: pending.map { .pending($0) } ?? .ready(revision), revision: revision,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }))
    }

    private final class Count { var value = 0 }
    private var sinks: [AnyCancellable] = []

    @MainActor
    private func runtime() -> (HCPanelSession, () -> Int, UUID) {
        let panel = UUID()
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel, key: key), session: HCUnavailableRuntime(),
                                     registrar: { _, _ in })
        let count = Count()
        sinks.append(runtime.$lifecycle.dropFirst().sink { _ in count.value += 1 })
        return (runtime, { count.value }, panel)
    }

    @MainActor
    func testAnUnchangedLiveRecordPublishesNothing() {
        let (runtime, publishes, panel) = runtime()
        let other = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "owned", localAddress: "t8"), state: .running)
        runtime.receiveInventory(snapshot([base(panel), other]))
        XCTAssertEqual(publishes(), 1)
        // Another terminal in the shard spins its title: this panel's record is equal.
        for title in ["x", "y", "z"] {
            runtime.receiveInventory(snapshot([base(panel), other.withTitle(title)]))
        }
        XCTAssertEqual(publishes(), 1, "an equal record must not republish")
    }

    @MainActor
    func testEveryFieldAnObserverReadsStillPublishes() {
        let (runtime, publishes, panel) = runtime()
        let start = base(panel)
        runtime.receiveInventory(snapshot([start]))
        let changes: [HCTerminalRecord] = [
            HCTerminalRecord(key: key, state: .running, labels: start.labels, pid: 321, foreground: start.foreground,
                title: "a", status: "working", turn: 3, grid: start.grid, tty: start.tty),
            HCTerminalRecord(key: key, state: .running, labels: start.labels, pid: 321, foreground: start.foreground,
                title: "a", status: "working", turn: 4, grid: start.grid, tty: start.tty),
            HCTerminalRecord(key: key, state: .running, labels: start.labels, pid: 321,
                foreground: HCForeground(pid: 401, name: "grok"), title: "a", status: "working", turn: 4,
                grid: start.grid, tty: start.tty),
            HCTerminalRecord(key: key, state: .running, labels: start.labels, pid: 321,
                foreground: HCForeground(pid: 401, name: "grok"), title: "b", status: "working", turn: 4,
                grid: start.grid, tty: start.tty),
            HCTerminalRecord(key: key, state: .running, labels: start.labels, pid: 321,
                foreground: HCForeground(pid: 401, name: "grok"), title: "b", status: "working", turn: 4,
                grid: HCGridSize(columns: 100, rows: 30), tty: start.tty),
        ]
        for (index, change) in changes.enumerated() {
            runtime.receiveInventory(snapshot([change]))
            XCTAssertEqual(publishes(), index + 2, "change \(index) must publish")
            guard case .live(let current) = runtime.lifecycle else { return XCTFail("not live") }
            XCTAssertEqual(current, change)
        }
    }

    @MainActor
    func testAnEqualRecordStillLeavesReconnectingAndPendingStates() {
        let (runtime, publishes, panel) = runtime()
        let record = base(panel)
        runtime.receiveInventory(snapshot([record]))
        runtime.receiveInventory(snapshot([], pending: .connectionLost))
        guard case .unresolved(_, .connectionLost) = runtime.lifecycle else { return XCTFail("not reconnecting") }
        let afterLoss = publishes()
        runtime.receiveInventory(snapshot([record], generation: 2))
        XCTAssertEqual(publishes(), afterLoss + 1, "a record equal to the last live one must clear Reconnecting")
        guard case .live(let back) = runtime.lifecycle else { return XCTFail("not live after reconnect") }
        XCTAssertEqual(back, record)
        XCTAssertEqual(runtime.lastLiveRecord, record)
        // Unresolved for any other reason, then the same record.
        runtime.publish(.unresolved(runtime.identity, .inventoryPending))
        let afterPending = publishes()
        runtime.receiveInventory(snapshot([record], generation: 2))
        XCTAssertEqual(publishes(), afterPending + 1)
    }

    @MainActor
    func testAnEndIsStillPublishedOnceAndEndedOnce() {
        let (runtime, publishes, panel) = runtime()
        var ends = 0
        runtime.onEnded = { _ in ends += 1 }
        runtime.receiveInventory(snapshot([base(panel)]))
        let finished = HCTerminalRecord(key: key, state: .finished, labels: ["c11.panel": panel.uuidString],
                                        exitCode: 0, endReason: "exited")
        runtime.receiveInventory(snapshot([finished]))
        runtime.receiveInventory(snapshot([finished]))
        runtime.receiveInventory(snapshot([finished]))
        XCTAssertEqual(publishes(), 2)
        XCTAssertEqual(ends, 1)
    }
}
