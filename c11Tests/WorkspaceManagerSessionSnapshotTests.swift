import XCTest
import Combine
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class WorkspaceManagerSessionSnapshotTests: XCTestCase {
    func testRestoreRetiresRetainedGraphBeforeReusingItsIDs() throws {
        let manager = WorkspaceManager()
        let oldWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let oldTerminal = try XCTUnwrap(oldWorkspace.focusedTerminalPanel)
        oldWorkspace.setCustomTitle("Retirement fixture")
        oldWorkspace.setOperatorMetadata(["fixture": "preserved"])
        try PanelMetadataStore.shared.setMetadata(workspaceId: oldWorkspace.id, surfaceId: oldTerminal.id,
                                               partial: ["fixture.tag": "preserved"], mode: .merge, source: .declare)
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        var publications: [[UUID]] = []
        let observation = manager.$workspaces.dropFirst().sink { publications.append($0.map(\.id)) }
        defer {
            observation.cancel()
            for workspace in manager.workspaces { workspace.teardownAllPanels() }
            oldWorkspace.teardownAllPanels()
            PanelMetadataStore.shared.removeWorkspace(workspaceId: oldWorkspace.id)
        }

        manager.restoreSessionSnapshot(snapshot)

        let replacement = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertFalse(replacement === oldWorkspace)
        XCTAssertEqual(replacement.id, oldWorkspace.id)
        XCTAssertTrue(oldWorkspace.panels.isEmpty, "externally retained old workspace must not retain live panels")
        XCTAssertNil(oldWorkspace.owningWorkspaceManager)
        XCTAssertEqual(oldTerminal.surface.portalBindingStateLabel(), "closed")
        XCTAssertNil(oldTerminal.surface.surface)
        let newTerminal = try XCTUnwrap(replacement.terminalPanel(for: oldTerminal.id))
        XCTAssertEqual(newTerminal.surface.portalBindingStateLabel(), "live")
        XCTAssertTrue(replacement.owningWorkspaceManager === manager)
        XCTAssertEqual(replacement.customTitle, "Retirement fixture")
        XCTAssertEqual(replacement.metadata["fixture"], "preserved")
        XCTAssertEqual(PanelMetadataStore.shared.getMetadata(workspaceId: replacement.id, surfaceId: newTerminal.id)
            .metadata["fixture.tag"] as? String, "preserved")
        XCTAssertEqual(publications, [[oldWorkspace.id]], "restore must publish only the replacement graph")
    }

    func testRestorePrunesDisplacedBackgroundLoads() throws {
        let manager = WorkspaceManager()
        let displaced = try XCTUnwrap(manager.selectedWorkspace)
        let source = WorkspaceManager()
        let kept = try XCTUnwrap(source.selectedWorkspace)
        manager.requestBackgroundWorkspaceLoad(for: displaced.id)
        manager.requestBackgroundWorkspaceLoad(for: kept.id)
        manager.retainDebugWorkspaceLoads(for: [displaced.id, kept.id])
        defer {
            for workspace in manager.workspaces + source.workspaces { workspace.teardownAllPanels() }
            displaced.teardownAllPanels()
        }

        manager.restoreSessionSnapshot(source.sessionSnapshot(includeScrollback: false))

        XCTAssertTrue(displaced.panels.isEmpty)
        XCTAssertNil(displaced.owningWorkspaceManager)
        XCTAssertEqual(manager.pendingBackgroundWorkspaceLoadIds, [kept.id])
        XCTAssertEqual(manager.debugPinnedWorkspaceLoadIds, [kept.id])
        XCTAssertEqual(manager.selectedWorkspaceId, kept.id)
    }

    func testEmptyRestoreRetiresRetainedGraphAndKeepsFallback() throws {
        let manager = WorkspaceManager()
        let displaced = try XCTUnwrap(manager.selectedWorkspace)
        let oldTerminal = try XCTUnwrap(displaced.focusedTerminalPanel)
        manager.requestBackgroundWorkspaceLoad(for: displaced.id)
        defer {
            for workspace in manager.workspaces { workspace.teardownAllPanels() }
            displaced.teardownAllPanels()
        }

        manager.restoreSessionSnapshot(.init(selectedWorkspaceIndex: nil, workspaces: []))

        XCTAssertTrue(displaced.panels.isEmpty)
        XCTAssertEqual(oldTerminal.surface.portalBindingStateLabel(), "closed")
        XCTAssertNil(displaced.owningWorkspaceManager)
        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNotEqual(manager.selectedWorkspaceId, displaced.id)
        XCTAssertTrue(manager.pendingBackgroundWorkspaceLoadIds.isEmpty)
        XCTAssertTrue(manager.selectedWorkspace?.owningWorkspaceManager === manager)
    }

    func testQueuedResumeDoesNotWriteIntoRetainedDisplacedTerminal() async throws {
        #if DEBUG
        guard SessionPersistencePolicy.agentRestartOnRestoreEnabled,
              !ConversationStorePolicy.isDisabled, StartupConversationAudit.shared.mode == .clean else {
            throw XCTSkip("resume scheduling is disabled by the host")
        }
        let manager = WorkspaceManager()
        let initial = try XCTUnwrap(manager.selectedWorkspace)
        let initialTerminal = try XCTUnwrap(initial.focusedTerminalPanel)
        initialTerminal.surface.useExecShellForTesting()
        let panelId = initialTerminal.id
        let sessionId = "11111111-1111-4111-8111-111111111111"
        await ConversationStore.shared.push(surfaceId: panelId.uuidString, kind: "codex", id: sessionId,
                                            source: .hook, state: .suspended)
        defer {
            for workspace in manager.workspaces { workspace.teardownAllPanels() }
            initial.teardownAllPanels()
            Task { await ConversationStore.shared.clear(surfaceId: panelId.uuidString) }
        }
        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        // Save the terminal as an exec shell. A persistent hc terminal is
        // never resumed from the snapshot (C11H-98), so without this neither
        // restore would schedule a resume and the test would prove nothing.
        var saved = 0
        for w in snapshot.workspaces.indices {
            for p in snapshot.workspaces[w].panels.indices where snapshot.workspaces[w].panels[p].id == panelId {
                var terminal = snapshot.workspaces[w].panels[p].terminal ?? SessionTerminalPanelSnapshot()
                terminal.hcIdentity = HCPanelIdentity(panelID: panelId, persistence: .nonpersistent, origin: .restored)
                snapshot.workspaces[w].panels[p].terminal = terminal
                saved += 1
            }
        }
        XCTAssertEqual(saved, 1, "fixture must save the terminal it resumes")
        manager.restoreSessionSnapshot(snapshot)
        let displaced = try XCTUnwrap(manager.selectedWorkspace)
        let oldTerminal = try XCTUnwrap(displaced.terminalPanel(for: panelId))
        defer { displaced.teardownAllPanels() }
        XCTAssertNil(oldTerminal.surface.surface, "fixture must not execute a real harness")
        XCTAssertEqual(oldTerminal.surface.pendingInitialInputForTests, "")

        manager.restoreSessionSnapshot(snapshot)
        let replacement = try XCTUnwrap(manager.selectedWorkspace?.terminalPanel(for: panelId))
        XCTAssertNil(replacement.surface.surface, "fixture must not execute a real harness")
        XCTAssertNil(replacement.hcIdentity, "the restored terminal is the saved exec shell")
        // A command decision records no outcome until its submission runs, so
        // each workspace's own outcome marks the end of its scheduled attempt.
        // Wait for both (bounded), then check what the displaced one typed.
        let bound = SessionPersistencePolicy.agentRestartDelay + 2
        let displacedDone = await waitForC11HostCondition(timeout: bound) {
            displaced.launchResumeOutcomes[panelId] != nil
        }
        XCTAssertTrue(displacedDone, "the displaced restore's scheduled resume must finish")
        let replacementDone = await waitForC11HostCondition(timeout: bound) {
            replacement.surface.pendingInitialInputForTests.contains(sessionId)
        }
        XCTAssertTrue(replacementDone, "the replacement's scheduled resume must arrive")
        if case .resumed? = displaced.launchResumeOutcomes[panelId] {
            XCTFail("the displaced restore resumed into its retained terminal")
        }

        XCTAssertEqual(oldTerminal.surface.pendingInitialInputForTests, "")
        XCTAssertFalse(oldTerminal.surface.pendingSubmitOnFlushForTests)
        XCTAssertTrue(replacement.surface.pendingInitialInputForTests.contains(sessionId),
                      "replacement must still receive its own scheduled resume")
        #else
        throw XCTSkip("pending-input observation requires Debug")
        #endif
    }

    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = WorkspaceManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(manager.selectedWorkspaceId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.workspaces.count, 2)
        XCTAssertEqual(restored.selectedWorkspaceId, restored.workspaces[1].id)
        XCTAssertEqual(restored.workspaces[0].customTitle, "First")
        XCTAssertEqual(restored.workspaces[1].customTitle, "Second")
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = WorkspaceManager()
        let emptySnapshot = SessionWorkspaceManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNotNil(manager.selectedWorkspaceId)
    }

    func testSessionSnapshotRoundtripsWorkspaceMetadata() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.setOperatorMetadata([
            WorkspaceMetadataKey.description: "Backend refactor",
            WorkspaceMetadataKey.icon: "🦊",
            "custom.tag": "v2"
        ])

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces[0].metadata?["description"], "Backend refactor")
        XCTAssertEqual(snapshot.workspaces[0].metadata?["icon"], "🦊")
        XCTAssertEqual(snapshot.workspaces[0].metadata?["custom.tag"], "v2")

        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(restored.workspaces[0].metadata["description"], "Backend refactor")
        XCTAssertEqual(restored.workspaces[0].metadata["icon"], "🦊")
        XCTAssertEqual(restored.workspaces[0].metadata["custom.tag"], "v2")
    }

    func testEmptyMetadataIsOmittedFromSnapshot() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        XCTAssertTrue(workspace.metadata.isEmpty)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(snapshot.workspaces.first?.metadata)
    }

    func testAutosaveFingerprintChangesOnMetadataValueEdit() {
        let manager = WorkspaceManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        workspace.setOperatorMetadata(["description": "one"])
        let before = manager.sessionAutosaveFingerprint()
        workspace.setOperatorMetadata(["description": "two"])
        let after = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(before, after,
            "Autosave fingerprint must change on value-only metadata edit (plan contract).")
    }

    func testAutosaveFingerprintTracksJSONOnlyAndSourceOnlyMetadataChanges() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let before = manager.sessionAutosaveFingerprint()
        try WorkspaceMetadataStore.shared.setMetadata(workspaceId: workspace.id,
            partial: ["nested": ["ready": true]], source: .osc)
        let jsonChanged = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(before, jsonChanged)
        try WorkspaceMetadataStore.shared.setMetadata(workspaceId: workspace.id,
            partial: ["nested": ["ready": true]], source: .explicit)
        XCTAssertNotEqual(jsonChanged, manager.sessionAutosaveFingerprint())
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces[0].metadataValues?["nested"], .object(["ready": .bool(true)]))
        XCTAssertEqual(snapshot.workspaces[0].metadataSources?["nested"]?.source, "explicit")
    }

    func testSessionSnapshotExcludesRemoteWorkspacesFromRestore() throws {
        let manager = WorkspaceManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let paneId = try XCTUnwrap(remoteWorkspace.bonsplitController.allPaneIds.first)
        _ = remoteWorkspace.newBrowserSurface(inPane: paneId, url: URL(string: "http://localhost:3000"), focus: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertNil(snapshot.selectedWorkspaceIndex)
        XCTAssertFalse(snapshot.workspaces.contains { $0.processTitle == remoteWorkspace.title })
    }
}

extension WorkspaceManagerSessionSnapshotTests {
    func testGroupValidationAndDeletionNeverCloseOrPartiallyMoveWorkspaces() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "  Services  ")
        let other = try manager.createWorkspaceGroup(name: "Other")
        XCTAssertEqual(group.name, "Services")
        let originalOrder = manager.workspaces.map(\.id)
        let originalPanels = manager.workspaces.map { Set($0.panels.keys) }
        let selection = manager.selectedWorkspaceId
        try manager.addWorkspacesToGroup(id: other.id, workspaceIds: [second.id])

        for request in [[first.id, first.id], [first.id, UUID()], [first.id, second.id]] {
            XCTAssertThrowsError(try manager.addWorkspacesToGroup(id: group.id, workspaceIds: request))
            XCTAssertNil(first.groupId)
            XCTAssertEqual(second.groupId, other.id)
        }
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id, third.id])
        XCTAssertThrowsError(try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id])) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .alreadyGrouped)
        }
        XCTAssertThrowsError(try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [first.id, second.id])) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .notMember)
        }
        XCTAssertEqual(first.groupId, group.id)
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: true)
        XCTAssertEqual(manager.selectedWorkspaceId, selection)
        try manager.deleteWorkspaceGroup(id: group.id)
        XCTAssertNil(first.groupId)
        XCTAssertNil(third.groupId)
        XCTAssertEqual(second.groupId, other.id)
        XCTAssertEqual(manager.workspaces.map(\.id), originalOrder)
        XCTAssertEqual(manager.workspaces.map { Set($0.panels.keys) }, originalPanels)
        XCTAssertEqual(manager.selectedWorkspaceId, selection)
    }

    func testGroupFocusRetainsSelectedMemberAndEmptyGroupReturnsError() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let group = try manager.createWorkspaceGroup(name: "Group")
        let empty = try manager.createWorkspaceGroup(name: "Empty")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id, second.id])
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        XCTAssertEqual(try manager.focusWorkspaceGroup(id: group.id), second.id)
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)
        XCTAssertFalse(try XCTUnwrap(manager.workspaceGroups.first { $0.id == group.id }).isCollapsed)
        XCTAssertThrowsError(try manager.focusWorkspaceGroup(id: empty.id)) {
            XCTAssertEqual($0 as? WorkspaceGroupOperationError, .emptyGroup)
        }
        XCTAssertEqual(manager.selectedWorkspaceId, second.id)
        try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [second.id])
        XCTAssertEqual(try manager.focusWorkspaceGroup(id: group.id), first.id)
    }

    func testBatchReorderPublishesOnceAndDryRunOrInvalidRequestsPublishNothing() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "Group")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id, third.id])
        var publications: [[UUID]] = []
        let subscription = manager.$workspaces.dropFirst().sink { publications.append($0.map(\.id)) }
        defer { subscription.cancel() }
        let plan = try manager.batchWorkspaceReorderPlan(orderedWorkspaceIds: [third.id, second.id])
        XCTAssertTrue(publications.isEmpty)
        XCTAssertThrowsError(try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [first.id, UUID()]))
        XCTAssertTrue(publications.isEmpty)
        let applied = try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [third.id, second.id])
        XCTAssertEqual(applied, plan)
        XCTAssertEqual(publications, [[third.id, second.id, first.id]])
        XCTAssertEqual(manager.selectedWorkspaceId, first.id)
        XCTAssertEqual(first.groupId, group.id)
        XCTAssertEqual(third.groupId, group.id)
        XCTAssertFalse(try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [third.id, second.id]).changed)
        XCTAssertEqual(publications.count, 1)
    }

    func testGroupAndMemberPinsAreIndependentAndDetachClearsMembership() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "Folder")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id])
        manager.setPinned(first, pinned: true)
        XCTAssertFalse(try XCTUnwrap(manager.workspaceGroups.first).isPinned)
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: true)
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: false)
        XCTAssertTrue(first.isPinned)
        try manager.moveWorkspaceToGroup(workspaceId: second.id, groupId: group.id)
        XCTAssertEqual(manager.workspaces.map(\.id), [first.id, second.id])
        let detached = try XCTUnwrap(manager.detachWorkspace(workspaceId: first.id))
        XCTAssertNil(detached.groupId)
        XCTAssertTrue(detached.isPinned)
        XCTAssertEqual(manager.workspaceGroups.count, 1)
        let destination = WorkspaceManager()
        destination.attachWorkspace(detached, select: false)
        XCTAssertNil(detached.groupId)
        XCTAssertEqual(destination.workspaces.first?.id, detached.id)
        try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [second.id])
        XCTAssertEqual(manager.workspaceGroups.count, 1)
    }

    func testGroupSnapshotMigrationRetainsSelectionAndClearsOrphans() throws {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let group = try manager.createWorkspaceGroup(name: "Services", color: "#123456", icon: "folder.fill")
        let empty = try manager.createWorkspaceGroup(name: "Empty")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [first.id])
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        var duplicate = group
        duplicate.name = "Discarded duplicate"
        snapshot.workspaceGroups?.append(duplicate)
        snapshot.workspaces[1].groupId = UUID()
        // Corrupt legacy pin order must normalize without shifting selection by index.
        snapshot.workspaces[1].isPinned = true
        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaceGroups.map(\.id), [group.id, empty.id])
        XCTAssertEqual(restored.workspaceGroups.first?.name, "Services")
        XCTAssertEqual(restored.workspaceGroups.first?.color, "#123456")
        XCTAssertEqual(restored.workspaceGroups.first?.icon, "folder.fill")
        XCTAssertEqual(restored.workspaceGroups.first?.isCollapsed, true)
        XCTAssertEqual(restored.workspaces.map(\.id), [second.id, first.id])
        XCTAssertNil(restored.workspaces.first?.groupId)
        XCTAssertEqual(restored.workspaces.last?.groupId, group.id)
        XCTAssertEqual(restored.selectedWorkspaceId, second.id)
        XCTAssertEqual(restored.sessionSnapshot(includeScrollback: false).selectedWorkspaceIndex, 0)

        // Decode an actual old workspace shape without either new key.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        old.removeValue(forKey: "workspaceGroups")
        var workspaces = try XCTUnwrap(old["workspaces"] as? [[String: Any]])
        for index in workspaces.indices { workspaces[index].removeValue(forKey: "groupId") }
        old["workspaces"] = workspaces
        let oldSnapshot = try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        restored.restoreSessionSnapshot(oldSnapshot)
        XCTAssertTrue(restored.workspaceGroups.isEmpty)
        XCTAssertTrue(restored.workspaces.allSatisfy { $0.groupId == nil })
        XCTAssertEqual(Set(restored.workspaces.map(\.id)), Set([first.id, second.id]))
    }

    /// C11H-299: the manager registers, saves, restores and drops a group's
    /// object; a write after restore reaches the restored group.
    func testGroupObjectLifecycleThroughSessionSnapshotAndRestore() throws {
        let store = WorkspaceMetadataStore.groups
        let manager = WorkspaceManager()
        let member = try XCTUnwrap(manager.selectedWorkspace)
        let group = try manager.createWorkspaceGroup(name: "Acme")
        XCTAssertTrue(store.contains(workspaceId: group.id), "a created group accepts writes")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [member.id])
        let before = manager.sessionAutosaveFingerprint()
        try store.setMetadata(workspaceId: group.id, partial: ["captain": "acme-captain"])
        XCTAssertNotEqual(manager.sessionAutosaveFingerprint(), before, "a group-object edit reaches autosave")
        let saved = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(saved.workspaceGroupMetadata?[group.id.uuidString]?.metadataValues?["captain"], .string("acme-captain"))

        // A relaunch starts with an empty store; the snapshot alone must
        // bring the object back and register the group for writes.
        store.removeWorkspace(workspaceId: group.id)
        XCTAssertFalse(store.contains(workspaceId: group.id))
        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self,
                                                                 from: JSONEncoder().encode(saved)))
        XCTAssertEqual(store.getMetadata(workspaceId: group.id).metadata["captain"] as? String, "acme-captain")
        XCTAssertTrue(store.contains(workspaceId: group.id), "a restored group is registered for writes")
        try store.setMetadata(workspaceId: group.id, partial: ["captain": "next-captain"], requireRegistered: true)
        XCTAssertEqual(restored.sessionSnapshot(includeScrollback: false)
            .workspaceGroupMetadata?[group.id.uuidString]?.metadataValues?["captain"], .string("next-captain"))

        try restored.deleteWorkspaceGroup(id: group.id)
        XCTAssertFalse(store.contains(workspaceId: group.id), "a deleted group's object goes with it")
        XCTAssertNil(store.getMetadata(workspaceId: group.id).metadata["captain"])
        XCTAssertNil(restored.sessionSnapshot(includeScrollback: false).workspaceGroupMetadata)
        try? manager.deleteWorkspaceGroup(id: group.id)
    }

    func testEveryFolderPropertyAndMembershipChangeTriggersAutosaveFingerprint() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var previous = manager.sessionAutosaveFingerprint()
        func assertChanged() {
            let current = manager.sessionAutosaveFingerprint()
            XCTAssertNotEqual(current, previous)
            previous = current
        }
        let group = try manager.createWorkspaceGroup(name: "One")
        assertChanged()
        try manager.renameWorkspaceGroup(id: group.id, name: "Two")
        assertChanged()
        try manager.setWorkspaceGroupColor(id: group.id, color: "#abcdef")
        assertChanged()
        try manager.setWorkspaceGroupIcon(id: group.id, icon: "folder.fill")
        assertChanged()
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        assertChanged()
        try manager.setWorkspaceGroupPinned(id: group.id, pinned: true)
        assertChanged()
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [workspace.id])
        assertChanged()
        try manager.removeWorkspacesFromGroup(id: group.id, workspaceIds: [workspace.id])
        assertChanged()
        try manager.deleteWorkspaceGroup(id: group.id)
        assertChanged()
    }

    func testSelectedSubsetResumePreservesWindowGroupsAndKeptMembership() throws {
        let manager = WorkspaceManager()
        let skipped = try XCTUnwrap(manager.selectedWorkspace)
        let kept = manager.addWorkspace(select: true)
        let ungrouped = manager.addWorkspace(select: false)
        let folder = try manager.createWorkspaceGroup(name: "Services", color: "#123456", icon: "folder.fill")
        let empty = try manager.createWorkspaceGroup(name: "Empty")
        try manager.addWorkspacesToGroup(id: folder.id, workspaceIds: [skipped.id, kept.id])
        try manager.setWorkspaceGroupCollapsed(id: folder.id, collapsed: true)
        try manager.setWorkspaceGroupPinned(id: folder.id, pinned: true)
        let saved = manager.sessionSnapshot(includeScrollback: false)
        let window = SessionWindowSnapshot(
            frame: nil, display: nil, workspaceManager: saved,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        // An entirely unselected window should still be discarded.
        var otherWindow = window
        otherWindow.workspaceManager.workspaces = [saved.workspaces[0]]
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 123,
            windows: [window, otherWindow]
        )
        let filtered = try XCTUnwrap(LaunchResumePicker.filtered(snapshot: snapshot, keep: [kept.id, ungrouped.id]))
        XCTAssertEqual(filtered.windows.count, 1)
        let selectedSubset = try XCTUnwrap(filtered.windows.first).workspaceManager
        XCTAssertEqual(selectedSubset.workspaces.map(\.id), [kept.id, ungrouped.id])
        XCTAssertEqual(selectedSubset.selectedWorkspaceIndex, 0)
        XCTAssertEqual(selectedSubset.workspaceGroups, saved.workspaceGroups)

        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(selectedSubset)
        XCTAssertEqual(restored.workspaces.map(\.id), [kept.id, ungrouped.id])
        XCTAssertEqual(restored.workspaces.first?.groupId, folder.id)
        XCTAssertNil(restored.workspaces.last?.groupId)
        XCTAssertEqual(restored.workspaceGroups, saved.workspaceGroups)
        XCTAssertEqual(restored.workspaceGroups.map(\.id), [folder.id, empty.id])
        XCTAssertEqual(restored.selectedWorkspaceId, kept.id)

        // Selecting only an ungrouped workspace leaves folders empty, not lost.
        let onlyUngrouped = try XCTUnwrap(LaunchResumePicker.filtered(snapshot: snapshot, keep: [ungrouped.id]))
        restored.restoreSessionSnapshot(try XCTUnwrap(onlyUngrouped.windows.first).workspaceManager)
        XCTAssertEqual(restored.workspaces.map(\.id), [ungrouped.id])
        XCTAssertNil(restored.workspaces.first?.groupId)
        XCTAssertEqual(restored.workspaceGroups, saved.workspaceGroups)
        XCTAssertEqual(restored.selectedWorkspaceId, ungrouped.id)
        XCTAssertNil(LaunchResumePicker.filtered(snapshot: snapshot, keep: []))
    }

}

extension WorkspaceManagerSessionSnapshotTests {
    func testRestoredDelegateKeepsWorkspaceProjection() throws {
        _ = NSApplication.shared
        let hostDelegateBeforeFixture = AppDelegate.shared
        let hostControllerManagerBeforeFixture = TerminalController.shared.workspaceManager
        defer {
            AppDelegate.shared = hostDelegateBeforeFixture
            TerminalController.shared.workspaceManager = hostControllerManagerBeforeFixture
        }
        let app = AppDelegate()
        let source = WorkspaceManager()
        let sourceWorkspace = try XCTUnwrap(source.selectedWorkspace)
        let owner = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel)
        sourceWorkspace.setPanelCustomTitle(panelId: owner.id, title: "Planner")
        let delegate = try XCTUnwrap(
            sourceWorkspace.newTerminalSplit(from: owner.id, orientation: .horizontal)
        )
        _ = try PanelMetadataStore.shared.mutateAttention(
            workspaceId: sourceWorkspace.id,
            surfaceId: delegate.id,
            delegation: .delegate(ownerPanelId: owner.id)
        )
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        sourceWorkspace.teardownAllPanels(markPanelsClosedForGood: false)

        let manager = WorkspaceManager()
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        app.registerMainWindow(
            window,
            windowId: windowId,
            workspaceManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            app.debugUnregisterMainWindow(window)
            window.orderOut(nil)
            for workspace in manager.workspaces { workspace.teardownAllPanels() }
            sourceWorkspace.teardownAllPanels(markPanelsClosedForGood: false)
            PanelMetadataStore.shared.removeWorkspace(workspaceId: sourceWorkspace.id)
            PanelAttentionIndex.shared.prune(workspaceId: sourceWorkspace.id, validSurfaceIds: [])
        }

        manager.restoreSessionSnapshot(snapshot)

        let restored = try XCTUnwrap(manager.workspaces.first { $0.id == sourceWorkspace.id })
        XCTAssertEqual(
            PanelMetadataStore.shared.attentionSnapshot(
                workspaceId: restored.id,
                surfaceId: delegate.id
            ).delegatedBy,
            owner.id
        )
        XCTAssertTrue(PanelAttentionIndex.shared.snapshot(
            workspaceId: restored.id,
            surfaceId: delegate.id
        ).delegated)
        XCTAssertTrue(restored.attentionSnapshot(panelId: delegate.id).delegated)
        XCTAssertEqual(
            restored.resolvedSurfacePanelActivityState(
                panelId: delegate.id,
                hasExactSurfaceNotification: true
            ),
            .idle,
            "a restored delegate's routine stop remains quiet"
        )

        let livePanelIds = Set(manager.workspaces.flatMap { $0.panels.keys })
        PanelAttentionService.shared.releaseDelegatesWithMissingOwners(livePanelIds: livePanelIds)
        XCTAssertEqual(restored.delegationOwnerTitlesByPanel[delegate.id], "Planner")

        // The explicit startup observer must route a permanent owner close
        // through the service, clear delegation, and make the retained wait gold.
        PanelLineage.shared.panelClosedForGood(owner.id)
        XCTAssertFalse(restored.attentionSnapshot(panelId: delegate.id).delegated)
        XCTAssertEqual(
            restored.resolvedSurfacePanelActivityState(
                panelId: delegate.id,
                hasExactSurfaceNotification: true
            ),
            .waiting
        )
    }

    func testCollapsedGroupProductionAdapterExcludesSuppressedRoutineUnreadButRetainsFlags() throws {
        let manager = WorkspaceManager()
        let plainFlagged = try XCTUnwrap(manager.selectedWorkspace)
        let suppressed = manager.addWorkspace(select: false)
        let waiting = manager.addWorkspace(select: false)
        let members = [plainFlagged, suppressed, waiting]
        let panelIds = try members.map { try XCTUnwrap($0.focusedPanelId) }
        let group = try manager.createWorkspaceGroup(name: "Unread fixture")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: members.map(\.id))
        try manager.setWorkspaceGroupCollapsed(id: group.id, collapsed: true)
        plainFlagged.setDetectedTerminalType("shell", forSurface: panelIds[0])
        waiting.setDetectedTerminalType("codex", forSurface: panelIds[2])
        XCTAssertFalse(AreaSizePolicy.isAgentKind(plainFlagged.surfaceActivityTerminalKind(panelId: panelIds[0])))

        // Seed the real index and workspace projections, as production attention delivery does.
        // Suppressed routine unread stays in history but must not reach the header.
        // A suppressed explicit flag remains signal eligible, exactly like a row.
        for index in 0..<2 {
            let snapshot = PanelAttentionSnapshot(workspaceId: members[index].id, surfaceId: panelIds[index],
                flagReason: index == 0 ? "Synthetic flag" : nil,
                flagRaisedAt: index == 0 ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
                suppressed: true)
            PanelAttentionIndex.shared.publish(snapshot)
            members[index].setAttentionSnapshot(snapshot, forSurface: panelIds[index])
        }
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var pending: [@MainActor () -> Void] = []
        let coordinator = WorkspaceGroupSidebarCoordinator(scheduleRefresh: { pending.append($0) })
        defer {
            coordinator.detach()
            for (workspace, panelId) in zip(members, panelIds) {
                PanelAttentionIndex.shared.remove(workspaceId: workspace.id, surfaceId: panelId)
                workspace.teardownAllPanels()
            }
        }
        func flushRefresh() {
            let work = pending
            pending.removeAll()
            for refresh in work { refresh() }
        }
        func notification(workspaceId: UUID, panelId: UUID?) -> TerminalNotification {
            TerminalNotification(id: UUID(), workspaceId: workspaceId, surfaceId: panelId,
                title: "Synthetic unread", subtitle: "", body: "", createdAt: Date(), isRead: false)
        }
        let notifications = zip(members, panelIds).map { notification(workspaceId: $0.0.id, panelId: $0.1) }
        coordinator.attach(manager: manager, notificationStore: store)
        store.replaceNotificationsForTesting(notifications)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary.unreadCount, 0,
                       "The coordinator must wait for the store's didSet index rebuild")
        flushRefresh()
        XCTAssertEqual(store.unreadCount, 2, "Suppressed unflagged notification is excluded only from signal demand")
        XCTAssertEqual(members.map { store.rawUnreadCount(forWorkspaceId: $0.id) }, [1, 1, 1])
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary,
                       WorkspaceGroupHeaderSummary(memberCount: 3, flaggedCount: 1, waitingCount: 1, unreadCount: 2))
        XCTAssertTrue(coordinator.projection.visibleWorkspaceIds.isEmpty)
        XCTAssertEqual(store.rawUnreadCount(forWorkspaceId: UUID()), 0)

        let workspaceScoped = notification(workspaceId: waiting.id, panelId: nil)
        store.replaceNotificationsForTesting(notifications + [workspaceScoped])
        flushRefresh()
        XCTAssertEqual(store.rawUnreadCount(forWorkspaceId: waiting.id), 2)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary,
                       WorkspaceGroupHeaderSummary(memberCount: 3, flaggedCount: 1, waitingCount: 1, unreadCount: 3))

        // Reading a suppressed notification changes raw history even though eligible demand stays unchanged.
        let eligibleBeforeRead = store.unreadCount
        store.markRead(id: notifications[1].id)
        flushRefresh()
        XCTAssertEqual(store.unreadCount, eligibleBeforeRead)
        XCTAssertEqual(store.rawUnreadCount(forWorkspaceId: suppressed.id), 0)
        XCTAssertEqual(coordinator.projection.headersById[group.id]?.summary,
                       WorkspaceGroupHeaderSummary(memberCount: 3, flaggedCount: 1, waitingCount: 1, unreadCount: 3))
    }
}

/// C11H-342: the manager keeps one root order for groups and ungrouped workspaces.
extension WorkspaceManagerSessionSnapshotTests {
    private func rootFixture() throws -> (WorkspaceManager, first: Workspace, second: Workspace, third: Workspace,
                                          member: Workspace, group: WorkspaceGroup) {
        let manager = WorkspaceManager()
        let first = try XCTUnwrap(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let member = manager.addWorkspace(select: false)
        let group = try manager.createWorkspaceGroup(name: "Fleet")
        try manager.addWorkspacesToGroup(id: group.id, workspaceIds: [member.id])
        XCTAssertEqual(manager.workspaceRootEntries.first?.id, group.id, "groups first until something moves")
        // Lay out first, second, Fleet, third.
        try manager.moveWorkspaceToGroup(workspaceId: first.id, groupId: nil, before: group.id)
        try manager.moveWorkspaceToGroup(workspaceId: second.id, groupId: nil, after: first.id)
        try manager.moveWorkspaceToGroup(workspaceId: third.id, groupId: nil, after: group.id)
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [first.id, second.id, group.id, third.id])
        return (manager, first, second, third, member, group)
    }

    func testRootOrderSurvivesSaveAndRestoreAndAnOlderSnapshotDrawsGroupsFirst() throws {
        let (manager, _, _, _, _, group) = try rootFixture()
        let drawn = manager.workspaceRootEntries.map(\.id)
        let saved = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(saved.workspaceRootOrder, drawn)
        let restored = WorkspaceManager()
        restored.restoreSessionSnapshot(try JSONDecoder().decode(SessionWorkspaceManagerSnapshot.self,
                                                                 from: JSONEncoder().encode(saved)))
        XCTAssertEqual(restored.workspaceRootEntries.map(\.id), drawn)
        var older = saved
        older.workspaceRootOrder = nil
        let legacy = WorkspaceManager()
        legacy.restoreSessionSnapshot(older)
        XCTAssertEqual(legacy.workspaceRootEntries.map(\.id),
                       [group.id] + older.workspaces.filter { $0.groupId == nil }.map(\.id),
                       "a session saved before the root order draws groups first, as it did")
    }

    func testFlatMovesToTheTopCarryNoGroupAlong() throws {
        let (manager, first, second, third, _, group) = try rootFixture()
        manager.moveWorkspaceToTopForNotification(second.id)
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [second.id, first.id, group.id, third.id])
        manager.moveWorkspacesToTop([third.id])
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [third.id, second.id, first.id, group.id])
        _ = try manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: [first.id])
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [first.id, third.id, second.id, group.id])
    }

    /// REPAIR-1: the palette's and the menu's Move Up/Down call exactly these two
    /// methods, for the action and for its enablement.
    func testMoveUpDownEnablementAndActionPassAGroupThatIsTheOnlyNeighbour() throws {
        let manager = WorkspaceManager()
        let only = try XCTUnwrap(manager.selectedWorkspace)
        let group = try manager.createWorkspaceGroup(name: "Empty")
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [group.id, only.id])
        XCTAssertEqual(manager.workspaces.firstIndex { $0.id == only.id }, 0, "flat index 0: the old check disabled Move Up")
        XCTAssertTrue(manager.canStepWorkspaceInSidebar(only.id, by: -1))
        XCTAssertFalse(manager.canStepWorkspaceInSidebar(only.id, by: 1))
        XCTAssertTrue(manager.stepWorkspaceInSidebar(only.id, by: -1))
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [only.id, group.id])
        XCTAssertFalse(manager.canStepWorkspaceInSidebar(only.id, by: -1))
        XCTAssertTrue(manager.canStepWorkspaceInSidebar(only.id, by: 1), "flat-last: the old check disabled Move Down")
        XCTAssertFalse(manager.stepWorkspaceInSidebar(only.id, by: -1))
    }

    func testDeletedGroupsMembersTakeItsPlaceAndStepsPassAGroup() throws {
        let (manager, first, second, third, member, group) = try rootFixture()
        XCTAssertTrue(manager.stepWorkspaceInSidebar(third.id, by: -1))
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [first.id, second.id, third.id, group.id])
        XCTAssertTrue(manager.stepWorkspaceInSidebar(third.id, by: 1))
        try manager.deleteWorkspaceGroup(id: group.id)
        XCTAssertEqual(manager.workspaceRootEntries.map(\.id), [first.id, second.id, member.id, third.id])
        XCTAssertNil(member.groupId)
    }
}
