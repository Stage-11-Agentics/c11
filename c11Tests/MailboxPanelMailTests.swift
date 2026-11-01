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
        // Delivered the moment it was sent, unless a test says otherwise.
        if let sent = MailboxPanelMail.ulidDate(id) {
            try FileManager.default.setAttributes([.modificationDate: sent], ofItemAtPath: url.path)
        }
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

    func testUnreadThatLandsLateCountsFromWhenItLanded() throws {
        let now = Date()
        let url = try write([:], id: ulid(now.addingTimeInterval(-600)))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        let summary = MailboxPanelMail.summary(inbox: inbox)
        XCTAssertEqual(summary.newestUnreadAt!.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(summary.isFresh(now: now))
    }

    func testMissingInboxIsEmpty() {
        let summary = MailboxPanelMail.summary(inbox: root.appendingPathComponent("nobody"))
        XCTAssertEqual(summary, .empty)
        XCTAssertFalse(summary.hasMail)
    }

    func testEmptyInboxHasNoMailAndReadMailStillCounts() throws {
        // An inbox that exists but never received anything shows no cell.
        XCTAssertFalse(MailboxPanelMail.summary(inbox: inbox).hasMail)
        // Once mail has landed the cell stays, even after all of it is read.
        try write([:], id: ulid(Date()), read: true)
        let summary = MailboxPanelMail.summary(inbox: inbox)
        XCTAssertEqual(summary.unread, 0)
        XCTAssertTrue(summary.hasMail)
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

    func testCountTextIsExactThroughTensOfThousandsAndNeverOutgrowsItsSlot() {
        XCTAssertEqual(MailboxPanelMail.countText(-3), "0")
        XCTAssertEqual(MailboxPanelMail.countText(0), "0")
        XCTAssertEqual(MailboxPanelMail.countText(100), "100")
        XCTAssertEqual(MailboxPanelMail.countText(12_345), "12345")
        XCTAssertEqual(MailboxPanelMail.countText(99_999), "99999")
        XCTAssertEqual(MailboxPanelMail.countText(100_000), "100k")
        XCTAssertEqual(MailboxPanelMail.countText(999_999), "999k")
        XCTAssertEqual(MailboxPanelMail.countText(1_000_000), "1M")
        for count in [0, 9, 99_999, 123_456, 999_999, 12_000_000, Int.max] {
            XCTAssertLessThanOrEqual(MailboxPanelMail.countText(count).count, MailboxPanelMail.countSlotCharacters, "\(count)")
        }
    }

    // MARK: - Insights

    func testInsightsCountsActivityRanksSendersAndTopics() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write(["from": "board", "topic": "lattice.freeze", "urgent": true], id: ulid(now.addingTimeInterval(-30 * 60)))
        try write(["from": "board", "topic": "lattice.freeze"], id: ulid(now.addingTimeInterval(-90 * 60)), read: true)
        try write(["from": "captain", "topic": "merge", "in_reply_to": "01X"], id: ulid(now.addingTimeInterval(-5 * 3600)), read: true)
        try write(["from": "board", "body_ref": "/tmp/x"], id: ulid(now.addingTimeInterval(-3 * 86400)), read: true)
        try write([:], id: ulid(now.addingTimeInterval(-30 * 86400)), read: true)
        try Data("not json".utf8).write(to: inbox.appendingPathComponent("\(ulid(now.addingTimeInterval(-10))).msg"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let insights = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, calendar: calendar)

        XCTAssertEqual(insights.received, 6)
        XCTAssertEqual(insights.unread, 2)
        XCTAssertEqual(insights.lastHour, 2)
        XCTAssertEqual(insights.lastDay, 4)
        XCTAssertEqual(insights.lastWeek, 5)
        XCTAssertEqual(insights.hourly.reduce(0, +), 4)
        XCTAssertEqual(insights.hourly[23], 2, "the past hour is the last bucket")
        XCTAssertEqual(insights.hourly[22], 1)
        XCTAssertEqual(insights.hourly[18], 1)
        XCTAssertEqual(insights.daily.reduce(0, +), 5, "the 30-day-old message is outside 14 days")
        XCTAssertEqual(insights.dayStarts.count, MailboxPanelMail.insightsDays)
        XCTAssertEqual(insights.dayStarts.last, calendar.startOfDay(for: now))

        XCTAssertEqual(insights.scanned, 5)
        XCTAssertEqual(insights.unparsed, 1)
        XCTAssertFalse(insights.scanIsPartial)
        XCTAssertEqual(insights.senders.top.first, MailboxPanelMail.Tally(name: "board", count: 3, unread: 1))
        XCTAssertEqual(insights.senders.distinct, 3)
        XCTAssertEqual(insights.topics.top.map(\.name), ["lattice.freeze", "merge"])
        XCTAssertEqual(insights.untitled, 2)
        XCTAssertEqual(insights.urgent, 1)
        XCTAssertEqual(insights.replies, 1)
        XCTAssertEqual(insights.fileBodies, 1)
        XCTAssertEqual(insights.oldestUnreadAt!.timeIntervalSince1970, now.addingTimeInterval(-30 * 60).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(insights.perDay!, 6.0 / 30, accuracy: 0.001, "measured from the first message to now")
    }

    func testInsightsScanStopsAtTheLimitButCountsEverything() throws {
        let now = Date()
        for minute in 1...8 {
            try write(["from": "a\(minute)"], id: ulid(now.addingTimeInterval(TimeInterval(-60 * minute))), read: true)
        }
        let insights = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, scanLimit: 3)
        XCTAssertEqual(insights.received, 8)
        XCTAssertEqual(insights.lastHour, 8)
        XCTAssertEqual(insights.scanned, 3)
        XCTAssertTrue(insights.scanIsPartial)
        XCTAssertEqual(Set(insights.senders.top.map(\.name)), ["a1", "a2", "a3"], "the newest are scanned")
    }

    func testSampledCountsAreLabeledWhenAFlagLiesOutsideTheSample() throws {
        let now = Date()
        // The only urgent, reply, file-body and no-topic message is the oldest,
        // outside a three-message sample of ordinary messages.
        try write(["urgent": true, "in_reply_to": "01X", "body_ref": "/tmp/x"], id: ulid(now.addingTimeInterval(-600)), read: true)
        for minute in 1...3 {
            try write(["topic": "t"], id: ulid(now.addingTimeInterval(TimeInterval(-60 * minute))), read: true)
        }
        let sampled = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, scanLimit: 3)
        XCTAssertEqual(sampled.received, 4)
        XCTAssertEqual([sampled.urgent, sampled.replies, sampled.fileBodies, sampled.untitled], [0, 0, 0, 0])
        let note = try XCTUnwrap(sampled.sampleScopeNote, "sampled counts must carry their scope")
        XCTAssertTrue(note.contains("urgent"), note)
        XCTAssertTrue(note.contains("3"), note)
        XCTAssertTrue(note.contains("4"), note)

        // With the whole mailbox scanned, the counts are totals and carry no note.
        let full = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now)
        XCTAssertEqual([full.urgent, full.replies, full.fileBodies, full.untitled], [1, 1, 1, 1])
        XCTAssertNil(full.sampleScopeNote)
    }

    func testInsightsSentCountsRecipientsAndWhatTheyTook() throws {
        let now = Date()
        let sender = inbox!
        let takerId = UUID(), waiterId = UUID()
        let taker = MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: takerId)
        let waiter = MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: waiterId)
        try FileManager.default.createDirectory(at: MailboxDrain.readURL(inbox: taker), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: waiter, withIntermediateDirectories: true)
        let first = ulid(now.addingTimeInterval(-120))
        let second = ulid(now.addingTimeInterval(-3 * 86400))
        try Data("{}".utf8).write(to: MailboxDrain.readURL(inbox: taker).appendingPathComponent(MailboxLayout.envelopeFilename(id: first)))
        try Data("{}".utf8).write(to: waiter.appendingPathComponent(MailboxLayout.envelopeFilename(id: first)))
        func recipient(_ id: UUID, _ name: String) -> MailboxSentLedger.Recipient {
            MailboxSentLedger.Recipient(panel: id.uuidString.lowercased(), name: name)
        }
        XCTAssertTrue(MailboxSentLedger.record(
            MailboxSentLedger.Entry(id: first, ts: nil, to: "team", topic: nil, recipients: [recipient(takerId, "Taker Title"), recipient(waiterId, "Waiter Title")]),
            senderInbox: sender
        ))
        XCTAssertTrue(MailboxSentLedger.record(
            MailboxSentLedger.Entry(id: second, ts: nil, to: "taker-address", topic: nil, recipients: [recipient(takerId, "~")]),
            senderInbox: sender
        ))
        let insights = MailboxPanelMail.insights(inbox: sender, mailboxesRoot: root, now: now)
        XCTAssertEqual(insights.sent, 2)
        // One row per recipient panel: the broadcast and the direct send to the
        // taker share a row, named by the direct send's address. The waiter only
        // got the broadcast and keeps its label.
        XCTAssertEqual(insights.recipients.top.map(\.name), ["taker-address", "Waiter Title"])
        XCTAssertEqual(insights.recipients.top.map(\.count), [2, 1])
        XCTAssertEqual(insights.recipients.top.map(\.key), [takerId, waiterId].map { $0.uuidString.lowercased() })
        XCTAssertEqual(insights.recipients.distinct, 2)
        XCTAssertEqual(insights.sentCopies, 2, "the second send's copy is gone")
        XCTAssertEqual(insights.sentTaken, 1)
        XCTAssertFalse(insights.sentIsTrimmed)
    }

    // MARK: - Drill-down

    func testHeaderCacheParsesEachEnvelopeOnceAndSkipsFailures() throws {
        let now = Date()
        let cache = MailboxPanelMail.HeaderCache()
        let url = try write(["from": "board", "topic": "first"], id: ulid(now.addingTimeInterval(-60)))
        try Data("not json".utf8).write(to: inbox.appendingPathComponent("\(ulid(now.addingTimeInterval(-30))).msg"))
        let first = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: cache)
        XCTAssertEqual(first.records.map(\.header.from), ["board"])
        XCTAssertEqual(cache.count, 1, "a failed parse is not cached")

        // Envelopes never change; a rewrite proves the second scan read the cache.
        try JSONSerialization.data(withJSONObject: ["version": 1, "from": "changed", "body": ""]).write(to: url)
        let second = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: cache)
        XCTAssertEqual(second.records.map(\.header.from), ["board"])

        // A claim moves the file into _read/ under the same name: still cached.
        try FileManager.default.moveItem(at: url, to: MailboxDrain.readURL(inbox: inbox).appendingPathComponent(url.lastPathComponent))
        let claimed = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: cache)
        XCTAssertEqual(claimed.records.map(\.header.from), ["board"])
        XCTAssertEqual(claimed.records.map(\.unread), [false])
        XCTAssertEqual(cache.count, 1)
    }

    func testHeaderKeepsTheFirstBodyLineAsPreview() {
        let header = MailboxPanelMail.Header(raw: ["from": "a", "body": "line one\nline two", "in_reply_to": "01X", "urgent": true])
        XCTAssertEqual(header.preview, "line one")
        XCTAssertTrue(header.reply)
        XCTAssertTrue(header.urgent)
        XCTAssertFalse(header.fileBody)
        XCTAssertNil(header.topic)
        let long = MailboxPanelMail.Header(raw: ["body": String(repeating: "x", count: 500)])
        XCTAssertEqual(long.preview.count, MailboxPanelMail.Header.previewLimit)
        XCTAssertEqual(long.from, "?")
    }

    func testSliceNarrowsFiguresAndKeepsEachRankingSwitchable() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write(["from": "board", "topic": "freeze", "urgent": true], id: ulid(now.addingTimeInterval(-30 * 60)))
        try write(["from": "board", "topic": "merge"], id: ulid(now.addingTimeInterval(-2 * 3600)), read: true)
        try write(["from": "captain", "topic": "freeze"], id: ulid(now.addingTimeInterval(-3 * 3600)), read: true)
        try write(["from": "board", "topic": "freeze"], id: ulid(now.addingTimeInterval(-3 * 86400)), read: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let insights = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, calendar: calendar, cache: nil)

        var filter = MailboxPanelMail.InsightsFilter()
        filter.toggleFrom("board")
        let board = MailboxPanelMail.slice(insights, filter: filter, calendar: calendar)
        XCTAssertEqual(board.count, 3)
        XCTAssertEqual(board.unread, 1)
        XCTAssertEqual(board.urgent, 1)
        XCTAssertEqual(board.lastDay, 2)
        XCTAssertEqual(board.messages.count, 3)
        XCTAssertEqual(board.messages.first?.header.topic, "freeze", "newest first")
        XCTAssertEqual(board.senders.top.map(\.name), ["board", "captain"], "the sender ranking ignores the sender filter")
        XCTAssertEqual(board.topics.top.map(\.name), ["freeze", "merge"])
        XCTAssertEqual(board.hourly.reduce(0, +), 2)

        // Stack a topic, then a time bucket.
        filter.toggleTopic("freeze")
        XCTAssertEqual(MailboxPanelMail.slice(insights, filter: filter, calendar: calendar).count, 2)
        filter.pickHour(23, in: insights)
        XCTAssertEqual(filter.selectedHour(in: insights), 23)
        let pastHour = MailboxPanelMail.slice(insights, filter: filter, calendar: calendar)
        XCTAssertEqual(pastHour.count, 1)
        XCTAssertEqual(pastHour.daily.reduce(0, +), 2, "the charts ignore the time filter")
        XCTAssertEqual(pastHour.topics.top.map(\.name), ["freeze"], "topics ignore only the topic filter")

        // The hour is an absolute range: a rescan 30 s later keeps the same
        // messages. Its bars have rolled, so none matches the range exactly
        // and none is highlighted; the chip names the range instead.
        let later = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now.addingTimeInterval(30), calendar: calendar, cache: nil)
        XCTAssertEqual(MailboxPanelMail.slice(later, filter: filter, calendar: calendar).count, 1)
        XCTAssertNil(filter.selectedHour(in: later))
        var cleared = filter
        cleared.pickHour(23, in: insights)
        XCTAssertNil(cleared.window, "picking the highlighted bar again clears it")

        // A day replaces the hour; the same day again clears it.
        let today = MailboxPanelMail.insightsDays - 1
        filter.pickDay(today, in: insights, calendar: calendar)
        XCTAssertEqual(filter.window?.isDay, true)
        XCTAssertEqual(filter.selectedDay(in: insights), today)
        XCTAssertNil(filter.selectedHour(in: insights))
        filter.pickDay(today, in: insights, calendar: calendar)
        XCTAssertNil(filter.window)

        // A recipient filter replaces every received filter, and vice versa;
        // it keeps the label its row showed.
        filter.toggleRecipient("abc", name: "reviewer")
        XCTAssertEqual(filter, MailboxPanelMail.InsightsFilter(recipient: "abc", recipientName: "reviewer"))
        filter.toggleFrom("board")
        XCTAssertNil(filter.recipient)
        filter.toggleFrom("board")
        XCTAssertTrue(filter.isEmpty)
    }

    func testSelectedNamePastTheTopStaysPinned() {
        let tallies = (1...8).map { MailboxPanelMail.Tally(name: "s\($0)", count: 10 - $0) }
        let pinned = MailboxPanelMail.ranking(tallies, top: 3, pinned: "s7")
        XCTAssertEqual(pinned.top.map(\.name), ["s1", "s2", "s7"])
        XCTAssertEqual(pinned.others, tallies.filter { !["s1", "s2", "s7"].contains($0.name) }.reduce(0) { $0 + $1.count })
        let absent = MailboxPanelMail.ranking(tallies, top: 3, pinned: "nobody")
        XCTAssertEqual(absent.top.last, MailboxPanelMail.Tally(name: "nobody", count: 0))
    }

    func testOthersCountsARecipientThatSharesAShownLabel() {
        // Two panels share the label "~"; only one makes the top.
        let ranking = MailboxPanelMail.ranking([
            .init(name: "~", count: 9, key: "a"), .init(name: "~", count: 2, key: "b"), .init(name: "z", count: 5, key: "c"),
        ], top: 2)
        XCTAssertEqual(ranking.top.map(\.id), ["a", "c"])
        XCTAssertEqual(ranking.others, 2)
    }

    func testHeaderCapsUntrustedFields() {
        let header = MailboxPanelMail.Header(raw: ["from": String(repeating: "f", count: 60_000), "topic": String(repeating: "t", count: 60_000)])
        XCTAssertEqual(header.from.count, MailboxPanelMail.Header.fieldLimit)
        XCTAssertEqual(header.topic?.count, MailboxPanelMail.Header.fieldLimit)
    }

    func testSliceListsAtMostFiftyMessages() throws {
        let now = Date()
        for minute in 1...60 {
            try write(["from": "a"], id: ulid(now.addingTimeInterval(TimeInterval(-60 * minute))), read: true)
        }
        let insights = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: nil)
        var filter = MailboxPanelMail.InsightsFilter()
        filter.toggleFrom("a")
        let slice = MailboxPanelMail.slice(insights, filter: filter)
        XCTAssertEqual(slice.count, 60)
        XCTAssertEqual(slice.messages.count, MailboxPanelMail.sliceMessageLimit)
    }

    func testSentSliceCountsOneRecipientsCopies() throws {
        let now = Date()
        let takerId = UUID(), waiterId = UUID()
        let taker = MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: takerId)
        let waiter = MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: waiterId)
        try FileManager.default.createDirectory(at: MailboxDrain.readURL(inbox: taker), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: waiter, withIntermediateDirectories: true)
        let first = ulid(now.addingTimeInterval(-120)), second = ulid(now.addingTimeInterval(-60))
        try Data("{}".utf8).write(to: MailboxDrain.readURL(inbox: taker).appendingPathComponent(MailboxLayout.envelopeFilename(id: first)))
        try Data("{}".utf8).write(to: waiter.appendingPathComponent(MailboxLayout.envelopeFilename(id: first)))
        func recipient(_ id: UUID, _ name: String) -> MailboxSentLedger.Recipient {
            MailboxSentLedger.Recipient(panel: id.uuidString.lowercased(), name: name)
        }
        MailboxSentLedger.record(
            MailboxSentLedger.Entry(id: first, ts: nil, to: "team", topic: "review", recipients: [recipient(takerId, "taker"), recipient(waiterId, "waiter")]),
            senderInbox: inbox
        )
        MailboxSentLedger.record(
            MailboxSentLedger.Entry(id: second, ts: nil, to: "taker", topic: nil, recipients: [recipient(takerId, "taker")]),
            senderInbox: inbox
        )
        let insights = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: nil)
        let takerKey = takerId.uuidString.lowercased()
        XCTAssertEqual(insights.recipients.top.first(where: { $0.key == takerKey })?.count, 2)

        let slice = MailboxPanelMail.sentSlice(insights, recipient: takerKey)
        XCTAssertEqual([slice.sent, slice.taken, slice.waiting, slice.gone], [2, 1, 0, 1])
        XCTAssertEqual(slice.messages.map(\.record.entryId), [second, first], "newest first")
        XCTAssertEqual(slice.messages.map(\.state), [.gone, .read])
        let waiterSlice = MailboxPanelMail.sentSlice(insights, recipient: waiterId.uuidString.lowercased())
        XCTAssertEqual([waiterSlice.sent, waiterSlice.waiting], [1, 1])
    }

    func testWarmScanOfFiveThousandEnvelopesParsesNothingAgain() throws {
        let now = Date()
        let cache = MailboxPanelMail.HeaderCache()
        let read = MailboxDrain.readURL(inbox: inbox)
        for index in 0..<MailboxPanelMail.insightsScanLimit {
            let id = ulid(now.addingTimeInterval(TimeInterval(-index)))
            let object: [String: Any] = ["version": 1, "id": id, "from": "s\(index % 9)", "topic": "t\(index % 5)", "body": "status \(index)"]
            try JSONSerialization.data(withJSONObject: object).write(to: read.appendingPathComponent("\(id).msg"))
        }
        let coldStart = Date()
        let cold = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: cache)
        let coldSeconds = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let warm = MailboxPanelMail.insights(inbox: inbox, mailboxesRoot: root, now: now, cache: cache)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        var filter = MailboxPanelMail.InsightsFilter()
        filter.toggleFrom("s3")
        let sliceStart = Date()
        let slice = MailboxPanelMail.slice(warm, filter: filter)
        let sliceSeconds = Date().timeIntervalSince(sliceStart)
        print("insights-timing cold=\(Int(coldSeconds * 1000))ms warm=\(Int(warmSeconds * 1000))ms slice=\(Int(sliceSeconds * 1000))ms n=\(cold.scanned)")
        XCTAssertEqual(cold.scanned, MailboxPanelMail.insightsScanLimit)
        XCTAssertEqual(warm, cold)
        XCTAssertEqual(cache.count, MailboxPanelMail.insightsScanLimit)
        XCTAssertEqual(slice.count, (0..<MailboxPanelMail.insightsScanLimit).filter { $0 % 9 == 3 }.count)
    }

    func testRankingFoldsTheRestIntoOthersInAStableOrder() {
        let ranking = MailboxPanelMail.ranking([
            .init(name: "b", count: 2), .init(name: "a", count: 2), .init(name: "c", count: 5), .init(name: "d", count: 1),
        ], top: 2)
        XCTAssertEqual(ranking.top.map(\.name), ["c", "a"])
        XCTAssertEqual(ranking.distinct, 4)
        XCTAssertEqual(ranking.others, 3)
    }

    // MARK: - Listing

    func testListingIsNewestFirstWithUnreadState() throws {
        let now = Date()
        let older = ulid(now.addingTimeInterval(-600))
        let newer = ulid(now.addingTimeInterval(-60))
        try write(["topic": "lattice.freeze", "body": "freeze", "ttl_seconds": 1800], id: older, read: true)
        try write(["topic": "lattice.unfreeze", "body": "thaw", "in_reply_to": older, "urgent": true], id: newer)
        let listing = MailboxPanelMail.listing(inbox: inbox)
        XCTAssertEqual(listing.messages.map(\.fileId), [newer, older])
        XCTAssertEqual(Set(listing.messages.map(\.id)).count, 2)
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

    func testSameFileInRootAndReadHasDistinctIds() throws {
        let id = ulid(Date())
        try write([:], id: id)
        try write([:], id: id, read: true)
        let listing = MailboxPanelMail.listing(inbox: inbox)
        XCTAssertEqual(listing.messages.count, 2)
        XCTAssertEqual(Set(listing.messages.map(\.id)).count, 2)
    }

    func testLongBodyIsMarkedForFolding() throws {
        try write(["body": (1...20).map { "line \($0)" }.joined(separator: "\n")], id: ulid(Date()))
        XCTAssertEqual(MailboxPanelMail.listing(inbox: inbox).messages.first?.isLong, true)
        XCTAssertFalse(MailboxPanelMail.isLong("short"))
    }

    func testFifoEnvelopeIsNotOpened() throws {
        let fifo = inbox.appendingPathComponent("\(ulid(Date())).msg")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        // Opening a FIFO with no writer would block the drawer's loader forever.
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertNotNil(message.problem)
    }

    func testSymlinkedEnvelopeIsNotFollowed() throws {
        let target = root.appendingPathComponent("elsewhere.msg")
        try JSONSerialization.data(withJSONObject: ["version": 1, "id": "x", "from": "a", "ts": "t", "body": "secret"]).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: inbox.appendingPathComponent("\(ulid(Date())).msg"),
            withDestinationURL: target
        )
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertNotNil(message.problem)
        XCTAssertEqual(message.body, "")
    }

    func testUnparseableEnvelopeCarriesAProblem() throws {
        let url = inbox.appendingPathComponent("\(ulid(Date())).msg")
        try Data("not json".utf8).write(to: url)
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertNotNil(message.problem)
    }

    // MARK: - Read-only

    /// Every file in the inbox root and `_read/`, by name, with its bytes.
    private func inboxFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (prefix, dir) in [("", inbox!), ("_read/", MailboxDrain.readURL(inbox: inbox))] {
            for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                files[prefix + url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return files
    }

    /// The drawer only looks: the doorbell (C11-394) and every drain rely on
    /// unread mail staying in the inbox root until an agent claims it.
    func testListingAndBodyRefReadNeverChangeReadState() throws {
        let now = Date()
        let file = root.appendingPathComponent("unfreeze.txt")
        try Data("Board writes are open again.".utf8).write(to: file)
        try write(["body": "Freeze the board."], id: ulid(now.addingTimeInterval(-7200)), read: true)
        try write(["body": "Still frozen."], id: ulid(now.addingTimeInterval(-600)))
        try write(["body_ref": file.path], id: ulid(now.addingTimeInterval(-60)))
        let before = try inboxFiles()
        XCTAssertEqual(before.count, 3)

        let listing = MailboxPanelMail.listing(inbox: inbox)
        let reference = MailboxPanelMail.referencedContent(path: file.path)
        _ = MailboxPanelMail.summary(inbox: inbox)

        XCTAssertEqual(listing.unread, 2)
        XCTAssertEqual(listing.messages.first?.reference?.content, .text("Board writes are open again.", truncated: false, byteCount: 28))
        XCTAssertEqual(reference.content, .text("Board writes are open again.", truncated: false, byteCount: 28))
        XCTAssertEqual(try inboxFiles(), before)
        XCTAssertEqual(try Data(contentsOf: file), Data("Board writes are open again.".utf8))
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
        let link = root.appendingPathComponent("pipe-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        XCTAssertEqual(MailboxPanelMail.referencedContent(path: link.path).content, .notRegularFile)
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

    func testRegularFilePrefixBoundsReadsFromSparseFile() throws {
        let file = root.appendingPathComponent("large-sparse.msg")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try handle.close()

        guard case .success(let read) = MailboxPanelMail.readRegularFilePrefix(
            path: file.path,
            limit: 64 * 1024,
            followSymlinks: false
        ) else {
            return XCTFail("expected a bounded prefix read")
        }
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.data.count, 64 * 1024)
        XCTAssertEqual(read.size, 4 * 1024 * 1024 * 1024)
    }

    func testRegularFileTailKeepsACompleteLineAtTheWindowBoundary() throws {
        let file = root.appendingPathComponent("dispatch.log")
        try Data("x\nAAAAAAA\nBBBBBBB\n".utf8).write(to: file)

        guard case .success(let data) = MailboxPanelMail.readRegularFileTail(
            path: file.path,
            limit: 16,
            followSymlinks: false
        ) else {
            return XCTFail("expected a bounded tail read")
        }

        XCTAssertEqual(String(data: data, encoding: .utf8), "AAAAAAA\nBBBBBBB\n")
    }

    func testRegularFileTailReturnsEmptyWhenTheWindowHasNoNewline() throws {
        let file = root.appendingPathComponent("long-line.log")
        try Data("prefix-AAAAAAA-BBBBBBBB".utf8).write(to: file)

        guard case .success(let data) = MailboxPanelMail.readRegularFileTail(
            path: file.path,
            limit: 8,
            followSymlinks: false
        ) else {
            return XCTFail("expected a bounded tail read")
        }

        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - Copy text (C11-400)

    func testCopyTextDropsTrailingNewlineAndKeepsInnerOnes() throws {
        try write(["body": "echo one\necho two\n"], id: ulid(Date()))
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertEqual(message.fullText, "echo one\necho two")
    }

    func testCopyTextOfBodyRefDropsTheFilesFinalNewline() throws {
        let file = root.appendingPathComponent("review.txt")
        try Data("first line\n\nsecond line\n".utf8).write(to: file)
        try write(["body": "See the file.", "body_ref": file.path], id: ulid(Date()))
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertEqual(message.fullText, "See the file.\n\nfirst line\n\nsecond line")
    }

    // MARK: - Conversations

    /// This test's panel: `inbox` is named by its id.
    private var thisPanel: UUID { UUID(uuidString: inbox.lastPathComponent)! }

    private func peerInbox(_ panel: UUID) -> URL { MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: panel) }

    /// Mail this panel received, stamped with the sending panel when `stamp` is given.
    @discardableResult
    private func receive(
        _ id: String,
        from name: String,
        stamp: UUID?,
        read: Bool = false,
        body: String = "hi",
        fields: [String: Any] = [:]
    ) throws -> URL {
        var object = fields
        object["from"] = name
        object["body"] = body
        if let stamp { object["ext"] = [MailboxEnvelope.senderPanelKey: stamp.uuidString.lowercased()] }
        return try write(object, id: id, read: read)
    }

    /// Where a recipient's copy of a send is: in its inbox root, in its
    /// `_read/`, nowhere, or in its inbox root under another sender's stamp.
    private enum Copy { case waiting, taken, gone, foreign }

    /// A send from this panel as the dispatcher records it: a `_sent/` entry
    /// and a stamped copy in each recipient's inbox.
    private func send(
        _ id: String,
        to recipients: [(UUID, Copy)],
        address: String? = nil,
        topic: String? = "t",
        body: String = "sent",
        fields: [String: Any] = [:]
    ) throws {
        for (panel, copy) in recipients where copy != .gone {
            var object: [String: Any] = ["version": 1, "id": id, "from": "board-move", "ts": "2026-10-10T08:33:37Z", "body": body, "to": address ?? "x"]
            object.merge(fields) { _, new in new }
            let stamp = copy == .foreign ? UUID() : thisPanel
            object["ext"] = [MailboxEnvelope.senderPanelKey: stamp.uuidString.lowercased()]
            let dir = copy == .taken ? MailboxDrain.readURL(inbox: peerInbox(panel)) : peerInbox(panel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent("\(id).msg"))
        }
        XCTAssertTrue(MailboxSentLedger.record(
            MailboxSentLedger.Entry(
                id: id, ts: nil, to: address, topic: topic,
                recipients: recipients.map {
                    MailboxSentLedger.Recipient(panel: $0.0.uuidString.lowercased(), name: "label-" + String($0.0.uuidString.prefix(4)))
                }
            ),
            senderInbox: inbox
        ))
    }

    private func conversationIndex(scanLimit: Int = MailboxPanelMail.insightsScanLimit) -> MailboxPanelMail.ConversationIndex {
        MailboxPanelMail.conversationIndex(inbox: inbox, mailboxesRoot: root, scanLimit: scanLimit, cache: MailboxPanelMail.HeaderCache())
    }

    private func openThread(
        _ key: MailboxPanelMail.PeerKey,
        in index: MailboxPanelMail.ConversationIndex,
        limit: Int = MailboxPanelMail.threadLimit,
        cache: MailboxPanelMail.HeaderCache = MailboxPanelMail.HeaderCache()
    ) throws -> MailboxPanelMail.ConversationThread {
        let conversation = try XCTUnwrap(index.conversation(key))
        return MailboxPanelMail.thread(
            conversation, inbox: inbox, mailboxesRoot: root, ledgerFloor: index.ledgerFloor,
            limit: limit, cache: cache
        )
    }

    func testHeaderCarriesTheSenderStampAndTheFileName() {
        let panel = UUID()
        let header = MailboxPanelMail.Header(raw: [
            "from": "x", "body_ref": "/tmp/review/findings.md",
            "ext": [MailboxEnvelope.senderPanelKey: panel.uuidString.lowercased()],
        ])
        XCTAssertEqual(header.senderPanel, panel)
        XCTAssertEqual(header.fileName, "findings.md")
        XCTAssertNil(MailboxPanelMail.Header(raw: ["from": "x", "ext": ["other": "y"]]).senderPanel)
    }

    func testConversationsGroupReceivedMailByTheSenderStamp() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captain = UUID(), reviewer = UUID()
        try receive(ulid(now - 300), from: "merge-captain", stamp: captain, read: true, body: "queued")
        try receive(ulid(now - 200), from: "merge-captain", stamp: captain, body: "landed\nand more")
        try receive(ulid(now - 100), from: "c11-reviewer", stamp: reviewer, read: true, body: "clean")

        let index = conversationIndex()
        // Newest activity first.
        XCTAssertEqual(index.conversations.map(\.key), [.panel(reviewer), .panel(captain)])
        let row = try XCTUnwrap(index.conversation(.panel(captain)))
        XCTAssertEqual(row.received, 2)
        XCTAssertEqual(row.sent, 0)
        XCTAssertEqual(row.unread, 1)
        XCTAssertEqual(row.label, "merge-captain")
        XCTAssertEqual(row.lastDirection, .received)
        XCTAssertEqual(row.lastPreview, .text("landed"))
        XCTAssertNil(row.lastSendState, "nothing sent")
        XCTAssertEqual(index.unread, 1)
        XCTAssertEqual(index.scanned, 3)
        XCTAssertFalse(index.scanIsPartial)
    }

    func testThreadBodiesCarryTheirLinksBothWays() throws {
        // C11-524: links in a Conversations bubble open like links in Received,
        // so the thread's messages carry the same found links, in and out.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captain = UUID()
        try receive(ulid(now - 200), from: "merge-captain", stamp: captain, body: "Landed: https://github.com/Stage-11-Agentics/c11/pull/861 ok")
        try send(ulid(now - 100), to: [(captain, .waiting)], body: "Review https://example.com/r/2 please")
        let thread = try openThread(.panel(captain), in: conversationIndex())
        XCTAssertEqual(thread.items.map(\.direction), [.received, .sent])
        let links = thread.items.map { item in
            (item.message?.bodyRich.runs.compactMap(\.link).map(\.absoluteString)) ?? []
        }
        XCTAssertEqual(links, [["https://github.com/Stage-11-Agentics/c11/pull/861"], ["https://example.com/r/2"]])
    }

    func testUnstampedMailStaysInItsOwnNameOnlyRow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captain = UUID()
        try receive(ulid(now - 300), from: "merge-captain", stamp: captain, read: true)
        // The same name with no stamp (a raw writer, a --from override, another
        // workspace) is not proof of the sender, so it is not merged.
        try receive(ulid(now - 200), from: "merge-captain", stamp: nil)
        try receive(ulid(now - 100), from: "lattice-poller", stamp: nil, read: true, body: "", fields: ["body_ref": "/tmp/nightly-report.txt"])

        let index = conversationIndex()
        XCTAssertEqual(Set(index.conversations.map(\.key)), [.panel(captain), .name("merge-captain"), .name("lattice-poller")])
        XCTAssertEqual(index.conversation(.panel(captain))?.received, 1)
        XCTAssertEqual(index.conversation(.panel(captain))?.unread, 0)
        XCTAssertEqual(index.conversation(.name("merge-captain"))?.received, 1)
        XCTAssertEqual(index.conversation(.name("merge-captain"))?.unread, 1)
        XCTAssertEqual(index.conversation(.name("lattice-poller"))?.lastPreview, .file("nightly-report.txt"))
        let nameOnly = try openThread(.name("merge-captain"), in: index)
        XCTAssertEqual(nameOnly.items.map(\.direction), [.received])
        XCTAssertEqual(nameOnly.items.first?.state, .unread)
        XCTAssertFalse(nameOnly.showsLedgerFloor)
    }

    func testABroadcastAppearsInEachRecipientsThreadWithEveryState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = UUID(), claude = UUID(), grok = UUID()
        let id = ulid(now - 600)
        try send(id, to: [(codex, .taken), (claude, .taken), (grok, .waiting)], address: "role:reviewer", topic: "review.request", body: "Review PR #866.")

        let index = conversationIndex()
        XCTAssertEqual(Set(index.conversations.map(\.key)), [.panel(codex), .panel(claude), .panel(grok)])
        for panel in [codex, claude, grok] {
            let conversation = try XCTUnwrap(index.conversation(.panel(panel)))
            XCTAssertEqual(conversation.sent, 1)
            XCTAssertEqual(conversation.lastDirection, .sent)
            XCTAssertEqual(conversation.lastPreview, .text("Review PR #866."))
            // A broadcast has no direct address, so its peers keep their labels.
            XCTAssertEqual(conversation.label, "label-" + String(panel.uuidString.prefix(4)))
        }
        XCTAssertEqual(index.conversation(.panel(grok))?.lastSendState, .unread)
        XCTAssertEqual(index.conversation(.panel(codex))?.lastSendState, .read)

        let item = try XCTUnwrap(openThread(.panel(grok), in: index).items.first)
        XCTAssertEqual(item.direction, .sent)
        XCTAssertEqual(item.state, .unread)
        XCTAssertEqual(item.to, "role:reviewer")
        XCTAssertEqual(item.topic, "review.request")
        XCTAssertEqual(item.recipients.map(\.panelId), [codex, claude, grok])
        XCTAssertEqual(item.recipients.map(\.state), [.read, .read, .unread])
        XCTAssertEqual(item.message?.body, "Review PR #866.")
        XCTAssertEqual(try openThread(.panel(codex), in: index).items.map(\.state), [.read])
        XCTAssertEqual(try openThread(.panel(codex), in: index).items.first?.id, item.id)
    }

    func testSentCopiesAreTakenWaitingOrGone() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID(), other = UUID()
        let taken = ulid(now - 400), waiting = ulid(now - 300), gone = ulid(now - 200), foreign = ulid(now - 100)
        try send(taken, to: [(peer, .taken)], address: "peer-address", body: "taken body")
        try send(waiting, to: [(peer, .waiting)], body: "waiting body")
        try send(gone, to: [(peer, .gone)], body: "gone body")
        try send(foreign, to: [(peer, .foreign)], body: "SECRET-FROM-SOMEONE-ELSE")

        let index = conversationIndex()
        let conversation = try XCTUnwrap(index.conversation(.panel(peer)))
        XCTAssertEqual(conversation.sent, 4)
        XCTAssertEqual(conversation.label, "peer-address", "a sent-only peer is named by the address of a direct send")
        // A copy without this panel's stamp is not this panel's mail.
        XCTAssertEqual(conversation.lastSendState, .gone)
        XCTAssertEqual(conversation.lastPreview, .copyGone)

        let items = try openThread(.panel(peer), in: index).items
        XCTAssertEqual(items.map(\.envelopeId), [taken, waiting, gone, foreign])
        XCTAssertEqual(items.map(\.state), [.read, .unread, .gone, .gone])
        XCTAssertEqual(items.map { $0.message?.body }, ["taken body", "waiting body", nil, nil])
        // The ledger keeps the topic when the text is gone.
        XCTAssertEqual(items.map(\.topic), ["t", "t", "t", "t"])

        // A broadcast's text survives while any recipient's copy remains.
        let shared = ulid(now - 50)
        try send(shared, to: [(peer, .gone), (other, .taken)], body: "still on disk")
        let later = conversationIndex()
        XCTAssertEqual(later.conversation(.panel(peer))?.lastPreview, .text("still on disk"))
        let last = try XCTUnwrap(openThread(.panel(peer), in: later).items.last)
        XCTAssertEqual(last.envelopeId, shared)
        XCTAssertEqual(last.state, .gone)
        XCTAssertEqual(last.message?.body, "still on disk")
        XCTAssertEqual(last.recipients.map(\.state), [.gone, .read])
    }

    func testThreadIsInTimeOrderAndLinksRepliesBothWays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captain = UUID()
        let ask = ulid(now - 500), answer = ulid(now - 400), followUp = ulid(now - 300), stray = ulid(now - 200)
        try send(ask, to: [(captain, .taken)], address: "merge-captain", topic: "merge.ready", body: "ready")
        try receive(answer, from: "merge-captain", stamp: captain, read: true, body: "queued", fields: ["in_reply_to": ask, "topic": "merge.ready"])
        try send(followUp, to: [(captain, .waiting)], topic: "build.status", body: "thanks", fields: ["in_reply_to": answer])
        try receive(stray, from: "merge-captain", stamp: captain, body: "elsewhere", fields: ["in_reply_to": "01JBXNOTINTHISTHREAD"])

        let index = conversationIndex()
        let opened = try openThread(.panel(captain), in: index)
        XCTAssertEqual(opened.items.map(\.envelopeId), [ask, answer, followUp, stray])
        XCTAssertEqual(opened.items.map(\.direction), [.sent, .received, .sent, .received])
        XCTAssertNil(opened.items[0].parent)
        // A received reply links to the send it answers, and the reverse.
        XCTAssertEqual(opened.items[1].parent?.id, opened.items[0].id)
        XCTAssertEqual(opened.items[1].parent?.topic, "merge.ready")
        XCTAssertEqual(opened.items[1].parent?.date, MailboxPanelMail.ulidDate(ask))
        XCTAssertEqual(opened.items[2].parent?.id, opened.items[1].id)
        // A parent outside the thread is named, not linked.
        XCTAssertNil(opened.items[3].parent)
        XCTAssertEqual(opened.items[3].message?.inReplyTo, "01JBXNOTINTHISTHREAD")
        XCTAssertEqual(opened.total, 4)
        XCTAssertEqual(opened.received, 2)
        XCTAssertEqual(opened.sent, 2)
    }

    func testUnreadCountsFollowTheAgentAndOpeningTakesNothing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID()
        try receive(ulid(now - 400), from: "p", stamp: peer, read: true)
        try receive(ulid(now - 300), from: "p", stamp: peer)
        try send(ulid(now - 200), to: [(peer, .waiting)])
        try receive(ulid(now - 100), from: "p", stamp: peer)
        let before = try inboxFiles()

        let index = conversationIndex()
        XCTAssertEqual(index.conversation(.panel(peer))?.unread, 2)
        XCTAssertEqual(index.unread, 2)
        let opened = try openThread(.panel(peer), in: index)
        XCTAssertEqual(opened.unread, 2)
        XCTAssertEqual(opened.items.map(\.state), [.read, .unread, .unread, .unread])
        XCTAssertEqual(opened.firstUnreadId, opened.items[1].id)
        XCTAssertEqual(try inboxFiles(), before, "reading a conversation claims nothing")

        // The agent takes one after the index was read: the thread finds it in _read/.
        let claimed = opened.items[1].envelopeId
        try FileManager.default.moveItem(
            at: inbox.appendingPathComponent("\(claimed).msg"),
            to: MailboxDrain.readURL(inbox: inbox).appendingPathComponent("\(claimed).msg")
        )
        let after = try openThread(.panel(peer), in: index)
        XCTAssertEqual(after.items[1].state, .read)
        XCTAssertNil(after.items[1].message?.problem)
        XCTAssertEqual(after.items[1].id, opened.items[1].id, "taking a message keeps its place in the thread")
        XCTAssertEqual(after.unread, 1)
        XCTAssertEqual(after.firstUnreadId, after.items[3].id)
        XCTAssertEqual(conversationIndex().conversation(.panel(peer))?.unread, 1)
    }

    func testThreadReadsOnlyItsNewestMessagesAndCountsTheRest() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID()
        var ids: [String] = []
        for step in 0..<5 {
            let id = ulid(now - TimeInterval(500 - step * 10))
            ids.append(id)
            // The oldest is still unread.
            try receive(id, from: "p", stamp: peer, read: step != 0)
        }
        let index = conversationIndex()
        let opened = try openThread(.panel(peer), in: index, limit: 3)
        XCTAssertEqual(opened.items.map(\.envelopeId), Array(ids.suffix(3)))
        XCTAssertEqual(opened.total, 5)
        XCTAssertEqual(opened.hiddenCount, 2)
        XCTAssertEqual(opened.unread, 1, "an unread message past the cap still counts")
        XCTAssertNil(opened.firstUnreadId)

        // The list reads at most the scan limit of headers, and says so.
        let partial = conversationIndex(scanLimit: 2)
        XCTAssertTrue(partial.scanIsPartial)
        XCTAssertEqual(partial.received, 5)
        XCTAssertEqual(partial.conversation(.panel(peer))?.received, 2)
    }

    func testLedgerFloorMarksWhereThisPanelsSentRecordStarts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID(), fresh = UUID()
        try receive(ulid(now - 900), from: "p", stamp: peer, read: true)
        let firstSend = ulid(now - 500)
        try send(firstSend, to: [(peer, .taken)])
        try receive(ulid(now - 100), from: "p", stamp: peer, read: true)
        try send(ulid(now - 50), to: [(fresh, .taken)])

        let index = conversationIndex()
        XCTAssertEqual(index.ledgerFloor, MailboxPanelMail.ulidDate(firstSend))
        let opened = try openThread(.panel(peer), in: index)
        XCTAssertTrue(opened.showsLedgerFloor, "the peer's side reaches back past the sent record")
        XCTAssertEqual(opened.ledgerFloorItemId, opened.items[1].id)
        XCTAssertFalse(try openThread(.panel(fresh), in: index).showsLedgerFloor)
    }

    func testAThreadShowsOnlyMessagesWhoseFileStillCarriesThePeersStamp() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID(), impostor = UUID()
        let kept = ulid(now - 300), rewritten = ulid(now - 200), moved = ulid(now - 100), named = ulid(now - 50)
        try receive(kept, from: "p", stamp: peer, read: true, body: "kept")
        try receive(rewritten, from: "p", stamp: peer, read: true, body: "original")
        try receive(moved, from: "p", stamp: peer, body: "original")
        try receive(named, from: "lattice-poller", stamp: nil, read: true, body: "nightly")
        // One cache for the index and the thread, as in the app, where a file
        // in the inbox root and one in `_read/` share an entry by name.
        let cache = MailboxPanelMail.HeaderCache()
        let index = MailboxPanelMail.conversationIndex(inbox: inbox, mailboxesRoot: root, cache: cache)
        XCTAssertEqual(index.conversation(.panel(peer))?.received, 3)

        // Other writers' envelopes under the same names: one rewritten in place,
        // one gone from the root with an unstamped file of its name in `_read/`,
        // and the name-only one rewritten under another name.
        try receive(rewritten, from: "p", stamp: impostor, read: true, body: "IMPOSTOR")
        try FileManager.default.removeItem(at: inbox.appendingPathComponent("\(moved).msg"))
        try receive(moved, from: "p", stamp: nil, read: true, body: "UNSTAMPED")
        try receive(named, from: "someone-else", stamp: nil, read: true, body: "LOOKALIKE")

        let opened = try openThread(.panel(peer), in: index, cache: cache)
        XCTAssertEqual(opened.items.map(\.envelopeId), [kept])
        XCTAssertEqual(opened.items.map { $0.message?.body }, ["kept"])
        XCTAssertEqual(opened.total, 1)
        XCTAssertEqual(opened.received, 1)
        XCTAssertEqual(opened.unread, 0)
        XCTAssertEqual(opened.hiddenCount, 0)
        XCTAssertTrue(try openThread(.name("lattice-poller"), in: index, cache: cache).items.isEmpty)
    }

    func testAPartialScanLeavesOutSendsOlderThanItReaches() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID()
        try receive(ulid(now - 900), from: "p", stamp: peer, read: true)
        let oldestScanned = ulid(now - 200), newest = ulid(now - 100)
        try receive(oldestScanned, from: "p", stamp: peer, read: true)
        try receive(newest, from: "p", stamp: peer, read: true)
        let oldSend = ulid(now - 500), newSend = ulid(now - 150)
        try send(oldSend, to: [(peer, .taken)])
        try send(newSend, to: [(peer, .taken)])

        let index = conversationIndex(scanLimit: 2)
        XCTAssertTrue(index.scanIsPartial)
        XCTAssertEqual(index.scanFloor, MailboxPanelMail.ulidDate(oldestScanned))
        // The ledger reaches back further, but this side is cut where the other is.
        XCTAssertEqual(index.ledgerFloor, MailboxPanelMail.ulidDate(oldSend))
        let conversation = try XCTUnwrap(index.conversation(.panel(peer)))
        XCTAssertEqual(conversation.received, 2)
        XCTAssertEqual(conversation.sent, 1)
        let opened = try openThread(.panel(peer), in: index)
        XCTAssertEqual(opened.items.map(\.envelopeId), [oldestScanned, newSend, newest])
        XCTAssertFalse(opened.showsLedgerFloor)

        // A scan of everything has no floor and keeps every send.
        let full = conversationIndex()
        XCTAssertNil(full.scanFloor)
        XCTAssertEqual(full.conversation(.panel(peer))?.sent, 2)
        XCTAssertEqual(full.conversation(.panel(peer))?.received, 3)
    }

    func testMessagesInTheSameMillisecondKeepOneOrder() throws {
        let millisecond = UInt64(1_800_000_000_000)
        func sameMillisecond(_ byte: UInt8) -> String {
            MailboxULID.encode(timestampMs: millisecond, random: [UInt8](repeating: byte, count: MailboxULID.randomByteCount))
        }
        let peer = UUID()
        let first = sameMillisecond(1), second = sameMillisecond(2), third = sameMillisecond(3)
        try receive(third, from: "p", stamp: peer, read: true)
        try send(second, to: [(peer, .taken)])
        try receive(first, from: "p", stamp: peer, read: true)
        let opened = try openThread(.panel(peer), in: conversationIndex())
        XCTAssertEqual(opened.items.map(\.envelopeId), [first, second, third])
        for _ in 0..<3 {
            XCTAssertEqual(try openThread(.panel(peer), in: conversationIndex()).items.map(\.id), opened.items.map(\.id))
        }

        // A send to this panel itself: one id in both directions, received first.
        let own = sameMillisecond(4)
        try send(own, to: [(thisPanel, .waiting)])
        let ownThread = try openThread(.panel(thisPanel), in: conversationIndex())
        XCTAssertEqual(ownThread.items.map(\.id), ["in/" + own, "out/" + own])
        XCTAssertEqual(ownThread.items.map(\.direction), [.received, .sent])
    }

    func testTheSameFileInTheInboxRootAndReadShowsTwiceWithDistinctIds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID()
        let id = ulid(now - 100)
        try receive(id, from: "p", stamp: peer, read: true, body: "first delivery")
        try receive(id, from: "p", stamp: peer, body: "delivered again")
        let index = conversationIndex()
        XCTAssertEqual(index.conversation(.panel(peer))?.received, 2)
        XCTAssertEqual(index.conversation(.panel(peer))?.unread, 1)
        let opened = try openThread(.panel(peer), in: index)
        XCTAssertEqual(opened.items.map(\.id), ["in/" + id, "in/" + id + "#2"])
        XCTAssertEqual(opened.items.map(\.state), [.read, .unread])
        XCTAssertEqual(opened.items.map { $0.message?.body }, ["first delivery", "delivered again"])
        XCTAssertEqual(opened.firstUnreadId, "in/" + id + "#2")
    }

    func testThreadSignatureChangesOnlyWhenWhatTheThreadShowsChanges() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peer = UUID()
        let sent = ulid(now - 200)
        try receive(ulid(now - 300), from: "p", stamp: peer)
        try send(sent, to: [(peer, .waiting)])
        let index = conversationIndex()
        let conversation = try XCTUnwrap(index.conversation(.panel(peer)))
        func signature() -> String {
            MailboxPanelMail.threadSignature(
                conversation, inbox: inbox, mailboxesRoot: root, ledgerFloor: index.ledgerFloor,
                cache: MailboxPanelMail.HeaderCache()
            )
        }
        let first = signature()
        XCTAssertEqual(signature(), first)
        XCTAssertEqual(try openThread(.panel(peer), in: index).signature, first)

        // The peer takes this panel's send: the same messages, a new state.
        try FileManager.default.createDirectory(at: MailboxDrain.readURL(inbox: peerInbox(peer)), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: peerInbox(peer).appendingPathComponent("\(sent).msg"),
            to: MailboxDrain.readURL(inbox: peerInbox(peer)).appendingPathComponent("\(sent).msg")
        )
        XCTAssertNotEqual(signature(), first)
    }

    // MARK: - Pickup wait (claim rows)

    private var dispatchLog: URL { root.appendingPathComponent(MailboxLayout.dispatchLogFileName) }

    private func claim(_ ids: [String], panel: UUID? = nil, at date: Date) {
        MailboxClaimLog.append(
            ids: ids, recipientPanel: panel ?? thisPanel, byPanel: panel ?? thisPanel,
            via: "recv", mailboxesRoot: root, now: date
        )
    }

    private func appendToLog(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: dispatchLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testClaimLogKeepsOnlyThisPanelsClaimsAndReadsOnlyWhatWasAppended() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let other = UUID()
        let first = ulid(now - 600), second = ulid(now - 300), later = ulid(now - 100)
        claim([first], at: now - 590)
        claim([first], at: now - 500)   // a second claim of one id keeps the earliest
        claim([second], panel: other, at: now - 290)   // another inbox's copy
        try appendToLog(#"{"event":"copied","id":"\#(second)","recipient":"x","ts":"2026-01-01T00:00:00Z"}"# + "\n")
        // A row still being written: not read until its newline lands.
        let partial = MailboxClaimLog.line(id: later, recipientPanel: thisPanel, byPanel: thisPanel, via: "hook", at: now - 90)
        try appendToLog(String(partial.dropLast(20)))

        let log = MailboxPanelMail.ClaimLog()
        var snapshot = log.snapshot(log: dispatchLog, panel: thisPanel, now: now)
        XCTAssertEqual(Set(snapshot.claims.keys), [first])
        XCTAssertEqual(snapshot.claims[first]!.timeIntervalSince1970, (now - 590).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(snapshot.coverage, MailboxPanelMail.ClaimLog.Coverage(exists: true, readFrom: nil))
        XCTAssertEqual(log.snapshot(log: dispatchLog, panel: other, now: now).claims.keys.sorted(), [second])

        // Overwrite the bytes already read, in place: the next look must not
        // read them again, only the rest of the partial row and what follows.
        let handle = try FileHandle(forWritingTo: dispatchLog)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: UInt8(ascii: "x"), count: 40))
        try handle.close()
        try appendToLog(String(partial.suffix(20)))
        snapshot = log.snapshot(log: dispatchLog, panel: thisPanel, now: now)
        XCTAssertEqual(Set(snapshot.claims.keys), [first, later], "kept from the first look, plus the finished row")
        XCTAssertEqual(snapshot.claims[first]!.timeIntervalSince1970, (now - 590).timeIntervalSince1970, accuracy: 0.01)

        // A fresh reader finds the first row garbled and keeps the second claim.
        let fresh = MailboxPanelMail.ClaimLog().snapshot(log: dispatchLog, panel: thisPanel, now: now)
        XCTAssertEqual(Set(fresh.claims.keys), [first, later])
        XCTAssertEqual(fresh.claims[first]!.timeIntervalSince1970, (now - 500).timeIntervalSince1970, accuracy: 0.01)
    }

    func testClaimLogReadsABoundedTailAndSaysWhereItStarts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<20).map { ulid(now - TimeInterval(2000 - $0 * 60)) }
        for (offset, id) in ids.enumerated() { claim([id], at: now - TimeInterval(1900 - offset * 60)) }
        let lineBytes = MailboxClaimLog.line(id: ids[0], recipientPanel: thisPanel, byPanel: thisPanel, via: "recv", at: now).utf8.count

        let log = MailboxPanelMail.ClaimLog(tailBytes: lineBytes * 5 + 10)
        let snapshot = log.snapshot(log: dispatchLog, panel: thisPanel, now: now)
        XCTAssertEqual(snapshot.claims.keys.sorted(), Array(ids.suffix(5)), "only whole rows of the last tail")
        let readFrom = try XCTUnwrap(snapshot.coverage.readFrom)
        XCTAssertEqual(readFrom.timeIntervalSince1970, (now - TimeInterval(1900 - 15 * 60)).timeIntervalSince1970, accuracy: 0.01)

        // More than a tail appended since the last look: start over from the new tail.
        let more = (0..<8).map { ulid(now - TimeInterval(500 - $0 * 10)) }
        for (offset, id) in more.enumerated() { claim([id], at: now - TimeInterval(400 - offset * 10)) }
        let after = log.snapshot(log: dispatchLog, panel: thisPanel, now: now)
        XCTAssertEqual(after.claims.keys.sorted(), Array(more.suffix(5)))
        XCTAssertGreaterThan(try XCTUnwrap(after.coverage.readFrom), readFrom)
    }

    func testClaimLogStartsOverOnAReplacedFileAndDropsOldClaims() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ulid(now - 20 * 86400), recent = ulid(now - 3600), replacement = ulid(now - 60)
        claim([old], at: now - 20 * 86400 + 30)
        claim([recent], at: now - 3500)
        let log = MailboxPanelMail.ClaimLog()
        XCTAssertEqual(log.snapshot(log: dispatchLog, panel: thisPanel, now: now).claims.keys.sorted(), [recent], "past the 14-day window")

        try FileManager.default.removeItem(at: dispatchLog)
        XCTAssertEqual(log.snapshot(log: dispatchLog, panel: thisPanel, now: now), MailboxPanelMail.ClaimLog.Snapshot())
        claim([replacement], at: now - 30)
        XCTAssertEqual(log.snapshot(log: dispatchLog, panel: thisPanel, now: now).claims.keys.sorted(), [replacement])

        try FileManager.default.removeItem(at: dispatchLog)
        try FileManager.default.createDirectory(at: dispatchLog, withIntermediateDirectories: true)
        XCTAssertEqual(
            log.snapshot(log: dispatchLog, panel: thisPanel, now: now).coverage,
            MailboxPanelMail.ClaimLog.Coverage(exists: true, unreadable: true)
        )
    }

    func testInsightsMeasurePickupFromLandingToTheClaim() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fast = ulid(now - 7200), slow = ulid(now - 6 * 3600), late = ulid(now - 3600)
        let unclaimed = ulid(now - 2 * 86400), ancient = ulid(now - 30 * 86400), waiting = ulid(now - 60)
        let broadcast = ulid(now - 1800)
        try receive(fast, from: "captain", stamp: UUID(), read: true)
        try receive(slow, from: "reviewer", stamp: nil, read: true)
        // Landed 10 minutes after it was sent: waits count from landing.
        let lateURL = try receive(late, from: "captain", stamp: nil, read: true)
        try FileManager.default.setAttributes([.modificationDate: now - 3000], ofItemAtPath: lateURL.path)
        try receive(unclaimed, from: "captain", stamp: nil, read: true)
        try receive(ancient, from: "captain", stamp: nil, read: true)
        try receive(waiting, from: "captain", stamp: nil)
        try receive(broadcast, from: "board", stamp: nil, read: true)
        claim([fast], at: now - 7200 + 30)
        claim([slow], at: now - 6 * 3600 + 3 * 3600)
        claim([late], at: now - 3000 + 240)
        // Another panel's copy of the same broadcast id is not this panel's claim.
        claim([broadcast], panel: UUID(), at: now - 1700)

        let insights = MailboxPanelMail.insights(
            inbox: inbox, mailboxesRoot: root, now: now,
            cache: MailboxPanelMail.HeaderCache(), claimLog: MailboxPanelMail.ClaimLog()
        )
        let pickup = insights.pickup
        XCTAssertEqual(pickup.claims, 3)
        XCTAssertEqual(pickup.median!, 240, accuracy: 0.01)
        XCTAssertEqual(pickup.p90!, 3 * 3600, accuracy: 0.01)
        XCTAssertEqual(pickup.slowest!, 3 * 3600, accuracy: 0.01)
        XCTAssertEqual(pickup.buckets, [1, 1, 0, 0, 1])
        XCTAssertEqual(pickup.unclaimed, 2, "taken in the window with no row of its own: the older one and the broadcast")
        XCTAssertEqual(pickup.senders.map(\.name), ["captain", "reviewer"])
        XCTAssertEqual(pickup.senders.first?.claims, 2)
        XCTAssertEqual(pickup.senders.first!.median, 30, accuracy: 0.01)
        XCTAssertTrue(insights.claimLog.exists)
        XCTAssertNil(insights.claimLog.readFrom)

        // The section follows the filters: one sender, then one topic it never used.
        var filter = MailboxPanelMail.InsightsFilter()
        filter.toggleFrom("reviewer")
        let slice = MailboxPanelMail.slice(insights, filter: filter)
        XCTAssertEqual(slice.pickup.claims, 1)
        XCTAssertEqual(slice.pickup.median!, 3 * 3600, accuracy: 0.01)
        filter.toggleTopic("none")
        XCTAssertEqual(MailboxPanelMail.slice(insights, filter: filter).pickup, MailboxPanelMail.Pickup())
    }

    func testPickupWithoutALogSaysSo() throws {
        try receive(ulid(Date() - 60), from: "captain", stamp: nil, read: true)
        let insights = MailboxPanelMail.insights(
            inbox: inbox, mailboxesRoot: root,
            cache: MailboxPanelMail.HeaderCache(), claimLog: MailboxPanelMail.ClaimLog()
        )
        XCTAssertFalse(insights.claimLog.exists)
        XCTAssertEqual(insights.pickup.claims, 0)
        XCTAssertNil(insights.pickup.median)
        XCTAssertEqual(insights.pickup.unclaimed, 1)
    }

    func testWaitTextStaysShortAtEveryScale() {
        XCTAssertEqual(MailboxDrawerText.wait(-5), "0s")
        XCTAssertEqual(MailboxDrawerText.wait(45), "45s")
        XCTAssertEqual(MailboxDrawerText.wait(245), "4m 05s")
        XCTAssertEqual(MailboxDrawerText.wait(12 * 60 + 9), "12m")
        XCTAssertEqual(MailboxDrawerText.wait(3 * 3600 + 5 * 60), "3h 05m")
        XCTAssertEqual(MailboxDrawerText.wait(2 * 86400 + 4 * 3600), "2d 4h")
    }

    // MARK: - Jumps to a conversation

    func testEveryReceivedMessageOpensAConversationTheIndexHolds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captain = UUID()
        try receive(ulid(now - 400), from: "merge-captain", stamp: captain)
        try receive(ulid(now - 300), from: "merge-captain", stamp: nil, read: true)
        try write(["from": ""], id: ulid(now - 200))
        try Data("not json".utf8).write(to: inbox.appendingPathComponent("\(ulid(now - 100)).msg"))

        let messages = MailboxPanelMail.listing(inbox: inbox).messages
        let keys = messages.map(MailboxPanelMail.peerKey(of:))
        XCTAssertEqual(keys, [nil, .name("?"), .name("merge-captain"), .panel(captain)], "newest first; never a name mapped to its panel")
        let index = conversationIndex()
        for key in keys.compactMap({ $0 }) {
            XCTAssertNotNil(index.conversation(key), "\(key)")
        }
    }

    func testASenderFilterOffersEachConversationUnderThatName() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUID(), b = UUID()
        try receive(ulid(now - 400), from: "merge-captain", stamp: a, read: true)
        try receive(ulid(now - 300), from: "merge-captain", stamp: nil)
        try receive(ulid(now - 200), from: "merge-captain", stamp: b)
        try receive(ulid(now - 100), from: "reviewer", stamp: a)
        let insights = MailboxPanelMail.insights(
            inbox: inbox, mailboxesRoot: root, now: now,
            cache: MailboxPanelMail.HeaderCache(), claimLog: nil
        )
        var filter = MailboxPanelMail.InsightsFilter()
        filter.toggleFrom("merge-captain")
        filter.toggleTopic("unrelated")   // other filters never narrow the peers
        let slice = MailboxPanelMail.slice(insights, filter: filter)
        XCTAssertEqual(slice.fromPeers, [.panel(b), .name("merge-captain"), .panel(a)])
        XCTAssertEqual(slice.fromFilter, "merge-captain")

        var one = MailboxPanelMail.InsightsFilter()
        one.toggleFrom("reviewer")
        XCTAssertEqual(MailboxPanelMail.slice(insights, filter: one).fromPeers, [.panel(a)])
        XCTAssertEqual(MailboxPanelMail.slice(insights, filter: MailboxPanelMail.InsightsFilter()).fromPeers, [])
    }

    private func runMain(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date() + timeout
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date() + 0.02)
        }
        return true
    }

    func testOpeningAConversationBeforeTheTabLoadsOpensThatThread() throws {
        let now = Date()
        let older = UUID(), newer = UUID()
        try receive(ulid(now - 300), from: "older", stamp: older)
        try receive(ulid(now - 100), from: "newer", stamp: newer)
        let model = MailboxConversationsModel()
        defer { model.disappeared() }
        model.open(.panel(older))
        XCTAssertTrue(model.showsThread)
        model.appeared(inbox: inbox, resolvePanels: { _ in [:] })
        XCTAssertTrue(runMain(until: { model.thread?.key == .panel(older) }, timeout: 10))
        XCTAssertEqual(model.selected, .panel(older), "not the newest, which a plain visit opens")
        XCTAssertTrue(model.showsThread)
        XCTAssertEqual(model.placement?.key, .panel(older), "placed like a click on its row")
        XCTAssertNil(model.pendingOpen)
    }

    func testOpeningAConversationTheListDoesNotHoldYetRescansAtOnce() throws {
        let now = Date()
        let known = UUID(), arrived = UUID()
        try receive(ulid(now - 300), from: "known", stamp: known)
        let model = MailboxConversationsModel()
        defer { model.disappeared() }
        model.appeared(inbox: inbox, resolvePanels: { _ in [:] })
        XCTAssertTrue(runMain(until: { model.thread?.key == .panel(known) }, timeout: 10))
        // Mail from a new peer lands, and its sender is clicked before the
        // list's next scan (scans are otherwise spaced five seconds apart).
        try receive(ulid(now - 1), from: "arrived", stamp: arrived)
        model.open(.panel(arrived))
        XCTAssertTrue(
            runMain(until: { model.thread?.key == .panel(arrived) }, timeout: MailboxConversationsModel.refreshInterval - 1),
            "the jump rescans without waiting for the spacing"
        )
        XCTAssertEqual(model.selected, .panel(arrived))
        XCTAssertEqual(model.placement?.key, .panel(arrived))
    }

    func testOpeningAConversationTheListLacksShowsTheList() throws {
        let now = Date()
        let peer = UUID()
        try receive(ulid(now - 100), from: "peer", stamp: peer)
        let model = MailboxConversationsModel()
        defer { model.disappeared() }
        model.open(.name("nobody"))
        model.appeared(inbox: inbox, resolvePanels: { _ in [:] })
        XCTAssertTrue(runMain(until: { model.index != nil && model.pendingOpen == nil && model.thread != nil }, timeout: 10))
        XCTAssertEqual(model.selected, .panel(peer), "the default selection, behind the list")
        XCTAssertFalse(model.showsThread, "a narrow drawer shows the list, not an empty thread")
    }

}

/// C11-400: which panels the subtitle bar's badge store keeps recounting.
final class MailboxBadgeStoreTests: XCTestCase {

    private var root: URL!
    private var store: MailboxBadgeStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-badge-store-\(UUID().uuidString)", isDirectory: true)
        let root = root!
        store = MailboxBadgeStore(mailboxesRoot: { root.appendingPathComponent($0.uuidString, isDirectory: true) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func deliver(to panelId: UUID, in workspaceId: UUID) throws {
        let inbox = try XCTUnwrap(store.inboxURL(workspaceId: workspaceId, panelId: panelId))
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = MailboxULID.encode(
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            random: [UInt8](repeating: 7, count: MailboxULID.randomByteCount)
        )
        let object: [String: Any] = ["version": 1, "id": id, "from": "Sender", "ts": "2026-10-14T08:00:00Z", "body": "hi"]
        try JSONSerialization.data(withJSONObject: object).write(to: inbox.appendingPathComponent("\(id).msg"))
    }

    private func waitForUnread(_ count: Int, panelId: UUID, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while store.cachedSummary(panelId: panelId).unread != count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(store.cachedSummary(panelId: panelId).unread, count, file: file, line: line)
    }

    /// C11-399: a panel that only sent mail still gets the mailbox cell.
    func testSentOnlyPanelExposesMailbox() throws {
        let workspace = UUID(), panel = UUID()
        let inbox = try XCTUnwrap(store.inboxURL(workspaceId: workspace, panelId: panel))
        XCTAssertFalse(MailboxPanelMail.summary(inbox: inbox).hasMail)
        store.track(panelId: panel, workspaceId: workspace)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(store.cachedSummary(panelId: panel).hasMail)

        // The dispatcher records a send, then reports the sender's inbox.
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        XCTAssertTrue(MailboxSentLedger.record(
            .init(id: "01K3A2B7X8PQRTVWYZ0123456J", ts: nil, to: "x", topic: nil, recipients: []),
            senderInbox: inbox
        ))
        store.inboxChanged(workspaceId: workspace, panelId: panel)
        let deadline = Date().addingTimeInterval(5)
        while !store.cachedSummary(panelId: panel).hasMail, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let summary = store.cachedSummary(panelId: panel)
        XCTAssertTrue(summary.hasMail)
        XCTAssertTrue(summary.hasSent)
        // The counts keep their meaning: nothing was received.
        XCTAssertEqual(summary.unread, 0)
        XCTAssertEqual(summary.received, 0)
    }

    func testDeliveryAfterCloseLeavesTheClosedPanelOffTheSweep() throws {
        let workspace = UUID(), panel = UUID()
        store.track(panelId: panel, workspaceId: workspace)
        store.forget(panelId: panel)
        try deliver(to: panel, in: workspace)
        store.inboxChanged(workspaceId: workspace, panelId: panel)
        XCTAssertFalse(store.isTracking(panelId: panel))
    }

    func testDeliveryToALivePanelRecountsIt() throws {
        let workspace = UUID(), panel = UUID()
        store.track(panelId: panel, workspaceId: workspace)
        waitForUnread(0, panelId: panel)
        try deliver(to: panel, in: workspace)
        store.inboxChanged(workspaceId: workspace, panelId: panel)
        waitForUnread(1, panelId: panel)
        XCTAssertTrue(store.isTracking(panelId: panel))
    }

    /// C11-517: a draft hold is not a file count. A recount leaves it, and
    /// clearing it or closing the panel removes it. Nothing here types.
    func testDraftHoldSurvivesARecountAndClears() throws {
        let workspace = UUID(), panel = UUID()
        store.track(panelId: panel, workspaceId: workspace)
        store.setDraftHold(panelId: panel, count: 2)
        XCTAssertEqual(store.draftHoldCount(panelId: panel), 2)
        let model = store.modelForPanel(panel)
        XCTAssertEqual(model.heldBehindDraft, 2)

        let later = store.modelForPanel(panel)
        XCTAssertTrue(later === model)

        store.setDraftHold(panelId: panel, count: 2)
        XCTAssertEqual(model.heldBehindDraft, 2)

        try deliver(to: panel, in: workspace)
        store.inboxChanged(workspaceId: workspace, panelId: panel)
        waitForUnread(1, panelId: panel)
        XCTAssertEqual(store.draftHoldCount(panelId: panel), 2)
        XCTAssertEqual(model.heldBehindDraft, 2)
        XCTAssertEqual(store.cachedSummary(panelId: panel).unread, 1)

        store.setDraftHold(panelId: panel, count: 0)
        XCTAssertEqual(store.draftHoldCount(panelId: panel), 0)
        XCTAssertEqual(model.heldBehindDraft, 0)

        store.setDraftHold(panelId: panel, count: 4)
        store.forget(panelId: panel)
        XCTAssertEqual(store.draftHoldCount(panelId: panel), 0)
    }

    /// An empty count before the cell has seen unread mail is not a receipt.
    /// Unread falling to zero is. The cell reads the model.
    func testReceiptClearsOnlyAfterUnreadDropsToZero() {
        let panel = UUID()
        let model = MailboxBadgeModel(panelId: panel)
        model.setDraftHold(1)
        model.apply(.empty, now: Date())
        XCTAssertEqual(model.heldBehindDraft, 1)

        var unread = MailboxPanelMail.Summary.empty
        unread.unread = 1
        unread.received = 1
        model.apply(unread, now: Date())
        XCTAssertEqual(model.heldBehindDraft, 1)

        model.apply(.empty, now: Date())
        XCTAssertEqual(model.heldBehindDraft, 0)
    }

    /// Claiming the last unread envelope clears the store and the cell.
    /// A later look is not required. Nothing here types into a composer.
    func testRecvOfTheLastUnreadClearsADraftHold() throws {
        let workspace = UUID(), panel = UUID()
        store.track(panelId: panel, workspaceId: workspace)
        try deliver(to: panel, in: workspace)
        store.inboxChanged(workspaceId: workspace, panelId: panel)
        waitForUnread(1, panelId: panel)
        store.setDraftHold(panelId: panel, count: 1)
        let model = store.modelForPanel(panel)
        XCTAssertEqual(model.heldBehindDraft, 1)
        XCTAssertEqual(store.draftHoldCount(panelId: panel), 1)

        let inbox = try XCTUnwrap(store.inboxURL(workspaceId: workspace, panelId: panel))
        let read = inbox.appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)
        let messages = try FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "msg" }
        XCTAssertFalse(messages.isEmpty)
        for message in messages {
            try FileManager.default.moveItem(
                at: message,
                to: read.appendingPathComponent(message.lastPathComponent)
            )
        }
        store.inboxChanged(workspaceId: workspace, panelId: panel)
        waitForUnread(0, panelId: panel)
        XCTAssertEqual(store.draftHoldCount(panelId: panel), 0)
        XCTAssertEqual(model.heldBehindDraft, 0)
    }

    func testDraftHoldRecordedBeforeTheCellIsCopiedOntoTheModel() {
        let panel = UUID()
        store.setDraftHold(panelId: panel, count: 3)
        XCTAssertEqual(store.modelForPanel(panel).heldBehindDraft, 3)
    }

    /// The cell and the drawer read the model. Removing the sentence from
    /// that copy fails this test. Nothing here types into a composer.
    func testCellAndDrawerCopyTheModelHold() {
        let panel = UUID()
        store.setDraftHold(panelId: panel, count: 1)
        let model = store.modelForPanel(panel)
        XCTAssertEqual(
            MailboxHoldCopy.cellAccessibility(unread: 1, received: 1, heldBehindDraft: model.heldBehindDraft),
            "Mailbox, 1 unread, 1 received. 1 message held behind your draft"
        )
        XCTAssertEqual(
            MailboxHoldCopy.drawerBanner(heldBehindDraft: model.heldBehindDraft),
            "1 message held behind your draft"
        )

        store.setDraftHold(panelId: panel, count: 0)
        XCTAssertNil(MailboxHoldCopy.drawerBanner(heldBehindDraft: model.heldBehindDraft))
        XCTAssertFalse(
            MailboxHoldCopy.cellAccessibility(unread: 0, received: 0, heldBehindDraft: model.heldBehindDraft)
                .contains("held behind")
        )
    }

    func testDeliveryToAPanelMovedToAnotherWorkspaceRecountsItThere() throws {
        let before = UUID(), after = UUID(), panel = UUID()
        store.track(panelId: panel, workspaceId: before)
        waitForUnread(0, panelId: panel)
        // The delivery reports the new workspace before its bar has re-read.
        try deliver(to: panel, in: after)
        store.inboxChanged(workspaceId: after, panelId: panel)
        waitForUnread(1, panelId: panel)
        XCTAssertTrue(store.isTracking(panelId: panel))
    }
}

/// C11-399: the Sent view, read from the sender's ledger and the recipients'
/// own copies on a real tree.
final class MailboxSentViewTests: XCTestCase {

    private var root: URL!
    private let sender = UUID()
    private let alpha = UUID()
    private let beta = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-sent-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func inbox(_ panel: UUID) -> URL { MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: panel) }

    private func ulid(_ offset: TimeInterval) -> String {
        MailboxULID.encode(
            timestampMs: UInt64(Date().addingTimeInterval(offset).timeIntervalSince1970 * 1000),
            random: [UInt8](repeating: 9, count: MailboxULID.randomByteCount)
        )
    }

    /// A recipient copy as the dispatcher writes it: stamped with the sender
    /// unless `stamp` says otherwise.
    private func deliver(_ id: String, to panel: UUID, read: Bool = false, stamp: UUID?, body: String = "hello") throws {
        var object: [String: Any] = ["version": 1, "id": id, "from": "sender", "ts": "2026-10-22T04:00:00Z", "body": body, "to": "x"]
        if let stamp { object["ext"] = [MailboxEnvelope.senderPanelKey: stamp.uuidString.lowercased()] }
        let dir = read ? MailboxDrain.readURL(inbox: inbox(panel)) : inbox(panel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent("\(id).msg"))
    }

    private func ledger(_ id: String, to panels: [(UUID, String)], topic: String? = "t") {
        MailboxSentLedger.record(
            .init(id: id, ts: "2026-10-22T04:00:00Z", to: "x", topic: topic,
                  recipients: panels.map { .init(panel: $0.0.uuidString.lowercased(), name: $0.1) }),
            senderInbox: inbox(sender)
        )
    }

    private func listing() -> MailboxPanelMail.SentListing {
        MailboxPanelMail.sentListing(senderInbox: inbox(sender), mailboxesRoot: root)
    }

    func testSentListsEachRecipientWithItsReadState() throws {
        let id = ulid(-10)
        try deliver(id, to: alpha, stamp: sender)
        try deliver(id, to: beta, read: true, stamp: sender)
        ledger(id, to: [(alpha, "alpha"), (beta, "beta")])
        let sent = listing()
        XCTAssertEqual(sent.total, 1)
        let message = try XCTUnwrap(sent.messages.first)
        XCTAssertEqual(message.recipients.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(message.recipients.map(\.state), [.unread, .read])
        XCTAssertEqual(message.message?.body, "hello")
        XCTAssertEqual(message.topic, "t")
    }

    func testStateFollowsTheRecipientClaimingAndTheCopyDisappearing() throws {
        let id = ulid(-10)
        try deliver(id, to: alpha, stamp: sender)
        ledger(id, to: [(alpha, "alpha")])
        XCTAssertEqual(listing().messages.first?.recipients.first?.state, .unread)
        // A claim renames the file into _read/.
        try FileManager.default.createDirectory(at: MailboxDrain.readURL(inbox: inbox(alpha)), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: inbox(alpha).appendingPathComponent("\(id).msg"),
            to: MailboxDrain.readURL(inbox: inbox(alpha)).appendingPathComponent("\(id).msg")
        )
        XCTAssertEqual(listing().messages.first?.recipients.first?.state, .read)
        try FileManager.default.removeItem(at: MailboxDrain.readURL(inbox: inbox(alpha)).appendingPathComponent("\(id).msg"))
        let gone = try XCTUnwrap(listing().messages.first)
        XCTAssertEqual(gone.recipients.first?.state, .gone)
        XCTAssertNil(gone.message)
    }

    func testMailSentBeforeTheStampIsNotInSentButStillInReceived() throws {
        // An old envelope: delivered to alpha with no stamp and no ledger entry.
        let old = ulid(-100)
        try deliver(old, to: alpha, stamp: nil)
        XCTAssertEqual(listing().total, 0)
        XCTAssertTrue(listing().messages.isEmpty)
        let received = MailboxPanelMail.listing(inbox: inbox(alpha))
        XCTAssertEqual(received.messages.map(\.fileId), [old])
        XCTAssertNil(received.messages.first?.senderPanelId)
    }

    func testACopyThisPanelDidNotSendIsNeverShown() throws {
        // The ledger names alpha, but alpha's copy carries another sender's stamp
        // (or none): the entry's say-so is not enough.
        let forged = ulid(-10), unstamped = ulid(-5)
        try deliver(forged, to: alpha, stamp: UUID(), body: "SECRET-FROM-SOMEONE-ELSE")
        try deliver(unstamped, to: alpha, stamp: nil, body: "SECRET-UNSTAMPED")
        ledger(forged, to: [(alpha, "alpha")])
        ledger(unstamped, to: [(alpha, "alpha")])
        for message in listing().messages {
            XCTAssertEqual(message.recipients.first?.state, .gone)
            XCTAssertNil(message.message)
        }
    }

    /// Records every directory listing and existence probe the reader makes.
    private final class RecordingFileManager: FileManager {
        var listed: [String] = []
        var probed: [String] = []
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            listed.append(url.path)
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
        override func contentsOfDirectory(atPath path: String) throws -> [String] {
            listed.append(path)
            return try super.contentsOfDirectory(atPath: path)
        }
        override func subpathsOfDirectory(atPath path: String) throws -> [String] {
            listed.append(path)
            return try super.subpathsOfDirectory(atPath: path)
        }
        override func fileExists(atPath path: String) -> Bool {
            probed.append(path)
            return super.fileExists(atPath: path)
        }
        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            probed.append(path)
            return super.fileExists(atPath: path, isDirectory: isDirectory)
        }
    }

    func testOnlyTheLedgersRecipientsAreTouched() throws {
        // The reader lists exactly one directory, the sender's `_sent/`, and
        // probes only the two paths of each recipient the ledger names. Other
        // panels' directories are neither listed nor probed, however many.
        let id = ulid(-10)
        try deliver(id, to: alpha, stamp: sender)
        ledger(id, to: [(alpha, "alpha")])
        let bystanders = [UUID(), UUID(), UUID()]
        for panel in bystanders {
            try FileManager.default.createDirectory(at: inbox(panel), withIntermediateDirectories: true)
            try "not json".write(to: inbox(panel).appendingPathComponent("\(ulid(-1)).msg"), atomically: true, encoding: .utf8)
        }
        let recorder = RecordingFileManager()
        let sent = MailboxPanelMail.sentListing(senderInbox: inbox(sender), mailboxesRoot: root, fileManager: recorder)
        XCTAssertEqual(sent.messages.count, 1)
        XCTAssertEqual(sent.messages.first?.recipients.map(\.name), ["alpha"])
        XCTAssertEqual(recorder.listed.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       [MailboxSentLedger.directory(inbox: inbox(sender)).standardizedFileURL.path])
        let allowed = Set([
            inbox(alpha).appendingPathComponent("\(id).msg").standardizedFileURL.path,
            MailboxDrain.readURL(inbox: inbox(alpha)).appendingPathComponent("\(id).msg").standardizedFileURL.path,
        ])
        for path in recorder.probed {
            XCTAssertTrue(allowed.contains(URL(fileURLWithPath: path).standardizedFileURL.path), "unexpected probe: \(path)")
        }
        XCTAssertFalse(recorder.probed.isEmpty)
    }

    func testAMismatchedCopysBodyRefIsNotFollowed() throws {
        // Another sender's stamp: the copy is dropped before its body_ref is read.
        let id = ulid(-10)
        let marker = root.appendingPathComponent("referenced.txt")
        try "REFERENCED-SECRET".write(to: marker, atomically: true, encoding: .utf8)
        var object: [String: Any] = ["version": 1, "id": id, "from": "x", "ts": "2026-10-22T04:00:00Z", "body": "", "to": "x",
                                     "body_ref": marker.path]
        object["ext"] = [MailboxEnvelope.senderPanelKey: UUID().uuidString.lowercased()]
        try FileManager.default.createDirectory(at: inbox(alpha), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: inbox(alpha).appendingPathComponent("\(id).msg"))
        ledger(id, to: [(alpha, "alpha")])
        let message = try XCTUnwrap(listing().messages.first)
        XCTAssertEqual(message.recipients.first?.state, .gone)
        XCTAssertNil(message.message)
    }

    func testListingIsNewestFirstAndLimited() throws {
        for offset in [-30.0, -20, -10] {
            let id = ulid(offset)
            try deliver(id, to: alpha, stamp: sender)
            ledger(id, to: [(alpha, "alpha")])
        }
        let sent = MailboxPanelMail.sentListing(senderInbox: inbox(sender), mailboxesRoot: root, limit: 2)
        XCTAssertEqual(sent.total, 3)
        XCTAssertEqual(sent.messages.count, 2)
        XCTAssertEqual(sent.hiddenCount, 1)
        XCTAssertEqual(sent.messages.map(\.entryId), sent.messages.map(\.entryId).sorted(by: >))
    }

    func testLedgerTrimsOldestPastItsBound() throws {
        let dir = MailboxSentLedger.directory(inbox: inbox(sender))
        let total = MailboxSentLedger.retain + MailboxSentLedger.trimSlack + 5
        var first = ""
        for index in 0..<total {
            let id = ulid(TimeInterval(index) - 10_000)
            if index == 0 { first = id }
            MailboxSentLedger.record(.init(id: id, ts: nil, to: nil, topic: nil, recipients: []), senderInbox: inbox(sender))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertLessThanOrEqual(names.count, MailboxSentLedger.retain + MailboxSentLedger.trimSlack)
        XCTAssertFalse(names.contains("\(first).\(MailboxSentLedger.fileExtension)"))
    }
}

