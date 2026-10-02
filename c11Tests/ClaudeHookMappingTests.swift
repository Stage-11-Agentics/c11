import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class ClaudeHookMappingTests: XCTestCase {
    private let tabA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let tabB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func testBypassAskStaysBlockedUntilMatchingResume() throws {
        let ask = try owned("pre-tool-use", base(tool: "AskUserQuestion", request: "request-a"), tab: tabA)
        XCTAssertEqual(ask.kind, .questionRequested)
        XCTAssertNil(ClaudeHookMapping.map(subcommand: "permission-request", object: base(tool: "AskUserQuestion", request: "request-a")))
        let note = try owned("notification", ["session_id": "sess-1", "notification_type": "permission_prompt"], tab: tabA)
        XCTAssertEqual(note.kind, .approvalRequested)
        XCTAssertNil(note.toolClass)
        let blocked = try XCTUnwrap(JournalTestData.fold(nil, ask, seq: 1).snapshot)
        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertEqual(blocked.reason, .question)
        let stopped = JournalTestData.fold(blocked, try owned("stop", base(), tab: tabA), seq: 2)
        XCTAssertEqual(stopped.snapshot, blocked)
        XCTAssertNotEqual(stopped.effect, .applied)

        let prompt = try owned("prompt-submit", base(request: "request-a"), tab: tabA)
        XCTAssertEqual(prompt.kind, .turnStarted)
        XCTAssertNil(prompt.requestID)
        XCTAssertNotEqual(prompt.eventID, ask.eventID)

        XCTAssertNil(ClaudeHookMapping.map(subcommand: "post-tool-use", object: base(tool: "AskUserQuestion", request: nil)))
        XCTAssertNil(ClaudeHookMapping.map(subcommand: "post-tool-use", object: base(tool: "AskUserQuestion", request: String(repeating: "x", count: 129))))
        let other = JournalTestData.fold(blocked, try owned("post-tool-use", base(tool: "Bash", request: "request-a"), tab: tabA), seq: 3)
        XCTAssertEqual(other.snapshot, blocked)
        let mismatch = JournalTestData.fold(blocked, try owned("post-tool-use", base(tool: "AskUserQuestion", request: "request-b"), tab: tabA), seq: 4)
        XCTAssertEqual(mismatch.snapshot, blocked)

        let resumed = try owned("post-tool-use", base(tool: "AskUserQuestion", request: "request-a"), tab: tabA)
        XCTAssertEqual(resumed.kind, .attentionResolved)
        XCTAssertEqual(resumed.resolution, .resumed)
        XCTAssertNil(resumed.signal)
        let working = try XCTUnwrap(JournalTestData.fold(blocked, resumed, seq: 5).snapshot)
        XCTAssertEqual(working.phase, .working)
        let completed = try XCTUnwrap(JournalTestData.fold(working, try owned("stop", base(), tab: tabA), seq: 6).snapshot)
        XCTAssertEqual(completed.phase, .idle)
        XCTAssertEqual(completed.turnOutcome, "completed")
        let repeated = JournalTestData.fold(completed, resumed, seq: 7)
        XCTAssertEqual(repeated.snapshot?.phase, .idle)
        XCTAssertEqual(repeated.snapshot?.terminalBarrier, true)
        XCTAssertNotEqual(repeated.effect, .applied)

        let plan = try owned("pre-tool-use", base(tool: "ExitPlanMode", request: "plan-a"), tab: tabA)
        XCTAssertEqual(plan.kind, .planReviewRequested)
        XCTAssertNil(ClaudeHookMapping.map(subcommand: "permission-request", object: base(tool: "ExitPlanMode", request: "plan-a")))
        let planBlocked = try XCTUnwrap(JournalTestData.fold(nil, plan, seq: 1).snapshot)
        XCTAssertEqual(planBlocked.reason, .planReview)
        let planWorking = try XCTUnwrap(JournalTestData.fold(planBlocked, try owned("post-tool-use", base(tool: "ExitPlanMode", request: "plan-a"), tab: tabA), seq: 2).snapshot)
        XCTAssertEqual(planWorking.phase, .working)
    }

    func testStopFailureChildAndPreCompactDoNotInventParentTransitions() throws {
        let working = try XCTUnwrap(JournalTestData.fold(nil, try owned("prompt-submit", base(), tab: tabA), seq: 1).snapshot)
        var failure = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "stop-failure", object: [
            "session_id": "sess-1", "error": "SENTINEL-ERROR", "last_assistant_message": "SENTINEL-ASSISTANT"
        ]))
        failure.tabID = tabA
        failure.workspaceID = JournalTestData.workspace
        XCTAssertEqual(failure.kind, .errorReported)
        XCTAssertNil(failure.reasonCode)
        XCTAssertEqual(failure.nativeEvent, "other")
        XCTAssertFalse(failure.isChild)
        let folded = JournalTestData.fold(working, failure, seq: 2)
        // C11-272: an unknown native name has no parent lifecycle effect. The row is still error.reported.
        XCTAssertEqual(folded.effect, .observation)
        XCTAssertEqual(folded.snapshot?.phase, .working)

        var child = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "subagent-start", object: [
            "session_id": "sess-1", "agent_id": "child-1", "last_assistant_message": "SENTINEL-ASSISTANT"
        ]))
        child.tabID = tabA
        child.workspaceID = JournalTestData.workspace
        XCTAssertEqual(child.kind, .childSpawned)
        XCTAssertEqual(child.sessionID, "child-1")
        XCTAssertEqual(child.parentSessionID, "sess-1")
        XCTAssertTrue(child.isChild)
        let spawned = JournalTestData.fold(working, child, seq: 3)
        XCTAssertEqual(spawned.effect, .child)
        XCTAssertEqual(spawned.snapshot, working)
        let done = JournalTestData.fold(working, try {
            var stop = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "subagent-stop", object: [
                "session_id": "sess-1", "agent_id": "child-1", "last_assistant_message": "SENTINEL-ASSISTANT"
            ]))
            stop.tabID = tabA
            stop.workspaceID = JournalTestData.workspace
            return stop
        }(), seq: 4)
        XCTAssertEqual(done.effect, .child)
        XCTAssertEqual(done.snapshot?.phase, .working)

        let missing = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "subagent-start", object: ["session_id": "sess-1"]))
        XCTAssertNil(missing.sessionID)
        XCTAssertEqual(missing.parentSessionID, "sess-1")
        XCTAssertTrue(missing.isChild)

        let compact = JournalTestData.fold(working, try owned("pre-compact", [
            "session_id": "sess-1", "custom_instructions": "SENTINEL-INSTRUCTIONS"
        ], tab: tabA), seq: 5)
        XCTAssertEqual(compact.effect, .observation)
        XCTAssertEqual(compact.snapshot?.phase, working.phase)
    }

    func testLateToolAndSiblingToolLeaveTheOtherState() throws {
        let working = try XCTUnwrap(JournalTestData.fold(nil, try owned("prompt-submit", base(), tab: tabA), seq: 1).snapshot)
        let completed = try XCTUnwrap(JournalTestData.fold(working, try owned("stop", base(), tab: tabA), seq: 2).snapshot)
        for tool in ["pre-tool-use", "post-tool-use"] {
            let late = JournalTestData.fold(completed, try owned(tool, base(tool: "Bash", request: "tool-9"), tab: tabA), seq: 3)
            XCTAssertEqual(late.snapshot?.phase, .idle)
            XCTAssertEqual(late.snapshot?.turnOutcome, "completed")
            XCTAssertNotEqual(late.effect, .applied)
        }
        let blocked = try XCTUnwrap(JournalTestData.fold(nil, try owned("pre-tool-use", base(tool: "AskUserQuestion", request: "request-a"), tab: tabA), seq: 1).snapshot)
        let siblingDraft = try owned("pre-tool-use", base(tool: "Bash", request: "tool-b", session: "sess-2"), tab: tabB)
        XCTAssertNotEqual(siblingDraft.owner, blocked.owner)
        let sibling = JournalTestData.fold(blocked, siblingDraft, seq: 2)
        XCTAssertEqual(sibling.snapshot, blocked)
        XCTAssertNotEqual(sibling.effect, .applied)
        let own = JournalTestData.fold(nil, siblingDraft, seq: 1)
        XCTAssertNil(own.snapshot)
    }

    func testPermissionRequestObservesWithoutADecisionAndDropsBodies() throws {
        let approval = try owned("permission-request", [
            "session_id": "sess-1", "tool_name": "Bash", "tool_use_id": "tool-1",
            "tool_input": ["command": "SENTINEL-INPUT"], "tool_response": "SENTINEL-RESPONSE"
        ], tab: tabA)
        XCTAssertEqual(approval.kind, .approvalRequested)
        XCTAssertEqual(approval.nativeEvent, "PermissionRequest")
        XCTAssertEqual(approval.toolClass, .other)
        XCTAssertEqual(approval.requestID, "tool-1")
        let blocked = try XCTUnwrap(JournalTestData.fold(nil, approval, seq: 1).snapshot)
        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertEqual(blocked.reason, .approval)
        let oversized = try owned("permission-request", [
            "session_id": "sess-1", "tool_name": "Bash", "tool_use_id": String(repeating: "y", count: 129)
        ], tab: tabA)
        XCTAssertNil(oversized.requestID)
        let ordinary = try owned("post-tool-use", base(tool: "Bash", request: String(repeating: "z", count: 129)), tab: tabA)
        XCTAssertEqual(ordinary.kind, .stateChanged)
        XCTAssertEqual(ordinary.signal, .toolActivity)
        XCTAssertNil(ordinary.requestID)
        try assertNoSentinels(try owned("post-tool-use", [
            "session_id": "sess-1", "prompt_id": "turn-a", "tool_name": "AskUserQuestion", "tool_use_id": "request-a",
            "tool_input": ["question": "SENTINEL-QUESTION"], "tool_response": ["answer": "SENTINEL-RESPONSE"],
            "last_assistant_message": "SENTINEL-ASSISTANT", "custom_instructions": "SENTINEL-INSTRUCTIONS"
        ], tab: tabA))
        let first = try owned("pre-tool-use", base(tool: "Bash", request: "tool-1"), tab: tabA)
        let retry = first
        XCTAssertEqual(try first.canonicalData(), try retry.canonicalData())
        XCTAssertNotEqual(first.eventID, try owned("pre-tool-use", base(tool: "Bash", request: "tool-1"), tab: tabA).eventID)
    }

    func testSharedFixtureCorpusKeepsProvenance() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lifecycle/normalized")
        let subcommands = [
            "SessionStart": "session-start", "UserPromptSubmit": "prompt-submit", "Stop": "stop",
            "PreToolUse": "pre-tool-use", "PostToolUse": "post-tool-use", "PermissionRequest": "permission-request",
            "Notification": "notification"
        ]
        for (name, expected) in [("claude-bypass-ask", JournalPhase.blocked), ("claude-bypass-ask-answered", .idle), ("derived-late-pretool-after-stop", .idle)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name + ".json"))) as? [String: Any])
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            var state: JournalSnapshot?
            for (index, event) in events.enumerated() where event["source"] as? String == "claude-hook" {
                let native = try XCTUnwrap(event["name"] as? String)
                let attrs = event["attrs"] as? [String: Any] ?? [:]
                guard let draft = ClaudeHookMapping.map(subcommand: try XCTUnwrap(subcommands[native]), object: attrs) else {
                    XCTAssertEqual(native, "PermissionRequest", name)
                    continue
                }
                var owned = draft
                owned.tabID = tabA
                owned.workspaceID = JournalTestData.workspace
                state = JournalTestData.fold(state, owned, seq: Int64(index + 1)).snapshot
            }
            XCTAssertEqual(state?.phase, expected, name)
        }
    }

    private func base(tool: String? = nil, request: String? = "request-a", session: String = "sess-1") -> [String: Any] {
        var object: [String: Any] = ["session_id": session, "prompt_id": "turn-a"]
        if let tool { object["tool_name"] = tool }
        if let request { object["tool_use_id"] = request }
        return object
    }

    private func owned(_ subcommand: String, _ object: [String: Any], tab: UUID) throws -> JournalDraft {
        var draft = try XCTUnwrap(ClaudeHookMapping.map(subcommand: subcommand, object: object))
        draft.tabID = tab
        draft.workspaceID = JournalTestData.workspace
        try draft.validate()
        XCTAssertNotEqual(draft.signal, .operatorResponse)
        return draft
    }

    private func assertNoSentinels(_ draft: JournalDraft) throws {
        let text = String(decoding: try draft.canonicalData(), as: UTF8.self)
        for sentinel in ["SENTINEL-QUESTION", "SENTINEL-RESPONSE", "SENTINEL-ASSISTANT", "SENTINEL-INSTRUCTIONS", "SENTINEL-INPUT", "SENTINEL-ERROR"] {
            XCTAssertFalse(text.contains(sentinel), text)
        }
    }
}
