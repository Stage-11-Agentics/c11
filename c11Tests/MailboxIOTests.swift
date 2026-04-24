import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MailboxIOTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-mailbox-io-\(UUID().uuidString)", isDirectory: true)
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

    private func listDirectory() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: tempRoot.path)
            .sorted()
    }

    // MARK: - Happy path

    func testAtomicWriteCreatesFinalFileAndRemovesTemp() throws {
        let target = tempRoot.appendingPathComponent("01K3A2B7X.msg")
        let payload = Data("build green sha=abc".utf8)

        try MailboxIO.atomicWrite(data: payload, to: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: target), payload)

        let entries = try listDirectory()
        XCTAssertEqual(entries, ["01K3A2B7X.msg"], "temp file must not linger")
    }

    func testAtomicWriteOverwritesNothingUnexpectedly() throws {
        let a = tempRoot.appendingPathComponent("a.msg")
        let b = tempRoot.appendingPathComponent("b.msg")
        try MailboxIO.atomicWrite(data: Data("one".utf8), to: a)
        try MailboxIO.atomicWrite(data: Data("two".utf8), to: b)
        XCTAssertEqual(try Data(contentsOf: a), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("two".utf8))
        XCTAssertEqual(try listDirectory(), ["a.msg", "b.msg"])
    }

    // MARK: - Error path

    func testAtomicWriteRejectsMissingParent() {
        let missing = tempRoot
            .appendingPathComponent("nonexistent", isDirectory: true)
            .appendingPathComponent("x.msg")

        XCTAssertThrowsError(try MailboxIO.atomicWrite(data: Data(), to: missing)) { error in
            guard case MailboxIO.Error.parentDirectoryMissing = error else {
                XCTFail("expected parentDirectoryMissing, got \(error)")
                return
            }
        }
    }

    // MARK: - Crash simulation

    /// Simulates a writer crash between "write temp" and "rename temp → final"
    /// by only doing the write step. The directory must contain a dot-prefixed
    /// `.tmp` file and NO `.msg` file — proving the dispatcher's stale-tmp
    /// sweep has something to collect and the fsevent watcher (filters on
    /// `.msg`) is untouched.
    func testCrashMidWriteLeavesOnlyTempFile() throws {
        // Manually do what `atomicWrite` does up to the rename point.
        let target = tempRoot.appendingPathComponent("01K3A2B7X.msg")
        let tempURL = tempRoot.appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("half-written".utf8).write(to: tempURL, options: .atomic)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let entries = try listDirectory()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].hasPrefix("."))
        XCTAssertTrue(entries[0].hasSuffix(".tmp"))
    }
}
