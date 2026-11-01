import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-550: `c11 mailbox status <id>` builds sent, delivered and read per
/// recipient from the dispatch log and the recipient's inbox files.
final class MailboxReceiptStatusTests: XCTestCase {

    private var root: URL!
    private var workspacesRoot: URL!
    private let workspace = UUID()
    private let recipient = UUID()
    private let other = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-status-\(UUID().uuidString)", isDirectory: true)
        workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: mailboxes(workspace), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func mailboxes(_ workspace: UUID) -> URL {
        workspacesRoot
            .appendingPathComponent(workspace.uuidString, isDirectory: true)
            .appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
    }

    private var logURL: URL { mailboxes(workspace).appendingPathComponent(MailboxLayout.dispatchLogFileName) }

    private func inbox(_ panel: UUID) -> URL {
        mailboxes(workspace).appendingPathComponent(MailboxLayout.inboxDirectoryName(panelId: panel), isDirectory: true)
    }

    private func line(_ event: MailboxDispatchLog.Event, _ at: Date) -> String {
        MailboxDispatchLog.serialize(event: event, at: at)
    }

    private func stdin(_ id: String, _ outcome: MailboxDispatchLog.HandlerOutcome, _ reason: String?,
                       route: String? = nil, panel: UUID? = nil, name: String = "lead") -> MailboxDispatchLog.Event {
        .handler(id: id, recipient: name, handler: "stdin", outcome: outcome, bytes: nil, elapsedMs: nil,
                 reason: reason, route: route, recipientPanel: panel ?? recipient)
    }

    /// The rows every dispatched envelope gets, to one recipient panel.
    private func dispatched(_ id: String, at: Date, panels: [(UUID, String)]? = nil) -> [String] {
        let targets = panels ?? [(recipient, "lead")]
        var rows = [
            line(.received(id: id, from: "owner", to: "lead", topic: "plan"), at),
            line(.resolved(id: id, recipients: targets.map(\.1)), at),
        ]
        for (panel, name) in targets {
            rows.append(line(.copied(id: id, recipient: name, recipientPanel: panel), at))
        }
        return rows
    }

    private func writeLog(_ lines: [String]) throws {
        try lines.joined().write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func deliverFile(_ id: String, to panel: UUID, read: Bool) throws {
        let dir = read ? MailboxDrain.readURL(inbox: inbox(panel)) : inbox(panel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
    }

    private func status(_ id: String) throws -> MailboxReceiptStatus.Report {
        try MailboxReceiptStatus.status(id: id, workspacesRoot: workspacesRoot)
    }

    private func newId(_ at: Date) -> String { MailboxULID.make(now: at) }

    // MARK: - Scenario 2: native, typed, held

    func testNativeRouteDeliveryShowsDeliveredWithItsRoute() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbell, "started", route: "claude_inbox"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbell, "submitted", route: "claude_inbox"), t.addingTimeInterval(2)),
        ])
        try deliverFile(id, to: recipient, read: false)

        let report = try status(id)
        XCTAssertEqual(report.state, .sent)
        XCTAssertEqual(report.recipients.count, 1)
        let row = try XCTUnwrap(report.recipients.first)
        XCTAssertEqual(row.panelId, recipient)
        XCTAssertEqual(row.delivery, .delivered)
        XCTAssertEqual(row.deliveryRoute, "claude_inbox")
        XCTAssertEqual(row.read, .unread)
        XCTAssertNotNil(row.sentAt)
        XCTAssertEqual(row.deliveredAt.map { Int($0.timeIntervalSince(t).rounded()) }, 2)
    }

    func testTypedRouteDeliveryShowsDelivered() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .buffered, nil), t),
            line(stdin(id, .doorbell, "started", route: "typed"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbell, "submitted", route: "typed"), t.addingTimeInterval(1)),
        ])
        try deliverFile(id, to: recipient, read: false)
        let row = try XCTUnwrap(try status(id).recipients.first)
        XCTAssertEqual(row.delivery, .delivered)
        XCTAssertEqual(row.deliveryRoute, "typed")
    }

    func testDraftHoldIsHeldNeverDelivered() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .buffered, nil), t),
            line(stdin(id, .doorbellSkipped, "draft"), t.addingTimeInterval(1)),
            line(.doorbellRecheck(id: id, recipient: "lead", reason: "draft", nextMs: 5_000, recipientPanel: recipient),
                 t.addingTimeInterval(6)),
        ])
        try deliverFile(id, to: recipient, read: false)
        let report = try status(id)
        let row = try XCTUnwrap(report.recipients.first)
        XCTAssertEqual(row.delivery, .held)
        XCTAssertEqual(row.deliveryReason, "draft")
        XCTAssertNil(row.deliveredAt)
        XCTAssertEqual(report.jsonObject()["recipients"].flatMap { ($0 as? [[String: Any]])?.first?["delivered"] as? Bool }, false)
        XCTAssertTrue(report.humanText().contains("held: recipient has a draft"), report.humanText())
    }

    /// Claude's chooser: the native invitation is never confirmed and the typed
    /// fallback finds a dialog. Held, not delivered and not failed.
    func testChooserHoldIsHeld() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbell, "started", route: "claude_inbox"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbellFailed, "native_unconfirmed", route: "claude_inbox"), t.addingTimeInterval(3)),
        ])
        try deliverFile(id, to: recipient, read: false)
        var row = try XCTUnwrap(try status(id).recipients.first)
        XCTAssertEqual(row.delivery, .held)
        XCTAssertEqual(row.deliveryReason, "unconfirmed")

        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbell, "started", route: "claude_inbox"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbellFailed, "native_unconfirmed", route: "claude_inbox"), t.addingTimeInterval(3)),
            line(stdin(id, .doorbellSkipped, "dialog"), t.addingTimeInterval(4)),
        ])
        row = try XCTUnwrap(try status(id).recipients.first)
        XCTAssertEqual(row.delivery, .held)
        XCTAssertEqual(row.deliveryReason, "dialog")
    }

    func testDeliveredSticksAfterLaterHoldRows() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbell, "submitted", route: "typed"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbellSkipped, "draft"), t.addingTimeInterval(2)),
            line(stdin(id, .doorbellFailed, "pasted_not_submitted"), t.addingTimeInterval(3)),
        ])
        try deliverFile(id, to: recipient, read: false)
        XCTAssertEqual(try status(id).recipients.first?.delivery, .delivered)
    }

    // MARK: - Scenario 3: read is the recipient's own claim

    func testRecipientClaimIsRead() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbell, "submitted", route: "typed"), t.addingTimeInterval(1)),
            MailboxClaimLog.line(id: id, recipientPanel: recipient, byPanel: recipient, via: "recv", at: t.addingTimeInterval(5)),
        ])
        try deliverFile(id, to: recipient, read: true)
        let report = try status(id)
        let row = try XCTUnwrap(report.recipients.first)
        XCTAssertEqual(row.read, .read)
        XCTAssertEqual(row.claimedBy, recipient)
        XCTAssertEqual(row.readAt.map { Int($0.timeIntervalSince(t).rounded()) }, 5)
        let json = try XCTUnwrap((report.jsonObject()["recipients"] as? [[String: Any]])?.first)
        XCTAssertEqual(json["read"] as? Bool, true)
        XCTAssertEqual(json["read_state"] as? String, "read")
    }

    func testOtherPanelClaimIsTakenNotRead() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            MailboxClaimLog.line(id: id, recipientPanel: recipient, byPanel: other, via: "recv", at: t.addingTimeInterval(5)),
        ])
        try deliverFile(id, to: recipient, read: true)
        let report = try status(id)
        let row = try XCTUnwrap(report.recipients.first)
        XCTAssertEqual(row.read, .taken)
        XCTAssertEqual(row.claimedBy, other)
        XCTAssertNotEqual(row.delivery, .delivered, "another panel's drain is not a delivery to the recipient")
        XCTAssertEqual((report.jsonObject()["recipients"] as? [[String: Any]])?.first?["read"] as? Bool, false)
        XCTAssertTrue(report.humanText().contains("taken by panel \(other.uuidString.lowercased())"))
    }

    func testRecipientClaimWithoutRingCountsAsDelivered() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            MailboxClaimLog.line(id: id, recipientPanel: recipient, byPanel: recipient, via: "hook", at: t.addingTimeInterval(4)),
        ])
        try deliverFile(id, to: recipient, read: true)
        let row = try XCTUnwrap(try status(id).recipients.first)
        XCTAssertEqual(row.delivery, .delivered)
        XCTAssertEqual(row.deliveryReason, "claim")
    }

    func testClaimWithoutRowIsClaimedUnknown() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t))
        try deliverFile(id, to: recipient, read: true)
        XCTAssertEqual(try status(id).recipients.first?.read, .claimedUnknown)
    }

    func testCopyGoneFromBothPlacesIsGone() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t))
        XCTAssertEqual(try status(id).recipients.first?.read, .gone)
    }

    // MARK: - Broadcast and multi-recipient

    func testSameTitleFanOutTracksEachPanel() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t, panels: [(recipient, "watcher"), (other, "watcher")]) + [
            line(stdin(id, .doorbell, "submitted", route: "typed", panel: recipient, name: "watcher"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbellSkipped, "draft", panel: other, name: "watcher"), t.addingTimeInterval(1)),
            MailboxClaimLog.line(id: id, recipientPanel: recipient, byPanel: recipient, via: "recv", at: t.addingTimeInterval(3)),
        ])
        try deliverFile(id, to: recipient, read: true)
        try deliverFile(id, to: other, read: false)
        let rows = try status(id).recipients
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first { $0.panelId == recipient })
        let second = try XCTUnwrap(rows.first { $0.panelId == other })
        XCTAssertEqual(first.delivery, .delivered)
        XCTAssertEqual(first.read, .read)
        XCTAssertEqual(second.delivery, .held)
        XCTAssertEqual(second.read, .unread)
    }

    func testTopicOnlyEnvelopeIsSentToNoRecipients() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog([
            line(.received(id: id, from: "owner", to: nil, topic: "ci.status"), t),
            line(.resolved(id: id, recipients: []), t),
            line(.cleaned(id: id), t),
        ])
        let report = try status(id)
        XCTAssertEqual(report.state, .sent)
        XCTAssertTrue(report.recipients.isEmpty)
        XCTAssertEqual(report.topic, "ci.status")
    }

    func testRejectedEnvelopeShowsItsReason() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog([
            line(.received(id: id, from: "owner", to: "nobody", topic: nil), t),
            line(.resolved(id: id, recipients: []), t),
            line(.rejected(id: id, reason: "no live panel named 'nobody'"), t),
        ])
        let report = try status(id)
        XCTAssertEqual(report.state, .rejected)
        XCTAssertEqual(report.rejectedReason, "no live panel named 'nobody'")
    }

    // MARK: - Scenario 1: unknown ids are clean errors

    func testUnknownAndMalformedIdsAreCleanErrors() throws {
        try writeLog(dispatched(newId(Date().addingTimeInterval(-30)), at: Date().addingTimeInterval(-30)))
        let missing = newId(Date().addingTimeInterval(-10))
        XCTAssertThrowsError(try status(missing)) {
            XCTAssertEqual($0 as? MailboxReceiptStatus.Failure, .notFound(missing))
        }
        XCTAssertThrowsError(try status("not-a-ulid")) {
            XCTAssertEqual($0 as? MailboxReceiptStatus.Failure, .invalidId("not-a-ulid"))
        }
    }

    func testEnvelopeStillInOutboxIsQueued() throws {
        let id = newId(Date().addingTimeInterval(-10))
        let outbox = mailboxes(workspace).appendingPathComponent(MailboxLayout.outboxDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
        XCTAssertEqual(try status(id).state, .queued)
    }

    func testCrossWorkspaceSendIsFoundInTheRecipientsLog() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        // The sender's workspace logged other traffic; the recipient's dispatched it.
        try writeLog(dispatched(newId(t), at: t))
        let elsewhere = UUID()
        try FileManager.default.createDirectory(at: mailboxes(elsewhere), withIntermediateDirectories: true)
        try dispatched(id, at: t).joined()
            .write(to: mailboxes(elsewhere).appendingPathComponent(MailboxLayout.dispatchLogFileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(try status(id).workspaceId, elsewhere)
    }

    // MARK: - Scenario 5: bounded on 5,000 envelopes

    func testFiveThousandEnvelopeQueryIsBounded() throws {
        let count = 5_000
        let start = Date().addingTimeInterval(-Double(count) - 60)
        var lines: [String] = []
        var ids: [String] = []
        lines.reserveCapacity(count * 7)
        for index in 0..<count {
            let t = start.addingTimeInterval(Double(index))
            let id = newId(t)
            ids.append(id)
            lines += dispatched(id, at: t)
            lines.append(line(stdin(id, .buffered, nil), t))
            lines.append(line(stdin(id, .doorbell, "submitted", route: "typed"), t.addingTimeInterval(0.5)))
            lines.append(line(.cleaned(id: id), t))
            try deliverFile(id, to: recipient, read: false)
        }
        try writeLog(lines)
        // Many quiet workspaces: their logs predate the send and are skipped by mtime.
        for _ in 0..<200 {
            let quiet = mailboxes(UUID())
            try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
            let log = quiet.appendingPathComponent(MailboxLayout.dispatchLogFileName)
            try lines.prefix(50).joined().write(to: log, atomically: true, encoding: .utf8)
            var times = [timeval(tv_sec: Int(start.timeIntervalSince1970) - 3600, tv_usec: 0),
                         timeval(tv_sec: Int(start.timeIntervalSince1970) - 3600, tv_usec: 0)]
            XCTAssertEqual(utimes(log.path, &times), 0)
        }
        let logBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int)

        let newestClock = Date()
        let newest = try status(ids[count - 1])
        let newestSeconds = Date().timeIntervalSince(newestClock)
        let oldestClock = Date()
        let oldest = try status(ids[0])
        let oldestSeconds = Date().timeIntervalSince(oldestClock)

        XCTAssertEqual(newest.recipients.first?.delivery, .delivered)
        XCTAssertEqual(oldest.recipients.first?.delivery, .delivered)
        // The binary search skips almost the whole log for a recent message.
        XCTAssertLessThan(newest.scannedBytes, logBytes / 20, "newest scanned \(newest.scannedBytes) of \(logBytes)")
        XCTAssertLessThanOrEqual(oldest.scannedBytes, logBytes + 64 * 1024)
        XCTAssertLessThan(newestSeconds, 1.0)
        XCTAssertLessThan(oldestSeconds, 2.0)
        let summary = "C11-550 bound: log \(logBytes) B, newest \(newest.scannedBytes) B in \(Int(newestSeconds * 1000)) ms, "
            + "oldest \(oldest.scannedBytes) B in \(Int(oldestSeconds * 1000)) ms\n"
        print(summary, terminator: "")
    }

    func testScanStopsAtItsByteBudget() throws {
        let t = Date().addingTimeInterval(-600)
        let id = newId(t)
        var lines = dispatched(id, at: t)
        let filler = newId(t)
        for index in 0..<2_000 {
            lines.append(line(stdin(filler, .buffered, nil), t.addingTimeInterval(Double(index) * 0.1)))
        }
        lines.append(line(stdin(id, .doorbell, "submitted", route: "typed"), t.addingTimeInterval(300)))
        try writeLog(lines)
        var limits = MailboxReceiptStatus.Limits()
        limits.maxScanBytes = 64 * 1024
        limits.chunkBytes = 16 * 1024
        let report = try MailboxReceiptStatus.status(id: id, workspacesRoot: workspacesRoot, limits: limits)
        XCTAssertTrue(report.scanTruncated)
        XCTAssertLessThanOrEqual(report.scannedBytes, 64 * 1024 + 16 * 1024)
    }

    /// A panel that moved keeps its inbox and `copied` row in the old
    /// workspace; its doorbell rows are written by the new one.
    func testMovedPanelMergesRowsFromBothWorkspaces() throws {
        let t = Date().addingTimeInterval(-900)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [line(stdin(id, .buffered, nil), t)])
        let moved = UUID()
        try FileManager.default.createDirectory(at: mailboxes(moved), withIntermediateDirectories: true)
        try line(stdin(id, .doorbell, "submitted", route: "typed"), t.addingTimeInterval(600))
            .write(to: mailboxes(moved).appendingPathComponent(MailboxLayout.dispatchLogFileName), atomically: true, encoding: .utf8)
        try deliverFile(id, to: recipient, read: false)
        let report = try status(id)
        XCTAssertEqual(report.workspaceId, workspace)
        XCTAssertEqual(report.from, "owner")
        let row = try XCTUnwrap(report.recipients.first)
        XCTAssertEqual(row.delivery, .delivered)
        XCTAssertEqual(row.read, .unread)
    }

    func testOpenCodeReplayAlreadyAdmittedIsDelivered() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbell, "started", route: "opencode_plugin"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbell, "native_already_admitted", route: "opencode_plugin"), t.addingTimeInterval(3)),
        ])
        try deliverFile(id, to: recipient, read: false)
        XCTAssertEqual(try status(id).recipients.first?.delivery, .delivered)
    }

    func testRetriedSkipsAreHeldOrPendingNotNeverRung() throws {
        let t = Date().addingTimeInterval(-30)
        let id = newId(t)
        try writeLog(dispatched(id, at: t) + [line(stdin(id, .doorbellSkipped, "unavailable"), t.addingTimeInterval(1))])
        try deliverFile(id, to: recipient, read: false)
        var row = try XCTUnwrap(try status(id).recipients.first)
        XCTAssertEqual(row.delivery, .held)
        XCTAssertEqual(row.deliveryReason, "unknown_prompt")

        try writeLog(dispatched(id, at: t) + [
            line(stdin(id, .doorbellSkipped, "flagged"), t.addingTimeInterval(1)),
            line(stdin(id, .doorbellSkipped, "agent_not_foreground"), t.addingTimeInterval(2)),
        ])
        row = try XCTUnwrap(try status(id).recipients.first)
        XCTAssertEqual(row.delivery, .pending)
    }

    /// An id whose rows lie past the byte budget is a scan-limit error, never
    /// "not found".
    func testBudgetExhaustedBeforeTheIdIsAScanLimitError() throws {
        let t = Date().addingTimeInterval(-900)
        let id = newId(t)
        var lines: [String] = []
        let filler = newId(t)
        for index in 0..<2_000 {
            lines.append(line(stdin(filler, .buffered, nil), t.addingTimeInterval(Double(index) * 0.1)))
        }
        lines += dispatched(id, at: t.addingTimeInterval(400))
        try writeLog(lines)
        var limits = MailboxReceiptStatus.Limits()
        limits.maxScanBytes = 64 * 1024
        limits.chunkBytes = 16 * 1024
        XCTAssertThrowsError(try MailboxReceiptStatus.status(id: id, workspacesRoot: workspacesRoot, limits: limits)) {
            XCTAssertEqual($0 as? MailboxReceiptStatus.Failure, .scanLimit(id))
        }
    }

    // MARK: - Writers

    /// The dispatcher and a drain both append to `_dispatch.log`. Neither may
    /// overwrite the other's line.
    func testDispatchLogAppendsKeepADrainsClaimRow() throws {
        let log = MailboxDispatchLog(url: logURL)
        log.append(.received(id: "A", from: "owner", to: "lead", topic: nil))
        log.flush()
        MailboxClaimLog.append(ids: ["B"], recipientPanel: recipient, byPanel: recipient, via: "recv",
                               mailboxesRoot: mailboxes(workspace))
        log.append(.cleaned(id: "A"))
        log.flush()
        let text = try String(contentsOf: logURL, encoding: .utf8)
        let events = text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["received", "claimed", "cleaned"], text)
        let claim = try XCTUnwrap(events.first { $0["event"] as? String == "claimed" })
        XCTAssertEqual(claim["by_panel"] as? String, recipient.uuidString.lowercased())
        XCTAssertEqual(claim["recipient_panel"] as? String, recipient.uuidString.lowercased())
    }

    /// Two writers at once (the dispatcher's queue and drains on other
    /// threads): every row lands whole and none is lost.
    func testConcurrentWritersProduceNoTornRows() throws {
        let log = MailboxDispatchLog(url: logURL)
        let rounds = 400
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for index in 0..<rounds {
                log.append(.handler(id: "D\(index)", recipient: "lead", handler: "stdin", outcome: .buffered,
                                    bytes: nil, elapsedMs: nil, reason: String(repeating: "x", count: 300)))
            }
            log.flush()
        }
        for worker in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for index in 0..<(rounds / 4) {
                    MailboxClaimLog.append(ids: ["C\(worker)-\(index)"], recipientPanel: self.recipient,
                                           byPanel: self.recipient, via: "recv", mailboxesRoot: self.mailboxes(self.workspace))
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        log.flush()
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, rounds * 2)
        let parsed = lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        XCTAssertEqual(parsed.count, lines.count, "a torn or interleaved row did not parse")
        XCTAssertEqual(parsed.filter { $0["event"] as? String == "claimed" }.count, rounds)
        XCTAssertEqual(parsed.filter { $0["event"] as? String == "handler" }.count, rounds)
    }

    /// The claimed row is best effort: an unwritable log neither throws nor
    /// creates anything, so a drain's claim and print are unaffected.
    func testClaimRowWriteFailureIsSilent() {
        let missing = root.appendingPathComponent("no-such-workspace/mailboxes", isDirectory: true)
        MailboxClaimLog.append(ids: [newId(Date())], recipientPanel: recipient, byPanel: recipient,
                               via: "recv", mailboxesRoot: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testCopiedAndHandlerRowsNameTheRecipientPanel() throws {
        let copied = MailboxDispatchLog.serialize(event: .copied(id: "A", recipient: "lead", recipientPanel: recipient), at: Date())
        XCTAssertTrue(copied.contains("\"recipient_panel\":\"\(recipient.uuidString.lowercased())\""), copied)
        let handler = MailboxDispatchLog.serialize(event: stdin("A", .doorbell, "submitted"), at: Date())
        XCTAssertTrue(handler.contains("\"recipient_panel\":\"\(recipient.uuidString.lowercased())\""), handler)
    }

    func testClaimerComesFromThePanelEnvironment() {
        XCTAssertEqual(MailboxClaimLog.callerPanelId(["C11_PANEL_ID": recipient.uuidString]), recipient)
        XCTAssertEqual(MailboxClaimLog.callerPanelId(["CMUX_SURFACE_ID": other.uuidString]), other)
        XCTAssertEqual(MailboxClaimLog.callerPanelId(["C11_TAB_ID": other.uuidString]), other)
        XCTAssertEqual(MailboxClaimLog.callerPanelId(["C11_SURFACE_ID": other.uuidString]), other)
        XCTAssertEqual(MailboxClaimLog.callerPanelId(["CMUX_TAB_ID": other.uuidString]), other)
        XCTAssertNil(MailboxClaimLog.callerPanelId([:]))
    }

    func testULIDTimeRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_793_000_000.123)
        let decoded = try XCTUnwrap(MailboxReceiptStatus.ulidTime(MailboxULID.make(now: at)))
        XCTAssertEqual(decoded.timeIntervalSince1970, 1_793_000_000.123, accuracy: 0.001)
        XCTAssertNil(MailboxReceiptStatus.ulidTime("ZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
    }

    // MARK: - Scenario 4: fleet field

    func testFleetUnreadFieldCarriesCountAndAgeOnly() throws {
        let formatter = ISO8601DateFormatter()
        let now = Date(timeIntervalSince1970: 1_793_000_600)
        let oldest = now.addingTimeInterval(-1_020)
        let field = try XCTUnwrap(FleetSnapshot.unreadField(count: 3, oldestAt: oldest, now: now, formatter: formatter) as? [String: Any])
        XCTAssertEqual(Set(field.keys), ["count", "oldest_at", "oldest_age_seconds"])
        XCTAssertEqual(field["count"] as? Int, 3)
        XCTAssertEqual(field["oldest_age_seconds"] as? Int, 1_020)
        XCTAssertEqual(field["oldest_at"] as? String, formatter.string(from: oldest))

        let empty = try XCTUnwrap(FleetSnapshot.unreadField(count: 0, oldestAt: oldest, now: now, formatter: formatter) as? [String: Any])
        XCTAssertTrue(empty["oldest_age_seconds"] is NSNull)
        XCTAssertTrue(FleetSnapshot.unreadField(count: nil, oldestAt: nil, now: now, formatter: formatter) is NSNull)
    }
}
