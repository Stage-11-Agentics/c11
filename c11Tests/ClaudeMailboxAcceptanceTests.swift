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

    private func record(sessionID: String? = nil, role: String = "user", text: String? = nil) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": role, "sessionId": sessionID ?? session,
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
