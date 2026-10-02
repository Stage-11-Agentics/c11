import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// One sanitized lifecycle edge from a C11-271 capture.
struct LifecycleReplayStep: Equatable {
    let id: String
    let seq: Int
    let t: String
    let tMs: Int
    let source: String
    let name: String
    let toolName: String?
    let sessionID: String?
    let tab: String?
    let attributes: [String: String]
    let oracle: LifecycleOracle?
}

/// The attention reading recorded for one oracle step.
struct LifecycleOracle: Equatable {
    let mark: String
    let unread: Int
    let activity: String
    let status: String
}

/// A corpus case. `steps` and `captureSteps` are loaded from different files.
struct LifecycleFixtureCase: Equatable {
    let id: String
    let origin: String
    let provider: String
    let incident: String
    let recaptureRequired: String?
    let steps: [LifecycleReplayStep]
    let captureSteps: [LifecycleReplayStep]
    let currentMark: String
    let intendedMark: String
    let currentNotes: String
    let intendedNotes: String
}

/// Replay rules over the sanitized steps. The test executes these functions.
enum LifecycleReplay {
    static func askReachedWaiting(_ steps: [LifecycleReplayStep]) -> Bool {
        guard let tool = steps.first(where: { $0.name == "PreToolUse" && $0.toolName == "AskUserQuestion" }) else {
            return false
        }
        return steps.contains { $0.seq > tool.seq && $0.oracle?.mark == "waiting" }
    }

    static func siblingToolStartedAfterAskWasWaiting(_ steps: [LifecycleReplayStep]) -> Bool {
        guard let before = steps.first(where: { $0.name == "ask-is-waiting" }),
              let tool = steps.first(where: { $0.name == "PreToolUse" && $0.toolName == "Bash" }),
              let after = steps.first(where: { $0.name == "after-sibling" }) else {
            return false
        }
        guard before.seq < tool.seq, tool.seq < after.seq else { return false }
        guard let beforeOracle = before.oracle, let afterOracle = after.oracle else { return false }
        guard beforeOracle.mark == "waiting", afterOracle.mark == "waiting" else { return false }
        guard afterOracle.unread == beforeOracle.unread else { return false }
        guard let askTab = before.tab, let toolTab = tool.tab, askTab != toolTab else { return false }
        guard after.tab == askTab else { return false }
        return true
    }

    static func exitPlanFired(_ steps: [LifecycleReplayStep]) -> Bool {
        steps.contains { $0.toolName == "ExitPlanMode" }
    }

    static func escapeLandedDuringTool(_ steps: [LifecycleReplayStep]) -> Bool {
        guard let pre = steps.first(where: { $0.name == "PreToolUse" && $0.toolName == "Bash" }),
              let key = steps.first(where: { $0.name == "escape-sent" }) else {
            return false
        }
        guard pre.seq < key.seq else { return false }
        guard key.attributes["bash_pretool"] == "true",
              key.attributes["post_seen"] == "false",
              key.attributes["stop_seen"] == "false",
              key.attributes["key_sent"] == "true" else {
            return false
        }
        let finishedBeforeKey = steps.contains {
            $0.seq < key.seq && ($0.name == "Stop" || ($0.name == "PostToolUse" && $0.toolName == "Bash"))
        }
        return !finishedBeforeKey
    }

    static func sessionEndedOnLiveTab(_ steps: [LifecycleReplayStep]) -> Bool {
        guard let end = steps.first(where: { $0.name == "SessionEnd" && $0.tab != nil }) else {
            return false
        }
        return steps.contains { $0.oracle != nil && $0.seq > end.seq && $0.tab == end.tab }
    }

    static func toolPrecedesStop(_ steps: [LifecycleReplayStep]) -> Bool {
        guard let pre = steps.first(where: { $0.name == "PreToolUse" && $0.toolName == "Bash" }),
              let stop = steps.first(where: { $0.name == "Stop" }) else {
            return false
        }
        return pre.seq < stop.seq
    }

    static func noFabricatedClaudeHooks(_ steps: [LifecycleReplayStep]) -> Bool {
        let banned: Set<String> = [
            "SessionStart", "Stop", "PreToolUse", "PostToolUse", "Notification",
            "PermissionRequest", "SessionEnd",
        ]
        return !steps.isEmpty && steps.allSatisfy { !banned.contains($0.name) }
    }

    static func opencodePluginFeed(_ steps: [LifecycleReplayStep]) -> Bool {
        let plugin = steps.filter { $0.source == "opencode" }
        guard plugin.contains(where: { $0.name == "session.created" }) else { return false }
        guard plugin.allSatisfy({ $0.attributes["has_session"] == "true" || $0.attributes["has_session"] == "false" }) else {
            return false
        }
        return !plugin.contains { $0.name == "session.idle" }
    }

    static func derivedPretoolStaysAfterStop(
        _ steps: [LifecycleReplayStep],
        parent: [LifecycleReplayStep]
    ) -> Bool {
        guard let stop = steps.firstIndex(where: { $0.name == "Stop" }),
              let pre = steps.firstIndex(where: { $0.name == "PreToolUse" }),
              stop < pre else {
            return false
        }
        guard steps[pre].tMs < steps[stop].tMs else { return false }
        for step in steps {
            guard step.attributes["provenance"] == "derived-reorder",
                  let source = step.attributes["source_event"],
                  let origin = parent.first(where: { $0.id == source }) else {
                return false
            }
            if origin.name != step.name || origin.t != step.t || origin.toolName != step.toolName || origin.sessionID != step.sessionID {
                return false
            }
        }
        return true
    }
}

enum LifecycleFixtureCatalog {
    private static let allowedOrigins: Set<String> = ["observed", "derived-reorder", "gap"]
    private static let marks: Set<String> = ["waiting", "idle", "working", "not-observed", "unknown"]

    static func directory(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lifecycle", isDirectory: true)
    }

    static func load(from directory: URL) throws -> [LifecycleFixtureCase] {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        try assertPublic(manifestText, label: "manifest.json")
        let manifest = try jsonObject(manifestText, label: "manifest.json")
        guard let cases = manifest["cases"] as? [[String: Any]], !cases.isEmpty else {
            throw CatalogError.malformed("manifest.json has no cases")
        }
        return try cases.map { entry in
            try loadCase(entry, directory: directory)
        }
    }

    private static func loadCase(_ entry: [String: Any], directory: URL) throws -> LifecycleFixtureCase {
        let id = try string(entry, "id")
        let origin = try string(entry, "origin")
        guard allowedOrigins.contains(origin) else {
            throw CatalogError.malformed("\(id) origin \(origin)")
        }
        let recapture = optionalString(entry, "recapture_required")
        if origin == "gap" {
            guard recapture == "tagged-build" else {
                throw CatalogError.malformed("\(id) gap is missing recapture_required")
            }
        } else if recapture != nil {
            throw CatalogError.malformed("\(id) \(origin) carries recapture_required")
        }
        let captureName = try string(entry, "capture_file")
        let normalizedName = try string(entry, "normalized_file")
        let captureURL = directory.appendingPathComponent(captureName)
        let normalizedURL = directory.appendingPathComponent(normalizedName)
        let captureText = try String(contentsOf: captureURL, encoding: .utf8)
        let normalizedText = try String(contentsOf: normalizedURL, encoding: .utf8)
        try assertPublic(captureText, label: captureName)
        try assertPublic(normalizedText, label: normalizedName)
        let capture = try jsonObject(captureText, label: captureName)
        let normalized = try jsonObject(normalizedText, label: normalizedName)
        guard capture["id"] as? String == id, normalized["id"] as? String == id else {
            throw CatalogError.malformed("\(id) file id does not match the manifest")
        }
        guard capture["origin"] as? String == origin, normalized["origin"] as? String == origin else {
            throw CatalogError.malformed("\(id) origin does not match the manifest")
        }
        guard optionalString(capture, "recapture_required") == recapture,
              optionalString(normalized, "recapture_required") == recapture else {
            throw CatalogError.malformed("\(id) recapture_required does not match the manifest")
        }
        let captureSteps = try steps(from: capture["events"], label: id)
        let normalizedSteps = try steps(from: normalized["events"], label: id)
        let current = try object(normalized, "current", label: id)
        let intended = try object(normalized, "intended", label: id)
        let currentMark = try string(current, "mark")
        let intendedMark = try string(intended, "mark")
        guard marks.contains(currentMark), marks.contains(intendedMark) else {
            throw CatalogError.malformed("\(id) mark is outside the replay vocabulary")
        }
        if origin == "gap" {
            guard captureSteps.isEmpty, normalizedSteps.isEmpty else {
                throw CatalogError.malformed("\(id) gap case contains events")
            }
            guard currentMark == "not-observed" else {
                throw CatalogError.malformed("\(id) gap current mark")
            }
        }
        return LifecycleFixtureCase(
            id: id,
            origin: origin,
            provider: try string(entry, "provider"),
            incident: try string(entry, "incident"),
            recaptureRequired: recapture,
            steps: normalizedSteps,
            captureSteps: captureSteps,
            currentMark: currentMark,
            intendedMark: intendedMark,
            currentNotes: try string(current, "notes"),
            intendedNotes: try string(intended, "notes")
        )
    }

    private static func steps(from value: Any?, label: String) throws -> [LifecycleReplayStep] {
        guard let events = value as? [[String: Any]] else {
            throw CatalogError.malformed("\(label) events is not an array")
        }
        return try events.enumerated().map { index, event in
            let seq = try int(event, "seq", label: label)
            if seq != index + 1 {
                throw CatalogError.malformed("\(label) seq \(seq) is not \(index + 1)")
            }
            return LifecycleReplayStep(
                id: try string(event, "id"),
                seq: seq,
                t: try string(event, "t"),
                tMs: try int(event, "t_ms", label: label),
                source: try string(event, "source"),
                name: try string(event, "name"),
                toolName: optionalString(event, "tool_name"),
                sessionID: optionalString(event, "session_id"),
                tab: optionalString(event, "tab"),
                attributes: try stringMap(event["attrs"], label: "\(label) attrs"),
                oracle: try oracle(event["oracle"], label: label)
            )
        }
    }

    private static func oracle(_ value: Any?, label: String) throws -> LifecycleOracle? {
        if value == nil || value is NSNull {
            return nil
        }
        guard let object = value as? [String: Any] else {
            throw CatalogError.malformed("\(label) oracle")
        }
        return LifecycleOracle(
            mark: try string(object, "mark"),
            unread: try int(object, "unread", label: label),
            activity: (object["activity"] as? String) ?? "",
            status: (object["status"] as? String) ?? ""
        )
    }

    private static func stringMap(_ value: Any?, label: String) throws -> [String: String] {
        if value == nil || value is NSNull {
            return [:]
        }
        guard let object = value as? [String: Any] else {
            throw CatalogError.malformed(label)
        }
        var out: [String: String] = [:]
        for (key, raw) in object {
            guard let text = raw as? String else {
                throw CatalogError.malformed("\(label) \(key)")
            }
            out[key] = text
        }
        return out
    }

    private static func jsonObject(_ text: String, label: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.malformed("\(label) is not a JSON object")
        }
        return object
    }

    private static func object(_ source: [String: Any], _ key: String, label: String) throws -> [String: Any] {
        guard let value = source[key] as? [String: Any] else {
            throw CatalogError.malformed("\(label) missing \(key)")
        }
        return value
    }

    private static func string(_ source: [String: Any], _ key: String) throws -> String {
        guard let value = source[key] as? String, !value.isEmpty else {
            throw CatalogError.malformed("missing \(key)")
        }
        return value
    }

    private static func optionalString(_ source: [String: Any], _ key: String) -> String? {
        guard let value = source[key], !(value is NSNull) else { return nil }
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func int(_ source: [String: Any], _ key: String, label: String) throws -> Int {
        if let value = source[key] as? Int { return value }
        if let value = source[key] as? NSNumber { return value.intValue }
        throw CatalogError.malformed("\(label) missing \(key)")
    }

    private static func assertPublic(_ text: String, label: String) throws {
        if text.contains("/Users/") || text.contains("/private/var/") || text.contains("toolu_") || text.contains("see-notes") {
            throw CatalogError.privateToken(label)
        }
        if text.range(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, options: .regularExpression) != nil {
            throw CatalogError.privateToken(label)
        }
        if text.range(
            of: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            options: .regularExpression
        ) != nil {
            throw CatalogError.privateToken(label)
        }
    }

    enum CatalogError: Error, Equatable {
        case malformed(String)
        case privateToken(String)
    }
}

final class LifecycleFixtureCatalogTests: XCTestCase {
    func testCapturedC11271CasesReachCommittedRosterConsumersAfterReopen() throws {
        let all = try LifecycleFixtureCatalog.load(from: LifecycleFixtureCatalog.directory())
        let selected = Set(["claude-bypass-ask", "claude-bypass-ask-answered", "claude-session-end", "derived-late-pretool-after-stop"])
        let tab = UUID(uuidString: "00000000-0000-0000-0000-000000000231")!
        let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000232")!

        for fixture in all where selected.contains(fixture.id) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("c11-journal-fixture-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var now: Int64 = 1_700_000_000_000
            var store: JournalStore? = try JournalStore(layout: JournalStorageLayout(directory: directory), clock: { now })
            var owner: JournalOwner?
            var appliedAskID: UUID?
            var turnID: String?

            for step in fixture.steps {
                let kind: JournalKind?
                switch step.name {
                case "SessionStart": kind = .sessionStarted
                case "UserPromptSubmit": kind = .turnStarted
                case "PermissionRequest" where step.toolName == "AskUserQuestion": kind = .questionRequested
                case "PreToolUse" where step.toolName == "AskUserQuestion": kind = .questionRequested
                case "Stop": kind = .turnCompleted
                case "SessionEnd": kind = .sessionEnded
                default: kind = nil
                }
                guard let kind, let sessionID = step.sessionID else { continue }
                let timestamp = 1_700_000_000_000 + Int64(step.tMs)
                now = timestamp
                var draft = JournalDraft(
                    kind: kind, emittedAtMs: timestamp, occurredAtMs: timestamp, timeQuality: .nativeLocal,
                    tabID: tab, workspaceID: workspace, sessionID: sessionID, agentKind: "claude-code",
                    source: .hook, adapter: .claudeHook, nativeEvent: step.name)
                draft.turnID = step.attributes["prompt_id"] ?? turnID ?? "fixture-turn"
                if kind == .turnStarted { turnID = draft.turnID }
                if kind == .questionRequested {
                    draft.requestID = step.attributes["prompt_id"] ?? "fixture-request"
                    draft.toolClass = .askUserQuestion
                }
                let result = try store!.append(draft: draft, context: JournalContext(eligible: true, verifiedNativeClock: true))
                owner = draft.owner
                if kind == .questionRequested, result.receipt.projectionEffect == .applied { appliedAskID = draft.eventID }
            }

            let exactOwner = try XCTUnwrap(owner, fixture.id)
            store = nil
            let reopened = try JournalStore(layout: JournalStorageLayout(directory: directory), clock: { now + 1 })
            let baseline = try XCTUnwrap(reopened.current(owner: exactOwner), fixture.id)
            let page = try reopened.retainedOwnerEvents(owner: exactOwner, throughSequence: baseline.lastSequence)
            let historical = JournalReplayPolicy.restored(baseline)
            let classification = AgentRoster.classifyRestore(
                eventsNewestFirst: page.events, throughSequence: baseline.lastSequence,
                truncated: page.truncated, storePruned: false)
            let turnStarted = AgentRoster.turnStartMs(
                turnID: baseline.turnID, throughSequence: baseline.lastSequence, eventsNewestFirst: page.events)
            let ask = AgentRoster.restoredAsk(snapshot: baseline, eventsNewestFirst: page.events)

            switch fixture.id {
            case "claude-bypass-ask":
                XCTAssertEqual(historical.phase, .blocked)
                XCTAssertEqual(classification.label, "historical_candidate")
                XCTAssertEqual(ask?.eventID, appliedAskID)
                XCTAssertNotNil(turnStarted)
                XCTAssertEqual(page.events.filter { $0.draft.kind == .questionRequested }.map(\.effect), [.duplicateEvidence, .applied])
            case "claude-bypass-ask-answered":
                XCTAssertEqual(historical.phase, .blocked, "J6 records the response but does not own ask resolution")
                XCTAssertEqual(ask?.eventID, appliedAskID)
                XCTAssertNotNil(turnStarted)
                let completeTrace = try reopened.retainedOwnerEvents(owner: exactOwner)
                XCTAssertTrue(completeTrace.events.contains { $0.draft.kind == .turnCompleted && $0.effect == .advisory })
            case "claude-session-end":
                XCTAssertEqual(classification.label, "ended")
            case "derived-late-pretool-after-stop":
                XCTAssertEqual(historical.phase, .idle)
                XCTAssertNotNil(turnStarted)
            default:
                XCTFail("unexpected selected lifecycle fixture \(fixture.id)")
            }
        }
    }

    func testReplayIdentityAndAttentionContract() throws {
        let cases = try LifecycleFixtureCatalog.load(from: LifecycleFixtureCatalog.directory())
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        XCTAssertEqual(cases.count, byID.count)
        for item in cases {
            XCTAssertEqual(item.steps, item.captureSteps, item.id)
            XCTAssertNotEqual(item.intendedMark, "see-notes", item.id)
            XCTAssertNotEqual(item.currentMark, "see-notes", item.id)
            if let oracle = item.steps.last(where: { $0.oracle != nil }) {
                XCTAssertEqual(item.currentMark, oracle.oracle?.mark, item.id)
            }
            if item.origin != "derived-reorder" {
                let times = Set(item.steps.map(\.t))
                if times.count > 1 {
                    XCTAssertGreaterThan(item.steps.map(\.tMs).max() ?? 0, 0, item.id)
                }
            }
            switch item.id {
            case "claude-bypass-ask":
                try assertObserved(item)
                XCTAssertTrue(LifecycleReplay.askReachedWaiting(item.steps))
                XCTAssertEqual(item.intendedMark, "waiting")
            case "claude-sibling-tool-while-waiting":
                try assertObserved(item)
                XCTAssertTrue(LifecycleReplay.siblingToolStartedAfterAskWasWaiting(item.steps))
                XCTAssertEqual(item.intendedMark, "waiting")
                let before = try XCTUnwrap(item.steps.first { $0.name == "ask-is-waiting" })
                let after = try XCTUnwrap(item.steps.first { $0.name == "after-sibling" })
                XCTAssertEqual(after.tab, before.tab)
                XCTAssertEqual(after.oracle?.mark, item.intendedMark)
                XCTAssertEqual(after.oracle?.unread, before.oracle?.unread)
            case "claude-bypass-exit-plan":
                try assertObservedOrGap(item, observed: LifecycleReplay.exitPlanFired, intended: "waiting")
            case "claude-esc-interrupt":
                try assertObservedOrGap(item, observed: LifecycleReplay.escapeLandedDuringTool, intended: "idle")
            case "claude-session-end":
                try assertObservedOrGap(item, observed: LifecycleReplay.sessionEndedOnLiveTab, intended: "idle")
            case "claude-normal-tool-stop":
                try assertObserved(item)
                XCTAssertTrue(LifecycleReplay.toolPrecedesStop(item.steps))
                XCTAssertEqual(item.intendedMark, "idle")
            case "grok-session":
                try assertObserved(item)
                XCTAssertTrue(LifecycleReplay.noFabricatedClaudeHooks(item.steps))
                XCTAssertEqual(item.intendedMark, "unknown")
            case "opencode-session":
                try assertObserved(item)
                XCTAssertTrue(LifecycleReplay.opencodePluginFeed(item.steps))
                XCTAssertEqual(item.intendedMark, "idle")
            case "derived-late-pretool-after-stop":
                let parent = try XCTUnwrap(byID["claude-normal-tool-stop"])
                XCTAssertEqual(item.origin, "derived-reorder")
                XCTAssertTrue(LifecycleReplay.derivedPretoolStaysAfterStop(item.steps, parent: parent.captureSteps))
                XCTAssertEqual(item.intendedMark, "idle")
                XCTAssertEqual(item.currentMark, "working")
            case "codex-child-completion":
                try assertObservedOrGap(item, observed: { steps in
                    steps.contains { $0.source == "codex-notify" }
                }, intended: "idle")
            case "claude-restart-while-waiting", "app-restart-while-waiting":
                try assertGap(item)
            default:
                XCTFail("unexpected case \(item.id)")
            }
        }
    }

    private func assertObserved(_ item: LifecycleFixtureCase, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(item.origin, "observed", file: file, line: line)
        XCTAssertNil(item.recaptureRequired, file: file, line: line)
        XCTAssertFalse(item.steps.isEmpty, file: file, line: line)
    }

    private func assertGap(_ item: LifecycleFixtureCase, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(item.origin, "gap", file: file, line: line)
        XCTAssertEqual(item.recaptureRequired, "tagged-build", file: file, line: line)
        XCTAssertTrue(item.steps.isEmpty, item.id, file: file, line: line)
        XCTAssertEqual(item.currentMark, "not-observed", file: file, line: line)
        XCTAssertFalse(item.intendedMark.isEmpty, file: file, line: line)
    }

    private func assertObservedOrGap(
        _ item: LifecycleFixtureCase,
        observed: ([LifecycleReplayStep]) -> Bool,
        intended: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(item.intendedMark, intended, file: file, line: line)
        if item.origin == "gap" {
            try assertGap(item, file: file, line: line)
            XCTAssertFalse(observed(item.steps), file: file, line: line)
        } else {
            try assertObserved(item, file: file, line: line)
            XCTAssertTrue(observed(item.steps), item.id, file: file, line: line)
        }
    }
}
