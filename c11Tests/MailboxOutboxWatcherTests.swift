import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MailboxOutboxWatcherTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-mailbox-watch-\(UUID().uuidString)", isDirectory: true)
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

    private func writeEnvelopeAtomically(name: String, body: String) throws {
        let temp = tempRoot.appendingPathComponent(".\(UUID().uuidString).tmp")
        let dest = tempRoot.appendingPathComponent(name)
        try Data(body.utf8).write(to: temp)
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    // MARK: - Periodic sweep

    /// Fast sweep interval proves the periodic path fires without relying on
    /// fsevent delivery (which can stall on CI).
    func testPeriodicSweepDetectsNewEnvelope() throws {
        let expectation = expectation(description: "handler fired via sweep")
        expectation.assertForOverFulfill = false

        let watcher = MailboxOutboxWatcher(
            directoryURL: tempRoot,
            debounceInterval: 0.01,
            pollingInterval: 0.1
        ) { urls in
            if urls.contains(where: { $0.lastPathComponent == "01K.msg" }) {
                expectation.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        // Write after start() so the initial snapshot picks up nothing and
        // the sweep has to detect the new file.
        try writeEnvelopeAtomically(name: "01K.msg", body: "{}")
        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - Filtering

    func testDotTempFilesAreIgnored() throws {
        let expectation = expectation(description: "handler fires on msg only")
        expectation.assertForOverFulfill = false
        var observedNames: Set<String> = []
        let lock = NSLock()

        let watcher = MailboxOutboxWatcher(
            directoryURL: tempRoot,
            debounceInterval: 0.01,
            pollingInterval: 0.1
        ) { urls in
            lock.lock()
            for url in urls {
                observedNames.insert(url.lastPathComponent)
            }
            lock.unlock()
            if observedNames.contains("final.msg") {
                expectation.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        // Drop a bare .tmp file — must be ignored.
        let temp = tempRoot.appendingPathComponent(".pending.tmp")
        try Data().write(to: temp)

        // Drop an unrelated extension — must be ignored.
        try Data().write(to: tempRoot.appendingPathComponent("README.txt"))

        // And finally, the real envelope.
        try writeEnvelopeAtomically(name: "final.msg", body: "{}")

        wait(for: [expectation], timeout: 3.0)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertFalse(observedNames.contains(".pending.tmp"))
        XCTAssertFalse(observedNames.contains("README.txt"))
    }

    // MARK: - Same envelope not re-delivered

    func testSameFileNotReportedTwice() throws {
        let firstShot = expectation(description: "first .msg seen")
        firstShot.assertForOverFulfill = false

        var callCount = 0
        let callLock = NSLock()

        let watcher = MailboxOutboxWatcher(
            directoryURL: tempRoot,
            debounceInterval: 0.01,
            pollingInterval: 0.1
        ) { urls in
            callLock.lock()
            if urls.contains(where: { $0.lastPathComponent == "a.msg" }) {
                callCount += 1
                if callCount == 1 { firstShot.fulfill() }
            }
            callLock.unlock()
        }
        watcher.start()
        defer { watcher.stop() }

        try writeEnvelopeAtomically(name: "a.msg", body: "{}")
        wait(for: [firstShot], timeout: 3.0)

        // Let several sweeps pass; the same file must not fire again because
        // it's in the known-set.
        Thread.sleep(forTimeInterval: 0.5)

        callLock.lock()
        defer { callLock.unlock() }
        XCTAssertEqual(callCount, 1, "known .msg files must not refire after first report")
    }

    // MARK: - Manual trigger

    func testTriggerImmediateScanFiresSynchronously() throws {
        let expectation = expectation(description: "manual trigger")
        expectation.assertForOverFulfill = false

        let watcher = MailboxOutboxWatcher(
            directoryURL: tempRoot,
            debounceInterval: 0.01,
            pollingInterval: 60.0  // effectively disables the polling timer
        ) { urls in
            if urls.contains(where: { $0.lastPathComponent == "b.msg" }) {
                expectation.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        try writeEnvelopeAtomically(name: "b.msg", body: "{}")
        watcher.triggerImmediateScan()

        wait(for: [expectation], timeout: 2.0)
    }
}
