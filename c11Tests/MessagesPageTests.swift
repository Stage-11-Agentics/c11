import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class LockedMessagesPageSource: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MessagesPageSourceData?

    func store(_ source: MessagesPageSourceData) {
        lock.lock()
        stored = source
        lock.unlock()
    }

    var value: MessagesPageSourceData? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class MessagesPageTests: XCTestCase {
    private let c1Line = #"{"instance":"com.stage11.c11.debug.c11.257.a-81821","payload":{"bytes":18,"caller_tab_id":"32B556C8-A907-4B4E-BC22-5A7ED82DA08C","caller_title":"~","kind":"text","submitted":true,"target_title":"~","text":"C11_257_TEXT_PROOF"},"seq":14,"surface":"92D986CC-57AA-48D2-8FB1-E991E569C144","ts":"2026-10-02T00:32:50.042Z","type":"tab.input_sent","v":1,"workspace":"63916DB4-C544-4057-8755-F290FDCA0B12"}"#
    private let acceptedLine = #"{"instance":"com.stage11.c11.debug.c11.257.a-81821","payload":{"body":"C11_257_MAILBOX_BODY_PROOF","from":"C11-257-Lane-A","id":"01K3A2B7X8PQRTVWYZ0123456J","reply_to":"C11-257-Lane-A","to":"C11-257-Mailbox-Target","topic":"c11_257_lane_a","urgent":true},"seq":22,"ts":"2026-10-02T00:35:58.461Z","type":"mailbox.accepted","v":1,"workspace":"63916DB4-C544-4057-8755-F290FDCA0B12"}"#
    private let deliveredLine = #"{"instance":"com.stage11.c11.debug.c11.257.a-81821","payload":{"id":"01K3A2B7X8PQRTVWYZ0123456J","recipient":"C11-257-Mailbox-Target","via":"inbox"},"seq":23,"surface":"92D986CC-57AA-48D2-8FB1-E991E569C144","ts":"2026-10-02T00:35:58.463Z","type":"mailbox.delivered","v":1,"workspace":"63916DB4-C544-4057-8755-F290FDCA0B12"}"#

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-messages-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func writeSparseFile(
        at url: URL,
        size: UInt64,
        writes: [(offset: UInt64, data: Data)]
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        for write in writes {
            try handle.seek(toOffset: write.offset)
            try handle.write(contentsOf: write.data)
        }
    }

    func testRedactedEventOverridesDurableMailboxBodyAndReference() throws {
        let instance = "privacy-test"
        let log = EventLog(url: EventLogLayout.logURL(state: tempDir, instance: instance), instance: instance)
        log.open()
        log.append(EventEnvelope(type: .panelInputSent, instance: instance, ts: Date(), payload: [
            "text_recorded": false, "bytes": 11, "kind": "text", "submitted": true,
        ]))
        log.append(EventEnvelope(type: .mailboxAccepted, instance: instance, ts: Date(), payload: [
            "id": "01K3A2B7X8PQRTVWYZ0123456J", "from": "sender", "to": "recipient",
            "text_recorded": false, "bytes": 15,
        ]))
        log.flush()
        let envelope = try MailboxEnvelope.build(
            from: "sender", to: "recipient", body: "HIDDEN_MAIL_BODY",
            id: "01K3A2B7X8PQRTVWYZ0123456J"
        )
        let inbox = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: UUID())
            .appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try envelope.encode().write(to: inbox.appendingPathComponent("\(envelope.id).msg"))
        let source = MessagesPageSource.load(stateURL: tempDir)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        XCTAssertEqual(snapshot.messages.count, 2)
        for message in snapshot.messages {
            XCTAssertFalse(message.textRecorded)
            XCTAssertTrue(message.body.isEmpty)
            XCTAssertNil(message.bodyRef)
            XCTAssertNotNil(message.recordedBytes)
            XCTAssertEqual(message.jsonObject["text_recorded"] as? Bool, false)
        }
        let rendered = MessagesPageRenderer.render(snapshot: snapshot)
        XCTAssertFalse(rendered.contains("HIDDEN_MAIL_BODY"))
        XCTAssertTrue(rendered.contains("text not recorded"))
    }

    func testDurableMailboxOptOutSurvivesAcceptedEventRetention() throws {
        let envelope = try MailboxEnvelope.build(
            from: "sender", to: "recipient", body: "DELIVERY_BODY_STAYS_LOCAL",
            id: "01K3A2B7X8PQRTVWYZ0123456K", ext: ["custom": "preserved"]
        ).suppressActivityHistoryText()
        let inbox = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: UUID())
            .appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let bytes = try envelope.encode()
        try bytes.write(to: inbox.appendingPathComponent("\(envelope.id).msg"))
        let delivered = try MailboxEnvelope.validate(data: bytes)
        XCTAssertEqual(delivered.body, "DELIVERY_BODY_STAYS_LOCAL")
        XCTAssertEqual(delivered.ext?["custom"] as? String, "preserved")
        XCTAssertEqual(delivered.ext?["c11_activity_text_recorded"] as? Bool, false)
        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertTrue(source.events.isEmpty)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        let message = try XCTUnwrap(snapshot.messages.first)
        XCTAssertFalse(message.textRecorded)
        XCTAssertEqual(message.recordedBytes, delivered.body.utf8.count)
        XCTAssertTrue(message.body.isEmpty)
        XCTAssertFalse(MessagesPageRenderer.render(snapshot: snapshot).contains(delivered.body))
    }

    func testUnacceptedOutboxAndProcessingHideTextWhileAcceptedInboxHistoryRemainsReadable() throws {
        let root = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: UUID())
        let directories = [
            (MailboxLayout.outboxDirectoryName, "outbox", false),
            (MailboxLayout.processingDirectoryName, "processing", false),
            ("recipient", "pending", true),
            ("_read", "read", true),
            (MailboxLayout.rejectedDirectoryName, "rejected", true),
        ]
        var expected: [(MailboxEnvelope, String, Bool)] = []
        for (directoryName, state, textRecorded) in directories {
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for usesReference in [false, true] {
                let envelope = try MailboxEnvelope.build(
                    from: "sender", to: "recipient",
                    body: usesReference ? "" : "BODY_FOR_\(state)",
                    bodyRef: usesReference ? "/tmp/reference-for-\(state)" : nil
                )
                try envelope.encode().write(to: directory.appendingPathComponent("\(envelope.id).msg"))
                expected.append((envelope, state, textRecorded))
            }
        }
        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertTrue(source.events.isEmpty, "No accepted events are needed to reproduce durable artifact loading")
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        XCTAssertEqual(snapshot.messages.count, expected.count)
        for (envelope, state, textRecorded) in expected {
            let message = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
            XCTAssertEqual(message.status, state)
            XCTAssertEqual(message.textRecorded, textRecorded)
            XCTAssertEqual(message.body, textRecorded ? envelope.body : "")
            XCTAssertEqual(message.bodyRef, textRecorded ? envelope.bodyRef : nil)
            if !textRecorded {
                XCTAssertEqual(message.recordedBytes, envelope.body.utf8.count)
            }
        }
        let rendered = MessagesPageRenderer.render(snapshot: snapshot)
        XCTAssertFalse(rendered.contains("BODY_FOR_outbox"))
        XCTAssertFalse(rendered.contains("BODY_FOR_processing"))
        XCTAssertTrue(rendered.contains("BODY_FOR_pending"))
    }

    func testRejectedInvalidArtifactFollowsCurrentPolicyWithoutAnAcceptanceDecision() throws {
        let log = EventLog(url: EventLogLayout.logURL(state: tempDir, instance: "rejected-policy"), instance: "rejected-policy")
        EventEmitter.shared.startForTesting(log: log, instance: "rejected-policy")
        defer { EventEmitter.shared.resetForTesting() }
        let directory = MailboxLayout.rejectedURL(state: tempDir, workspaceId: UUID())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Deliberately invalid: validation rejects an envelope with no version
        // or routing fields before the dispatcher can accept it.
        let object: [String: Any] = ["id": "invalid-message", "body": "PRIVATE_INVALID_BODY",
                                     "body_ref": "/tmp/private-invalid-reference",
                                     "ext": ["c11_activity_text_recorded": true]]
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("invalid-message.msg"))
        for keepText in [false, true] {
            EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: keepText))
            let source = MessagesPageSource.load(stateURL: tempDir)
            let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
            let message = try XCTUnwrap(snapshot.messages.first { $0.id == "invalid-message" })
            XCTAssertEqual(message.textRecorded, keepText)
            XCTAssertEqual(message.body, keepText ? "PRIVATE_INVALID_BODY" : "")
            XCTAssertEqual(message.bodyRef, keepText ? "/tmp/private-invalid-reference" : nil)
            if !keepText { XCTAssertEqual(message.recordedBytes, "PRIVATE_INVALID_BODY".utf8.count) }
        }
    }

    func testReadsOlderNumberedEventGenerations() throws {
        let directory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try c1Line.write(to: directory.appendingPathComponent("events-history.ndjson.3"), atomically: true, encoding: .utf8)
        try c1Line.write(to: directory.appendingPathComponent("events-history.ndjson.backup"), atomically: true, encoding: .utf8)
        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertEqual(source.events.count, 1)
        let snapshot = MessagesPageBuilder.build(events: source.events)
        XCTAssertEqual(snapshot.messages.first?.body, "C11_257_TEXT_PROOF")
    }

    func testExplicitAcceptedTextDecisionOverridesSenderArtifactOptOut() throws {
        let directory = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: UUID())
            .appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for usesReference in [false, true] {
            let envelope = try MailboxEnvelope.build(
                from: "sender", to: "recipient", body: usesReference ? "" : "ACCEPTED_BODY",
                bodyRef: usesReference ? "/tmp/accepted-reference" : nil,
                ext: ["c11_activity_text_recorded": false]
            )
            try envelope.encode().write(to: directory.appendingPathComponent("\(envelope.id).msg"))
            var payload: [String: Any] = [
                "id": envelope.id, "body": envelope.body, "text_recorded": true,
                "bytes": envelope.body.utf8.count,
            ]
            if let reference = envelope.bodyRef { payload["body_ref"] = reference }
            let event = try XCTUnwrap(MessagesPageEvent(object: [
                "v": 2, "type": "mailbox.accepted", "instance": "accepted-policy",
                "ts": "2026-10-08T00:00:00.000Z", "seq": 1, "payload": payload,
            ]))
            let source = MessagesPageSource.load(stateURL: tempDir)
            let snapshot = MessagesPageBuilder.build(events: [event], mailboxArtifacts: source.mailboxArtifacts)
            let message = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
            XCTAssertTrue(message.textRecorded)
            XCTAssertEqual(message.body, envelope.body)
            XCTAssertEqual(message.bodyRef, envelope.bodyRef)
        }
    }

    func testRotatingGenerationsReuseCachedFileContentsByIdentity() throws {
        let directory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("events-cache.ndjson")
        let first = directory.appendingPathComponent("events-cache.ndjson.1")
        let second = directory.appendingPathComponent("events-cache.ndjson.2")
        try c1Line.write(to: current, atomically: true, encoding: .utf8)
        var cache = MessagesPageEventLogCache()
        var reads = 0
        func load() -> MessagesPageSourceData {
            MessagesPageSource.load(stateURL: tempDir, eventLogCache: &cache, readEventData: { url in
                reads += 1
                return try Data(contentsOf: url)
            })
        }
        XCTAssertEqual(load().events.count, 1)
        XCTAssertEqual(reads, 1)
        try FileManager.default.moveItem(at: current, to: first)
        try acceptedLine.write(to: current, atomically: true, encoding: .utf8)
        XCTAssertEqual(load().events.count, 2)
        XCTAssertEqual(reads, 2, "The renamed first generation must not be read again")
        try FileManager.default.moveItem(at: first, to: second)
        try FileManager.default.moveItem(at: current, to: first)
        try deliveredLine.write(to: current, atomically: true, encoding: .utf8)
        let rotated = load()
        XCTAssertEqual(rotated.events.count, 3)
        XCTAssertEqual(reads, 3, "Only the newly created current file needs a read")
        let snapshot = MessagesPageBuilder.build(events: rotated.events)
        XCTAssertEqual(snapshot.messages.first { $0.channel == "mailbox" }?.status, "delivered")
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(load().events.count, 2, "Pruned file identities must leave the cache")
        XCTAssertEqual(reads, 3)
    }

    func testPinnedC1AndC2FixturesShapeBothChannelsAndLifecycle() throws {
        let events = [c1Line, acceptedLine, deliveredLine].compactMap(MessagesPageEvent.init(line:))
        let snapshot = MessagesPageBuilder.build(
            events: events,
            generatedAt: "2026-10-02T00:36:00.000Z"
        )

        XCTAssertEqual(snapshot.totalObserved, 2)
        let send = try XCTUnwrap(snapshot.messages.first(where: { $0.channel == "send" }))
        XCTAssertEqual(send.body, "C11_257_TEXT_PROOF")
        XCTAssertEqual(send.sender, "~")
        XCTAssertEqual(send.recipient, "~")
        XCTAssertEqual(send.surface, "92D986CC-57AA-48D2-8FB1-E991E569C144")
        XCTAssertEqual(send.kind, "text")
        XCTAssertTrue(send.submitted == true)

        let mailbox = try XCTUnwrap(snapshot.messages.first(where: { $0.channel == "mailbox" }))
        XCTAssertEqual(mailbox.id, "01K3A2B7X8PQRTVWYZ0123456J")
        XCTAssertEqual(mailbox.body, "C11_257_MAILBOX_BODY_PROOF")
        XCTAssertEqual(mailbox.sender, "C11-257-Lane-A")
        XCTAssertEqual(mailbox.recipient, "C11-257-Mailbox-Target")
        XCTAssertEqual(mailbox.topic, "c11_257_lane_a")
        XCTAssertEqual(mailbox.replyTo, "C11-257-Lane-A")
        XCTAssertEqual(mailbox.urgent, true)
        XCTAssertEqual(mailbox.status, "delivered")
        XCTAssertEqual(mailbox.lifecycle.map(\.state), ["accepted", "delivered"])
        XCTAssertEqual(mailbox.lifecycle.last?.detail, "inbox")
    }

    func testQueuedSendPreservesNullCallerTitleAndWireState() throws {
        let event = MessagesPageEvent(object: [
            "instance": "queued",
            "payload": [
                "bytes": 4,
                "caller_tab_id": NSNull(),
                "caller_title": NSNull(),
                "kind": "text",
                "queued": true,
                "submitted": false,
                "target_title": "target",
                "text": "mail",
            ],
            "seq": 9,
            "surface": "surface",
            "ts": "2026-10-02T00:00:00.000Z",
            "type": "tab.input_sent",
            "v": 1,
            "workspace": "workspace",
        ])!
        let snapshot = MessagesPageBuilder.build(events: [event], generatedAt: "now")
        let send = try XCTUnwrap(snapshot.messages.first)

        XCTAssertNil(send.callerTitle)
        XCTAssertEqual(send.sender, "unknown caller")
        XCTAssertFalse(send.submitted ?? true)
        XCTAssertTrue(send.queued == true)
        XCTAssertEqual(send.status, "queued")
        XCTAssertTrue(send.jsonObject["caller_title"] is NSNull)
        XCTAssertTrue(send.jsonObject["caller_panel_id"] is NSNull)
        XCTAssertNil(send.jsonObject["caller_tab_id"], "C11-345: the record writes only caller_panel_id")
        XCTAssertEqual(send.jsonObject["queued"] as? Bool, true)
    }

    func testMailboxFileHistorySuppliesOlderBodyAndDispatchLifecycle() throws {
        let mailboxRoot = tempDir
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("workspace-old", isDirectory: true)
            .appendingPathComponent("mailboxes", isDirectory: true)
        let inbox = mailboxRoot.appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = "01K3A2B7X8PQRTVWYZ0123456K"
        let envelope: [String: Any] = [
            "version": 1,
            "id": id,
            "from": "old-sender",
            "to": "old-recipient",
            "ts": "2026-10-01T23:00:00.000Z",
            "body": "OLDER_BODY_FROM_READ_INBOX",
        ]
        let envelopeURL = inbox.appendingPathComponent("\(id).msg")
        try JSONSerialization.data(withJSONObject: envelope).write(to: envelopeURL)

        let pendingID = "01K3A2B7X8PQRTVWYZ0123456L"
        let pendingInbox = mailboxRoot.appendingPathComponent("recipient", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingInbox, withIntermediateDirectories: true)
        let pendingEnvelope: [String: Any] = [
            "version": 1,
            "id": pendingID,
            "from": "pending-sender",
            "to": "recipient",
            "ts": "2026-10-01T23:01:00.000Z",
            "body": "UNREAD_INBOX_BODY",
        ]
        try JSONSerialization.data(withJSONObject: pendingEnvelope)
            .write(to: pendingInbox.appendingPathComponent("\(pendingID).msg"))

        let rejectedID = "01K3A2B7X8PQRTVWYZ0123456M"
        let rejectedInbox = mailboxRoot.appendingPathComponent(MailboxLayout.rejectedDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: rejectedInbox, withIntermediateDirectories: true)
        let rejectedEnvelope: [String: Any] = [
            "version": 1,
            "id": rejectedID,
            "from": "rejected-sender",
            "to": "missing-recipient",
            "ts": "2026-10-01T23:02:00.000Z",
            "body": "REJECTED_BODY",
        ]
        try JSONSerialization.data(withJSONObject: rejectedEnvelope)
            .write(to: rejectedInbox.appendingPathComponent("\(rejectedID).msg"))

        let dispatchLog = mailboxRoot.appendingPathComponent("_dispatch.log")
        let dispatchLines = [
            #"{"event":"received","from":"old-sender","id":"01K3A2B7X8PQRTVWYZ0123456K","ts":"2026-10-01T23:00:00.100Z"}"#,
            #"{"event":"copied","id":"01K3A2B7X8PQRTVWYZ0123456K","recipient":"old-recipient","ts":"2026-10-01T23:00:00.200Z"}"#,
            #"{"event":"cleaned","id":"01K3A2B7X8PQRTVWYZ0123456K","ts":"2026-10-01T23:00:00.300Z"}"#,
            #"{"event":"rejected","id":"01K3A2B7X8PQRTVWYZ0123456M","reason":"no live recipient","ts":"2026-10-01T23:02:00.100Z"}"#,
        ].joined(separator: "\n") + "\n"
        try dispatchLines.write(to: dispatchLog, atomically: true, encoding: .utf8)

        let source = MessagesPageSource.load(stateURL: tempDir)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        XCTAssertEqual(snapshot.totalObserved, 3)
        let message = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(message.body, "OLDER_BODY_FROM_READ_INBOX")
        XCTAssertEqual(message.status, "read")
        XCTAssertEqual(message.lifecycle.map(\.state), ["received", "copied", "cleaned"])

        let pending = try XCTUnwrap(snapshot.messages.first(where: { $0.id == pendingID }))
        XCTAssertEqual(pending.body, "UNREAD_INBOX_BODY")
        XCTAssertEqual(pending.status, "pending")

        let rejected = try XCTUnwrap(snapshot.messages.first(where: { $0.id == rejectedID }))
        XCTAssertEqual(rejected.body, "REJECTED_BODY")
        XCTAssertEqual(rejected.status, "rejected")
        XCTAssertEqual(rejected.lifecycle.map(\.state), ["rejected"])
    }

    func testOversizedRejectedBodyIsTruncatedAndSkippedWithoutHidingHistory() throws {
        let mailboxRoot = tempDir
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("workspace-oversized", isDirectory: true)
            .appendingPathComponent("mailboxes", isDirectory: true)
        let readInbox = mailboxRoot.appendingPathComponent("_read", isDirectory: true)
        let rejectedInbox = mailboxRoot.appendingPathComponent(
            MailboxLayout.rejectedDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: readInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rejectedInbox, withIntermediateDirectories: true)

        let olderID = "01K3A2B7X8PQRTVWYZ0123456N"
        let olderEnvelope: [String: Any] = [
            "version": 1,
            "id": olderID,
            "from": "history-sender",
            "to": "history-recipient",
            "ts": "2026-10-01T22:00:00.000Z",
            "body": "OLDER_HISTORY_SURVIVES",
        ]
        try JSONSerialization.data(withJSONObject: olderEnvelope)
            .write(to: readInbox.appendingPathComponent("\(olderID).msg"))

        let oversizedID = "01K3A2B7X8PQRTVWYZ0123456P"
        let oversizedEnvelope: [String: Any] = [
            "version": 1,
            "id": oversizedID,
            "from": "rejected-sender",
            "to": "missing-recipient",
            "ts": "2026-10-01T23:00:00.000Z",
            "body": String(repeating: "x", count: 512 * 1024),
        ]
        try JSONSerialization.data(withJSONObject: oversizedEnvelope)
            .write(to: rejectedInbox.appendingPathComponent("\(oversizedID).msg"))

        let source = MessagesPageSource.load(stateURL: tempDir)
        let oversizedArtifact = try XCTUnwrap(
            source.mailboxArtifacts.first(where: { $0.id == oversizedID })
        )
        XCTAssertEqual(oversizedArtifact.body?.utf8.count, 256 * 1024)
        XCTAssertTrue(oversizedArtifact.truncated)

        let snapshot = MessagesPageBuilder.build(
            events: source.events,
            mailboxArtifacts: source.mailboxArtifacts,
            generatedAt: "now",
            messageByteLimit: 200_000
        )
        XCTAssertEqual(snapshot.totalObserved, 2)
        XCTAssertEqual(snapshot.messages.map(\.id), [olderID])
        XCTAssertEqual(snapshot.messages.first?.body, "OLDER_HISTORY_SURVIVES")
        XCTAssertEqual(snapshot.messages.first?.status, "read")
        XCTAssertFalse(snapshot.messages.first?.truncated ?? true)
    }

    func testSparseAndOversizedMailboxArtifactsAreSkippedByLoad() throws {
        let workspaceId = UUID()
        let mailboxRoot = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: workspaceId)
        let blobs = mailboxRoot.appendingPathComponent("blobs", isDirectory: true)
        let rejected = mailboxRoot.appendingPathComponent(MailboxLayout.rejectedDirectoryName, isDirectory: true)
        let read = mailboxRoot.appendingPathComponent("_read", isDirectory: true)
        for directory in [blobs, rejected, read] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let sparseID = "01K3A2B7X8PQRTVWYZ0123456R"
        try writeSparseFile(
            at: blobs.appendingPathComponent("\(sparseID).msg"),
            size: 4 * 1024 * 1024 * 1024,
            writes: []
        )

        let oversizedID = "01K3A2B7X8PQRTVWYZ0123456S"
        let oversized = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "id": oversizedID,
            "from": "rejected-sender",
            "to": "missing-recipient",
            "ts": "2026-10-01T23:00:00.000Z",
            "body": String(repeating: "x", count: MessagesPageSource.maxEnvelopeFileBytes + 1024),
        ])
        XCTAssertGreaterThan(oversized.count, MessagesPageSource.maxEnvelopeFileBytes)
        try oversized.write(to: rejected.appendingPathComponent("\(oversizedID).msg"))

        let siblingID = "01K3A2B7X8PQRTVWYZ0123456T"
        let sibling: [String: Any] = [
            "version": 1,
            "id": siblingID,
            "from": "history-sender",
            "to": "history-recipient",
            "ts": "2026-10-01T22:00:00.000Z",
            "body": "SIBLING_BODY_SURVIVES",
        ]
        try JSONSerialization.data(withJSONObject: sibling)
            .write(to: read.appendingPathComponent("\(siblingID).msg"))

        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertEqual(source.mailboxArtifacts.map(\.id), [siblingID])
        XCTAssertEqual(source.mailboxArtifacts.first?.body, "SIBLING_BODY_SURVIVES")
    }

    func testFifoAndSymlinkMailboxArtifactsDoNotBlockLoad() throws {
        let mailboxRoot = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: UUID())
        let read = mailboxRoot.appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)

        let fifoID = "01K3A2B7X8PQRTVWYZ0123456U"
        let fifo = read.appendingPathComponent("\(fifoID).msg")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let symlinkID = "01K3A2B7X8PQRTVWYZ0123456V"
        let target = tempDir.appendingPathComponent("symlink-target.msg")
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": symlinkID, "from": "sender", "ts": "2026-10-01T22:00:00Z",
            "body": "SYMLINK_BODY_MUST_NOT_LOAD",
        ]).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: read.appendingPathComponent("\(symlinkID).msg"),
            withDestinationURL: target
        )

        let siblingID = "01K3A2B7X8PQRTVWYZ0123456W"
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": siblingID, "from": "sender", "ts": "2026-10-01T22:00:00Z",
            "body": "SIBLING_BODY_SURVIVES",
        ]).write(to: read.appendingPathComponent("\(siblingID).msg"))

        let result = LockedMessagesPageSource()
        let completed = expectation(description: "mailbox load completes without opening the FIFO")
        let stateURL = tempDir!
        DispatchQueue.global(qos: .utility).async {
            result.store(MessagesPageSource.load(stateURL: stateURL))
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
        let source = try XCTUnwrap(result.value)
        XCTAssertEqual(source.mailboxArtifacts.map(\.id), [siblingID])
        XCTAssertEqual(source.mailboxArtifacts.first?.body, "SIBLING_BODY_SURVIVES")
    }

    func testOversizedSparseEventLogIsSkippedWhileSiblingLogParses() throws {
        let events = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)

        let oversized = events.appendingPathComponent("events-oversized.ndjson")
        try writeSparseFile(
            at: oversized,
            size: UInt64(MessagesPageSource.maxEventLogFileBytes + 128),
            writes: [(offset: 0, data: Data((acceptedLine + "\n").utf8))]
        )

        let sibling = events.appendingPathComponent("events-normal.ndjson")
        try Data((deliveredLine + "\n").utf8).write(to: sibling)

        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertEqual(source.events.count, 1)
        XCTAssertEqual(source.events.first?.type, "mailbox.delivered")
    }

    func testDispatchLogTailKeepsNewestLifecycleAndDropsCutPartialLine() throws {
        let mailboxRoot = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: UUID())
        try FileManager.default.createDirectory(at: mailboxRoot, withIntermediateDirectories: true)
        let dispatchLog = mailboxRoot.appendingPathComponent(MailboxLayout.dispatchLogFileName)
        let headID = "old-head-event"
        let tailID = "new-tail-event"

        func line(id: String, event: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "event": event,
                "id": id,
                "ts": "2026-10-01T22:00:00.000Z",
            ])
            data.append(0x0A)
            return data
        }

        let head = try line(id: headID, event: "received")
        let tail = try line(id: tailID, event: "rejected")
        let cap = MessagesPageSource.maxDispatchLogFileBytes
        let startOffset: UInt64 = 1024 * 1024
        let fileSize = UInt64(cap) + startOffset
        let tailOffset = fileSize - UInt64(tail.count)
        try writeSparseFile(
            at: dispatchLog,
            size: fileSize,
            writes: [
                (offset: 0, data: head),
                // The tail starts on the continuation byte of this UTF-8 scalar.
                (offset: startOffset - 1, data: Data([0xE2, 0x82])),
                (offset: tailOffset - 1, data: Data([0x0A])),
                (offset: tailOffset, data: tail),
            ]
        )

        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertFalse(source.mailboxArtifacts.contains { $0.id == headID })
        let tailArtifact = try XCTUnwrap(source.mailboxArtifacts.first { $0.id == tailID })
        XCTAssertEqual(tailArtifact.lifecycle.map(\.state), ["rejected"])
        XCTAssertEqual(tailArtifact.fileState, "rejected")
    }

    func testDispatchLogSkipsInvalidUTF8LineAndKeepsLaterHistory() throws {
        let workspaceId = UUID()
        let mailboxRoot = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: workspaceId)
        let rejected = mailboxRoot.appendingPathComponent(MailboxLayout.rejectedDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)

        let firstID = "01K3A2B7X8PQRTVWYZ0123456A"
        let lastID = "01K3A2B7X8PQRTVWYZ0123456B"
        for id in [firstID, lastID] {
            let envelope = try MailboxEnvelope.build(from: "sender", to: "watcher", body: "", id: id)
            try envelope.encode().write(to: rejected.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
        }

        func line(id: String, event: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["event": event, "id": id, "ts": "t"])
            data.append(0x0A)
            return data
        }
        var log = try line(id: firstID, event: "received")
        log.append(contentsOf: [0x7B, 0xFF, 0x7D, 0x0A]) // invalid UTF-8 on its own line
        log.append(try line(id: lastID, event: "rejected"))
        try log.write(to: mailboxRoot.appendingPathComponent(MailboxLayout.dispatchLogFileName))

        let artifacts = MessagesPageSource.load(stateURL: tempDir).mailboxArtifacts
        XCTAssertEqual(artifacts.first { $0.id == firstID }?.lifecycle.map(\.state), ["received"])
        XCTAssertEqual(artifacts.first { $0.id == lastID }?.lifecycle.map(\.state), ["rejected"])
    }

    func testDispatchLogSkipsManyJunkLinesAndKeepsValidRecord() throws {
        let workspaceId = UUID()
        let mailboxRoot = MailboxLayout.mailboxesRoot(state: tempDir, workspaceId: workspaceId)
        let rejected = mailboxRoot.appendingPathComponent(MailboxLayout.rejectedDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)

        let id = "01K3A2B7X8PQRTVWYZ0123456C"
        let envelope = try MailboxEnvelope.build(from: "sender", to: "watcher", body: "", id: id)
        try envelope.encode().write(to: rejected.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))

        var log = Data(String(repeating: "unstructured noise\n{\"type\":\"noise\"}\n", count: 10_000).utf8)
        var validLine = try JSONSerialization.data(withJSONObject: [
            "event": "rejected",
            "id": id,
            "ts": "t",
        ])
        validLine.append(0x0A)
        log.append(validLine)
        try log.write(to: mailboxRoot.appendingPathComponent(MailboxLayout.dispatchLogFileName))

        let artifacts = MessagesPageSource.load(stateURL: tempDir).mailboxArtifacts
        XCTAssertEqual(artifacts.first { $0.id == id }?.lifecycle.map(\.state), ["rejected"])
    }

    func testMailboxOnlyEventLogIsReadWithoutASeparateSendMarker() throws {
        let eventsDirectory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let noise = #"{"ts":"2026-10-02T00:00:00.000Z","type":"surface.created","v":1}"#
        let log = [noise, acceptedLine, deliveredLine].joined(separator: "\n") + "\n"
        try log.write(
            to: eventsDirectory.appendingPathComponent("events-mailbox-only.ndjson"),
            atomically: true,
            encoding: .utf8
        )

        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertEqual(source.events.count, 2)
        XCTAssertTrue(source.events.allSatisfy { $0.type.hasPrefix("mailbox.") })

        let snapshot = MessagesPageBuilder.build(events: source.events)
        let mailbox = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(mailbox.body, "C11_257_MAILBOX_BODY_PROOF")
        XCTAssertEqual(mailbox.sender, "C11-257-Lane-A")
        XCTAssertEqual(mailbox.recipient, "C11-257-Mailbox-Target")
        XCTAssertEqual(mailbox.status, "delivered")
    }

    func testRendererEscapesAgentTextAndEmbedsNoNetworkPage() throws {
        let malicious = #"</script><script>alert("owned")</script> & <b>text</b>"#
        let payload: [String: Any] = [
            "instance": "fixture",
            "payload": [
                "bytes": malicious.utf8.count,
                "caller_tab_id": NSNull(),
                "caller_title": NSNull(),
                "kind": "text",
                "submitted": true,
                "target_title": "target",
                "text": malicious,
            ],
            "seq": 1,
            "surface": "surface",
            "ts": "2026-10-02T00:00:00.000Z",
            "type": "tab.input_sent",
            "v": 1,
            "workspace": "workspace",
        ]
        let line = String(
            data: try JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        )!
        let snapshot = MessagesPageBuilder.build(
            events: [try XCTUnwrap(MessagesPageEvent(line: line))],
            generatedAt: "2026-10-02T00:00:01.000Z"
        )
        let html = MessagesPageRenderer.render(snapshot: snapshot)

        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("\\u003C"))
        XCTAssertTrue(html.contains("\\u003E"))
        XCTAssertFalse(html.contains("</script><script>alert(\"owned\")"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(html.contains("Date (UTC)"))
        XCTAssertTrue(html.contains("queued at send"))
        XCTAssertTrue(html.contains("body truncated at source"))
        XCTAssertTrue(html.contains("sessionStorage"))
    }

    func testRendererBoundsWorstCaseEscapedBodies() throws {
        let bodySize = 256 * 1024
        let events = (0..<63).map { index in
            let body: String
            switch index % 3 {
            case 0:
                body = String(repeating: "<", count: bodySize)
            case 1:
                body = String(repeating: "&", count: bodySize)
            default:
                body = String(repeating: "</script>", count: bodySize / 8)
            }
            return MessagesPageEvent(object: [
                "instance": "worst-case-escaped-body",
                "payload": [
                    "bytes": body.utf8.count,
                    "caller_tab_id": NSNull(),
                    "caller_title": NSNull(),
                    "kind": "text",
                    "submitted": true,
                    "target_title": "target",
                    "text": body,
                ],
                "seq": index + 1,
                "surface": "surface",
                "ts": "2026-10-02T00:00:00.000Z",
                "type": "tab.input_sent",
                "v": 1,
                "workspace": "workspace",
            ])!
        }

        let snapshot = MessagesPageBuilder.build(events: events, generatedAt: "now")
        let html = MessagesPageRenderer.render(snapshot: snapshot)

        XCTAssertEqual(snapshot.totalObserved, 63)
        XCTAssertLessThan(snapshot.messages.count, snapshot.totalObserved)
        XCTAssertTrue(snapshot.wasBounded)
        XCTAssertTrue(html.contains("\\u003C"))
        XCTAssertTrue(html.contains("\\u0026"))
        XCTAssertLessThanOrEqual(
            Data(html.utf8).count,
            MessagesPageBuilder.defaultMessageByteLimit
        )
    }

    func testSnapshotKeepsNewestRecordsWithinExplicitBound() {
        let events = (0..<7).map { index in
            MessagesPageEvent(object: [
                "instance": "bound",
                "payload": [
                    "bytes": 1,
                    "caller_tab_id": NSNull(),
                    "caller_title": "sender",
                    "kind": "text",
                    "submitted": true,
                    "target_title": "target",
                    "text": "message-\(index)",
                ],
                "seq": index + 1,
                "surface": "surface",
                "ts": "2026-10-02T00:00:0\(index).000Z",
                "type": "tab.input_sent",
                "v": 1,
                "workspace": "workspace",
            ])!
        }
        let snapshot = MessagesPageBuilder.build(
            events: events,
            generatedAt: "now",
            messageLimit: 3
        )

        XCTAssertEqual(snapshot.totalObserved, 7)
        XCTAssertEqual(snapshot.messages.count, 3)
        XCTAssertTrue(snapshot.wasBounded)
        XCTAssertEqual(snapshot.messages.map(\.body), ["message-4", "message-5", "message-6"])
    }

    func testSnapshotAlsoBoundsEmbeddedBodyBytes() {
        let events = (0..<3).map { index in
            MessagesPageEvent(object: [
                "instance": "byte-bound",
                "payload": [
                    "caller_title": "sender",
                    "kind": "text",
                    "submitted": true,
                    "target_title": "target",
                    "text": String(repeating: "x", count: 128),
                ],
                "seq": index + 1,
                "ts": "2026-10-02T00:00:0\(index).000Z",
                "type": "tab.input_sent",
            ])!
        }

        let snapshot = MessagesPageBuilder.build(
            events: events,
            generatedAt: "now",
            messageByteLimit: 10_000
        )
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.messages.first?.body.count, 128)
        XCTAssertEqual(snapshot.messages.first?.sequence, 3)
        XCTAssertTrue(snapshot.wasBounded)
        XCTAssertEqual(snapshot.messageByteLimit, 10_000)
    }

    func testPagePathIsSharedOnlyForProductionBundle() {
        XCTAssertEqual(
            MessagesPageLayout.pageFileName(bundleIdentifier: "com.stage11.c11"),
            "messages.html"
        )
        XCTAssertEqual(
            MessagesPageLayout.pageFileName(bundleIdentifier: "com.stage11.c11.debug.da8"),
            "messages-com.stage11.c11.debug.da8.html"
        )
        let state = URL(fileURLWithPath: "/tmp/c11-messages-state", isDirectory: true)
        XCTAssertTrue(MessagesPageLayout.isMessagesPageURL(
            MessagesPageLayout.pageURL(state: state, bundleIdentifier: "com.stage11.c11.debug.da8")
        ))
        XCTAssertTrue(MessagesPageWriter.isRunningUnderXCTest([
            "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"
        ]))
    }

    func testWriterCreatesOwnerOnlyPageAtomically() throws {
        let eventsDirectory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let logURL = eventsDirectory.appendingPathComponent("events-fixture.ndjson")
        try (c1Line + "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let writer = MessagesPageWriter(
            stateURL: tempDir,
            debounceInterval: 0,
            observeEvents: false,
            label: "com.stage11.c11.messages-page-tests-\(UUID().uuidString)"
        )
        writer.start()
        try writer.rebuildNowForTesting()
        writer.stopForTesting()

        let directory = MessagesPageLayout.directoryURL(state: tempDir)
        let page = MessagesPageLayout.pageURL(state: tempDir)
        let directoryMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        let pageMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: page.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(pageMode & 0o777, 0o600)
        XCTAssertTrue(try String(contentsOf: page, encoding: .utf8).contains("C11_257_TEXT_PROOF"))
    }
}

// MARK: - C11-337: v1 and v2 event lines

extension MessagesPageTests {
    private static let v1SendLine = #"{"instance":"fixture-v1","payload":{"bytes":7,"caller_tab_id":"11111111-1111-4111-8111-111111111111","caller_title":"old-caller","kind":"text","submitted":true,"target_title":"old-target","text":"V1_BODY"},"seq":5,"surface":"22222222-2222-4222-8222-222222222222","ts":"2026-10-01T00:00:00.000Z","type":"tab.input_sent","v":1,"workspace":"44444444-4444-4444-8444-444444444444"}"#
    private static let v2SendLine = #"{"area":"33333333-3333-4333-8333-333333333333","instance":"fixture-v2","panel":"55555555-5555-4555-8555-555555555555","payload":{"bytes":7,"caller_panel_id":"66666666-6666-4666-8666-666666666666","caller_title":null,"kind":"text","submitted":true,"target_title":"new-target","text":"V2_BODY"},"seq":9,"ts":"2026-10-06T00:00:00.000Z","type":"panel.input_sent","v":2,"workspace":"44444444-4444-4444-8444-444444444444"}"#
    private static let v2DeliveredLine = #"{"instance":"fixture-v2","panel":"55555555-5555-4555-8555-555555555555","payload":{"id":"01K3A2B7X8PQRTVWYZ0123456Q","recipient":"new-target","via":"drain"},"seq":10,"ts":"2026-10-06T00:00:01.000Z","type":"mailbox.delivered","v":2,"workspace":"44444444-4444-4444-8444-444444444444"}"#
    private static let v2NoiseLine = #"{"instance":"fixture-v2","panel":"55555555-5555-4555-8555-555555555555","payload":{"kind":"terminal"},"seq":8,"ts":"2026-10-06T00:00:00.000Z","type":"panel.created","v":2}"#

    func testV1AndV2SendLinesBothRenderAsMessages() throws {
        let events = [Self.v1SendLine, Self.v2SendLine].compactMap(MessagesPageEvent.init(line:))
        XCTAssertEqual(events.map(\.type), ["panel.input_sent", "panel.input_sent"])
        let snapshot = MessagesPageBuilder.build(events: events, generatedAt: "now")
        XCTAssertEqual(snapshot.totalObserved, 2)

        let old = try XCTUnwrap(snapshot.messages.first(where: { $0.body == "V1_BODY" }))
        XCTAssertEqual(old.channel, "send")
        XCTAssertEqual(old.senderID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(old.sender, "old-caller")
        XCTAssertEqual(old.surface, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(old.recipient, "old-target")

        let new = try XCTUnwrap(snapshot.messages.first(where: { $0.body == "V2_BODY" }))
        XCTAssertEqual(new.channel, "send")
        XCTAssertEqual(new.senderID, "66666666-6666-4666-8666-666666666666")
        XCTAssertNil(new.callerTitle)
        XCTAssertEqual(new.surface, "55555555-5555-4555-8555-555555555555")
        XCTAssertEqual(new.recipient, "new-target")
        XCTAssertEqual(new.status, "submitted")
    }

    /// The raw-byte prefilter must admit a log that holds only v2 send lines,
    /// and an old log that holds only v1 send lines.
    func testEventLogsWithOnlyV1OrOnlyV2SendLinesAreRead() throws {
        let eventsDirectory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try (Self.v1SendLine + "\n").write(
            to: eventsDirectory.appendingPathComponent("events-old.ndjson"),
            atomically: true,
            encoding: .utf8
        )
        try ([Self.v2NoiseLine, Self.v2SendLine, Self.v2DeliveredLine].joined(separator: "\n") + "\n").write(
            to: eventsDirectory.appendingPathComponent("events-new.ndjson"),
            atomically: true,
            encoding: .utf8
        )

        let source = MessagesPageSource.load(stateURL: tempDir)
        // panel.created is kept for the conversation web's panel history, never as a message.
        XCTAssertEqual(source.events.filter { $0.type != "panel.created" }.count, 3, "two sends and one mailbox event")
        XCTAssertEqual(source.events.filter { $0.type == "panel.created" }.count, 1)

        let snapshot = MessagesPageBuilder.build(events: source.events, generatedAt: "now")
        XCTAssertEqual(Set(snapshot.messages.filter { $0.channel == "send" }.map(\.body)), ["V1_BODY", "V2_BODY"])
        let mailbox = try XCTUnwrap(snapshot.messages.first(where: { $0.channel == "mailbox" }))
        XCTAssertEqual(mailbox.surface, "55555555-5555-4555-8555-555555555555")
        XCTAssertEqual(mailbox.status, "delivered")
    }
}

// MARK: - Conversation web: panel directory, sender stamp, deep links

extension MessagesPageTests {
    private func makeDirectorySession(
        livePanel: UUID,
        liveWorkspace: UUID,
        closedPanel: UUID,
        closedWorkspace: UUID
    ) throws -> Data {
        let panel = SessionPanelSnapshot(
            id: livePanel,
            type: .terminal,
            title: "zsh",
            customTitle: "Fleet Lead",
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: nil,
            markdown: nil,
            metadata: [
                "mailbox.address": .string("fleet-lead"),
                MetadataKey.terminalType: .string("claude-code"),
            ],
            metadataSources: nil
        )
        let workspace = SessionWorkspaceSnapshot(
            id: liveWorkspace,
            processTitle: "zsh",
            customTitle: "Fleet",
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: livePanel,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [livePanel], selectedPanelId: livePanel)),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 0,
            windows: [window]
        )
        // Lineage nodes are added as JSON: this test target compiles its own
        // copy of PanelLineageNode, which is not the app's type.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object["panelLineageNodes"] = [
            [
                "id": livePanel.uuidString, "workspace_id": liveWorkspace.uuidString,
                "workspace_title": "Fleet", "last_title": "Fleet Lead", "panel_type": "terminal",
                "agent_type": "claude-code",
            ],
            [
                "id": closedPanel.uuidString, "parent_panel_id": livePanel.uuidString,
                "workspace_id": closedWorkspace.uuidString, "workspace_title": "Old Run",
                "last_title": "T-7 Owner", "panel_type": "terminal", "agent_type": "codex",
                "closed_at": 1.0,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testDirectoryNamesOpenAndClosedPanelsFromTheSessionFile() throws {
        let live = UUID(), liveWorkspace = UUID(), closed = UUID(), closedWorkspace = UUID()
        let sessionURL = tempDir.appendingPathComponent("session.json")
        try makeDirectorySession(
            livePanel: live, liveWorkspace: liveWorkspace, closedPanel: closed, closedWorkspace: closedWorkspace
        ).write(to: sessionURL)

        let directory = MessagesPageDirectory.load(sessionURL: sessionURL)

        let lead = try XCTUnwrap(directory.panels.first(where: { $0.id == live.uuidString }))
        XCTAssertEqual(lead.title, "Fleet Lead")
        XCTAssertEqual(lead.address, "fleet-lead")
        XCTAssertEqual(lead.agent, "claude-code")
        XCTAssertEqual(lead.workspace, liveWorkspace.uuidString)
        XCTAssertTrue(lead.live)

        let owner = try XCTUnwrap(directory.panels.first(where: { $0.id == closed.uuidString }))
        XCTAssertEqual(owner.title, "T-7 Owner")
        XCTAssertEqual(owner.parent, live.uuidString)
        XCTAssertEqual(owner.workspace, closedWorkspace.uuidString)
        XCTAssertFalse(owner.live)

        XCTAssertEqual(
            directory.workspaces.map { [$0.id, $0.title ?? "", $0.live ? "live" : "closed"] },
            [[liveWorkspace.uuidString, "Fleet", "live"], [closedWorkspace.uuidString, "Old Run", "closed"]]
        )
    }

    func testMissingOrUnreadableSessionFileGivesAnEmptyDirectory() throws {
        XCTAssertEqual(MessagesPageDirectory.load(sessionURL: nil), .empty)
        XCTAssertEqual(MessagesPageDirectory.load(sessionURL: tempDir.appendingPathComponent("absent.json")), .empty)
        let garbage = tempDir.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        XCTAssertEqual(MessagesPageDirectory.load(sessionURL: garbage), .empty)
    }

    func testDispatcherSenderStampNamesTheSendingPanel() throws {
        let inbox = tempDir
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("workspace-stamp", isDirectory: true)
            .appendingPathComponent("mailboxes", isDirectory: true)
            .appendingPathComponent("_read", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let sender = UUID()
        let stamped: [String: Any] = [
            "version": 1, "id": "01K3A2B7X8PQRTVWYZ0123456S", "from": "fleet-lead", "to": "t-7",
            "ts": "2026-10-01T23:00:00.000Z", "body": "STAMPED",
            "ext": [MailboxEnvelope.senderPanelKey: sender.uuidString.lowercased()],
        ]
        let forged: [String: Any] = [
            "version": 1, "id": "01K3A2B7X8PQRTVWYZ0123456T", "from": "fleet-lead", "to": "t-7",
            "ts": "2026-10-01T23:01:00.000Z", "body": "NOT_A_UUID",
            "ext": [MailboxEnvelope.senderPanelKey: "not-a-panel"],
        ]
        for envelope in [stamped, forged] {
            try JSONSerialization.data(withJSONObject: envelope)
                .write(to: inbox.appendingPathComponent("\(envelope["id"]!).msg"))
        }

        let source = MessagesPageSource.load(stateURL: tempDir)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)

        let record = try XCTUnwrap(snapshot.messages.first(where: { $0.body == "STAMPED" }))
        XCTAssertEqual(record.senderID, sender.uuidString)
        XCTAssertEqual(record.jsonObject["sender_id"] as? String, sender.uuidString)
        let unstamped = try XCTUnwrap(snapshot.messages.first(where: { $0.body == "NOT_A_UUID" }))
        XCTAssertNil(unstamped.senderID)
    }

    func testWriterEmbedsTheDirectoryAndTheWebView() throws {
        let live = UUID(), liveWorkspace = UUID()
        let sessionURL = tempDir.appendingPathComponent("session.json")
        try makeDirectorySession(
            livePanel: live, liveWorkspace: liveWorkspace, closedPanel: UUID(), closedWorkspace: UUID()
        ).write(to: sessionURL)
        let eventsDirectory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try (c1Line + "\n").write(
            to: eventsDirectory.appendingPathComponent("events-fixture.ndjson"), atomically: true, encoding: .utf8
        )

        let writer = MessagesPageWriter(
            stateURL: tempDir,
            sessionURL: sessionURL,
            debounceInterval: 0,
            observeEvents: false,
            label: "com.stage11.c11.messages-page-tests-\(UUID().uuidString)"
        )
        writer.start()
        try writer.rebuildNowForTesting()
        writer.stopForTesting()

        let html = try String(contentsOf: MessagesPageLayout.pageURL(state: tempDir), encoding: .utf8)
        XCTAssertTrue(html.contains(#""directory":{"#))
        XCTAssertTrue(html.contains("Fleet Lead"))
        XCTAssertTrue(html.contains("fleet-lead"))
        XCTAssertTrue(html.contains(#"id="cw""#))
        XCTAssertTrue(html.contains(#"data-view="traffic""#))
        // The traffic view stays the page's fallback until the web script runs.
        XCTAssertTrue(html.contains(#"<body class="view-traffic">"#))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
    }

    func testWriterWithAFixedStateDirectoryNeverReadsTheLiveSession() throws {
        let writer = MessagesPageWriter(
            stateURL: tempDir,
            debounceInterval: 0,
            observeEvents: false,
            label: "com.stage11.c11.messages-page-tests-\(UUID().uuidString)"
        )
        writer.start()
        try writer.rebuildNowForTesting()
        writer.stopForTesting()

        let html = try String(contentsOf: MessagesPageLayout.pageURL(state: tempDir), encoding: .utf8)
        XCTAssertTrue(html.contains(#""directory":{"link_scheme":"c11","panels":[],"workspaces":[]}"#))
    }

    func testDeepLinkTargetsThePanelAndStaysTheMessagesPage() throws {
        let panel = try XCTUnwrap(UUID(uuidString: "6E1E3B2A-1111-4222-8333-944455556666"))
        let page = MessagesPageLayout.pageURL(state: tempDir)
        let fragment = MessagesPageWeb.deepLinkFragment(panelID: panel, nonce: 42)
        XCTAssertEqual(fragment, "web:panel=6E1E3B2A-1111-4222-8333-944455556666&n=42")
        let url = MessagesPageWeb.url(page: page, fragment: fragment)
        XCTAssertEqual(url.fragment, fragment)
        XCTAssertEqual(url.standardizedFileURL.path, page.standardizedFileURL.path)
        XCTAssertTrue(MessagesPageLayout.isMessagesPageURL(url))
        XCTAssertEqual(
            MessagesPageWeb.deepLinkFragment(workspaceID: panel),
            "web:workspace=6E1E3B2A-1111-4222-8333-944455556666"
        )
    }
}

// MARK: - Conversation web: live stamps, every recipient, a fresh directory

extension MessagesPageTests {
    private func deliveredLine(id: String, panel: UUID, sender: UUID?, seq: Int) -> String {
        var payload: [String: Any] = ["id": id, "recipient": "role-review", "via": "inbox"]
        if let sender { payload["sender_panel_id"] = sender.uuidString }
        let object: [String: Any] = [
            "instance": "fixture", "payload": payload, "seq": seq, "surface": panel.uuidString,
            "ts": "2026-10-02T00:35:5\(seq % 10).000Z", "type": "mailbox.delivered", "v": 1,
            "workspace": "63916DB4-C544-4057-8755-F290FDCA0B12",
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testDeliveredEventsNameTheSenderPanelAndEveryRecipient() throws {
        let id = "01K3A2B7X8PQRTVWYZ0123456J"
        let sender = UUID(), first = UUID(), second = UUID()
        let lines = [
            acceptedLine,
            deliveredLine(id: id, panel: first, sender: sender, seq: 3),
            deliveredLine(id: id, panel: second, sender: sender, seq: 4),
            // A drain receipt for the first copy repeats its panel and carries no stamp.
            deliveredLine(id: id, panel: first, sender: nil, seq: 5),
        ]
        let snapshot = MessagesPageBuilder.build(events: try lines.map { try XCTUnwrap(MessagesPageEvent(line: $0)) })

        let record = try XCTUnwrap(snapshot.messages.first(where: { $0.id == id }))
        XCTAssertEqual(record.senderID, sender.uuidString)
        XCTAssertEqual(record.recipientPanelIDs, [first.uuidString, second.uuidString])
        XCTAssertEqual(record.jsonObject["recipient_panel_ids"] as? [String], [first.uuidString, second.uuidString])
    }

    func testWriterSeesARenamedPanelAfterTheSessionFileChanges() throws {
        let live = UUID(), liveWorkspace = UUID()
        let sessionURL = tempDir.appendingPathComponent("session.json")
        let original = try makeDirectorySession(
            livePanel: live, liveWorkspace: liveWorkspace, closedPanel: UUID(), closedWorkspace: UUID()
        )
        try original.write(to: sessionURL)
        let writer = MessagesPageWriter(
            stateURL: tempDir,
            sessionURL: sessionURL,
            debounceInterval: 0,
            observeEvents: false,
            label: "com.stage11.c11.messages-page-tests-\(UUID().uuidString)"
        )
        writer.start()
        defer { writer.stopForTesting() }
        try writer.rebuildNowForTesting()
        let page = MessagesPageLayout.pageURL(state: tempDir)
        XCTAssertTrue(try String(contentsOf: page, encoding: .utf8).contains("Fleet Lead"))

        let renamed = String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "Fleet Lead", with: "Fleet Captain, Renamed")
        try Data(renamed.utf8).write(to: sessionURL)
        try writer.rebuildNowForTesting()

        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("Fleet Captain, Renamed"))
        XCTAssertFalse(html.contains("Fleet Lead"))
    }

    func testDirectoryKeepsOpenAndReferencedPanelsAndTheirAncestors() {
        func panel(_ id: String, live: Bool, address: String? = nil, parent: String? = nil) -> MessagesPageDirectory.Panel {
            .init(id: id, title: id, workspace: "W-\(id)", live: live, type: "terminal", agent: nil, address: address, parent: parent)
        }
        let grandparent = UUID().uuidString, parent = UUID().uuidString, referenced = UUID().uuidString
        let open = UUID().uuidString, addressed = UUID().uuidString, forgotten = UUID().uuidString
        let directory = MessagesPageDirectory(
            panels: [
                panel(grandparent, live: false),
                panel(parent, live: false, parent: grandparent),
                panel(referenced, live: false, parent: parent),
                panel(open, live: true),
                panel(addressed, live: false, address: "lead"),
                panel(forgotten, live: false),
            ],
            workspaces: [.init(id: "W-\(forgotten)", title: "gone", live: false), .init(id: "W-\(open)", title: "here", live: true)]
        )
        let message = MessagesPageRecord(
            id: "m", channel: "mailbox", timestamp: "2026-10-02T00:00:00.000Z", sequence: nil, workspace: nil,
            surface: referenced.lowercased(), sender: "lead", senderID: nil, callerTitle: nil, recipient: "x",
            targetTitle: nil, kind: nil, topic: nil, body: "", bodyRef: nil, replyTo: nil, inReplyTo: nil,
            urgent: nil, submitted: nil, queued: nil, truncated: false, status: "delivered", lifecycle: []
        )

        let kept = directory.relevant(to: [message])

        // A closed panel with only a remembered address is dropped: senders are
        // matched by address against open panels alone.
        XCTAssertEqual(Set(kept.panels.map(\.id)), [grandparent, parent, referenced, open])
        XCTAssertEqual(kept.workspaces.map(\.title), ["here"])
    }
}

// MARK: - Conversation web: live overlay, id: addresses, inbox recipients

extension MessagesPageTests {
    private func directoryPanel(_ id: String, title: String?, live: Bool, address: String? = nil) -> MessagesPageDirectory.Panel {
        .init(id: id, title: title, workspace: "W", live: live, type: "terminal", agent: "codex", address: address, parent: nil)
    }

    func testLiveOverlayRenamesClosesAndAddsPanels() {
        let renamed = UUID().uuidString, gone = UUID().uuidString, new = UUID().uuidString
        let saved = MessagesPageDirectory(
            panels: [directoryPanel(renamed, title: "~", live: true), directoryPanel(gone, title: "Old", live: true)],
            workspaces: [.init(id: "W", title: "Fleet", live: true)]
        )
        let merged = saved.overlaying(live: [
            directoryPanel(renamed, title: "Beta", live: true, address: "beta"),
            .init(id: new, title: "Fresh", workspace: "W2", live: true, type: nil, agent: nil, address: nil, parent: nil),
        ])
        let byID = Dictionary(uniqueKeysWithValues: merged.panels.map { ($0.id, $0) })
        XCTAssertEqual(byID[renamed]?.title, "Beta")
        XCTAssertEqual(byID[renamed]?.address, "beta")
        XCTAssertEqual(byID[renamed]?.agent, "codex", "facts the overlay lacks are kept")
        XCTAssertEqual(byID[gone]?.live, false)
        XCTAssertEqual(byID[new]?.title, "Fresh")
        XCTAssertEqual(merged.workspaces.map(\.id), ["W", "W2"])
    }

    func testDirectoryKeepsAClosedPanelNamedOnlyByAnIdAddress() {
        let closed = UUID()
        let directory = MessagesPageDirectory(
            panels: [directoryPanel(closed.uuidString, title: "Closed Owner", live: false)],
            workspaces: []
        )
        let rejected = MessagesPageRecord(
            id: "r", channel: "mailbox", timestamp: "2026-10-02T00:00:00.000Z", sequence: nil, workspace: nil,
            surface: nil, sender: "lead", senderID: nil, callerTitle: nil, recipient: "id:\(closed.uuidString.lowercased())",
            targetTitle: nil, kind: nil, topic: nil, body: "", bodyRef: nil, replyTo: nil, inReplyTo: nil,
            urgent: nil, submitted: nil, queued: nil, truncated: false, status: "rejected", lifecycle: []
        )
        XCTAssertEqual(directory.relevant(to: [rejected]).panels.map(\.title), ["Closed Owner"])
    }

    func testInboxCopiesNameEveryRecipientPanel() throws {
        let mailboxes = tempDir
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("mailboxes", isDirectory: true)
        let one = UUID(), two = UUID()
        let envelope: [String: Any] = [
            "version": 1, "id": "01K3A2B7X8PQRTVWYZ0123456W", "from": "lead", "to": "reviewers",
            "ts": "2026-10-01T23:00:00.000Z", "body": "BROADCAST",
        ]
        for (panel, folder) in [(one, ""), (two, "_read")] {
            var inbox = mailboxes.appendingPathComponent(panel.uuidString.lowercased(), isDirectory: true)
            if !folder.isEmpty { inbox = inbox.appendingPathComponent(folder, isDirectory: true) }
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: envelope)
                .write(to: inbox.appendingPathComponent("01K3A2B7X8PQRTVWYZ0123456W.msg"))
        }

        let source = MessagesPageSource.load(stateURL: tempDir)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)

        let record = try XCTUnwrap(snapshot.messages.first(where: { $0.body == "BROADCAST" }))
        XCTAssertEqual(Set(record.recipientPanelIDs), [one.uuidString, two.uuidString])
    }

    func testFreshPageUsesLivePanelsUntilTheSessionFileCatchesUp() throws {
        let live = UUID(), liveWorkspace = UUID()
        let sessionURL = tempDir.appendingPathComponent("session.json")
        let saved = try makeDirectorySession(
            livePanel: live, liveWorkspace: liveWorkspace, closedPanel: UUID(), closedWorkspace: UUID()
        )
        try saved.write(to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: sessionURL.path
        )
        let writer = MessagesPageWriter(
            stateURL: tempDir,
            sessionURL: sessionURL,
            debounceInterval: 0,
            observeEvents: false,
            allowStartUnderXCTest: true,
            label: "com.stage11.c11.messages-page-tests-\(UUID().uuidString)"
        )
        writer.start()
        defer { writer.stopForTesting() }
        let page = MessagesPageLayout.pageURL(state: tempDir)
        let done = expectation(description: "fresh page")
        writer.ensureFreshPage(livePanels: [
            .init(id: live.uuidString, title: "Renamed Live", workspace: liveWorkspace.uuidString,
                  live: true, type: nil, agent: nil, address: "fleet-lead", parent: nil),
        ]) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(try String(contentsOf: page, encoding: .utf8).contains("Renamed Live"))

        // A later rebuild before the session is saved keeps the live name...
        try writer.rebuildNowForTesting()
        XCTAssertTrue(try String(contentsOf: page, encoding: .utf8).contains("Renamed Live"))

        // ...and once the session file is newer, it is the source again.
        let resaved = String(decoding: saved, as: UTF8.self).replacingOccurrences(of: "Fleet Lead", with: "Saved Name")
        try Data(resaved.utf8).write(to: sessionURL)
        try writer.rebuildNowForTesting()
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("Saved Name"))
        XCTAssertFalse(html.contains("Renamed Live"))
    }
}

// MARK: - Conversation web: names and subtitles from the event log

extension MessagesPageTests {
    private func historyEvent(_ type: String, panel: UUID?, workspace: String, ts: String, payload: [String: Any]) throws -> MessagesPageEvent {
        var object: [String: Any] = ["v": 2, "type": type, "instance": "fixture", "ts": ts, "workspace": workspace, "payload": payload]
        if let panel { object["panel"] = panel.uuidString }
        return try XCTUnwrap(MessagesPageEvent(object: object))
    }

    func testEventLogNamesAClosedPanelTheSessionForgot() throws {
        let closed = UUID(), live = UUID(), workspace = UUID().uuidString
        let events = [
            try historyEvent("workspace.created", panel: nil, workspace: workspace, ts: "2026-11-01T10:00:00.000Z", payload: ["title": "Fleet"]),
            try historyEvent("panel.created", panel: closed, workspace: workspace, ts: "2026-11-01T10:00:01.000Z",
                             payload: ["kind": "terminal", "title": "Terminal", "parent_panel_id": live.uuidString]),
            try historyEvent("metadata.changed", panel: closed, workspace: workspace, ts: "2026-11-01T10:00:02.000Z",
                             payload: ["scope": "panel", "key": "title", "source": "osc", "value": "bash /tmp/run.sh"]),
            try historyEvent("metadata.changed", panel: closed, workspace: workspace, ts: "2026-11-01T10:00:03.000Z",
                             payload: ["scope": "panel", "key": "title", "source": "explicit", "value": "Review Owner"]),
            try historyEvent("metadata.changed", panel: closed, workspace: workspace, ts: "2026-11-01T10:00:04.000Z",
                             payload: ["scope": "panel", "key": "description", "source": "explicit", "value": "Auditing retries"]),
            try historyEvent("metadata.changed", panel: closed, workspace: workspace, ts: "2026-11-01T10:00:05.000Z",
                             payload: ["scope": "panel", "key": "description", "source": "explicit", "value": "Done: PR 12 merged"]),
            try historyEvent("panel.closed", panel: closed, workspace: workspace, ts: "2026-11-01T10:00:06.000Z", payload: [:]),
            try historyEvent("metadata.changed", panel: live, workspace: workspace, ts: "2026-11-01T10:00:07.000Z",
                             payload: ["scope": "panel", "key": "description", "source": "explicit", "value": "Leading the fleet"]),
        ]
        let history = MessagesPagePanelHistory.build(events: events.reversed())
        let directory = MessagesPageDirectory(
            panels: [.init(id: live.uuidString, title: "Fleet Lead", workspace: workspace, live: true, type: "terminal",
                           agent: nil, address: nil, parent: nil)],
            workspaces: []
        ).adding(history: history)

        let byID = Dictionary(uniqueKeysWithValues: directory.panels.map { ($0.id, $0) })
        let gone = try XCTUnwrap(byID[closed.uuidString])
        XCTAssertEqual(gone.title, "Review Owner", "the chosen title, never the command the terminal ran")
        XCTAssertEqual(gone.description, "Done: PR 12 merged")
        XCTAssertEqual(gone.notes.map(\.text), ["Auditing retries", "Done: PR 12 merged"])
        XCTAssertEqual(gone.closed, "2026-11-01T10:00:06.000Z")
        XCTAssertEqual(gone.parent, live.uuidString)
        XCTAssertFalse(gone.live)
        XCTAssertEqual(byID[live.uuidString]?.title, "Fleet Lead", "what the session says wins")
        XCTAssertEqual(byID[live.uuidString]?.notes.map(\.text), ["Leading the fleet"])
        XCTAssertNil(byID[live.uuidString]?.description, "a live panel's subtitle is the session's, never an old note")
        XCTAssertEqual(directory.workspaces.first(where: { $0.id == workspace })?.title, "Fleet")
        XCTAssertEqual(gone.jsonObject["notes"] as? [[String: String]], [
            ["at": "2026-11-01T10:00:04.000Z", "text": "Auditing retries"],
            ["at": "2026-11-01T10:00:05.000Z", "text": "Done: PR 12 merged"],
        ])
    }

    func testEventLogWithOnlyPanelHistoryIsRead() throws {
        let panel = UUID()
        let directory = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = #"{"instance":"fixture","panel":"\#(panel.uuidString)","payload":{"key":"title","prior":"~","scope":"panel","source":"explicit","value":"Named From Log"},"seq":3,"ts":"2026-11-01T10:00:00.000Z","type":"metadata.changed","v":2,"workspace":"63916DB4-C544-4057-8755-F290FDCA0B12"}"#
        let unrelated = #"{"instance":"fixture","panel":"\#(panel.uuidString)","payload":{"key":"activity","scope":"panel","source":"explicit","value":"working"},"seq":4,"ts":"2026-11-01T10:00:01.000Z","type":"metadata.changed","v":2,"workspace":"63916DB4-C544-4057-8755-F290FDCA0B12"}"#
        try [line, unrelated].joined(separator: "\n").write(to: directory.appendingPathComponent("events-history.ndjson"), atomically: true, encoding: .utf8)

        let source = MessagesPageSource.load(stateURL: tempDir)
        XCTAssertEqual(source.events.count, 1, "only the title change is kept")
        XCTAssertTrue(MessagesPageBuilder.build(events: source.events).messages.isEmpty, "history is not a message")
        XCTAssertEqual(MessagesPagePanelHistory.build(events: source.events).panels[panel.uuidString]?.title, "Named From Log")
    }
}
