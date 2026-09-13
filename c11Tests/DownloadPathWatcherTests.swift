import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-222. Behavioural tests for `DownloadPathWatcher`, the watch behind
/// `browser download wait --path`, driven against real files in a real temp
/// directory — no stubbed file system, because the whole bug was about which
/// vnode events the kernel does and does not deliver.
///
/// The regression these pin down: watching only the parent directory misses a
/// file that is created empty and then written in place, because a child's
/// contents changing does not disturb the directory's own vnode. The wait then
/// ran to its full timeout even though the download had landed.
///
/// The last test covers the other half of the contract — the descriptor
/// lifetime invariants from C11-209. Every descriptor the watcher opens must be
/// closed exactly once, from its source's cancel handler, including on the
/// deadline path where the caller's await has already unwound.
final class DownloadPathWatcherTests: XCTestCase {

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        func set(_ value: Bool) {
            lock.lock()
            stored = value
            lock.unlock()
        }
        var value: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-download-path-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Readiness predicate

    func testIsPathReadyRequiresBytesOnDisk() throws {
        let missing = directory.appendingPathComponent("nope.bin")
        XCTAssertFalse(DownloadPathWatcher.isPathReady(missing.path))

        let empty = directory.appendingPathComponent("empty.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: nil))
        XCTAssertFalse(DownloadPathWatcher.isPathReady(empty.path))

        let filled = directory.appendingPathComponent("filled.bin")
        try Data("payload".utf8).write(to: filled)
        XCTAssertTrue(DownloadPathWatcher.isPathReady(filled.path))
    }

    // MARK: - Resolution paths

    /// What a real `WKDownload` does: stage elsewhere, rename over the target.
    /// This is the case that already worked, kept so the fix cannot regress it.
    func testResolvesWhenFileIsRenamedIntoPlace() throws {
        let target = directory.appendingPathComponent("download.bin")
        let watcher = makeWatcher(path: target.path)
        let outcome = OutcomeBox()
        let resolved = expectation(description: "watcher resolved")

        XCTAssertTrue(watcher.start(timeout: 5.0) { value in
            outcome.set(value)
            resolved.fulfill()
        })

        let staging = directory.appendingPathComponent("download.bin.part")
        try Data("payload".utf8).write(to: staging)
        try FileManager.default.moveItem(at: staging, to: target)

        wait(for: [resolved], timeout: 4.0)
        XCTAssertEqual(outcome.value, true)
        watcher.teardown()
        assertEveryDescriptorClosed(watcher)
    }

    /// C11-222 proper: the file appears empty and is then filled in place. The
    /// create produces one directory event (size still zero); the write
    /// produces none, so only a source on the file's own descriptor can see it.
    func testResolvesWhenFileIsCreatedEmptyThenWrittenInPlace() throws {
        let target = directory.appendingPathComponent("download.bin")
        let watcher = makeWatcher(path: target.path)
        let outcome = OutcomeBox()
        let resolved = expectation(description: "watcher resolved")

        XCTAssertTrue(watcher.start(timeout: 5.0) { value in
            outcome.set(value)
            resolved.fulfill()
        })

        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
        Thread.sleep(forTimeInterval: 0.2)
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data("payload".utf8))
        try handle.close()

        // A directory-only watch resolves this at its 5s deadline at the
        // earliest, so a 3s wait is the assertion.
        wait(for: [resolved], timeout: 3.0)
        XCTAssertEqual(outcome.value, true)
        watcher.teardown()
        assertEveryDescriptorClosed(watcher)
    }

    /// Same shape, except the empty file is already there when the wait starts,
    /// so there is no directory event at all to hang the file watch off.
    func testResolvesWhenAlreadyPresentEmptyFileIsFilled() throws {
        let target = directory.appendingPathComponent("download.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))

        let watcher = makeWatcher(path: target.path)
        let outcome = OutcomeBox()
        let resolved = expectation(description: "watcher resolved")

        XCTAssertTrue(watcher.start(timeout: 5.0) { value in
            outcome.set(value)
            resolved.fulfill()
        })

        Thread.sleep(forTimeInterval: 0.2)
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data("payload".utf8))
        try handle.close()

        wait(for: [resolved], timeout: 3.0)
        XCTAssertEqual(outcome.value, true)
        watcher.teardown()
        assertEveryDescriptorClosed(watcher)
    }

    /// A file that never fills must report failure at its deadline and leave no
    /// descriptor behind — including the file descriptor, which this case opens
    /// because the empty target exists from the start.
    func testTimesOutAndClosesEveryDescriptorWhenFileNeverFills() throws {
        let target = directory.appendingPathComponent("download.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))

        let watcher = makeWatcher(path: target.path)
        let outcome = OutcomeBox()
        let resolved = expectation(description: "watcher gave up")

        XCTAssertTrue(watcher.start(timeout: 0.4) { value in
            outcome.set(value)
            resolved.fulfill()
        })

        wait(for: [resolved], timeout: 3.0)
        XCTAssertEqual(outcome.value, false)

        // The caller tears down after its own await unwinds, whether or not the
        // watcher's deadline fired first. Teardown is idempotent.
        watcher.teardown()
        let accounting = assertEveryDescriptorClosed(watcher)
        XCTAssertEqual(
            accounting.opened.count,
            2,
            "expected a directory descriptor and a file descriptor, got \(accounting.opened)"
        )
    }

    /// The caller's `v2AwaitCallback` can unwind on its own deadline while the
    /// watcher is still live. Teardown from that path must reclaim everything
    /// and must not deliver a result afterwards.
    func testTeardownBeforeResolutionClosesDescriptorsAndSuppressesCompletion() throws {
        let target = directory.appendingPathComponent("download.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))

        let watcher = makeWatcher(path: target.path)
        let outcome = OutcomeBox()
        XCTAssertTrue(watcher.start(timeout: 30.0) { value in
            outcome.set(value)
        })

        watcher.teardown()
        watcher.teardown()

        // Filling the file after teardown must not resurrect the completion.
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data("payload".utf8))
        try handle.close()
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertNil(outcome.value)
        assertEveryDescriptorClosed(watcher)
    }

    // MARK: - Helpers

    private func makeWatcher(path: String) -> DownloadPathWatcher {
        DownloadPathWatcher(
            path: path,
            queue: DispatchQueue(label: "c11.tests.download-wait.\(UUID().uuidString)")
        )
    }

    /// Cancel handlers run asynchronously on the watcher's queue, so poll for a
    /// bounded window rather than assuming teardown completed synchronously.
    @discardableResult
    private func assertEveryDescriptorClosed(
        _ watcher: DownloadPathWatcher,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (opened: [Int32], closed: [Int32]) {
        let deadline = Date().addingTimeInterval(3.0)
        var accounting = watcher.descriptorAccounting()
        while accounting.opened.count != accounting.closed.count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            accounting = watcher.descriptorAccounting()
        }
        XCTAssertFalse(accounting.opened.isEmpty, "watcher opened no descriptors", file: file, line: line)
        XCTAssertEqual(
            accounting.closed.sorted(),
            accounting.opened.sorted(),
            "every opened descriptor must be closed exactly once",
            file: file,
            line: line
        )
        return accounting
    }
}
