import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// These tests exercise the once-per-terminal and guard bookkeeping against a
/// fake attachment, so they send straight to it. Production never does: it
/// uses the runtime overload, which the input-fault tests below cover.
extension HCConversationResumeSubmission {
    @MainActor
    fileprivate func submit(
        panelID: UUID, attachment: any HCAttachment, attemptEpoch: Date? = nil, text: String, submitReturn: Bool,
        permitsResume: @escaping @MainActor @Sendable () -> Bool,
        screenGuard: @escaping HCInputGuard, returnGuard: @escaping HCInputGuard
    ) async -> HCInputOutcome {
        await submit(panelID: panelID, attachment: attachment, attemptEpoch: attemptEpoch, text: text, submitReturn: submitReturn,
            permitsResume: permitsResume, screenGuard: screenGuard, returnGuard: returnGuard,
            send: { await attachment.submit($0) })
    }
}

final class HCConversationRecoveryTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "test-core", localAddress: "1")

    func testRecoveryRequiresAuthoritativeEndForPersistentIdentity() {
        let panelID = UUID()
        let identity = HCPanelIdentity(panelID: panelID, key: key)
        let saved: Set<UUID> = [panelID]
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let lifecycle: [HCLifecycle] = [
            .new, .live(HCTerminalRecord(key: key, state: .running)),
            .unresolved(identity, .connectionLost),
            .ended(HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .postAdoptionAbsence))
        ]
        XCTAssertFalse(HCConversationRecoveryPolicy.permitsDeadProcessRecovery(
            surfaceID: panelID.uuidString, savedPersistentPanels: saved, lookup: { _ in nil }))
        for (index, state) in lifecycle.enumerated() {
            let allowed = HCConversationRecoveryPolicy.permitsDeadProcessRecovery(
                surfaceID: panelID.uuidString, savedPersistentPanels: saved,
                lookup: { _ in .init(identity: identity, lifecycle: state, creation: nil) })
            XCTAssertEqual(allowed, index == 3)
        }
        let fallback = HCPanelIdentity(panelID: panelID, persistence: .nonpersistent)
        XCTAssertTrue(HCConversationRecoveryPolicy.permitsDeadProcessRecovery(
            surfaceID: panelID.uuidString, savedPersistentPanels: saved,
            lookup: { _ in .init(identity: fallback, lifecycle: .new, creation: nil) }))
    }

    @MainActor
    func testResumeRefusesSurvivorAndRechecksBeforeInput() async {
        let sender = HCConversationResumeSubmission()
        let attachment = ResumeAttachment(key: key)
        var allowed = false
        _ = await sender.submit(panelID: UUID(), attachment: attachment, text: "resume", submitReturn: true,
            permitsResume: { allowed }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(attachment.requests.count, 0)
        allowed = true
        attachment.beforeGuard = { allowed = false }
        _ = await sender.submit(panelID: UUID(), attachment: attachment, text: "resume", submitReturn: true,
            permitsResume: { allowed }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(attachment.writes, 0)
    }

    @MainActor
    func testResumeWritesOncePerTerminalEvenAfterUncertainTransmission() async {
        let sender = HCConversationResumeSubmission()
        let first = ResumeAttachment(key: key)
        first.uncertain = true
        for _ in 0..<2 {
            _ = await sender.submit(panelID: UUID(), attachment: first, text: "claude --resume exact", submitReturn: true,
                permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        }
        XCTAssertEqual(first.requests.count, 1)
        XCTAssertEqual(first.writes, 1)
        XCTAssertEqual(first.requests.first?.source, .resume)
        XCTAssertEqual(first.requests.first?.submitReturn, true)
        let second = ResumeAttachment(key: .init(owningCoreID: "test-core", localAddress: "2"))
        _ = await sender.submit(panelID: UUID(), attachment: second, text: "claude --resume exact", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(second.writes, 1)
    }

    /// C11H-272: a live shell an agent left takes one resume per empty
    /// prompt, uncertain writes included; a newer prompt takes its own. The
    /// replacement terminal's once-only attempt is a separate one.
    @MainActor
    func testLiveShellResumeIsOncePerEmptyPrompt() async {
        let sender = HCConversationResumeSubmission()
        let shell = ResumeAttachment(key: key)
        shell.uncertain = true
        let first = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<2 {
            _ = await sender.submit(panelID: UUID(), attachment: shell, attemptEpoch: first, text: "codex resume --yolo x",
                submitReturn: true, permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        }
        XCTAssertEqual(shell.writes, 1, "the same prompt never takes a second resume")
        let outcome = await sender.submit(panelID: UUID(), attachment: shell, attemptEpoch: first.addingTimeInterval(60),
            text: "codex resume --yolo x", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(shell.writes, 2, "a newer empty prompt takes its own: \(outcome)")
        _ = await sender.submit(panelID: UUID(), attachment: shell, text: "codex resume --yolo x", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(shell.writes, 3, "the replacement route keeps its own once-only attempt")
    }

    @MainActor
    func testZeroByteRefusalPermitsExplicitRetryWithNewGuard() async {
        let sender = HCConversationResumeSubmission()
        let attachment = ResumeAttachment(key: key)
        _ = await sender.submit(panelID: UUID(), attachment: attachment, text: "resume", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in false }, returnGuard: { _ in true })
        XCTAssertEqual(attachment.writes, 0)
        _ = await sender.submit(panelID: UUID(), attachment: attachment, text: "resume", submitReturn: true,
            permitsResume: { true }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(attachment.requests.count, 2)
        XCTAssertEqual(attachment.writes, 1)
    }

    @MainActor
    func testResumeRechecksBeforeReturnAndDoesNotReplayPartialWrite() async {
        let sender = HCConversationResumeSubmission()
        let attachment = ResumeAttachment(key: key)
        var allowed = true
        attachment.beforeReturn = { allowed = false }
        _ = await sender.submit(panelID: UUID(), attachment: attachment, text: "resume", submitReturn: true,
            permitsResume: { allowed }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(attachment.writes, 1)
        XCTAssertEqual(attachment.returns, 0)
        allowed = true
        attachment.beforeReturn = nil
        _ = await sender.submit(panelID: UUID(), attachment: attachment, text: "resume", submitReturn: true,
            permitsResume: { allowed }, screenGuard: { _ in true }, returnGuard: { _ in true })
        XCTAssertEqual(attachment.requests.count, 1)
    }


    /// Startup replacement publishes ended, creationPending, then a bound
    /// replacement while the conversation audit is still running. Recovery
    /// must still know which ended terminal it answers to at every step.
    func testEndedSourceSurvivesReplacementAdvancingPastEnded() {
        let panelID = UUID()
        defer { HCPanelRestoreState.shared.remove(panelID: panelID) }
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let proof = HCEndEvidence(id: UUID(), key: key, revision: revision, kind: .finished, hcReason: "holder_lost")
        let identity = HCPanelIdentity(panelID: panelID, key: key)
        HCPanelRestoreState.shared.seed(identity)
        HCPanelRestoreState.shared.publish(identity: identity, lifecycle: .ended(proof))
        func source() -> HCRecoveryEndedProof.Source? {
            let entry = HCPanelRestoreState.shared.entry(for: panelID)
            return HCRecoveryEndedProof.source(lifecycle: entry?.lifecycle ?? .new, creation: entry?.creation)
        }
        func alive() -> Bool {  // liveness: Quit and no-resume bulk mutations
            HCConversationRecoveryPolicy.permitsDeadProcessRecovery(
                surfaceID: panelID.uuidString, savedPersistentPanels: [panelID])
        }
        func policy() -> Bool {  // late audit commit for the old conversation
            HCConversationRecoveryPolicy.permitsRecoveryCommit(
                surfaceID: panelID.uuidString, savedPersistentPanels: [panelID])
        }
        XCTAssertEqual(source(), .init(key: key, replacementStarted: false))
        XCTAssertTrue(policy())
        XCTAssertTrue(alive(), "an ended terminal is dead")

        let creationID = UUID()
        HCPanelRestoreState.shared.recordCreation(panelID: panelID, creationID: creationID, replacing: proof)
        HCPanelRestoreState.shared.publish(identity: identity, lifecycle: .unresolved(identity, .creationPending))
        XCTAssertEqual(source(), .init(key: key, replacementStarted: true),
                       "the replaced end evidence is lost while creation is pending")
        XCTAssertTrue(policy(), "a slow verdict commit is refused once the replacement started")
        XCTAssertFalse(alive(), "past provenance made a replacement terminal count as dead")

        let replacementKey = HCTerminalKey(owningCoreID: "test-core", localAddress: "2")
        let record = HCTerminalRecord(key: replacementKey, state: .running,
            labels: ["c11.creation": creationID.uuidString], pid: 4242)
        HCPanelRestoreState.shared.publish(
            identity: HCPanelIdentity(panelID: panelID, key: replacementKey, persistence: .persistent,
                creationID: creationID, origin: .fresh),
            lifecycle: .live(record))
        XCTAssertEqual(source(), .init(key: key, replacementStarted: true),
                       "the bound replacement forgot which terminal it replaced")
        XCTAssertTrue(policy())
        XCTAssertFalse(alive(), "a live replacement agent counts as dead")
    }

    func testEndedSourceNeverCoversSurvivorsFreshTerminalsOrRejectedCreation() {
        let panelID = UUID()
        defer { HCPanelRestoreState.shared.remove(panelID: panelID) }
        let identity = HCPanelIdentity(panelID: panelID, key: key)
        let record = HCTerminalRecord(key: key, state: .running, pid: 1)
        // A restored survivor: live, never ended, no creation.
        XCTAssertNil(HCRecoveryEndedProof.source(lifecycle: .live(record), creation: nil))
        // A brand-new terminal replaces no end evidence.
        let fresh = HCCreationProvenance(creationID: UUID(), replaces: nil, outcome: .bound, boundKey: key)
        XCTAssertNil(HCRecoveryEndedProof.source(lifecycle: .live(record), creation: fresh))
        // A keyless end proof cannot name a terminal.
        let keyless = HCEndEvidence(id: UUID(), key: nil, creationID: UUID(),
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .finished)
        XCTAssertNil(HCRecoveryEndedProof.source(lifecycle: .ended(keyless), creation: nil))
        // A creation refused before transmission replaced nothing.
        let proof = HCEndEvidence(id: UUID(), key: key,
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .finished)
        let rejected = HCCreationProvenance(creationID: UUID(), replaces: proof, outcome: .rejected, boundKey: nil)
        XCTAssertNil(HCRecoveryEndedProof.source(lifecycle: .unresolved(identity, .creationPending), creation: rejected))
        // The current end wins over an older retained replacement.
        let newer = HCEndEvidence(id: UUID(), key: HCTerminalKey(owningCoreID: "test-core", localAddress: "9"),
            revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished)
        let retained = HCCreationProvenance(creationID: UUID(), replaces: proof, outcome: .bound, boundKey: key)
        XCTAssertEqual(HCRecoveryEndedProof.source(lifecycle: .ended(newer), creation: retained),
                       .init(key: newer.key!, replacementStarted: false))
    }


    /// A replacement attempt that throws before any terminal exists (a relaunch
    /// whose surface has no launch spec or window yet) must not consume the
    /// ended key; one that startup already began must keep its plan.
    func testFailedReplacementReleasesTheEndedKeyUnlessOneIsUnderway() {
        let proof = HCEndEvidence(id: UUID(), key: key,
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .finished, hcReason: "server_stop")
        let ended = HCRecoveryEndedProof.source(lifecycle: .ended(proof), creation: nil)
        XCTAssertTrue(HCRecoveryEndedProof.shouldReleasePlanAfterFailedReplacement(endedKey: key, current: ended),
                      "a failed attempt before any terminal exists consumed the ended key")
        let creation = HCCreationProvenance(creationID: UUID(), replaces: proof, outcome: .attempted, boundKey: nil)
        let underway = HCRecoveryEndedProof.source(lifecycle: .unresolved(HCPanelIdentity(panelID: UUID(), key: key),
            .creationPending), creation: creation)
        XCTAssertFalse(HCRecoveryEndedProof.shouldReleasePlanAfterFailedReplacement(endedKey: key, current: underway),
                       "startup's own replacement was abandoned")
        XCTAssertTrue(HCRecoveryEndedProof.shouldReleasePlanAfterFailedReplacement(endedKey: key, current: nil))
        let other = HCEndEvidence(id: UUID(), key: HCTerminalKey(owningCoreID: "test-core", localAddress: "9"),
            revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished)
        XCTAssertTrue(HCRecoveryEndedProof.shouldReleasePlanAfterFailedReplacement(
            endedKey: key, current: HCRecoveryEndedProof.source(lifecycle: .ended(other), creation: nil)))
    }

    /// C11H-205: End All ends this install's terminals, never one another
    /// install labelled (a staging build here, another Mac's on Studio).
    func testEndAllLeavesAnotherInstallsTerminalsRunning() {
        let mine = "mine-install", theirs = "staging-install"
        let ownLocal = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "test-core", localAddress: "t1"), state: .running,
            labels: [HCOwnerLabels.app: mine])
        let legacyLocal = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "test-core", localAddress: "t2"), state: .running)
        let stagingLocal = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "test-core", localAddress: "t3"), state: .running,
            labels: [HCOwnerLabels.app: theirs])
        let ownAtlas = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "studio", localAddress: "t4"), state: .running,
            labels: [HCOwnerLabels.app: mine], machineName: "studio", machineAvailability: .connected)
        let otherMacAtlas = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "studio", localAddress: "t5"), state: .running,
            machineName: "studio", machineAvailability: .connected)
        let records = [ownLocal, legacyLocal, stagingLocal, ownAtlas, otherMacAtlas]
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let targets = HCEndAllTargets.identities(panels: [],
            inventory: HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })), appInstallID: mine)
        XCTAssertEqual(Set(targets.compactMap(\.key)), [ownLocal.key, legacyLocal.key, ownAtlas.key])
    }

    func testEndAllIncludesInventoryOnlySessionsAndDeduplicatesExactKeys() {
        let visible = HCPanelIdentity(panelID: UUID(), key: key)
        let duplicate = HCPanelIdentity(panelID: UUID(), key: key)
        let unresolved = HCPanelIdentity(panelID: UUID())
        let orphanKey = HCTerminalKey(owningCoreID: "test-core", localAddress: "2")
        let endedKey = HCTerminalKey(owningCoreID: "test-core", localAddress: "3")
        let records = [HCTerminalRecord(key: key, state: .running),
            HCTerminalRecord(key: orphanKey, state: .running, labels: ["c11.panel": visible.panelID.uuidString]),
            HCTerminalRecord(key: endedKey, state: .finished)]
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let targets = HCEndAllTargets.identities(panels: [visible, duplicate, unresolved],
            inventory: HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })))
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(Set(targets.compactMap(\.key)), [key, orphanKey])
        XCTAssertTrue(targets.contains(unresolved))
        XCTAssertEqual(Set(targets.map(\.panelID)).count, 3)
        let bound = HCEndAllTargets.identities(panels: [unresolved],
            inventory: HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: [orphanKey: records[1]], panelBindings: [unresolved.panelID: orphanKey]))
        XCTAssertEqual(bound.count, 1)
        XCTAssertEqual(bound.first?.key, orphanKey)
        let replacement = HCPanelIdentity(panelID: unresolved.panelID, creationID: UUID())
        let pendingReplacement = HCEndAllTargets.identities(panels: [replacement],
            inventory: HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: [orphanKey: records[1]], panelBindings: [unresolved.panelID: orphanKey]))
        XCTAssertEqual(pendingReplacement.first?.panelID, replacement.panelID)
        XCTAssertNil(pendingReplacement.first?.key, "An old binding cannot resolve the pending replacement end")
        XCTAssertEqual(pendingReplacement.count, 2, "End the known orphan and keep the unresolved creation intent")
    }

    @MainActor
    private final class ResumeAttachment: HCAttachment, HCInputPort {
        nonisolated let key: HCTerminalKey
        nonisolated let generation: UInt64 = 1
        nonisolated var input: any HCInputPort { self }
        var requests: [HCInputRequest] = []
        var writes = 0
        var returns = 0
        var uncertain = false
        var beforeGuard: (() -> Void)?
        var beforeReturn: (() -> Void)?
        init(key: HCTerminalKey) { self.key = key }
        func submit(_ request: HCInputRequest) async -> HCInputOutcome {
            requests.append(request)
            beforeGuard?()
            let receipt = HCScreenReceipt(revision: .init(attachmentGeneration: generation, displayGeneration: 1),
                parsedOutputWatermark: 1, columns: 80, rows: 24)
            guard request.screenGuard?(receipt) == true else { return .refused(.guardRefused) }
            writes += 1
            beforeReturn?()
            let returned = request.submitReturn && request.returnGuard?(receipt) == true
            if returned { returns += 1 }
            let result = HCWriteReceipt(operationID: request.operationID, attachmentGeneration: generation,
                bodyBytesWritten: request.payload.count, returnWritten: returned)
            return uncertain || (request.submitReturn && !returned) ? .uncertain(result) : .written(result)
        }
        nonisolated func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
        nonisolated func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome { .written }
        nonisolated func detach() {}
        nonisolated func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64) {}
        nonisolated func invalidate(generation: UInt64, reason: HCInputRefusal) {}
    }
}

/// C11-468 (logic-only, member of `c11LogicTests`). The startup conversation
/// audit decides resume per panel: exact causal refs never wait on, or lose
/// state to, a scrape; a failed or slow phase writes nothing.
final class StartupConversationAuditTests: XCTestCase {

    // MARK: - Mocks

    final class MockFS: ConversationFilesystem, @unchecked Sendable {
        let home = URL(fileURLWithPath: "/Users/test")
        var existingPaths: Set<String> = []
        var codexRollouts: [ConversationFilesystemEntry] = []
        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
        func listSessionsRecursivelyByMtime(_ root: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] {
            guard root.path == home.appendingPathComponent(".codex/sessions").path else { return [] }
            return Array(codexRollouts.prefix(max))
        }
    }

    /// A scraper slower than any startup budget, counting its collections.
    final class SlowScraper: ConversationScraper, @unchecked Sendable {
        let kind: String
        let delay: TimeInterval
        let preset: [ScrapeCandidate]
        let failure: ScrapeCollectionFailure?
        private let lock = NSLock()
        private var collections = 0

        init(kind: String, delay: TimeInterval, preset: [ScrapeCandidate] = [], failure: ScrapeCollectionFailure? = nil) {
            self.kind = kind
            self.delay = delay
            self.preset = preset
            self.failure = failure
        }

        var collectionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return collections
        }

        func candidates(cwd: String?) -> [ScrapeCandidate] { preset }

        func collectBatchCandidates(
            contexts: [ScrapeCaptureContext],
            maxCandidates: Int
        ) -> ScrapeCandidateCollectionResult {
            lock.lock()
            collections += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            if let failure { return .failure(failure) }
            return .success(Array(preset.prefix(maxCandidates)))
        }
    }

    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StartupConversationAuditReport?
        func set(_ report: StartupConversationAuditReport) {
            lock.lock(); stored = report; lock.unlock()
        }
        var value: StartupConversationAuditReport? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    // MARK: - Fixtures

    private struct Panel {
        var id = UUID()
        let kind: String
        let cwd: String
        let ref: ConversationRef?
    }

    private func uuid(_ prefix: Int, _ index: Int) -> String {
        String(format: "%08x-1111-4111-8111-%012x", prefix, index)
    }

    private func claudePanel(_ index: Int, state: ConversationState = .alive) -> Panel {
        let cwd = "/work/claude-\(index)"
        return Panel(kind: "claude-code", cwd: cwd, ref: ConversationRef(
            kind: "claude-code", id: uuid(0xC1, index), cwd: cwd,
            capturedVia: .hook, state: state
        ))
    }

    private func codexPanel(_ index: Int) -> Panel {
        let cwd = "/work/codex-\(index)"
        return Panel(kind: "codex", cwd: cwd, ref: ConversationRef(
            kind: "codex", id: uuid(0xC0, index), cwd: cwd,
            capturedVia: .runtimeEnv, state: .alive
        ))
    }

    private func placeholderPanel(_ index: Int) -> Panel {
        let cwd = "/work/late-\(index)"
        return Panel(kind: "codex", cwd: cwd, ref: ConversationRef(
            kind: "codex", id: "wrapper-claim:p\(index)", placeholder: true, cwd: cwd,
            capturedVia: .wrapperClaim, state: .unknown
        ))
    }

    private func snapshot(_ panels: [Panel]) -> AppSessionSnapshot {
        let snapshots = panels.map { panel in
            SessionPanelSnapshot(
                id: panel.id, type: .terminal, title: "T", customTitle: nil, directory: panel.cwd,
                isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [],
                ttyName: nil, terminal: nil, browser: nil, markdown: nil,
                metadata: [PanelMetadataKeyName.terminalType: .string(panel.kind)],
                metadataSources: nil,
                surfaceConversations: panel.ref.map { PanelConversations(active: $0) }
            )
        }
        let workspace = SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "Terminal", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: nil,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: snapshots.map(\.id), selectedPanelId: nil)),
            panels: snapshots, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil
        )
        let window = SessionWindowSnapshot(
            frame: nil, display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        return AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion,
                                  createdAt: Date().timeIntervalSince1970, windows: [window])
    }

    /// Every panel's transcript is on disk: Claude by exact path, Codex as a
    /// date-nested rollout.
    private func filesystem(for panels: [Panel], extraCodexIds: [String] = []) -> MockFS {
        let fs = MockFS()
        for panel in panels {
            guard let ref = panel.ref, !ref.placeholder else { continue }
            if ref.kind == "claude-code" {
                fs.existingPaths.insert(fs.home
                    .appendingPathComponent(".claude/projects")
                    .appendingPathComponent(ClaudeCodeStrategy.projectSlug(forCwd: panel.cwd))
                    .appendingPathComponent("\(ref.id).jsonl").path)
            }
        }
        let codexIds = panels.compactMap { $0.ref }.filter { $0.kind == "codex" && !$0.placeholder }.map(\.id)
        for id in codexIds + extraCodexIds {
            let name = "rollout-2026-10-21T15-00-00-\(id).jsonl"
            fs.codexRollouts.append(ConversationFilesystemEntry(
                url: fs.home.appendingPathComponent(".codex/sessions/2026/10/21/\(name)"),
                fileName: name, mtime: Date(), size: 4096
            ))
        }
        return fs
    }

    private func environment(
        store: ConversationStore,
        scrapers: [any ConversationScraper],
        filesystem: MockFS,
        report: ReportBox
    ) -> StartupConversationAudit.Environment {
        StartupConversationAudit.Environment(
            store: store,
            pipeline: ScrapeCapturePipeline(scrapers: ConversationScraperRegistry(scrapers: scrapers), strategies: .v1),
            registry: .v1,
            filesystem: filesystem,
            loadLaunchBoundaries: { _ in [] },
            refreshOwners: {},
            classificationReady: {},
            report: { report.set($0) }
        )
    }

    private func decision(_ panel: Panel, in conversations: [String: PanelConversations], mode: ResumeRecoveryMode) -> ResumeDecision? {
        conversations[panel.id.uuidString]?.active.map {
            Workspace.resumeDecision(for: $0, registry: .v1, mode: mode)
        }
    }

    private func isCommand(_ decision: ResumeDecision?) -> Bool {
        if case .command = decision { return true }
        return false
    }

    // MARK: - Acceptance

    func testFreshLaunchQuitPreservesPersistentAgentWithoutRestoreSnapshot() async {
        let store = ConversationStore()
        let audit = StartupConversationAudit()
        audit.beginWithoutAudit(mode: .clean, store: store, permitsDeadProcessRecovery: { _ in false })
        await audit.awaitSeeded()
        _ = await store.push(surfaceId: "fresh", kind: "claude-code", id: uuid(0xC1, 79), source: .hook)
        await store.suspendAllAlive()
        let records = await store.snapshot()
        XCTAssertEqual(records["fresh"]?.active?.state, .alive)
    }

    /// hc's inventory is authoritative even when transcripts cannot be
    /// verified. Neither a dirty launch nor a clean Quit ends these agents.
    func testPersistentClaudeAndCodexStayAliveAcrossDirtyAuditAndQuit() async {
        let panels = [claudePanel(80), codexPanel(80)]
        let store = ConversationStore()
        var env = environment(store: store, scrapers: [], filesystem: MockFS(), report: ReportBox())
        env.permitsDeadProcessRecovery = { _ in false }
        let audit = StartupConversationAudit()
        audit.begin(mode: .dirty, snapshot: snapshot(panels), environment: env)
        _ = await audit.awaitReport()
        await store.suspendAllAlive()
        let records = await store.snapshot()
        for panel in panels {
            XCTAssertEqual(records[panel.id.uuidString]?.active, panel.ref)
        }
    }

    /// Real policy, real restore state, real store. `replaces` is kept for the
    /// replacement's whole lifetime, so the policy must never read it as
    /// "dead": old terminal ended, replacement bound, resumed agent alive.
    private func seedReplacement(_ panel: Panel, bound: Bool) async -> ConversationStore {
        let panelID = panel.id
        let oldKey = HCTerminalKey(owningCoreID: "test-core", localAddress: "old")
        let newKey = HCTerminalKey(owningCoreID: "test-core", localAddress: "new")
        let proof = HCEndEvidence(id: UUID(), key: oldKey,
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .finished, hcReason: "server_stop")
        let identity = HCPanelIdentity(panelID: panelID, key: oldKey)
        HCPanelRestoreState.shared.seed(identity)
        HCPanelRestoreState.shared.publish(identity: identity, lifecycle: .ended(proof))
        let creationID = UUID()
        HCPanelRestoreState.shared.recordCreation(panelID: panelID, creationID: creationID, replacing: proof)
        if bound {
            HCPanelRestoreState.shared.publish(
                identity: HCPanelIdentity(panelID: panelID, key: newKey, persistence: .persistent,
                    creationID: creationID, origin: .fresh),
                lifecycle: .live(HCTerminalRecord(key: newKey, state: .running,
                    labels: ["c11.creation": creationID.uuidString], pid: 4242)))
        } else {
            HCPanelRestoreState.shared.publish(identity: identity,
                lifecycle: .unresolved(identity, .creationPending))
        }
        let saved: Set<UUID> = [panelID]
        let store = ConversationStore()
        _ = await store.seed(from: [panelID.uuidString: PanelConversations(active: panel.ref)],
            permitsDeadProcessRecovery: { HCConversationRecoveryPolicy.permitsDeadProcessRecovery(
                surfaceID: $0, savedPersistentPanels: saved) },
            permitsRecoveryCommit: { HCConversationRecoveryPolicy.permitsRecoveryCommit(
                surfaceID: $0, savedPersistentPanels: saved) })
        return store
    }

    func testLiveReplacementAgentIsNeverSuspendedByQuitOrNoResume() async {
        let panel = claudePanel(86)
        defer { HCPanelRestoreState.shared.remove(panelID: panel.id) }
        let store = await seedReplacement(panel, bound: true)
        await store.suspendAllAlive()
        var records = await store.snapshot()
        XCTAssertEqual(records[panel.id.uuidString]?.active, panel.ref,
                       "clean Quit suspended an agent that is still running in its replacement terminal")
        await store.markAllUnknown()
        records = await store.snapshot()
        XCTAssertEqual(records[panel.id.uuidString]?.active, panel.ref,
                       "no-resume marked a live replacement agent unknown")
    }

    /// The reason the retained evidence exists: a slow audit must still be able
    /// to settle the OLD conversation while its replacement is being created.
    func testDelayedAuditStillCommitsWhileTheReplacementIsBeingCreated() async {
        let panel = claudePanel(87)
        defer { HCPanelRestoreState.shared.remove(panelID: panel.id) }
        let store = await seedReplacement(panel, bound: false)
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: await store.snapshot(), registry: .v1, filesystem: MockFS())
        await store.applyCrashTranscriptVerdicts(verdicts)
        let records = await store.snapshot()
        XCTAssertNotEqual(records[panel.id.uuidString]?.active?.state, .alive,
                          "the delayed audit verdict was refused while the replacement was pending")
    }

    func testPersistentReconciliationPrecedesCrashClassification() async {
        final class Lifecycle: @unchecked Sendable {
            private let lock = NSLock()
            private var ended = false
            func confirmEnd() { lock.lock(); ended = true; lock.unlock() }
            func permitsRecovery() -> Bool { lock.lock(); defer { lock.unlock() }; return ended }
        }
        let panel = claudePanel(81)
        let lifecycle = Lifecycle()
        let store = ConversationStore()
        var env = environment(store: store, scrapers: [], filesystem: filesystem(for: [panel]), report: ReportBox())
        env.permitsDeadProcessRecovery = { _ in lifecycle.permitsRecovery() }
        env.reconcilePersistentTerminals = { lifecycle.confirmEnd() }
        let audit = StartupConversationAudit()
        audit.begin(mode: .dirty, snapshot: snapshot([panel]), environment: env)
        _ = await audit.awaitReport()
        let records = await store.snapshot()
        XCTAssertEqual(records[panel.id.uuidString]?.active?.state, .suspended)
        XCTAssertTrue(isCommand(decision(panel, in: records, mode: .dirty)))
    }

    func testUnresolvedPersistentRefSurvivesNoResumeAndLateVerdict() async {
        let panel = claudePanel(82)
        let store = ConversationStore()
        _ = await store.seed(from: [panel.id.uuidString: PanelConversations(active: panel.ref)],
                             permitsDeadProcessRecovery: { _ in false })
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: await store.snapshot(), registry: .v1, filesystem: MockFS())
        await store.markAllUnknown(reason: "app restart --no-resume")
        await store.applyCrashTranscriptVerdicts(verdicts)
        let records = await store.snapshot()
        XCTAssertEqual(records[panel.id.uuidString]?.active, panel.ref,
                       "uncertain inventory is never proof of a dead process")
    }

    func testLateScrapeCannotReplacePersistentConversation() async throws {
        let panel = Panel(kind: "codex", cwd: "/work/survivor", ref: ConversationRef(
            kind: "codex", id: uuid(0xC1, 83), cwd: "/work/survivor",
            capturedAt: Date().addingTimeInterval(-600), capturedVia: .scrape, state: .alive))
        let store = ConversationStore()
        _ = await store.seed(from: [panel.id.uuidString: PanelConversations(active: panel.ref)],
                             permitsDeadProcessRecovery: { _ in false })
        let scraper = SlowScraper(kind: "codex", delay: 0, preset: [
            ScrapeCandidate(id: uuid(0xC1, 84), filePath: "/work/new.jsonl",
                            mtime: Date(), size: 4096, cwd: panel.cwd)
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: ConversationScraperRegistry(scrapers: [scraper]), strategies: .v1)
        let contexts = ConversationSnapshotCaptureScope(snapshot: snapshot([panel])).scrapeContexts
        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        _ = await store.applyScrapeBatch(batch, pipeline: pipeline, isStartupRecovery: true)
        let records = await store.snapshot()
        XCTAssertEqual(records[panel.id.uuidString]?.active, panel.ref)
        // This batch really can replace the inferred ref during ordinary
        // live discovery; only the startup-recovery commit must hold it.
        _ = await store.applyScrapeBatch(batch, pipeline: pipeline)
        let liveRecords = await store.snapshot()
        XCTAssertEqual(liveRecords[panel.id.uuidString]?.active?.id, uuid(0xC1, 84))
    }

    func testLateCrashVerdictCannotOverwriteSameConversationNewCausalReport() async {
        let panel = claudePanel(85)
        let store = ConversationStore()
        _ = await store.seed(from: [panel.id.uuidString: PanelConversations(active: panel.ref)])
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: await store.snapshot(), registry: .v1, filesystem: MockFS())
        _ = await store.push(surfaceId: panel.id.uuidString, kind: panel.kind,
                             id: panel.ref!.id, source: .hook, cwd: panel.cwd,
                             capturedAt: Date().addingTimeInterval(1))
        await store.applyCrashTranscriptVerdicts(verdicts)
        let records = await store.snapshot()
        XCTAssertEqual(records[panel.id.uuidString]?.active?.state, .alive)
    }

    /// The 2026-10-21 shape: 24 Claude hook refs, 6 Codex runtime refs and 2
    /// placeholders on a dirty restore, with every scraper slower than the old
    /// 5 s budget would allow for. Every causal ref resumes before any scrape
    /// finishes; the placeholders settle when theirs does.
    func testDirtyRestoreResumesEveryCausalRefWhileScrapeIsStillRunning() async {
        let causal = (0..<24).map { claudePanel($0) } + (0..<6).map { codexPanel($0) }
        let resolvable = placeholderPanel(0)
        let unresolvable = placeholderPanel(1)
        let lateId = uuid(0x1A7E, 0)
        let panels = causal + [resolvable, unresolvable]
        let fs = filesystem(for: panels, extraCodexIds: [lateId])
        let claudeScraper = SlowScraper(kind: "claude-code", delay: 3.0)
        let codexScraper = SlowScraper(kind: "codex", delay: 1.5, preset: [
            ScrapeCandidate(id: lateId, filePath: "/Users/test/.codex/sessions/2026/10/21/x-\(lateId).jsonl",
                            mtime: Date(), size: 4096, cwd: resolvable.cwd),
        ])
        let store = ConversationStore()
        let report = ReportBox()
        let audit = StartupConversationAudit()

        let start = Date()
        audit.begin(mode: .dirty, snapshot: snapshot(panels), environment: environment(
            store: store, scrapers: [claudeScraper, codexScraper], filesystem: fs, report: report
        ))
        let classification = await audit.awaitClassification()
        let conversations = await store.snapshot()
        let classifiedAfter = Date().timeIntervalSince(start)

        XCTAssertLessThan(classifiedAfter, 1.0, "classification must not wait on a scrape")
        XCTAssertNil(report.value, "the scrape is still running")
        for panel in causal {
            XCTAssertTrue(isCommand(decision(panel, in: conversations, mode: .dirty)),
                          "causal \(panel.kind) ref must resume without the scrape")
        }
        XCTAssertEqual(
            Set(classification.scrapeKindBySurface.keys),
            [resolvable.id.uuidString, unresolvable.id.uuidString]
        )
        XCTAssertNil(classification.scrapes["claude-code"], "no Claude panel needs a scrape")

        let finished = await audit.awaitReport()
        let settled = await store.snapshot()
        XCTAssertEqual(claudeScraper.collectionCount, 0)
        XCTAssertEqual(codexScraper.collectionCount, 1)
        XCTAssertEqual(finished?.outcome, "complete")
        XCTAssertEqual(finished?.panelsByTier["causal"], 30)
        XCTAssertEqual(finished?.panelsByTier["placeholder"], 2)
        XCTAssertEqual(finished?.scrapeDependentPanels, 2)
        XCTAssertNotNil(finished?.collectMsByKind["codex"])

        XCTAssertTrue(isCommand(decision(resolvable, in: settled, mode: .dirty)),
                      "a placeholder the scrape resolves resumes late")
        guard case .skip(let code, _)? = decision(unresolvable, in: settled, mode: .dirty) else {
            return XCTFail("an unresolved placeholder must skip")
        }
        XCTAssertEqual(code, .placeholder)
        for panel in causal {
            XCTAssertTrue(isCommand(decision(panel, in: settled, mode: .dirty)))
        }
    }

    /// A failed scrape changes no persisted state, and a relaunch from what
    /// autosave would write still resumes every causal ref.
    func testFailedScrapeWritesNothingAndRelaunchStillResumes() async {
        let causal = (0..<4).map { claudePanel($0) } + (0..<2).map { codexPanel($0) }
        let pending = placeholderPanel(0)
        let panels = causal + [pending]
        let fs = filesystem(for: panels)
        let records = WorkspaceSnapshotConversationBridge.records(from: snapshot(panels))

        func launch(_ panels: [Panel], mode: ResumeRecoveryMode) async -> (ConversationStore, StartupConversationAuditReport?) {
            let store = ConversationStore()
            let report = ReportBox()
            let audit = StartupConversationAudit()
            audit.begin(mode: mode, snapshot: snapshot(panels), environment: environment(
                store: store,
                scrapers: [SlowScraper(kind: "codex", delay: 0.3, failure: .unreadable)],
                filesystem: fs, report: report
            ))
            return (store, await audit.awaitReport())
        }

        let (cleanStore, cleanReport) = await launch(panels, mode: .clean)
        let afterClean = await cleanStore.snapshot()
        XCTAssertEqual(cleanReport?.outcome, "scrape_failed")
        XCTAssertNotNil(cleanReport?.scrapeFailuresByKind["codex"])
        XCTAssertEqual(afterClean, records, "a failed audit must not write state")

        let (dirtyStore, _) = await launch(panels, mode: .dirty)
        let persisted = await dirtyStore.snapshot()
        XCTAssertFalse(persisted.values.contains {
            $0.active?.diagnosticReason?.hasPrefix("startup audit failed") == true
        })
        // Relaunch from exactly what autosave would persist, failing again.
        let relaunched = panels.map { panel in
            Panel(id: panel.id, kind: panel.kind, cwd: panel.cwd, ref: persisted[panel.id.uuidString]?.active)
        }
        let (secondStore, _) = await launch(relaunched, mode: .dirty)
        let second = await secondStore.snapshot()
        for panel in causal {
            XCTAssertTrue(isCommand(decision(panel, in: persisted, mode: .dirty)))
            XCTAssertTrue(isCommand(decision(panel, in: second, mode: .dirty)),
                          "a forced failure must not cost the next launch its resumes")
        }
        guard case .skip(let code, _)? = decision(pending, in: second, mode: .dirty) else {
            return XCTFail("an unresolved placeholder must skip")
        }
        XCTAssertEqual(code, .placeholder)
    }

    func testSameIdRuntimeCaptureHealsUnknownRef() async {
        let store = ConversationStore()
        let id = uuid(0xC0, 7)
        _ = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/work/codex")
        await store.markAllUnknown(reason: "app restart --no-resume")
        let stale = await store.active(for: "S1")
        XCTAssertEqual(stale?.state, .unknown)

        let healed = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/work/codex")
        XCTAssertEqual(healed.outcome, .accepted)
        XCTAssertEqual(healed.ref.state, .alive)
        XCTAssertTrue(isCommand(Workspace.resumeDecision(for: healed.ref, registry: .v1, mode: .clean)))

        let repeated = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/work/codex")
        XCTAssertEqual(repeated.outcome, .idempotent)
    }

    func testExitTombstoneAndNoResumeNeverResume() async {
        let exited = claudePanel(0, state: .tombstoned)
        let live = claudePanel(1)
        let pending = placeholderPanel(0)
        let panels = [exited, live, pending]
        let fs = filesystem(for: panels)

        let store = ConversationStore()
        let audit = StartupConversationAudit()
        audit.begin(mode: .dirty, snapshot: snapshot(panels), environment: environment(
            store: store, scrapers: [], filesystem: fs, report: ReportBox()
        ))
        _ = await audit.awaitClassification()
        let dirty = await store.snapshot()
        XCTAssertFalse(isCommand(decision(exited, in: dirty, mode: .dirty)), "a /exit tombstone must never resume")
        XCTAssertEqual(dirty[exited.id.uuidString]?.active?.state, .tombstoned)
        guard case .skip(let code, _)? = decision(exited, in: dirty, mode: .clean) else {
            return XCTFail("a /exit tombstone must never resume")
        }
        XCTAssertEqual(code, .stateNotResumable)
        XCTAssertTrue(isCommand(decision(live, in: dirty, mode: .dirty)))

        let noResumeStore = ConversationStore()
        let noResume = StartupConversationAudit()
        let codexScraper = SlowScraper(kind: "codex", delay: 0)
        noResume.begin(mode: .noResume, snapshot: snapshot(panels), environment: environment(
            store: noResumeStore, scrapers: [codexScraper], filesystem: fs, report: ReportBox()
        ))
        let classification = await noResume.awaitClassification()
        let suppressed = await noResumeStore.snapshot()
        XCTAssertTrue(classification.scrapes.isEmpty, "no-resume collects nothing")
        XCTAssertEqual(codexScraper.collectionCount, 0)
        for panel in panels {
            guard case .skip(let code, _)? = decision(panel, in: suppressed, mode: .noResume) else {
                return XCTFail("no-resume must never resume")
            }
            XCTAssertEqual(code, .policyNoResume)
        }
    }

    /// A persisted inferred ref A and a newer session B in the same cwd: the
    /// scrape must still be able to replace A on a dirty restore, so A is
    /// not checked (and restamped) before its scrape lands.
    func testDirtyRestoreLetsTheScrapeReplaceAStaleInferredRef() async {
        let cwd = "/work/inferred"
        let staleId = uuid(0xA, 1)
        let freshId = uuid(0xB, 2)
        let stale = Panel(kind: "codex", cwd: cwd, ref: ConversationRef(
            kind: "codex", id: staleId, cwd: cwd,
            capturedAt: Date().addingTimeInterval(-600),
            capturedVia: .scrape, state: .alive
        ))
        let fs = filesystem(for: [stale], extraCodexIds: [freshId])
        let scraper = SlowScraper(kind: "codex", delay: 0.2, preset: [
            ScrapeCandidate(id: freshId, filePath: "/Users/test/.codex/sessions/2026/10/21/x-\(freshId).jsonl",
                            mtime: Date().addingTimeInterval(-60), size: 4096, cwd: cwd),
        ])
        let store = ConversationStore()
        let audit = StartupConversationAudit()
        audit.begin(mode: .dirty, snapshot: snapshot([stale]), environment: environment(
            store: store, scrapers: [scraper], filesystem: fs, report: ReportBox()
        ))
        let classification = await audit.awaitClassification()
        XCTAssertEqual(Set(classification.scrapeKindBySurface.keys), [stale.id.uuidString])
        _ = await audit.awaitReport()
        let settled = await store.snapshot()
        XCTAssertEqual(settled[stale.id.uuidString]?.active?.id, freshId, "the newer scraped session wins")
        XCTAssertTrue(isCommand(decision(stale, in: settled, mode: .dirty)))
    }

    func testCrashVerdictsNeverOverwriteARefThatChangedMeanwhile() async {
        let store = ConversationStore()
        let stale = uuid(0xE, 1)
        let fresh = uuid(0xE, 2)
        _ = await store.push(surfaceId: "A", kind: "claude-code", id: stale, source: .hook, cwd: "/work/a")
        _ = await store.push(surfaceId: "B", kind: "claude-code", id: uuid(0xE, 3), source: .hook, cwd: "/work/b")
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: await store.snapshot(), registry: .v1, filesystem: MockFS()
        )
        // A new causal report lands on A while the verdicts were computed.
        _ = await store.push(surfaceId: "A", kind: "claude-code", id: fresh, source: .hook, cwd: "/work/a",
                             capturedAt: Date().addingTimeInterval(1))
        await store.applyCrashTranscriptVerdicts(verdicts)
        let after = await store.snapshot()
        XCTAssertEqual(after["A"]?.active?.id, fresh)
        XCTAssertEqual(after["A"]?.active?.state, .alive, "a newer ref keeps its state")
        XCTAssertEqual(after["B"]?.active?.state, .unknown, "an unchanged ref takes its verdict")
    }

    func testOneCodexWalkAnswersEveryCodexRef() {
        final class CountingFS: ConversationFilesystem, @unchecked Sendable {
            let inner: MockFS
            var walks = 0
            init(_ inner: MockFS) { self.inner = inner }
            var homeDirectory: URL? { inner.homeDirectory }
            func fileExists(atPath path: String) -> Bool { inner.fileExists(atPath: path) }
            func listDirectoryByMtime(_ d: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
            func listSessionsRecursivelyByMtime(_ r: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] {
                walks += 1
                return inner.listSessionsRecursivelyByMtime(r, extensionFilter: extensionFilter, max: max)
            }
        }
        let panels = (0..<8).map { codexPanel($0) }
        let counting = CountingFS(filesystem(for: panels))
        let records = Dictionary(uniqueKeysWithValues: panels.map {
            ($0.id.uuidString, PanelConversations(active: $0.ref))
        })
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: records, registry: .v1, filesystem: SessionNameIndexFilesystem(base: counting)
        )
        XCTAssertEqual(verdicts.count, 8)
        XCTAssertTrue(verdicts.values.allSatisfy { $0.exists == true })
        XCTAssertEqual(counting.walks, 1)
    }

    func testScrapeScopeSkipsKindsWhoseRefsAreAllCausal() {
        let claudeCausal = ScrapeCaptureContext(surfaceId: "C1", kind: "claude-code", cwd: "/a")
        let claudeMissing = ScrapeCaptureContext(surfaceId: "C2", kind: "claude-code", cwd: "/b")
        let codexCausal = ScrapeCaptureContext(surfaceId: "X1", kind: "codex", cwd: "/c")
        let codexPlaceholder = ScrapeCaptureContext(surfaceId: "X2", kind: "codex", cwd: "/d")
        let piCausal = ScrapeCaptureContext(surfaceId: "P1", kind: "pi", cwd: "/e")
        let conversations: [String: PanelConversations] = [
            "C1": PanelConversations(active: ConversationRef(kind: "claude-code", id: uuid(1, 1), capturedVia: .hook, state: .alive)),
            "X1": PanelConversations(active: ConversationRef(kind: "codex", id: uuid(1, 2), capturedVia: .runtimeEnv, state: .alive)),
            "X2": PanelConversations(active: ConversationRef(kind: "codex", id: "wrapper-claim:x", placeholder: true, capturedVia: .wrapperClaim, state: .unknown)),
            "P1": PanelConversations(active: ConversationRef(kind: "pi", id: "p1", capturedVia: .hook, state: .alive)),
        ]
        let scoped = ScrapeCaptureContext.scoped(
            [claudeCausal, claudeMissing, codexCausal, codexPlaceholder, piCausal],
            to: conversations
        )
        XCTAssertEqual(scoped["claude-code"], [claudeMissing])
        XCTAssertEqual(scoped["codex"], [codexCausal, codexPlaceholder], "Codex keeps causal contexts for reservation")
        XCTAssertNil(scoped["pi"])
        XCTAssertTrue(ScrapeCaptureContext.scoped([claudeCausal, codexCausal], to: conversations).isEmpty)
    }
}
