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
        XCTAssertEqual(obj["type"] as? String, "panel.created")
        XCTAssertEqual(obj["instance"] as? String, "inst-1")
        XCTAssertEqual(obj["v"] as? Int, 2)
        XCTAssertEqual(obj["workspace"] as? String, "ws-uuid")
        XCTAssertEqual(obj["panel"] as? String, "sf-uuid")
        XCTAssertNil(obj["surface"], "v2 writes the subject panel under `panel` only")
        XCTAssertNil(obj["area"], "nil refs must be omitted, not encoded as null")
        XCTAssertNil(obj["pane"])
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
        let panel = UUID(uuidString: "6f9619ff-8b86-d011-b42d-00cf4fc964ff")!
        let line = EventEnvelope(
            type: .lifecycleChanged,
            instance: "i",
            ts: Date(timeIntervalSince1970: 1_770_000_123),
            workspace: "9b2d4e6a-1c3f-4a5b-8d7e-2f0a1b3c4d5e",
            surface: panel.uuidString,
            payload: ["tab": panel.uuidString, "agent": "claude-code", "from": "working", "to": "blocked", "reason": "question"]
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
        let panel = JournalTestData.panel
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
            scope: "surface", workspace: workspace, surface: panel,
            key: "status", value: "waiting", prior: "working", source: "fixture")
        XCTAssertEqual(writerBlocked.wait(timeout: .now() + .seconds(1)), .success)

        EventEmitter.shared.emitLifecycleChanged(
            workspace: workspace, panel: panel,
            payload: ["tab": panel.uuidString, "agent": "claude-code", "from": "working", "to": "blocked", "reason": "question"])
        for _ in 0..<8 { releaseWriter.signal() }
        log.flush()
        EventEmitter.shared.emitMetadataChanged(
            scope: "surface", workspace: workspace, surface: panel,
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
        XCTAssertEqual(objs[0]["type"] as? String, "panel.created")
        XCTAssertEqual(objs[0]["panel"] as? String, sf.uuidString)
        XCTAssertNil(objs[0]["surface"])
        XCTAssertEqual(objs[1]["type"] as? String, "metadata.changed")
        let payload = objs[1]["payload"] as? [String: Any]
        XCTAssertEqual(payload?["key"] as? String, "status")
        XCTAssertEqual(payload?["value"] as? String, "working")
        XCTAssertEqual(payload?["prior"] as? String, "idle")
        XCTAssertEqual(payload?["source"] as? String, "explicit")
        XCTAssertEqual(payload?["scope"] as? String, "panel", "the caller's v1 scope is written as v2 `panel`")
    }

    func testPanelInputPayloadRecordsNullCallerAndKeyAttribution() {
        let log = EventLog(url: logURL(), instance: "input-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "input-inst")
        let workspace = UUID()
        let textSurface = UUID()
        let keySurface = UUID()
        let caller = UUID()

        EventEmitter.shared.emitPanelInputSent(
            workspace: workspace,
            surface: textSurface,
            callerPanelId: nil,
            callerTitle: nil,
            targetTitle: "outside target",
            kind: "text",
            text: "hello",
            submitted: true
        )
        EventEmitter.shared.emitPanelInputSent(
            workspace: workspace,
            surface: keySurface,
            callerPanelId: caller,
            callerTitle: "caller",
            targetTitle: "key target",
            kind: "key",
            text: "enter",
            submitted: true
        )
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.map { $0["type"] as? String }, ["panel.input_sent", "panel.input_sent"])

        let textPayload = events[0]["payload"] as? [String: Any]
        XCTAssertTrue(textPayload?["caller_panel_id"] is NSNull)
        XCTAssertNil(textPayload?["caller_tab_id"], "v2 payloads carry only caller_panel_id")
        XCTAssertTrue(textPayload?["caller_title"] is NSNull)
        XCTAssertEqual(textPayload?["target_title"] as? String, "outside target")
        XCTAssertEqual(textPayload?["kind"] as? String, "text")
        XCTAssertEqual(textPayload?["text"] as? String, "hello")
        XCTAssertEqual(textPayload?["bytes"] as? Int, 5)
        XCTAssertEqual(textPayload?["submitted"] as? Bool, true)

        let keyPayload = events[1]["payload"] as? [String: Any]
        XCTAssertEqual(keyPayload?["caller_panel_id"] as? String, caller.uuidString)
        XCTAssertEqual(keyPayload?["caller_title"] as? String, "caller")
        XCTAssertEqual(keyPayload?["kind"] as? String, "key")
        XCTAssertEqual(keyPayload?["text"] as? String, "enter")
    }

    func testPanelInputPayloadRecordsQueuedAndSubmitState() {
        let payload = EventEmitter.panelInputPayload(
            callerPanelId: UUID(),
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

    func testPanelInputPayloadTruncatesBodyAtUTF8Boundary() {
        let text = "a" + String(repeating: "🙂", count: 100_000)
        let payload = EventEmitter.panelInputPayload(
            callerPanelId: nil,
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
        XCTAssertEqual(events[1]["panel"] as? String, skippedSurface.uuidString)
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

        XCTAssertEqual(events[2]["panel"] as? String, commandSurface.uuidString)
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
        defer { PanelMetadataStore.shared.removeSurface(workspaceId: ws, surfaceId: sf) }

        // Only canonical keys mirror; non-canonical display chips do not.
        XCTAssertEqual(TerminalController.sidebarStatusCanonicalMirrorKey("status"), "status")
        XCTAssertNil(TerminalController.sidebarStatusCanonicalMirrorKey("build"))

        // Mirror the canonical status exactly as the fast path does.
        XCTAssertTrue(PanelMetadataStore.shared.setInternal(
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
        XCTAssertEqual(events[0]["panel"] as? String, sf.uuidString)
    }

    /// `progress` mirrors into the store (records a ts, TEL-1) but is
    /// deliberately excluded from the event stream for flood-control, so the
    /// mirror must NOT emit a `metadata.changed` for it.
    func testProgressMirrorDoesNotEmitEvent() {
        let log = EventLog(url: logURL(), instance: "prog-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "prog-inst")
        let ws = UUID(), sf = UUID()
        defer { PanelMetadataStore.shared.removeSurface(workspaceId: ws, surfaceId: sf) }

        XCTAssertTrue(PanelMetadataStore.shared.setInternal(
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
            callerPanelId: callerSurface,
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
        let raisedPayload = events[0]["payload"] as? [String: Any]
        XCTAssertEqual(raisedPayload?["caller_panel_id"] as? String, callerSurface.uuidString)
        XCTAssertNil(raisedPayload?["caller_tab_id"], "v2 flag.raised writes only caller_panel_id")
        XCTAssertNil(raisedPayload?["caller_surface_id"])
        XCTAssertEqual((events[0]["payload"] as? [String: Any])?["by"] as? String, "agent")
        XCTAssertEqual((events[1]["payload"] as? [String: Any])?["by"] as? String, "operator")
        XCTAssertEqual((events[2]["payload"] as? [String: Any])?["by"] as? String, "agent")
        XCTAssertEqual((events[3]["payload"] as? [String: Any])?["by"] as? String, "operator")
    }
}

extension EventLogTests {
    func testWorkspaceSwitchAttributionSerializes() {
        let target = UUID(), caller = UUID()
        let blocked = parse(EventEnvelope(type: .workspaceSwitchBlocked, instance: "fixture", ts: Date(timeIntervalSince1970: 1770000000), workspace: target.uuidString,
            payload: ["target": target.uuidString, "method": "workspace.select", "caller_tab_id": caller.uuidString]).serialize(seq: 1))
        XCTAssertEqual(blocked["type"] as? String, "workspace.switch_blocked")
        let payload = blocked["payload"] as? [String: Any]
        XCTAssertEqual(payload?["caller_tab_id"] as? String, caller.uuidString)
        XCTAssertEqual(payload?["target"] as? String, target.uuidString)
        let selected = parse(EventEnvelope(type: .workspaceSelected, instance: "fixture", ts: Date(timeIntervalSince1970: 1770000000), workspace: target.uuidString,
            payload: ["cause": "sidebar"]).serialize(seq: 2))
        XCTAssertEqual((selected["payload"] as? [String: Any])?["cause"] as? String, "sidebar")
    }
}

// MARK: - C11-337: schema v2 writer and v1/v2 readers

extension EventLogTests {
    private static let v1Line = #"{"instance":"fixture","payload":{"caller_tab_id":"11111111-1111-4111-8111-111111111111","caller_title":"caller","kind":"text","text":"hi"},"pane":"33333333-3333-4333-8333-333333333333","seq":1,"surface":"22222222-2222-4222-8222-222222222222","ts":"2026-10-01T00:00:00.000Z","type":"tab.input_sent","v":1,"workspace":"44444444-4444-4444-8444-444444444444"}"#
    private static let v2Line = #"{"area":"33333333-3333-4333-8333-333333333333","instance":"fixture","panel":"22222222-2222-4222-8222-222222222222","payload":{"caller_panel_id":"11111111-1111-4111-8111-111111111111","caller_title":"caller","kind":"text","text":"hi"},"seq":2,"ts":"2026-10-06T00:00:00.000Z","type":"panel.input_sent","v":2,"workspace":"44444444-4444-4444-8444-444444444444"}"#

    func testV2EnvelopeWritesPanelAndAreaKeysOnly() {
        let line = EventEnvelope(
            type: .surfaceClosed,
            instance: "i",
            ts: Date(timeIntervalSince1970: 1_770_000_000),
            workspace: "ws",
            surface: "panel-ref",
            pane: "area-ref"
        ).serialize(seq: 3)
        let object = parse(line)
        XCTAssertEqual(object["v"] as? Int, EventEnvelope.schemaVersion)
        XCTAssertEqual(EventEnvelope.schemaVersion, 2)
        XCTAssertEqual(object["type"] as? String, "panel.closed")
        XCTAssertEqual(object["panel"] as? String, "panel-ref")
        XCTAssertEqual(object["area"] as? String, "area-ref")
        XCTAssertNil(object["surface"])
        XCTAssertNil(object["pane"])
        XCTAssertEqual(
            Set(object.keys),
            ["seq", "ts", "type", "instance", "v", "workspace", "panel", "area"]
        )
    }

    func testV2TypeNamesForRenamedEvents() {
        XCTAssertEqual(EventEnvelope.EventType.surfaceCreated.rawValue, "panel.created")
        XCTAssertEqual(EventEnvelope.EventType.surfaceClosed.rawValue, "panel.closed")
        XCTAssertEqual(EventEnvelope.EventType.panelInputSent.rawValue, "panel.input_sent")
        // Every alias resolves to a live v2 type, and no v2 type is itself an alias.
        let live = Set(EventEnvelope.EventType.allCases.map(\.rawValue))
        for (legacy, current) in EventEnvelope.legacyTypeAliases {
            XCTAssertTrue(live.contains(current), "\(legacy) must alias a live type")
            XCTAssertFalse(live.contains(legacy), "\(legacy) must not be emitted in v2")
        }
    }

    func testMetadataScopeIsWrittenAsPanelOrArea() {
        let log = EventLog(url: logURL(), instance: "scope-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "scope-inst")
        let ws = UUID(), panel = UUID()
        for scope in ["surface", "pane", "panel", "area"] {
            EventEmitter.shared.emitMetadataChanged(
                scope: scope, workspace: ws, surface: panel,
                key: "title", value: "t", prior: nil, source: "explicit")
        }
        EventEmitter.shared.flush()

        let scopes = readLines(logURL()).map(parse)
            .compactMap { ($0["payload"] as? [String: Any])?["scope"] as? String }
        XCTAssertEqual(scopes, ["panel", "area", "panel", "area"])
        XCTAssertEqual(EventEnvelope.canonicalScope("surface"), "panel")
        XCTAssertEqual(EventEnvelope.canonicalScope("pane"), "area")
        XCTAssertEqual(EventEnvelope.canonicalScope("workspace"), "workspace")
    }

    func testLifecycleChangedEmitterWritesPanelPayloadKey() {
        let log = EventLog(url: logURL(), instance: "lifecycle-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "lifecycle-inst")
        let ws = UUID(), panel = UUID()
        EventEmitter.shared.emitLifecycleChanged(
            workspace: ws, panel: panel,
            payload: ["tab": panel.uuidString, "agent": "claude-code", "from": "working", "to": "blocked", "reason": "question"])
        EventEmitter.shared.flush()

        let object = readLines(logURL()).map(parse).first
        XCTAssertEqual(object?["type"] as? String, "lifecycle.changed")
        XCTAssertEqual(object?["panel"] as? String, panel.uuidString)
        let payload = object?["payload"] as? [String: Any] ?? [:]
        XCTAssertEqual(payload["panel"] as? String, panel.uuidString)
        XCTAssertNil(payload["tab"], "v2 lifecycle payloads carry `panel`, not `tab`")
        XCTAssertEqual(payload["to"] as? String, "blocked")
        XCTAssertEqual(EventEnvelope.lifecyclePanel(inPayload: payload), panel.uuidString)
        XCTAssertEqual(EventEnvelope.lifecyclePanel(inPayload: ["tab": "legacy"]), "legacy")
    }

    func testWorkspaceSelectionEventsCarryCallerPanelId() {
        let log = EventLog(url: logURL(), instance: "select-inst")
        EventEmitter.shared.startForTesting(log: log, instance: "select-inst")
        let target = UUID(), caller = UUID()
        EventEmitter.shared.emitWorkspaceSwitchBlocked(target: target, method: "workspace.select", callerPanelId: caller)
        EventEmitter.shared.emitWorkspaceSelected(previous: nil, selected: target, cause: "socket", method: "workspace.select", callerPanelId: nil)
        EventEmitter.shared.flush()

        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["workspace.switch_blocked", "workspace.selected"])
        let blocked = events[0]["payload"] as? [String: Any] ?? [:]
        XCTAssertEqual(blocked["caller_panel_id"] as? String, caller.uuidString)
        XCTAssertNil(blocked["caller_tab_id"])
        let selected = events[1]["payload"] as? [String: Any] ?? [:]
        XCTAssertTrue(selected["caller_panel_id"] is NSNull)
        XCTAssertNil(selected["caller_tab_id"])
    }

    func testReaderHelpersAcceptV1AndV2Lines() throws {
        for line in [Self.v1Line, Self.v2Line] {
            XCTAssertEqual(EventEnvelope.canonicalType(fromLine: line), "panel.input_sent")
            XCTAssertEqual(EventEnvelope.panelRef(fromLine: line), "22222222-2222-4222-8222-222222222222")
            XCTAssertEqual(EventEnvelope.areaRef(fromLine: line), "33333333-3333-4333-8333-333333333333")
            let object = try XCTUnwrap(EventEnvelope.object(fromLine: line))
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])
            XCTAssertEqual(EventEnvelope.callerPanelId(inPayload: payload), "11111111-1111-4111-8111-111111111111")
        }
        // Raw types are preserved; only the canonical form is shared.
        XCTAssertEqual(EventEnvelope.type(fromLine: Self.v1Line), "tab.input_sent")
        XCTAssertEqual(EventEnvelope.type(fromLine: Self.v2Line), "panel.input_sent")
        // The flag.raised v1 key and null callers.
        XCTAssertEqual(EventEnvelope.callerPanelId(inPayload: ["caller_surface_id": "s"]), "s")
        XCTAssertNil(EventEnvelope.callerPanelId(inPayload: ["caller_panel_id": NSNull()]))
        // Untouched types and junk.
        XCTAssertEqual(EventEnvelope.canonicalType("mailbox.delivered"), "mailbox.delivered")
        XCTAssertNil(EventEnvelope.canonicalType(fromLine: "not json"))
        XCTAssertNil(EventEnvelope.panelRef(fromLine: #"{"type":"log.opened","v":2}"#))
    }

    /// `c11 events tail --filter type=<t>` compares canonical forms on both
    /// sides, so old filter spellings match v2 lines and new ones match v1 lines.
    func testTypeFilterMatchesAcrossSpellings() {
        let v1Created = #"{"seq":1,"surface":"22222222-2222-4222-8222-222222222222","ts":"2026-10-01T00:00:00.000Z","type":"surface.created","v":1}"#
        let v2Created = EventEnvelope(type: .surfaceCreated, instance: "i", ts: Date(), surface: "p").serialize(seq: 2)
        for filter in ["surface.created", "panel.created"] {
            let canonical = EventEnvelope.canonicalType(filter)
            XCTAssertEqual(EventEnvelope.canonicalType(fromLine: v1Created), canonical, filter)
            XCTAssertEqual(EventEnvelope.canonicalType(fromLine: v2Created), canonical, filter)
        }
        for filter in ["tab.input_sent", "panel.input_sent"] {
            let canonical = EventEnvelope.canonicalType(filter)
            XCTAssertEqual(EventEnvelope.canonicalType(fromLine: Self.v1Line), canonical, filter)
            XCTAssertEqual(EventEnvelope.canonicalType(fromLine: Self.v2Line), canonical, filter)
            XCTAssertNotEqual(EventEnvelope.canonicalType(fromLine: v2Created), canonical, filter)
        }
    }
}


extension EventLogTests {
    func testPresenceSnapshotsDeduplicateAndResumeAfterAnalyticsGap() {
        let log = EventLog(url: logURL(), instance: "presence")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "presence")
        emitter.observePresence(appActive: true, screenLocked: false, sleeping: false, snapshot: true)
        emitter.observePresence(appActive: true, screenLocked: false, sleeping: false)
        emitter.observePresence(screenLocked: true)
        emitter.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false))
        emitter.observePresence(appActive: false, screenLocked: false)
        emitter.emitWorkspaceCreated(workspace: UUID(), title: "Hidden", rootDirectory: nil)
        emitter.updatePolicy(ActivityHistoryPolicy())
        emitter.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, [
            "app.activated", "screen.unlocked", "system.wake", "screen.locked",
            "log.policy", "log.policy", "app.deactivated", "screen.unlocked", "system.wake"])
        XCTAssertEqual((events[0]["payload"] as? [String: Any])?["snapshot"] as? Bool, true)
        XCTAssertEqual((events[4]["payload"] as? [String: Any])?["analytics_enabled"] as? Bool, false)
        XCTAssertEqual((events[6]["payload"] as? [String: Any])?["snapshot"] as? Bool, true)
    }

    func testWorkspaceTeardownBalancesRemainingPanelsBeforeClose() {
        let log = EventLog(url: logURL(), instance: "workspaces")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "workspaces")
        let workspace = UUID(), first = UUID(), second = UUID()
        emitter.emitWorkspaceCreated(workspace: workspace, title: "Research", rootDirectory: "/tmp/project")
        emitter.emitSurfaceCreated(workspace: workspace, surface: first, kind: "terminal")
        emitter.emitSurfaceCreated(workspace: workspace, surface: second, kind: "browser")
        emitter.emitWorkspaceRenamed(workspace: workspace, title: "Review", prior: "Research")
        emitter.emitWorkspaceClosed(workspace: workspace, title: "Review", remainingPanels: [first, second])
        emitter.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["workspace.created", "panel.created", "panel.created", "workspace.renamed", "panel.closed", "panel.closed", "workspace.closed"])
        XCTAssertEqual(Set(events[4...5].compactMap { $0["panel"] as? String }), [first.uuidString, second.uuidString])
        XCTAssertEqual((events.last?["payload"] as? [String: Any])?["title"] as? String, "Review")
    }

    func testTextOffRedactsNewInputAndMailboxBodiesCentrally() {
        let log = EventLog(url: logURL(), instance: "privacy")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "privacy")
        emitter.updatePolicy(ActivityHistoryPolicy(keepText: false))
        let workspace = UUID()
        emitter.emitPanelInputSent(workspace: workspace, surface: UUID(), callerPanelId: nil,
                                   callerTitle: nil, targetTitle: "worker", kind: "text", text: "private input", submitted: true)
        emitter.emitMailboxAccepted(workspace: workspace, id: "mail", from: "sender", to: "worker", body: "private body", bodyRef: "/tmp/private", topic: nil)
        emitter.updatePolicy(ActivityHistoryPolicy())
        // Acceptance's durable decision wins over a racing later setting.
        emitter.emitMailboxAccepted(workspace: workspace, id: "mail2", from: "sender", to: nil, body: "also private", topic: nil, textRecorded: false)
        emitter.emitPanelInputSent(workspace: workspace, surface: UUID(), callerPanelId: nil,
                                   callerTitle: nil, targetTitle: "worker", kind: "text", text: "public input", submitted: true)
        emitter.flush()
        let events = readLines(logURL()).map(parse).filter { $0["type"] as? String != "log.policy" }
        for (event, bytes) in zip(events.prefix(3), [13, 12, 12]) {
            let payload = event["payload"] as? [String: Any]
            XCTAssertEqual(payload?["text_recorded"] as? Bool, false)
            XCTAssertEqual(payload?["bytes"] as? Int, bytes)
            XCTAssertNil(payload?["text"])
            XCTAssertNil(payload?["body"])
            XCTAssertNil(payload?["body_ref"])
        }
        XCTAssertEqual((events.last?["payload"] as? [String: Any])?["text"] as? String, "public input")
    }

    func testFullSwitchEndsCoverageAndStopsAllEventWrites() {
        let log = EventLog(url: logURL(), instance: "disabled")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "disabled")
        emitter.updatePolicy(ActivityHistoryPolicy(enabled: false))
        emitter.emitSurfaceClosed(workspace: UUID(), surface: UUID())
        emitter.observePresence(appActive: true)
        emitter.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "log.policy")
        XCTAssertEqual((events[0]["payload"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertFalse(emitter.isRecording)
    }

    func testSpinnerFramesDisappearAndRealTitleChurnKeepsFirstLastCount() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let log = EventLog(url: logURL(), instance: "titles", now: { clock })
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "titles")
        let workspace = UUID(), panel = UUID()
        func title(_ value: String, prior: String? = nil, source: String = "osc") {
            emitter.emitMetadataChanged(scope: "panel", workspace: workspace, surface: panel,
                                        key: "title", value: value, prior: prior, source: source)
        }
        title("⠋ Working")
        for _ in 0..<1000 { title("⠙ Working", prior: "⠋ Working") }
        title("✳ Reading", prior: "⠙ Working")
        title("✓ Done", prior: "✳ Reading")
        // A subsequent structural edge expires the window, without a new timer.
        log.sampleForTesting() // drain queued title changes before advancing the fake clock
        clock.addTimeInterval(61)
        emitter.emitSurfaceClosed(workspace: workspace, surface: panel)
        emitter.flush()
        let events = readLines(logURL()).map(parse)
        let titles = events.filter { $0["type"] as? String == "metadata.changed" }
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual((titles.first?["payload"] as? [String: Any])?["value"] as? String, "⠋ Working")
        XCTAssertEqual((titles.last?["payload"] as? [String: Any])?["value"] as? String, "✓ Done")
        XCTAssertEqual((titles.last?["payload"] as? [String: Any])?["title_change_count"] as? Int, 3)
        XCTAssertEqual(events.last?["type"] as? String, "panel.closed")
    }

    func testSamplingRunsOnWriterQueueSkipsSleepAndOffAndEndsAtShutdown() {
        let log = EventLog(url: logURL(), instance: "samples")
        var calls = 0
        log.startSampling {
            XCTAssertFalse(Thread.isMainThread)
            calls += 1
            return EventEnvelope(type: .instanceSample, instance: "samples", ts: Date(), payload: ["threads": calls])
        }
        log.sampleForTesting()
        log.setSamplingAsleep(true)
        log.sampleForTesting()
        log.setSamplingAsleep(false)
        log.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false))
        log.sampleForTesting()
        log.updatePolicy(ActivityHistoryPolicy())
        log.sampleForTesting()
        log.finishSampling { EventEnvelope(type: .instanceSample, instance: "samples", ts: Date(), payload: ["shutdown": true]) }
        XCTAssertEqual(calls, 2)
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual((events.last?["payload"] as? [String: Any])?["shutdown"] as? Bool, true)
    }

    func testHangContextUsesCachedPresenceAndCurrentProcessRSS() {
        let log = EventLog(url: logURL(), instance: "hang")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "hang")
        emitter.observePresence(appActive: true, screenLocked: false)
        emitter.emitHangPrecursor(cause: "socket", culprit: nil, count: 3, windowMs: 1000, spanMs: 500,
                                  durationsMs: [100, 200, 200], fingerprint: ["sample"])
        emitter.flush()
        let event = readLines(logURL()).map(parse).last
        let payload = event?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["app_active"] as? Bool, true)
        XCTAssertEqual(payload?["screen_locked"] as? Bool, false)
        XCTAssertGreaterThan(payload?["rss_mb"] as? Double ?? 0, 0)
    }

    func testRotationRetainsSeveralGenerationsWithinDirectoryBudgetAndAge() throws {
        let date = Date()
        let url = logURL("events-budget.ndjson")
        let stale = logURL("events-old.ndjson.2")
        let unrelated = logURL("other-data.ndjson")
        try Data(repeating: 120, count: 500).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-15 * 86_400)], ofItemAtPath: stale.path)
        try Data("preserve".utf8).write(to: unrelated)
        let log = EventLog(url: url, instance: "budget", sizeCap: 500, totalSizeCap: 2400, now: { date })
        log.open()
        for index in 0..<30 {
            log.append(EventEnvelope(type: .surfaceCreated, instance: "budget", ts: date, payload: ["n": index, "title": String(repeating: "x", count: 100)]))
        }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("events-") }
        XCTAssertGreaterThan(files.count, 2)
        XCTAssertLessThanOrEqual(try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }, 2400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "preserve")
    }

    func testOversizedRecordDoesNotExceedBudget() throws {
        let log = EventLog(url: logURL(), instance: "oversized", sizeCap: 8192, totalSizeCap: 512)
        log.append(EventEnvelope(type: .panelInputSent, instance: "oversized", ts: Date(), payload: ["text": String(repeating: "x", count: 2048)]))
        log.flush()
        let values = try logURL().resourceValues(forKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(values.fileSize ?? 0, 512)
    }
}


extension EventLogTests {
    func testHistoryDirectoryOverrideAndExactGenerationRecognition() {
        let state = URL(fileURLWithPath: "/tmp/history-state")
        XCTAssertEqual(EventLogLayout.eventsDirectoryURL(state: state, directoryOverride: "/tmp/isolated-history").path, "/tmp/isolated-history")
        XCTAssertEqual(EventLogLayout.eventsDirectoryURL(state: state, directoryOverride: "relative").path, "/tmp/history-state/events")
        for name in ["events-test.ndjson", "events-test.ndjson.1", "events-test.ndjson.25"] {
            XCTAssertTrue(EventLogLayout.isLogFileName(name))
        }
        for name in ["events-.ndjson", "events-test.ndjson.bad", "events-test.ndjson.0", "unrelated.ndjson", "events-test.ndjson.1.extra"] {
            XCTAssertFalse(EventLogLayout.isLogFileName(name))
        }
    }

    func testCustomLogPathStillRetainsAndPrunesItsOwnGenerations() throws {
        let url = logURL("custom.log")
        let log = EventLog(url: url, instance: "custom", sizeCap: 400, totalSizeCap: 1800)
        log.open()
        for index in 0..<30 {
            log.append(EventEnvelope(type: .surfaceCreated, instance: "custom", ts: Date(), payload: ["n": index, "title": String(repeating: "x", count: 100)]))
        }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertGreaterThan(files.count, 2)
        XCTAssertLessThanOrEqual(try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }, 1800)
    }
}


extension EventLogTests {
    func testTwoWritersShareOneHistoryDirectoryBudget() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstURL = logURL("events-first-\(pid).ndjson")
        let secondURL = logURL("events-second-\(pid).ndjson")
        let budget = 2400
        let first = EventLog(url: firstURL, instance: "first", sizeCap: 500, totalSizeCap: budget)
        let second = EventLog(url: secondURL, instance: "second", sizeCap: 500, totalSizeCap: budget)
        first.open(); second.open()
        first.flush(); second.flush() // both writers know the initial small total
        let producers = DispatchGroup()
        for log in [first, second] {
            producers.enter()
            DispatchQueue.global().async {
                for index in 0..<100 {
                    log.append(EventEnvelope(type: .surfaceCreated, instance: "writer", ts: Date(),
                        payload: ["n": index, "title": String(repeating: "x", count: 100)]))
                }
                log.flush()
                producers.leave()
            }
        }
        XCTAssertEqual(producers.wait(timeout: .now() + 10), .success)
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { EventLogLayout.isLogFileName($0.lastPathComponent) }
        XCTAssertLessThanOrEqual(try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }, budget)
        XCTAssertFalse(readLines(firstURL).isEmpty)
        XCTAssertFalse(readLines(secondURL).isEmpty)
    }
}


extension EventLogTests {
    func testSymlinkedHistoryDirectoryProtectsCurrentAndShiftsGenerations() throws {
        let target = tempDir.appendingPathComponent("history-real", isDirectory: true)
        let alias = tempDir.appendingPathComponent("history-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let url = alias.appendingPathComponent("events-symlink.ndjson")
        // Newly created files have wall-clock mtimes. An advanced retention
        // clock exposes a mistaken failure to protect our own current file.
        let future = Date().addingTimeInterval(60 * 86_400)
        let log = EventLog(url: url, instance: "symlink", sizeCap: 500, totalSizeCap: 4096, now: { future })
        log.open()
        log.append(EventEnvelope(type: .surfaceCreated, instance: "symlink", ts: future))
        log.flush()
        XCTAssertFalse(readLines(url).isEmpty)

        // Use a wall-clock writer to exercise generation shifts through the
        // same alias without intentionally aging out every archived file.
        let rotating = EventLog(url: alias.appendingPathComponent("events-generations.ndjson"),
                                instance: "generations", sizeCap: 500, totalSizeCap: 4096)
        rotating.open()
        for index in 0..<12 {
            rotating.append(EventEnvelope(type: .surfaceCreated, instance: "generations", ts: Date(),
                payload: ["n": index, "title": String(repeating: "x", count: 100)]))
        }
        rotating.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotating.url.path + ".2"))
        XCTAssertFalse(readLines(rotating.url).isEmpty)
    }

    func testAnalyticsOffKeepsOriginalHangWithoutNewHealthContext() {
        var metricQueries = 0
        let log = EventLog(url: logURL(), instance: "hang-off", healthMetrics: {
            XCTAssertFalse(Thread.isMainThread)
            metricQueries += 1
            return ["rss_mb": 42]
        })
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "hang-off")
        emitter.observePresence(appActive: true, screenLocked: false)
        emitter.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false))
        emitter.emitHangPrecursor(cause: "socket", culprit: "worker", count: 3,
                                  windowMs: 1000, spanMs: 500, durationsMs: [100, 200, 200], fingerprint: ["sample"])
        emitter.flush()
        let event = readLines(logURL()).map(parse).last
        XCTAssertEqual(event?["type"] as? String, "hang.precursor")
        let payload = event?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["cause"] as? String, "socket")
        XCTAssertEqual(payload?["culprit"] as? String, "worker")
        XCTAssertEqual(payload?["count"] as? Int, 3)
        XCTAssertNil(payload?["app_active"])
        XCTAssertNil(payload?["screen_locked"])
        XCTAssertNil(payload?["rss_mb"])
        XCTAssertEqual(metricQueries, 0)
        emitter.updatePolicy(ActivityHistoryPolicy())
        emitter.emitHangPrecursor(cause: "socket", culprit: nil, count: 3,
                                  windowMs: 1000, spanMs: 500, durationsMs: [100, 200, 200], fingerprint: ["sample"])
        emitter.flush()
        XCTAssertEqual(metricQueries, 1)
        let enabledPayload = readLines(logURL()).map(parse).last?["payload"] as? [String: Any]
        XCTAssertEqual(enabledPayload?["rss_mb"] as? Int, 42)
    }
}
