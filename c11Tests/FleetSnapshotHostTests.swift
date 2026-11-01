import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class FleetSnapshotHostTests: XCTestCase {
    private var previousApp: AppDelegate?
    private var previousManager: WorkspaceManager?
    private var app: AppDelegate!
    private var windows: [NSWindow] = []
    private var managers: [WorkspaceManager] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousApp = AppDelegate.shared
        previousManager = TerminalController.shared.workspaceManager
        app = AppDelegate()
        AppDelegate.shared = app
    }

    override func tearDown() {
        for window in windows { app.debugUnregisterMainWindow(window); window.close() }
        for manager in managers { for workspace in manager.workspaces { workspace.teardownAllPanels() } }
        windows = []; managers = []
        AppDelegate.shared = previousApp
        TerminalController.shared.workspaceManager = previousManager
        app = nil
        super.tearDown()
    }

    private func addWindow() -> (UUID, WorkspaceManager) {
        let id = UUID()
        let manager = WorkspaceManager()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("c11.main.\(id.uuidString)")
        app.registerMainWindow(window, windowId: id, workspaceManager: manager,
                               sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
        windows.append(window); managers.append(manager)
        return (id, manager)
    }

    private func agent(_ workspace: Workspace, panel: UUID? = nil, model: String? = "fleet-fixture") throws -> UUID {
        let id = try XCTUnwrap(panel ?? workspace.focusedPanelId)
        var values: [String: Any] = [MetadataKey.terminalType: "claude-code", MetadataKey.description: "fixture description",
                                     MetadataKey.mailboxAddress: "fleet-\(id.uuidString)"]
        if let model { values[MetadataKey.model] = model }
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: id,
                                                       partial: values, mode: .merge, source: .explicit)
        workspace.setDerivedActivity(.working, forSurface: id)
        return id
    }

    private func envelope(_ encoded: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
    }

    private func request() async throws -> [String: Any] {
        let controller = TerminalController.shared
        let response = await Task.detached {
            controller.processCommandUsingSocketExecutionPolicy(#"{"id":549,"method":"system.fleet","params":{}}"#)
        }.value
        let reply = try envelope(response)
        XCTAssertEqual(reply["ok"] as? Bool, true, response)
        return try XCTUnwrap(reply["result"] as? [String: Any])
    }

    func testAllWindowsHiddenWorkspacesSourceParityAndReadOnlyLoop() async throws {
        let (firstWindow, firstManager) = addWindow()
        let (secondWindow, secondManager) = addWindow()
        let first = try XCTUnwrap(firstManager.selectedWorkspace)
        let hidden = firstManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let background = try XCTUnwrap(secondManager.selectedWorkspace)
        let a = try agent(first)
        let b = try agent(hidden)
        let c = try agent(background, model: nil)
        let pane = try XCTUnwrap(first.bonsplitController.focusedPaneId)
        let plain = try XCTUnwrap(first.newTerminalSurface(inPane: pane, focus: false))
        let browser = try XCTUnwrap(first.newBrowserSurface(inPane: pane, focus: false, pendingHibernate: true))
        let markdown = try XCTUnwrap(first.newMarkdownPanel(inPane: pane, focus: false))
        // Even forged agent metadata must not turn a browser/markdown into an agent terminal.
        _ = try agent(first, panel: browser.id)
        _ = try agent(first, panel: markdown.id)
        let child = try XCTUnwrap(PanelLineage.shared.withCreator(a) {
            hidden.newTerminalSurface(inPane: hidden.bonsplitController.focusedPaneId!, focus: false)
        })
        let d = try agent(hidden, panel: child.id)
        _ = try PanelMetadataStore.shared.mutateAttention(workspaceId: hidden.id, surfaceId: b,
            flag: .raise("review ready", kind: PanelFlagKind(id: "merge-issue", name: "Merge Issue", color: .red, emoji: nil)),
            delegation: .delegate(ownerPanelId: a), callerPanelId: a)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        PanelSeenTracker.shared.seed(panelId: b, at: stamp)
        PromptCacheReportStore.shared.record(.request(.init(at: Date(), provider: "anthropic", model: "fixture",
            inputTokens: 10, cacheReadTokens: 100, cacheWriteTokens: 0, ttl: 3600)), panelId: b)
        defer { PromptCacheReportStore.shared.remove(panelId: b) }
        let controller = TerminalController.shared
        let tree = controller.v2TreeWorkspaceNode(workspace: hidden, index: 1, selected: false)
        let treePanels = (tree["areas"] as? [[String: Any]] ?? []).flatMap { $0["panels"] as? [[String: Any]] ?? [] }
        let treeB = try XCTUnwrap(treePanels.first { $0["id"] as? String == b.uuidString })
        let mdReply = try envelope(controller.v2DispatchSurface("panel.get_metadata", id: 1,
            params: ["workspace_id": hidden.id.uuidString, "surface_id": b.uuidString]))
        let metadata = try XCTUnwrap((mdReply["result"] as? [String: Any])?["metadata"] as? [String: Any])
        let attention = PanelMetadataStore.shared.attentionSnapshot(workspaceId: hidden.id, surfaceId: b)
        let selected = managers.map(\.selectedWorkspaceId)
        let focused = [first, hidden, background].map(\.focusedPanelId)
        let fixturePanels = [(first, a), (hidden, b), (background, c), (hidden, d),
                             (first, plain.id), (first, browser.id), (first, markdown.id)]
        let beforeMetadata = fixturePanels.map {
            PanelMetadataStore.shared.getMetadata(workspaceId: $0.0.id, surfaceId: $0.1).metadata as NSDictionary
        }
        let unread = MailboxBadgeStore.shared.knownSummary(panelId: b)?.unread
        let tracked = MailboxBadgeStore.shared.isTracking(panelId: b)
        for _ in 0..<20 {
            let doc = try await request()
            XCTAssertEqual(doc["schema_version"] as? Int, 1)
            XCTAssertEqual(doc["serialization_on_main_thread"] as? Bool, false)
            let panels = try XCTUnwrap(doc["panels"] as? [[String: Any]])
            XCTAssertEqual(Set(panels.compactMap { $0["panel_id"] as? String }), Set([a,b,c,d].map(\.uuidString)))
            XCTAssertFalse(panels.contains { $0["panel_id"] as? String == plain.id.uuidString })
            let row = try XCTUnwrap(panels.first { $0["panel_id"] as? String == b.uuidString })
            XCTAssertEqual(row["window_id"] as? String, firstWindow.uuidString)
            XCTAssertEqual(row["workspace_title"] as? String, tree["title"] as? String)
            XCTAssertEqual(row["panel_title"] as? String, treeB["title"] as? String)
            XCTAssertEqual(row["last_seen_at"] as? String, treeB["last_seen_at"] as? String)
            XCTAssertEqual(row["being_seen"] as? Bool, treeB["being_seen"] as? Bool)
            XCTAssertEqual(row["description"] as? String, metadata[MetadataKey.description] as? String)
            XCTAssertEqual(row["model"] as? String, metadata[MetadataKey.model] as? String)
            XCTAssertEqual(row["flag_reason"] as? String, metadata[MetadataKey.flag] as? String)
            XCTAssertEqual(row["delegated"] as? Bool, true)
            XCTAssertEqual(row["delegated_by"] as? String, a.uuidString)
            XCTAssertEqual(row["mailbox_address"] as? String, metadata[MetadataKey.mailboxAddress] as? String)
            XCTAssertEqual(row["mailbox_unread_count"] as? Int, unread)
            XCTAssertEqual((row["prompt_cache"] as? NSDictionary), treeB["prompt_cache"] as? NSDictionary)
            XCTAssertTrue((row["flag_kind"] as? [String: Any])?["emoji"] is NSNull)
            let childRow = try XCTUnwrap(panels.first { $0["panel_id"] as? String == d.uuidString })
            XCTAssertEqual(childRow["parent_panel_id"] as? String, a.uuidString)
            let unknown = try XCTUnwrap(panels.first { $0["panel_id"] as? String == c.uuidString })
            XCTAssertEqual(unknown["window_id"] as? String, secondWindow.uuidString)
            for field in ["model", "model_label", "flag_reason", "flag_kind", "delegated_by", "parent_panel_id", "last_turn_end", "prompt_cache"] {
                XCTAssertTrue(unknown[field] is NSNull, field)
            }
        }
        XCTAssertEqual(managers.map(\.selectedWorkspaceId), selected)
        XCTAssertEqual([first, hidden, background].map(\.focusedPanelId), focused)
        for (index, fixture) in fixturePanels.enumerated() {
            XCTAssertEqual(PanelMetadataStore.shared.getMetadata(workspaceId: fixture.0.id, surfaceId: fixture.1).metadata as NSDictionary,
                           beforeMetadata[index], "fleet changed fixture panel \(fixture.1)")
        }
        XCTAssertEqual(PanelMetadataStore.shared.attentionSnapshot(workspaceId: hidden.id, surfaceId: b), attention)
        XCTAssertEqual(PanelSeenTracker.shared.storedLastSeenAt(panelId: b), stamp)
        XCTAssertEqual(MailboxBadgeStore.shared.isTracking(panelId: b), tracked)
        XCTAssertEqual(MailboxBadgeStore.shared.knownSummary(panelId: b)?.unread, unread)
    }

    func testCopiedRecordsSurviveCloseAndCreationBeforeSerialization() async throws {
        let (_, manager) = addWindow()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let id = try agent(workspace)
        let captured = TerminalController.shared.captureFleetSnapshot()
        workspace.teardownAllPanels()
        let created = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let newId = try agent(created)
        let before = await Task.detached { captured.document() }.value
        let old = try XCTUnwrap((before["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(old["panel_id"] as? String, id.uuidString)
        XCTAssertEqual(old["description"] as? String, "fixture description")
        let after = try await request()
        XCTAssertEqual((after["panels"] as? [[String: Any]])?.compactMap { $0["panel_id"] as? String }, [newId.uuidString])
    }

    func testUnreadCountMatchesRealMailboxAndUnknownDoesNotStartTracking() async throws {
        let (_, manager) = addWindow()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let known = try agent(workspace)
        let other = try XCTUnwrap(workspace.newTerminalSurface(inPane: workspace.bonsplitController.focusedPaneId!, focus: false))
        let unknown = try agent(workspace, panel: other.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let badges = MailboxBadgeStore(mailboxesRoot: { _ in root })
        defer { badges.forget(panelId: known); try? FileManager.default.removeItem(at: root) }
        let inbox = try XCTUnwrap(badges.inboxURL(workspaceId: workspace.id, panelId: known))
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = MailboxULID.encode(timestampMs: 1_700_000_000_000,
                                    random: [UInt8](repeating: 7, count: MailboxULID.randomByteCount))
        let message: [String: Any] = ["version": 1, "id": id, "from": "fixture", "body": "unread"]
        try JSONSerialization.data(withJSONObject: message).write(to: inbox.appendingPathComponent("\(id).msg"))
        badges.track(panelId: known, workspaceId: workspace.id)
        let deadline = Date().addingTimeInterval(5)
        while badges.knownSummary(panelId: known) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(badges.knownSummary(panelId: known)?.unread, 1)
        let existing = MailboxPanelMail.summary(inbox: inbox)
        for _ in 0..<20 {
            let copy = TerminalController.shared.captureFleetSnapshot(mailboxBadges: badges)
            let document = await Task.detached { copy.document() }.value
            let rows = try XCTUnwrap(document["panels"] as? [[String: Any]])
            XCTAssertEqual(rows.first { $0["panel_id"] as? String == known.uuidString }?["mailbox_unread_count"] as? Int,
                           existing.unread)
            XCTAssertTrue(rows.first { $0["panel_id"] as? String == unknown.uuidString }?["mailbox_unread_count"] is NSNull)
        }
        XCTAssertEqual(MailboxPanelMail.summary(inbox: inbox), existing)
        XCTAssertEqual(badges.knownSummary(panelId: known), existing)
        XCTAssertFalse(badges.isTracking(panelId: unknown))
    }

    func testUnknownCacheHasExplicitNullsAndDetectedShellIsExcluded() async throws {
        let (_, manager) = addWindow()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let id = try agent(workspace)
        PromptCacheReportStore.shared.record(.unknown, panelId: id)
        defer { PromptCacheReportStore.shared.remove(panelId: id) }
        let first = try await request()
        let row = try XCTUnwrap((first["panels"] as? [[String: Any]])?.first)
        let cache = try XCTUnwrap(row["prompt_cache"] as? [String: Any])
        XCTAssertEqual(cache["state"] as? String, "unknown")
        for key in ["basis", "lifetime_seconds", "requested_at", "cold_at", "reset", "prompt_tokens", "misses"] {
            XCTAssertTrue(cache[key] is NSNull, key)
        }
        workspace.setDetectedTerminalType("shell", forSurface: id)
        let second = try await request()
        XCTAssertEqual((second["panels"] as? [Any])?.count, 0)
    }

    func testFiftyWorkspacesTwoHundredPanelsStayBelowMainBudget() async throws {
        for _ in 0..<2 {
            let (_, manager) = addWindow()
            for index in 0..<25 {
                let ws = index == 0 ? manager.workspaces[0] : manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
                _ = try agent(ws)
                let pane = try XCTUnwrap(ws.bonsplitController.focusedPaneId)
                for _ in 0..<3 { _ = try agent(ws, panel: XCTUnwrap(ws.newTerminalSurface(inPane: pane, focus: false)).id) }
            }
        }
        var costs: [Double] = []
        for _ in 0..<30 {
            let doc = try await request()
            XCTAssertEqual(doc["workspace_count"] as? Int, 50)
            XCTAssertEqual((doc["panels"] as? [Any])?.count, 200)
            costs.append(try XCTUnwrap(doc["main_copy_duration_ms"] as? Double))
        }
        costs.sort()
        print("FLEET_BENCH workspaces=50 panels=200 samples=30 main_max_ms=\(costs.last!) main_p95_ms=\(costs[28])")
        XCTAssertLessThan(costs.last!, 50)
    }

    func testTimeoutReturnsWhileMainIsBusyAndAbandonsQueuedCapture() throws {
        let controller = TerminalController.shared
        let result = SelectionReadOperation<String>(timeout: 2)
        XCTAssertTrue(result.beginCapture())
        DispatchQueue.global().async {
            result.complete(controller.v2FleetWorker(id: 549, params: [:], timeout: 0.02))
        }
        // Holding main proves this path cannot call DispatchQueue.main.sync.
        let reply = try envelope(XCTUnwrap(result.wait()))
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "main_thread_timeout")
    }

    func testCLIUsesOneFleetRequestAndPrintsJSONAndTable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let cli = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("bin/c11")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), cli.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("tests/test_cli_fleet.py").path]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("C11_SOCKET") && !$0.key.hasPrefix("CMUX_SOCKET")
        }
        environment["C11_CLI"] = cli.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print(text)
        XCTAssertEqual(process.terminationStatus, 0, text)
    }
}
