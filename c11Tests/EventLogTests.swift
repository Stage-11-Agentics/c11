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
