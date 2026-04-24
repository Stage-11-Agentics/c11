import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxDispatcherGCTests: XCTestCase {

    private var tempState: URL!
    private var workspaceId: UUID!
    private var outbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempState = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-mailbox-gc-\(UUID().uuidString)", isDirectory: true)
        workspaceId = UUID()
        outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
        try FileManager.default.createDirectory(
            at: outbox,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempState, FileManager.default.fileExists(atPath: tempState.path) {
            try FileManager.default.removeItem(at: tempState)
        }
        tempState = nil
        try super.tearDownWithError()
    }

    private func makeDispatcher() -> MailboxDispatcher {
        let resolver = MailboxSurfaceResolver(
            workspaceId: workspaceId,
            liveSurfaces: { [] }
        )
        return MailboxDispatcher(
            workspaceId: workspaceId,
            stateURL: tempState,
            resolver: resolver
        )
    }

    private func writeTempFile(name: String, ageSeconds: TimeInterval) throws {
        let url = outbox.appendingPathComponent(name)
        try Data("partial".utf8).write(to: url)
        let when = Date(timeIntervalSinceNow: -ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }

    // MARK: - Age thresholds

    func testGCRemovesTempFilesOlderThanFiveMinutes() throws {
        try writeTempFile(name: ".abc.tmp", ageSeconds: 10 * 60) // 10 min old
        let dispatcher = makeDispatcher()

        let removed = dispatcher.runGCSweep()
        XCTAssertEqual(removed, 1)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: outbox.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testGCLeavesFreshTempFiles() throws {
        try writeTempFile(name: ".fresh.tmp", ageSeconds: 30)
        let dispatcher = makeDispatcher()

        let removed = dispatcher.runGCSweep()
        XCTAssertEqual(removed, 0)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: outbox.path).sorted()
        XCTAssertEqual(remaining, [".fresh.tmp"])
    }

    // MARK: - Filtering

    func testGCIgnoresNonTempFiles() throws {
        let msgPath = outbox.appendingPathComponent("01K.msg")
        try Data("{}".utf8).write(to: msgPath)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: msgPath.path
        )
        let dispatcher = makeDispatcher()

        let removed = dispatcher.runGCSweep()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: msgPath.path))
    }

    func testGCIgnoresNonDottedTempFiles() throws {
        // A hypothetical writer that didn't dot-prefix their temp. Out of our
        // domain — don't touch it.
        try writeTempFile(name: "notours.tmp", ageSeconds: 3600)
        let dispatcher = makeDispatcher()

        let removed = dispatcher.runGCSweep()
        XCTAssertEqual(removed, 0)
    }

    // MARK: - Mocked clock

    func testGCUsesInjectedClock() throws {
        try writeTempFile(name: ".oldish.tmp", ageSeconds: 299) // just under threshold
        let dispatcher = makeDispatcher()

        // At real-now, still fresh.
        XCTAssertEqual(dispatcher.runGCSweep(now: Date()), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outbox.appendingPathComponent(".oldish.tmp").path))

        // Fast-forward the clock past the threshold.
        let future = Date(timeIntervalSinceNow: 60)
        XCTAssertEqual(dispatcher.runGCSweep(now: future), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.appendingPathComponent(".oldish.tmp").path))
    }

    // MARK: - Dispatch log

    func testGCAppendsGCEventWhenFilesRemoved() throws {
        try writeTempFile(name: ".stale.tmp", ageSeconds: 3600)
        let dispatcher = makeDispatcher()
        _ = dispatcher.runGCSweep()
        dispatcher.log.flush()

        let logURL = MailboxLayout.dispatchLogURL(state: tempState, workspaceId: workspaceId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"event\":\"gc\""))
        XCTAssertTrue(text.contains("\"temp_files_removed\":1"))
    }

    func testGCDoesNotAppendEventWhenNothingRemoved() throws {
        let dispatcher = makeDispatcher()
        _ = dispatcher.runGCSweep()
        dispatcher.log.flush()

        let logURL = MailboxLayout.dispatchLogURL(state: tempState, workspaceId: workspaceId)
        // Log file may not even exist if nothing was appended.
        if FileManager.default.fileExists(atPath: logURL.path) {
            let text = try String(contentsOf: logURL, encoding: .utf8)
            XCTAssertFalse(text.contains("\"event\":\"gc\""))
        }
    }
}
