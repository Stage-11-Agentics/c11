import Foundation
import Combine
import AppKit
import Bonsplit

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the bonsplit-based layout system.
@MainActor
final class TerminalPanel: Panel, ObservableObject {
    var pendingHCConversationRecovery: HCPendingConversationRecovery? {
        didSet {
            // C11H-203: a launch resume that no longer stands (ended on
            // purpose, typed over, kept, closed) leaves the Ask question.
            if oldValue?.launchScoped == true, pendingHCConversationRecovery?.launchScoped != true {
                LaunchResumeGate.shared.forget(id)
            }
        }
    }
    var retainsAfterEndAllSessions = false
    /// C11H-46: set when an explicit close asked hc to end this panel's
    /// terminal, so the end backstop does not count this panel as a holder.
    var hcClosingForEnd = false
    /// C11H-434: the end the operator asked for on this panel (End All, End
    /// Session), so a kept panel names it. Cleared when a new shell starts.
    var hcRequestedEnd: HCEndOrigin? {
        didSet {
            guard hcRequestedEnd != oldValue else { return }
            // The surface keeps its last screen when hc closes the ended stream.
            surface.hcKeepsScreenAfterEnd = hcRequestedEnd != nil
            refreshHCEndedNotice()
        }
    }
    /// C11H-434: shown while this panel is kept after its terminal ended.
    @Published private(set) var hcEndedNotice: HCEndedPanelNotice? {
        didSet { if hcEndedNotice != oldValue { reportRecoveryDiagnostics() } }
    }
    /// C11H-434: Start a new shell is under way; its button waits.
    @Published private(set) var hcStartingNewShell = false
    /// C11H-434: why the last Start a new shell did not give a shell.
    @Published private(set) var hcNewShellFailure: String?

    /// Recomputes the ended notice from the lifecycle the runtime is about to
    /// publish (a `@Published` sink sees the value before it is stored). Each
    /// write is guarded, so a live terminal's record and status updates
    /// publish nothing to the panel's view.
    func refreshHCEndedNotice(lifecycle: HCLifecycle? = nil) {
        let current = lifecycle ?? hcSession?.lifecycle
        let shown = hcEndedNotice
        let next: HCEndedPanelNotice?
        if let made = HCEndedPanelNotice.make(lifecycle: current, requestedEnd: hcRequestedEnd, observedAt: Date()) {
            // The same end keeps its first time: hc republishes an end, and an
            // untimed one would otherwise move to each republish's time.
            if let shown, shown.endedKey == made.endedKey, shown.reason == made.reason { next = shown } else { next = made }
        } else if shown != nil, keepsHCEndedNotice(through: current) {
            next = shown
        } else {
            next = nil
        }
        guard next != shown else { return }
        hcEndedNotice = next
        if hcNewShellFailure != nil { hcNewShellFailure = nil }
        // Keys pressed while it was ended were refused and their notice
        // hidden; a new shell must not inherit that stale "reconnects" strip.
        if next == nil { hcSession?.disconnectedInput?.dismissRefusal() }
    }

    /// C11H-434: once shown, the notice stays until a new shell is usable in
    /// this panel. A start under way, or one that did not give a shell, keeps
    /// it with its retry; so does a lost line (`.unresolved`), since an ended
    /// terminal never comes back. A live terminal, or no runtime, clears it.
    private func keepsHCEndedNotice(through lifecycle: HCLifecycle?) -> Bool {
        if hcStartingNewShell || hcNewShellFailure != nil { return true }
        if case .unresolved? = lifecycle { return true }
        return false
    }

    private var hcEndedNoticeSubscription: AnyCancellable?

    /// C11H-434: the ended notice follows the runtime's lifecycle. It changes
    /// only at an end or a new shell, so a live terminal's status updates
    /// publish nothing to the panel's view.
    private func followHCEndedNotice(_ runtime: HCPanelSession) {
        hcEndedNoticeSubscription = runtime.$lifecycle.sink { [weak self] lifecycle in
            self?.refreshHCEndedNotice(lifecycle: lifecycle)
        }
    }

    #if DEBUG
    /// Test seam: installs a runtime on this panel's surface and follows it, as
    /// a production panel follows the runtime its surface starts with.
    func installHCSessionForTesting(_ runtime: HCPanelSession) {
        surface.installHCSessionForTesting(runtime)
        followHCEndedNotice(runtime)
    }
    #endif

    /// How long Start a new shell waits for a creation it began to be live and
    /// attached before it says the shell did not start. A test seam.
    static var hcNewShellUsableTimeout: TimeInterval = 15

    /// C11H-434: Start a new shell on an ended panel: a fresh login shell in
    /// this panel (on its own machine), through the same start a host end's
    /// recovery uses. The notice stays through the start; a start that does
    /// not give a usable shell keeps it, says so, and offers the retry.
    func startNewShellAfterEnd() {
        guard hcEndedNotice != nil, !hcStartingNewShell, let runtime = hcSession else { return }
        hcStartingNewShell = true
        if hcNewShellFailure != nil { hcNewShellFailure = nil }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.startNewShell(on: runtime)
            guard outcome == .usable, self.hcSession === runtime else {
                self.hcNewShellFailure = outcome == .unconfirmed
                    ? String(localized: "terminal.ended.startUnconfirmed",
                        defaultValue: "The terminal host has not confirmed the new shell, so c11 won't start a second one. Try again to check, or close the panel.")
                    : String(localized: "terminal.ended.startFailed",
                        defaultValue: "A new shell could not be started. Try again, or close the panel.")
                self.hcStartingNewShell = false
                return
            }
            self.hcStartingNewShell = false
            // The panel is an ordinary terminal again: its next exit closes it.
            self.retainsAfterEndAllSessions = false
            self.hcClosingForEnd = false
            self.hcRequestedEnd = nil
            self.refreshHCEndedNotice()
        }
    }

    /// How a Start a new shell ended: a shell in the panel, none, or a creation
    /// hc has not confirmed either way (c11 never starts a second over it).
    enum HCNewShellOutcome: Equatable { case usable, failed, unconfirmed }

    /// One new shell, never two. After a start that did not give a shell, the
    /// panel's own creation is looked up first: one that ran after all is
    /// adopted, one hc has not settled is reported unconfirmed, and only a
    /// panel whose terminal is still the ended one starts a new terminal.
    private func startNewShell(on runtime: HCPanelSession) async -> HCNewShellOutcome {
        // An end the coordinator still owes names the old terminal's key, never the new one's.
        if let coordinator = HCSessionEnd.coordinator, coordinator.isEndPending(panelID: id) {
            _ = await coordinator.outcomes(for: [id], timeout: 5)
        }
        do {
            if case .ended = runtime.lifecycle {} else {
                switch await runtime.resolveIdentity() {
                case .ended: break
                case .live(let record):
                    if runtime.attachment == nil { _ = try await surface.recreateHCAttachment(record) }
                    return await hcNewShellIsUsable(runtime) ? .usable : .failed
                case .unresolved(_, .creationPending), .unresolved(_, .creationUncertain): return .unconfirmed
                case .new, .unresolved: return .failed
                }
            }
            try await surface.startHostEndReplacement()
            return await hcNewShellIsUsable(runtime) ? .usable : .failed
        } catch {
            return .failed
        }
    }

    /// A start that returns once its creation is under way (a panel never
    /// started this launch) attaches later: wait, bounded, for a bound terminal.
    private func hcNewShellIsUsable(_ runtime: HCPanelSession) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.hcNewShellUsableTimeout)
        while hcSession === runtime {
            if case .live = runtime.lifecycle, runtime.attachment != nil { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Ended terminals whose conversation recovery was already planned. A
    /// retained replacement record must not plan the same end twice.
    var plannedHCEndedKeys: Set<HCTerminalKey> = []
    /// C11H-196: the host end this panel is recovering from (one per ended
    /// key), for its banner, its Resume conversation action and diagnostics.
    @Published var hcHostEnd: HCHostEndStatus? {
        didSet {
            guard hcHostEnd != oldValue else { return }
            // A record now explains the end: a live replacement needs no notice.
            if hcHostEnd != nil, hcRestoreNotice == .holderLost || hcRestoreNotice == .previousSessionEnded,
               let runtime = hcSession, case .live = runtime.lifecycle { hcRestoreNotice = nil }
            reportRecoveryDiagnostics()
            HCRestoreProgress.shared.update(panelID: id, workspaceID: workspaceId, status: hcHostEnd,
                                            carried: restoringCarriedHostEnd)
        }
    }
    /// The operator closed the host-end banner for this ended key.
    @Published private(set) var hcHostEndDismissedKey: HCTerminalKey?

    func dismissHCHostEnd() {
        hcHostEndDismissedKey = hcHostEnd?.endedKey
        // The banner under it (an ended panel's) now shows: diagnostics follow.
        reportRecoveryDiagnostics()
    }
    func resetHCHostEndDismissal() { hcHostEndDismissedKey = nil }

    /// C11H-209: ends the previous session found on this panel and never
    /// planned a resume for. A launch offers them instead of resuming them.
    var hcEndsFoundByPreviousSession: Set<HCTerminalKey> = []
    /// Set while a record carried over from the previous session is restored,
    /// so the restore strip does not count it as this launch's.
    private var restoringCarriedHostEnd = false

    /// C11H-209: a restored panel takes back its settled decisions, so its
    /// ended terminal is not decided again, and a record still waiting on the
    /// operator shows (and offers Resume) as it did before the relaunch.
    func restoreSavedHostEnd(_ saved: HCSavedHostEnd) {
        plannedHCEndedKeys.formUnion(saved.decidedKeys)
        hcEndsFoundByPreviousSession.formUnion(saved.foundEndedKeys)
        guard let record = saved.record, record.isSettled, record.needsOperator else { return }
        plannedHCEndedKeys.insert(record.endedKey)
        restoringCarriedHostEnd = true
        defer { restoringCarriedHostEnd = false }
        hcHostEnd = record
    }

    /// The banner shows while recovery is underway or has failed, until the
    /// operator closes it; a resumed panel or a fresh plain shell shows none.
    var visibleHCHostEnd: HCHostEndStatus? {
        guard let status = hcHostEnd, status.endedKey != hcHostEndDismissedKey else { return nil }
        switch status.phase {
        case .resumed: return nil
        case .noConversation:
            if let runtime = hcSession, case .live = runtime.lifecycle { return nil }
            return status
        default: return status
        }
    }
    let id: UUID
    /// Ownership is tied to this object, independent of a restored/reused tab UUID.
    let launchPromptOwner = UUID()
    let createdAt: Date?
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface
    /// Persistent identity remains available even while the backend is unresolved.
    var hcIdentity: HCPanelIdentity? {
        guard let identity = surface.hcSession?.identity, identity.persistence == .persistent else { return nil }
        return identity
    }
    var hcSession: HCPanelSession? { surface.hcSession }
    /// Ticket 12: the machine this terminal runs on when it is not this Mac.
    var hcRemoteTarget: HCRemoteTarget? { surface.hcRemoteTarget }
    @Published private(set) var hcRestoreNotice: HCRestoreLifecycleProjection.Notice? {
        didSet { if hcRestoreNotice != oldValue { reportRecoveryDiagnostics() } }
    }

    /// C11H-196: `hc-diagnostics --json` reports what the banner shows.
    private func reportRecoveryDiagnostics() {
        let notice: String?
        // C11H-434: whenever the ended banner is the one showing, say why it ended.
        if let ended = hcEndedNotice, visibleHCHostEnd == nil {
            notice = "session_ended:" + ended.reasonToken
        } else {
            switch hcRestoreNotice {
            case .holderLost: notice = "holder_lost"
            case .resourceExhausted: notice = "resource_exhausted"
            case .previousSessionEnded: notice = "previous_session_ended"
            case nil: notice = nil
            }
        }
        var hostEnd: [String: Any]?
        if let status = hcHostEnd {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            hostEnd = [
                "state": status.stateToken,
                "record": status.recordState,
                "reason": status.reasonToken as Any? ?? NSNull(),
                "cause": status.causeToken,
                "signal": status.signal.map { Int($0) } as Any? ?? NSNull(),
                "ended_at": formatter.string(from: status.endedAt),
                "conversation_id": status.conversation?.id as Any? ?? NSNull(),
                "offers_resume": status.offersResume,
            ]
        }
        HCDiagnosticRecorder.shared.recordPanelRecovery(panelID: id, notice: notice, hostEnd: hostEnd)
    }
    private var hcDismissedRestoreNotice: HCRestoreLifecycleProjection.Notice?
    private struct RecoveryClaim: Equatable {
        let key: HCTerminalKey?
        let creationID: UUID?
        let unresolved: Bool
    }
    private var hcRecoveryClaim: RecoveryClaim?

    func dismissHCRestoreNotice() {
        hcDismissedRestoreNotice = hcRestoreNotice
        hcRestoreNotice = nil
    }

    var permitsConversationResume: Bool {
        guard let hcSession, hcIdentity?.persistence == .persistent else { return true }
        return HCRestoreLifecycleStore.shared.permitsResume(hcSession)
    }

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    /// Published title from the terminal process
    @Published private(set) var title: String = "Terminal"

    /// Published directory from the terminal
    @Published private(set) var directory: String = ""

    /// Search state for find functionality
    @Published var searchState: TerminalSurface.SearchState? {
        didSet {
            surface.searchState = searchState
        }
    }

    /// Bump this token to force SwiftUI to call `updateNSView` on `GhosttyTerminalView`,
    /// which re-attaches the hosted view after bonsplit close/reparent operations.
    ///
    /// Without this, certain pane-close sequences can leave terminal views detached
    /// (hostedView.window == nil) until the user switches workspaces.
    @Published var viewReattachToken: UInt64 = 0

    // MARK: - [TextBox] Per-panel TextBoxInput state
    //
    // Each terminal panel owns its own TextBox visibility flag, draft
    // content buffer, and a weak reference to the live InputTextView so
    // the workspace can swap focus between the TextBox and the terminal
    // without walking the AppKit responder chain. The `@Published`
    // flags let SwiftUI react to toggle changes; the input view is a
    // non-published `weak` so view lifecycle does not churn observers.

    /// Whether the TextBox is mounted for this panel. Hidden by default;
    /// Cmd+Option+B summons and dismisses it per panel.
    @Published var isTextBoxActive: Bool = false

    /// Draft text currently held in the TextBox. Preserved across tab
    /// switches so users do not lose in-flight prompts.
    @Published var textBoxContent: String = ""

    /// Live InputTextView for this panel (when mounted). Used by
    /// `Workspace.toggleTextBoxMode` to detect and move focus.
    weak var inputTextView: InputTextView?

    /// Per-surface lifecycle controller (C11-25). Owns the canonical
    /// `lifecycle_state` metadata mirror and dispatches occlusion to
    /// libghostty on state transitions. Visibility is driven from
    /// `TerminalPanelView` via `applyVisibility(_:)`.
    let lifecycle: PanelLifecycleController

    private var cancellables = Set<AnyCancellable>()

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
    }

    var isDirty: Bool {
        // Bonsplit's "dirty" indicator is a very small dot in the tab strip.
        //
        // For terminals, `ghostty_surface_needs_confirm_quit` is driven by shell integration
        // heuristics and can be transiently (or permanently) wrong, which results in a dot
        // showing on every new terminal. That reads as a notification/alert and is misleading.
        //
        // We still honor `needsConfirmClose()` when actually closing a panel; we just don't
        // surface it as a tab-level dirty indicator.
        false
    }

    /// The hosted NSView for embedding in SwiftUI
    var hostedView: GhosttySurfaceScrollView {
        surface.hostedView
    }

    var requestedWorkingDirectory: String? {
        surface.requestedWorkingDirectory
    }

    /// Post-boot prompts wait for a real launcher Return. Reuse the existing
    /// nonqueued completion primitive without changing send/mailbox behavior.
    func submitLaunchPlan(_ plan: LaunchPromptDelivery.Plan,
                          isLive: @escaping @MainActor () -> Bool,
                          requestBackgroundStart: Bool = true) {
        isLaunchPending = true
        guard let prompt = plan.delayedPrompt else {
            // Pending until the launcher's Return is actually written (queued before the terminal attaches), so a
            // retry meanwhile finds this panel instead of making a second agent.
            if isLive() {
                surface.sendLaunchLine(plan.launchLine) { [weak self] _ in self?.isLaunchPending = false }
            } else {
                isLaunchPending = false
            }
            return
        }
        if requestBackgroundStart, surface.surface == nil {
            surface.requestBackgroundSurfaceStartIfNeeded()
        }
        // Bind when the launcher becomes ready, then preserve that generation
        // across the launcher completion and post-boot prompt delay.
        let binding = LaunchGenerationBinding<TerminalSurface.InputGenerationStamp>()
        let sequence = LaunchPostBootSequence(
            launcher: plan.launchLine, prompt: prompt, isLive: isLive,
            isReady: { [weak self] in
                guard let self else { return false }
                // C11H-112: a terminal running headless takes the prompt through hc like a shown one.
                let hasTerminal = self.surface.surface != nil || MainActor.assumeIsolated { self.surface.hcHeadlessBridge != nil }
                return hasTerminal && self.surface.isHCInputReady && !self.surface.isInputTransactionActive
            },
            submit: { [weak self] text, completion in
                guard let self else { completion(false); return }
                binding.bindIfNeeded { self.surface.captureInputGeneration() }
                self.surface.sendSubmitFormText(text, shouldSubmit: { [weak self] in
                    guard let self else { return false }
                    return binding.admitsSubmit(isLive: isLive(), isCurrent: { self.surface.isInputGenerationCurrent($0) })
                }, completion: completion)
            },
            generationIsCurrent: { [weak self] in
                guard let self else { return false }
                return binding.isCurrent { self.surface.isInputGenerationCurrent($0) }
            },
            isBlockedByDialog: { [weak self] in
                // An unreadable screen does not hold the prompt (today's behavior).
                guard let self, let live = self.surface.surface,
                      let region = TerminalController.shared.capturePromptInputRegion(surface: live, harness: nil) else {
                    return false
                }
                return PromptInputClassifier.classify(region, harness: nil).state == .dialog
            },
            headlessReadiness: { [weak self] in
                // No Ghostty surface: hc's own agent status is the gate (C11H-116). nil keeps the screen path.
                guard let self else { return nil }
                return MainActor.assumeIsolated {
                    guard self.surface.surface == nil, self.surface.hcHeadlessBridge != nil else { return nil }
                    return HCHeadless.promptReadiness(self.surface.hcLiveRecord)
                }
            },
            onFailure: { [weak self] reason in self?.reportLaunchPromptNotDelivered(reason: reason) },
            onFinished: { [weak self] in self?.isLaunchPending = false }
        )
        sequence.start()
    }

    /// Ticket 12 (T12.1): launch an agent with a prompt in a terminal on
    /// another machine. Once that terminal is live the staged prompt is sent
    /// there, the launch is composed with the remote path, and only then
    /// submitted, once. If the prompt cannot be sent, nothing is launched and
    /// the operator is told.
    func submitRemoteLaunch(promptURL: URL, isLive: @escaping @MainActor () -> Bool,
                            compose: @escaping @MainActor (String) -> LaunchPromptDelivery.Plan?) {
        isLaunchPending = true
        let machine = hcRemoteTarget.map { HCMachineTarget.displayName($0.machine) } ?? ""
        guard let runtime = surface.hcSession, let transfer = runtime.session as? any HCFileTransfer else {
            reportRemoteLaunchFailure(machine: machine, reason: "no hc session"); return
        }
        if surface.surface == nil { surface.requestBackgroundSurfaceStartIfNeeded() }
        Task { @MainActor [weak self] in
            guard let record = await runtime.liveRecord(within: HCLimits.creationResolutionSeconds) else {
                self?.reportRemoteLaunchFailure(machine: machine, reason: "terminal not live"); return
            }
            let sent = await HCRemoteLaunchPrompt.send(prompt: promptURL, to: record.key, via: transfer)
            guard let self, isLive() else { return }
            switch sent {
            case .success(let path):
                guard let plan = compose(path) else {
                    self.reportRemoteLaunchFailure(machine: machine, reason: "compose"); return
                }
                self.submitLaunchPlan(plan, isLive: isLive)
            case .failure(let failure):
                self.reportRemoteLaunchFailure(machine: machine, reason: String(describing: failure))
            }
        }
    }

    /// C11H-116: set while a launch's command or prompt has not been delivered; a retry of the same launch finds
    /// this panel instead of making a second agent.
    var launchKey: String?
    var isLaunchPending = false

    /// The agent started but its prompt was not delivered: shown to the operator with the reason, never typed
    /// into a dialog.
    /// Test seam: observes a launch whose prompt was not delivered. Nil in production.
    nonisolated(unsafe) static var launchFailureSink: ((TerminalPanel, String) -> Void)?

    func reportLaunchPromptNotDelivered(reason: String) {
        isLaunchPending = false
        Self.launchFailureSink?(self, reason)
        NSLog("hc.launch.prompt_not_delivered panel=%@ reason=%@", id.uuidString, reason)
        let why = reason == "blocked"
            ? String(localized: "agentLaunch.promptBlocked", defaultValue: "the agent is waiting on a question or dialog")
            : String(localized: "agentLaunch.promptNeverReady", defaultValue: "the agent never reached its prompt")
        AppDelegate.shared?.notificationStore?.addNotification(
            workspaceId: workspaceId, surfaceId: id, title: displayTitle, subtitle: "",
            body: String(format: String(localized: "agentLaunch.promptNotDelivered",
                defaultValue: "The agent's prompt was not delivered: %@. The agent was not given its task."), why))
    }

    private func reportRemoteLaunchFailure(machine: String, reason: String) {
        isLaunchPending = false
        NSLog("hc.launch.prompt_not_sent panel=%@ reason=%@", id.uuidString, reason)
        AppDelegate.shared?.notificationStore?.addNotification(
            workspaceId: workspaceId, surfaceId: id, title: displayTitle, subtitle: "",
            body: String(format: String(localized: "agentLaunch.remotePromptFailed",
                defaultValue: "Couldn't send the agent prompt to %@. The agent was not started."), machine))
    }

    /// The Settings and New Workspace rails share asynchronous staging and
    /// revalidate their actual target before binding ownership and submitting.
    /// Mission reads and prompt staging share the worker path. The callback
    /// revalidates the captured workspace root as well as the actual panel.
    func submitConfiguredAgentLaunch(agent: AgentType, launch: ResolvedAgentLaunch,
                                     missionRoot: String? = nil,
                                     isLive: @escaping @MainActor () -> Bool) {
        let delivery = AgentRegistry.shared.manifest(for: agent)?.launch.promptDelivery ?? .postBoot
        let isRemote = hcRemoteTarget != nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let context = WorkspaceMissionLaunchContext.forLaunch(isRemote: isRemote, missionRoot: missionRoot)
            let prompt = launch.initialPrompt
            let staged: LaunchPromptStore.StagedPrompt?
            do {
                if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    staged = try LaunchPromptStore.shared.stage(prompt: prompt)
                } else {
                    staged = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, isLive() else { return }
                    AppDelegate.shared?.notificationStore?.addNotification(
                        workspaceId: self.workspaceId, surfaceId: self.id, title: agent.displayName,
                        subtitle: "",
                        body: String(localized: "agentLaunch.promptStagingFailed", defaultValue: "Couldn't prepare the agent prompt. Check c11's runtime storage permissions and try again.")
                    )
                }
                return
            }
            let command = context.command(launch.command)
            let plan = LaunchPromptDelivery.compose(
                command: command, delivery: delivery, promptFilePath: staged?.url.path
            )
            DispatchQueue.main.async {
                guard let self, isLive() else {
                    if let staged { DispatchQueue.global(qos: .utility).async { LaunchPromptStore.shared.discard(staged) } }
                    return
                }
                do {
                    if let staged { try LaunchPromptStore.shared.retain(staged, owner: self.launchPromptOwner) }
                    if isRemote, let staged {
                        // C11H-138: an operator launch on another machine sends
                        // the prompt file there first and composes with the path
                        // it lands at, as `launch-agent --on` does.
                        self.submitRemoteLaunch(promptURL: staged.url, isLive: isLive) { remotePath in
                            LaunchPromptDelivery.compose(command: command, delivery: delivery, promptFilePath: remotePath)
                        }
                    } else {
                        self.submitLaunchPlan(plan, isLive: isLive)
                    }
                } catch {
                    if let staged { DispatchQueue.global(qos: .utility).async { LaunchPromptStore.shared.discard(staged) } }
                }
            }
        }
    }

    init(workspaceId: UUID, surface: TerminalSurface, createdAt: Date? = Date()) {
        self.id = surface.id
        self.createdAt = createdAt
        self.workspaceId = workspaceId
        self.surface = surface
        surface.configureHCSessionIfNeeded()
        self.lifecycle = PanelLifecycleController(
            workspaceId: workspaceId,
            surfaceId: surface.id,
            initial: .active
        ) { [weak surface] _, target in
            // Pause libghostty's CVDisplayLink wakeups when the surface
            // leaves `.active`. PTY drains in every state — only the
            // renderer is throttled. Called on workspace-selection edge
            // events; never on the typing-latency hot path.
            surface?.setOcclusion(target == .active)
        }

        if let hcSession = surface.hcSession {
            HCRestoreLifecycleStore.shared.observe(hcSession)
            hcSession.$lifecycle.sink { [weak self] lifecycle in
                guard let self else { return }
                // Repeated inventory updates describe the same interruption.
                // Recovery permits a later interruption to show a new notice.
                if case .live = lifecycle { self.hcDismissedRestoreNotice = nil }
                let notice = HCRestoreLifecycleProjection.notice(for: lifecycle,
                    retaining: self.hcRestoreNotice, hostEndCovered: self.hcHostEnd != nil)
                let visibleNotice = notice == self.hcDismissedRestoreNotice ? nil : notice
                if self.hcRestoreNotice != visibleNotice { self.hcRestoreNotice = visibleNotice }
                let claim: RecoveryClaim
                switch lifecycle {
                case .live(let record):
                    claim = RecoveryClaim(key: record.key, creationID: hcSession.identity.creationID, unresolved: false)
                case .unresolved(let identity, _):
                    claim = RecoveryClaim(key: identity.key, creationID: identity.creationID, unresolved: true)
                case .new, .ended:
                    claim = RecoveryClaim(key: hcSession.identity.key, creationID: hcSession.identity.creationID, unresolved: false)
                }
                if self.hcRecoveryClaim != claim {
                    self.hcRecoveryClaim = claim
                    // @Published emits before identity is updated. Reconcile
                    // after the claim completes, only when the claim changes;
                    // title/status inventory updates do not enqueue more work.
                    DispatchQueue.main.async { AppDelegate.shared?.hcPanelClaimsChanged() }
                }
            }.store(in: &cancellables)
            followHCEndedNotice(hcSession)
            // Gap 6: the chip for a local terminal (remote terminals are fed
            // by HCRemoteStatusBinding).
            LocalSessionPlacementFeed.follow(
                lifecycle: hcSession.$lifecycle,
                persistence: { [weak hcSession] in hcSession?.identity.persistence ?? .persistent },
                isRemote: surface.hcRemoteTarget != nil
            ) { [weak self] lifecycle, persistence, machineName in
                self?.noteLocalPlacement(lifecycle, persistence, machineName)
            }?.store(in: &cancellables)
        }

        // C11-25 commit 6: register with the per-surface CPU/RSS sampler.
        //
        // C11-25 fix DoD #5: terminal CPU/MEM is now wired via the
        // Sendable pid-provider rail. The provider is installed in
        // `TerminalController.reportTTY` once the shell announces its
        // tty (the only point in time where the tty name is known to
        // the app side); the sampler invokes `TerminalPIDResolver`
        // every couple of seconds to track the foreground process.
        // Until that report lands, the surface is registered without
        // a pid and the sidebar renders `—`.
        PanelMetricsSampler.shared.register(surfaceId: surface.id)

        // Subscribe to surface's search state changes
        surface.$searchState
            .sink { [weak self] state in
                if self?.searchState !== state {
                    self?.searchState = state
                }
            }
            .store(in: &cancellables)

        // C11H-127: the first new terminal on another machine teaches its label.
        if let remote = surface.hcRemoteTarget, let hcSession = surface.hcSession,
           hcSession.identity.origin == .fresh {
            hcSession.$lifecycle
                .first { if case .live = $0 { return true } else { return false } }
                .sink { [weak self] _ in
                    guard let self else { return }
                    C11TipCenter.shared.offer(.remoteLabel, machine: WhatsDifferentPlaces.look(remote.machine).name) {
                        [weak self] in self.flatMap { C11TipCenter.hostedViewAnchor($0.hostedView) }
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// Create a new terminal panel with a fresh surface.
    ///
    /// `id` is the stable panel UUID. Pass `nil` for fresh creation; pass a
    /// snapshot's panel id during session restore to keep IDs stable across
    /// app restarts (Tier 1 persistence, Phase 1).
    convenience init(
        id: UUID? = nil,
        createdAt: Date? = Date(),
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: ghostty_surface_config_s? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        remoteTarget: HCRemoteTarget? = nil
    ) {
        let surface = TerminalSurface(
            id: id,
            workspaceId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            remoteTarget: remoteTarget
        )
        self.init(workspaceId: workspaceId, surface: surface, createdAt: createdAt)
    }

    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    func updateDirectory(_ newDirectory: String) {
        let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && directory != trimmed {
            directory = trimmed
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        surface.updateWorkspaceId(newWorkspaceId)
        lifecycle.updateWorkspaceId(newWorkspaceId)
        deliverLocalPlacement()
    }

    /// Last local chip inputs. The sink can fire during init, before the panel
    /// is registered in its workspace, so delivery hops to the next main turn.
    private var lastLocalPlacement: (lifecycle: HCLifecycle, persistence: HCPersistence, machineName: String?)?

    private func noteLocalPlacement(_ lifecycle: HCLifecycle, _ persistence: HCPersistence,
                                    _ machineName: String?) {
        lastLocalPlacement = (lifecycle, persistence, machineName)
        deliverLocalPlacement()
    }

    private func deliverLocalPlacement() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let last = self.lastLocalPlacement,
                  let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: self.id, preferredWorkspaceId: self.workspaceId) else { return }
            located.workspace.noteSessionLifecycle(panelId: self.id, lifecycle: last.lifecycle,
                persistence: last.persistence, machineName: last.machineName, isLocal: true)
        }
    }

    // MARK: - Lifecycle dispatch

    /// Translate the panel's `isVisibleInUI` from SwiftUI into a
    /// lifecycle transition. Idempotent: calling with the same value
    /// twice is a no-op. Called on workspace-selection edge events
    /// (`.onChange`) and at panel mount (`.onAppear`); never on the
    /// typing-latency hot path.
    ///
    /// Operator-pinned states (`hibernated`) are preserved — only
    /// `active ↔ throttled` flip on automatic visibility changes. A
    /// hibernated panel resumes via the operator's "Resume Workspace"
    /// action, which calls `setHibernated(false)`.
    func applyVisibility(_ isVisibleInUI: Bool) {
        if lifecycle.state.isOperatorPinned { return }
        lifecycle.transition(to: isVisibleInUI ? .active : .throttled)
    }

    func focus() {
#if DEBUG
        let focusStart = CACurrentMediaTime()
#endif
        surface.setFocus(true)
#if DEBUG
        let postSetFocus = (CACurrentMediaTime() - focusStart) * 1000
#endif
        // `unfocus()` force-disables active state to stop stale retries from stealing focus.
        // Re-enable it immediately for explicit focus requests (socket/UI) so ensureFocus can run.
        hostedView.setActive(true)
#if DEBUG
        let postSetActive = (CACurrentMediaTime() - focusStart) * 1000
#endif
        hostedView.ensureFocus(for: workspaceId, surfaceId: id)
#if DEBUG
        let postEnsureFocus = (CACurrentMediaTime() - focusStart) * 1000
        if postEnsureFocus > 5 {
            dlog(
                "terminalPanel.focus.timing panel=\(id.uuidString.prefix(5)) " +
                "setFocus=\(String(format: "%.2f", postSetFocus))ms " +
                "setActive=\(String(format: "%.2f", postSetActive - postSetFocus))ms " +
                "ensureFocus=\(String(format: "%.2f", postEnsureFocus - postSetActive))ms " +
                "total=\(String(format: "%.2f", postEnsureFocus))ms"
            )
        }
#endif
    }

    func unfocus() {
        surface.setFocus(false)
        // Cancel any pending focus work items so an inactive terminal can't steal first responder
        // back from another surface (notably WKWebView) during rapid focus changes in tests.
        //
        // Also flip the hosted view's active state immediately: SwiftUI focus propagation can lag
        // by a runloop tick, and `requestFocus` retries that are already executing can otherwise
        // schedule new work items that fire after we navigate away.
        hostedView.setActive(false)
    }

    func close() {
        disposeSurface(reason: "panel.close")
    }

    /// Replacing a restored UI graph is not an operator request to end the
    /// terminal. Keep this path separate when explicit close gains HC end.
    func detachForSessionRestore() {
        disposeSurface(reason: "panel.restore_retire")
    }

    private func disposeSurface(reason: String) {
        if let hcSession { HCRestoreLifecycleStore.shared.forget(hcSession) }
        LaunchPromptStore.shared.release(owner: launchPromptOwner)
        // The surface will be cleaned up by its deinit
        // Detach from the window portal on real close so stale hosted views
        // cannot remain above browser panes after split close.
        surface.beginPortalCloseLifecycle(reason: reason)
#if DEBUG
        let frame = String(format: "%.1fx%.1f", hostedView.frame.width, hostedView.frame.height)
        let bounds = String(format: "%.1fx%.1f", hostedView.bounds.width, hostedView.bounds.height)
        dlog(
            "surface.panel.close.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) runtimeSurface=\(surface.surface != nil ? 1 : 0) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        )
#endif
        unfocus()
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
        PanelMetricsSampler.shared.unregister(surfaceId: id)
#if DEBUG
        dlog(
            "surface.panel.close.end panel=\(id.uuidString.prefix(5)) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
        surface.teardownSurface()
    }

    func requestViewReattach() {
        viewReattachToken &+= 1
    }

    // MARK: - Terminal-specific methods

    func sendText(_ text: String) {
        surface.sendText(text)
    }

    func performBindingAction(_ action: String) -> Bool {
        surface.performBindingAction(action)
    }

    func hasSelection() -> Bool {
        surface.hasSelection()
    }

    func needsConfirmClose() -> Bool {
        surface.needsConfirmClose()
    }

    func shouldPersistScrollbackForSessionSnapshot() -> Bool {
        guard hcIdentity?.persistence != .persistent else { return false }
        // Autosave asks only whether the child is live. Operator close confirmation
        // is a separate prompt-state query and may acquire the renderer lock.
        return surface.hasLiveProcess()
    }

    func triggerFlash() {
        guard NotificationAreaFlashSettings.isEnabled() else { return }
        hostedView.triggerFlash()
    }

    func triggerFlash(appearance: FlashAppearance) {
        guard NotificationAreaFlashSettings.isEnabled() else { return }
        hostedView.triggerFlash(style: .standardFocus, appearance: appearance)
    }

    func triggerNotificationDismissFlash() {
        guard NotificationAreaFlashSettings.isEnabled() else { return }
        hostedView.triggerFlash(style: .notificationDismiss)
    }

    func applyWindowBackgroundIfActive() {
        surface.applyWindowBackgroundIfActive()
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        .terminal(hostedView.capturePanelFocusIntent(in: window))
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .terminal(hostedView.preferredPanelFocusIntentForActivation())
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard case .terminal(let target) = intent else { return }
        hostedView.preparePanelFocusIntentForActivation(target)
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .panel:
            focus()
            return true
        case .terminal(let target):
            return hostedView.restorePanelFocusIntent(target)
        default:
            return false
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        guard let intent = hostedView.ownedPanelFocusIntent(for: responder) else { return nil }
        return .terminal(intent)
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard case .terminal(let target) = intent else { return false }
        return hostedView.yieldPanelFocusIntent(target, in: window)
    }
}
