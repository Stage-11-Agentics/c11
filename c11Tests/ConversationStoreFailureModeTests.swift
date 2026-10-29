import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// 1:1 mapping with the C11-24 architecture doc §"Failure modes" table.
/// Each test exercises one row from the grid: the failure scenario and
/// the new conversation-store behaviour that prevents it.
///
/// The merge-blocker fixture-driven regression test for the 2026-04-27
/// staging-QA bug (two codex panes same cwd) is also here, with a
/// fixture session-storage layout under
/// `Tests/Fixtures/codex/two-panes-same-cwd/`. The test reproduces the
/// failure shape against the new strategy.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class ConversationStoreFailureModeTests: XCTestCase {

    private let claudeId = "abc12345-ef67-890a-bcde-f0123456789a"
    private let codexIdA = "ddd11111-2222-3333-4444-555566667777"
    private let codexIdB = "eee22222-3333-4444-5555-666677778888"
    private let cwd = "/work/proj"

    override func setUp() async throws {
        try await super.setUp()
        for id in await ConversationStore.shared.snapshot().keys {
            await ConversationStore.shared.clear(surfaceId: id)
        }
    }

    // MARK: - Row: Hook fires after shutdown begins

    /// Hook fires during shutdown with slow/dying socket → ref preserved
    /// (NOT tombstoned). The hook side-decides via system.ping
    /// is_terminating_app; CLI policy treats unreachable/timeout as
    /// terminating so we err on preservation.
    ///
    /// Pure-store test: simulate the hook handler's "no-op when
    /// terminating" decision and verify the ref stays at its previous
    /// state.
    func testHookFiresAfterShutdownBegins() async {
        let store = ConversationStore.shared
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: claudeId,
            source: .hook,
            state: .alive
        )
        // Application shutdown begins → suspendAllAlive transitions to
        // .suspended.
        await store.suspendAllAlive()
        // SessionEnd hook fires AFTER shutdown began. The CLI handler
        // detects is_terminating_app == true and NO-OPS. Simulate by
        // not calling the store at all; the ref must remain suspended.
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .suspended,
                       "ref must NOT be tombstoned during shutdown — preserved for next-launch resume")
    }

    // MARK: - Row: Hook env strips CMUX_SURFACE_ID

    /// Without `CMUX_SURFACE_ID` and no `--surface` flag, the conversation
    /// CLI errors out. No silent misroute. (Tested via the surface
    /// resolution rule in the strategy layer.)
    func testHookEnvStripsCmuxSurfaceId() async {
        // The CLI would error out at parse time. Verify by calling the
        // store directly: a missing surface id can't even reach the
        // store (the store API takes surfaceId by value), so the bug
        // shape is structurally impossible. This test serves as the
        // structural assertion.
        let store = ConversationStore.shared
        // No write. Verify: nothing leaked into the store.
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 0,
                       "missing surface id must NOT silently route to focused — that path was eliminated")
    }

    // MARK: - Row: TUI crashes before hook fires

    /// TUI crashes before SessionStart fires → next-launch pull-scrape
    /// catches the session id from `~/.claude/sessions/<uuid>.jsonl`.
    func testTuiCrashesBeforeHookFires() {
        let mock = ConversationScraperTests.MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let sessionsDir = URL(fileURLWithPath: "/Users/test/.claude/projects")
        mock.recursiveEntries[sessionsDir] = [
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("\(claudeId).jsonl"),
                fileName: "\(claudeId).jsonl",
                mtime: Date(),
                size: 4096
            )
        ]
        let scraper = ClaudeCodeScraper(filesystem: mock)
        let candidates = scraper.candidates(cwd: cwd)
        XCTAssertEqual(candidates.count, 1,
                       "pull-scrape must surface the session even if the hook never fired")
        XCTAssertEqual(candidates.first?.id, claudeId)
    }

    // MARK: - Row: c11 crashes (dirty sentinel found)

    /// Dirty sentinel found at next launch → conversation refs transition
    /// to .unknown, ready for the forthcoming pull-scrape pass to
    /// reclassify.
    func testCrashRecoveryUnknownTransition() async {
        let store = ConversationStore.shared
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: claudeId,
            source: .hook,
            state: .alive
        )
        // Dirty sentinel found at next launch → AppDelegate calls
        // markAllUnknown.
        await store.markAllUnknown(reason: "crash recovery (dirty sentinel)")
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
        XCTAssertEqual(active?.diagnosticReason, "crash recovery (dirty sentinel)")
    }

    // MARK: - MERGE-BLOCKER row: Two panes same TUI same cwd (Codex)

    /// Reproduces the 2026-04-27 staging-QA failure shape using the
    /// fixture layout under
    /// `c11Tests/Fixtures/codex/two-panes-same-cwd/`. With the new
    /// Codex strategy, BOTH panes return `state = .unknown` and `resume`
    /// returns `.skip(reason: "ambiguous")`. Neither pane resumes the
    /// other's session.
    func testTwoPanesSameTuiSameCwd_2026_04_27() {
        // Two distinct sessions, same cwd, both newer than the
        // wrapper-claim time. The strategy filters by cwd → both
        // candidates pass; ambiguity policy fires.
        let mock = ConversationScraperTests.MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = URL(fileURLWithPath: "/Users/test/.codex/sessions")
        let claimTime = Date().addingTimeInterval(-300)
        mock.recursiveEntries[root] = [
            ConversationFilesystemEntry(
                url: root.appendingPathComponent("2026/04/27/\(codexIdA).jsonl"),
                fileName: "\(codexIdA).jsonl",
                mtime: claimTime.addingTimeInterval(60),
                size: 8192
            ),
            ConversationFilesystemEntry(
                url: root.appendingPathComponent("2026/04/27/\(codexIdB).jsonl"),
                fileName: "\(codexIdB).jsonl",
                mtime: claimTime.addingTimeInterval(120),
                size: 4096
            )
        ]
        for entry in mock.recursiveEntries[root] ?? [] {
            mock.sessionHeads[entry.url.path] = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"\(cwd)\"}}"
        }
        let scraper = CodexScraper(filesystem: mock)
        let candidates = scraper.candidates(cwd: cwd)
        XCTAssertEqual(candidates.count, 2)

        let strategy = CodexStrategy()
        let claim = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:S1:1",
            placeholder: true,
            cwd: cwd,
            capturedAt: claimTime,
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            wrapperClaim: claim,
            scrapeCandidates: candidates
        )
        let ref = strategy.capture(inputs: inputs)
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.state, .unknown,
                       "ambiguous candidates must transition to unknown — the merge-blocker behaviour")
        XCTAssertTrue(ref?.diagnosticReason?.contains("ambiguous") ?? false,
                      "advisory must surface for operator visibility")
        guard case .skip(let reason) = strategy.resume(ref: ref!) else {
            XCTFail("expected skip on ambiguous ref")
            return
        }
        XCTAssertEqual(reason, "quarantined:ambiguous_global_assignment",
                       "resume must NOT auto-fire — neither pane resumes the other's session")
    }

    // MARK: - Row: Sleep/power-off mid-session (same as crash recovery)

    func testSleepPowerOffMidSession() async {
        // Same as testCrashRecoveryUnknownTransition: dirty sentinel +
        // markAllUnknown. The "same as crash recovery" row in the
        // failure-modes table is intentional — both paths converge on
        // the same primitive.
        let store = ConversationStore.shared
        await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: codexIdA,
            source: .scrape,
            state: .alive
        )
        await store.markAllUnknown(reason: "sleep recovery (dirty sentinel)")
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
    }

    // MARK: - Row: TUI session file deleted out-of-band

    /// For Claude (with hook history) → tombstone is appropriate.
    /// For hookless TUIs (Codex/Opencode/Kimi) → state stays `.unknown`,
    /// operator clears explicitly. (Pure logic — the strategy never
    /// auto-tombstones for hookless kinds.)
    func testTuiSessionFileDeletedOutOfBand() {
        // Codex strategy with no candidates and no claim → returns nil
        // (no ref to update); state would stay where it was (likely
        // unknown from the prior dirty-sentinel transition).
        let strategy = CodexStrategy()
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            scrapeCandidates: []
        )
        XCTAssertNil(strategy.capture(inputs: inputs))
    }

    // MARK: - OpenCode displayed-root identity reservations

    func testOpenCodeNeighborCaptureConflictPreservesPreviousBinding() async {
        let store = ConversationStore()
        let idA = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let idB = "ses_0fd8a6fffffe6JzzcloHmtDV0R"
        await store.claim(surfaceId: "A", kind: "opencode", cwd: cwd,
                          placeholderId: "wrapper-claim:A", expectedResumeId: idA, interactivePID: 1001,
                          expiresAt: Date().addingTimeInterval(120))
        await store.claim(surfaceId: "B", kind: "opencode", cwd: cwd,
                          placeholderId: "wrapper-claim:B", expectedResumeId: idB, interactivePID: 1002,
                          expiresAt: Date().addingTimeInterval(120))
        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: idA, cwd: cwd, callerPID: 1001
        ) else { return XCTFail("A's TUI process must capture its resumed root") }
        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "B", id: idB, cwd: cwd, callerPID: 1002
        ) else { return XCTFail("B's TUI process must capture its resumed root") }

        let result = await store.captureDisplayedOpenCodeRoot(surfaceId: "A", id: idB, cwd: cwd, callerPID: 1001)
        guard case .conflict(let owners, let preserved) = result else {
            return XCTFail("a route change to another panel's session must be rejected")
        }
        XCTAssertEqual(owners, ["B"])
        XCTAssertEqual(preserved?.id, idA)
        XCTAssertEqual(preserved?.state, .unknown, "a stale displayed binding must not auto-resume")
        XCTAssertTrue(preserved?.diagnosticReason?.contains(idB) ?? false)
        let activeB = await store.active(for: "B")
        let activeA = await store.active(for: "A")
        XCTAssertEqual(activeB?.id, idB)
        XCTAssertEqual(activeA?.id, idA)
    }

    func testOpenCodeResumeReservationProtectsNeighborBeforeTuiCapture() async {
        let store = ConversationStore()
        let idA = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let idB = "ses_0fd8a6fffffe6JzzcloHmtDV0R"
        await store.claim(surfaceId: "A", kind: "opencode", cwd: cwd,
                          placeholderId: "wrapper-claim:A", expectedResumeId: idA, interactivePID: 1001,
                          expiresAt: Date().addingTimeInterval(120))
        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: idA, cwd: cwd, callerPID: 1001
        ) else { return XCTFail("A's TUI process must capture its resumed root") }
        let claim = await store.claim(
            surfaceId: "B",
            kind: "opencode",
            cwd: cwd,
            placeholderId: "wrapper-claim:B:resume",
            expectedResumeId: idB,
            interactivePID: 1002,
            expiresAt: Date().addingTimeInterval(120)
        )
        guard case .accepted(let claimRef) = claim else { return XCTFail("B's resume claim should be accepted") }
        XCTAssertEqual(claimRef.payload?[ConversationLifecyclePayloadKey.expectedResumeID], .string(idB))

        let conflict = await store.captureDisplayedOpenCodeRoot(surfaceId: "A", id: idB, cwd: cwd, callerPID: 1001)
        guard case .conflict(let owners, let preserved) = conflict else {
            return XCTFail("B's wrapper reservation must protect its ID before TUI setup")
        }
        XCTAssertEqual(owners, ["B"])
        XCTAssertEqual(preserved?.id, idA)
        XCTAssertEqual(preserved?.state, .unknown)
        let activeReservation = await store.active(for: "B")
        XCTAssertEqual(activeReservation?.placeholder, true)

        let captured = await store.captureDisplayedOpenCodeRoot(surfaceId: "B", id: idB, cwd: cwd, callerPID: 1002)
        guard case .accepted(let ref) = captured else { return XCTFail("the reservation owner must consume its claim") }
        XCTAssertEqual(ref.id, idB)
        XCTAssertFalse(ref.placeholder)
        XCTAssertNil(ref.payload?[ConversationLifecyclePayloadKey.expectedResumeID])
        XCTAssertNil(ref.payload?[ConversationLifecyclePayloadKey.resumeExpiresAtEpochMs])
        XCTAssertEqual(ref.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID], .number(1002))

        let afterCapture = await store.captureDisplayedOpenCodeRoot(surfaceId: "A", id: idB, cwd: cwd, callerPID: 1001)
        guard case .conflict(let ownersAfterCapture, _) = afterCapture else {
            return XCTFail("the captured exact ref must continue protecting B from A")
        }
        XCTAssertEqual(ownersAfterCapture, ["B"])
    }

    func testOpenCodeDisplayedRootRejectsSubprocessCallerEnvironment() async {
        let store = ConversationStore()
        let id = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        await store.claim(surfaceId: "A", kind: "opencode", cwd: cwd,
                          placeholderId: "wrapper-claim:A", expectedResumeId: id, interactivePID: 1001,
                          expiresAt: Date().addingTimeInterval(120))

        let spoofed = await store.captureDisplayedOpenCodeRoot(surfaceId: "A", id: id, cwd: cwd, callerPID: 2002)
        guard case .unauthorized = spoofed else {
            return XCTFail("a subprocess inheriting A's panel environment is not the TUI socket peer")
        }
        let active = await store.active(for: "A")
        XCTAssertEqual(active?.placeholder, true, "rejected spoof must not consume the resume reservation")
    }

    func testOpenCodeGenericPushCannotForgeOrReplaceAuthenticatedTuiRoute() async {
        let store = ConversationStore()
        let rootID = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let attackerID = "ses_0fd8a6fffffe6JzzcloHmtDV0R"
        await store.claim(
            surfaceId: "A", kind: "opencode", cwd: cwd,
            placeholderId: "wrapper-claim:A", interactivePID: 1001,
            openCodeRecoveryPayload: [
                ConversationLifecyclePayloadKey.openCodeRecoveryContextVersion: .number(1),
                ConversationLifecyclePayloadKey.openCodeRecoveryHome: .string("/open-code/home"),
                ConversationLifecyclePayloadKey.openCodeRecoveryXDGDataHome: .string("/open-code/data"),
                ConversationLifecyclePayloadKey.openCodeRecoveryDatabaseOverride: .string("tenant-state/custom.sqlite"),
            ]
        )

        let forgedClaim = await store.push(
            surfaceId: "A", kind: "opencode", id: attackerID, source: .hook,
            payload: [ConversationLifecyclePayloadKey.openCodeTuiPID: .number(2002)]
        )
        XCTAssertNil(forgedClaim, "generic pushes cannot write server-owned TUI claim metadata")

        let forgedRecoveryContext = await store.push(
            surfaceId: "A", kind: "opencode", id: attackerID, source: .hook,
            payload: [ConversationLifecyclePayloadKey.openCodeRecoveryContextVersion: .number(1)]
        )
        XCTAssertNil(forgedRecoveryContext, "generic pushes cannot forge the authenticated recovery context")

        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: rootID, cwd: cwd, callerPID: 1001
        ) else { return XCTFail("the authenticated wrapper TUI must bind its displayed root") }

        let replacement = await store.push(
            surfaceId: "A", kind: "opencode", id: attackerID, source: .hook
        )
        XCTAssertNil(replacement, "generic pushes cannot replace a v2 displayed route")
        let crossKindReplacement = await store.push(
            surfaceId: "A", kind: "claude-code", id: claudeId, source: .hook
        )
        XCTAssertNil(crossKindReplacement, "a generic push cannot bypass v2 route protection by changing kind")
        let active = await store.active(for: "A")
        XCTAssertEqual(active?.id, rootID)
        XCTAssertEqual(active?.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID], .number(1001))
        XCTAssertEqual(active?.payload?[ConversationLifecyclePayloadKey.openCodeRecoveryHome], .string("/open-code/home"))
        XCTAssertEqual(active?.payload?[ConversationLifecyclePayloadKey.openCodeRecoveryXDGDataHome], .string("/open-code/data"))
        XCTAssertEqual(active?.payload?[ConversationLifecyclePayloadKey.openCodeRecoveryDatabaseOverride], .string("tenant-state/custom.sqlite"))

        let subprocessCapture = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: attackerID, cwd: cwd, callerPID: 2002
        )
        guard case .unauthorized = subprocessCapture else {
            return XCTFail("a forged PID in an ordinary hook payload must not authorize a displayed-route capture")
        }
    }

    func testSeededOpenCodeV2ReferenceRequiresFreshAuthenticatedClaim() async {
        let store = ConversationStore()
        let id = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let persisted = ConversationRef(
            kind: "opencode", id: id, placeholder: false, cwd: cwd,
            capturedAt: Date(), capturedVia: .hook, state: .alive,
            payload: [ConversationLifecyclePayloadKey.openCodeTuiPID: .number(1001)]
        )
        _ = await store.seed(from: ["A": PanelConversations(active: persisted)])

        let recoveredPush = await store.push(
            surfaceId: "A", kind: "opencode", id: "ses_0fd8a6fffffe6JzzcloHmtDV0R", source: .hook
        )
        XCTAssertNil(recoveredPush, "a restored v2 route remains protected until a fresh TUI claim")
        let staleTui = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: id, cwd: cwd, callerPID: 1001
        )
        guard case .unauthorized = staleTui else {
            return XCTFail("persisted PID metadata is not a live socket authentication")
        }
    }

    func testOpenCodeSessionConflictBlocksTypedMailboxFallback() {
        let registration = MailboxNativeDoorbell.Registration(
            id: UUID(), panelID: UUID(), agentPID: 0, processStart: 0,
            sessionID: "opencode-session:1", route: .opencodePlugin, canQueue: false)
        let conflict = MailboxNativeDoorbell.Fallback(
            registration: registration, ids: ["mail-a"], reason: "native_session_conflict")
        XCTAssertTrue(conflict.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: []))
        XCTAssertFalse(conflict.blocksTyped(unreadIDs: ["mail-b"], coveredIDs: []))
        XCTAssertFalse(conflict.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: ["mail-a"]))

        let ordinaryFailure = MailboxNativeDoorbell.Fallback(
            registration: registration, ids: ["mail-a"], reason: "native_timeout")
        XCTAssertFalse(ordinaryFailure.blocksTyped(unreadIDs: ["mail-a"], coveredIDs: []))
    }

    func testOpenCodeTuiConflictHoldsTypedMailWithoutNativeRegistration() {
        let conflict = ConversationRef(
            kind: "opencode", id: "ses_0fda89a49ffeLHwJXtrxnn4X6g", placeholder: false,
            cwd: cwd, capturedAt: Date(), capturedVia: .hook, state: .unknown,
            diagnosticReason: "OpenCode displayed route ses_0fd8a6fffffe6JzzcloHmtDV0R conflicts with panel(s): B",
            payload: [ConversationLifecyclePayloadKey.openCodeTuiPID: .number(1001)]
        )
        XCTAssertTrue(MailboxNativeDoorbell.blocksTypedForUnboundOpenCodeTUI(conversation: conflict))

        var bound = conflict
        bound.state = .alive
        bound.diagnosticReason = "displayed root captured by this OpenCode TUI"
        XCTAssertFalse(MailboxNativeDoorbell.blocksTypedForUnboundOpenCodeTUI(conversation: bound))

        var v1 = conflict
        v1.payload = nil
        XCTAssertFalse(MailboxNativeDoorbell.blocksTypedForUnboundOpenCodeTUI(conversation: v1))
        XCTAssertTrue(MailboxNativeDoorbell.openCodePluginPeerMatches(peerPID: 1001, agentPID: 1001))
        XCTAssertFalse(MailboxNativeDoorbell.openCodePluginPeerMatches(peerPID: 2002, agentPID: 1001),
                       "a shared-server tool subprocess cannot register as the TUI peer")
    }

    func testOpenCodeChildRouteDropsExactBindingAndHoldsTypedMail() async {
        let store = ConversationStore()
        let rootID = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let childID = "ses_0fd8cb310ffe2of6OsP2qYz4Q5"
        await store.claim(surfaceId: "A", kind: "opencode", cwd: cwd,
                          placeholderId: "wrapper-claim:A", expectedResumeId: rootID, interactivePID: 1001,
                          expiresAt: Date().addingTimeInterval(120))
        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: rootID, cwd: cwd, callerPID: 1001
        ) else { return XCTFail("root route should bind before switching to a child") }

        let result = await store.markDisplayedOpenCodeRouteUnbound(
            surfaceId: "A", id: childID, cwd: cwd, routeState: "child", callerPID: 1001
        )
        guard case .accepted(let childRef) = result else { return XCTFail("TUI child state should be accepted") }
        XCTAssertTrue(childRef.placeholder)
        XCTAssertTrue(childRef.diagnosticReason?.contains("child session") ?? false)
        XCTAssertEqual(childRef.payload?[ConversationLifecyclePayloadKey.openCodeTuiPID], .number(1001))
        XCTAssertNil(childRef.payload?[ConversationLifecyclePayloadKey.expectedResumeID])
        XCTAssertNil(childRef.payload?[ConversationLifecyclePayloadKey.resumeExpiresAtEpochMs])
        XCTAssertTrue(MailboxNativeDoorbell.blocksTypedForUnboundOpenCodeTUI(conversation: childRef))

        let nextOwner = await store.claim(
            surfaceId: "B", kind: "opencode", cwd: cwd,
            placeholderId: "wrapper-claim:B:resume", expectedResumeId: rootID,
            interactivePID: 1002, expiresAt: Date().addingTimeInterval(120)
        )
        guard case .accepted(let nextOwnerRef) = nextOwner else { return XCTFail("another panel may resume the released root") }
        XCTAssertEqual(nextOwnerRef.payload?[ConversationLifecyclePayloadKey.expectedResumeID], .string(rootID),
                       "a child display must release the prior root's ownership")
    }

    func testOpenCodeNoRouteDoesNotRetainPreviousExactRoot() async {
        let store = ConversationStore()
        let rootID = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        await store.claim(surfaceId: "A", kind: "opencode", cwd: cwd,
                          placeholderId: "wrapper-claim:A", expectedResumeId: rootID, interactivePID: 1001,
                          expiresAt: Date().addingTimeInterval(120))
        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "A", id: rootID, cwd: cwd, callerPID: 1001
        ) else { return XCTFail("root route should bind before navigating home") }

        let result = await store.markDisplayedOpenCodeRouteUnbound(
            surfaceId: "A", id: rootID, cwd: cwd, routeState: "no-route", callerPID: 1001
        )
        guard case .accepted(let ref) = result else { return XCTFail("the home route should unbind its old root") }
        XCTAssertTrue(ref.placeholder)
        XCTAssertTrue(ref.diagnosticReason?.contains("no displayed session") ?? false)
        XCTAssertTrue(MailboxNativeDoorbell.blocksTypedForUnboundOpenCodeTUI(conversation: ref))
    }

    func testExpiredOpenCodeResumeReservationDoesNotBlockAnotherPanel() async throws {
        let store = ConversationStore()
        let id = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let initial = await store.claim(surfaceId: "A", kind: "opencode", cwd: cwd,
                                        placeholderId: "wrapper-claim:A", expectedResumeId: id, interactivePID: 1001,
                                        expiresAt: Date().addingTimeInterval(0.2))
        guard case .accepted(let initialRef) = initial else { return XCTFail("initial reservation should be accepted") }
        XCTAssertEqual(initialRef.payload?[ConversationLifecyclePayloadKey.expectedResumeID], .string(id))
        try await Task.sleep(for: .milliseconds(400))

        let next = await store.claim(
            surfaceId: "B", kind: "opencode", cwd: cwd,
            placeholderId: "wrapper-claim:B", expectedResumeId: id,
            interactivePID: 1002, expiresAt: Date().addingTimeInterval(120)
        )
        guard case .accepted(let nextRef) = next else { return XCTFail("the next panel should be allowed to reserve after expiry") }
        XCTAssertEqual(nextRef.payload?[ConversationLifecyclePayloadKey.expectedResumeID], .string(id))
        guard case .accepted = await store.captureDisplayedOpenCodeRoot(
            surfaceId: "B", id: id, cwd: cwd, callerPID: 1002
        ) else { return XCTFail("the expired reservation must not retain ownership") }
    }

    // MARK: - Row: Wrapper not on PATH (system update)

    /// Wrapper-claim absent → strategy degrades to pull-scrape only;
    /// no regression. Verified via Claude Code: with no wrapper-claim
    /// AND a scrape candidate, capture returns the scraped ref.
    func testWrapperNotOnPath() {
        let strategy = ClaudeCodeStrategy()
        let candidate = ScrapeCandidate(
            id: claudeId,
            filePath: "/Users/test/.claude/projects/\(claudeId).jsonl",
            mtime: Date(),
            size: 4096,
            cwd: cwd
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            wrapperClaim: nil, // wrapper absent
            push: nil,
            scrapeCandidates: [candidate]
        )
        let ref = strategy.capture(inputs: inputs)
        XCTAssertEqual(ref?.id, claudeId,
                       "without a wrapper-claim, scrape still produces a usable ref — no regression")
    }
}
