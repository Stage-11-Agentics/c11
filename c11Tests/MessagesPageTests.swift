import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

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
        XCTAssertTrue(send.jsonObject["caller_tab_id"] is NSNull)
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
            "body": String(repeating: "x", count: 2 * 1024 * 1024),
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
        XCTAssertEqual(source.events.count, 3, "two sends and one mailbox event; panel.created is not a message")
        XCTAssertFalse(source.events.contains { $0.type == "panel.created" })

        let snapshot = MessagesPageBuilder.build(events: source.events, generatedAt: "now")
        XCTAssertEqual(Set(snapshot.messages.filter { $0.channel == "send" }.map(\.body)), ["V1_BODY", "V2_BODY"])
        let mailbox = try XCTUnwrap(snapshot.messages.first(where: { $0.channel == "mailbox" }))
        XCTAssertEqual(mailbox.surface, "55555555-5555-4555-8555-555555555555")
        XCTAssertEqual(mailbox.status, "delivered")
    }
}
