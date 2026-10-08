import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxDispatcherTests: XCTestCase {

    private var tempState: URL!
    private var workspaceId: UUID!
    private var dispatcher: MailboxDispatcher?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempState = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-mailbox-dispatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempState, withIntermediateDirectories: true)
        workspaceId = UUID()
        // Tests drive `dispatchOne` directly and skip `start()` to keep the
        // watcher and GC timer out of the way; pre-create the three mailbox
        // dirs that `start()` would have created so the atomic outbox→processing
        // move and quarantine path can find their targets.
        for dir in [
            MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId),
            MailboxLayout.processingURL(state: tempState, workspaceId: workspaceId),
            MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId),
        ] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        // Drain the dispatch log queue so any async `_dispatch.log` writes
        // settle before we remove the tree; the CI runner has raced
        // `removeItem(tempState)` against an in-flight createDirectory and
        // produced NSCocoaError 513 EPERM.
        dispatcher?.log.flush()
        dispatcher = nil
        if let tempState, FileManager.default.fileExists(atPath: tempState.path) {
            try? FileManager.default.removeItem(at: tempState)
        }
        tempState = nil
        try super.tearDownWithError()
    }

    // MARK: - Test helpers

    private func seedSurface(name: String, delivery: String? = nil) -> UUID {
        let surfaceId = UUID()
        var partial: [String: Any] = [MetadataKey.title: name]
        if let delivery {
            partial["mailbox.delivery"] = delivery
        }
        _ = try? PanelMetadataStore.shared.setMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            partial: partial,
            mode: .merge,
            source: .explicit
        )
        return surfaceId
    }

    private func makeDispatcher(surfaces: [UUID]) -> MailboxDispatcher {
        let resolver = MailboxPanelResolver(
            workspaceId: workspaceId,
            livePanels: { surfaces }
        )
        let dispatcher = MailboxDispatcher(
            workspaceId: workspaceId,
            stateURL: tempState,
            resolver: resolver
        )
        self.dispatcher = dispatcher
        return dispatcher
    }

    private func writeEnvelope(_ envelope: MailboxEnvelope) throws {
        let outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
        try FileManager.default.createDirectory(
            at: outbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try envelope.encode()
        let target = outbox.appendingPathComponent(
            MailboxLayout.envelopeFilename(id: envelope.id)
        )
        try MailboxIO.atomicWrite(data: data, to: target)
    }

    private func readInboxFile(panel: UUID, id: String) throws -> Data {
        let inbox = MailboxLayout.inboxURL(
            state: tempState,
            workspaceId: workspaceId,
            panelId: panel
        )
        return try Data(
            contentsOf: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        )
    }

    private func readLog() throws -> [[String: Any]] {
        let logURL = MailboxLayout.dispatchLogURL(state: tempState, workspaceId: workspaceId)
        let text = try String(contentsOf: logURL, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
    }

    // MARK: - Happy path (silent delivery)

    /// Dispatching a `to: watcher` envelope must:
    ///  1. Move the file out of `_outbox/` and (finally) out of `_processing/`.
    ///  2. Copy into `<watcher>/01K.msg` byte-identically to the sender's encoding.
    ///  3. Emit received/resolved/copied/handler/cleaned events.
    ///  4. Call the registered handler with the right recipient tuple.
    func testTextOptOutKeepsDeliveryBodyButSuppressesDurableHistory() throws {
        let instance = "dispatcher-privacy"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: false))
        defer { EventEmitter.shared.resetForTesting() }
        let recipient = seedSurface(name: "privacy-recipient")
        let dispatcher = makeDispatcher(surfaces: [recipient])
        let envelope = try MailboxEnvelope.build(
            from: "sender", to: "privacy-recipient", body: "PRIVATE_DELIVERY_TEXT",
            id: "01K3A2B7X8PQRTVWYZ0123456J", ext: ["custom": "preserved"]
        )
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        dispatcher.log.flush()
        eventLog.flush()
        let delivery = try MailboxEnvelope.validate(data: readInboxFile(panel: recipient, id: envelope.id))
        XCTAssertEqual(delivery.body, envelope.body)
        XCTAssertEqual(delivery.ext?["custom"] as? String, "preserved")
        XCTAssertEqual(delivery.ext?["c11_activity_text_recorded"] as? Bool, false)
        var source = MessagesPageSource.load(stateURL: tempState)
        let accepted = try XCTUnwrap(source.events.first { $0.type == "mailbox.accepted" })
        XCTAssertNil(accepted.payload["body"])
        XCTAssertEqual(accepted.payload["text_recorded"] as? Bool, false)
        XCTAssertEqual(accepted.payload["bytes"] as? Int, envelope.body.utf8.count)
        // Remove only this test's event log to model accepted-event retention.
        try FileManager.default.removeItem(at: eventLog.url)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
        source = MessagesPageSource.load(stateURL: tempState)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        let history = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
        XCTAssertFalse(history.textRecorded)
        XCTAssertTrue(history.body.isEmpty)
        XCTAssertFalse(MessagesPageRenderer.render(snapshot: snapshot).contains(envelope.body))
    }

    func testTextOptOutSurvivesUnresolvedRecipientQuarantineAndLogRetention() throws {
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: "privacy-rejected"), instance: "privacy-rejected")
        EventEmitter.shared.startForTesting(log: eventLog, instance: "privacy-rejected")
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: false))
        defer { EventEmitter.shared.resetForTesting() }
        let dispatcher = makeDispatcher(surfaces: [])
        let envelope = try MailboxEnvelope.build(from: "sender", to: "absent-recipient", body: "PRIVATE_REJECTED_TEXT", id: "01K3A2B7X8PQRTVWYZ0123456K")
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        dispatcher.log.flush()
        eventLog.flush()
        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        let retained = try MailboxEnvelope.validate(data: Data(contentsOf: rejected))
        XCTAssertEqual(retained.body, envelope.body)
        XCTAssertEqual(retained.ext?["c11_activity_text_recorded"] as? Bool, false)
        try FileManager.default.removeItem(at: eventLog.url)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
        let source = MessagesPageSource.load(stateURL: tempState)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        let message = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
        XCTAssertFalse(message.textRecorded)
        XCTAssertTrue(message.body.isEmpty)
        XCTAssertFalse(MessagesPageRenderer.render(snapshot: snapshot).contains(envelope.body))
    }

    func testDispatchesToNamedRecipient() throws {
        let watcher = seedSurface(name: "watcher", delivery: "silent")
        let dispatcher = makeDispatcher(surfaces: [watcher])

        var handlerCallCount = 0
        var seenRecipient: String?
        dispatcher.registerHandler(name: "silent") { _, _, name in
            handlerCallCount += 1
            seenRecipient = name
            return .init(outcome: .ok, bytes: 0)
        }

        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "hello",
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            ts: "2026-04-23T10:15:42Z"
        )
        try writeEnvelope(envelope)

        dispatcher.dispatchOne(
            url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
                .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        )
        dispatcher.log.flush()

        // Inbox contains a byte-identical envelope copy.
        let inboxBytes = try readInboxFile(panel: watcher, id: envelope.id)
        XCTAssertEqual(inboxBytes, try envelope.encode())

        // Outbox and processing are both empty.
        let outboxContents = try FileManager.default.contentsOfDirectory(
            atPath: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId).path
        )
        XCTAssertEqual(outboxContents, [])
        let processingContents = try FileManager.default.contentsOfDirectory(
            atPath: MailboxLayout.processingURL(state: tempState, workspaceId: workspaceId).path
        )
        XCTAssertEqual(processingContents, [])

        // Handler invoked once with the recipient we seeded.
        XCTAssertEqual(handlerCallCount, 1)
        XCTAssertEqual(seenRecipient, "watcher")

        // Dispatch log has the full sequence.
        let events = try readLog().compactMap { $0["event"] as? String }
        XCTAssertEqual(events, ["received", "resolved", "copied", "handler", "cleaned"])
    }

    /// Titles with `/` or past 64 bytes used to be inbox directory names, so
    /// every copy to them failed (`_copy eio`) and the message was lost. The
    /// inbox is keyed on the tab UUID, so such a title receives normally.
    func testRecipientWithSlashedLongTitleGetsInboxCopy() throws {
        let title = "a/b: c " + String(repeating: "x", count: 93)
        XCTAssertEqual(title.utf8.count, 100)
        let recipient = seedSurface(name: title, delivery: "silent")
        let dispatcher = makeDispatcher(surfaces: [recipient])
        dispatcher.registerHandler(name: "silent") { _, _, _ in .init(outcome: .ok) }

        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: title,
            body: "hello",
            id: "01K3A2B7X8PQRTVWYZ0123456Q",
            ts: "2026-04-23T10:15:42Z"
        )
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(
            url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
                .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        )
        dispatcher.log.flush()

        XCTAssertEqual(try readInboxFile(panel: recipient, id: envelope.id), try envelope.encode())
        let log = try readLog()
        XCTAssertEqual(log.compactMap { $0["event"] as? String },
                       ["received", "resolved", "copied", "handler", "cleaned"])
        XCTAssertFalse(log.contains { ($0["handler"] as? String) == "_copy" })
    }

    // MARK: - Validation failures

    func testInvalidEnvelopeQuarantinedToRejected() throws {
        let watcher = seedSurface(name: "watcher", delivery: "silent")
        let dispatcher = makeDispatcher(surfaces: [watcher])
        dispatcher.registerHandler(name: "silent") { _, _, _ in .init(outcome: .ok) }

        // Craft a malformed envelope — version is a string.
        let outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
        try FileManager.default.createDirectory(
            at: outbox,
            withIntermediateDirectories: true
        )
        let badID = "01K3A2B7X8PQRTVWYZ0123456J"
        let bad = Data(#"{"version":"1","id":"\#(badID)","from":"x","ts":"2026-04-23T10:15:42Z","body":"hi","to":"watcher"}"#.utf8)
        let badURL = outbox.appendingPathComponent("\(badID).msg")
        try bad.write(to: badURL)

        dispatcher.dispatchOne(url: badURL)
        dispatcher.log.flush()

        // Rejected dir has the msg + err sidecar.
        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
        let entries = try FileManager.default.contentsOfDirectory(atPath: rejected.path).sorted()
        XCTAssertEqual(entries, ["\(badID).err", "\(badID).msg"])

        // Log event is `rejected`, not `received`.
        let events = try readLog().compactMap { $0["event"] as? String }
        XCTAssertEqual(events, ["rejected"])
    }

    // MARK: - Unknown recipient

    /// A `to`-addressed envelope that resolves to nobody must NOT be silently
    /// cleaned-and-discarded (the cross-workspace silent-drop bug). It is
    /// quarantined like a validation failure: `_rejected/<id>.msg` + a `.err`
    /// sidecar + a `rejected` event, and no handler fires.
    func testUnresolvedRecipientIsRejectedNotSilentlyDropped() throws {
        // No surface named "ghost" — recipient list is empty.
        let builder = seedSurface(name: "builder")
        let dispatcher = makeDispatcher(surfaces: [builder])
        var handlerCalls = 0
        dispatcher.registerHandler(name: "silent") { _, _, _ in
            handlerCalls += 1
            return .init(outcome: .ok)
        }

        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "ghost",
            body: "anyone home?",
            id: "01K3A2B7X8PQRTVWYZ0123456G",
            ts: "2026-04-23T10:15:42Z"
        )
        try writeEnvelope(envelope)

        let outboxPath = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        dispatcher.dispatchOne(url: outboxPath)
        dispatcher.log.flush()

        // No handler fired; nothing was copied to an inbox.
        XCTAssertEqual(handlerCalls, 0)

        // The envelope landed in _rejected/ with a sidecar, not silently gone.
        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
        let entries = try FileManager.default.contentsOfDirectory(atPath: rejected.path).sorted()
        XCTAssertEqual(entries, ["\(envelope.id).err", "\(envelope.id).msg"])
        let reason = try String(
            contentsOf: rejected.appendingPathComponent("\(envelope.id).err"),
            encoding: .utf8
        )
        XCTAssertTrue(reason.contains("ghost"), "rejection reason names the recipient")

        // Outbox and processing are empty; the envelope was moved, not left behind.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId).path
            ),
            []
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: MailboxLayout.processingURL(state: tempState, workspaceId: workspaceId).path
            ),
            []
        )

        // Log sequence ends in `rejected`, with no `cleaned`.
        let events = try readLog().compactMap { $0["event"] as? String }
        XCTAssertEqual(events, ["received", "resolved", "rejected"])
        XCTAssertFalse(events.contains("cleaned"))
        let resolved = try readLog().first { $0["event"] as? String == "resolved" }
        XCTAssertEqual(resolved?["recipients"] as? [String], [])
    }

    // MARK: - Dedupe

    func testSecondDispatchOfSameIdIsNoop() throws {
        let watcher = seedSurface(name: "watcher", delivery: "silent")
        let dispatcher = makeDispatcher(surfaces: [watcher])
        dispatcher.registerHandler(name: "silent") { _, _, _ in .init(outcome: .ok) }

        let envelope = try MailboxEnvelope.build(
            from: "builder",
            to: "watcher",
            body: "once",
            id: "01K3A2B7X8PQRTVWYZ0123456P",
            ts: "2026-04-23T10:15:42Z"
        )
        try writeEnvelope(envelope)

        let outboxURL = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))

        dispatcher.dispatchOne(url: outboxURL)
        // File is gone after first dispatch; second call should no-op because
        // the move fails with ENOENT and id is in the recently-seen set.
        dispatcher.dispatchOne(url: outboxURL)
        dispatcher.log.flush()

        let events = try readLog().compactMap { $0["event"] as? String }
        // Exactly one full dispatch sequence.
        XCTAssertEqual(events, ["received", "resolved", "copied", "handler", "cleaned"])
    }

    // MARK: - C11-144 stdin buffer/flush lifecycle logging

    /// `logStdinLifecycle` is what makes the "never a silent drop" story
    /// observable: blocks buffered while a recipient is busy, then flushed (or
    /// expired/evicted) from the main-actor path, must still surface in
    /// `c11 mailbox trace <id>` as `handler` events keyed on the same
    /// id/recipient. This locks that contract without a live PTY.
    func testLogStdinLifecycleEmitsTraceableHandlerEvents() throws {
        let dispatcher = makeDispatcher(surfaces: [])

        dispatcher.logStdinLifecycle(
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            recipient: "watcher",
            outcome: .flushed,
            bytes: 42
        )
        dispatcher.logStdinLifecycle(
            id: "01K3A2B7X8PQRTVWYZ0123456K",
            recipient: "watcher",
            outcome: .expired
        )
        dispatcher.logStdinLifecycle(
            id: "01K3A2B7X8PQRTVWYZ0123456L",
            recipient: "watcher",
            outcome: .evicted
        )
        dispatcher.log.flush()

        let handlerEvents = try readLog().filter { ($0["event"] as? String) == "handler" }
        XCTAssertEqual(handlerEvents.count, 3)
        for event in handlerEvents {
            XCTAssertEqual(event["handler"] as? String, "stdin")
            XCTAssertEqual(event["recipient"] as? String, "watcher")
        }
        XCTAssertEqual(handlerEvents.map { $0["outcome"] as? String }, ["flushed", "expired", "evicted"])
        // Bytes are carried through when present, omitted otherwise.
        let flushed = handlerEvents.first { ($0["outcome"] as? String) == "flushed" }
        XCTAssertEqual(flushed?["bytes"] as? Int, 42)
        let expired = handlerEvents.first { ($0["outcome"] as? String) == "expired" }
        XCTAssertNil(expired?["bytes"])
    }
}
