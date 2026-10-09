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
        let stale = URL(fileURLWithPath: url.path + ".7")
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
        let firstURL = logURL("events-shared-\(pid).ndjson")
        let secondURL = logURL("events-shared-\(pid + 1).ndjson")
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
        // Coordination is nonblocking. Reconciliation after the concurrent
        // burst restores the shared build target when the lock is available.
        first.sampleForTesting()
        second.sampleForTesting()
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


extension EventLogTests {
    func testRepeatedReceiptReadDrainsDoNotEndTitleCoalescingWindow() {
        let log = EventLog(url: logURL(), instance: "receipt-drain")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "receipt-drain")
        let workspace = UUID(), panel = UUID()
        func title(_ value: String, prior: String? = nil) {
            emitter.emitMetadataChanged(scope: "panel", workspace: workspace, surface: panel,
                                        key: "title", value: value, prior: prior, source: "osc")
        }
        title("First")
        title("Second", prior: "First")
        // MailboxReceiptRecorder drains the emitter before reading. Repeated
        // reads must not turn one window into multiple first/last pairs.
        for _ in 0..<3 {
            emitter.flush()
            let interimTitles = readLines(logURL()).map(parse)
                .filter { $0["type"] as? String == "metadata.changed" }
            XCTAssertEqual(interimTitles.count, 1)
            XCTAssertEqual((interimTitles.first?["payload"] as? [String: Any])?["value"] as? String, "First")
        }
        title("Third", prior: "Second")
        emitter.emitSurfaceClosed(workspace: workspace, surface: panel)
        emitter.flush()
        let events = readLines(logURL()).map(parse)
        let titles = events.filter { $0["type"] as? String == "metadata.changed" }
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual((titles.first?["payload"] as? [String: Any])?["value"] as? String, "First")
        XCTAssertEqual((titles.last?["payload"] as? [String: Any])?["value"] as? String, "Third")
        XCTAssertEqual((titles.last?["payload"] as? [String: Any])?["title_change_count"] as? Int, 3)
        XCTAssertEqual(events.last?["type"] as? String, "panel.closed")
    }
}


extension EventLogTests {
    func testNativeHealthSampleCPUAgreesWithIndependentResourceUsage() {
        let log = EventLog(url: logURL(), instance: "native-cpu")
        func resourceUsageCPU() -> Double {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var lower = 0.0, upper = 0.0
        log.startSampling {
            XCTAssertFalse(Thread.isMainThread)
            lower = resourceUsageCPU()
            let metrics = ActivityHistoryMetrics.sample()
            upper = resourceUsageCPU()
            return EventEnvelope(type: .instanceSample, instance: "native-cpu", ts: Date(), payload: metrics)
        }
        log.sampleForTesting()
        log.stopSampling()
        let payload = readLines(logURL()).map(parse).last?["payload"] as? [String: Any]
        let sampled = payload?["cpu_s_total"] as? Double ?? -.infinity
        // Independent timevals bracket the query; allow only scheduling and
        // kernel-accounting quantization, with no busy loop or timing sleep.
        XCTAssertGreaterThanOrEqual(sampled, lower - 0.001)
        XCTAssertLessThanOrEqual(sampled, upper + 0.001)
        XCTAssertGreaterThan(payload?["rss_mb"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(payload?["threads"] as? Int ?? 0, 0)
    }
}

extension EventLogTests {
    private func appendOSCTitle(_ value: String, prior: String? = nil, panel: String = "panel", to log: EventLog) {
        var payload: [String: Any] = ["key": "title", "value": value, "source": "osc", "scope": "panel"]
        if let prior { payload["prior"] = prior }
        log.append(EventEnvelope(type: .metadataChanged, instance: "titles", ts: Date(), surface: panel, payload: payload))
    }

    func testCombinedDeadlineFlushesIdleTitleWithAnalyticsOffWithoutHealthQuery() {
        var clock = Date()
        var healthCalls = 0
        let log = EventLog(url: logURL(), instance: "idle-title", now: { clock })
        log.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false))
        log.startSampling { healthCalls += 1; return nil }
        appendOSCTitle("First", to: log)
        appendOSCTitle("Last", prior: "First", to: log)
        log.flush()
        XCTAssertEqual(readLines(logURL()).count, 1)
        clock.addTimeInterval(59)
        log.fireDeadlineForTesting()
        XCTAssertEqual(readLines(logURL()).count, 1)
        clock.addTimeInterval(1)
        log.fireDeadlineForTesting()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual((events.last?["payload"] as? [String: Any])?["value"] as? String, "Last")
        XCTAssertEqual((events.last?["payload"] as? [String: Any])?["title_change_count"] as? Int, 2)
        XCTAssertEqual(healthCalls, 0)
    }

    func testNonOSCTitleDescriptionAndStatusFollowPendingTitleTailInSequence() {
        let log = EventLog(url: logURL(), instance: "causality")
        for key in ["title", "description", "status"] {
            appendOSCTitle("First-\(key)", to: log)
            appendOSCTitle("Last-\(key)", prior: "First-\(key)", to: log)
            log.append(EventEnvelope(type: .metadataChanged, instance: "causality", ts: Date(), surface: "panel",
                payload: ["key": key, "value": "Declared-\(key)", "source": "explicit"]))
        }
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.count, 9)
        for (index, key) in ["title", "description", "status"].enumerated() {
            let values = events.dropFirst(index * 3).prefix(3).map { ($0["payload"] as? [String: Any])?["value"] as? String }
            XCTAssertEqual(values, ["First-\(key)", "Last-\(key)", "Declared-\(key)"])
        }
        XCTAssertEqual(events.compactMap { $0["seq"] as? Int }, Array(1...9))
    }

    func testFiveSecondOSCTitlesKeepOneWindowAcrossTenSecondInputAndThirtySecondMail() {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        var clock = start
        let log = EventLog(url: logURL(), instance: "synthetic-interleaving", now: { clock },
                           policy: ActivityHistoryPolicy(analyticsEnabled: false))
        defer { log.stopSampling() }
        for second in stride(from: 0, through: 55, by: 5) {
            clock = start.addingTimeInterval(Double(second))
            var payload: [String: Any] = ["key": "title", "value": "Step \(second)", "source": "osc", "scope": "panel"]
            if second > 0 { payload["prior"] = "Step \(second - 5)" }
            log.append(EventEnvelope(type: .metadataChanged, instance: "synthetic-interleaving", ts: clock,
                                     surface: "panel", payload: payload))
            if second > 0, second.isMultiple(of: 10) {
                log.append(EventEnvelope(type: .panelInputSent, instance: "synthetic-interleaving", ts: clock,
                                         surface: "panel", payload: ["kind": "text", "bytes": 1, "submitted": true]))
            }
            if second == 30 {
                log.append(EventEnvelope(type: .mailboxAccepted, instance: "synthetic-interleaving", ts: clock,
                                         surface: "panel", payload: ["id": "synthetic-mail", "bytes": 1, "text_recorded": false]))
                log.append(EventEnvelope(type: .mailboxDelivered, instance: "synthetic-interleaving", ts: clock,
                                         surface: "panel", payload: ["id": "synthetic-mail", "via": "drain"]))
            }
            log.flush()
            let events = readLines(logURL()).map(parse)
            XCTAssertEqual(events.filter { $0["type"] as? String == "metadata.changed" }.count, 1,
                           "Input and mailbox events must not end the sixty-second OSC window")
            XCTAssertEqual(events.count, 1 + second / 10 + (second >= 30 ? 2 : 0),
                           "Every unrelated event must be readable at its own queue drain")
        }
        clock = start.addingTimeInterval(58)
        log.append(EventEnvelope(type: .livenessDerived, instance: "synthetic-interleaving", ts: clock,
                                 surface: "panel", payload: ["state": "working"]))
        log.flush()
        XCTAssertEqual(readLines(logURL()).map(parse).last?["type"] as? String, "liveness.derived")
        clock = start.addingTimeInterval(59)
        log.fireDeadlineForTesting()
        XCTAssertEqual(readLines(logURL()).count, 9)
        clock = start.addingTimeInterval(60)
        log.fireDeadlineForTesting()
        let events = readLines(logURL()).map(parse)
        let titles = events.filter { $0["type"] as? String == "metadata.changed" }
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual((titles.first?["payload"] as? [String: Any])?["value"] as? String, "Step 0")
        XCTAssertNil((titles.first?["payload"] as? [String: Any])?["last_changed_at"])
        let tail = titles.last?["payload"] as? [String: Any]
        XCTAssertEqual(tail?["value"] as? String, "Step 55")
        XCTAssertEqual(tail?["title_change_count"] as? Int, 12)
        XCTAssertEqual(tail?["last_changed_at"] as? String, EventEnvelope.formatTimestamp(start.addingTimeInterval(55)))
        XCTAssertEqual(events.last?["ts"] as? String, EventEnvelope.formatTimestamp(start.addingTimeInterval(55)),
                       "The tail records the actual last title change, not its sixty-second write deadline")
        XCTAssertEqual(events.compactMap { $0["seq"] as? Int }, Array(1...10))
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, [
            "metadata.changed", "panel.input_sent", "panel.input_sent", "panel.input_sent",
            "mailbox.accepted", "mailbox.delivered", "panel.input_sent", "panel.input_sent",
            "liveness.derived", "metadata.changed"
        ])
        log.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-interleaving", ts: clock, surface: "panel"))
        log.flush()
        XCTAssertEqual(readLines(logURL()).count, 11, "Close after expiry must not duplicate the title tail")
    }

    func testNonOSCTitleReplacementAndClearFlushOnlyTheAffectedPanelWindow() {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        for source in ["explicit", "declare", "derived", "heuristic"] {
            for clear in [false, true] {
                let url = logURL("title-boundary-\(source)-\(clear).ndjson")
                var clock = start
                let log = EventLog(url: url, instance: "synthetic-title-boundary", now: { clock })
                func title(_ value: String, panel: String) {
                    log.append(EventEnvelope(type: .metadataChanged, instance: "synthetic-title-boundary", ts: clock,
                                             surface: panel, payload: ["key": "title", "value": value, "source": "osc", "scope": "panel"]))
                }
                title("First", panel: "panel")
                title("Other first", panel: "other-panel")
                log.flush()
                clock = start.addingTimeInterval(5)
                title("Last", panel: "panel")
                title("Other last", panel: "other-panel")
                log.flush()
                clock = start.addingTimeInterval(10)
                let replacement: Any = clear ? NSNull() : "Replacement"
                log.append(EventEnvelope(type: .panelInputSent, instance: "synthetic-title-boundary", ts: clock,
                                         surface: "panel", payload: ["kind": "text", "bytes": 1]))
                log.append(EventEnvelope(type: .metadataChanged, instance: "synthetic-title-boundary", ts: clock,
                                         surface: "panel", payload: ["key": "title", "value": replacement,
                                                                   "source": source, "scope": "panel"]))
                log.flush()
                let beforeClose = readLines(url).map(parse)
                XCTAssertEqual(beforeClose.compactMap { $0["type"] as? String }, [
                    "metadata.changed", "metadata.changed", "panel.input_sent", "metadata.changed", "metadata.changed"
                ])
                let tail = beforeClose[3]["payload"] as? [String: Any]
                XCTAssertEqual(tail?["value"] as? String, "Last")
                XCTAssertEqual(tail?["title_change_count"] as? Int, 2)
                XCTAssertEqual(tail?["last_changed_at"] as? String, EventEnvelope.formatTimestamp(start.addingTimeInterval(5)))
                XCTAssertEqual((beforeClose[4]["payload"] as? [String: Any])?["source"] as? String, source)
                if clear { XCTAssertTrue((beforeClose[4]["payload"] as? [String: Any])?["value"] is NSNull) }
                else { XCTAssertEqual((beforeClose[4]["payload"] as? [String: Any])?["value"] as? String, "Replacement") }
                log.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-title-boundary", ts: clock, surface: "other-panel"))
                log.flush()
                let events = readLines(url).map(parse)
                XCTAssertEqual(events.count, 7)
                XCTAssertEqual(events.compactMap { $0["seq"] as? Int }, Array(1...7))
                XCTAssertEqual((events[5]["payload"] as? [String: Any])?["value"] as? String, "Other last",
                               "A title replacement on one panel must preserve the other panel's pending tail")
                XCTAssertEqual(events.last?["type"] as? String, "panel.closed")
                log.stopSampling()
            }
        }
    }

    func testPolicyBoundariesFlushPendingTitleBeforeMarkerIncludingFullDisable() {
        let policies = [ActivityHistoryPolicy(keepText: false), ActivityHistoryPolicy(analyticsEnabled: false), ActivityHistoryPolicy(enabled: false)]
        for (index, policy) in policies.enumerated() {
            let url = logURL("policy-\(index).ndjson")
            let log = EventLog(url: url, instance: "policy")
            EventEmitter.shared.startForTesting(log: log, instance: "policy")
            appendOSCTitle("First", to: log)
            appendOSCTitle("Last", prior: "First", to: log)
            EventEmitter.shared.updatePolicy(policy)
            log.flush()
            let events = readLines(url).map(parse)
            XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["metadata.changed", "metadata.changed", "log.policy"])
            XCTAssertEqual((events[1]["payload"] as? [String: Any])?["value"] as? String, "Last")
            EventEmitter.shared.resetForTesting()
        }
    }

    func testWorkspaceCloseFlushesTitleWithoutRequiringPanelCloseAndSleepSuspendsDeadline() {
        var clock = Date()
        let log = EventLog(url: logURL(), instance: "sleep-title", now: { clock })
        appendOSCTitle("First", to: log)
        appendOSCTitle("Last", prior: "First", to: log)
        log.setSamplingAsleep(true)
        log.flush()
        clock.addTimeInterval(61)
        log.fireDeadlineForTesting()
        XCTAssertEqual(readLines(logURL()).count, 1)
        log.setSamplingAsleep(false)
        log.append(EventEnvelope(type: .workspaceClosed, instance: "sleep-title", ts: clock, workspace: "workspace"))
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["metadata.changed", "metadata.changed", "workspace.closed"])
    }

    func testSpinnerPrefixesPreservePathsAndTildeWhileDroppingOnlyStatusFrames() {
        let log = EventLog(url: logURL(), instance: "glyphs")
        let fixtures = [
            ("/src", "~/src", true), ("~/src", "/src", true),
            ("/ task", "- task", false), ("- task", "\\ task", false),
            ("\\ task", "| task", false), ("⠋ task", "⠙ task", false),
            ("✓ /src", "⠋ ~/src", true), ("/src", "\\src", true),
        ]
        for (index, fixture) in fixtures.enumerated() {
            appendOSCTitle(fixture.1, prior: fixture.0, panel: "panel-\(index)", to: log)
        }
        log.finishSampling { nil }
        let values = readLines(logURL()).map(parse).compactMap { ($0["payload"] as? [String: Any])?["value"] as? String }
        XCTAssertEqual(values, fixtures.filter { $0.2 }.map { $0.1 })
    }

    func testFailedOversizedWriteConsumesNoSequenceNotificationOrDeliveryAcknowledgment() {
        let log = EventLog(url: logURL(), instance: "write-results", sizeCap: 1024, totalSizeCap: 4096)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: EventLog.eventWrittenNotification, object: nil, queue: nil) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        log.append(EventEnvelope(type: .mailboxDelivered, instance: "write-results", ts: Date(), payload: [
            "id": "lost", "via": "drain", "extra": String(repeating: "x", count: 5000),
        ]))
        log.append(EventEnvelope(type: .mailboxDelivered, instance: "write-results", ts: Date(), payload: ["id": "kept", "via": "drain"]))
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["log.dropped", "mailbox.delivered"])
        XCTAssertEqual(events.compactMap { $0["seq"] as? Int }, [1, 2])
        XCTAssertEqual((events.first?["payload"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(log.confirmedDrainDeliveryIDs(["lost", "kept"]), ["kept"])
    }

    func testShutdownBarrierIsBoundedWhenWriterIsStalled() {
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let log = EventLog(url: logURL(), instance: "stalled-shutdown")
        log.onQueueBeforeWrite = { entered.signal(); gate.wait() }
        log.append(EventEnvelope(type: .surfaceCreated, instance: "stalled-shutdown", ts: Date()))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let began = Date()
        log.finishSampling { nil }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        gate.signal()
        log.flush()
    }

    func testFeedAnswerAndSuppliedMailboxTrueCannotOverrideCurrentTextOptOut() {
        let log = EventLog(url: logURL(), instance: "central-privacy")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "central-privacy")
        emitter.updatePolicy(ActivityHistoryPolicy(keepText: false))
        emitter.emitFlagLowered(workspace: UUID(), surface: UUID(), by: .operator, answer: "PRIVATE_ANSWER")
        XCTAssertFalse(emitter.emitMailboxAccepted(workspace: UUID(), id: "mail", from: "sender", to: "recipient",
            body: "PRIVATE_BODY", topic: nil, textRecorded: true))
        emitter.flush()
        let events = readLines(logURL()).map(parse).filter { $0["type"] as? String != "log.policy" }
        XCTAssertEqual(events.count, 2)
        let answer = events[0]["payload"] as? [String: Any]
        XCTAssertNil(answer?["answer"])
        XCTAssertEqual(answer?["answer_bytes"] as? Int, "PRIVATE_ANSWER".utf8.count)
        XCTAssertEqual(answer?["text_recorded"] as? Bool, false)
        let mailbox = events[1]["payload"] as? [String: Any]
        XCTAssertNil(mailbox?["body"])
        XCTAssertEqual(mailbox?["text_recorded"] as? Bool, false)
    }

    func testFirstEnableAfterDisabledLaunchOpensExactlyOnce() {
        let log = EventLog(url: logURL(), instance: "first-enable")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "first-enable", policy: ActivityHistoryPolicy(enabled: false), opened: false)
        emitter.updatePolicy(ActivityHistoryPolicy())
        emitter.updatePolicy(ActivityHistoryPolicy())
        emitter.flush()
        XCTAssertEqual(readLines(logURL()).map(parse).filter { $0["type"] as? String == "log.opened" }.count, 1)
    }

    func testNormalAppendsDoNotReconcileHistoryDirectory() {
        let log = EventLog(url: logURL(), instance: "cached-budget")
        var reconciliations = 0
        log.onHistoryReconcile = { reconciliations += 1 }
        log.open()
        log.flush()
        XCTAssertEqual(reconciliations, 1)
        for _ in 0..<100 {
            log.append(EventEnvelope(type: .surfaceCreated, instance: "cached-budget", ts: Date()))
        }
        log.flush()
        XCTAssertEqual(reconciliations, 1)
        XCTAssertEqual(readLines(logURL()).count, 101)
    }

    func testOffPolicyAndShutdownPruneHistoryWithoutWritingActivity() throws {
        let url = logURL("events-off-7001.ndjson")
        let stale = logURL("events-off-7000.ndjson.1")
        func seedStale() throws {
            try Data("old history".utf8).write(to: stale)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * 86_400)], ofItemAtPath: stale.path)
        }
        try seedStale()
        let log = EventLog(url: url, instance: "off-7001")
        log.updatePolicy(ActivityHistoryPolicy(enabled: false))
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try seedStale()
        log.finishSampling { XCTFail("Disabled shutdown must not sample"); return nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDisabledStartupPrunesAgedExactCurrentFileWithoutLiveWriter() throws {
        let url = logURL("events-reused-pid-7001.ndjson")
        try Data("abandoned prior process history".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * 86_400)], ofItemAtPath: url.path)
        let log = EventLog(url: url, instance: "reused-pid-7001")
        log.updatePolicy(ActivityHistoryPolicy(enabled: false))
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPendingDropsStaySilentAfterDisableUntilRecordingResumes() {
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let log = EventLog(url: logURL(), instance: "off-drops", maxPending: 1)
        log.onQueueBeforeWrite = { entered.signal(); gate.wait() }
        log.append(EventEnvelope(type: .surfaceCreated, instance: "off-drops", ts: Date()))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        log.append(EventEnvelope(type: .surfaceCreated, instance: "off-drops", ts: Date())) // sheds while pinned
        log.updatePolicy(ActivityHistoryPolicy(enabled: false))
        gate.signal()
        log.flush()
        // The barrier proves the hook is no longer running. A stale emitter
        // snapshot may enqueue after disable; it must not publish drop counts.
        log.onQueueBeforeWrite = nil
        log.append(EventEnvelope(type: .surfaceCreated, instance: "off-drops", ts: Date()))
        log.flush()
        XCTAssertEqual(readLines(logURL()).map(parse).compactMap { $0["type"] as? String }, ["panel.created"])
        log.updatePolicy(ActivityHistoryPolicy())
        log.append(EventEnvelope(type: .surfaceCreated, instance: "off-drops", ts: Date()))
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["panel.created", "log.dropped", "panel.created"])
        XCTAssertEqual((events.dropFirst().first?["payload"] as? [String: Any])?["count"] as? Int, 1)
    }

    /// A real second process owns the exact descriptor flock. Pipes publish
    /// acquisition and release; timeout cleanup always terminates the child.
    private func withExternalFileLocks(at urls: [URL], exclusive: Bool, _ body: () throws -> Void) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
        import fcntl, os, sys
        handles = [open(path, 'a+b') for path in sys.argv[2:]]
        for handle in handles:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX if sys.argv[1] == 'exclusive' else fcntl.LOCK_SH)
        os.write(1, b'ready\\n')
        if os.read(0, 1) != b'q':
            sys.exit(2)
        os.write(1, b'released\\n')
        """, exclusive ? "exclusive" : "shared"] + urls.map(\.path)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        func expect(_ expected: String) throws {
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result = Data()
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readData(ofLength: expected.utf8.count)
                lock.lock(); result = data; lock.unlock()
                done.signal()
            }
            guard done.wait(timeout: .now() + 5) == .success else {
                XCTFail("External flock handshake timed out")
                throw CocoaError(.fileReadUnknown)
            }
            lock.lock(); let received = result; lock.unlock()
            XCTAssertEqual(String(decoding: received, as: UTF8.self), expected)
            guard received == Data(expected.utf8) else { throw CocoaError(.fileReadUnknown) }
        }
        try expect("ready\n")
        try body()
        try input.fileHandleForWriting.write(contentsOf: Data("q".utf8))
        try expect("released\n")
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testExternalRetentionLockNeverBlocksOrDropsWritesAndPublishesOneEpisode() throws {
        let lockURL = tempDir.appendingPathComponent(".activity-history.lock")
        let log = EventLog(url: logURL("events-contention-7001.ndjson"), instance: "contention-7001")
        try withExternalFileLocks(at: [lockURL], exclusive: true) {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                log.open()
                log.append(EventEnvelope(type: .surfaceCreated, instance: "contention-7001", ts: Date()))
                log.flush()
                completed.signal()
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 1), .success, "A foreign lock must not stall the writer")
            log.sampleForTesting()
            log.sampleForTesting()
            let events = readLines(log.url).map(parse)
            XCTAssertTrue(events.contains { $0["type"] as? String == "panel.created" })
            XCTAssertFalse(events.contains { $0["type"] as? String == "log.dropped" })
            let markers = events.filter { $0["type"] as? String == "log.retention" }
            XCTAssertEqual(markers.count, 1)
            XCTAssertEqual((markers.first?["payload"] as? [String: Any])?["state"] as? String, "degraded")
            XCTAssertEqual((markers.first?["payload"] as? [String: Any])?["reason"] as? String, "lock_busy")
        }
        log.sampleForTesting()
        let markers = readLines(log.url).map(parse).filter { $0["type"] as? String == "log.retention" }
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual((markers.last?["payload"] as? [String: Any])?["state"] as? String, "recovered")
    }

    func testUnavailableRetentionLockKeepsWritingWithExplicitDegradedMarker() throws {
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".activity-history.lock"), withIntermediateDirectories: true)
        let log = EventLog(url: logURL(), instance: "unavailable")
        log.open()
        log.append(EventEnvelope(type: .surfaceCreated, instance: "unavailable", ts: Date()))
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertTrue(events.contains { $0["type"] as? String == "panel.created" })
        let marker = events.first { $0["type"] as? String == "log.retention" }
        XCTAssertEqual((marker?["payload"] as? [String: Any])?["reason"] as? String, "lock_unavailable")
        XCTAssertFalse(events.contains { $0["type"] as? String == "log.dropped" })
    }

    func testRetentionUsesBuildLabelAndKernelWriterLivenessWithoutTouchingForeignProduction() throws {
        let label = "com.stage11.c11.debug.c11.349"
        let url = logURL("events-\(label)-7001.ndjson")
        let staleOwn = logURL("events-\(label)-7000.ndjson.2")
        let liveOwn = logURL("events-\(label)-7002.ndjson")
        let staleDebug = logURL("events-com.stage11.c11.debug.other-7000.ndjson")
        let youngDebug = logURL("events-com.stage11.c11.debug.young-7000.ndjson")
        let production = logURL("events-com.stage11.c11-7000.ndjson.2")
        let nightly = logURL("events-com.stage11.c11.nightly-7000.ndjson.2")
        for file in [staleOwn, liveOwn, staleDebug, youngDebug, production, nightly] {
            try Data("preserved bytes".utf8).write(to: file)
            let age = file == youngDebug ? 8 : 30
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(age) * 86_400)], ofItemAtPath: file.path)
        }
        let log = EventLog(url: url, instance: "\(label)-7001", retentionDays: 7)
        try withExternalFileLocks(at: [liveOwn, staleDebug], exclusive: false) {
            log.open()
            log.flush()
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleOwn.path))
            for file in [liveOwn, staleDebug, youngDebug, production, nightly] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
            }
        }
        log.sampleForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveOwn.path), "Kernel releases the writer lock at child exit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDebug.path), "Dead foreign debug history has a fixed14-day TTL")
        for file in [youngDebug, production, nightly] {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserved bytes")
        }
    }
}


extension EventLogTests {
    func testUnavailableWriterLivenessKeepsRecordsProtectsCurrentFilesAndRecovers() throws {
        for failure in [ENOTSUP, ENOLCK] {
            let directory = tempDir.appendingPathComponent("synthetic-lock-\(failure)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = directory.appendingPathComponent("events-synthetic-lock-7001.ndjson")
            let otherCurrent = directory.appendingPathComponent("events-synthetic-lock-7002.ndjson")
            try Data("synthetic abandoned current".utf8).write(to: otherCurrent)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: otherCurrent.path)
            var unavailable = true
            let log = EventLog(url: current, instance: "synthetic-lock-7001", acquireWriterLock: { fd in
                XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "Close-on-exec must already be set when locking begins")
                if unavailable { errno = failure; return errno }
                return flock(fd, LOCK_SH | LOCK_NB) == 0 ? 0 : errno
            })
            log.open()
            for _ in 0..<3 { log.append(EventEnvelope(type: .surfaceCreated, instance: "synthetic-lock-7001", ts: Date())) }
            log.flush()
            log.sampleForTesting()
            let events = readLines(current).map(parse)
            XCTAssertEqual(events.first?["type"] as? String, "log.opened")
            XCTAssertEqual(events.filter { $0["type"] as? String == "panel.created" }.count, 3)
            XCTAssertFalse(events.contains { $0["type"] as? String == "log.dropped" })
            let markers = events.filter { $0["type"] as? String == "log.retention" }
            XCTAssertEqual(markers.count, 1)
            XCTAssertEqual((markers.first?["payload"] as? [String: Any])?["reason"] as? String, "liveness_lock_unavailable")
            XCTAssertEqual(try String(contentsOf: otherCurrent, encoding: .utf8), "synthetic abandoned current", "Unsupported liveness must never prune current files")
            unavailable = false // previous barrier drains the injected lock call
            log.sampleForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: otherCurrent.path))
            let recovered = readLines(current).map(parse).filter { $0["type"] as? String == "log.retention" }
            XCTAssertEqual(recovered.count, 2)
            XCTAssertEqual((recovered.last?["payload"] as? [String: Any])?["state"] as? String, "recovered")
        }
    }

    func testBusyWriterLivenessLockNeverDropsTheOpenedOrActivityRecords() throws {
        let url = logURL("events-synthetic-busy-7001.ndjson")
        let log = EventLog(url: url, instance: "synthetic-busy-7001")
        try withExternalFileLocks(at: [url], exclusive: true) {
            log.open()
            log.append(EventEnvelope(type: .surfaceCreated, instance: "synthetic-busy-7001", ts: Date()))
            log.flush()
            XCTAssertEqual(readLines(url).map(parse).compactMap { $0["type"] as? String }, ["log.opened", "panel.created"])
        }
        log.sampleForTesting() // reacquires the transiently unavailable SH lock
        log.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-busy-7001", ts: Date()))
        log.flush()
        XCTAssertEqual(readLines(url).map(parse).last?["type"] as? String, "panel.closed")
    }

    func testForeignTagSlugsExpireOnlyAfterFixedDevelopmentTTLAndWriterExit() throws {
        let stale = logURL("events-synthetic-one-off-tag-7002.ndjson")
        let rolled = logURL("events-synthetic-one-off-tag-7002.ndjson.1")
        let young = logURL("events-synthetic-young-tag-7003.ndjson")
        let production = logURL("events-com.stage11.c11-7004.ndjson")
        let nightly = logURL("events-com.stage11.c11.nightly-7005.ndjson")
        for file in [stale, rolled, young, production, nightly] {
            try Data("synthetic retained history".utf8).write(to: file)
            let age = file == young ? 13 : 15
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(age) * 86_400)], ofItemAtPath: file.path)
        }
        let log = EventLog(url: logURL("events-synthetic-current-tag-7001.ndjson"), instance: "synthetic-current-tag-7001")
        try withExternalFileLocks(at: [stale], exclusive: false) {
            log.open(); log.flush()
            XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: rolled.path))
        }
        log.sampleForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for file in [young, production, nightly] {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "synthetic retained history")
        }
    }

    func testDailyRetentionDeadlineWithAnalyticsOffPrunesWithoutHealthQuery() throws {
        var clock = Date()
        var healthCalls = 0, reconciliations = 0, timers = 0
        var schedules: [(TimeInterval, Int)] = []
        let stale = logURL("events-synthetic-daily-7002.ndjson.1")
        try Data("synthetic aging history".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-6.5 * 86_400)], ofItemAtPath: stale.path)
        let log = EventLog(url: logURL("events-synthetic-daily-7001.ndjson"), instance: "synthetic-daily-7001", now: { clock },
                           policy: ActivityHistoryPolicy(analyticsEnabled: false, retentionDays: 7))
        log.onHistoryReconcile = { reconciliations += 1 }
        log.onTimerCreated = { timers += 1 }
        log.onTimerScheduled = { schedules.append(($0, $1)) }
        log.open()
        log.startSampling { healthCalls += 1; return nil }
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(reconciliations, 1)
        XCTAssertEqual(schedules.last?.0 ?? -1, 86_400, accuracy: 0.001)
        XCTAssertEqual(schedules.last?.1, 60)
        clock.addTimeInterval(86_399)
        log.fireDeadlineForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        clock.addTimeInterval(1)
        log.fireDeadlineForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(reconciliations, 2)
        XCTAssertEqual(healthCalls, 0)
        XCTAssertEqual(timers, 1)
        log.finishSampling { XCTFail("Analytics off must not query shutdown health"); return nil }
    }

    func testTitleDeadlinesRearmOneTimerWithTwoSecondLeewayThroughShutdown() {
        var clock = Date()
        var timers = 0
        var schedules: [(TimeInterval, Int)] = []
        let log = EventLog(url: logURL(), instance: "synthetic-rearm", now: { clock }, policy: ActivityHistoryPolicy(analyticsEnabled: false))
        log.onTimerCreated = { timers += 1 }
        log.onTimerScheduled = { schedules.append(($0, $1)) }
        log.startSampling { XCTFail("Analytics off must not sample"); return nil }
        appendOSCTitle("First A", panel: "A", to: log)
        appendOSCTitle("Last A", panel: "A", to: log)
        log.flush()
        clock.addTimeInterval(5)
        appendOSCTitle("First B", panel: "B", to: log)
        appendOSCTitle("Last B", panel: "B", to: log)
        log.flush()
        XCTAssertEqual(timers, 1)
        XCTAssertEqual(schedules.last?.0 ?? -1, 55, accuracy: 0.001)
        XCTAssertEqual(schedules.last?.1, 2)
        log.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-rearm", ts: clock, surface: "A"))
        log.flush()
        XCTAssertEqual(timers, 1)
        XCTAssertEqual(schedules.last?.0 ?? -1, 60, accuracy: 0.001)
        log.finishSampling { nil }
        XCTAssertEqual(timers, 1, "Shutdown tail flush must not recreate the cancelled timer")
        let titles = readLines(logURL()).map(parse).filter { $0["type"] as? String == "metadata.changed" }
        XCTAssertEqual(titles.compactMap { ($0["payload"] as? [String: Any])?["value"] as? String }, ["First A", "First B", "Last A", "Last B"])
    }

    func testInitialPolicyOpensBeforeRetentionMarkerWithOneReconciliation() throws {
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".activity-history.lock"), withIntermediateDirectories: true)
        var reconciliations = 0
        let log = EventLog(url: logURL(), instance: "synthetic-startup", policy: ActivityHistoryPolicy(analyticsEnabled: false))
        log.onHistoryReconcile = { reconciliations += 1 }
        log.open(); log.flush()
        XCTAssertEqual(reconciliations, 1)
        XCTAssertEqual(readLines(logURL()).map(parse).compactMap { $0["type"] as? String }, ["log.opened", "log.retention"])
    }

    func testDisabledInitialPolicyPrunesSilentlyAndFirstEnableOpensBeforeRetentionMarker() throws {
        let stale = logURL("events-synthetic-initial-off-7002.ndjson.1")
        try Data("synthetic stale history".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * 86_400)], ofItemAtPath: stale.path)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".activity-history.lock"), withIntermediateDirectories: true)
        // An unavailable shared lock limits this checkpoint to our own rolls.
        let current = logURL("events-synthetic-initial-off-7001.ndjson")
        let ownRoll = URL(fileURLWithPath: current.path + ".1")
        try FileManager.default.moveItem(at: stale, to: ownRoll)
        let log = EventLog(url: current, instance: "synthetic-initial-off-7001", policy: ActivityHistoryPolicy(enabled: false))
        var timers = 0
        log.onTimerCreated = { timers += 1 }
        log.open(); log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownRoll.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(timers, 0)
        log.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false))
        log.open(); log.flush()
        XCTAssertEqual(readLines(current).map(parse).compactMap { $0["type"] as? String }, ["log.opened", "log.retention"])
        log.stopSampling()
    }
}


extension EventLogTests {
    func testRepeatedAwakeNotificationsCannotPostponeTenMinuteHealthDeadline() {
        var clock = Date()
        var healthCalls = 0
        let log = EventLog(url: logURL(), instance: "synthetic-awake-cadence", now: { clock })
        log.startSampling {
            healthCalls += 1
            return EventEnvelope(type: .instanceSample, instance: "synthetic-awake-cadence", ts: clock)
        }
        log.flush()
        for _ in 0..<5 {
            clock.addTimeInterval(100)
            log.setSamplingAsleep(false)
            log.fireDeadlineForTesting()
        }
        XCTAssertEqual(healthCalls, 0)
        clock.addTimeInterval(100)
        log.setSamplingAsleep(false)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 1)
        log.setSamplingAsleep(true); log.flush()
        clock.addTimeInterval(1000)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 1)
        log.setSamplingAsleep(false); log.flush() // genuine wake starts a new interval
        clock.addTimeInterval(599)
        log.setSamplingAsleep(false)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 1)
        clock.addTimeInterval(1)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 2)
        log.stopSampling()
        XCTAssertEqual(readLines(logURL()).map(parse).filter { $0["type"] as? String == "instance.sample" }.count, 2)
    }

    func testTextAndRetentionPolicyChangesPreserveHealthCadenceAndAnalyticsResumeRestartsIt() {
        var clock = Date()
        var healthCalls = 0
        let log = EventLog(url: logURL(), instance: "synthetic-policy-cadence", now: { clock })
        log.startSampling {
            healthCalls += 1
            return EventEnvelope(type: .instanceSample, instance: "synthetic-policy-cadence", ts: clock)
        }
        log.flush()
        clock.addTimeInterval(599)
        log.updatePolicy(ActivityHistoryPolicy(keepText: false, retentionDays: 7))
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 0)
        clock.addTimeInterval(1)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 1)
        log.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false)); log.flush()
        clock.addTimeInterval(1000)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 1)
        log.updatePolicy(ActivityHistoryPolicy()); log.flush()
        clock.addTimeInterval(599)
        log.updatePolicy(ActivityHistoryPolicy(keepText: false))
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 1)
        clock.addTimeInterval(1)
        log.fireDeadlineForTesting()
        XCTAssertEqual(healthCalls, 2)
        log.stopSampling()
    }
}


extension EventLogTests {
    func testFreshCurrentWriterWithoutSharedLockSurvivesAnotherInstancesBudgetPruning() throws {
        let current = logURL("events-synthetic-unlocked-7001.ndjson")
        let writer = EventLog(url: current, instance: "synthetic-unlocked-7001", acquireWriterLock: { _ in ENOLCK })
        writer.open()
        writer.append(EventEnvelope(type: .surfaceCreated, instance: "synthetic-unlocked-7001", ts: Date(),
                                    payload: ["synthetic_padding": String(repeating: "S", count: 2048)]))
        writer.flush()
        let original = try Data(contentsOf: current)
        XCTAssertGreaterThan(original.count, 1024)
        // This instance can acquire EX on the unlocked writer's fresh file.
        // Its deliberately tiny shared target must still preserve that file.
        let observer = EventLog(url: logURL("events-synthetic-unlocked-7002.ndjson"), instance: "synthetic-unlocked-7002", totalSizeCap: 1024)
        observer.open(); observer.flush()
        XCTAssertEqual(try Data(contentsOf: current), original)
        observer.sampleForTesting()
        XCTAssertEqual(try Data(contentsOf: current), original)
        writer.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-unlocked-7001", ts: Date()))
        writer.flush()
        XCTAssertEqual(readLines(current).map(parse).last?["type"] as? String, "panel.closed", "The writer must remain attached to the retained directory entry")
    }
}


extension EventLogTests {
    func testUnavailablePruneLocksStillPruneOwnRollsByAgeAndBudgetAndKeepWriting() throws {
        for failure in [ENOTSUP, ENOLCK] {
            let directory = tempDir.appendingPathComponent("synthetic-prune-lock-\(failure)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = directory.appendingPathComponent("events-synthetic-prune-lock-7001.ndjson")
            let agedOwn = URL(fileURLWithPath: current.path + ".3")
            let budgetOwn = [1, 2].map { URL(fileURLWithPath: current.path + ".\($0)") }
            let foreignRoll = directory.appendingPathComponent("events-synthetic-prune-lock-7002.ndjson.1")
            let foreignCurrent = directory.appendingPathComponent("events-synthetic-prune-lock-7002.ndjson")
            let otherTagRoll = directory.appendingPathComponent("events-synthetic-other-tag-7003.ndjson.1")
            for file in [agedOwn, foreignRoll, foreignCurrent, otherTagRoll] {
                try Data(repeating: 0x53, count: 128).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: file.path)
            }
            for (index, file) in budgetOwn.enumerated() {
                try Data(repeating: 0x53, count: 900).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(index + 1))], ofItemAtPath: file.path)
            }
            var pruneProbes = 0
            let log = EventLog(url: current, instance: "synthetic-prune-lock-7001", sizeCap: 1024, totalSizeCap: 2048,
                               acquireWriterLock: { _ in failure }, acquirePruneLock: { _ in
                pruneProbes += 1
                errno = failure
                return errno
            })
            log.open(); log.flush()
            XCTAssertFalse(FileManager.default.fileExists(atPath: agedOwn.path), "Age pruning of our immutable rolls needs no lock support")
            XCTAssertLessThan(budgetOwn.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 2,
                              "The byte target must prune young own rolls even when EX locking is unavailable")
            XCTAssertGreaterThan(pruneProbes, 0, "Foreign rolled files must still execute the failing exclusive probe")
            for file in [foreignRoll, foreignCurrent, otherTagRoll] {
                XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 0x53, count: 128))
            }
            for _ in 0..<3 {
                log.append(EventEnvelope(type: .surfaceCreated, instance: "synthetic-prune-lock-7001", ts: Date(),
                                         payload: ["synthetic_padding": String(repeating: "S", count: 300)]))
            }
            log.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-prune-lock-7001", ts: Date()))
            log.flush()
            log.sampleForTesting() // reconcile the byte target after continuing writes
            let ownFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent == current.lastPathComponent || $0.lastPathComponent.hasPrefix(current.lastPathComponent + ".") }
            let bytes = try ownFiles.reduce(0) { try $0 + Data(contentsOf: $1).count }
            XCTAssertLessThanOrEqual(bytes, 2048)
            let ownEvents = ownFiles.flatMap { readLines($0).map(parse) }
            XCTAssertTrue(ownEvents.contains { $0["type"] as? String == "panel.closed" }, "New records must continue to reach retained files")
            XCTAssertFalse(ownEvents.contains { $0["type"] as? String == "log.dropped" })
            XCTAssertTrue(ownEvents.contains { $0["type"] as? String == "log.rotated" }, "The regression must exercise actual writer rotation")
            for file in [foreignRoll, foreignCurrent, otherTagRoll] {
                XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 0x53, count: 128))
            }
        }
    }
}


extension EventLogTests {
    func testRecoveryBoundaryIsReservedWithinAnExactlyFullHistoryBudget() throws {
        let current = logURL("events-synthetic-recovery-budget-7001.ndjson")
        let budget = 2400
        let log = EventLog(url: current, instance: "synthetic-recovery-budget-7001", totalSizeCap: budget)
        try withExternalFileLocks(at: [tempDir.appendingPathComponent(".activity-history.lock")], exclusive: true) {
            log.open(); log.flush()
        }
        let initial = try Data(contentsOf: current).count
        let rolled = URL(fileURLWithPath: current.path + ".1")
        try Data(repeating: 0x53, count: budget - initial).write(to: rolled)
        XCTAssertEqual(try Data(contentsOf: current).count + Data(contentsOf: rolled).count, budget)
        log.sampleForTesting()
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { EventLogLayout.isLogFileName($0.lastPathComponent) }
        XCTAssertLessThanOrEqual(try files.reduce(0) { try $0 + Data(contentsOf: $1).count }, budget,
                                 "The recovery marker is part of the shared byte target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolled.path), "The pending recovery marker requires pruning the exact-full roll")
        let markers = readLines(current).map(parse).filter { $0["type"] as? String == "log.retention" }
        XCTAssertEqual(markers.compactMap { ($0["payload"] as? [String: Any])?["state"] as? String }, ["degraded", "recovered"])
    }

    func testFailedRecoveryBoundaryRemainsPendingUntilSuccessfullyWritten() throws {
        let current = logURL("events-synthetic-recovery-failure-7001.ndjson")
        var writerFD: Int32 = -1
        let log = EventLog(url: current, instance: "synthetic-recovery-failure-7001", acquireWriterLock: { fd in
            writerFD = fd
            return flock(fd, LOCK_SH | LOCK_NB) == 0 ? 0 : errno
        })
        try withExternalFileLocks(at: [tempDir.appendingPathComponent(".activity-history.lock")], exclusive: true) {
            log.open(); log.flush()
        }
        log.onQueueBeforeWrite = {
            // Replace only this isolated logger's descriptor with a read-only
            // descriptor. The real FileHandle write then fails with EBADF.
            let readOnly = Darwin.open(current.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(readOnly, 0)
            if readOnly >= 0 {
                XCTAssertEqual(dup2(readOnly, writerFD), writerFD)
                Darwin.close(readOnly)
            }
        }
        log.sampleForTesting()
        XCTAssertEqual(readLines(current).map(parse).filter { $0["type"] as? String == "log.retention" }.count, 1)
        // Keep the real EBADF fault active for one genuine activity record.
        // Only that lost record counts; the pending boundary is still retried.
        log.append(EventEnvelope(type: .surfaceClosed, instance: "synthetic-recovery-failure-7001", ts: Date()))
        log.flush()
        log.onQueueBeforeWrite = nil
        log.sampleForTesting()
        let events = readLines(current).map(parse)
        let markers = events.filter { $0["type"] as? String == "log.retention" }
        XCTAssertEqual(markers.compactMap { ($0["payload"] as? [String: Any])?["state"] as? String }, ["degraded", "recovered"])
        let drops = events.filter { $0["type"] as? String == "log.dropped" }
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual((drops.first?["payload"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertFalse(events.contains { $0["type"] as? String == "panel.closed" })
        log.sampleForTesting()
        XCTAssertEqual(readLines(current).map(parse).filter { $0["type"] as? String == "log.dropped" }.count, 1)
    }

    // MARK: - Synthetic bootstrap graph classification

    @MainActor
    func testTransientConstructionLeavesNormalGraphUnmarkedBeforeAnyDelayedCallback() async throws {
        let log = EventLog(url: logURL(), instance: "synthetic-bootstrap")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "synthetic-bootstrap")
        let bootstrap = UUID(), bootstrapPanel = UUID(), normal = UUID(), normalPanel = UUID()
        emitter.withTransientWorkspaceConstruction {
            emitter.enrollTransientWorkspaceConstruction(bootstrap)
            // Panel creation can precede workspace.created in real construction.
            emitter.emitSurfaceCreated(workspace: bootstrap, surface: bootstrapPanel, kind: "terminal", title: "Synthetic bootstrap")
            emitter.emitWorkspaceCreated(workspace: bootstrap, title: "Synthetic bootstrap", rootDirectory: nil)
        }
        emitter.enrollTransientWorkspaceConstruction(normal)
        emitter.emitSurfaceCreated(workspace: normal, surface: normalPanel, kind: "terminal", title: "Synthetic installed")
        emitter.emitWorkspaceCreated(workspace: normal, title: "Synthetic installed", rootDirectory: nil)
        // No onAppear, activation or delayed callback has run. Classification
        // already belongs to the construction UUID, not later UI attachment.
        log.flush()
        let initialEvents = readLines(logURL()).map(parse)
        let initialNormal = initialEvents.filter { $0["workspace"] as? String == normal.uuidString }
        XCTAssertEqual(initialNormal.compactMap { $0["type"] as? String }, ["panel.created", "workspace.created"])
        XCTAssertTrue(initialNormal.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] == nil },
                      "Normal graph creation must be unmarked before any later UI callback")
        let initialBootstrap = initialEvents.filter { $0["workspace"] as? String == bootstrap.uuidString }
        XCTAssertEqual(initialBootstrap.count, 2)
        XCTAssertTrue(initialBootstrap.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] as? Bool == true })
        await Task.detached {
            EventEmitter.shared.emitMetadataChanged(scope: "panel", workspace: bootstrap, surface: bootstrapPanel,
                                                    key: "status", value: "Synthetic delayed callback", prior: nil, source: "explicit")
        }.value
        emitter.emitWorkspaceClosed(workspace: bootstrap, title: "Synthetic bootstrap", remainingPanels: [bootstrapPanel])
        emitter.emitWorkspaceClosed(workspace: normal, title: "Synthetic installed", remainingPanels: [normalPanel])
        log.flush()

        let events = readLines(logURL()).map(parse)
        let bootstrapEvents = events.filter { $0["workspace"] as? String == bootstrap.uuidString }
        let normalEvents = events.filter { $0["workspace"] as? String == normal.uuidString }
        XCTAssertEqual(bootstrapEvents.compactMap { $0["type"] as? String },
                       ["panel.created", "workspace.created", "metadata.changed", "panel.closed", "workspace.closed"])
        XCTAssertEqual(normalEvents.compactMap { $0["type"] as? String },
                       ["panel.created", "workspace.created", "panel.closed", "workspace.closed"])
        XCTAssertTrue(bootstrapEvents.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] as? Bool == true })
        XCTAssertTrue(normalEvents.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] == nil })
    }

    @MainActor
    func testAnalyticsOffStillMarksTransientStructuralPanelEdges() {
        let log = EventLog(url: logURL(), instance: "synthetic-bootstrap-analytics-off")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "synthetic-bootstrap-analytics-off",
                                policy: ActivityHistoryPolicy(analyticsEnabled: false))
        let workspace = UUID(), panel = UUID()
        emitter.withTransientWorkspaceConstruction {
            emitter.enrollTransientWorkspaceConstruction(workspace)
            emitter.emitSurfaceCreated(workspace: workspace, surface: panel, kind: "terminal", title: "Synthetic bootstrap")
            emitter.emitWorkspaceCreated(workspace: workspace, title: "Synthetic bootstrap", rootDirectory: nil)
        }
        emitter.emitWorkspaceClosed(workspace: workspace, title: "Synthetic bootstrap", remainingPanels: [panel])
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["panel.created", "panel.closed"])
        XCTAssertTrue(events.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] as? Bool == true })
    }

    @MainActor
    func testTransientEnrollmentWhileRecordingOffSurvivesReenableAndLaterToggle() {
        let policy = ActivityHistoryPolicy(enabled: false)
        let log = EventLog(url: logURL(), instance: "synthetic-bootstrap-recording-off", policy: policy)
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "synthetic-bootstrap-recording-off", policy: policy, opened: false)
        let workspace = UUID(), panel = UUID()
        emitter.withTransientWorkspaceConstruction {
            emitter.enrollTransientWorkspaceConstruction(workspace)
            emitter.emitSurfaceCreated(workspace: workspace, surface: panel, kind: "terminal", title: "Synthetic bootstrap")
        }
        log.flush()
        XCTAssertTrue(readLines(logURL()).isEmpty)
        emitter.updatePolicy(ActivityHistoryPolicy())
        emitter.emitSurfaceCreated(workspace: workspace, surface: panel, kind: "terminal", title: "Synthetic delayed bootstrap")
        emitter.updatePolicy(ActivityHistoryPolicy(enabled: false))
        emitter.updatePolicy(ActivityHistoryPolicy())
        emitter.emitWorkspaceClosed(workspace: workspace, title: "Synthetic bootstrap", remainingPanels: [panel])
        log.flush()
        let events = readLines(logURL()).map(parse).filter { $0["workspace"] as? String == workspace.uuidString }
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["panel.created", "panel.closed", "workspace.closed"])
        XCTAssertTrue(events.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] as? Bool == true })
    }

    @MainActor
    func testTransientConstructionThrowRestoresNormalConstructionScope() {
        enum SyntheticFailure: Error { case expected }
        let log = EventLog(url: logURL(), instance: "synthetic-bootstrap-throw")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "synthetic-bootstrap-throw")
        let bootstrap = UUID(), normal = UUID()
        XCTAssertThrowsError(try emitter.withTransientWorkspaceConstruction {
            emitter.enrollTransientWorkspaceConstruction(bootstrap)
            throw SyntheticFailure.expected
        })
        emitter.enrollTransientWorkspaceConstruction(normal)
        emitter.emitWorkspaceCreated(workspace: bootstrap, title: "Synthetic bootstrap", rootDirectory: nil)
        emitter.emitWorkspaceCreated(workspace: normal, title: "Synthetic installed", rootDirectory: nil)
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual((events.first?["payload"] as? [String: Any])?["transient"] as? Bool, true)
        XCTAssertNil((events.last?["payload"] as? [String: Any])?["transient"])
    }

}


extension EventLogTests {
    @MainActor
    func testSuccessfulTerminalRuntimeMakesEnrolledWorkspaceNonTransient() async {
        let log = EventLog(url: logURL(), instance: "synthetic-runtime-guard")
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "synthetic-runtime-guard")
        let workspace = UUID(), panel = UUID()
        emitter.withTransientWorkspaceConstruction {
            emitter.enrollTransientWorkspaceConstruction(workspace)
            emitter.emitSurfaceCreated(workspace: workspace, surface: panel, kind: "terminal", title: "Synthetic bootstrap")
        }
        log.flush()
        XCTAssertEqual((readLines(logURL()).map(parse).first?["payload"] as? [String: Any])?["transient"] as? Bool, true)
        // Exercise the same success hook used only after ghostty_surface_new
        // returns a real runtime. No Ghostty allocation occurs in this fixture.
        emitter.noteWorkspaceRuntimeSurfaceCreated(workspace)
        emitter.emitWorkspaceCreated(workspace: workspace, title: "Synthetic real graph", rootDirectory: nil)
        await Task.detached {
            EventEmitter.shared.emitMetadataChanged(scope: "panel", workspace: workspace, surface: panel,
                                                    key: "status", value: "Synthetic later real runtime", prior: nil, source: "explicit")
        }.value
        emitter.emitWorkspaceClosed(workspace: workspace, title: "Synthetic real graph", remainingPanels: [panel])
        log.flush()
        let events = readLines(logURL()).map(parse)
        XCTAssertEqual(events.compactMap { $0["type"] as? String },
                       ["panel.created", "workspace.created", "metadata.changed", "panel.closed", "workspace.closed"])
        XCTAssertTrue(events.dropFirst().allSatisfy { ($0["payload"] as? [String: Any])?["transient"] == nil },
                      "Real runtime allocation must preserve the graph even if construction assumptions change")
    }

    @MainActor
    func testSuccessfulRuntimeWhileRecordingOffClearsEnrollmentBeforeReenable() {
        let policy = ActivityHistoryPolicy(enabled: false)
        let log = EventLog(url: logURL(), instance: "synthetic-runtime-guard-off", policy: policy)
        let emitter = EventEmitter.shared
        emitter.startForTesting(log: log, instance: "synthetic-runtime-guard-off", policy: policy, opened: false)
        let workspace = UUID(), panel = UUID()
        emitter.withTransientWorkspaceConstruction {
            emitter.enrollTransientWorkspaceConstruction(workspace)
        }
        emitter.noteWorkspaceRuntimeSurfaceCreated(workspace)
        emitter.updatePolicy(ActivityHistoryPolicy(analyticsEnabled: false))
        emitter.emitSurfaceCreated(workspace: workspace, surface: panel, kind: "terminal", title: "Synthetic real runtime")
        emitter.emitWorkspaceClosed(workspace: workspace, title: "Synthetic real runtime", remainingPanels: [panel])
        log.flush()
        let edges = readLines(logURL()).map(parse).filter { $0["workspace"] as? String == workspace.uuidString }
        XCTAssertEqual(edges.compactMap { $0["type"] as? String }, ["panel.created", "panel.closed"])
        XCTAssertTrue(edges.allSatisfy { ($0["payload"] as? [String: Any])?["transient"] == nil })
    }

    func testFailedRetriedRetentionBoundaryDoesNotReportAnActivityDrop() throws {
        let current = logURL("events-synthetic-boundary-retry-7001.ndjson")
        var writerFD: Int32 = -1
        let log = EventLog(url: current, instance: "synthetic-boundary-retry-7001", acquireWriterLock: { fd in
            writerFD = fd
            return flock(fd, LOCK_SH | LOCK_NB) == 0 ? 0 : errno
        })
        try withExternalFileLocks(at: [tempDir.appendingPathComponent(".activity-history.lock")], exclusive: true) {
            log.open(); log.flush()
        }
        log.onQueueBeforeWrite = {
            let readOnly = Darwin.open(current.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(readOnly, 0)
            if readOnly >= 0 {
                XCTAssertEqual(dup2(readOnly, writerFD), writerFD)
                Darwin.close(readOnly)
            }
        }
        log.sampleForTesting()
        XCTAssertEqual(readLines(current).map(parse).filter { $0["type"] as? String == "log.retention" }.count, 1)
        log.onQueueBeforeWrite = nil
        log.sampleForTesting()
        log.sampleForTesting()
        let events = readLines(current).map(parse)
        XCTAssertEqual(events.filter { $0["type"] as? String == "log.retention" }
            .compactMap { ($0["payload"] as? [String: Any])?["state"] as? String }, ["degraded", "recovered"])
        XCTAssertFalse(events.contains { $0["type"] as? String == "log.dropped" }, "A retried control boundary never lost an activity record")
    }
}


// MARK: - C11-348: owner-only modes and retention of sent text

extension EventLogTests {
    private func permissions(_ url: URL) -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return info.st_mode & 0o7777
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func seed(_ url: URL, _ text: String = "legacy history", ageDays: Double = 0, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([
            .modificationDate: Date().addingTimeInterval(-ageDays * 86_400),
            .posixPermissions: mode,
        ], ofItemAtPath: url.path)
    }

    func testNewHistoryIsCreatedOwnerOnlyIncludingRolledGenerationsAndMissingParents() throws {
        let state = tempDir.appendingPathComponent("fresh-state", isDirectory: true)
        let directory = state.appendingPathComponent("events", isDirectory: true)
        let url = directory.appendingPathComponent("events-synthetic-modes-7001.ndjson")
        let log = EventLog(url: url, instance: "synthetic-modes-7001", sizeCap: 400, totalSizeCap: 64 * 1024)
        log.open()
        for index in 0..<12 {
            log.append(EventEnvelope(type: .panelInputSent, instance: "synthetic-modes-7001", ts: Date(),
                                     payload: ["n": index, "text": String(repeating: "x", count: 100)]))
        }
        log.flush()
        XCTAssertEqual(permissions(directory), 0o700)
        XCTAssertEqual(permissions(state), 0o700, "A missing parent is created owner-only too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".2"), "The run must exercise rotation")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == ".activity-history.lock" })
        for file in files {
            XCTAssertEqual(permissions(file), 0o600, file.lastPathComponent)
        }
    }

    func testLaunchCheckpointTightensOlderHistoryOffMainWithRecordingOnOrOff() throws {
        for recording in [true, false] {
            let directory = tempDir.appendingPathComponent("legacy-\(recording)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            let legacy = ["events-com.stage11.c11-4100.ndjson", "events-com.stage11.c11-4100.ndjson.1",
                          "events-com.stage11.c11.debug.other-4200.ndjson.3"].map { directory.appendingPathComponent($0) }
            let unrelated = directory.appendingPathComponent("notes.txt")
            let outside = tempDir.appendingPathComponent("outside-\(recording).ndjson")
            let link = directory.appendingPathComponent("events-com.stage11.c11-4300.ndjson")
            for file in legacy + [unrelated, outside] { try seed(file, ageDays: 1) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertEqual(permissions(directory), 0o755)

            let url = directory.appendingPathComponent("events-com.stage11.c11-4400.ndjson")
            let log = EventLog(url: url, instance: "com.stage11.c11-4400",
                               policy: ActivityHistoryPolicy(enabled: recording))
            var reconciledOnMain = false
            log.onHistoryReconcile = { if Thread.isMainThread { reconciledOnMain = true } }
            log.open()
            log.flush()

            XCTAssertFalse(reconciledOnMain)
            XCTAssertEqual(permissions(directory), 0o700)
            for file in legacy {
                XCTAssertEqual(permissions(file), 0o600, file.lastPathComponent)
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "legacy history", "Tightening never edits content")
            }
            XCTAssertEqual(permissions(unrelated), 0o644, "Only event history is tightened")
            XCTAssertEqual(permissions(outside), 0o644, "A symlink is never followed")
            XCTAssertEqual(FileManager.default.fileExists(atPath: url.path), recording)
            if recording { XCTAssertEqual(permissions(url), 0o600) }

            // Idempotent, and every later checkpoint also catches a file an
            // older build wrote after launch.
            let late = directory.appendingPathComponent("events-com.stage11.c11-4500.ndjson")
            try seed(late, ageDays: 0)
            log.sampleForTesting()
            log.updatePolicy(ActivityHistoryPolicy(enabled: recording, retentionDays: 30))
            log.flush()
            for file in legacy + [late] { XCTAssertEqual(permissions(file), 0o600, file.lastPathComponent) }
            XCTAssertEqual(permissions(directory), 0o700)
            log.stopSampling()
        }
    }

    func testOneDotZeroBacklogAgesOutAtLaunchAndTheCurrentFileOutlivesItsOwnAge() throws {
        var clock = Date()
        let directory = tempDir.appendingPathComponent("backlog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var kept: [URL] = [], aged: [URL] = []
        for day in 0..<40 {
            let file = directory.appendingPathComponent("events-com.stage11.c11-\(5000 + day).ndjson")
            try seed(file, "{\"type\":\"panel.input_sent\",\"payload\":{\"text\":\"day \(day)\"}}\n",
                     ageDays: Double(day) + 0.05)
            if day >= 14 { aged.append(file) } else { kept.append(file) }
        }
        let url = directory.appendingPathComponent("events-com.stage11.c11-5100.ndjson")
        let log = EventLog(url: url, instance: "com.stage11.c11-5100", now: { clock })
        log.open()
        log.flush()
        for file in aged { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent) }
        for file in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
            XCTAssertEqual(permissions(file), 0o600, file.lastPathComponent)
        }

        // Sixty days later every other file is past the horizon. This
        // launch's own current file is never deleted, whatever its age.
        clock.addTimeInterval(60 * 86_400)
        log.append(EventEnvelope(type: .panelInputSent, instance: "com.stage11.c11-5100", ts: clock, payload: ["text": "kept"]))
        log.sampleForTesting()
        for file in kept { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent) }
        XCTAssertEqual(readLines(url).map(parse).compactMap { $0["type"] as? String }, ["log.opened", "panel.input_sent"])
    }

    func testByteBudgetPrunesOldestHistoryFirstButNeverTheCurrentLaunchFile() throws {
        let directory = tempDir.appendingPathComponent("budget", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rolls: [URL] = []
        for index in 0..<8 {
            let roll = directory.appendingPathComponent("events-com.stage11.c11-\(6000 + index).ndjson.1")
            try seed(roll, String(repeating: "y", count: 1024), ageDays: Double(8 - index) / 24)
            rolls.append(roll)
        }
        let budget = 4096
        let url = directory.appendingPathComponent("events-com.stage11.c11-6100.ndjson")
        let log = EventLog(url: url, instance: "com.stage11.c11-6100", sizeCap: 1024, totalSizeCap: budget)
        log.open()
        log.flush()
        let survivors = rolls.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertFalse(survivors.isEmpty)
        XCTAssertLessThan(survivors.count, rolls.count)
        XCTAssertEqual(survivors, Array(rolls.suffix(survivors.count)), "Oldest history goes first")
        let total = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { EventLogLayout.isLogFileName($0.lastPathComponent) }
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(total, budget)
        XCTAssertEqual(readLines(url).map(parse).first?["type"] as? String, "log.opened")
    }

    func testReusedPidRollsInheritedCurrentFileAsideSoRetentionStillApplies() throws {
        for (ageDays, survives) in [(20.0, false), (3.0, true)] {
            let directory = tempDir.appendingPathComponent("reused-\(Int(ageDays))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("events-com.stage11.c11-7001.ndjson")
            let rolled = URL(fileURLWithPath: url.path + ".1")
            try seed(url, "{\"type\":\"panel.input_sent\",\"payload\":{\"text\":\"INHERITED_SECRET\"}}\n", ageDays: ageDays)
            let inheritedDate = try XCTUnwrap(modificationDate(url))
            let log = EventLog(url: url, instance: "com.stage11.c11-7001")
            log.open()
            log.append(EventEnvelope(type: .surfaceCreated, instance: "com.stage11.c11-7001", ts: Date()))
            log.flush()
            let current = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(current.contains("INHERITED_SECRET"), "This launch's file holds only this launch")
            XCTAssertEqual(readLines(url).map(parse).first?["type"] as? String, "log.opened")
            XCTAssertEqual(permissions(url), 0o600)
            if survives {
                XCTAssertTrue(try String(contentsOf: rolled, encoding: .utf8).contains("INHERITED_SECRET"))
                XCTAssertEqual(permissions(rolled), 0o600)
                XCTAssertEqual(try XCTUnwrap(modificationDate(rolled)).timeIntervalSince(inheritedDate), 0, accuracy: 1,
                               "The roll keeps the inherited mtime, so its age still counts")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: rolled.path), "Inherited history past the horizon is pruned")
            }
        }
    }

    func testInheritedCurrentFileHeldByALiveWriterIsAppendedNotMoved() throws {
        let url = logURL("events-synthetic-held-7001.ndjson")
        try seed(url, "{\"type\":\"log.opened\"}\n", ageDays: 1)
        let log = EventLog(url: url, instance: "synthetic-held-7001")
        try withExternalFileLocks(at: [url], exclusive: false) {
            log.open()
            log.flush()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".1"))
        XCTAssertEqual(readLines(url).count, 2)
        XCTAssertEqual(permissions(url), 0o600, "A reused file is tightened on open")
    }

    func testRetentionDaysDefaultsKeyOverridesTheFourteenDayDefault() throws {
        let suiteName = "c11-348-retention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(ActivityHistoryPolicy(defaults: defaults).retentionDays, 14)
        let tenDays = logURL("events-synthetic-override-7000.ndjson.1")
        let twentyDays = logURL("events-synthetic-override-6999.ndjson.1")
        try seed(tenDays, ageDays: 10)
        try seed(twentyDays, ageDays: 20)
        let url = logURL("events-synthetic-override-7001.ndjson")
        let initial = ActivityHistoryPolicy(defaults: defaults)
        let log = EventLog(url: url, instance: "synthetic-override-7001", policy: initial)
        EventEmitter.shared.startForTesting(log: log, instance: "synthetic-override-7001", policy: initial)
        log.open()
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tenDays.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: twentyDays.path))

        defaults.set(7, forKey: ActivityHistoryPolicy.retentionDaysKey)
        EventEmitter.shared.reloadPolicy(defaults: defaults)
        EventEmitter.shared.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tenDays.path))
        let policy = readLines(url).map(parse).last { $0["type"] as? String == "log.policy" }
        XCTAssertEqual((policy?["payload"] as? [String: Any])?["retention_days"] as? Int, 7)

        // Only the Settings values are accepted; anything else is the default.
        defaults.set(3, forKey: ActivityHistoryPolicy.retentionDaysKey)
        XCTAssertEqual(ActivityHistoryPolicy(defaults: defaults).retentionDays, 14)
        defaults.set(30, forKey: ActivityHistoryPolicy.retentionDaysKey)
        XCTAssertEqual(ActivityHistoryPolicy(defaults: defaults).retentionDays, 30)
    }

    func testEventsTailExplainsAnInstanceLogThatRetentionRemoved() throws {
        let cli = try bundledCLIForEventsTail()
        let dead = logURL("events-synthetic-tail-7000.ndjson")
        try seed(dead, "{\"v\":2,\"seq\":1,\"type\":\"log.opened\",\"instance\":\"synthetic-tail-7000\",\"ts\":\"2026-09-01T00:00:00.000Z\"}\n",
                 ageDays: 20)
        let live = EventLog(url: logURL("events-synthetic-tail-7001.ndjson"), instance: "synthetic-tail-7001")
        live.open()
        live.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path), "The live launch's retention removed the dead log")

        func tail(_ instance: String) throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            let out = Pipe(), err = Pipe()
            process.executableURL = cli
            process.arguments = ["events", "tail", "--instance", instance]
            var environment = ProcessInfo.processInfo.environment
            environment["C11_ACTIVITY_HISTORY_DIRECTORY"] = tempDir.path
            process.environment = environment
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
        }
        let pruned = try tail("synthetic-tail-7000")
        XCTAssertEqual(pruned.status, 0)
        XCTAssertEqual(pruned.out, "")
        XCTAssertTrue(pruned.err.contains("note: no event log for instance synthetic-tail-7000"), pruned.err)
        let present = try tail("synthetic-tail-7001")
        XCTAssertEqual(present.status, 0, present.err)
        XCTAssertTrue(present.out.contains("\"log.opened\""), present.out)
        XCTAssertFalse(present.err.contains("no event log"), present.err)
    }

    private func bundledCLIForEventsTail() throws -> URL {
        var url = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            for name in ["c11 DEV.app", "c11.app"] {
                let cli = url.appendingPathComponent(name + "/Contents/Resources/bin/c11")
                if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
            }
            url.deleteLastPathComponent()
        }
        XCTFail("bundled c11 CLI not found from \(Bundle(for: Self.self).bundleURL.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    func testRecordingOffStillRunsTheDailyRetentionCheckpoint() throws {
        var clock = Date()
        var timers = 0
        var schedules: [(TimeInterval, Int)] = []
        let stale = logURL("events-synthetic-off-daily-7002.ndjson.1")
        try seed(stale, ageDays: 6.5)
        let url = logURL("events-synthetic-off-daily-7001.ndjson")
        let log = EventLog(url: url, instance: "synthetic-off-daily-7001", now: { clock },
                           policy: ActivityHistoryPolicy(enabled: false, retentionDays: 7))
        log.onTimerCreated = { timers += 1 }
        log.onTimerScheduled = { schedules.append(($0, $1)) }
        log.open()
        log.startSampling { XCTFail("Recording off must not sample health"); return nil }
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(timers, 1)
        XCTAssertEqual(schedules.last?.0 ?? -1, 86_400, accuracy: 0.001)
        XCTAssertEqual(schedules.last?.1, 60)
        clock.addTimeInterval(86_399)
        log.fireDeadlineForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        clock.addTimeInterval(1)
        log.fireDeadlineForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Recording off writes nothing")
        XCTAssertEqual(schedules.last?.0 ?? -1, 86_400, accuracy: 0.001, "The next daily checkpoint is armed")
        log.stopSampling()
    }
}
