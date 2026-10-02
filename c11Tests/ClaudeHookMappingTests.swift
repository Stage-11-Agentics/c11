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

    func testAnswerArrivalCannotBePassedByStopForAskAndPlan() throws {
        for (tool, request, expectedReason) in [
            ("AskUserQuestion", "request-ask", JournalReason.question),
            ("ExitPlanMode", "request-plan", JournalReason.planReview),
        ] {
            let ask = try owned("pre-tool-use", base(tool: tool, request: request), tab: tabA)
            XCTAssertEqual(ask.kind, expectedReason == .question ? .questionRequested : .planReviewRequested)
            let blocked = try XCTUnwrap(JournalTestData.fold(nil, ask, seq: 1).snapshot)
            XCTAssertEqual(blocked.reason, expectedReason)

            let stop = JournalTestData.fold(blocked, try owned("stop", base(), tab: tabA), seq: 2)
            XCTAssertEqual(stop.snapshot, blocked, "Stop must not pass the unresolved blocking request for \(tool)")
            XCTAssertNotEqual(stop.effect, .applied)

            let resolved = try owned("post-tool-use", base(tool: tool, request: request), tab: tabA)
            let working = try XCTUnwrap(JournalTestData.fold(blocked, resolved, seq: 3).snapshot)
            XCTAssertEqual(working.phase, .working)
            XCTAssertNil(working.reason)
        }
    }

    func testStopFailureChildAndPreCompactDoNotInventParentTransitions() throws {
        let working = try XCTUnwrap(JournalTestData.fold(nil, try owned("prompt-submit", base(), tab: tabA), seq: 1).snapshot)
        var failure = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "stop-failure", object: [
            "session_id": "sess-1", "error": "SENTINEL-ERROR", "last_assistant_message": "SENTINEL-ASSISTANT"
        ]))
        failure.tabID = tabA
        failure.workspaceID = JournalTestData.workspace
        XCTAssertEqual(failure.kind, .errorReported)
        XCTAssertEqual(failure.reasonCode, .sessionFailure)
        XCTAssertEqual(failure.nativeEvent, "StopFailure")
        XCTAssertFalse(failure.isChild)
        let folded = JournalTestData.fold(working, failure, seq: 2)
        XCTAssertEqual(folded.effect, .applied)
        XCTAssertEqual(folded.snapshot?.phase, .error)
        XCTAssertEqual(folded.snapshot?.reason, .sessionFailure)
        XCTAssertEqual(folded.snapshot?.terminalBarrier, true)

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

    func testSharedFixtureCorpusReplaysValidatorCasesAndKeepsProvenance() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lifecycle")
        let normalizedRoot = fixtureRoot.appendingPathComponent("normalized")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.json"))) as? [String: Any])
        let manifestCases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        let manifestByID: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: manifestCases.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        })
        let providers = try XCTUnwrap((manifest["provenance"] as? [String: Any])?["providers"] as? [String: Any])
        XCTAssertEqual(providers["claude-code"] as? String, "2.1.287 (Claude Code)")

        let subcommands = [
            "SessionStart": "session-start", "UserPromptSubmit": "prompt-submit", "Stop": "stop",
            "PreToolUse": "pre-tool-use", "PostToolUse": "post-tool-use", "PermissionRequest": "permission-request",
            "Notification": "notification"
        ]
        let validatorCases = [
            "claude-bypass-ask", "claude-bypass-ask-answered", "claude-bypass-exit-plan",
            "claude-normal-tool-stop", "claude-sibling-tool-while-waiting", "derived-late-pretool-after-stop"
        ]

        for (number, name) in validatorCases.enumerated() {
            let label = "Validator case \(number + 1): \(name)"
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: normalizedRoot.appendingPathComponent(name + ".json"))) as? [String: Any], label)
            let events = try XCTUnwrap(object["events"] as? [[String: Any]], label)
            let descriptor: [String: Any]
            if let manifestDescriptor = manifestByID[name] {
                descriptor = manifestDescriptor
            } else {
                // The answer continuation is a derived extension of the observed
                // bypass-ask capture, so it is intentionally absent from the
                // capture manifest's provider-run case list.
                XCTAssertEqual(name, "claude-bypass-ask-answered", label)
                let provenance = try XCTUnwrap(object["provenance"] as? [String: Any], label)
                XCTAssertEqual(provenance["base_fixture"] as? String, "claude-bypass-ask", label)
                descriptor = ["provider": "claude-code", "origin": "derived"]
            }
            XCTAssertEqual(descriptor["provider"] as? String, "claude-code", label)
            XCTAssertEqual(object["origin"] as? String, descriptor["origin"] as? String, label)

            if descriptor["origin"] as? String == "gap" {
                XCTAssertEqual(descriptor["recapture_required"] as? String, "tagged-build", label)
                XCTAssertTrue(events.isEmpty, label)
                XCTAssertTrue((descriptor["missing_native_signals"] as? [String] ?? []).contains("ExitPlanMode"), label)
                continue
            }

            var states: [JournalOwner: JournalSnapshot] = [:]
            if name == "claude-sibling-tool-while-waiting" {
                let seed = try owned(
                    "pre-tool-use",
                    base(tool: "AskUserQuestion", request: "tool-1", session: "sess-1"),
                    tab: tabA
                )
                let blocked = try XCTUnwrap(JournalTestData.fold(nil, seed, seq: 1).snapshot, label)
                states[try XCTUnwrap(seed.owner, label)] = blocked
            }

            var observedOracleCount = 0
            var observedEventOrigins = Set<String>()
            for (index, event) in events.enumerated() {
                if let eventOrigin = event["origin"] as? String {
                    observedEventOrigins.insert(eventOrigin)
                    XCTAssertFalse(eventOrigin.isEmpty, label)
                }
                if let attrs = event["attrs"] as? [String: Any], attrs["provenance"] != nil {
                    XCTAssertEqual(attrs["provenance"] as? String, "derived-reorder", label)
                }
                if event["source"] as? String == "oracle" {
                    let oracle = try XCTUnwrap(event["oracle"] as? [String: Any], label)
                    XCTAssertNotNil(oracle["mark"], label)
                    XCTAssertNotNil(oracle["activity"], label)
                    observedOracleCount += 1
                    if name == "claude-normal-tool-stop" {
                        // The captured oracle is the old working symptom. The executable
                        // projection below is the intended idle completion.
                        XCTAssertEqual(oracle["mark"] as? String, "working", label)
                    }
                    continue
                }
                guard event["source"] as? String == "claude-hook" else { continue }
                let native = try XCTUnwrap(event["name"] as? String, label)
                let attrs = event["attrs"] as? [String: Any] ?? [:]
                guard let subcommand = subcommands[native] else {
                    XCTFail("\(label): unknown native hook \(native)")
                    continue
                }
                guard var draft = ClaudeHookMapping.map(subcommand: subcommand, object: attrs) else {
                    XCTAssertEqual(native, "PermissionRequest", label)
                    continue
                }
                let captureTab = try XCTUnwrap(event["tab"] as? String, label)
                draft.tabID = captureTab == "tab-sibling" ? tabB : tabA
                draft.workspaceID = JournalTestData.workspace
                try draft.validate()
                let owner = try XCTUnwrap(draft.owner, label)
                states[owner] = JournalTestData.fold(
                    states[owner], draft, seq: Int64(event["seq"] as? Int ?? index + 1)
                ).snapshot

                if name == "claude-bypass-ask", native == "PreToolUse" {
                    XCTAssertEqual(states[owner]?.phase, .blocked, label)
                }
                if name == "claude-bypass-ask-answered", native == "PostToolUse" {
                    XCTAssertEqual(states[owner]?.phase, .working, label)
                    XCTAssertEqual(event["origin"] as? String, "synthetic-extension", label)
                }
            }

            XCTAssertFalse(observedEventOrigins.contains(""), label)
            if name != "derived-late-pretool-after-stop" {
                XCTAssertGreaterThan(observedOracleCount, 0, label)
            }
            let tabAStates = states.values.filter { $0.owner.tabID == tabA }
            let tabBStates = states.values.filter { $0.owner.tabID == tabB }
            switch name {
            case "claude-bypass-ask":
                XCTAssertTrue(tabAStates.contains { $0.phase == .blocked }, label)
            case "claude-bypass-ask-answered":
                XCTAssertTrue(tabAStates.contains { $0.phase == .idle && $0.terminalBarrier }, label)
            case "claude-normal-tool-stop", "derived-late-pretool-after-stop":
                XCTAssertTrue(tabAStates.contains { $0.phase == .idle && $0.terminalBarrier }, label)
            case "claude-sibling-tool-while-waiting":
                XCTAssertTrue(tabAStates.contains { $0.phase == .blocked }, label)
                XCTAssertTrue(tabBStates.contains { $0.phase == .working }, label)
            default:
                XCTFail("\(label): unhandled validator case")
            }
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
