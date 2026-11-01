import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class ClaudeMailboxAcceptanceTests: XCTestCase {
    private let session = "6e70208a-c331-4dd6-a647-717941c8a8d3"
    private var directory: URL!
    private var transcript: URL { directory.appendingPathComponent(session + ".jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func record(sessionID: String? = nil, role: String = "user", text: String? = nil,
                        timestamp: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONSerialization.data(withJSONObject: [
            "type": role, "sessionId": sessionID ?? session,
            "timestamp": formatter.string(from: timestamp),
            "message": ["role": role, "content": text ??
                "Another Claude session sent a message:\n\(ClaudeMailboxAcceptance.invitation)\n\nPeer permission boundary."]
        ])
        data.append(0x0A)
        return data
    }

    private func append(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: transcript.path) { try Data().write(to: transcript) }
        let file = try FileHandle(forWritingTo: transcript)
        defer { try? file.close() }
        _ = try file.seekToEnd()
        try file.write(contentsOf: data)
    }

    /// The app's native deliver frame carries `MailboxDoorbell.text`; the
    /// Claude bridge rejects any other text as `unsupported_invitation`.
    func testInvitationIsTheAppDoorbell() {
        XCTAssertEqual(ClaudeMailboxAcceptance.invitation, MailboxDoorbell.text)
    }

    func testOnlyNewRecordConfirmsOffer() throws {
        try append(record())
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        XCTAssertFalse(try observer.observe(), "An old identical invitation must not acknowledge a new offer")
        try append(record())
        XCTAssertTrue(try observer.observe())
        XCTAssertFalse(try observer.observe())
    }

    func testDifferentSessionDoesNotConfirm() throws {
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        try append(record(sessionID: UUID().uuidString))
        XCTAssertFalse(try observer.observe())
        try append(record())
        XCTAssertTrue(try observer.observe())
    }

    func testTypedInvitationAndAssistantQuoteDoNotConfirm() throws {
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        try append(record(text: ClaudeMailboxAcceptance.invitation))
        try append(record(role: "assistant"))
        try append(record(text: "Quoted: Another Claude session sent a message:\n\(ClaudeMailboxAcceptance.invitation)\n\n"))
        XCTAssertFalse(try observer.observe())
        try append(record())
        XCTAssertTrue(try observer.observe())
    }

    func testPartialRecordWaitsForNewline() throws {
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        let data = try record()
        try append(data.dropLast())
        XCTAssertFalse(try observer.observe())
        try append(Data([0x0A]))
        XCTAssertTrue(try observer.observe())
    }

    func testFileCreatedAfterOfferCanConfirm() throws {
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        XCTAssertFalse(try observer.observe())
        try append(record())
        XCTAssertTrue(try observer.observe())
    }

    func testLateCreatedTranscriptCannotConfirmHistoricalInvitation() throws {
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        try append(record(timestamp: Date().addingTimeInterval(-60)))
        XCTAssertFalse(try observer.observe(), "A newly created file can contain old session history")
        try append(record(timestamp: Date().addingTimeInterval(1)))
        XCTAssertTrue(try observer.observe())
    }

    func testReplacingTranscriptDoesNotRebindObserver() throws {
        try append(Data())
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        try FileManager.default.removeItem(at: transcript)
        try append(record())
        XCTAssertFalse(try observer.observe(), "A replacement file is not the offered session's open transcript")
    }

    func testLargeUnrelatedRecordDoesNotPreventLaterAcceptance() throws {
        let observer = try ClaudeMailboxAcceptance(path: transcript.path, sessionID: session)
        try append(Data(repeating: 0x78, count: 2 * 1024 * 1024))
        try append(Data([0x0A]))
        try append(record())
        var observed = false
        for _ in 0..<40 {
            if try observer.observe() { observed = true; break }
        }
        XCTAssertTrue(observed)
    }
}

final class GrokMailboxAcceptanceTests: XCTestCase {
    private let bound = "909f490f-cdde-47ed-b8e6-2ec3274979e0"
    private let other = "01a1992a-fd6e-77a3-82fc-f10d48225436"
    private let birth: UInt64 = 1_793_570_764_543_966

    private func registry(_ entries: [(String, Int, UInt64)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries.map {
            ["session_id": $0.0, "pid": $0.1, "pid_start": $0.2, "cwd": "/tmp/p", "opened_at": "2026-11-01T22:06:05Z"]
        })
    }

    func testNativeRingNeedsTheTUIToHoldOnlyTheBoundSession() throws {
        // One session, the bound one: the panel shows it.
        XCTAssertTrue(GrokMailboxAcceptance.showsOnlyBoundSession(
            registry: try registry([(bound, 44036, birth), (other, 51000, birth)]),
            pid: 44036, birthMicros: birth + 400_000, sessionID: bound.uppercased()))
        // After /new or /resume the TUI holds two sessions: refuse.
        XCTAssertFalse(GrokMailboxAcceptance.showsOnlyBoundSession(
            registry: try registry([(bound, 44036, birth), (other, 44036, birth)]),
            pid: 44036, birthMicros: birth, sessionID: bound))
        // The TUI holds a different session only.
        XCTAssertFalse(GrokMailboxAcceptance.showsOnlyBoundSession(
            registry: try registry([(other, 44036, birth)]), pid: 44036, birthMicros: birth, sessionID: bound))
        // The entry belongs to an earlier process that had this PID.
        XCTAssertFalse(GrokMailboxAcceptance.showsOnlyBoundSession(
            registry: try registry([(bound, 44036, birth - 60_000_000)]), pid: 44036, birthMicros: birth, sessionID: bound))
        // Missing or malformed registry: refuse.
        XCTAssertFalse(GrokMailboxAcceptance.showsOnlyBoundSession(
            registry: try registry([]), pid: 44036, birthMicros: birth, sessionID: bound))
        XCTAssertFalse(GrokMailboxAcceptance.showsOnlyBoundSession(
            registry: Data("{".utf8), pid: 44036, birthMicros: birth, sessionID: bound))
    }

    func testTypedRingRowsCarryOnlyAShortNativeStateToken() {
        XCTAssertEqual(MailboxDispatchLog.nativeStateToken("grok_leader"), "grok_leader")
        XCTAssertEqual(MailboxDispatchLog.nativeStateToken("off:no_socket"), "off:no_socket")
        XCTAssertNil(MailboxDispatchLog.nativeStateToken(""))
        XCTAssertNil(MailboxDispatchLog.nativeStateToken("off:Sandbox"))
        XCTAssertNil(MailboxDispatchLog.nativeStateToken("off: sandbox"))
        XCTAssertNil(MailboxDispatchLog.nativeStateToken("off:\"injected\""))
        XCTAssertNil(MailboxDispatchLog.nativeStateToken(String(repeating: "a", count: 49)))
    }

    func testConfirmationIsTheInvitationEchoedInTheBoundSession() {
        let invitation = ClaudeMailboxAcceptance.invitation
        let queued: [String: Any] = ["jsonrpc": "2.0", "method": "_x.ai/queue/changed",
            "params": ["sessionId": bound, "entries": [["id": "e1", "version": 0, "kind": "prompt", "text": invitation]]]]
        XCTAssertTrue(GrokMailboxAcceptance.confirms(frame: queued, sessionID: bound))
        XCTAssertFalse(GrokMailboxAcceptance.confirms(frame: queued, sessionID: other))
        let otherText: [String: Any] = ["method": "_x.ai/queue/changed",
            "params": ["sessionId": bound, "entries": [["kind": "prompt", "text": "operator prompt"]]]]
        XCTAssertFalse(GrokMailboxAcceptance.confirms(frame: otherText, sessionID: bound))
        let userRow: [String: Any] = ["method": "session/update", "params": ["sessionId": bound,
            "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": invitation]]]]
        XCTAssertTrue(GrokMailboxAcceptance.confirms(frame: userRow, sessionID: bound))
        let agentRow: [String: Any] = ["method": "session/update", "params": ["sessionId": bound,
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": invitation]]]]
        XCTAssertFalse(GrokMailboxAcceptance.confirms(frame: agentRow, sessionID: bound))
        XCTAssertFalse(GrokMailboxAcceptance.confirms(frame: ["method": "_x.ai/sessions/changed",
            "params": ["sessionId": bound]], sessionID: bound))
    }
}
