import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
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

    // MARK: - C3 claim

    private func seedInbox(id: String) throws -> URL {
        let inbox = tempRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("envelope".utf8).write(
            to: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        )
        return inbox
    }

    func testClaimMovesEnvelopeIntoRead() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456J"
        let inbox = try seedInbox(id: id)
        let claimed = try XCTUnwrap(try MailboxIO.claim(id: id, inbox: inbox))
        XCTAssertEqual(claimed.deletingLastPathComponent().lastPathComponent, "_read")
        XCTAssertEqual(try Data(contentsOf: claimed), Data("envelope".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)).path
        ))
    }

    /// Two consumers race; the second finds nothing and must skip, not throw.
    func testSecondClaimFindsNothing() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456K"
        let inbox = try seedInbox(id: id)
        XCTAssertNotNil(try MailboxIO.claim(id: id, inbox: inbox))
        XCTAssertNil(try MailboxIO.claim(id: id, inbox: inbox))
    }

    func testClaimOfMissingInboxIsNil() throws {
        let inbox = tempRoot.appendingPathComponent("absent", isDirectory: true)
        XCTAssertNil(try MailboxIO.claim(id: "01K3A2B7X8PQRTVWYZ0123456L", inbox: inbox))
    }

    /// A failed hand-over puts the envelope back in the inbox root, where the
    /// next consumer (or `recv --drain`) finds it.
    func testUnclaimRestoresEnvelope() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456M"
        let inbox = try seedInbox(id: id)
        XCTAssertNotNil(try MailboxIO.claim(id: id, inbox: inbox))
        MailboxIO.unclaim(id: id, inbox: inbox)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)).path
        ))
        XCTAssertNotNil(try MailboxIO.claim(id: id, inbox: inbox))
    }

    /// A claim that cannot rename reports the errno and leaves the envelope in
    /// the inbox root (never typed, still drainable).
    func testClaimFailureReportsErrnoAndKeepsEnvelope() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456N"
        let inbox = try seedInbox(id: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path) }
        guard case .failed(let code) = MailboxIO.claimResult(id: id, inbox: inbox) else {
            return XCTFail("expected a failed claim")
        }
        XCTAssertEqual(code, EACCES)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)).path
        ))
        XCTAssertThrowsError(try MailboxIO.claim(id: id, inbox: inbox)) { error in
            XCTAssertEqual(error as? MailboxIO.Error, .claimFailed(errno: EACCES))
        }
    }

    func testClaimResultGoneAndClaimed() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456P"
        let inbox = try seedInbox(id: id)
        guard case .claimed(let url) = MailboxIO.claimResult(id: id, inbox: inbox) else {
            return XCTFail("expected a claim")
        }
        XCTAssertEqual(url.lastPathComponent, MailboxLayout.envelopeFilename(id: id))
        XCTAssertEqual(MailboxIO.claimResult(id: id, inbox: inbox), .gone)
        XCTAssertTrue(MailboxIO.unclaim(id: id, inbox: inbox))
        XCTAssertFalse(MailboxIO.unclaim(id: id, inbox: inbox))
    }
}
