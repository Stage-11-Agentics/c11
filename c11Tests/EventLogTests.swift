import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-163 events stream — logic tests for the envelope, layout, writer
/// (rotation + backpressure), and emitter facade. Hermetic: every test uses a
/// fresh temp dir and blocks on `flush()`, so the whole file runs sub-second in
/// the `c11-logic` scheme.
final class EventLogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-events-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        EventEmitter.shared.resetForTesting()
    }

    private func logURL(_ name: String = "events.ndjson") -> URL {
        tempDir.appendingPathComponent(name, isDirectory: false)
    }

    private func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func parse(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - EVT-1: envelope shape

    func testEnvelopeCarriesRequiredFieldsAndOmitsNilRefs() {
        let env = EventEnvelope(
            type: .surfaceCreated,
            instance: "inst-1",
            ts: Date(timeIntervalSince1970: 1_770_000_000),
            workspace: "ws-uuid",
            surface: "sf-uuid",
            payload: ["kind": "terminal"]
        )
        let line = env.serialize(seq: 7)
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = parse(line)
        XCTAssertEqual(obj["seq"] as? Int, 7)
        XCTAssertEqual(obj["type"] as? String, "surface.created")
        XCTAssertEqual(obj["instance"] as? String, "inst-1")
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["workspace"] as? String, "ws-uuid")
        XCTAssertEqual(obj["surface"] as? String, "sf-uuid")
        XCTAssertNil(obj["pane"], "nil refs must be omitted, not encoded as null")
        XCTAssertNotNil(obj["ts"] as? String)
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["kind"] as? String, "terminal")
    }

    func testEnvelopeParseHelpers() {
        let line = EventEnvelope(
            type: .metadataChanged,
            instance: "i",
            ts: Date(timeIntervalSince1970: 1_770_000_123)
        ).serialize(seq: 42)
        XCTAssertEqual(EventEnvelope.type(fromLine: line), "metadata.changed")
        XCTAssertEqual(EventEnvelope.seq(fromLine: line), 42)
        XCTAssertNotNil(EventEnvelope.timestamp(fromLine: line))
        // Tolerant of junk.
        XCTAssertNil(EventEnvelope.type(fromLine: "not json"))
        XCTAssertNil(EventEnvelope.seq(fromLine: ""))
    }

    func testLifecycleChangedEnvelopeUsesTheClosedTypeAndPayload() {
        let tab = UUID(uuidString: "6f9619ff-8b86-d011-b42d-00cf4fc964ff")!
        let line = EventEnvelope(
            type: .lifecycleChanged,
            instance: "i",
            ts: Date(timeIntervalSince1970: 1_770_000_123),
            workspace: "9b2d4e6a-1c3f-4a5b-8d7e-2f0a1b3c4d5e",
            surface: tab.uuidString,
            payload: ["tab": tab.uuidString, "agent": "claude-code", "from": "working", "to": "blocked", "reason": "question"]
        ).serialize(seq: 12)
        let object = parse(line)
        XCTAssertEqual(object["type"] as? String, "lifecycle.changed")
        XCTAssertEqual((object["payload"] as? [String: Any])?["to"] as? String, "blocked")
    }

    // MARK: - Layout

    func testLayoutFilenameAndInstanceSanitize() {
        XCTAssertEqual(EventLogLayout.logFileName(instance: "abc-123"), "events-abc-123.ndjson")
        XCTAssertEqual(EventLogLayout.sanitizeInstance("a/b c:d"), "a_b_c_d")
        let id = EventLogLayout.makeInstanceId(tag: "evt-post", bundleId: "x", pid: 99)
        XCTAssertEqual(id, "evt-post-99")
    }

    func testLayoutNewestByMtime() throws {
        let dir = EventLogLayout.eventsDirectoryURL(state: tempDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let older = dir.appendingPathComponent("events-old.ndjson")
        let newer = dir.appendingPathComponent("events-new.ndjson")
        FileManager.default.createFile(atPath: older.path, contents: Data("{}\n".utf8))
        FileManager.default.createFile(atPath: newer.path, contents: Data("{}\n".utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: newer.path)
        let resolved = try EventLogLayout.newestLogURL(state: tempDir)
        XCTAssertEqual(resolved.lastPathComponent, "events-new.ndjson")
    }

    // MARK: - EVT-1: monotonic seq + ordering

    func testAppendAssignsMonotonicSeqInFileOrder() {
        let log = EventLog(url: logURL(), instance: "i")
        for i in 0..<5 {
            log.append(EventEnvelope(type: .workspaceSelected, instance: "i", ts: Date(),
                                     payload: ["n": i]))
        }
        log.flush()
        let seqs = readLines(logURL()).compactMap { EventEnvelope.seq(fromLine: $0) }
        XCTAssertEqual(seqs, [1, 2, 3, 4, 5])
    }

    func testOpenWritesLogOpenedMarker() {
        let log = EventLog(url: logURL(), instance: "boot-1")
        log.open()
        log.flush()
        let lines = readLines(logURL())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(EventEnvelope.type(fromLine: lines[0]), "log.opened")
        XCTAssertEqual(EventEnvelope.seq(fromLine: lines[0]), 1)
    }

    // MARK: - EVT-4: rotation

    func testRotationRollsAndMarksAndRetainsOneGeneration() {
        // Tiny cap forces a roll after a couple of lines.
        let log = EventLog(url: logURL(), instance: "i", sizeCap: 200)
        for i in 0..<40 {
            log.append(EventEnvelope(type: .surfaceCreated, instance: "i", ts: Date(),
                                     surface: "s\(i)", payload: ["kind": "terminal"]))
        }
        log.flush()

        let rolled = EventLogLayout.rolledURL(for: logURL())
        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled.path),
                      "rotation must retain one rolled generation (.1)")

        // The fresh current file must open with a log.rotated marker so a
        // consumer that detects the shrink lands on the boundary.
        let currentLines = readLines(logURL())
        XCTAssertFalse(currentLines.isEmpty)
        XCTAssertEqual(EventEnvelope.type(fromLine: currentLines[0]), "log.rotated")

        // Seq stays monotonic across the boundary (rolled tail < current head).
        let rolledSeqs = readLines(rolled).compactMap { EventEnvelope.seq(fromLine: $0) }
        let currentSeqs = currentLines.compactMap { EventEnvelope.seq(fromLine: $0) }
        XCTAssertLessThan(rolledSeqs.last ?? 0, currentSeqs.first ?? 0)
    }

    // MARK: - EVT-3: non-blocking under a stalled disk

    func testAppendIsNonBlockingAndDropsUnderBackpressure() {
        let log = EventLog(url: logURL(), instance: "i", maxPending: 4)
        let gate = DispatchSemaphore(value: 0)
        // Pin the writer queue on the first write so pending saturates.
        log.onQueueBeforeWrite = { gate.wait() }

        // Flood far past maxPending. Each append must return immediately.
        let start = Date()
        for i in 0..<500 {
            log.append(EventEnvelope(type: .metadataChanged, instance: "i", ts: Date(),
                                     payload: ["n": i]))
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "append must not block even while the writer queue is stalled")

        // Release the queue and drain. Signal generously (more than any line
        // the queue could write) and leave the hook in place — nil-ing it from
        // this thread would race the queue's read of the closure.
        for _ in 0..<2000 { gate.signal() }
        log.flush()

        // The shed events must surface in-stream as a log.dropped marker.
        let types = readLines(logURL()).compactMap { EventEnvelope.type(fromLine: $0) }
        XCTAssertTrue(types.contains("log.dropped"),
                      "backpressure drops must be observable as a log.dropped marker")
    }

    func testDroppedLifecycleLineRecoversFromCommittedJournalSnapshot() throws {
        let tab = JournalTestData.tab
        let workspace = JournalTestData.workspace
        let draft = JournalTestData.draft(.questionRequested)
        let journalLayout = JournalStorageLayout(directory: tempDir.appendingPathComponent("journal", isDirectory: true))
        let store = try JournalStore(layout: journalLayout, clock: { 1_000 })
        _ = try store.append(draft: draft, context: JournalContext(eligible: true))

        let log = EventLog(url: logURL(), instance: "drop-recovery", maxPending: 1)
        let writerBlocked = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        log.onQueueBeforeWrite = {
            writerBlocked.signal()
            releaseWriter.wait()
        }
        EventEmitter.shared.startForTesting(log: log, instance: "drop-recovery")
        EventEmitter.shared.emitMetadataChanged(
            scope: "surface", workspace: workspace, surface: tab,
            key: "status", value: "waiting", prior: "working", source: "fixture")
        XCTAssertEqual(writerBlocked.wait(timeout: .now() + .seconds(1)), .success)

        EventEmitter.shared.emitLifecycleChanged(
            workspace: workspace, tab: tab,
            payload: ["tab": tab.uuidString, "agent": "claude-code", "from": "working", "to": "blocked", "reason": "question"])
        for _ in 0..<8 { releaseWriter.signal() }
        log.flush()
        EventEmitter.shared.emitMetadataChanged(
            scope: "surface", workspace: workspace, surface: tab,
            key: "status", value: "blocked", prior: "waiting", source: "fixture")
        EventEmitter.shared.flush()

        let written = readLines(logURL()).compactMap { EventEnvelope.type(fromLine: $0) }
        XCTAssertTrue(written.contains("log.dropped"))
        XCTAssertFalse(written.contains("lifecycle.changed"), "the saturated writer deliberately dropped the phase edge")

        let baseline = try XCTUnwrap(store.current(owner: try XCTUnwrap(draft.owner)))
        let page = try store.retainedOwnerEvents(owner: baseline.owner, throughSequence: baseline.lastSequence)
        let recovered = AgentRoster.document(
            live: [], currents: [JournalReplayPolicy.restored(baseline)], eventsByOwner: [baseline.owner.key: page.events],
            truncatedOwners: [], unattributed: 0, storePruned: false, storageAvailable: true,
            healthDegraded: false, now: 2_000, liveIdentity: "unavailable")
        let candidates = recovered["restore_candidates"] as? [[String: Any]] ?? []
        XCTAssertEqual(candidates.first?["state"] as? String, "blocked")
        XCTAssertEqual(candidates.first?["reason"] as? String, "question")
    }

    // MARK: - Emitter

    func testEmitterExcludesProgressFromCanonicalKeys() {
        XCTAssertTrue(EventEmitter.canonicalMetadataEventKeys.contains("status"))
        XCTAssertTrue(EventEmitter.canonicalMetadataEventKeys.contains("title"))
        XCTAssertTrue(EventEmitter.canonicalMetadataEventKeys.contains("description"))
        XCTAssertFalse(EventEmitter.canonicalMetadataEventKeys.contains("progress"),
                       "progress is excluded from v1 metadata.changed (flood control)")
    }

    func testEmitterEmitsThroughInjectedLog() {
        let log = EventLog(url: logURL(), instance: "test-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "test-inst")
        let ws = UUID(), sf = UUID()
        EventEmitter.shared.emitSurfaceCreated(workspace: ws, surface: sf, kind: "terminal")
        EventEmitter.shared.emitMetadataChanged(
            scope: "surface", workspace: ws, surface: sf,
            key: "status", value: "working", prior: "idle", source: "explicit")
        EventEmitter.shared.flush()

        let objs = readLines(logURL()).map(parse)
        XCTAssertEqual(objs.count, 2)
        XCTAssertEqual(objs[0]["type"] as? String, "surface.created")
        XCTAssertEqual(objs[0]["surface"] as? String, sf.uuidString)
        XCTAssertEqual(objs[1]["type"] as? String, "metadata.changed")
        let payload = objs[1]["payload"] as? [String: Any]
        XCTAssertEqual(payload?["key"] as? String, "status")
        XCTAssertEqual(payload?["value"] as? String, "working")
        XCTAssertEqual(payload?["prior"] as? String, "idle")
        XCTAssertEqual(payload?["source"] as? String, "explicit")
        XCTAssertEqual(payload?["scope"] as? String, "surface")
    }

    func testTabInputPayloadRecordsNullCallerAndKeyAttribution() {
        let log = EventLog(url: logURL(), instance: "input-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "input-inst")
        let workspace = UUID()
        let textSurface = UUID()
        let keySurface = UUID()
        let caller = UUID()

        EventEmitter.shared.emitTabInputSent(
            workspace: workspace,
            surface: textSurface,
            callerTabId: nil,
            callerTitle: nil,
            targetTitle: "outside target",
            kind: "text",
            text: "hello",
            submitted: true
        )
        EventEmitter.shared.emitTabInputSent(
            workspace: workspace,
            surface: keySurface,
            callerTabId: caller,
            callerTitle: "caller",
            targetTitle: "key target",
            kind: "key",
            text: "enter",
            submitted: true
        )
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.map { $0["type"] as? String }, ["tab.input_sent", "tab.input_sent"])

        let textPayload = events[0]["payload"] as? [String: Any]
        XCTAssertTrue(textPayload?["caller_tab_id"] is NSNull)
        XCTAssertTrue(textPayload?["caller_title"] is NSNull)
        XCTAssertEqual(textPayload?["target_title"] as? String, "outside target")
        XCTAssertEqual(textPayload?["kind"] as? String, "text")
        XCTAssertEqual(textPayload?["text"] as? String, "hello")
        XCTAssertEqual(textPayload?["bytes"] as? Int, 5)
        XCTAssertEqual(textPayload?["submitted"] as? Bool, true)

        let keyPayload = events[1]["payload"] as? [String: Any]
        XCTAssertEqual(keyPayload?["caller_tab_id"] as? String, caller.uuidString)
        XCTAssertEqual(keyPayload?["caller_title"] as? String, "caller")
        XCTAssertEqual(keyPayload?["kind"] as? String, "key")
        XCTAssertEqual(keyPayload?["text"] as? String, "enter")
    }

    func testTabInputPayloadRecordsQueuedAndSubmitState() {
        let payload = EventEmitter.tabInputPayload(
            callerTabId: UUID(),
            callerTitle: "caller",
            targetTitle: "target",
            kind: "text",
            text: "partial line",
            submitted: false,
            queued: true
        )

        XCTAssertEqual(payload["submitted"] as? Bool, false)
        XCTAssertEqual(payload["queued"] as? Bool, true)
    }

    func testTabInputPayloadTruncatesBodyAtUTF8Boundary() {
        let text = "a" + String(repeating: "🙂", count: 100_000)
        let payload = EventEmitter.tabInputPayload(
            callerTabId: nil,
            callerTitle: nil,
            targetTitle: "target",
            kind: "text",
            text: text,
            submitted: false
        )

        guard let recorded = payload["text"] as? String else {
            XCTFail("payload text must be a string")
            return
        }
        XCTAssertEqual(payload["bytes"] as? Int, text.utf8.count)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(recorded.utf8.count, EventEmitter.maxRecordedTextBytes)
        XCTAssertTrue(text.hasPrefix(recorded))
        XCTAssertFalse(recorded.contains("\u{FFFD}"), "truncation must not split a UTF-8 scalar")
    }

    func testMailboxEventsCarryMessageFieldsAndDeliveryVia() {
        let log = EventLog(url: logURL(), instance: "mailbox-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "mailbox-inst")
        let workspace = UUID()
        let surface = UUID()

        EventEmitter.shared.emitMailboxAccepted(
            workspace: workspace,
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            from: "builder",
            to: "watcher",
            body: "deploy green",
            bodyRef: "/tmp/deploy.txt",
            topic: "ci.status",
            replyTo: "builder",
            inReplyTo: "01K3A2B7X8PQRTVWYZ0123456K",
            urgent: true
        )
        EventEmitter.shared.emitMailboxDelivered(
            workspace: workspace,
            id: "01K3A2B7X8PQRTVWYZ0123456J",
            recipient: "watcher",
            surface: surface,
            via: "inbox"
        )
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
        let accepted = events[0]["payload"] as? [String: Any]
        XCTAssertEqual(accepted?["body"] as? String, "deploy green")
        XCTAssertEqual(accepted?["body_ref"] as? String, "/tmp/deploy.txt")
        XCTAssertEqual(accepted?["topic"] as? String, "ci.status")
        XCTAssertEqual(accepted?["reply_to"] as? String, "builder")
        XCTAssertEqual(accepted?["in_reply_to"] as? String, "01K3A2B7X8PQRTVWYZ0123456K")
        XCTAssertEqual(accepted?["urgent"] as? Bool, true)

        let delivered = events[1]["payload"] as? [String: Any]
        XCTAssertEqual(delivered?["via"] as? String, "inbox")
    }

    func testEmitterRecordsResumeModeAndTypedDecisions() {
        let log = EventLog(url: logURL(), instance: "resume-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "resume-inst")
        let ws = UUID()
        let skippedSurface = UUID()
        let commandSurface = UUID()

        XCTAssertTrue(EventEmitter.shared.emitConversationResumeMode(.dirty))
        XCTAssertTrue(EventEmitter.shared.emitConversationResumeDecision(
            workspace: ws,
            surface: skippedSurface,
            kind: "claude-code",
            conversationId: "abc12345-ef67-890a-bcde-f0123456789a",
            mode: .dirty,
            decision: .skip(
                code: .transcriptMissing,
                reason: "transcript not found"
            )
        ))
        XCTAssertTrue(EventEmitter.shared.emitConversationResumeDecision(
            workspace: ws,
            surface: commandSurface,
            kind: "opencode",
            conversationId: "ses_example",
            mode: .dirty,
            decision: .command(ResumeCommand(text: "not persisted"))
        ))
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.count, 3)

        XCTAssertEqual(events[0]["type"] as? String, "conversation.resume.mode")
        let modePayload = events[0]["payload"] as? [String: Any]
        XCTAssertEqual(modePayload?["mode"] as? String, "dirty")

        XCTAssertEqual(events[1]["type"] as? String, "conversation.resume.decision")
        XCTAssertEqual(events[1]["workspace"] as? String, ws.uuidString)
        XCTAssertEqual(events[1]["surface"] as? String, skippedSurface.uuidString)
        let skipPayload = events[1]["payload"] as? [String: Any]
        XCTAssertEqual(skipPayload?["kind"] as? String, "claude-code")
        XCTAssertEqual(
            skipPayload?["conversation_id"] as? String,
            "abc12345-ef67-890a-bcde-f0123456789a"
        )
        XCTAssertEqual(skipPayload?["mode"] as? String, "dirty")
        XCTAssertEqual(skipPayload?["decision"] as? String, "skip")
        XCTAssertEqual(skipPayload?["skip_code"] as? String, "transcript-missing")
        XCTAssertEqual(skipPayload?["reason"] as? String, "transcript not found")

        XCTAssertEqual(events[2]["surface"] as? String, commandSurface.uuidString)
        let commandPayload = events[2]["payload"] as? [String: Any]
        XCTAssertEqual(commandPayload?["decision"] as? String, "command")
        XCTAssertTrue(commandPayload?["skip_code"] is NSNull)
        XCTAssertNil(commandPayload?["command"], "resume command text must not be logged")
    }

    // MARK: - C11-171: set_status mirror emits metadata.changed via the store

    /// The set_status fast path mirrors a canonical `status` write into the
    /// evented `SurfaceMetadataStore` at `.explicit`. This is the seam the fast
    /// path exercises — it must fire a `metadata.changed` event (the v0.58.0
    /// blocker was that set_status wrote only the display store and emitted
    /// nothing).
    func testStatusMirrorThroughStoreEmitsMetadataChanged() {
        let log = EventLog(url: logURL(), instance: "mirror-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "mirror-inst")
        let ws = UUID(), sf = UUID()
        defer { TabMetadataStore.shared.removeSurface(workspaceId: ws, surfaceId: sf) }

        // Only canonical keys mirror; non-canonical display chips do not.
        XCTAssertEqual(TerminalController.sidebarStatusCanonicalMirrorKey("status"), "status")
        XCTAssertNil(TerminalController.sidebarStatusCanonicalMirrorKey("build"))

        // Mirror the canonical status exactly as the fast path does.
        XCTAssertTrue(TabMetadataStore.shared.setInternal(
            workspaceId: ws, surfaceId: sf,
            key: TerminalController.sidebarStatusCanonicalMirrorKey("status")!,
            value: "working", source: .explicit))
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
            .filter { ($0["type"] as? String) == "metadata.changed" }
        XCTAssertEqual(events.count, 1, "one metadata.changed for the mirrored status")
        let payload = events[0]["payload"] as? [String: Any]
        XCTAssertEqual(payload?["key"] as? String, "status")
        XCTAssertEqual(payload?["value"] as? String, "working")
        XCTAssertEqual(payload?["source"] as? String, "explicit")
        XCTAssertEqual(events[0]["surface"] as? String, sf.uuidString)
    }

    /// `progress` mirrors into the store (records a ts, TEL-1) but is
    /// deliberately excluded from the event stream for flood-control, so the
    /// mirror must NOT emit a `metadata.changed` for it.
    func testProgressMirrorDoesNotEmitEvent() {
        let log = EventLog(url: logURL(), instance: "prog-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "prog-inst")
        let ws = UUID(), sf = UUID()
        defer { TabMetadataStore.shared.removeSurface(workspaceId: ws, surfaceId: sf) }

        XCTAssertTrue(TabMetadataStore.shared.setInternal(
            workspaceId: ws, surfaceId: sf,
            key: MetadataKey.progress, value: 0.5, source: .explicit))
        EventEmitter.shared.flush()

        let progressEvents = readLines(logURL()).map(parse)
            .filter { ($0["type"] as? String) == "metadata.changed" }
        XCTAssertTrue(progressEvents.isEmpty, "progress must not flood the event stream")
    }

    func testAttentionEventsUseExactTypesAndPayloadVocabulary() {
        let log = EventLog(url: logURL(), instance: "attention-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "attention-inst")
        let workspace = UUID()
        let surface = UUID()
        let callerSurface = UUID()

        EventEmitter.shared.emitFlagRaised(
            workspace: workspace,
            surface: surface,
            reason: "Needs schema decision",
            callerTabId: callerSurface,
            by: .agent
        )
        EventEmitter.shared.emitFlagLowered(workspace: workspace, surface: surface, by: .operator)
        EventEmitter.shared.emitFlagSuppressed(workspace: workspace, surface: surface, by: .agent)
        EventEmitter.shared.emitFlagUnsuppressed(workspace: workspace, surface: surface, by: .operator)
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(
            events.compactMap { $0["type"] as? String },
            ["flag.raised", "flag.lowered", "flag.suppressed", "flag.unsuppressed"]
        )
        XCTAssertEqual(
            (events[0]["payload"] as? [String: Any])?["reason"] as? String,
            "Needs schema decision"
        )
        XCTAssertEqual(
            (events[0]["payload"] as? [String: Any])?["caller_surface_id"] as? String,
            callerSurface.uuidString
        )
        XCTAssertEqual((events[0]["payload"] as? [String: Any])?["by"] as? String, "agent")
        XCTAssertEqual((events[1]["payload"] as? [String: Any])?["by"] as? String, "operator")
        XCTAssertEqual((events[2]["payload"] as? [String: Any])?["by"] as? String, "agent")
        XCTAssertEqual((events[3]["payload"] as? [String: Any])?["by"] as? String, "operator")
    }
}
