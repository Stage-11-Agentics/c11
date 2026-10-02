import XCTest
import Darwin

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class JournalSpoolTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("journal-spool-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private var layout: JournalStorageLayout { JournalStorageLayout(directory: directory) }

    // Offline delivery and ambiguous acknowledgement repeat the exact original event ID.
    func testOfflineDraftDrainsOnceAndLostDeleteReturnsOriginalReceipt() throws {
        let spool = JournalSpool(layout: layout)
        let draft = JournalTestData.draft(.questionRequested)
        XCTAssertTrue(spool.write(draft))
        let store = try JournalStore(layout: layout, clock: { 1000 })
        var receipts: [JournalReceipt] = []
        let first = spool.drain(now: 1000) { receipts.append(try store.append(draft: $0, context: JournalContext(eligible: true, historical: true)).receipt) }
        XCTAssertEqual(first.committed, 1)
        XCTAssertEqual(try store.current(owner: draft.owner!)?.confirmation, .unconfirmed)
        XCTAssertTrue(spool.write(draft)) // Models a crash after commit, before consumed file deletion.
        _ = spool.drain(now: 1000) { receipts.append(try store.append(draft: $0, context: JournalContext(eligible: true, historical: true)).receipt) }
        XCTAssertEqual(receipts.map(\.sequence), [1, 1])
        XCTAssertTrue(receipts[1].replayed)
        XCTAssertEqual(spool.drain(now: 1000) { _ in XCTFail("already drained") }.committed, 0)
    }

    // Audit truncated tail: never execute an incomplete JSON line.
    func testPartialTailIsDiscardedWithoutExecutingIt() throws {
        try layout.prepare()
        let draft = JournalTestData.draft(.questionRequested)
        let path = layout.spool.appendingPathComponent("\(getpid()).\(UUID().uuidString).ready")
        var data = try draft.canonicalData(); data.append(10); data.append(contentsOf: "{\"event_id\":".utf8)
        try data.write(to: path)
        var ids: [UUID] = []
        let counts = JournalSpool(layout: layout).drain(now: 1000) { ids.append($0.eventID) }
        XCTAssertEqual(ids, [draft.eventID])
        XCTAssertEqual(counts.partial, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    // Unknown/stale attribution is retained diagnostically, never rebound to a live tab.
    func testUnattributedSpoolDoesNotCreateCurrentState() throws {
        let draft = JournalTestData.draft(.questionRequested)
        let spool = JournalSpool(layout: layout)
        XCTAssertTrue(spool.write(draft))
        let store = try JournalStore(layout: layout, clock: { 1000 })
        _ = spool.drain(now: 1000) { _ = try store.append(draft: $0, context: JournalContext(eligible: false, historical: true)) }
        XCTAssertTrue(try store.baselines().isEmpty)
        XCTAssertEqual(try store.readPage(after: 0).first?.effect, .unattributed)
    }

    // Bounded best effort admits no new file at cap and never removes the first one.
    func testSpoolSaturationAndActiveWriterAreBounded() throws {
        var budgets = JournalBudgets(); budgets.spoolFiles = 1
        let spool = JournalSpool(layout: layout, budgets: budgets)
        XCTAssertTrue(spool.write(JournalTestData.draft(.questionRequested)))
        XCTAssertFalse(spool.write(JournalTestData.draft(.turnCompleted)))
        let ready = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: layout.spool, includingPropertiesForKeys: nil).first { $0.pathExtension == "ready" })
        let active = ready.deletingPathExtension().appendingPathExtension("open")
        try FileManager.default.moveItem(at: ready, to: active)
        XCTAssertEqual(spool.drain(now: 1000) { _ in XCTFail("writer is alive") }.committed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    }

    func testSymlinkSpoolEntryIsNeverReadOrRemoved() throws {
        try layout.prepare()
        let outside = directory.appendingPathComponent("private-sentinel")
        try Data("PRIVATE-SENTINEL".utf8).write(to: outside)
        let link = layout.spool.appendingPathComponent("\(getpid()).\(UUID().uuidString).ready")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = JournalSpool(layout: layout).drain(now: 1000) { _ in XCTFail("symlink followed") }
        XCTAssertEqual(try String(contentsOf: outside), "PRIVATE-SENTINEL")
    }
}
