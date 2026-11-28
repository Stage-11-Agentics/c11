import XCTest
import Darwin

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

    func testDuplicateMailboxRoutesToOwnerAcrossWorkspacesAndLogsBothAddresses() throws {
        let alias = seedSurface(name: "duplicate", delivery: "stdin")
        let owner = UUID(), ownerWorkspace = UUID()
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: ownerWorkspace, surfaceId: owner,
            partial: [MetadataKey.title: "owner", "mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let resolver = MailboxPanelResolver(workspaceId: workspaceId,
            canonicalOwner: { $0 == alias ? (owner, ownerWorkspace) : nil }, livePanels: { [alias] })
        let dispatcher = MailboxDispatcher(workspaceId: workspaceId, stateURL: tempState, resolver: resolver)
        self.dispatcher = dispatcher
        let delivered = expectation(description: "owner handler")
        dispatcher.registerHandler(name: "stdin") { _, panel, _ in
            XCTAssertEqual(panel, owner)
            delivered.fulfill()
            return .init(outcome: .ok)
        }
        let envelope = try MailboxEnvelope.build(from: "sender", to: "duplicate", body: "shared inbox")
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        wait(for: [delivered], timeout: 3)
        let ownerFile = MailboxLayout.inboxURL(state: tempState, workspaceId: ownerWorkspace, panelId: owner)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        XCTAssertEqual(try MailboxEnvelope.validate(data: Data(contentsOf: ownerFile)).body, "shared inbox")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MailboxLayout.inboxURL(
            state: tempState, workspaceId: workspaceId, panelId: alias).path))
        dispatcher.log.flush()
        let log = try String(contentsOf: dispatcher.log.url, encoding: .utf8)
        XCTAssertTrue(log.contains("requested_recipient"))
        XCTAssertTrue(log.contains("duplicate"))
        XCTAssertTrue(log.contains(owner.uuidString))

        // Receipt status follows the canonical inbox across workspaces, even
        // though dispatch and claim rows live in different workspace logs.
        let workspaces = tempState.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        var status = try MailboxReceiptStatus.status(id: envelope.id, workspacesRoot: workspaces)
        XCTAssertEqual(try XCTUnwrap(status.recipients.first).read, .unread)
        let inbox = ownerFile.deletingLastPathComponent()
        let drained = MailboxDrain.claimPending(inbox: inbox)
        XCTAssertEqual(drained.claimed.map(\.id), [envelope.id])
        MailboxClaimLog.append(ids: drained.claimed.map(\.id), recipientPanel: owner, byPanel: owner,
                               via: "recv", mailboxesRoot: inbox.deletingLastPathComponent())
        status = try MailboxReceiptStatus.status(id: envelope.id, workspacesRoot: workspaces)
        let receipt = try XCTUnwrap(status.recipients.first)
        XCTAssertEqual(receipt.panelId, owner)
        XCTAssertEqual(receipt.read, .read)
        XCTAssertEqual(receipt.claimedBy, owner)
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

    // MARK: - C11H-360: linked-machine panels never take a local panel's name

    private func dispatchRelayRouting(to: String, local: [UUID], linked: [UUID: String],
                                      localAnswersAnywhere: Bool = false) throws -> Set<UUID> {
        let resolver = MailboxPanelResolver(workspaceId: workspaceId, linkedMachines: { linked },
                                            localAnswersAnywhere: { _ in localAnswersAnywhere },
                                            livePanels: { local + Array(linked.keys) })
        let dispatcher = MailboxDispatcher(workspaceId: workspaceId, stateURL: tempState, resolver: resolver)
        self.dispatcher = dispatcher
        let envelope = try MailboxEnvelope.build(from: "sender", to: to, body: "for \(to)")
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        dispatcher.log.flush()
        return Set((local + Array(linked.keys)).filter { (try? readInboxFile(panel: $0, id: envelope.id)) != nil })
    }

    private func seedLinked(title: String, source: MetadataSource = .explicit, address: String? = nil) -> UUID {
        let surfaceId = UUID()
        var partial: [String: Any] = [MetadataKey.title: title]
        if let address { partial["mailbox.address"] = address }
        _ = try? PanelMetadataStore.shared.setMetadata(workspaceId: workspaceId, surfaceId: surfaceId,
                                                       partial: partial, mode: .merge, source: source)
        return surfaceId
    }

    func testLinkedPanelNeverTakesALocalPanelsName() throws {
        let local = seedSurface(name: "watcher-360")
        let byTitle = seedLinked(title: "watcher-360")
        XCTAssertEqual(try dispatchRelayRouting(to: "watcher-360", local: [local], linked: [byTitle: "studio"]), [local])
        // Even an address on the linked panel loses to a local title.
        let byAddress = seedLinked(title: "other", address: "watcher-360")
        XCTAssertEqual(try dispatchRelayRouting(to: "watcher-360", local: [local], linked: [byAddress: "studio"]), [local])
    }

    func testLinkedPanelLosesToALocalPanelInAnotherWorkspace() throws {
        let linked = seedLinked(title: "reviewer-360")
        XCTAssertEqual(try dispatchRelayRouting(to: "reviewer-360", local: [], linked: [linked: "studio"],
                                                localAnswersAnywhere: true), [])
        // Alone with the name, a linked panel is still reachable.
        XCTAssertEqual(try dispatchRelayRouting(to: "reviewer-360", local: [], linked: [linked: "studio"]), [linked])
        XCTAssertEqual(try dispatchRelayRouting(to: "id:\(linked.uuidString)", local: [], linked: [linked: "studio"],
                                                localAnswersAnywhere: true), [linked])
    }

    /// C11H-360 (L7): the accepted event names the machine relayed mail came
    /// from, so history keeps it with no envelope copy left; local mail's
    /// event carries no such field.
    func testAcceptedEventCarriesTheRelayMachine() throws {
        let instance = "dispatcher-relay-origin"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        defer { EventEmitter.shared.resetForTesting() }
        let recipient = seedSurface(name: "origin-recipient")
        let dispatcher = makeDispatcher(surfaces: [recipient])
        let local = try MailboxEnvelope.build(from: "reviewer", to: "origin-recipient", body: "local words")
        let relayed = try MailboxEnvelope.build(from: "reviewer", to: "origin-recipient", body: "remote words")
            .relayed(originHost: "demo-mac-studio", machine: "studio", id: MailboxULID.make())
        for envelope in [local, relayed] {
            try writeEnvelope(envelope)
            dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
                .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        }
        dispatcher.log.flush()
        eventLog.flush()
        let accepted = MessagesPageSource.load(stateURL: tempState).events.filter { $0.type == "mailbox.accepted" }
        let byId = Dictionary(accepted.compactMap { event in (event.payload["id"] as? String).map { ($0, event) } },
                              uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byId[relayed.id]?.payload["relay_machine"] as? String, "studio")
        XCTAssertNotNil(byId[local.id])
        XCTAssertNil(byId[local.id]?.payload["relay_machine"])
    }

    func testLinkedPanelsTerminalTitleIsNotAMailName() throws {
        let osc = seedLinked(title: "builder-360", source: .osc)
        XCTAssertEqual(try dispatchRelayRouting(to: "builder-360", local: [], linked: [osc: "studio"]), [])
        // A local panel's terminal title still is.
        let localOSC = seedLinked(title: "builder-360", source: .osc)
        XCTAssertEqual(try dispatchRelayRouting(to: "builder-360", local: [localOSC], linked: [:]), [localOSC])
    }

    private func makeDispatcher(surfaces: [UUID],
                                detectedKinds: @escaping () -> [UUID: String] = { [:] }) -> MailboxDispatcher {
        let resolver = MailboxPanelResolver(
            workspaceId: workspaceId,
            detectedKinds: detectedKinds,
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

    // MARK: - Sender stamp and Sent ledger (C11-399)

    private func dispatch(_ envelope: MailboxEnvelope, with dispatcher: MailboxDispatcher) throws {
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        dispatcher.log.flush()
    }

    private func senderInbox(_ panel: UUID) -> URL {
        MailboxLayout.inboxURL(state: tempState, workspaceId: workspaceId, panelId: panel)
    }

    private func claim(_ panel: UUID, workspace: UUID? = nil) -> [String: Any] {
        MailboxEnvelope.senderClaim(panel: panel, workspace: workspace ?? workspaceId)
    }

    private func setAddress(_ address: String, on panel: UUID) {
        _ = try? PanelMetadataStore.shared.setMetadata(
            workspaceId: workspaceId, surfaceId: panel,
            partial: [MetadataKey.mailboxAddress: address], mode: .merge, source: .explicit
        )
    }

    func testAcceptedEnvelopeIsStampedWithItsSendingPanelAndLedgered() throws {
        let sender = seedSurface(name: "stamp-sender")
        let one = seedSurface(name: "stamp-one")
        let two = seedSurface(name: "stamp-two")
        let dispatcher = makeDispatcher(surfaces: [sender, one, two])
        var ids: [String] = []
        for target in ["stamp-one", "stamp-two"] {
            let envelope = try MailboxEnvelope.build(
                from: "stamp-sender", to: target, topic: "stamp.t", body: "hi " + target, ext: claim(sender)
            )
            try dispatch(envelope, with: dispatcher)
            ids.append(envelope.id)
        }
        for (panel, id) in zip([one, two], ids) {
            let copy = try MailboxEnvelope.validate(data: try readInboxFile(panel: panel, id: id))
            XCTAssertEqual(copy.senderPanelId, sender)
            // The claim is consumed: recipients see only the stamp.
            XCTAssertNil(copy.ext?[MailboxEnvelope.senderClaimKey])
        }
        let listed = MailboxSentLedger.entries(senderInbox: senderInbox(sender), limit: 10)
        XCTAssertEqual(listed.total, 2)
        XCTAssertEqual(Set(listed.entries.map(\.id)), Set(ids))
        let byId = Dictionary(uniqueKeysWithValues: listed.entries.map { ($0.id, $0) })
        XCTAssertEqual(byId[ids[0]]?.recipients, [.init(panel: one.uuidString.lowercased(), name: "stamp-one")])
        XCTAssertEqual(byId[ids[1]]?.recipients, [.init(panel: two.uuidString.lowercased(), name: "stamp-two")])
        XCTAssertEqual(byId[ids[0]]?.topic, "stamp.t")
        // The ledger lives in the sender's directory, not the recipients'.
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(one), limit: 10).total, 0)
    }

    func testNoClaimOrAForeignOrClosedClaimIsNotStampedOrLedgered() throws {
        let panel = seedSurface(name: "claimless")
        let recipient = seedSurface(name: "stamp-recipient")
        let dispatcher = makeDispatcher(surfaces: [panel, recipient])
        let cases: [(String, [String: Any]?)] = [
            ("no claim", nil),
            ("claim from another workspace", claim(panel, workspace: UUID())),
            ("claim of a panel that is not live here", claim(UUID())),
        ]
        for (label, ext) in cases {
            // `from` names a live panel; that alone must not become the sender.
            let envelope = try MailboxEnvelope.build(from: "claimless", to: "stamp-recipient", body: "x", ext: ext)
            try dispatch(envelope, with: dispatcher)
            let copy = try MailboxEnvelope.validate(data: try readInboxFile(panel: recipient, id: envelope.id))
            XCTAssertNil(copy.senderPanelId, label)
            XCTAssertNil(copy.ext?[MailboxEnvelope.senderClaimKey], label)
            XCTAssertEqual(copy.body, "x", label)
        }
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(panel), limit: 10).total, 0)
    }

    func testSenderCannotForgeTheReservedStamp() throws {
        let real = seedSurface(name: "real-sender")
        let victim = seedSurface(name: "victim")
        let recipient = seedSurface(name: "forge-recipient")
        let dispatcher = makeDispatcher(surfaces: [real, victim, recipient])
        // A forged stamp naming another panel is replaced by the claimed sender.
        let forged = try MailboxEnvelope.build(
            from: "real-sender", to: "forge-recipient", body: "x",
            ext: [MailboxEnvelope.senderPanelKey: victim.uuidString.lowercased(), "custom": "kept"]
                .merging(claim(real)) { a, _ in a }
        )
        try dispatch(forged, with: dispatcher)
        let copy = try MailboxEnvelope.validate(data: try readInboxFile(panel: recipient, id: forged.id))
        XCTAssertEqual(copy.senderPanelId, real)
        XCTAssertEqual(copy.ext?["custom"] as? String, "kept")
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(victim), limit: 10).total, 0)
        // A forged stamp with no claim is dropped, not kept.
        let unclaimed = try MailboxEnvelope.build(
            from: "ghost", to: "forge-recipient", body: "y",
            ext: [MailboxEnvelope.senderPanelKey: victim.uuidString.lowercased()]
        )
        try dispatch(unclaimed, with: dispatcher)
        let dropped = try MailboxEnvelope.validate(data: try readInboxFile(panel: recipient, id: unclaimed.id))
        XCTAssertNil(dropped.senderPanelId)
        XCTAssertNil(dropped.ext)
        // A claim for a panel that is not the named one is honored only inside
        // this workspace: claiming the victim here is a claim like any other.
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(victim), limit: 10).total, 0)
    }

    func testCrossWorkspaceTitleCollisionDoesNotAttributeSentMail() throws {
        // Workspace A's panel, addressed "builder-a", sends to "Reviewer", which
        // lives here in B. B also has its own, different panel with that same
        // address, so the `from` string alone names the wrong panel here.
        let lookalike = seedSurface(name: "Builder")
        setAddress("builder-a", on: lookalike)
        let reviewer = seedSurface(name: "Reviewer")
        let dispatcher = makeDispatcher(surfaces: [lookalike, reviewer])
        let otherWorkspace = UUID()
        let senderInA = UUID()
        let from = try XCTUnwrap(MailboxSenderFrom.defaultValue(title: "Builder", mailboxAddress: "builder-a", panelId: senderInA))
        XCTAssertEqual(from, "builder-a")
        let envelope = try MailboxEnvelope.build(
            from: from, to: "Reviewer", body: "from workspace A",
            ext: claim(senderInA, workspace: otherWorkspace)
        )
        try dispatch(envelope, with: dispatcher)
        let copy = try MailboxEnvelope.validate(data: try readInboxFile(panel: reviewer, id: envelope.id))
        XCTAssertEqual(copy.body, "from workspace A")
        XCTAssertNil(copy.senderPanelId)
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(lookalike), limit: 10).total, 0)
    }

    func testSenderTitleAddressCollisionKeepsExactIdentity() throws {
        // "orch" is the real sender's title; another panel's address is "orch",
        // which wins a bare-name match.
        let sender = seedSurface(name: "orch")
        setAddress("orch-real", on: sender)
        let other = seedSurface(name: "someone-else")
        setAddress("orch", on: other)
        let recipient = seedSurface(name: "third")
        let dispatcher = makeDispatcher(surfaces: [sender, other, recipient])
        let envelope = try MailboxEnvelope.build(from: "orch", to: "third", body: "x", ext: claim(sender))
        try dispatch(envelope, with: dispatcher)
        let copy = try MailboxEnvelope.validate(data: try readInboxFile(panel: recipient, id: envelope.id))
        XCTAssertEqual(copy.senderPanelId, sender)
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(sender), limit: 10).total, 1)
        XCTAssertEqual(MailboxSentLedger.entries(senderInbox: senderInbox(other), limit: 10).total, 0)
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

    /// The messages page names a live message's sending panel from this
    /// field; without it the sender waits for a relaunch's file scan.
    func testDeliveredEventCarriesTheDispatchersSenderStamp() throws {
        let instance = "dispatcher-delivered-sender-stamp"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        defer { EventEmitter.shared.resetForTesting() }
        let sender = seedSurface(name: "stamped-sender")
        let recipient = seedSurface(name: "stamped-recipient")
        let dispatcher = makeDispatcher(surfaces: [sender, recipient])
        let envelope = try MailboxEnvelope.build(
            from: "stamped-sender", to: "stamped-recipient", body: "hello", ext: claim(sender)
        )
        try dispatch(envelope, with: dispatcher)
        dispatcher.log.flush()
        eventLog.flush()

        let delivered = try XCTUnwrap(MessagesPageSource.load(stateURL: tempState).events.first {
            $0.type == "mailbox.delivered" && $0.payload["id"] as? String == envelope.id
        })
        XCTAssertEqual(delivered.payload["sender_panel_id"] as? String, sender.uuidString)
    }

    func testUntitledPanelDeliveryUsesPanelIdInEventRecipient() throws {
        let instance = "dispatcher-untitled-recipient"
        let eventLog = EventLog(url: EventLogLayout.logURL(state: tempState, instance: instance), instance: instance)
        EventEmitter.shared.startForTesting(log: eventLog, instance: instance)
        defer { EventEmitter.shared.resetForTesting() }
        let recipient = seedSurface(name: "")
        let dispatcher = makeDispatcher(surfaces: [recipient])
        let envelope = try MailboxEnvelope.build(
            from: "sender", to: "id:\(recipient.uuidString)", body: "hello"
        )
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        dispatcher.log.flush()
        eventLog.flush()

        let delivered = try XCTUnwrap(MessagesPageSource.load(stateURL: tempState).events.first {
            $0.type == "mailbox.delivered" && $0.payload["id"] as? String == envelope.id
        })
        XCTAssertEqual(delivered.payload["recipient"] as? String, "id:\(recipient.uuidString)")
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

    func testOversizedOutboxEnvelopeIsRejectedAndNextEnvelopeDispatches() throws {
        let recipient = seedSurface(name: "bounded-recipient")
        let dispatcher = makeDispatcher(surfaces: [recipient])

        let oversized = try MailboxEnvelope.build(
            from: "sender",
            to: "bounded-recipient",
            body: "valid envelope prefix",
            id: "01K3A2B7X8PQRTVWYZ0123456X"
        )
        var oversizedBytes = try oversized.encode()
        oversizedBytes.append(contentsOf: Data(repeating: 0x20, count: 1024 * 1024 + 1 - oversizedBytes.count))
        XCTAssertNoThrow(try MailboxEnvelope.validate(data: oversizedBytes))
        let outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
        let oversizedURL = outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: oversized.id))
        try oversizedBytes.write(to: oversizedURL)

        dispatcher.dispatchOne(url: oversizedURL)

        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: oversized.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertThrowsError(try readInboxFile(panel: recipient, id: oversized.id))

        let valid = try MailboxEnvelope.build(
            from: "sender",
            to: "bounded-recipient",
            body: "NEXT_ENVELOPE_DELIVERED",
            id: "01K3A2B7X8PQRTVWYZ0123456Y"
        )
        try writeEnvelope(valid)
        dispatcher.dispatchOne(
            url: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: valid.id))
        )
        dispatcher.log.flush()

        let delivered = try MailboxEnvelope.validate(data: readInboxFile(panel: recipient, id: valid.id))
        XCTAssertEqual(delivered.body, "NEXT_ENVELOPE_DELIVERED")
        let history = try XCTUnwrap(
            MessagesPageSource.load(stateURL: tempState).mailboxArtifacts.first { $0.id == oversized.id }
        )
        XCTAssertNil(history.body)
        XCTAssertEqual(history.fileState, "rejected")
        XCTAssertEqual(history.lifecycle.map(\.state), ["rejected"])
        let events = try readLog().compactMap { $0["event"] as? String }
        XCTAssertEqual(events.first, "rejected")
        XCTAssertTrue(events.contains("cleaned"))
    }

    func testSymlinkOutboxEntryIsRejectedWithoutFollowingIt() throws {
        let dispatcher = makeDispatcher(surfaces: [])
        let id = "01K3A2B7X8PQRTVWYZ0123456M"
        let outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
        let link = outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        let target = tempState.appendingPathComponent("outside.msg")
        try Data("not an envelope".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        dispatcher.dispatchOne(url: link)
        dispatcher.log.flush()

        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: rejected.path)[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "not an envelope")
    }

    func testFIFOOutboxEntryIsRejectedWithoutBlocking() throws {
        let dispatcher = makeDispatcher(surfaces: [])
        let id = "01K3A2B7X8PQRTVWYZ0123456N"
        let outbox = MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
        let fifo = outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        dispatcher.dispatchOne(url: fifo)
        dispatcher.log.flush()

        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rejected.path))
        var fileInfo = stat()
        XCTAssertEqual(lstat(rejected.path, &fileInfo), 0)
        XCTAssertEqual(fileInfo.st_mode & mode_t(S_IFMT), mode_t(S_IFIFO))
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

    func testCaptainHolderClosingAfterResolutionLeavesDurableRejectionAndReceipt() throws {
        let captain = seedSurface(name: "captain", delivery: "silent")
        let lookalike = seedSurface(name: "role:lead", delivery: "silent")
        setAddress("role:lead", on: captain)
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspaceId, surfaceId: lookalike,
            partial: ["mailbox.role": "role:lead"], mode: .merge, source: .explicit)
        let caller = UUID()
        let resolved = try MailboxCaptainSendTarget.resolve(callerPanelId: caller) {
            ["resolution": "unique", "captain": "role:lead", "requested_recipient": "panel:role:lead",
             "caller_panel_id": caller.uuidString, "sender_workspace_id": self.workspaceId.uuidString,
             "target_workspace_id": self.workspaceId.uuidString, "panel_ids": [captain.uuidString],
             "recipients": [["requested_panel_id": captain.uuidString]]]
        }
        let envelope = try MailboxEnvelope.build(from: "sender", to: resolved.recipient, body: "report")
        let outboxFile = try MailboxSendTarget.verified(resolved.workspaceId).writeEnvelope(envelope, stateURL: tempState)

        // The holder closed after resolution. Its stale metadata remains, and a
        // live title/role lookalike remains, but neither is an exact live holder.
        let dispatcher = makeDispatcher(surfaces: [lookalike])
        var handlerCalls = 0
        dispatcher.registerHandler(name: "silent") { _, _, _ in
            handlerCalls += 1
            return .init(outcome: .ok)
        }
        dispatcher.dispatchOne(url: outboxFile)
        dispatcher.log.flush()
        XCTAssertEqual(handlerCalls, 0)
        let rejected = MailboxLayout.rejectedURL(state: tempState, workspaceId: workspaceId)
        let retained = try MailboxEnvelope.validate(data: Data(contentsOf:
            rejected.appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))))
        XCTAssertEqual(retained.to, "panel:role:lead")
        XCTAssertEqual(retained.body, "report")
        let reason = try String(contentsOf: rejected.appendingPathComponent(envelope.id + ".err"), encoding: .utf8)
        XCTAssertTrue(reason.contains("panel:role:lead"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxFile.path))
        XCTAssertThrowsError(try readInboxFile(panel: lookalike, id: envelope.id))
        let events = try readLog().compactMap { $0["event"] as? String }
        XCTAssertEqual(events, ["received", "resolved", "rejected"])
        let receipt = try MailboxReceiptStatus.status(id: envelope.id,
            workspacesRoot: tempState.appendingPathComponent(MailboxLayout.workspacesDirectoryName))
        XCTAssertEqual(receipt.state, .rejected)
        XCTAssertTrue(receipt.rejectedReason?.contains("panel:role:lead") == true)
        XCTAssertTrue(receipt.recipients.isEmpty)
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

    func testOnlyAttemptedDoorbellsLogRouteMetadata() throws {
        let dispatcher = makeDispatcher(surfaces: [])
        for outcome: MailboxDispatchLog.HandlerOutcome in [.doorbellSkipped, .doorbellCapped, .doorbell, .doorbellFailed] {
            dispatcher.logStdinLifecycle(id: outcome.rawValue, recipient: "pi", outcome: outcome,
                route: "typed", nativeRoute: "pi_extension", nativeFailure: "native_timeout")
        }
        dispatcher.log.flush()
        let rows = try readLog()
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            let attempted = ["doorbell", "doorbell_failed"].contains(row["outcome"] as? String ?? "")
            XCTAssertEqual(row["route"] as? String, attempted ? "typed" : nil)
            XCTAssertEqual(row["native_route"] as? String, attempted ? "pi_extension" : nil)
            XCTAssertEqual(row["native_failure"] as? String, attempted ? "native_timeout" : nil)
        }
    }

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

    /// Restages the doorbell sequence Workspace runs. There is no PTY here.
    /// `ownsTerminal` stands in for the kernel check.
    private final class StdinSeat: @unchecked Sendable {
        let state = MailboxStdinBufferStore()
        var ownsTerminal = true
        var lastOperatorKeyAt: Date?
        var lastOperatorInputAt: Date?
        var focused = false
        var textBox = ""
        var screen: PromptInputState = .empty
        /// C11H-445: the panel's live agent kind, as Workspace reads it.
        var agentKind: String?
        private(set) var rings: [String] = []
        private(set) var idleFlushes = 0
        private var ledger = MailboxDoorbell.Ledger()
        let dispatcher: MailboxDispatcher
        let stateURL: URL
        let workspaceId: UUID
        var buffer: MailboxStdinBuffer { state.buffer }

        init(dispatcher: MailboxDispatcher, stateURL: URL, workspaceId: UUID) {
            self.dispatcher = dispatcher
            self.stateURL = stateURL
            self.workspaceId = workspaceId
        }

        func inbox(_ surfaceId: UUID) -> URL {
            MailboxLayout.inboxURL(state: stateURL, workspaceId: workspaceId, panelId: surfaceId)
        }

        func beginTurn(surfaceId: UUID, at: Date) {
            state.buffer.noteAgentTurn(surfaceId: surfaceId, atPrompt: true, at: at)
            state.buffer.noteSubmit(surfaceId: surfaceId, at: at.addingTimeInterval(1))
        }

        func noteIdle(surfaceId: UUID, at: Date) {
            noteReported(surfaceId: surfaceId, activity: .idle, at: at, agentPid: nil, processStartTime: nil)
        }

        func noteWrapperIdle(surfaceId: UUID, at: Date) {
            ownsTerminal = true
            noteReported(surfaceId: surfaceId, activity: .idle, at: at, agentPid: 1, processStartTime: 1)
        }

        /// C11H-445: Workspace's inbox rescan, through the production helper.
        func rescanInbox(surfaceId: UUID, recipient: String) -> [String] {
            let found = MailboxStdinDelivery.inboxEntriesToQueue(
                inbox: inbox(surfaceId), inboxWorkspaceId: workspaceId, panelId: surfaceId, recipientName: recipient,
                skipping: Set(state.buffer.queuedEntries(surfaceId: surfaceId).map(\.id)).union(ledger.coveredIds),
                since: MailboxStdinDelivery.processStartedAt)
            for entry in found { _ = state.buffer.enqueue(surfaceId: surfaceId, entry: entry) }
            return found.map(\.id)
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
            let admitted = MailboxStdinDelivery.deliver(
                state: state,
                surfaceId: surfaceId,
                entry: entry,
                gate: gate(),
                logEvicted: { [dispatcher] evicted in
                    dispatcher.logStdinLifecycle(
                        id: evicted.id,
                        recipient: evicted.recipientName,
                        outcome: .evicted
                    )
                }
            )
            switch admitted {
            case .ok(let bytes):
                return .init(outcome: .ok, bytes: bytes, elapsedMs: 0)
            case .buffered(let bytes), .doorbell(let bytes, _):
                return .init(outcome: .buffered, bytes: bytes, elapsedMs: 0)
            }
        }

        private func gate() -> MailboxStdinDelivery.Gate {
            MailboxStdinDelivery.Gate(
                panelPresent: true,
                isAgentKind: true,
                ownsTerminal: ownsTerminal,
                lastOperatorKeyAt: lastOperatorKeyAt,
                inputTransactionActive: false,
                inputTransactionEpoch: 0,
                surfaceAttached: true
            )
        }

        private func noteReported(
            surfaceId: UUID,
            activity: SidebarActivityState,
            at: Date,
            agentPid: pid_t?,
            processStartTime: UInt64?
        ) {
            MailboxStdinDelivery.noteReported(
                state: state,
                surfaceId: surfaceId,
                activity: activity,
                at: at,
                agentPid: agentPid,
                processStartTime: processStartTime,
                flush: { [self] in
                    self.idleFlushes += 1
                    self.ringQueued(surfaceId: surfaceId)
                }
            )
        }

        /// Idle-edge ring. Stats the inbox, then runs the doorbell decision.
        /// A ring records the invitation. It does not claim and does not paste.
        private func ringQueued(surfaceId: UUID) {
            let queued = state.buffer.queuedEntries(surfaceId: surfaceId)
            let pending = Set(queued.map(\.id).filter {
                MailboxIO.isPending(id: $0, inbox: inbox(surfaceId))
            })
            let gone = MailboxDoorbellSequence.droppedIds(
                snapshot: queued.map(\.id),
                stillPending: pending
            )
            for id in gone {
                _ = state.buffer.removeQueued(surfaceId: surfaceId, id: id)
            }
            let live = state.buffer.queuedEntries(surfaceId: surfaceId)
            guard !live.isEmpty else { return }
            let now = Date()
            guard state.buffer.promptGate(
                surfaceId: surfaceId,
                isAgentKind: true,
                agentOwnsTerminal: ownsTerminal,
                journalTurnOpen: false,
                now: now
            ) != .closed else { return }
            let turn = state.buffer.agentTurn(surfaceId: surfaceId)
            let epoch = turn.map {
                MailboxDoorbell.promptEpoch(since: $0.since, atPrompt: $0.atPrompt)
            } ?? "none"
            var input = MailboxDoorbell.Input()
            // The delivery Workspace reads for the ring: the same policy the
            // dispatcher's handlers came from (C11H-445).
            input.stdinDelivery = MailboxDeliveryPolicy.effective(
                metadata: PanelMetadataStore.shared.getMetadata(workspaceId: workspaceId, surfaceId: surfaceId).metadata,
                agentKind: agentKind
            ).includesStdin
            input.prompt = screen
            input.rungThisEpoch = ledger.rung(in: epoch)
            input.recentAttempts = ledger.rings(at: now)
            input.inFlight = ledger.inFlight
            input.focused = focused
            input.operatorKeyAge = MailboxDoorbellSequence.operatorKeyAge(
                keyAt: lastOperatorKeyAt,
                inputAt: lastOperatorInputAt,
                now: now
            )
            input.textBoxUnsent = MailboxDoorbellSequence.textBoxHoldsUnsent(textBox)
            input.epoch = epoch
            input.now = now
            let decision = MailboxDoorbell.decide(input)
            let plan = MailboxDoorbellSequence.plan(
                decision: decision,
                attempts: ledger.attempts,
                now: now,
                busyExhausted: false,
                strandedDoorbell: false
            )
            guard case .ring = plan.arrival else { return }
            rings.append(MailboxDoorbell.text)
            ledger.beginAttempt(at: now, epoch: epoch)
        }
    }

    private func t381(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private func makeStdinSeat(delivery: String? = "stdin", terminalType: String? = nil,
                               doorbell: String? = nil,
                               detectedKinds: @escaping () -> [UUID: String] = { [:] }) -> (UUID, StdinSeat) {
        let surface = seedSurface(name: "grok-seat", delivery: delivery)
        var identity: [String: Any] = [:]
        if let terminalType { identity[MetadataKey.terminalType] = terminalType }
        if let doorbell { identity["mailbox.doorbell"] = doorbell }
        if !identity.isEmpty {
            _ = try? PanelMetadataStore.shared.setMetadata(workspaceId: workspaceId, surfaceId: surface,
                                                           partial: identity, mode: .merge, source: .explicit)
        }
        let dispatcher = makeDispatcher(surfaces: [surface], detectedKinds: detectedKinds)
        let seat = StdinSeat(dispatcher: dispatcher, stateURL: tempState, workspaceId: workspaceId)
        seat.agentKind = terminalType
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

    /// Mail admitted while the agent is mid-turn stays in the inbox. An idle
    /// edge does not claim it and does not paste a block. The doorbell ring
    /// is Workspace's, and it leaves the file unread.
    func testBufferedStdinStaysUnclaimedOnIdle() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456A"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "flush-once")
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))

        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertEqual(seat.idleFlushes, 1)
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))

        seat.noteIdle(surfaceId: surface, at: t381(30))
        dispatcher?.log.flush()
        XCTAssertEqual(seat.idleFlushes, 2)
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))
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
        XCTAssertTrue(seat.rings.isEmpty)
    }

    /// An idle edge does not type over an operator draft, and does not claim.
    func testDraftIsNotTypedOver() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456C"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "behind-draft")
        seat.screen = .draft
        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))
        XCTAssertTrue(seat.rings.isEmpty)
    }

    /// A drain that claimed the file first keeps it. The idle edge does not paste.
    func testDrainClaimSkipsPush() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456D"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "drain-first")
        let claimed = try XCTUnwrap(try MailboxIO.claim(id: id, inbox: seat.inbox(surface)))
        XCTAssertEqual(claimed.deletingLastPathComponent().lastPathComponent, "_read")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(seat.rings.isEmpty)
        XCTAssertEqual(seat.idleFlushes, 1)
        XCTAssertTrue(envelopeIsClaimed(surface: surface, id: id))
    }

    /// A transcript idle does not pin a process. The later wrapper idle does.
    /// Neither claims the envelope.
    func testTranscriptIdleThenWrapperIdlePinsWithoutClaiming() throws {
        let (surface, seat) = makeStdinSeat()
        let id = "01K3A2B7X8PQRTVWYZ0123456E"
        seat.ownsTerminal = false
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "after-pin")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(seat.rings.isEmpty)
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertNil(seat.buffer.agentProcess(surfaceId: surface))

        seat.noteWrapperIdle(surfaceId: surface, at: t381(21))
        dispatcher?.log.flush()
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))
        XCTAssertEqual(seat.buffer.agentProcess(surfaceId: surface)?.pid, 1)

        seat.noteWrapperIdle(surfaceId: surface, at: t381(40))
        dispatcher?.log.flush()
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertEqual(try handlerOutcomes().filter { $0 == "flushed" }.count, 0)
    }
}

extension MailboxDispatcherTests {
    func testLimitedRecipientTraceKeepsOneEnvelopeUnreadUntilExplicitClaim() throws {
        let recipient = seedSurface(name: "limited-recipient")
        let resolver = MailboxPanelResolver(workspaceId: workspaceId, livePanels: { [recipient] })
        let dispatcher = MailboxDispatcher(workspaceId: workspaceId, stateURL: tempState,
            resolver: resolver, recipientUsageLimit: { panel in panel == recipient ? .monthlySpend : nil })
        self.dispatcher = dispatcher
        let envelope = try MailboxEnvelope.build(from: "sender", to: "limited-recipient",
            body: "synthetic mail", id: "01K3A2B7X8PQRTVWYZ0123456J")
        try writeEnvelope(envelope)
        dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: tempState, workspaceId: workspaceId)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id)))
        dispatcher.log.flush()
        let copied = try XCTUnwrap(readLog().first { $0["event"] as? String == "copied" })
        XCTAssertEqual(copied["recipient_usage_limit"] as? String, "monthly_spend")
        let inbox = MailboxLayout.inboxURL(state: tempState, workspaceId: workspaceId, panelId: recipient)
        let pending = MailboxDrain.pendingEntries(inbox: inbox)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(try MailboxEnvelope.validate(data: readInboxFile(panel: recipient, id: envelope.id)).body,
                       envelope.body)
        XCTAssertTrue(MailboxDrain.pendingEntries(inbox: MailboxDrain.readURL(inbox: inbox)).isEmpty)
        let entry = try XCTUnwrap(pending.first)
        XCTAssertNotNil(MailboxDrain.claim(entry))
        XCTAssertNil(MailboxDrain.claim(entry), "the same envelope is claimed exactly once")
        XCTAssertTrue(MailboxDrain.pendingEntries(inbox: inbox).isEmpty)
        XCTAssertEqual(MailboxDrain.pendingEntries(inbox: MailboxDrain.readURL(inbox: inbox)).count, 1)
    }
}

// MARK: - C11H-445: mail on by default for agents with a doorbell

extension MailboxDispatcherTests {
    private func copiedDelivery() throws -> (value: String?, source: String?) {
        let copied = try XCTUnwrap(readLog().first { $0["event"] as? String == "copied" })
        return (copied["delivery"] as? String, copied["delivery_source"] as? String)
    }

    /// A seat launch-agent stamped (or a wrapper declared) with no mailbox
    /// metadata gets the doorbell at its next idle with an empty composer.
    func testWrapperLaunchedAgentWithNoMetadataIsRung() throws {
        let (surface, seat) = makeStdinSeat(delivery: nil, terminalType: "claude-code")
        let id = "01K3A2B7X8PQRTVWYZ0123445A"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "reply to your mail")
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(seat.rings.isEmpty, "a running turn is not rung")
        let delivery = try copiedDelivery()
        XCTAssertEqual(delivery.value, "stdin")
        XCTAssertEqual(delivery.source, "default")

        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id), "the ring invites; recv --ack claims")
    }

    /// The operator's own seat with no metadata: the default never types over
    /// a draft, and rings at the next real idle with an empty composer.
    func testDefaultDeliveryNeverTypesOverADraft() throws {
        let (surface, seat) = makeStdinSeat(delivery: nil, terminalType: "codex")
        let id = "01K3A2B7X8PQRTVWYZ0123445B"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "behind the operator's draft")
        seat.screen = .draft
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertTrue(seat.rings.isEmpty, "a draft is never typed over")
        seat.screen = .empty
        seat.textBox = "half a thought"
        seat.beginTurn(surfaceId: surface, at: t381(30))
        seat.noteIdle(surfaceId: surface, at: t381(40))
        XCTAssertTrue(seat.rings.isEmpty, "unsent text-box input is a draft too")
        seat.textBox = ""
        seat.beginTurn(surfaceId: surface, at: t381(50))
        seat.noteIdle(surfaceId: surface, at: t381(60))
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
    }

    /// `mailbox.delivery=off` runs no handler (and logs no unknown handler),
    /// so nothing is queued or rung; the mail waits in the inbox.
    func testDeliveryOffIsNotRung() throws {
        let (surface, seat) = makeStdinSeat(delivery: "off", terminalType: "claude-code")
        let id = "01K3A2B7X8PQRTVWYZ0123445C"
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "not for a bell")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(try handlerOutcomes(), [])
        XCTAssertTrue(seat.buffer.queuedEntries(surfaceId: surface).isEmpty)
        XCTAssertTrue(seat.rings.isEmpty)
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))
        let delivery = try copiedDelivery()
        XCTAssertEqual(delivery.value, "off")
        XCTAssertEqual(delivery.source, "explicit")
    }

    /// `mailbox.doorbell=off` with no delivery set withholds the default.
    func testDoorbellOffWithholdsTheDefault() throws {
        let (surface, seat) = makeStdinSeat(delivery: nil, terminalType: "grok", doorbell: "off")
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: "01K3A2B7X8PQRTVWYZ0123445D", body: "quiet seat")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(try handlerOutcomes(), [])
        XCTAssertTrue(seat.rings.isEmpty)
        XCTAssertEqual(try copiedDelivery().source, "doorbell_off")
    }

    /// A plain shell has no agent kind, so nothing is queued for it.
    func testPlainShellIsNotRung() throws {
        let (shell, shellSeat) = makeStdinSeat(delivery: nil, terminalType: nil)
        shellSeat.beginTurn(surfaceId: shell, at: t381(0))
        try dispatchToSeat(id: "01K3A2B7X8PQRTVWYZ0123445E", body: "to a shell")
        shellSeat.noteIdle(surfaceId: shell, at: t381(20))
        XCTAssertEqual(try handlerOutcomes(), [])
        XCTAssertTrue(shellSeat.rings.isEmpty)
        XCTAssertEqual(try copiedDelivery().source, "none")
    }

    /// A one-shot run declares its kind, but no interactive PID owns the
    /// terminal, so its queued mail is never rung.
    func testOneShotRunIsNotRung() throws {
        let (surface, seat) = makeStdinSeat(delivery: nil, terminalType: "claude-code")
        seat.ownsTerminal = false
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: "01K3A2B7X8PQRTVWYZ0123445F", body: "to claude -p")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(try handlerOutcomes(), ["buffered"])
        XCTAssertTrue(seat.rings.isEmpty, "no interactive agent owns the terminal")
    }

    /// A panel's own value wins over the default: `silent` stays silent.
    func testExplicitDeliveryWinsOverTheDefault() throws {
        let (surface, seat) = makeStdinSeat(delivery: "silent", terminalType: "claude-code")
        var silent = 0
        dispatcher?.registerHandler(name: "silent") { _, _, _ in
            silent += 1
            return .init(outcome: .ok, bytes: 0)
        }
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: "01K3A2B7X8PQRTVWYZ0123445G", body: "silent please")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(silent, 1)
        XCTAssertEqual(try handlerOutcomes(), ["ok"])
        XCTAssertTrue(seat.buffer.queuedEntries(surfaceId: surface).isEmpty)
        XCTAssertTrue(seat.rings.isEmpty)
        let delivery = try copiedDelivery()
        XCTAssertEqual(delivery.value, "silent")
        XCTAssertEqual(delivery.source, "explicit")
    }
}

// MARK: - C11H-445: mail that came during a startup shell rings once the agent appears

extension MailboxDispatcherTests {
    private func writeInbox(panel: UUID, id: String) throws {
        let inbox = MailboxLayout.inboxURL(state: tempState, workspaceId: workspaceId, panelId: panel)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let envelope = try MailboxEnvelope.build(from: "orch", to: "grok-seat", body: "mail \(id)", id: id)
        try MailboxIO.atomicWrite(data: try envelope.encode(),
                                  to: inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
    }

    /// The rescan queues unread mail this process accepted that the queue
    /// does not hold: not mail already queued or rung, not read mail, not mail
    /// from before `since`.
    func testInboxRescanQueuesOnlyFreshUnqueuedUnreadMail() throws {
        let panel = UUID()
        let now = Date()
        let old = MailboxULID.make(now: now.addingTimeInterval(-3600))
        let queued = MailboxULID.make(now: now.addingTimeInterval(-2))
        let fresh = MailboxULID.make(now: now.addingTimeInterval(-1))
        let read = MailboxULID.make(now: now)
        for id in [old, queued, fresh, read] { try writeInbox(panel: panel, id: id) }
        let inbox = MailboxLayout.inboxURL(state: tempState, workspaceId: workspaceId, panelId: panel)
        XCTAssertNotNil(try MailboxIO.claim(id: read, inbox: inbox))
        let found = MailboxStdinDelivery.inboxEntriesToQueue(
            inbox: inbox, inboxWorkspaceId: workspaceId, panelId: panel, recipientName: "seat",
            skipping: [queued], since: now.addingTimeInterval(-60))
        XCTAssertEqual(found.map(\.id), [fresh])
        XCTAssertEqual(found.first?.recipientPanelId, panel)
        XCTAssertEqual(found.first?.inboxWorkspaceId, workspaceId)
    }

    /// A launched seat whose terminal still reads as a shell (a remote prompt
    /// transfer, a slow start) gets no default, so its first mail is copied
    /// but not queued. Once detection sees the agent, the rescan queues it
    /// and the agent's first idle rings it, with no second send.
    func testMailDuringAStartupShellRingsOnceTheAgentAppears() throws {
        var detected = "shell"
        var surfaceId = UUID()
        let (surface, seat) = makeStdinSeat(delivery: nil, terminalType: "codex",
                                            detectedKinds: { [surfaceId: detected] })
        surfaceId = surface
        seat.agentKind = "shell"
        let id = MailboxULID.make()
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "first mail while launching")
        XCTAssertEqual(try handlerOutcomes(), [], "a startup shell gets no default")
        XCTAssertEqual(try copiedDelivery().source, "none")
        XCTAssertTrue(envelopeIsInInboxRoot(surface: surface, id: id))

        detected = "codex"
        seat.agentKind = "codex"
        XCTAssertEqual(seat.rescanInbox(surfaceId: surface, recipient: "grok-seat"), [id])
        XCTAssertEqual(seat.rescanInbox(surfaceId: surface, recipient: "grok-seat"), [], "queued once")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id), "the ring invites; recv --ack claims")
    }
}

// MARK: - C11H-445: a dispatch resolved as a shell, with the agent appearing before its copy lands

extension MailboxDispatcherTests {
    /// The interleaving the rescan alone misses: the dispatch resolves the
    /// panel while it still reads as a shell; before the copy lands, the agent
    /// appears and its inbox rescan runs and finds nothing; then the copy
    /// lands with no handler from the shell resolution. The post-copy recheck
    /// reads the panel again and queues it, and it rings with no second send.
    func testADispatchResolvedAsAShellRingsWhenTheAgentAppearedBeforeTheCopy() throws {
        var detected = "shell"
        var surfaceId = UUID()
        var seatRef: StdinSeat?
        var scanned: [String]?
        let (surface, seat) = makeStdinSeat(delivery: nil, terminalType: "codex", detectedKinds: {
            let now = [surfaceId: detected]
            if detected == "shell", let seat = seatRef {
                // The pause after shell resolution: the agent appears, and
                // its rescan runs before the copy is in the inbox.
                detected = "codex"
                seat.agentKind = "codex"
                scanned = seat.rescanInbox(surfaceId: surfaceId, recipient: "grok-seat")
            }
            return now
        })
        surfaceId = surface
        seatRef = seat
        seat.agentKind = "shell"
        let id = MailboxULID.make()
        seat.beginTurn(surfaceId: surface, at: t381(0))
        try dispatchToSeat(id: id, body: "first mail, racing the launch")

        XCTAssertEqual(scanned, [], "the transition's rescan ran before the copy and found nothing")
        XCTAssertEqual(try copiedDelivery().source, "none", "the dispatch resolved the panel as a shell")
        XCTAssertEqual(try handlerOutcomes(), ["buffered"], "the post-copy recheck queued it")
        seat.noteIdle(surfaceId: surface, at: t381(20))
        XCTAssertEqual(seat.rings, [MailboxDoorbell.text])
        XCTAssertFalse(envelopeIsClaimed(surface: surface, id: id))
    }
}
