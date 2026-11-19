import XCTest
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class FlagTestBox: @unchecked Sendable {
    var result: TerminalController.V2CallResult?
}

/// C11H-246: a raised flag is the loudest notification, from any host; the
/// routine dial never reaches it. Logic-only (no host app): every flag here
/// goes through `PanelAttentionService` into the shared store, whose system
/// center is replaced by capturing hooks.
@MainActor
final class FlagNotificationTests: XCTestCase {
    private var requests: [UNNotificationRequest] = []
    private var removals: [String] = []
    private var records: [FlagNotificationRecord] = []
    private var lookingAt: Set<UUID> = []
    private var settings: UserDefaults!
    private var suiteName = ""
    private var cleanups: [(UUID, UUID)] = []

    override func setUp() {
        super.setUp()
        suiteName = "c11-246-\(UUID().uuidString)"
        settings = UserDefaults(suiteName: suiteName)
        requests = []
        removals = []
        records = []
        lookingAt = []
        cleanups = []
        let store = TerminalNotificationStore.shared
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { $0(true) }
        store.configureDirectFlagCustomCommandHandlerForTesting { _ in }
        store.configureFlagNotificationObservationForTesting(
            request: { [weak self] request, completion in
                self?.requests.append(request)
                completion(nil)
            },
            removal: { [weak self] in self?.removals.append($0) },
            record: { [weak self] in self?.records.append($0) },
            operatorLooking: { [weak self] _, surface in self?.lookingAt.contains(surface) ?? false },
            settings: settings
        )
    }

    override func tearDown() {
        for (workspace, surface) in cleanups {
            PanelAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }
        let store = TerminalNotificationStore.shared
        store.resetDirectFlagDeliveryHandlersForTesting()
        store.resetFlagNotificationReplacementHandlerForTesting()
        UserDefaults().removePersistentDomain(forName: suiteName)
        AppFocusState.overrideIsFocused = nil
        super.tearDown()
    }

    private func panel() -> (UUID, UUID) {
        let pair = (UUID(), UUID())
        cleanups.append(pair)
        return pair
    }

    /// Completions hop to main; let them land.
    private func drainMain() {
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func raise(_ workspace: UUID, _ surface: UUID, _ reason: String, kind: PanelFlagKind? = nil) throws {
        _ = try PanelAttentionService.shared.raise(
            workspaceId: workspace, surfaceId: surface, reason: reason, kind: kind, title: "Owner"
        )
        drainMain()
    }

    private func builtInKind() throws -> PanelFlagKind {
        try XCTUnwrap(PanelFlagKindRegistry.shared.all().first)
    }

    // MARK: 1. Raise, lower, raise again

    func testRaiseLowerRaiseAgainPostsRemovesThenPostsFresh() throws {
        let (workspace, surface) = panel()

        try raise(workspace, surface, "Need a decision")
        XCTAssertEqual(requests.count, 1)
        let first = try XCTUnwrap(requests.first?.identifier)
        XCTAssertTrue(FlagNotificationSpec.isFlagIdentifier(first))
        XCTAssertEqual(records.last?.action, .posted)

        try raise(workspace, surface, "Need a decision")
        XCTAssertEqual(requests.count, 1, "an identical re-raise posts nothing")

        try raise(workspace, surface, "Need a decision", kind: try builtInKind())
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.identifier, first, "a --kind change replaces in place; it never stacks")
        XCTAssertEqual(records.last?.action, .replaced)

        _ = try PanelAttentionService.shared.lower(workspaceId: workspace, surfaceId: surface, by: .agent)
        XCTAssertTrue(removals.contains(first), "lowering removes the delivered alert")
        XCTAssertEqual(records.last?.action, .removed)
        XCTAssertEqual(records.last?.cause, .lowered)
        XCTAssertFalse(TerminalNotificationStore.shared.postedFlagIdentifiersForTesting().contains(first))

        try raise(workspace, surface, "Another decision")
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(requests.last?.identifier, first, "a fresh raise is a fresh alert")
        XCTAssertEqual(records.last?.action, .posted)
    }

    // MARK: 2. Opening the panel

    func testOperatorOpenRemovesTheAlertAndLeavesTheFlagRaised() throws {
        let (workspace, surface) = panel()
        try raise(workspace, surface, "Look at this")
        let identifier = try XCTUnwrap(requests.last?.identifier)

        TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)

        XCTAssertEqual(removals, [identifier])
        XCTAssertEqual(records.last?.cause, .opened)
        XCTAssertTrue(PanelAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: surface).isFlagged,
                      "opening the panel never lowers the flag")
    }

    func testAgentFocusInsideASocketRequestIsNotAnOpen() throws {
        let (workspace, surface) = panel()
        try raise(workspace, surface, "Look at this")
        let context = SocketCommandContext(method: "panel.focus", allowsFocus: false)

        SocketCommandContext.withContext(context) {
            TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)
        }

        XCTAssertTrue(removals.isEmpty)
        XCTAssertEqual(records.last?.action, .posted)
    }

    /// A fresh raise on the panel in front of the operator is skipped only
    /// when the operator's own last open named it. Focus alone (an agent's
    /// `panel.focus` leaves the panel focused in the key window) is not
    /// enough: the flag posts.
    func testAFreshRaiseOnAFocusedPanelPostsUnlessTheOperatorOpenedIt() throws {
        let (workspace, surface) = panel()
        lookingAt = [surface]

        try raise(workspace, surface, "Focused, but nobody opened me")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(records.last?.action, .posted)
        _ = try PanelAttentionService.shared.lower(workspaceId: workspace, surfaceId: surface, by: .agent)

        // A request naming the panel is never the operator's open.
        SocketCommandContext.withContext(SocketCommandContext(method: "panel.focus", allowsFocus: true)) {
            TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)
        }
        try raise(workspace, surface, "Still nobody opened me")
        XCTAssertEqual(requests.count, 2)

        _ = try PanelAttentionService.shared.lower(workspaceId: workspace, surfaceId: surface, by: .agent)
        TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)
        try raise(workspace, surface, "The operator opened me and is looking")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(records.last?.action, .skippedOperatorLooking)
    }

    func testFlagSkipsTheSystemAlertOnlyWhileTheOperatorLooksAtItsPanel() throws {
        let (workspace, watched) = panel()
        let other = UUID()
        cleanups.append((workspace, other))
        lookingAt = [watched]
        TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: watched)

        try raise(workspace, watched, "Right in front of you")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(records.last?.action, .skippedOperatorLooking)

        try raise(workspace, other, "Somewhere else")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(records.last?.action, .posted)
    }

    // MARK: 3. Relaunch

    func testRestoringARaisedFlagPostsNothing() {
        let (workspace, surface) = panel()
        PanelAttentionService.shared.restore(PanelAttentionSnapshot(
            workspaceId: workspace, surfaceId: surface, flagReason: "Raised before quit",
            flagRaisedAt: Date(timeIntervalSince1970: 1_700_000_000), delegated: false
        ))
        drainMain()
        XCTAssertTrue(PanelAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: surface).isFlagged)
        XCTAssertTrue(requests.isEmpty)
    }

    func testLaunchReconcileKeepsOwnedAlertsAndRemovesEveryOtherFlagAlert() {
        let workspace = UUID()
        let owned = FlagNotificationSpec.identifier(workspaceId: workspace, surfaceId: UUID(), flagRaisedAt: Date())
        let stale = FlagNotificationSpec.identifier(workspaceId: workspace, surfaceId: UUID(), flagRaisedAt: Date())
        let routine = UUID().uuidString

        let plan = FlagNotificationReconcilePlan.make(delivered: [owned, stale, routine], raised: [owned])

        XCTAssertEqual(plan.keep, [owned])
        XCTAssertEqual(plan.remove, [stale], "a routine alert is never touched; a flag alert nobody owns goes")
    }

    // MARK: 4. Remote and local

    func testRemoteAndLocalRaisesBuildTheSameNotification() throws {
        let kind = try builtInKind()
        let reason = "Same words from any host"

        func post(_ params: [String: Any], relayMachine: String?, workspace: UUID, surface: UUID) throws -> UNNotificationRequest {
            let canonical = LegacyWireAliases.canonicalParams(params)
            let context = SocketCommandContext(method: "flag.raise", allowsFocus: false)
            context.relayMachine = relayMachine
            let validation = SocketCommandContext.withContext(context) {
                TerminalController.v2ValidateFlagMutation(method: "flag.raise", params: canonical)
            }
            guard case .valid(let request) = validation else {
                XCTFail("flag.raise was refused: \(validation)")
                throw NSError(domain: "FlagNotificationTests", code: 1)
            }
            _ = try TerminalController.commitFlagRaise(request, workspaceId: workspace, surfaceId: surface, title: "Owner")
            drainMain()
            return try XCTUnwrap(requests.last)
        }

        // A local `c11 raise-flag --kind <id>` from the panel's own shell.
        let (localWorkspace, localSurface) = panel()
        let local = try post([
            "panel_id": localSurface.uuidString, "workspace_id": localWorkspace.uuidString,
            "by": "agent", "kind": kind.id, "reason": reason, "caller_panel_id": localSurface.uuidString,
        ], relayMachine: nil, workspace: localWorkspace, surface: localSurface)
        let localRecord = try XCTUnwrap(records.last)

        // The same command from a shell on Studio, as the relay admits it.
        let (remoteWorkspace, remoteSurface) = panel()
        let line = String(data: try JSONSerialization.data(withJSONObject: [
            "id": "1", "method": "flag.raise",
            "params": ["panel_id": remoteSurface.uuidString, "workspace_id": remoteWorkspace.uuidString,
                       "kind": kind.id, "reason": reason],
        ]), encoding: .utf8)!
        let relayed = C11Relay.Request(
            id: UUID().uuidString, at: Int64(Date().timeIntervalSince1970 * 1000),
            panel: remoteSurface.uuidString, workspace: remoteWorkspace.uuidString,
            term: "t3", framing: .json, line: line, timeoutMilliseconds: 5000
        )
        let caller = C11RelayPolicy.VerifiedCaller(panel: remoteSurface, workspace: remoteWorkspace, machine: "studio", terminal: "t3")
        guard case .v2(_, _, let admittedParams, _) = try C11RelayPolicy.admit(relayed, caller: caller).get() else {
            return XCTFail("the relay did not admit flag.raise as v2")
        }
        let remote = try post(admittedParams, relayMachine: "studio", workspace: remoteWorkspace, surface: remoteSurface)
        let remoteRecord = try XCTUnwrap(records.last)

        XCTAssertEqual(local.content.title, remote.content.title)
        XCTAssertEqual(local.content.subtitle, remote.content.subtitle)
        XCTAssertEqual(local.content.body, remote.content.body)
        XCTAssertEqual(local.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(remote.content.interruptionLevel, .timeSensitive)
        XCTAssertNotNil(local.content.sound)
        XCTAssertNotNil(remote.content.sound)
        XCTAssertEqual(local.content.threadIdentifier, remote.content.threadIdentifier)
        XCTAssertEqual(local.content.categoryIdentifier, remote.content.categoryIdentifier)
        XCTAssertEqual(local.content.userInfo[FlagNotificationSpec.userInfoFlagKey] as? Bool, true)
        XCTAssertEqual(remote.content.userInfo[FlagNotificationSpec.userInfoFlagKey] as? Bool, true)
        // The identifier rule: prefix, workspace, panel, epoch.
        for (request, workspace, surface) in [(local, localWorkspace, localSurface), (remote, remoteWorkspace, remoteSurface)] {
            XCTAssertTrue(request.identifier.hasPrefix(
                FlagNotificationSpec.identifierPrefix + workspace.uuidString.lowercased() + "." + surface.uuidString.lowercased() + "."
            ))
        }
        XCTAssertEqual(localRecord.sourceHost, "local")
        XCTAssertEqual(remoteRecord.sourceHost, "studio")
        XCTAssertEqual(localRecord.sound, remoteRecord.sound)
    }

    // MARK: 5. The dial never touches a flag

    func testFlagAlwaysPostsTimeSensitiveWithTheFlagSoundAtEveryStop() throws {
        for level in NotificationLevel.allCases {
            settings.set(level.rawValue, forKey: NotificationLevel.key)
            let (workspace, surface) = panel()
            requests = []
            try raise(workspace, surface, "Stop \(level.rawValue)")
            let request = try XCTUnwrap(requests.last, "no flag at \(level.rawValue)")
            XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
            XCTAssertNotNil(request.content.sound)
            XCTAssertEqual(records.last?.sound, FlagSoundSettings.defaultValue)
        }
    }

    func testFlagSoundIsItsOwnSettingWithADistinctDefault() {
        XCTAssertNotEqual(FlagSoundSettings.defaultValue, NotificationSoundSettings.defaultValue)
        settings.set("Glass", forKey: FlagSoundSettings.key)
        settings.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertEqual(FlagSoundSettings.value(defaults: settings), "Glass")
        settings.set("none", forKey: FlagSoundSettings.key)
        XCTAssertEqual(FlagSoundSettings.value(defaults: settings), FlagSoundSettings.defaultValue, "a flag always sounds")
    }

    func testRoutineDialStops() {
        typealias P = RoutineDeliveryPolicy
        XCTAssertEqual(P.decide(level: .silent, focusSuppressed: false, attentionSuppressed: false), .none)
        XCTAssertEqual(P.decide(level: .quiet, focusSuppressed: false, attentionSuppressed: false), .banner(sound: false))
        XCTAssertEqual(P.decide(level: .normal, focusSuppressed: false, attentionSuppressed: false), .banner(sound: true))
        XCTAssertEqual(P.decide(level: .chatty, focusSuppressed: false, attentionSuppressed: false), .banner(sound: true))
        for level in NotificationLevel.allCases {
            XCTAssertEqual(P.decide(level: level, focusSuppressed: true, attentionSuppressed: false), .none,
                           "the operator looking at the panel still suppresses at \(level.rawValue)")
        }
        // 6. A delegate's routine stop goes to its owner, except at Chatty.
        XCTAssertEqual(P.decide(level: .normal, focusSuppressed: false, attentionSuppressed: true), .none)
        XCTAssertEqual(P.decide(level: .quiet, focusSuppressed: false, attentionSuppressed: true), .none)
        XCTAssertEqual(P.decide(level: .chatty, focusSuppressed: false, attentionSuppressed: true), .banner(sound: true))
        XCTAssertFalse(P.deliversMail(level: .normal))
        XCTAssertTrue(P.deliversMail(level: .chatty))
    }

    func testRoutineStoreAppliesTheDialAndKeepsTheRecordAtEveryStop() throws {
        AppFocusState.overrideIsFocused = false
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        store.configureNotificationSettingsDefaultsForTesting(settings)
        var delivered: [TerminalNotification] = []
        store.configureNotificationDeliveryHandlerForTesting { _, notification in delivered.append(notification) }
        let (workspace, surface) = panel()

        settings.set(NotificationLevel.silent.rawValue, forKey: NotificationLevel.key)
        store.addNotification(workspaceId: workspace, surfaceId: surface, title: "Turn ended", subtitle: "", body: "")
        XCTAssertTrue(delivered.isEmpty, "Silent posts no system banner")
        XCTAssertEqual(store.notifications.count, 1, "Silent still feeds the Feed and sidebar")
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace, surfaceId: surface))

        settings.set(NotificationLevel.quiet.rawValue, forKey: NotificationLevel.key)
        store.addNotification(workspaceId: workspace, surfaceId: surface, title: "Turn ended", subtitle: "", body: "")
        XCTAssertEqual(delivered.last?.deliversSound, false)

        settings.set(NotificationLevel.normal.rawValue, forKey: NotificationLevel.key)
        store.addNotification(workspaceId: workspace, surfaceId: surface, title: "Turn ended", subtitle: "", body: "")
        XCTAssertEqual(delivered.last?.deliversSound, true)
        XCTAssertEqual(delivered.count, 2)

        // A delegate: barred at Normal, delivered at Chatty.
        let (delegateWorkspace, delegateSurface) = panel()
        _ = try PanelAttentionService.shared.delegate(
            workspaceId: delegateWorkspace, surfaceId: delegateSurface, ownerPanelId: nil, by: .operator
        )
        store.addNotification(workspaceId: delegateWorkspace, surfaceId: delegateSurface, title: "Delegate done", subtitle: "", body: "")
        XCTAssertEqual(delivered.count, 2)
        settings.set(NotificationLevel.chatty.rawValue, forKey: NotificationLevel.key)
        store.addNotification(workspaceId: delegateWorkspace, surfaceId: delegateSurface, title: "Delegate done", subtitle: "", body: "")
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered.last?.title, "Delegate done")
    }

    func testQuietRoutineRequestCarriesNoSound() throws {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var built: [UNNotificationRequest] = []
        store.configureRoutineNotificationDeliveryHooksForTesting(
            authorization: { $0(true) },
            add: { request, completion in built.append(request); completion(nil) }
        )
        store.configureNotificationCustomCommandDefaultsForTesting(settings)
        func routine(sound: Bool) -> TerminalNotification {
            TerminalNotification(id: UUID(), workspaceId: UUID(), surfaceId: UUID(), title: "t", subtitle: "", body: "",
                                 createdAt: Date(), isRead: false, deliversSound: sound)
        }
        store.scheduleUserNotificationForTesting(routine(sound: false))
        store.scheduleUserNotificationForTesting(routine(sound: true))
        XCTAssertEqual(built.count, 2)
        XCTAssertNil(built.first?.content.sound)
        XCTAssertNotNil(built.last?.content.sound)
        XCTAssertNotEqual(built.last?.content.interruptionLevel, .timeSensitive, "only a flag asks for time-sensitive")
    }

    func testTheStopSurvivesARelaunchThroughTheSocketSet() {
        let done = expectation(description: "notification.level.set committed")
        let settings = self.settings!
        let box = FlagTestBox()
        DispatchQueue.global().async {
            box.result = TerminalController.v2NotificationLevel(
                method: "notification.level.set", params: ["level": "Quiet"], defaults: settings
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .ok(let payload)? = box.result else { return XCTFail("set failed: \(String(describing: box.result))") }
        XCTAssertEqual((payload as? [String: Any])?["level"] as? String, "quiet")
        // A relaunch reads the same defaults domain afresh.
        XCTAssertEqual(NotificationLevel.current(defaults: UserDefaults(suiteName: suiteName)!), .quiet)
        guard case .err = TerminalController.v2NotificationLevel(
            method: "notification.level.set", params: ["level": "loud"], defaults: settings
        ) else { return XCTFail("an unknown stop must be refused") }
        XCTAssertEqual(NotificationLevel.current(defaults: settings), .quiet)
    }

    // MARK: 6. A delegate's flag still escalates

    func testADelegatesFlagStillReachesTheOperator() throws {
        let (workspace, surface) = panel()
        _ = try PanelAttentionService.shared.delegate(workspaceId: workspace, surfaceId: surface, ownerPanelId: nil, by: .operator)
        settings.set(NotificationLevel.silent.rawValue, forKey: NotificationLevel.key)
        try raise(workspace, surface, "Needs the operator, not my owner")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.last?.content.interruptionLevel, .timeSensitive)
    }

    // MARK: 10. What an agent reads

    func testEachFlagAlertWritesOneRecordWithItsFieldsOnPostAndRemoval() throws {
        let (workspace, surface) = panel()
        try raise(workspace, surface, "Recorded")
        _ = try PanelAttentionService.shared.lower(workspaceId: workspace, surfaceId: surface, by: .operator)

        XCTAssertEqual(records.map(\.action), [.posted, .removed])
        for record in records {
            XCTAssertEqual(record.surfaceId, surface)
            XCTAssertEqual(record.workspaceId, workspace)
            XCTAssertEqual(record.payload["panel"] as? String, surface.uuidString.lowercased())
            XCTAssertEqual(record.payload["level"] as? String, "time_sensitive")
            XCTAssertEqual(record.payload["sound"] as? String, FlagSoundSettings.defaultValue)
            XCTAssertEqual(record.payload["source_host"] as? String, "local")
        }
        XCTAssertTrue(records[0].logLine.hasPrefix("notification.flag action=posted cause=raised panel=\(surface.uuidString.lowercased())"))
        XCTAssertEqual(records[1].payload["cause"] as? String, "lowered")
        // C11H-319: the line also says where the sound came from.
        XCTAssertTrue(records[1].logLine.contains("sound=\(FlagSoundSettings.defaultValue) sound_source=flag source_host=local"))
        XCTAssertEqual(records[0].payload["sound_source"] as? String, "flag")
    }

    func testAnOpenRemovalOfARelayedFlagNamesItsHost() throws {
        let (workspace, surface) = panel()
        _ = try PanelAttentionService.shared.raise(
            workspaceId: workspace, surfaceId: surface, reason: "From Linuxbox", title: "Owner", sourceHost: "linuxbox"
        )
        drainMain()
        TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)
        let removal = try XCTUnwrap(records.last)
        XCTAssertEqual(removal.cause, .opened)
        XCTAssertEqual(removal.sourceHost, "linuxbox")
        XCTAssertEqual(removal.sound, FlagSoundSettings.defaultValue)
        XCTAssertEqual(requests.last?.content.userInfo[FlagNotificationSpec.userInfoSourceHostKey] as? String, "linuxbox",
                       "the alert carries its host, so a later launch can still name it")
    }

    // MARK: Review repairs (C11H-246 repair 1)

    /// R2 #2: a revision never removes the alert that is up, even when the
    /// panel now counts as looked-at by the operator.
    func testARevisionNeverRemovesTheAlertThatIsUp() throws {
        let (workspace, surface) = panel()
        TerminalNotificationStore.shared.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)
        try raise(workspace, surface, "First reason") // not in front of the operator yet: posts
        let identifier = try XCTUnwrap(requests.last?.identifier)
        lookingAt = [surface]

        try raise(workspace, surface, "Revised reason")

        XCTAssertTrue(removals.isEmpty, "a revision never removes the alert")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.identifier, identifier)
        XCTAssertEqual(requests.last?.content.body, "Revised reason")
        XCTAssertEqual(records.last?.action, .replaced)
        XCTAssertTrue(PanelAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: surface).isFlagged)
    }

    /// R1 (Astra) B4: an operator open while the launch read is out is not
    /// undone when the read answers: the alert is neither re-adopted nor
    /// removed again.
    func testAnOpenWhileTheLaunchReadIsOutIsNotReadopted() throws {
        let store = TerminalNotificationStore.shared
        var answer: (([(String, [AnyHashable: Any])]) -> Void)?
        store.configureDeliveredFlagReaderForTesting { answer = $0 }
        let (workspace, surface) = panel()
        try raise(workspace, surface, "Opened during the read")
        let identifier = try XCTUnwrap(requests.last?.identifier)

        store.reconcileDeliveredFlagNotifications()
        store.dismissFlagNotificationForOperatorOpen(workspaceId: workspace, surfaceId: surface)
        XCTAssertEqual(removals, [identifier])
        let recordsBefore = records.count
        try XCTUnwrap(answer)([(identifier, [:])])
        drainMain()

        XCTAssertFalse(store.postedFlagIdentifiersForTesting().contains(identifier), "not re-adopted")
        XCTAssertEqual(removals, [identifier], "not removed a second time")
        XCTAssertEqual(records.count, recordsBefore, "no stale_at_launch record")
        XCTAssertTrue(PanelAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: surface).isFlagged)
    }

    /// R2 #3: the launch read answers late; a flag raised while it was in
    /// flight keeps its alert, and only the alert nothing owns goes.
    func testLaunchReconcileReadsOwnershipWhenNotificationCenterAnswers() throws {
        let store = TerminalNotificationStore.shared
        var answer: (([(String, [AnyHashable: Any])]) -> Void)?
        store.configureDeliveredFlagReaderForTesting { answer = $0 }
        let stale = FlagNotificationSpec.identifier(workspaceId: UUID(), surfaceId: UUID(), flagRaisedAt: Date(timeIntervalSince1970: 1))

        store.reconcileDeliveredFlagNotifications() // the AppDelegate call, default ownership read
        let (workspace, surface) = panel()
        try raise(workspace, surface, "Raised while the read was in flight")
        let fresh = try XCTUnwrap(requests.last?.identifier)
        removals = []
        let respond = try XCTUnwrap(answer)
        let done = expectation(description: "read answered off main")
        DispatchQueue.global().async {
            respond([(fresh, [:]), (stale, [:]), ("routine-\(UUID().uuidString)", [:])])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        drainMain()

        XCTAssertEqual(removals, [stale])
        XCTAssertEqual(records.last?.cause, .staleAtLaunch)
    }

    /// R2 #4: a launch removal names the panel, and the sound and host the
    /// alert carried; an older build's alert says unknown.
    func testLaunchRemovalRecordsCarryAttribution() throws {
        let store = TerminalNotificationStore.shared
        var answer: (([(String, [AnyHashable: Any])]) -> Void)?
        store.configureDeliveredFlagReaderForTesting { answer = $0 }
        let workspace = UUID(), surface = UUID(), legacyPanel = UUID()
        let carried = FlagNotificationSpec.make(
            workspaceId: workspace, surfaceId: surface, flagRaisedAt: Date(timeIntervalSince1970: 2),
            title: nil, reason: "gone", kind: nil, sourceHost: "studio", defaults: settings
        )
        let legacy = FlagNotificationSpec.identifier(workspaceId: workspace, surfaceId: legacyPanel, flagRaisedAt: Date(timeIntervalSince1970: 3))

        store.reconcileDeliveredFlagNotifications(raisedIdentifiers: { [] })
        try XCTUnwrap(answer)([(carried.identifier, carried.userInfo), (legacy, [:])])
        drainMain()

        XCTAssertEqual(records.count, 2)
        let byPanel = Dictionary(uniqueKeysWithValues: records.map { ($0.surfaceId, $0) })
        XCTAssertEqual(byPanel[surface]?.sourceHost, "studio")
        XCTAssertEqual(byPanel[surface]?.sound, FlagSoundSettings.defaultValue)
        XCTAssertEqual(byPanel[surface]?.workspaceId, workspace)
        XCTAssertEqual(byPanel[legacyPanel]?.sourceHost, FlagNotificationAttribution.unknown)
        XCTAssertEqual(byPanel[legacyPanel]?.sound, FlagNotificationAttribution.unknown)
        XCTAssertEqual(byPanel[legacyPanel]?.payload["panel"] as? String, legacyPanel.uuidString.lowercased())
    }

    /// R1 (Grok) NB3: an add that completes after its flag was lowered left
    /// an alert nothing owned; it is taken down when the add lands.
    func testAnAddThatLandsAfterItsFlagWasLoweredIsRemoved() throws {
        var held: ((Error?) -> Void)?
        TerminalNotificationStore.shared.configureFlagNotificationObservationForTesting(
            request: { [weak self] request, completion in self?.requests.append(request); held = completion },
            removal: { [weak self] in self?.removals.append($0) },
            record: { [weak self] in self?.records.append($0) },
            operatorLooking: { _, _ in false },
            settings: settings
        )
        let (workspace, surface) = panel()
        try raise(workspace, surface, "Lowered before the add finished")
        let identifier = try XCTUnwrap(requests.last?.identifier)
        _ = try PanelAttentionService.shared.lower(workspaceId: workspace, surfaceId: surface, by: .agent)
        XCTAssertEqual(removals, [identifier])

        try XCTUnwrap(held)(nil)
        drainMain()

        XCTAssertEqual(removals, [identifier, identifier], "the late alert is removed when it lands")
    }

    /// R2 #5: one real dispatcher delivery at Chatty posts exactly one banner
    /// for the recipient, and touches no store, waiting or liveness state.
    func testChattyMailPostsOneBannerThroughTheDispatcher() throws {
        let fixture = try MailFixture(settings: settings, suiteName: suiteName)
        defer { fixture.tearDown() }

        settings.set(NotificationLevel.chatty.rawValue, forKey: NotificationLevel.key)
        try fixture.deliver(body: "chatty")
        drainMain()

        XCTAssertEqual(fixture.banners.count, 1)
        XCTAssertEqual(fixture.banners.first?.workspaceId, fixture.workspaceId)
        XCTAssertEqual(fixture.banners.first?.surfaceId, fixture.recipient)
        XCTAssertEqual(fixture.banners.first?.body, "From sender")
        XCTAssertTrue(fixture.store.notifications.isEmpty, "no store record")
        XCTAssertTrue(fixture.waitingEdges.isEmpty, "no waiting edge")
        XCTAssertFalse(fixture.store.hasUnreadNotification(forWorkspaceId: fixture.workspaceId, surfaceId: fixture.recipient))
        XCTAssertNil(PanelActivityTracker.shared.lastActivity(for: fixture.recipient.uuidString),
                     "no liveness activity recorded for the recipient")
    }

    func testNoMailBannerBelowChatty() throws {
        let fixture = try MailFixture(settings: settings, suiteName: suiteName)
        defer { fixture.tearDown() }
        for level in [NotificationLevel.silent, .quiet, .normal] {
            settings.set(level.rawValue, forKey: NotificationLevel.key)
            try fixture.deliver(body: level.rawValue)
            drainMain()
        }
        XCTAssertTrue(fixture.banners.isEmpty)
    }
}

/// A real `MailboxDispatcher` with one live recipient, the shared store's
/// banner delivery captured, and the dial read from the test's suite.
@MainActor
private final class MailFixture {
    let workspaceId = UUID()
    let recipient = UUID()
    let state: URL
    let dispatcher: MailboxDispatcher
    let store = TerminalNotificationStore.shared
    var banners: [TerminalNotification] = []
    var waitingEdges: [Bool] = []
    private let priorMailDefaults = TerminalNotificationStore.mailLevelDefaults
    private let priorNotifications: [TerminalNotification]

    init(settings: UserDefaults, suiteName: String) throws {
        state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-246-mail-\(UUID().uuidString)", isDirectory: true)
        for dir in [MailboxLayout.outboxURL(state: state, workspaceId: workspaceId),
                    MailboxLayout.processingURL(state: state, workspaceId: workspaceId),
                    MailboxLayout.rejectedURL(state: state, workspaceId: workspaceId)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        _ = try PanelMetadataStore.shared.setMetadata(
            workspaceId: workspaceId, surfaceId: recipient,
            partial: [MetadataKey.title: "chatty-recipient"], mode: .merge, source: .explicit
        )
        let live = recipient
        dispatcher = MailboxDispatcher(
            workspaceId: workspaceId, stateURL: state,
            resolver: MailboxPanelResolver(workspaceId: workspaceId, livePanels: { [live] })
        )
        priorNotifications = store.notifications
        store.replaceNotificationsForTesting([])
        TerminalNotificationStore.mailLevelDefaults = settings
        store.configureNotificationDeliveryHandlerForTesting { [weak self] _, notification in
            self?.banners.append(notification)
        }
        store.configureWaitingEdgeHandlerForTesting { [weak self] entered, _ in self?.waitingEdges.append(entered) }
    }

    func deliver(body: String) throws {
        let envelope = try MailboxEnvelope.build(from: "sender", to: "chatty-recipient", body: body)
        let outbox = MailboxLayout.outboxURL(state: state, workspaceId: workspaceId)
        let url = outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        try MailboxIO.atomicWrite(data: try envelope.encode(), to: url)
        dispatcher.dispatchOne(url: url)
        let inbox = MailboxLayout.inboxURL(state: state, workspaceId: workspaceId, panelId: recipient)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: envelope.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path), "the envelope reached the recipient's inbox")
    }

    func tearDown() {
        dispatcher.log.flush()
        TerminalNotificationStore.mailLevelDefaults = priorMailDefaults
        store.resetNotificationDeliveryHandlerForTesting()
        store.resetWaitingEdgeHandlerForTesting()
        store.replaceNotificationsForTesting(priorNotifications)
        PanelMetadataStore.shared.removeSurface(workspaceId: workspaceId, surfaceId: recipient)
        try? FileManager.default.removeItem(at: state)
    }
}
