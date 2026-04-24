import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxDispatchLogTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-mailbox-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func makeLog() -> (MailboxDispatchLog, URL) {
        let url = tempRoot.appendingPathComponent("_dispatch.log")
        return (
            MailboxDispatchLog(
                url: url,
                label: "com.stage11.c11.mailbox.log.test-\(UUID().uuidString)"
            ),
            url
        )
    }

    private func readLines(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - One line per event

    func testAppendWritesOneNDJSONLine() throws {
        let (log, url) = makeLog()
        log.append(
            .received(id: "01K3A2B7X8PQRTVWYZ0123456J", from: "builder", to: "watcher", topic: nil)
        )
        log.flush()

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "received")
        XCTAssertEqual(obj?["id"] as? String, "01K3A2B7X8PQRTVWYZ0123456J")
        XCTAssertEqual(obj?["from"] as? String, "builder")
        XCTAssertEqual(obj?["to"] as? String, "watcher")
        XCTAssertNil(obj?["topic"])
    }

    // MARK: - Every event variant encodes

    func testEveryEventVariantSerializes() throws {
        let (log, url) = makeLog()
        log.append(.received(id: "A", from: "builder", to: nil, topic: "ci.status"))
        log.append(.resolved(id: "A", recipients: ["watcher", "tester"]))
        log.append(.copied(id: "A", recipient: "watcher"))
        log.append(.handler(
            id: "A",
            recipient: "watcher",
            handler: "stdin",
            outcome: .ok,
            bytes: 67,
            elapsedMs: 12
        ))
        log.append(.rejected(id: "B", reason: "invalid ULID"))
        log.append(.cleaned(id: "A"))
        log.append(.replayed(id: "C"))
        log.append(.gc(tempFilesRemoved: 3))
        log.flush()

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, 8)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(obj?["ts"])
            XCTAssertNotNil(obj?["event"])
        }
    }

    // MARK: - Prior content is preserved on second open

    func testAppendPreservesPriorContent() throws {
        let (log1, url) = makeLog()
        log1.append(.cleaned(id: "A"))
        log1.flush()

        // A second log handle (e.g., a dispatcher restart) should NOT truncate.
        let log2 = MailboxDispatchLog(
            url: url,
            label: "com.stage11.c11.mailbox.log.second-\(UUID().uuidString)"
        )
        log2.append(.cleaned(id: "B"))
        log2.flush()

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"A\""))
        XCTAssertTrue(lines[1].contains("\"B\""))
    }

    // MARK: - Concurrent appends

    /// The off-main utility queue serializes writes; 16 concurrent producers
    /// must not interleave partial NDJSON lines.
    func testSixteenConcurrentAppendsProduceSixteenValidLines() throws {
        let (log, url) = makeLog()
        let count = 16

        DispatchQueue.concurrentPerform(iterations: count) { index in
            log.append(.cleaned(id: "id-\(index)"))
        }
        log.flush()

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, count, "one NDJSON line per append")

        var seenIds = Set<String>()
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(obj)
            XCTAssertEqual(obj?["event"] as? String, "cleaned")
            if let id = obj?["id"] as? String {
                seenIds.insert(id)
            }
        }
        XCTAssertEqual(seenIds.count, count, "every thread's id is present exactly once")
    }

    // MARK: - Schema fidelity

    func testReceivedOmitsNilToAndTopic() throws {
        let str = MailboxDispatchLog.serialize(
            event: .received(id: "A", from: "builder", to: nil, topic: nil),
            at: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(str.hasSuffix("\n"))
        let data = Data(str.dropLast().utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "received")
        XCTAssertNil(obj?["to"])
        XCTAssertNil(obj?["topic"])
    }

    func testHandlerOmitsNilBytesAndElapsed() throws {
        let str = MailboxDispatchLog.serialize(
            event: .handler(id: "A", recipient: "w", handler: "silent", outcome: .ok, bytes: nil, elapsedMs: nil),
            at: Date(timeIntervalSince1970: 0)
        )
        let data = Data(str.dropLast().utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["bytes"])
        XCTAssertNil(obj?["elapsed_ms"])
        XCTAssertEqual(obj?["outcome"] as? String, "ok")
    }
}
