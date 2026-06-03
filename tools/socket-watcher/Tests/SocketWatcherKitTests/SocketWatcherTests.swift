import XCTest
@testable import SocketWatcherKit

final class SocketWatcherTests: XCTestCase {
    // MARK: - Helpers

    /// Captures emitted events in memory; thread-safe so the watcher's
    /// run loop and the test thread can read/write concurrently.
    final class RecordingEmitter: EventEmitting, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [SocketWatcherEvent] = []
        private var raw: [String] = []

        func emit(_ event: SocketWatcherEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var snapshot: [SocketWatcherEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    struct StubSnapshotter: SnapshotCapturing {
        func captureLsof(path: String) -> String { "STUB_LSOF for \(path)" }
        func capturePs() -> String { "STUB_PS rows" }
    }

    private func makeTempFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("c11-socket-watcher-test-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data("seed".utf8), attributes: nil)
        return path
    }

    // MARK: - Tests

    /// AC2: emits a `delete` event when the target file is unlinked,
    /// with a populated JSON-Lines record (timestamp + path + lsof + ps).
    func testWatcherEmitsDeleteEvent() throws {
        let path = try makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let emitter = RecordingEmitter()
        let watcher = SocketWatcher(
            path: path,
            snapshotter: StubSnapshotter(),
            emitter: emitter,
            pollInterval: 0.02
        )

        let runExpectation = expectation(description: "watcher returns")
        DispatchQueue.global(qos: .userInitiated).async {
            try? watcher.run(maxEvents: 1)
            runExpectation.fulfill()
        }

        // Give the watcher a moment to arm before we yank the file.
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(unlink(path), 0, "unlink failed errno=\(errno)")

        wait(for: [runExpectation], timeout: 2.0)

        let events = emitter.snapshot
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.event, .delete)
        XCTAssertEqual(event.path, path)
        XCTAssertEqual(event.lsof, "STUB_LSOF for \(path)")
        XCTAssertEqual(event.ps, "STUB_PS rows")
        XCTAssertFalse(event.timestamp.isEmpty)
    }

    /// AC3: after a delete, the watcher re-arms on the recreated file
    /// and emits a `rebound` event, then another `delete` on the second
    /// unlink.
    func testWatcherReArmsAfterDelete() throws {
        let path = try makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let emitter = RecordingEmitter()
        let watcher = SocketWatcher(
            path: path,
            snapshotter: StubSnapshotter(),
            emitter: emitter,
            pollInterval: 0.02
        )

        let runExpectation = expectation(description: "watcher returns")
        DispatchQueue.global(qos: .userInitiated).async {
            // 3 events: delete -> rebound -> delete.
            try? watcher.run(maxEvents: 3)
            runExpectation.fulfill()
        }

        // First delete.
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(unlink(path), 0)

        // Wait for the watcher to notice + emit, then recreate the
        // file so it can re-arm.
        try waitFor(emitter, count: 1, timeout: 2.0)
        FileManager.default.createFile(atPath: path, contents: Data("again".utf8), attributes: nil)

        // Wait for the rebound event, then unlink a second time.
        try waitFor(emitter, count: 2, timeout: 2.0)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(unlink(path), 0)

        wait(for: [runExpectation], timeout: 4.0)

        let events = emitter.snapshot
        XCTAssertEqual(events.count, 3, "expected delete -> rebound -> delete, got \(events.map { $0.event })")
        XCTAssertEqual(events[0].event, .delete)
        XCTAssertEqual(events[1].event, .rebound)
        XCTAssertEqual(events[2].event, .delete)
    }

    /// JSON Lines round-trip: a recorded event survives encode/decode
    /// with the snake-cased `ts` key the runbook documents.
    func testEventEncodesAsJSONLines() throws {
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
            func append(_ s: String) {
                lock.lock(); lines.append(s); lock.unlock()
            }
        }
        let sink = Sink()
        let emitter = JSONLinesEmitter { [sink] line in
            sink.append(line)
        }

        let event = SocketWatcherEvent(
            timestamp: "2026-05-18T20:00:00.000Z",
            event: .delete,
            path: "/tmp/some-socket.sock",
            lsof: "lsof output",
            ps: "ps output"
        )
        emitter.emit(event)

        XCTAssertEqual(sink.lines.count, 1)
        let line = try XCTUnwrap(sink.lines.first)
        XCTAssertTrue(line.hasSuffix("\n"))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["ts"] as? String, "2026-05-18T20:00:00.000Z")
        XCTAssertEqual(parsed?["event"] as? String, "delete")
        XCTAssertEqual(parsed?["path"] as? String, "/tmp/some-socket.sock")
        XCTAssertEqual(parsed?["lsof"] as? String, "lsof output")
        XCTAssertEqual(parsed?["ps"] as? String, "ps output")
    }

    // MARK: - Helpers

    private func waitFor(
        _ emitter: RecordingEmitter,
        count: Int,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if emitter.snapshot.count >= count { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail(
            "timed out waiting for \(count) events; saw \(emitter.snapshot.count)",
            file: file,
            line: line
        )
    }
}
