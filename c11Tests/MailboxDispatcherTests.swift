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

    func testTextOptOutPersistenceFailureStillDeliversNormalizedEnvelope() throws {
        try assertTextOptOutPersistenceFailure(recipientExists: true)
    }

    func testSenderCannotHideAcceptedDeliveryOrQuarantineWithReservedPrivacyMarker() throws {
        let instance = "privacy-sender-marker"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
        defer { EventEmitter.shared.resetForTesting() }
        let recipient = seedSurface(name: "privacy-recipient")
        var envelopes: [MailboxEnvelope] = []
        for recipientExists in [true, false] {
            let dispatcher = makeDispatcher(surfaces: recipientExists ? [recipient] : [])
            let envelope = try MailboxEnvelope.build(
                from: "sender", to: "privacy-recipient", body: "SENDER_MARKER_CANNOT_HIDE_BODY",
                ext: ["c11_activity_text_recorded": false, "custom": "preserved"]
            )
            try writeEnvelope(envelope)
            dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
                .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
            dispatcher.log.flush()
            let retainedBytes: Data
            if recipientExists {
                retainedBytes = try readInboxFile(panel: recipient, id: envelope.id)
            } else {
                let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
                    .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
                retainedBytes = try Data(contentsOf: rejected)
            }
            let retained = try MailboxEnvelope.validate(data: retainedBytes)
            XCTAssertNil(retained.ext?["c11_activity_text_recorded"])
            XCTAssertEqual(retained.ext?["custom"] as? String, "preserved")
            XCTAssertEqual(retained.body, envelope.body)
            envelopes.append(envelope)
        }
        eventLog.flush()
        try FileManager.default.removeItem(at: eventLog.url)
        let source = MessagesPageSource.load(stateURL: tempState)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        for envelope in envelopes {
            let message = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
            XCTAssertTrue(message.textRecorded)
            XCTAssertEqual(message.body, envelope.body)
        }
    }

    func testLateTextOptOutDeliversEvenIfSecondMarkerWriteFails() throws {
        let instance = "privacy-late-policy"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        defer { EventEmitter.shared.resetForTesting() }
        let recipient = seedSurface(name: "privacy-recipient")
        let resolver = MailboxPanelResolver(workspaceId: workspaceId, livePanels: { [recipient] })
        var envelopes: [MailboxEnvelope] = []
        for secondWriteFails in [false, true] {
            EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
            let envelope = try MailboxEnvelope.build(
                from: "sender", to: "privacy-recipient", body: "PRIVATE_LATE_POLICY_BODY",
                ext: ["c11_activity_text_recorded": false]
            )
            var writes = 0
            let dispatcher = MailboxDispatcher(
                workspaceId: workspaceId, stateURL: tempState, resolver: resolver,
                replaceProcessingEnvelope: { data, url in
                    writes += 1
                    if writes == 2 && secondWriteFails { throw CocoaError(.fileWriteOutOfSpace) }
                    try data.write(to: url, options: .atomic)
                    if writes == 1 {
                        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: false))
                    }
                }
            )
            self.dispatcher = dispatcher
            try writeEnvelope(envelope)
            let filename = MailboxLayout.envelopeFilename(id: envelope.id)
            dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
                .appendingPathComponent(filename))
            dispatcher.log.flush()
            eventLog.flush()
            XCTAssertEqual(writes, 2)
            let processing = MailboxLayout.processingURL(state: tempState, workspaceId: workspaceId)
                .appendingPathComponent(filename)
            XCTAssertFalse(FileManager.default.fileExists(atPath: processing.path))
            let delivery = try MailboxEnvelope.validate(data: readInboxFile(panel: recipient, id: envelope.id))
            XCTAssertEqual(delivery.body, envelope.body)
            XCTAssertEqual(delivery.ext?["c11_activity_text_recorded"] as? Bool, false)
            let accepted = try XCTUnwrap(MessagesPageSource.load(stateURL: tempState).events.first {
                $0.type == "mailbox.accepted" && $0.payload["id"] as? String == envelope.id
            })
            XCTAssertEqual(accepted.payload["text_recorded"] as? Bool, false)
            XCTAssertNil(accepted.payload["body"])
            envelopes.append(envelope)
        }
        try FileManager.default.removeItem(at: eventLog.url)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
        let source = MessagesPageSource.load(stateURL: tempState)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        for envelope in envelopes {
            let message = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
            XCTAssertFalse(message.textRecorded)
            XCTAssertTrue(message.body.isEmpty)
            XCTAssertFalse(MessagesPageRenderer.render(snapshot: snapshot).contains(envelope.body))
        }
    }

    func testTextOptOutPersistenceFailureHoldsUnresolvedEnvelopeWithoutQuarantine() throws {
        try assertTextOptOutPersistenceFailure(recipientExists: false)
    }

    private func assertTextOptOutPersistenceFailure(recipientExists: Bool) throws {
        let instance = "privacy-persistence-failure"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: false))
        defer { EventEmitter.shared.resetForTesting() }
        let recipient = seedSurface(name: "privacy-recipient", delivery: "privacy-test")
        let resolver = MailboxPanelResolver(
            workspaceId: workspaceId,
            livePanels: { recipientExists ? [recipient] : [] }
        )
        let envelope = try MailboxEnvelope.build(
            from: "sender", to: "privacy-recipient", body: "PRIVATE_FAILED_MARKER_BODY"
        )
        let originalBytes = try envelope.encode()
        let filename = MailboxLayout.envelopeFilename(id: envelope.id)
        let outboxURL = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(filename)
        let processingURL = MailboxLayout.processingURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(filename)
        var replacementAttempts = 0
        let dispatcher = MailboxDispatcher(
            workspaceId: workspaceId,
            stateURL: tempState,
            resolver: resolver,
            replaceProcessingEnvelope: { bytes, url in
                replacementAttempts += 1
                XCTAssertEqual(url, processingURL)
                let marked = try MailboxEnvelope.validate(data: bytes)
                XCTAssertEqual(marked.body, envelope.body)
                XCTAssertEqual(marked.ext?["c11_activity_text_recorded"] as? Bool, false)
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        self.dispatcher = dispatcher
        var handlerCalls = 0
        dispatcher.registerHandler(name: "privacy-test") { _, _, _ in
            handlerCalls += 1
            return .init(outcome: .ok)
        }
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: outboxURL)
        // Replayed watcher notifications and a new dispatcher cannot find an
        // outbox file to retry. The original is held solely for recovery.
        dispatcher.dispatchOne(url: outboxURL)
        let restarted = MailboxDispatcher(workspaceId: workspaceId, stateURL: tempState, resolver: resolver)
        restarted.dispatchOne(url: outboxURL)
        dispatcher.log.flush()
        restarted.log.flush()
        eventLog.flush()

        XCTAssertEqual(replacementAttempts, 1)
        XCTAssertEqual(handlerCalls, recipientExists ? 1 : 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxURL.path))
        let rejectedURL = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
        let dispatchEvents = try readLog()
        if recipientExists {
            XCTAssertFalse(FileManager.default.fileExists(atPath: processingURL.path))
            let delivered = try MailboxEnvelope.validate(data: readInboxFile(panel: recipient, id: envelope.id))
            XCTAssertEqual(delivered.body, envelope.body)
            XCTAssertEqual(delivered.ext?["c11_activity_text_recorded"] as? Bool, false)
            XCTAssertFalse(dispatchEvents.contains { $0["event"] as? String == "rejected" })
        } else {
            XCTAssertEqual(try? Data(contentsOf: processingURL), originalBytes)
            XCTAssertNil(try? readInboxFile(panel: recipient, id: envelope.id))
            let reason = dispatchEvents.last?["reason"] as? String ?? ""
            XCTAssertTrue(reason.contains("activity history"))
            XCTAssertTrue(reason.contains("_processing"))
            XCTAssertFalse(reason.contains(envelope.body))
        }

        try FileManager.default.removeItem(at: eventLog.url)
        EventEmitter.shared.updatePolicy(ActivityHistoryPolicy(keepText: true))
        let source = MessagesPageSource.load(stateURL: tempState)
        let snapshot = MessagesPageBuilder.build(events: source.events, mailboxArtifacts: source.mailboxArtifacts)
        let message = try XCTUnwrap(snapshot.messages.first { $0.id == envelope.id })
        XCTAssertFalse(message.textRecorded)
        XCTAssertTrue(message.body.isEmpty)
        XCTAssertNil(message.bodyRef)
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

    // MARK: - C11-381 stdin flush seam

    /// Gate plus claim plus dispatch log, in the order `Workspace.startMailboxPush` uses.
    /// `ownsTerminal` stands in for the kernel check; there is no PTY here.
    private final class StdinSeat: @unchecked Sendable {
        var buffer = MailboxStdinBuffer()
        var ownsTerminal = true
        var lastOperatorKeyAt: Date?
        private(set) var pasted: [String] = []
        let dispatcher: MailboxDispatcher
        let stateURL: URL
        let workspaceId: UUID

        init(dispatcher: MailboxDispatcher, stateURL: URL, workspaceId: UUID) {
            self.dispatcher = dispatcher
            self.stateURL = stateURL
            self.workspaceId = workspaceId
        }

        func inbox(_ surfaceId: UUID) -> URL {
            MailboxLayout.inboxURL(state: stateURL, workspaceId: workspaceId, panelId: surfaceId)
        }

        func beginTurn(surfaceId: UUID, at: Date) {
            buffer.noteAgentTurn(surfaceId: surfaceId, atPrompt: true, at: at)
            buffer.noteSubmit(surfaceId: surfaceId, at: at.addingTimeInterval(1))
        }

        func noteIdle(surfaceId: UUID, at: Date) {
            buffer.noteAgentTurn(surfaceId: surfaceId, atPrompt: true, at: at)
            push(surfaceId: surfaceId, immediateId: nil, typedAt: at.addingTimeInterval(0.2))
        }

        func noteWrapperIdle(surfaceId: UUID, at: Date) {
            buffer.noteAgentProcess(surfaceId: surfaceId, process: .init(pid: 1, startTime: 1))
            ownsTerminal = true
            noteIdle(surfaceId: surfaceId, at: at)
        }

        func admit(
            surfaceId: UUID,
            envelopeId: String,
            recipient: String,
            block: String
        ) -> MailboxDispatcher.HandlerInvocationResult {
            let entry = MailboxStdinBuffer.Entry(
                id: envelopeId,
                recipientName: recipient,
                block: block,
                bufferedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let decision = decide(surfaceId)
            let immediate = decision == .injectNow && buffer.pendingCount(surfaceId: surfaceId) == 0
            _ = buffer.enqueue(surfaceId: surfaceId, entry: entry)
            if decision == .injectNow {
                push(surfaceId: surfaceId, immediateId: immediate ? envelopeId : nil, typedAt: Date(timeIntervalSince1970: 1_700_000_100))
            }
            let outcome: MailboxDispatchLog.HandlerOutcome = immediate ? .ok : .buffered
            return .init(outcome: outcome, bytes: block.utf8.count, elapsedMs: 0)
        }

        private func decide(_ surfaceId: UUID) -> MailboxStdinBuffer.Decision {
            buffer.decide(
                surfaceId: surfaceId,
                isAgentKind: true,
                agentOwnsTerminal: ownsTerminal,
                lastOperatorKeyAt: lastOperatorKeyAt
            )
        }

        private func push(surfaceId: UUID, immediateId: String?, typedAt: Date) {
            guard buffer.pendingCount(surfaceId: surfaceId) > 0,
                  !buffer.isPushInFlight(surfaceId: surfaceId) else { return }
            guard decide(surfaceId) == .injectNow else { return }
            let admitted = buffer.agentTurn(surfaceId: surfaceId)
            let flush = buffer.drainForFlush(surfaceId: surfaceId, now: typedAt, trigger: .agentPrompt)
            buffer.beginPush(surfaceId: surfaceId)
            let inbox = inbox(surfaceId)
            var claimed: [MailboxStdinBuffer.Entry] = []
            for entry in flush.fresh {
                switch MailboxIO.claimResult(id: entry.id, inbox: inbox) {
                case .claimed:
                    claimed.append(entry)
                case .gone:
                    dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .skipped)
                case .failed(let code):
                    dispatcher.logStdinClaimFailed(id: entry.id, recipient: entry.recipientName, errno: code)
                }
            }
            guard !claimed.isEmpty else {
                buffer.endPush(surfaceId: surfaceId, typedAt: nil)
                return
            }
            let verdict = buffer.pushVerdict(
                surfaceId: surfaceId,
                admittedAs: .agentPrompt,
                admittedTurn: admitted,
                lastOperatorKeyAt: lastOperatorKeyAt,
                surfaceAttached: true,
                agentOwnsTerminal: ownsTerminal
            )
            guard verdict == .paste else {
                for entry in claimed {
                    _ = MailboxIO.unclaim(id: entry.id, inbox: inbox)
                }
                if verdict == .requeue {
                    _ = buffer.requeueFront(surfaceId: surfaceId, entries: claimed)
                    for entry in claimed {
                        dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .buffered)
                    }
                }
                buffer.endPush(surfaceId: surfaceId, typedAt: nil)
                return
            }
            pasted.append(MailboxStdinBuffer.joinedBlock(claimed))
            for entry in claimed where entry.id != immediateId {
                dispatcher.logStdinLifecycle(
                    id: entry.id,
                    recipient: entry.recipientName,
                    outcome: .flushed,
                    bytes: entry.block.utf8.count
                )
            }
            buffer.endPush(surfaceId: surfaceId, typedAt: typedAt)
        }
    }

    private func t381(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private func makeStdinSeat() -> (UUID, StdinSeat) {
        let surface = seedSurface(name: "grok-seat", delivery: "stdin")
        let dispatcher = makeDispatcher(surfaces: [surface])
        let seat = StdinSeat(dispatcher: dispatcher, stateURL: tempState, workspaceId: workspaceId)
        dispatcher.registerHandler(name: "stdin") { envelope, surfaceId, name in
            let block = StdinMailboxHandler.formatFramedBlock(envelope: envelope)
            return seat.admit(surfaceId: surfaceId, envelopeId: envelope.id, recipient: name, block: block)
        }
        return (surface, seat)
    }

    private func dispatchToSeat(id: String, body: String) throws {
        let envelope = try MailboxEnvelope.build(
            from: "orch",
            to: "grok-seat",
            body: body,
            id: id,
            ts: "2026-10-09T22:00:00Z"
        )
        try writeEnvelope(envelope)
        let outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        dispatcher?.dispatchOne(url: outbox)
        dispatcher?.log.flush()
    }

    private func handlerOutcomes() throws -> [String] {
        try readLog().compactMap { event in
            guard (event["event"] as? String) == "handler" else { return nil }
            return event["outcome"] as? String
        }
    }

    private func envelopeIsInInboxRoot(surface: UUID, id: String) -> Bool {
        let inbox = MailboxLayout.inboxURL(state: tempState, workspaceId: workspaceId, panelId: surface)
        return FileManager.default.fileExists(
            atPath: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)).path
        )
    }

    private func envelopeIsClaimed(surface: UUID, id: String) -> Bool {
        let inbox = MailboxLayout.inboxURL(state: tempState, workspaceId: workspaceId, panelId: surface)
        let claimed = MailboxLayout.readURL(inbox: inbox)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        return FileManager.default.fileExists(atPath: claimed.path)
    }

    /// Mail admitted while the agent is mid-turn stays in the inbox, then one
    /// idle claims it once and logs `flushed` once. A second idle does not.
    func testBufferedStdinFlushesOnceOnIdle() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456A"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "flush-once")
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertTrue(seat.pasted.isEmpty)

        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered", "flushed"])
        XCTAssertEqual(seat.pasted.count, 1)
        XCTAssertFalse(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertTrue(envelopeIsClaimed(surface: surface, id: id))

        seat.noteIdle(surfaceId: surface, at: t381(30))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered", "flushed"])
        XCTAssertEqual(seat.pasted.count, 1)
    }

    /// A busy turn does not claim. The inbox file stays where a drain can find it.
    func testBusyStdinStaysBuffered() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456B"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "still-busy")
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))
        XCTAssertTrue(seat.pasted.isEmpty)
    }

    /// An idle edge does not type over an operator draft, and does not claim.
    func testDraftIsNotTypedOver() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456C"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "behind-draft")
        seat.lastOperatorKeyAt = t381(5)
        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))
        XCTAssertTrue(seat.pasted.isEmpty)
    }

    /// A drain that claimed the file first wins. The push logs `skipped` and does not paste.
    func testDrainClaimSkipsPush() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456D"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "drain-first")
        let claimed = try XCTUnwrap(try MailboxIO.claim(id: id, inbox: seat.inbox(surface)))
        XCTAssertEqual(claimed.deletingLastPathComponent().lastPathComponent, "_read")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered", "skipped"])
        XCTAssertTrue(seat.pasted.isEmpty)
        XCTAssertTrue(envelopeIsClaimed(surface: surface, id: id))
    }

    /// A transcript idle does not pin a process. The later wrapper idle does, and claims once.
    func testTranscriptIdleThenWrapperIdleClaimsOnce() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456E"
        seat.ownsTerminal = false
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "after-pin")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertNil(seat.buffer.agentProcess(surfaceId: surface))

        seat.noteWrapperIdle(surfaceId: surface, at: t381(21))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered", "flushed"])
        XCTAssertEqual(seat.pasted.count, 1)
        XCTAssertTrue(envelopeIsClaimed(surface: surface, id: id))
        XCTAssertEqual(seat.buffer.agentProcess(surfaceId: surface)?.pid, 1)

        seat.noteWrapperIdle(surfaceId: surface, at: t381(40))
        dispatcher?.log.flush()
        XCTAssertEqual(seat.pasted.count, 1)
        XCTAssertEqual(try handlerOutcomes().filter { $0 == "flushed" }.count, 1)
    }
}
