import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Coverage for the "Show surface IDs in tab titles" feature: the
/// `TabOrdinalDisplaySettings` resolver, eager `surface:N` ordinal minting,
/// the "N: title" prefix composition, and the ref field on the M7
/// title-bar socket payload.
@MainActor
final class PanelOrdinalDisplayTests: XCTestCase {

    private func call(_ controller: TerminalController, _ method: String,
                      _ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": 156, "method": method, "params": params])
        let command = String(decoding: data, as: UTF8.self)
        let response = await Task.detached {
            controller.processCommandUsingSocketExecutionPolicy(command)
        }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    // MARK: - Settings resolver

    func testShowsSurfaceIdsDefaultsToTrueWhenUnset() {
        let suite = "TabOrdinalDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(PanelOrdinalDisplaySettings.showsSurfaceIds(defaults: defaults))
    }

    func testShowsSurfaceIdsRespectsExplicitValues() {
        let suite = "TabOrdinalDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: PanelOrdinalDisplaySettings.showSurfaceIdsInPanelTitlesKey)
        XCTAssertTrue(PanelOrdinalDisplaySettings.showsSurfaceIds(defaults: defaults))

        defaults.set(false, forKey: PanelOrdinalDisplaySettings.showSurfaceIdsInPanelTitlesKey)
        XCTAssertFalse(PanelOrdinalDisplaySettings.showsSurfaceIds(defaults: defaults))
    }

    // MARK: - Ordinal minting

    func testSurfaceOrdinalMintsSequentiallyAndIsStablePerSurface() {
        // Panel numbers are durable (C11H-23): a fresh registry, so this test
        // does not see numbers other tests minted in the shared one.
        let controller = TerminalController.makeForTesting(panelAllocations: PanelAllocationRegistry(fileURL: nil))
        let a = UUID()
        let b = UUID()

        let first = controller.surfaceOrdinal(forSurfaceUUID: a)
        let second = controller.surfaceOrdinal(forSurfaceUUID: b)

        XCTAssertEqual(first, 1, "A fresh controller numbers its first surface 1")
        XCTAssertEqual(second, 2, "Ordinals are minted in creation order")
        XCTAssertEqual(controller.surfaceOrdinal(forSurfaceUUID: a), first,
                       "Re-asking for a surface's ordinal must not re-mint")
        XCTAssertEqual(controller.surfaceRefOnly(forSurfaceUUID: a), "panel:\(first)",
                       "The displayed number is the N of the panel:N handle")
    }

    func testSurfaceOrdinalMatchesRefResolution() {
        let controller = TerminalController.makeForTesting(panelAllocations: PanelAllocationRegistry(fileURL: nil))
        let uuid = UUID()
        let ordinal = controller.surfaceOrdinal(forSurfaceUUID: uuid)

        XCTAssertEqual(controller.v2ResolveHandleRef("surface:\(ordinal)"), uuid,
                       "The spoken number must resolve back to the same surface")
        XCTAssertEqual(controller.v2ResolveHandleRef("tab:\(ordinal)"), uuid,
                       "tab:N and the legacy surface:N are the same handle")
        XCTAssertEqual(controller.v2ResolveHandleRef("panel:\(ordinal)"), uuid,
                       "panel:N is the canonical spelling of the same handle")
    }

    func testSurfaceRefStaysStableAcrossSiblingCreateAndClose() async throws {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        let registry = PanelAllocationRegistry(fileURL: nil)
        PanelLineage.shared.addPanelClosedForGoodObserver { [weak registry] ids in
            MainActor.assumeIsolated { registry?.releasePanels(ids) }
        }
        let controller = TerminalController.makeForTesting(panelAllocations: registry)
        controller.setActiveWorkspaceManager(manager)
        let target = try XCTUnwrap(workspace.focusedPanelId)

        let targetRef = controller.surfaceRefOnly(forSurfaceUUID: target)
        var siblings: [(id: UUID, ref: String)] = []
        for _ in 0..<2 {
            let created = try await call(controller, "panel.create", [
                "workspace_id": workspace.id.uuidString,
                "type": "terminal",
            ])
            XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
            let result = try XCTUnwrap(created["result"] as? [String: Any])
            let panelId = try XCTUnwrap(UUID(uuidString: (result["panel_id"] as? String)
                ?? (result["surface_id"] as? String ?? "")))
            siblings.append((panelId, controller.surfaceRefOnly(forSurfaceUUID: panelId)))
        }

        for sibling in siblings {
            let close = controller.v2PanelClose(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": sibling.id.uuidString,
            ])
            guard case .ok = close else {
                XCTFail("Closing a sibling failed: \(close)")
                return
            }

            let later = try await call(controller, "panel.create", [
                "workspace_id": workspace.id.uuidString,
                "type": "terminal",
            ])
            XCTAssertEqual(later["ok"] as? Bool, true, "\(later)")
            let laterResult = try XCTUnwrap(later["result"] as? [String: Any])
            let laterId = try XCTUnwrap(UUID(uuidString: (laterResult["panel_id"] as? String)
                ?? (laterResult["surface_id"] as? String ?? "")))
            XCTAssertFalse(siblings.map(\.ref).contains(controller.surfaceRefOnly(forSurfaceUUID: laterId)),
                           "A later sibling must not inherit a closed sibling's ref")
        }

        XCTAssertEqual(controller.surfaceRefOnly(forSurfaceUUID: target), targetRef,
                       "Creating or closing siblings must not change a live panel's ref")
    }

    // MARK: - Prefix composition

    func testOrdinalPrefixedComposesOnlyWhenShownAndPresent() {
        XCTAssertEqual(TitleFormatting.ordinalPrefixed(ordinal: 7, title: "agent", show: true), "7: agent")
        XCTAssertEqual(TitleFormatting.ordinalPrefixed(ordinal: 7, title: "agent", show: false), "agent")
        XCTAssertEqual(TitleFormatting.ordinalPrefixed(ordinal: nil, title: "agent", show: true), "agent")
    }

    // MARK: - Workspace wiring

    func testNewWorkspaceTabCarriesItsSurfaceOrdinal() {
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)

        let bonsplitTabIds = workspace.bonsplitController.allTabIds
        XCTAssertFalse(bonsplitTabIds.isEmpty, "A new workspace has an initial terminal tab")

        for bonsplitTabId in bonsplitTabIds {
            guard let panelId = workspace.tabIdFromBonsplitTabId(bonsplitTabId) else {
                XCTFail("Tab \(bonsplitTabId) has no panel mapping")
                continue
            }
            let expected = TerminalController.shared.surfaceOrdinal(forSurfaceUUID: panelId)
            XCTAssertEqual(workspace.bonsplitController.tab(bonsplitTabId)?.displayOrdinal, expected,
                           "Every tab is numbered with its surface:N ordinal at creation")
        }
    }

    // MARK: - Live-toggle observer

    func testObserverFiresOnKeyChange() {
        let suite = "TabOrdinalDisplayTests.observer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fired = expectation(description: "onChange fired")
        let observer = PanelOrdinalDisplayObserver(defaults: defaults) {
            fired.fulfill()
        }

        defaults.set(true, forKey: PanelOrdinalDisplaySettings.showSurfaceIdsInPanelTitlesKey)
        wait(for: [fired], timeout: 2.0)
        _ = observer
    }
}
