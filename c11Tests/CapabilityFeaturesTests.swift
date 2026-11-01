import XCTest
import Foundation

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CapabilityFeaturesTests: XCTestCase {
    @MainActor
    func testWhitespaceWrappedCapabilitiesKeepsSocketWorkerRouting() throws {
        let controller = TerminalController.makeForTesting()
        for whitespace in [" ", "\t", "\r\n"] {
            let reply = try workerReply(
                controller,
                command: whitespace + #"{"id":463,"method":"system.capabilities","params":{}}"# + whitespace
            )
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            XCTAssertEqual(envelope["id"] as? Int, 463)
            XCTAssertEqual(envelope["ok"] as? Bool, true)
            XCTAssertNotNil((envelope["result"] as? [String: Any])?["methods"])
        }
    }

    @MainActor
    func testCapabilitiesTracksAccessModeChangesOnTheWorker() throws {
        let controller = TerminalController.makeForTesting()
        // Exercise the same property writer used by start() and listener restarts,
        // without opening a listener or constructing a workspace graph.
        for mode in [SocketControlMode.password, .allowAll, .c11Only] {
            controller.accessMode = mode
            let reply = try workerReply(
                controller,
                command: #"{"id":463,"method":"system.capabilities","params":{}}"#
            )
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertEqual(result["access_mode"] as? String, mode.rawValue)
            XCTAssertEqual(result["access_mode"] as? String, controller.accessMode.rawValue)
        }
    }

    @MainActor
    private func workerReply(_ controller: TerminalController, command: String) throws -> String {
        let replies = LockedSocketReplies()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "c11-463-capability-worker").async {
            replies.store("response", controller.processCommandUsingSocketExecutionPolicy(command))
            finished.signal()
        }
        // Hold main so a successful response proves the real policy router
        // kept the command on its worker. Always join before leaving the test.
        let completedOffMain = finished.wait(timeout: .now() + .seconds(1)) == .success
        if !completedOffMain {
            while finished.wait(timeout: .now()) != .success {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        }
        XCTAssertTrue(completedOffMain, "capabilities must finish while main is stalled")
        return try XCTUnwrap(replies.snapshot()["response"])
    }

    func testCurrentAdvertisesBrowserProfilesFeedAsksAndTerminalInputState() {
        let featureIDs = Set(CapabilityFeatures.current.payload.compactMap { $0["id"] as? String })
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.browserProfiles.rawValue))
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.feedAsks.rawValue))
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.markdownAgentCLI.rawValue))
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.terminalInputState.rawValue))
        XCTAssertTrue(featureIDs.contains(CapabilityFeatures.ID.fleet.rawValue))
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "system.fleet"), .socketWorker)
    }

    @MainActor
    func testPanelLinksCapabilityIsAdvertisedOnTheSocketWorker() throws {
        let controller = TerminalController.makeForTesting()
        let reply = try workerReply(
            controller,
            command: #"{"id":532,"method":"system.capabilities","params":{}}"#
        )
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["id"] as? Int, 532)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let features = try XCTUnwrap(result["features"] as? [[String: Any]])
        let panelLinks = features.filter { $0["id"] as? String == "links.panel" }
        XCTAssertEqual(panelLinks.count, 1)
        XCTAssertEqual(panelLinks.first?["version"] as? Int, 1)
        let terminalLinks = features.filter { $0["id"] as? String == "links.terminal" }
        XCTAssertEqual(terminalLinks.count, 1)
        XCTAssertEqual(terminalLinks.first?["version"] as? Int, 1)
    }

    @MainActor
    func testMarkdownBacklinksCapabilityIsAdvertised() throws {
        let controller = TerminalController.makeForTesting()
        let data = try XCTUnwrap(controller.v2DispatchSystem("system.capabilities", id: 1, params: [:]).data(using: .utf8))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let methods = try XCTUnwrap(result["methods"] as? [String])
        XCTAssertTrue(methods.contains("markdown.backlinks"))
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "markdown.backlinks"), .socketWorker)
    }

    @MainActor
    func testCapabilitiesAndClaudeStopEdgeFinishWhileMainThreadIsStalled() throws {
        XCTAssertTrue(Thread.isMainThread)

        let controller = TerminalController.makeForTesting()
        let mainResponse = controller.v2DispatchSystem("system.capabilities", id: 1, params: [:])
        let expectedPayload = try canonicalJSON(mainResponse)

        // Give the real append handler an isolated, already-open store. The
        // test never touches the app or logic-test bundle's persistent journal.
        let journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-402-journal-\(UUID().uuidString)", isDirectory: true)
        var journalStore: JournalStore? = try JournalStore(
            layout: JournalStorageLayout(directory: journalDirectory)
        )
        let previousStore = JournalCoordinator.shared.replaceStoreForTesting(journalStore)
        defer {
            _ = JournalCoordinator.shared.replaceStoreForTesting(previousStore)
            journalStore = nil
            try? FileManager.default.removeItem(at: journalDirectory)
        }

        let workspaceID = UUID()
        let panelID = UUID()
        var draft = try XCTUnwrap(ClaudeHookMapping.map(
            subcommand: "stop",
            object: ["session_id": "c11-402-test-session"]
        ))
        draft.panelID = panelID
        draft.workspaceID = workspaceID
        let event = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: draft.canonicalData()) as? [String: Any]
        )
        let appendRequest = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "id": 2,
                "method": "agent.event.append",
                "params": ["event": event]
            ], options: [.sortedKeys]),
            encoding: .utf8
        ))

        let replies = LockedSocketReplies()
        let finished = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "system-capabilities-hook-test")
        let hookDeadline = DispatchTime.now() + .milliseconds(250)
        worker.async {
            replies.store("worker_is_main", String(Thread.isMainThread))
            replies.store("capabilities", controller.processCommandUsingSocketExecutionPolicy(
                #"{"id":1,"method":"system.capabilities","params":{}}"#
            ))
            // A real hook cannot submit the lifecycle edge until capability
            // discovery returns. If that answer missed the hook deadline, do
            // not let the late main-thread response mutate the isolated journal.
            guard DispatchTime.now() < hookDeadline else {
                finished.signal()
                return
            }
            replies.store("hook_edge", controller.processCommandUsingSocketExecutionPolicy(appendRequest))
            replies.store("idle_activity", controller.processCommandUsingSocketExecutionPolicy(
                "report_agent_activity idle --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
            ))
            finished.signal()
        }

        // This blocks main for the same 250 ms window the Claude hook gives a
        // socket request. A main-actor dispatch cannot finish here.
        let completedBeforeHookDeadline = finished.wait(timeout: hookDeadline)
        guard completedBeforeHookDeadline == .success else {
            // The test resumes main at the deadline. Drain any already-started
            // worker request before the defer restores and removes its journal.
            // Running the main loop also releases a deliberately main-routed
            // capabilities request so the worker can observe the expired bound.
            while finished.wait(timeout: .now()) != .success {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            XCTFail("capability discovery and the Claude Stop edge must finish while main is stalled")
            return
        }
        XCTAssertEqual(TerminalController.executionPolicy(forV2Method: "system.capabilities"), .socketWorker)

        let result = replies.snapshot()
        XCTAssertEqual(result["worker_is_main"], "false")
        let workerResponse = try XCTUnwrap(result["capabilities"])
        XCTAssertEqual(try canonicalJSON(workerResponse), expectedPayload,
                       "the worker reply must preserve the existing capabilities payload")

        let edgeResponse = try XCTUnwrap(result["hook_edge"])
        let edgeEnvelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(edgeResponse.utf8)) as? [String: Any])
        XCTAssertEqual(edgeEnvelope["ok"] as? Bool, true)
        let receipt = try XCTUnwrap(edgeEnvelope["result"] as? [String: Any])
        XCTAssertEqual(receipt["event_id"] as? String, draft.eventID.uuidString,
                       "the synthetic Claude Stop hook edge must be durably committed")
        XCTAssertEqual(result["idle_activity"], "OK",
                       "the hook's legacy idle report must also receive its worker acknowledgement")
        let recorded = try XCTUnwrap(
            try journalStore?.readPage(after: 0).first { $0.draft.eventID == draft.eventID }
        )
        XCTAssertEqual(recorded.draft.kind, .turnCompleted)
        XCTAssertEqual(recorded.draft.nativeEvent, "Stop")
    }

    func testMarkdownAgentMethodsRunOnSocketWorkersWithoutInAppFocusIntent() {
        let methods = [
            "markdown.scroll",
            "markdown.navigate",
            "markdown.history",
            "markdown.links",
            "markdown.backlinks",
            "markdown.visible",
            "markdown.theme",
            "markdown.typeface",
            "markdown.font",
            "markdown.open_external"
        ]
        for method in methods {
            XCTAssertEqual(TerminalController.executionPolicy(forV2Method: method), .socketWorker, method)
            XCTAssertFalse(
                TerminalController.socketCommandAllowsInAppFocusMutations(commandKey: method, isV2: true),
                method
            )
        }
    }

    func testDisabledAndMissingFeaturesNeverExecute() throws {
        let registry = CapabilityFeatures(entries: [
            .init(id: .terminalSelection, version: 3, enabled: false)
        ])
        var executions = 0
        for id in [CapabilityFeatures.ID.terminalSelection, .rawSend] {
            XCTAssertThrowsError(try registry.dispatch(id) { executions += 1 }) { error in
                XCTAssertEqual((error as? CapabilityFeatures.Unsupported)?.id, id)
            }
        }
        XCTAssertEqual(executions, 0)
        XCTAssertTrue(registry.payload.isEmpty)
    }

    func testEnablingEntryAdmitsBehaviorAndAdvertisesVersion() throws {
        let registry = CapabilityFeatures(entries: [
            .init(id: .offlineEvents, version: 7, enabled: true),
            .init(id: .rawSend, version: 1, enabled: false)
        ])
        let result = try registry.dispatch(.offlineEvents) { "fixture event" }
        XCTAssertEqual(result, "fixture event")
        XCTAssertEqual(registry.payload.count, 1)
        XCTAssertEqual(registry.payload.first?["id"] as? String, "events.offline")
        XCTAssertEqual(registry.payload.first?["version"] as? Int, 7)
    }
}

private final class LockedSocketReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func store(_ key: String, _ value: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func canonicalJSON(_ text: String) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
