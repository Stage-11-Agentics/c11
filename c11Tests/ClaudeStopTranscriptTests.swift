import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// B028: multi-day transcripts must cost only one bounded tail read per Stop.
final class ClaudeStopTranscriptTests: XCTestCase {
    private func record(_ text: String, role: String = "assistant") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["message": ["role": role, "content": text]])
        data.append(0x0A)
        return data
    }

    private func withTranscript(_ data: Data, body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.jsonl")
        try data.write(to: path)
        try body(path.path)
    }

    private func summary(_ message: String? = nil, cwd: String? = nil,
                         body: String? = nil, subtitle: String? = nil) -> (subtitle: String, body: String)? {
        ClaudeStopTranscript.summary(cwd: cwd, lastAssistantMessage: message,
                                     fallbackBody: body, fallbackSubtitle: subtitle)
    }

    func testMultiMegabyteTranscriptPreservesCompletionTextAndCapsActualRead() throws {
        let filler = try record(String(repeating: "x", count: 1024), role: "user")
        var data = Data()
        for _ in 0..<4096 { data.append(filler) }
        data.append(try record("  Finished\n\t synthetic   fixture  "))
        try withTranscript(data) { path in
            let result = try XCTUnwrap(ClaudeStopTranscript.read(path: path))
            XCTAssertEqual(result.bytesRead, ClaudeStopTranscript.defaultMaxTailBytes)
            XCTAssertEqual(result.lastAssistantMessage, "Finished synthetic fixture")
            let completion = try XCTUnwrap(summary(result.lastAssistantMessage, cwd: "/tmp/sample-project"))
            XCTAssertEqual(completion.subtitle, "Completed in sample-project")
            XCTAssertEqual(completion.body, "Finished synthetic fixture")
            XCTAssertEqual(summary(result.lastAssistantMessage)?.subtitle, "Completed")
        }
    }

    func testOlderAssistantIsOutsideTailAndUsesSessionFallback() throws {
        var data = try record("old assistant")
        let filler = try record(String(repeating: "x", count: 1024), role: "user")
        for _ in 0..<4096 { data.append(filler) }
        var calls = 0
        let result = try XCTUnwrap(ClaudeStopTranscript.read(fileSize: UInt64(data.count)) { offset, length in
            calls += 1
            XCTAssertEqual(length, ClaudeStopTranscript.defaultMaxTailBytes)
            XCTAssertEqual(offset, UInt64(data.count - length))
            return data.subdata(in: Int(offset)..<(Int(offset) + length))
        })
        XCTAssertEqual(calls, 1)
        XCTAssertNil(result.lastAssistantMessage)
        try withTranscript(data) { path in
            let actual = try XCTUnwrap(ClaudeStopTranscript.read(path: path))
            XCTAssertNil(actual.lastAssistantMessage)
            XCTAssertLessThanOrEqual(actual.bytesRead, ClaudeStopTranscript.defaultMaxTailBytes)
        }
        let completion = try XCTUnwrap(summary(cwd: "/tmp/project", body: "saved body", subtitle: "saved subtitle"))
        XCTAssertEqual(completion.subtitle, "Completed")
        XCTAssertEqual(completion.body, "Claude session completed in project. Last: saved body")
    }

    func testMissingAndUnreadablePathsUseFallback() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(ClaudeStopTranscript.read(path: missing.path))
        // A file used as a parent is unreadable regardless of the test user's uid.
        try withTranscript(Data()) { path in
            XCTAssertNil(ClaudeStopTranscript.read(path: path + "/child.jsonl"))
        }
        XCTAssertEqual(summary(body: "saved")?.body, "Claude session completed. Last: saved")
        XCTAssertNil(summary())
    }

    func testNilAndEmptyFallbackContextPreservePrecedence() {
        XCTAssertNil(summary())
        XCTAssertEqual(summary(cwd: "")?.body, "Claude session completed")
        XCTAssertEqual(summary(body: "", subtitle: "must not appear")?.body, "Claude session completed")
        XCTAssertEqual(summary(subtitle: "saved subtitle")?.body, "Claude session completed. Last: saved subtitle")
    }

    func testCapInsideMultibyteScalarDropsPartialRecordBeforeDecoding() throws {
        let final = try record("complete assistant")
        var tail = Data([0x82, 0xAC, 0x0A]) // cutoff inside UTF-8 euro sign
        tail.append(final)
        let result = ClaudeStopTranscript.read(fileSize: UInt64(tail.count + 100), maxTailBytes: tail.count) { _, _ in tail }
        XCTAssertEqual(result?.lastAssistantMessage, "complete assistant")
    }

    func testLongAssistantWithinCapKeepsExisting120CharacterTruncation() throws {
        let long = String(repeating: "z", count: 200_000)
        try withTranscript(try record(long)) { path in
            let result = try XCTUnwrap(ClaudeStopTranscript.read(path: path))
            XCTAssertEqual(result.lastAssistantMessage, String(repeating: "z", count: 119) + "…")
            XCTAssertEqual(summary(result.lastAssistantMessage)?.body, result.lastAssistantMessage)
        }
    }

    func testAssistantRecordLargerThanCapFallsBack() throws {
        try withTranscript(try record(String(repeating: "z", count: 300_000))) { path in
            let result = try XCTUnwrap(ClaudeStopTranscript.read(path: path))
            XCTAssertEqual(result.bytesRead, ClaudeStopTranscript.defaultMaxTailBytes)
            XCTAssertNil(result.lastAssistantMessage)
            XCTAssertEqual(summary(result.lastAssistantMessage, body: "saved")?.body,
                           "Claude session completed. Last: saved")
        }
    }

    func testMalformedAndTruncatedFinalRecordsKeepEarlierCompleteAssistant() throws {
        var data = try record("earlier complete")
        data.append(Data("not JSON\n{\"message\":{\"role\":\"assistant\",\"content\":\"cut".utf8))
        try withTranscript(data) { path in
            XCTAssertEqual(ClaudeStopTranscript.read(path: path)?.lastAssistantMessage, "earlier complete")
        }
    }

    func testTextBlocksAndStringContentKeepLatestNonemptyAssistant() throws {
        var data = try record("earlier")
        data.append(try JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": [
            ["type": "text", "text": " first\nblock "],
            ["type": "tool_use", "text": "ignored"],
            ["type": "text", "text": " second block "],
        ]]]))
        data.append(0x0A)
        data.append(try record("   "))
        data.append(try record("user text", role: "user"))
        try withTranscript(data) { path in
            XCTAssertEqual(ClaudeStopTranscript.read(path: path)?.lastAssistantMessage, "first block second block")
        }
    }

    func testSmallFileAndValidFinalRecordWithoutNewline() throws {
        var data = try record("final")
        data.removeLast()
        let result = ClaudeStopTranscript.read(fileSize: UInt64(data.count)) { offset, length in
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(length, data.count)
            return data
        }
        XCTAssertEqual(result?.lastAssistantMessage, "final")
        XCTAssertEqual(result?.bytesRead, data.count)
    }

    func testInvalidUtf8AndReadFailureRemainNonthrowing() {
        let invalid = ClaudeStopTranscript.read(fileSize: 2) { _, _ in Data([0xFF, 0x0A]) }
        XCTAssertNil(invalid)
        let failed = ClaudeStopTranscript.read(fileSize: 100) { _, _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertNil(failed)
        XCTAssertEqual(summary(body: "saved")?.body, "Claude session completed. Last: saved")
    }

    func testInvalidCapDoesNotReadAndEmptyFileHasNoMessage() {
        for cap in [0, -1] {
            XCTAssertNil(ClaudeStopTranscript.read(fileSize: 100, maxTailBytes: cap) { _, _ in
                XCTFail("invalid cap must not read")
                return Data()
            })
        }
        let empty = ClaudeStopTranscript.read(fileSize: 0) { offset, length in
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(length, 0)
            return Data()
        }
        XCTAssertNil(empty?.lastAssistantMessage)
        XCTAssertEqual(empty?.bytesRead, 0)
    }
}
