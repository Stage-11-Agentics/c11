import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-397: the counts behind the subtitle bar's mailbox cell and the message
/// listing behind its drawer, read from a real inbox tree on disk.
final class MailboxPanelMailTests: XCTestCase {

    private var root: URL!
    private var inbox: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-panel-mail-\(UUID().uuidString)", isDirectory: true)
        inbox = MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: UUID())
        try FileManager.default.createDirectory(at: MailboxDrain.readURL(inbox: inbox), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ulid(_ date: Date) -> String {
        MailboxULID.encode(
            timestampMs: UInt64(date.timeIntervalSince1970 * 1000),
            random: [UInt8](repeating: 7, count: MailboxULID.randomByteCount)
        )
    }

    @discardableResult
    private func write(
        _ fields: [String: Any],
        id: String,
        read: Bool = false
    ) throws -> URL {
        var object: [String: Any] = ["version": 1, "id": id, "from": "Board Move", "ts": "2026-10-10T08:33:37Z", "body": ""]
        object.merge(fields) { _, new in new }
        let dir = read ? MailboxDrain.readURL(inbox: inbox) : inbox!
        let url = dir.appendingPathComponent("\(id).msg")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    // MARK: - Counts

    func testSummaryCountsUnreadInRootAndReceivedAcrossBoth() throws {
        let now = Date()
        try write([:], id: ulid(now.addingTimeInterval(-7200)), read: true)
        try write([:], id: ulid(now.addingTimeInterval(-3600)))
        try write([:], id: ulid(now.addingTimeInterval(-60)))
        let summary = MailboxPanelMail.summary(inbox: inbox)
        XCTAssertEqual(summary.unread, 2)
        XCTAssertEqual(summary.received, 3)
        XCTAssertEqual(summary.oldestUnreadAt!.timeIntervalSince1970, now.addingTimeInterval(-3600).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(summary.newestUnreadAt!.timeIntervalSince1970, now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 0.01)
    }

    func testMissingInboxIsEmpty() {
        let summary = MailboxPanelMail.summary(inbox: root.appendingPathComponent("nobody"))
        XCTAssertEqual(summary, .empty)
        XCTAssertFalse(summary.hasMail)
    }

    func testFreshForThreeMinutesAfterNewestUnreadLands() {
        let landed = Date(timeIntervalSince1970: 1_000_000)
        let summary = MailboxPanelMail.Summary(unread: 1, received: 1, newestUnreadAt: landed, oldestUnreadAt: landed)
        XCTAssertTrue(summary.isFresh(now: landed.addingTimeInterval(179)))
        XCTAssertFalse(summary.isFresh(now: landed.addingTimeInterval(181)))
        XCTAssertEqual(summary.freshUntil(now: landed.addingTimeInterval(10)), landed.addingTimeInterval(180))
        XCTAssertNil(summary.freshUntil(now: landed.addingTimeInterval(200)))
        XCTAssertFalse(MailboxPanelMail.Summary(unread: 0, received: 4).isFresh(now: landed))
    }

    func testUlidDateRoundTripsAndRejectsNonUlids() {
        let date = Date(timeIntervalSince1970: 1_791_620_017.123)
        XCTAssertEqual(MailboxPanelMail.ulidDate(ulid(date))!.timeIntervalSince1970, 1_791_620_017.123, accuracy: 0.001)
        XCTAssertNil(MailboxPanelMail.ulidDate("note"))
        XCTAssertNil(MailboxPanelMail.ulidDate("01M4JF4F3KD9YCWKK4W0YPQM3!"))
    }

    func testCountTextCapsAtNinetyNinePlus() {
        XCTAssertEqual(MailboxPanelMail.countText(0), "0")
        XCTAssertEqual(MailboxPanelMail.countText(99), "99")
        XCTAssertEqual(MailboxPanelMail.countText(100), "99+")
    }

    // MARK: - Listing

    func testListingIsNewestFirstWithUnreadState() throws {
        let now = Date()
        let older = ulid(now.addingTimeInterval(-600))
        let newer = ulid(now.addingTimeInterval(-60))
        try write(["topic": "lattice.freeze", "body": "freeze", "ttl_seconds": 1800], id: older, read: true)
        try write(["topic": "lattice.unfreeze", "body": "thaw", "in_reply_to": older, "urgent": true], id: newer)
        let listing = MailboxPanelMail.listing(inbox: inbox)
        XCTAssertEqual(listing.messages.map(\.id), [newer, older])
        XCTAssertEqual(listing.messages.map(\.isUnread), [true, false])
        XCTAssertEqual(listing.unread, 1)
        XCTAssertEqual(listing.total, 2)
        let first = listing.messages[0]
        XCTAssertEqual(first.topic, "lattice.unfreeze")
        XCTAssertEqual(first.inReplyTo, older)
        XCTAssertTrue(first.urgent)
        XCTAssertEqual(first.from, "Board Move")
        let second = listing.messages[1]
        XCTAssertEqual(second.ttlSeconds, 1800)
        // Sent 2026-10-10T08:33:37Z with a 30 minute TTL.
        XCTAssertTrue(second.isExpired(now: MailboxPanelMail.parseTimestamp("2026-10-10T09:04:00Z")!))
        XCTAssertFalse(second.isExpired(now: MailboxPanelMail.parseTimestamp("2026-10-10T09:00:00Z")!))
    }

    func testListingLimitReportsHiddenCount() throws {
        let now = Date()
        for offset in 0..<5 {
            try write([:], id: ulid(now.addingTimeInterval(TimeInterval(-offset * 10))), read: offset % 2 == 0)
        }
        let listing = MailboxPanelMail.listing(inbox: inbox, limit: 3)
        XCTAssertEqual(listing.messages.count, 3)
        XCTAssertEqual(listing.total, 5)
        XCTAssertEqual(listing.hiddenCount, 2)
    }

    func testBodyIsKeptVerbatim() throws {
        let markup = "<script>alert(1)</script> **bold** [link](https://example.com)"
        try write(["body": markup], id: ulid(Date()))
        XCTAssertEqual(MailboxPanelMail.listing(inbox: inbox).messages.first?.body, markup)
    }

    func testUnparseableEnvelopeCarriesAProblem() throws {
        let url = inbox.appendingPathComponent("\(ulid(Date())).msg")
        try Data("not json".utf8).write(to: url)
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertNotNil(message.problem)
    }

    // MARK: - body_ref

    func testBodyRefTextIsRead() throws {
        let file = root.appendingPathComponent("unfreeze.txt")
        try Data("Board writes are open again.".utf8).write(to: file)
        try write(["body_ref": file.path], id: ulid(Date()))
        let reference = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first?.reference)
        XCTAssertEqual(reference.content, .text("Board writes are open again.", truncated: false, byteCount: 28))
    }

    func testBodyRefMissingFile() {
        let reference = MailboxPanelMail.referencedContent(path: root.appendingPathComponent("gone.txt").path)
        XCTAssertEqual(reference.content, .missing)
    }

    func testBodyRefRelativePathIsNotOpened() {
        XCTAssertEqual(MailboxPanelMail.referencedContent(path: "notes.txt").content, .notAbsolute)
    }

    func testBodyRefDirectoryAndFifoAreNotOpened() throws {
        XCTAssertEqual(MailboxPanelMail.referencedContent(path: root.path).content, .notRegularFile)
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        // Opening a FIFO with no writer would block; it must be refused first.
        XCTAssertEqual(MailboxPanelMail.referencedContent(path: fifo.path).content, .notRegularFile)
    }

    func testBodyRefBinaryIsNotText() throws {
        let file = root.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0xFF, 0x10]).write(to: file)
        XCTAssertEqual(MailboxPanelMail.referencedContent(path: file.path).content, .notText(byteCount: 4))
    }

    func testBodyRefLargeFileIsTruncated() throws {
        let file = root.appendingPathComponent("big.txt")
        let size = MailboxPanelMail.maxReferencedBytes + 1000
        try Data(repeating: 0x61, count: size).write(to: file)
        guard case .text(let text, let truncated, let bytes) = MailboxPanelMail.referencedContent(path: file.path).content else {
            return XCTFail("expected text")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(bytes, size)
        XCTAssertEqual(text.utf8.count, MailboxPanelMail.maxReferencedBytes)
    }
}
