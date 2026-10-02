import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeUnretainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> ghostty_surface_config_s {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = inherited

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.font_size = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.font_size)
    dlog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}

struct SidebarStatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: SidebarMetadataFormat
    let timestamp: Date
    /// True when this entry was rebuilt from a session snapshot on restart.
    /// The process that last wrote it is gone, so the value is shown with
    /// reduced emphasis until the next real write clears the flag. See the
    /// stale→live override in `TerminalController.shouldReplaceStatusEntry`.
    let staleFromRestart: Bool

    init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date(),
        staleFromRestart: Bool = false
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
        self.staleFromRestart = staleFromRestart
    }
}

struct SidebarMetadataBlock {
    let key: String
    let markdown: String
    let priority: Int
    let timestamp: Date
}

enum SidebarMetadataFormat: String {
    case plain
    case markdown
}

private struct SessionAreaRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionAreaLayoutSnapshot
}

struct WorkspaceRemoteDaemonManifest: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let goOS: String
        let goArch: String
        let assetName: String
        let downloadURL: String
        let sha256: String
    }

    let schemaVersion: Int
    let appVersion: String
    let releaseTag: String
    let releaseURL: String
    let checksumsAssetName: String
    let checksumsURL: String
    let entries: [Entry]

    func entry(goOS: String, goArch: String) -> Entry? {
        entries.first { $0.goOS == goOS && $0.goArch == goArch }
    }
}

extension Workspace {
    nonisolated static let remoteDaemonManifestInfoKey = WorkspaceRemoteSessionController.remoteDaemonManifestInfoKey

    nonisolated static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        WorkspaceRemoteSessionController.remoteDaemonManifest(from: infoDictionary)
    }

    nonisolated static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try WorkspaceRemoteSessionController.remoteDaemonCachedBinaryURL(
            version: version,
            goOS: goOS,
            goArch: goArch,
            fileManager: fileManager
        )
    }

    func sessionSnapshot(
        includeScrollback: Bool,
        conversationsByPanelId injectedConversations: [String: TabConversations]? = nil
    ) -> SessionWorkspaceSnapshot {
        let tree = bonsplitController.treeSnapshot()
        let layout = sessionLayoutSnapshot(from: tree)

        let orderedPanelIds = sidebarOrderedTabIds()
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in orderedPanelIds where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }

        // C11-24: bulk-read conversation refs once from the actor before
        // building any panel snapshots. Replaces the per-panel sync-bridge
        // that deadlocked because the spawned `Task` inherited
        // `@MainActor` isolation from this `@MainActor` class and could
        // not run while main was blocked on the semaphore wait. Single
        // `Task.detached` breaks the isolation inheritance; one
        // round-trip per save instead of N.
        //
        // C11-170: the store snapshot is *global* (all panels across all
        // workspaces), so a full-app `session.save` iterating W workspaces
        // used to fire W independent `Task.detached` + 2s-semaphore reads —
        // one per workspace, each an independent timeout dice-roll on the
        // main thread. Under the concurrent load the TEL/EVT telemetry now
        // generates during pane build, some of those reads missed the
        // window and the workspace persisted an empty `surface_conversations`
        // (dropped `active` refs → RES acceptance-harness flake). The caller
        // (`AppDelegate.buildSessionSnapshot`) now reads the store once and
        // injects the same map into every workspace; the self-read below is
        // the fallback for the standalone call sites that snapshot a single
        // workspace (DebugHandlers).
        let conversationsByPanelId = injectedConversations
            ?? Workspace.readConversationsByTabIdSync()

        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { sessionTabSnapshot(
                panelId: $0,
                includeScrollback: includeScrollback,
                conversationsByPanelId: conversationsByPanelId
            ) }

        let statusSnapshots = statusEntries.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in
                SessionStatusEntrySnapshot(
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    timestamp: entry.timestamp.timeIntervalSince1970,
                    url: entry.url?.absoluteString,
                    priority: entry.priority == 0 ? nil : entry.priority,
                    format: entry.format == .plain ? nil : entry.format.rawValue,
                    staleFromRestart: entry.staleFromRestart ? true : nil
                )
            }
        let logSnapshots = logEntries.map { entry in
            SessionLogEntrySnapshot(
                message: entry.message,
                level: entry.level.rawValue,
                source: entry.source,
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }

        let progressSnapshot = progress.map { progress in
            SessionProgressSnapshot(
                value: progress.value,
                label: progress.label,
                timestamp: progress.timestamp.timeIntervalSince1970
            )
        }
        let gitBranchSnapshot = gitBranch.map { branch in
            SessionGitBranchSnapshot(branch: branch.branch, isDirty: branch.isDirty)
        }

        let metadataSnapshot: [String: String]? = metadata.isEmpty ? nil : metadata

        return SessionWorkspaceSnapshot(
            id: id,
            processTitle: processTitle,
            customTitle: customTitle,
            stableDefaultTitle: stableDefaultTitle,
            customColor: customColor,
            isPinned: isPinned,
            groupId: groupId,
            currentDirectory: currentDirectory,
            rootDirectory: rootDirectory,
            rootAdoptionArmed: rootAdoptionArmed,
            focusedPanelId: focusedPanelId,
            layout: layout,
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot,
            metadata: metadataSnapshot
        )
    }

    func restoreSessionSnapshot(_ savedSnapshot: SessionWorkspaceSnapshot) {
        let (snapshot, drops) = SessionRestoreNormalization.normalize(savedSnapshot)
        for drop in drops {
            NSLog("%@", drop.diagnostic(workspaceId: snapshot.id))
        }
        restoredTerminalScrollbackByTabId.removeAll(keepingCapacity: false)

        let normalizedCurrentDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }
        restoreRootDirectory(snapshot.rootDirectory, adoptionArmed: snapshot.rootAdoptionArmed)

        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let leafEntries = restoreSessionLayout(snapshot.layout)
        // Panel UUIDs are stable across restart: `createPanel` threads each
        // `snapshot.id` into the panel constructor, so a restored panel keeps
        // the snapshot's id. Restore paths key directly on the snapshot id.

        for entry in leafEntries {
            restorePane(
                entry.paneId,
                snapshot: entry.snapshot,
                panelSnapshotsById: panelSnapshotsById
            )
        }

        restoreSurfaceMetadataFromSnapshot(panels: snapshot.panels)
        syncSurfaceTabActivityStates()

        // CMUX-11 Phase 3: rehydrate PaneMetadataStore entries from each
        // restored leaf and prune any pane metadata not in the live set.
        restoreAreaMetadataFromSnapshot(leafEntries: leafEntries)
        prunePaneMetadata(validPaneIds: Set(bonsplitController.allPaneIds.map { $0.id }))

        pruneSurfaceMetadata(validSurfaceIds: Set(panels.keys))

        // C11-25 review fix I1: rehydrate per-surface lifecycle from the
        // canonical metadata mirror. The blueprint-apply restore path
        // (`WorkspaceLayoutExecutor.apply`) already calls this; the
        // session-snapshot restore path used by `TabManager` /
        // `TerminalController` / `AppDelegate` did not, so a hibernated
        // browser restored on app relaunch landed with
        // `lifecycle_state == "hibernated"` in metadata but was running
        // as `.active` in runtime. Operator intent was silently dropped.
        restoreLifecycleStateFromMetadata()

        applySessionDividerPositions(snapshotNode: snapshot.layout, liveNode: bonsplitController.treeSnapshot())

        let restoredStableDefaultTitle = snapshot.stableDefaultTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stableDefaultTitle = restoredStableDefaultTitle.isEmpty ? nil : restoredStableDefaultTitle
        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned
        groupId = snapshot.groupId
        metadata = snapshot.metadata ?? [:]

        // Tier 1 Phase 3: restore `statusEntries` from the snapshot, stamping
        // each entry with `staleFromRestart: true` so the sidebar can render
        // them with reduced emphasis until the agent re-announces the value.
        // `agentPIDs` stays cleared — a PID from a prior boot is meaningless.
        statusEntries = snapshot.statusEntries.reduce(into: [:]) { acc, snap in
            let url = snap.url.flatMap { URL(string: $0) }
            let format = snap.format.flatMap { SidebarMetadataFormat(rawValue: $0) } ?? .plain
            acc[snap.key] = SidebarStatusEntry(
                key: snap.key,
                value: snap.value,
                icon: snap.icon,
                color: snap.color,
                url: url,
                priority: snap.priority ?? 0,
                format: format,
                timestamp: Date(timeIntervalSince1970: snap.timestamp),
                staleFromRestart: true
            )
        }
        clearAgentPIDs()
        logEntries = snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        // C11-162 (MAJOR-2): restore the original write time so a restored
        // progress bar carries its real age instead of appearing freshly written.
        // Falls back to now for pre-existing snapshots that lack the field.
        progress = snapshot.progress.map {
            SidebarProgressState(
                value: $0.value,
                label: $0.label,
                timestamp: $0.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
            )
        }
        gitBranch = snapshot.gitBranch.map { SidebarGitBranchState(branch: $0.branch, isDirty: $0.isDirty) }

        recomputeListeningPorts()

        if let focusedPanelId = snapshot.focusedPanelId,
           panels[focusedPanelId] != nil {
            focusPanel(focusedPanelId)
        } else if let fallbackFocusedPanelId = self.focusedPanelId, panels[fallbackFocusedPanelId] != nil {
            focusPanel(fallbackFocusedPanelId)
        } else {
            scheduleFocusReconcile()
        }

        // C11-24: schedule agent-resume for restored terminal surfaces that
        // carry a ConversationRef in the store. The dispatch is deferred so
        // Ghostty PTYs + their shells have time to come up;
        // `CMUX_DISABLE_AGENT_RESTART=1` suppresses the whole pass. Layout/
        // metadata/status restore above is independent — failures here
        // cannot break a normal restore.
        //
        // Kill switch (`CMUX_DISABLE_CONVERSATION_STORE=1`): falls back to
        // the legacy AgentRestartRegistry path for snapshots already
        // containing `claude.session_id` reserved metadata (i.e., 0.43.0
        // / 0.44.0-pre captures). New 0.44.0+ sessions captured under
        // the kill switch do NOT capture (claude-hook session-start no
        // longer writes that key), so they will not resume on restart.
        // The kill switch is a one-release safety net for already-captured
        // state, not a full rollback. Removed in 0.46.0 / v1.1 alongside
        // the legacy claude.session_id metadata bridge.
        if ConversationStorePolicy.isDisabled {
            let startup = ResumeStartupEpochGate.shared.snapshot()
            if startup.auditComplete, startup.mode != .noResume {
                scheduleAgentRestartLegacy(
                    from: snapshot,
                    registry: .phase1
                )
            }
        } else {
            scheduleAgentRestart(
                from: snapshot,
                registry: ConversationStrategyRegistry.v1
            )
        }
    }

    /// Legacy fallback path used only when CMUX_DISABLE_CONVERSATION_STORE=1.
    /// Reads the legacy `claude.session_id` reserved metadata directly from
    /// the panel snapshot via AgentRestartRegistry. Removed in 0.46.0/v1.1.
    private func scheduleAgentRestartLegacy(
        from snapshot: SessionWorkspaceSnapshot,
        registry: AgentRestartRegistry
    ) {
        guard SessionPersistencePolicy.agentRestartOnRestoreEnabled else { return }
        var commands: [(panelId: UUID, command: String)] = []
        for panelSnapshot in snapshot.panels {
            guard panelSnapshot.type == .terminal else { continue }
            let meta = Workspace.stringValues(from: panelSnapshot.metadata)
            let terminalType = meta[TabMetadataKeyName.terminalType]
            let sessionId = meta[TabMetadataKeyName.claudeSessionId]
            guard let command = registry.resolveCommand(
                terminalType: terminalType,
                sessionId: sessionId,
                metadata: meta
            ) else { continue }
            commands.append((panelId: panelSnapshot.id, command: command))
        }
        guard !commands.isEmpty else { return }
        // C11-156: stagger resumes (see scheduleAgentRestart) so the legacy
        // path doesn't herd either.
        let base = SessionPersistencePolicy.agentRestartDelay
        let stagger = SessionPersistencePolicy.agentRestartStagger
        for (index, (panelId, command)) in commands.enumerated() {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + base + Double(index) * stagger
            ) { [weak self] in
                guard let self,
                      let terminalTab = self.panels[panelId] as? TerminalTab else {
                    return
                }
                TextBoxSubmit.send(command, via: terminalTab.surface)
            }
        }
    }

    /// C11-24: synchronous bulk read of the `ConversationStore` for use
    /// from `@MainActor` contexts (snapshot capture, restore, dirty-boot
    /// transitions). Uses `Task.detached` so the spawned task does NOT
    /// inherit `@MainActor` isolation from the caller — otherwise the
    /// task body could not run while the calling thread blocks on the
    /// semaphore wait, deadlocking until the timeout. The previous
    /// pattern (`Task { await actor.method(); sema.signal() }`) was
    /// buggy in every `@MainActor` call site; per-panel snapshot capture
    /// hit it once per panel per save and produced empty conversation
    /// state in every persisted snapshot. Verified by reproducer at
    /// `notes/c11-24-snapshot-capture-bug.md`.
    ///
    /// `nonisolated` so it can be called without an actor hop and
    /// without inheriting the caller's isolation. The actor call inside
    /// `Task.detached` still hops to `ConversationStore`'s executor in
    /// the normal way.
    nonisolated static func readConversationsByTabIdSync(
        timeout: TimeInterval = 2.0
    ) -> [String: TabConversations] {
        guard !ConversationStorePolicy.isDisabled else { return [:] }
        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var captured: [String: TabConversations] = [:]
        Task.detached(priority: .userInitiated) {
            captured = await ConversationStore.shared.snapshot()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + timeout)
        return captured
    }

    /// C11-24: collect ResumeActions for terminal panels by consulting the
    /// `ConversationStore`. Reads via the strategy registry: each panel's
    /// active ref is handed to its strategy's `resume(ref:)`; the action
    /// is then executed via `execute(_:on:panelMap:)`.
    ///
    /// Internal (not private) so unit tests can exercise it without going
    /// through the full live workspace restore path.
    func pendingRestartPlans(
        from snapshot: SessionWorkspaceSnapshot,
        registry: ConversationStrategyRegistry,
        startup: ResumeStartupEpochGate.Snapshot? = nil
    ) -> [(panelId: UUID, action: ResumeAction)] {
        guard SessionPersistencePolicy.agentRestartOnRestoreEnabled else { return [] }
        let startup = startup ?? ResumeStartupEpochGate.shared.snapshot()
        var result: [(panelId: UUID, action: ResumeAction)] = []
        // C11-24: bulk-read the actor via the shared sync helper. The
        // previous inline `Task { ... }` deadlocked from `@MainActor`
        // contexts because the unstructured Task inherited that
        // isolation and could not run while main was blocked on the
        // semaphore. `readConversationsByPanelIdSync` uses
        // `Task.detached` to break the inheritance.
        let storeSnapshot = Workspace.readConversationsByTabIdSync(timeout: 1.0)
        for panelSnapshot in snapshot.panels {
            guard panelSnapshot.type == .terminal else { continue }
            let key = panelSnapshot.id.uuidString
            guard let surface = storeSnapshot[key], let ref = surface.active else {
                let persistedRef = panelSnapshot.surfaceConversations?.active
                let metadataKind = Self.stringValues(from: panelSnapshot.metadata)[
                    TabMetadataKeyName.terminalType
                ]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let kind = persistedRef?.kind ?? metadataKind,
                   !kind.isEmpty,
                   registry.contains(kind: kind) {
                    EventEmitter.shared.emitConversationResumeDecision(
                        workspace: id,
                        surface: panelSnapshot.id,
                        kind: kind,
                        conversationId: persistedRef?.id,
                        mode: startup.mode,
                        decision: .skip(
                            code: .conversationUnavailable,
                            reason: "no active conversation in restore store"
                        )
                    )
                }
                continue
            }
            guard let strategy = registry.strategy(forKind: ref.kind) else {
                EventEmitter.shared.emitConversationResumeDecision(
                    workspace: id,
                    surface: panelSnapshot.id,
                    kind: ref.kind,
                    conversationId: ref.id,
                    mode: startup.mode,
                    decision: .skip(
                        code: .strategyUnavailable,
                        reason: "no registered resume strategy for kind \(ref.kind)"
                    )
                )
                continue
            }
            let strategyAction = strategy.resume(ref: ref)
            let fallbackCommand: ResumeCommand?
            if case .typeCommand(let text, let submit) = strategyAction {
                fallbackCommand = ResumeCommand(text: text, submitWithReturn: submit)
            } else {
                fallbackCommand = nil
            }
            let decision = ResumeDecisionEngine.decide(ResumeDecisionInput(
                mode: startup.mode,
                auditComplete: startup.auditComplete,
                ownership: Self.resumeOwnership(for: ref),
                kind: ref.kind,
                id: ref.id,
                placeholder: ref.placeholder,
                state: ResumePersistedState(rawValue: ref.state.rawValue) ?? .unsupported,
                exactIDValid: strategy.isValidId(ref.id),
                transcriptEvidence: Self.transcriptEvidence(for: ref, mode: startup.mode),
                diagnosticReason: ref.diagnosticReason,
                fallbackCommand: fallbackCommand
            ))
            EventEmitter.shared.emitConversationResumeDecision(
                workspace: id,
                surface: panelSnapshot.id,
                kind: ref.kind,
                conversationId: ref.id,
                mode: startup.mode,
                decision: decision
            )
            guard case .command(let command) = decision else { continue }
            result.append((
                panelId: panelSnapshot.id,
                action: .typeCommand(
                    text: command.text,
                    submitWithReturn: command.submitWithReturn
                )
            ))
        }
        return result
    }

    nonisolated static func resumeOwnership(
        for ref: ConversationRef
    ) -> ResumeOwnershipStatus {
        if let quarantine = ref.quarantineReason {
            switch quarantine {
            case .duplicateInferredIdentity, .conflictingCausalIdentity, .displacedByCausalOwner:
                return .duplicate
            case .sameCwdWithoutCausalIdentity, .ambiguousGlobalAssignment:
                return .ambiguous
            }
        }
        // Startup audit completion is a separate ResumeDecisionInput axis.
        // Once complete, an unquarantined singleton is uniquely owned
        // regardless of placeholder/lifecycle state; the shared decision
        // engine must reach those later gates so app and CLI emit the same
        // typed placeholder or state-not-resumable skip.
        return .unique
    }

    nonisolated static func transcriptEvidence(
        for ref: ConversationRef,
        mode: ResumeRecoveryMode
    ) -> ResumeTranscriptEvidence {
        guard mode == .dirty else { return .notRequired }
        let diagnostic = ref.diagnosticReason?.lowercased() ?? ""
        if diagnostic.contains("transcript verified") { return .verified }
        if diagnostic.contains("transcript not found") { return .missing }
        return .unavailable
    }

    /// Flatten persisted metadata to `[String: String]`, keeping only
    /// `.string(...)` entries. Mirrors the existing
    /// `WorkspaceLayoutExecutor.stringMetadata` helper: the registry
    /// contract is string-valued (`terminal_type`, `claude.session_id`)
    /// and the metadata store rejects non-string writes for these
    /// reserved keys at the boundary, so silently dropping any non-string
    /// value here is consistent with the executor's restore path.
    static func stringValues(from metadata: [String: PersistedJSONValue]?) -> [String: String] {
        guard let metadata else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in metadata {
            if case .string(let s) = value {
                out[key] = s
            }
        }
        return out
    }

    /// Schedule deferred submission of `ResumeAction`s for terminal panels
    /// resolved via `pendingRestartPlans`. The dispatch runs on the main
    /// actor after `SessionPersistencePolicy.agentRestartDelay` so Ghostty
    /// surfaces have time to initialise.
    ///
    /// Submission goes through `TerminalSurface.sendSubmitFormText`.
    /// Ghostty's text-input path (`sendText` → `ghostty_surface_text`)
    /// wraps every call in bracketed-paste markers (`ESC[200~…ESC[201~`).
    /// Bracketed paste is intentionally designed so embedded `\n`/`\r`
    /// inside the paste do not auto-execute — zsh ZLE and bash readline
    /// only execute when a *real* Return arrives outside the paste. So a
    /// raw `sendText("<cmd>\n")` types the command but leaves it sitting
    /// at the prompt, which is exactly the regression the operator
    /// observed. `sendSubmitFormText` types the trimmed text via paste
    /// and then dispatches a synthetic Return key — and, critically,
    /// defers the Return until the pending-text queue actually flushes
    /// on surface attach, so the boot-time race where `view.window` is
    /// still nil at the 2.5s mark (and `sendKey` silently drops) no
    /// longer hides the submission.
    ///
    /// Panel ids are stable across restart, so the live panel id equals the
    /// snapshot panel id resolved in `pendingRestartPlans`.
    private func scheduleAgentRestart(
        from snapshot: SessionWorkspaceSnapshot,
        registry: ConversationStrategyRegistry
    ) {
        let plans = pendingRestartPlans(from: snapshot, registry: registry)
        guard !plans.isEmpty else { return }
        // C11-156: stagger the resumes so N agents don't all boot in the same
        // main-queue turn and fire their SessionStart hooks at once (the
        // mass-resume thundering herd that beachballs the app). Each agent
        // resumes one `agentRestartStagger` after the previous.
        let base = SessionPersistencePolicy.agentRestartDelay
        let stagger = SessionPersistencePolicy.agentRestartStagger
        for (index, (panelId, action)) in plans.enumerated() {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + base + Double(index) * stagger
            ) { [weak self] in
                self?.executeResumeAction(action, on: panelId)
            }
        }
    }

    /// Execute a `ResumeAction` against a live terminal panel. Logs `.skip`
    /// reasons for diagnostic visibility. Main-actor; only called from
    /// `scheduleAgentRestart`'s deferred dispatch.
    private func executeResumeAction(_ action: ResumeAction, on panelId: UUID) {
        switch action {
        case .typeCommand(let text, let submit):
            guard let terminalTab = self.panels[panelId] as? TerminalTab else { return }
            if submit {
                // Use the deferred-Return submission path (see
                // scheduleAgentRestart's doc comment): sendSubmitFormText
                // queues the Return until the pending-text flush on surface
                // attach, so the 2.5s boot-time race where view.window is
                // still nil no longer silently drops the submission.
                terminalTab.surface.sendSubmitFormText(text)
            } else {
                terminalTab.surface.sendText(text)
            }
        case .skip(let reason):
            #if DEBUG
            dlog("conversation.resume.skipped panel=\(panelId.uuidString.prefix(8)) reason=\(reason)")
            #endif
            _ = reason // silence release-build unused warning
        }
    }

    private func sessionLayoutSnapshot(from node: ExternalTreeNode) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let panelIds = sessionTabIDs(for: pane)
            let selectedPanelId = pane.selectedTabId.flatMap(sessionTabID(forExternalTabIDString:))
            // CMUX-11 Phase 3: capture the bonsplit pane UUID and any
            // PaneMetadataStore values so they survive a restart. Both fields
            // are optional; we only emit them when we can resolve a UUID and
            // a non-empty store. bonsplit's `PaneID.description` is
            // `UUID.uuidString`, so a parse failure here means the external
            // contract has drifted — log so the regression is visible.
            let paneUUID = UUID(uuidString: pane.id)
            #if DEBUG
            if paneUUID == nil {
                dlog("pane.metadata.persist.drop workspace=\(id.uuidString.prefix(8)) reason=unparseable_pane_id raw=\(pane.id)")
            }
            #endif
            let (persistedPaneMetadata, persistedPaneSources) = persistedPaneMetadata(forPaneUUID: paneUUID)
            // Remember an open rail per area across relaunch (nil when closed, to keep snapshots minimal).
            let railOpen: Bool? = paneUUID.flatMap { uuid in
                bonsplitController.railOpenPaneIds.contains(PaneID(id: uuid)) ? true : nil
            }
            return .pane(
                SessionAreaLayoutSnapshot(
                    panelIds: panelIds,
                    selectedPanelId: selectedPanelId,
                    id: paneUUID,
                    metadata: persistedPaneMetadata,
                    metadataSources: persistedPaneSources,
                    railOpen: railOpen
                )
            )
        case .split(let split):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    dividerPosition: split.dividerPosition,
                    first: sessionLayoutSnapshot(from: split.first),
                    second: sessionLayoutSnapshot(from: split.second)
                )
            )
        }
    }

    /// CMUX-11 Phase 3: pull `PaneMetadataStore` values + sources for a pane,
    /// run them through the persistence bridge, and apply the 64 KiB cap.
    /// Returns `(nil, nil)` when the store is empty or the pane UUID could
    /// not be parsed — keeping snapshots minimal.
    private func persistedPaneMetadata(
        forPaneUUID paneUUID: UUID?
    ) -> ([String: PersistedJSONValue]?, [String: PersistedMetadataSource]?) {
        guard let paneUUID else { return (nil, nil) }
        let snapshot = AreaMetadataStore.shared.getMetadata(workspaceId: id, paneId: paneUUID)
        if snapshot.metadata.isEmpty && snapshot.sources.isEmpty {
            return (nil, nil)
        }
        let bridgedValues = PersistedMetadataBridge.encodeValues(
            snapshot.metadata,
            surfaceIdForLog: paneUUID,
            sources: snapshot.sources
        )
        let cappedValues = PersistedMetadataBridge.enforceSizeCap(
            bridgedValues,
            entityKind: "pane",
            entityId: paneUUID
        )
        let bridgedSources = PersistedMetadataBridge.encodeSources(snapshot.sources)
        let alignedSources = bridgedSources.filter { cappedValues.keys.contains($0.key) }
        return (
            cappedValues.isEmpty ? nil : cappedValues,
            alignedSources.isEmpty ? nil : alignedSources
        )
    }

    private func sessionTabIDs(for pane: ExternalPaneNode) -> [UUID] {
        var panelIds: [UUID] = []
        var seen = Set<UUID>()
        for bonsplitTab in pane.tabs {
            guard let panelId = sessionTabID(forExternalTabIDString: bonsplitTab.id) else { continue }
            if seen.insert(panelId).inserted {
                panelIds.append(panelId)
            }
        }
        return panelIds
    }

    private func sessionTabID(forExternalTabIDString tabIDString: String) -> UUID? {
        guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
        for (bonsplitTabId, panelId) in bonsplitTabIdToTabId {
            guard let surfaceUUID = sessionSurfaceUUID(for: bonsplitTabId) else { continue }
            if surfaceUUID == tabUUID {
                return panelId
            }
        }
        return nil
    }

    private func sessionSurfaceUUID(for bonsplitTabId: TabID) -> UUID? {
        struct EncodedTabID: Decodable {
            let id: UUID
        }

        guard let data = try? JSONEncoder().encode(bonsplitTabId),
              let decoded = try? JSONDecoder().decode(EncodedTabID.self, from: data) else {
            return nil
        }
        return decoded.id
    }

    private func sessionTabSnapshot(
        panelId: UUID,
        includeScrollback: Bool,
        conversationsByPanelId conversationsByTabId: [String: TabConversations]
    ) -> SessionTabSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        let tabTitle = tabTitle(panelId: panelId)
        let customTitle = tabCustomTitles[panelId]
        let directory = tabDirectories[panelId]
        let isPinned = pinnedTabIds.contains(panelId)
        let isManuallyUnread = manualUnreadTabIds.contains(panelId)
        let branchSnapshot = tabGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts = (tabListeningPorts[panelId] ?? []).sorted()
        let ttyName = tabTTYNames[panelId]

        let terminalSnapshot: SessionTerminalTabSnapshot?
        let browserSnapshot: SessionBrowserTabSnapshot?
        let markdownSnapshot: SessionMarkdownTabSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalTab = panel as? TerminalTab else { return nil }
            let shouldPersistScrollback = terminalTab.shouldPersistScrollbackForSessionSnapshot()
            let capturedScrollback = includeScrollback && shouldPersistScrollback
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalTab,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: capturedScrollback,
                includeScrollback: includeScrollback,
                allowFallbackScrollback: shouldPersistScrollback
            )
            terminalSnapshot = SessionTerminalTabSnapshot(
                workingDirectory: tabDirectories[panelId],
                scrollback: resolvedScrollback
            )
            browserSnapshot = nil
            markdownSnapshot = nil
        case .browser:
            guard let browserTab = panel as? BrowserTab else { return nil }
            terminalSnapshot = nil
            let historySnapshot = browserTab.sessionNavigationHistorySnapshot()
            browserSnapshot = SessionBrowserTabSnapshot(
                urlString: browserTab.preferredURLStringForOmnibar(),
                profileID: browserTab.profileID,
                shouldRenderWebView: browserTab.shouldRenderWebView,
                pageZoom: Double(browserTab.currentPageZoomFactor()),
                developerToolsVisible: browserTab.isDeveloperToolsVisible(),
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings
            )
            markdownSnapshot = nil
        case .markdown:
            guard let markdownTab = panel as? MarkdownTab else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = SessionMarkdownTabSnapshot(
                filePath: markdownTab.filePath,
                fontScale: markdownTab.fontScale
            )
        }

        var persistedMetadata: [String: PersistedJSONValue]?
        let persistedMetadataSources: [String: PersistedMetadataSource]?
        do {
            let snapshot = TabMetadataStore.shared.getMetadata(
                workspaceId: id,
                surfaceId: panelId
            )
            if snapshot.metadata.isEmpty && snapshot.sources.isEmpty {
                persistedMetadata = nil
                persistedMetadataSources = nil
            } else {
                let bridgedValues = PersistedMetadataBridge.encodeValues(
                    snapshot.metadata,
                    surfaceIdForLog: panelId,
                    sources: snapshot.sources
                )
                let cappedValues = PersistedMetadataBridge.enforceSizeCap(
                    bridgedValues,
                    surfaceId: panelId
                )
                let bridgedSources = PersistedMetadataBridge.encodeSources(snapshot.sources)
                // If enforceSizeCap dropped keys, drop their sidecars too.
                let alignedSources = bridgedSources.filter { cappedValues.keys.contains($0.key) }
                persistedMetadata = cappedValues.isEmpty ? nil : cappedValues
                persistedMetadataSources = alignedSources.isEmpty ? nil : alignedSources
            }
        }
        // Marks this snapshot as written with launch-stamp tiering (see
        // `Workspace.migrateLaunchStampTiers`); stripped again on restore.
        if persistedMetadata != nil {
            persistedMetadata?[Self.modelTieringMarkerKey] = .string("2")
        }

        // C11-24: lookup the surface's ConversationRefs from the
        // pre-built map (bulk-read once at the workspace level — see
        // `readConversationsByPanelIdSync` in `sessionSnapshot`). The
        // previous implementation did a per-panel sync-bridge here, which
        // deadlocked: this method is `@MainActor`-isolated, the spawned
        // `Task { ... }` inherited that isolation and could not run while
        // main was blocked on `sema.wait`. Every call timed out and the
        // resulting snapshot wrote `.empty` for every panel, regardless of
        // what the live store actually held. Empty `SurfaceConversations`
        // (`active: nil, history: []`) is still written for terminal
        // surfaces with no captured conversation — the empty shape is part
        // of the v1 JSON contract.
        var tabConversations: TabConversations? = nil
        if !ConversationStorePolicy.isDisabled, panel.panelType == .terminal {
            tabConversations = conversationsByTabId[panelId.uuidString] ?? .empty
        }
        // C11-164 (RES-2): persist the surface's live activity floor so the
        // Codex/pi/omp scrape disambiguation survives a crash. Only terminal
        // surfaces carry a meaningful floor; `lastActivity(for:)` is a bounded
        // synchronous queue read (no main-thread hot-path work).
        var lastActivityAt: Date? = nil
        if !ConversationStorePolicy.isDisabled, panel.panelType == .terminal {
            lastActivityAt = TabActivityTracker.shared.lastActivity(for: panelId.uuidString)
        }
        return SessionTabSnapshot(
            id: panelId,
            createdAt: panel.createdAt,
            type: panel.panelType,
            title: tabTitle,
            customTitle: customTitle,
            customColor: tabCustomColors[panelId],
            directory: directory,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            gitBranch: branchSnapshot,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: markdownSnapshot,
            metadata: persistedMetadata,
            metadataSources: persistedMetadataSources,
            surfaceConversations: tabConversations,
            lastActivityAt: lastActivityAt,
            lastSeenAt: TabSeenTracker.shared.lastSeenAt(panelId: panelId)
        )
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let captured = SessionPersistencePolicy.truncatedScrollback(capturedScrollback) {
            return captured
        }
        guard allowFallbackScrollback else { return nil }
        return SessionPersistencePolicy.truncatedScrollback(fallbackScrollback)
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        guard includeScrollback else { return nil }
        let fallback = allowFallbackScrollback ? restoredTerminalScrollbackByTabId[panelId] : nil
        let resolved = Self.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback,
            allowFallbackScrollback: allowFallbackScrollback
        )
        if let resolved {
            restoredTerminalScrollbackByTabId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByTabId.removeValue(forKey: panelId)
        }
        return resolved
    }

    private func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionAreaRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionAreaRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    private func restoreSessionLayoutNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [SessionAreaRestoreEntry]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(SessionAreaRestoreEntry(paneId: paneId, snapshot: pane))
        case .split(let split):
            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { tabIdFromBonsplitTabId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                    from: anchorPanelId,
                    orientation: split.orientation.splitOrientation,
                    insertFirst: false,
                    focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append(
                    SessionAreaRestoreEntry(
                        paneId: paneId,
                        snapshot: SessionAreaLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                    )
                )
                return
            }

            restoreSessionLayoutNode(split.first, inPane: paneId, leaves: &leaves)
            restoreSessionLayoutNode(split.second, inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func restorePane(
        _ paneId: PaneID,
        snapshot: SessionAreaLayoutSnapshot,
        panelSnapshotsById tabSnapshotsById: [UUID: SessionTabSnapshot]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { tabIdFromBonsplitTabId($0.id) }
        let desiredTabIds = snapshot.panelIds.filter { tabSnapshotsById[$0] != nil }

        var createdPanelIds: [UUID] = []
        for desiredPanelId in desiredTabIds {
            guard let tabSnapshot = tabSnapshotsById[desiredPanelId] else { continue }
            guard let createdPanelId = createTab(from: tabSnapshot, inPane: paneId) else { continue }
            createdPanelIds.append(createdPanelId)
        }

        if snapshot.railOpen == true {
            bonsplitController.restoreRailOpen(true, inPane: paneId)
        }

        guard !createdPanelIds.isEmpty else { return }

        for existingPanelId in existingPanelIds where !createdPanelIds.contains(existingPanelId) {
            _ = closeTab(existingPanelId, force: true)
        }

        for (index, panelId) in createdPanelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index)
        }

        let selectedPanelId: UUID? = snapshot.selectedPanelId ?? createdPanelIds.first

        if let selectedPanelId,
           let selectedBonsplitTabId = bonsplitTabIdFromTabId(selectedPanelId) {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(selectedBonsplitTabId)
        }
    }

    private func createTab(from snapshot: SessionTabSnapshot, inPane paneId: PaneID) -> UUID? {
        // Tier 1 persistence: restore-time ID injection. Pass the snapshot's
        // id through to the panel constructor so external consumers
        // (surface.list callers, cached-id scripts) see the same UUID across
        // restarts.
        let restoredPanelId: UUID? = snapshot.id

        switch snapshot.type {
        case .terminal:
            let workingDirectory = snapshot.terminal?.workingDirectory ?? snapshot.directory ?? currentDirectory
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(
                for: snapshot.terminal?.scrollback
            )
            guard let terminalTab = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: workingDirectory,
                startupEnvironment: replayEnvironment,
                panelId: restoredPanelId,
                createdAt: snapshot.createdAt
            ) else {
                return nil
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(snapshot.terminal?.scrollback)
            if let fallbackScrollback {
                restoredTerminalScrollbackByTabId[terminalTab.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByTabId.removeValue(forKey: terminalTab.id)
            }
            applySessionTabMetadata(snapshot, toPanelId: terminalTab.id)
            return terminalTab.id
        case .browser:
            let initialURL = snapshot.browser?.urlString.flatMap { URL(string: $0) }
            // C11-25 fix S4+E1: when the persisted snapshot says the panel
            // was hibernated, construct it natively in `.hibernated` so the
            // initial WKWebView load never fires for `initialURL` —
            // matches the executor-driven restore path and closes the same
            // privacy/billing leak on session-snapshot restore.
            let restoredHibernated = snapshotRequestsHibernated(snapshot)
            guard let browserTab = newBrowserSurface(
                inPane: paneId,
                url: initialURL,
                focus: false,
                preferredProfileID: snapshot.browser?.profileID,
                panelId: restoredPanelId,
                pendingHibernate: restoredHibernated,
                createdAt: snapshot.createdAt
            ) else {
                return nil
            }
            applySessionTabMetadata(snapshot, toPanelId: browserTab.id)
            return browserTab.id
        case .markdown:
            guard let markdownTab = newMarkdownTab(
                inPane: paneId,
                filePath: snapshot.markdown?.filePath,
                focus: false,
                panelId: restoredPanelId,
                createdAt: snapshot.createdAt
            ) else {
                return nil
            }
            if let restoredScale = snapshot.markdown?.fontScale {
                markdownTab.applyRestoredFontScale(restoredScale)
            }
            applySessionTabMetadata(snapshot, toPanelId: markdownTab.id)
            return markdownTab.id
        }
    }

    /// C11-25 fix S4+E1: returns `true` when the persisted session
    /// snapshot's per-surface metadata pinned the panel to
    /// `lifecycle_state == "hibernated"`. Used by `createPanel` to
    /// suppress the initial WKWebView navigate so a restored hibernated
    /// browser never briefly hits the network for its persisted URL.
    private func snapshotRequestsHibernated(_ snapshot: SessionTabSnapshot) -> Bool {
        guard let metadata = snapshot.metadata,
              case .string(let raw)? = metadata[MetadataKey.lifecycleState] else {
            return false
        }
        return raw == TabLifecycleState.hibernated.rawValue
    }

    private func applySessionTabMetadata(_ snapshot: SessionTabSnapshot, toPanelId panelId: UUID) {
        // C11-243: restore the persisted last-seen stamp onto the created panel id.
        if let lastSeenAt = snapshot.lastSeenAt {
            TabSeenTracker.shared.seed(panelId: panelId, at: lastSeenAt)
        }
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            tabTitles[panelId] = title
        }

        setTabCustomTitle(panelId: panelId, title: snapshot.customTitle)
        setTabCustomColor(panelId: panelId, color: snapshot.customColor)
        setTabPinned(panelId: panelId, pinned: snapshot.isPinned)

        if snapshot.isManuallyUnread {
            markTabUnread(panelId)
        } else {
            clearManualUnread(panelId: panelId)
        }

        if let directory = snapshot.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            updateTabDirectory(panelId: panelId, directory: directory)
        }

        if let branch = snapshot.gitBranch {
            tabGitBranches[panelId] = SidebarGitBranchState(branch: branch.branch, isDirty: branch.isDirty)
        } else {
            tabGitBranches.removeValue(forKey: panelId)
        }

        tabListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()

        if let ttyName = snapshot.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            tabTTYNames[panelId] = ttyName
        } else {
            tabTTYNames.removeValue(forKey: panelId)
        }

        if let browserSnapshot = snapshot.browser,
           let browserPanel = browserPanel(for: panelId) {
            browserPanel.restoreSessionNavigationHistory(
                backHistoryURLStrings: browserSnapshot.backHistoryURLStrings ?? [],
                forwardHistoryURLStrings: browserSnapshot.forwardHistoryURLStrings ?? [],
                currentURLString: browserSnapshot.urlString
            )

            let pageZoom = CGFloat(max(0.25, min(5.0, browserSnapshot.pageZoom)))
            if pageZoom.isFinite {
                _ = browserPanel.setPageZoomFactor(pageZoom)
            }

            if browserSnapshot.developerToolsVisible {
                _ = browserPanel.showDeveloperTools()
                browserPanel.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
            } else {
                _ = browserPanel.hideDeveloperTools()
            }
        }
    }

    private func applySessionDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode, liveNode) {
        case (.split(let snapshotSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(snapshotSplit.dividerPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            applySessionDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
            applySessionDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
        default:
            return
        }
    }
}

final class WorkspaceRemoteDaemonPendingCallRegistry {
    final class PendingCall {
        let id: Int
        fileprivate let semaphore = DispatchSemaphore(value: 0)
        fileprivate var response: [String: Any]?
        fileprivate var failureMessage: String?

        fileprivate init(id: Int) {
            self.id = id
        }
    }

    enum WaitOutcome {
        case response([String: Any])
        case failure(String)
        case missing
        case timedOut
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.remote-ssh.daemon-rpc.pending.\(UUID().uuidString)")
    private var nextRequestID = 1
    private var pendingCalls: [Int: PendingCall] = [:]

    func reset() {
        queue.sync {
            nextRequestID = 1
            pendingCalls.removeAll(keepingCapacity: false)
        }
    }

    func register() -> PendingCall {
        queue.sync {
            let call = PendingCall(id: nextRequestID)
            nextRequestID += 1
            pendingCalls[call.id] = call
            return call
        }
    }

    @discardableResult
    func resolve(id: Int, payload: [String: Any]) -> Bool {
        queue.sync {
            guard let pendingCall = pendingCalls[id] else { return false }
            pendingCall.response = payload
            pendingCall.semaphore.signal()
            return true
        }
    }

    func failAll(_ message: String) {
        queue.sync {
            let calls = Array(pendingCalls.values)
            for call in calls {
                guard call.response == nil, call.failureMessage == nil else { continue }
                call.failureMessage = message
                call.semaphore.signal()
            }
        }
    }

    func remove(_ call: PendingCall) {
        _ = queue.sync {
            pendingCalls.removeValue(forKey: call.id)
        }
    }

    func wait(for call: PendingCall, timeout: TimeInterval) -> WaitOutcome {
        if call.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            _ = queue.sync {
                pendingCalls.removeValue(forKey: call.id)
            }
            // A response can win the race immediately before timeout cleanup removes the call.
            // Drain any late signal so DispatchSemaphore is not deallocated with a positive count.
            _ = call.semaphore.wait(timeout: .now())
            return .timedOut
        }

        return queue.sync {
            guard let pendingCall = pendingCalls.removeValue(forKey: call.id) else {
                return .missing
            }
            if let failure = pendingCall.failureMessage {
                return .failure(failure)
            }
            guard let response = pendingCall.response else {
                return .missing
            }
            return .response(response)
        }
    }
}

private final class WorkspaceRemoteDaemonRPCClient {
    private static let maxStdoutBufferBytes = 256 * 1024
    static let requiredProxyStreamCapability = "proxy.stream.push"

    enum StreamEvent {
        case data(Data)
        case eof(Data)
        case error(String)
    }

    private struct StreamSubscription {
        let queue: DispatchQueue
        let handler: (StreamEvent) -> Void
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let onUnexpectedTermination: (String) -> Void
    private let writeQueue = DispatchQueue(label: "com.stage11.c11.remote-ssh.daemon-rpc.write.\(UUID().uuidString)")
    private let stateQueue = DispatchQueue(label: "com.stage11.c11.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")
    private let pendingCalls = WorkspaceRemoteDaemonPendingCallRegistry()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var isClosed = true
    private var shouldReportTermination = true

    private var stdoutBuffer = Data()
    private var stderrBuffer = ""
    private var streamSubscriptions: [String: StreamSubscription] = [:]

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.onUnexpectedTermination = onUnexpectedTermination
    }

    func start() throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.daemonArguments(configuration: configuration, remotePath: remotePath)
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStdoutData(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStderrData(data)
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async {
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon transport: \(error.localizedDescription)",
            ])
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.stdoutHandle = stdoutPipe.fileHandleForReading
            self.stderrHandle = stderrPipe.fileHandleForReading
            self.isClosed = false
            self.shouldReportTermination = true
            self.stdoutBuffer = Data()
            self.stderrBuffer = ""
            self.streamSubscriptions.removeAll(keepingCapacity: false)
        }
        pendingCalls.reset()

        do {
            let hello = try call(method: "hello", params: [:], timeout: 8.0)
            let capabilities = (hello["capabilities"] as? [String]) ?? []
            guard capabilities.contains(Self.requiredProxyStreamCapability) else {
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(Self.requiredProxyStreamCapability)",
                ])
            }
        } catch {
            stop(suppressTerminationCallback: true)
            throw error
        }
    }

    func stop() {
        stop(suppressTerminationCallback: true)
    }

    func openStream(host: String, port: Int, timeoutMs: Int = 10000) throws -> String {
        let result = try call(
            method: "proxy.open",
            params: [
                "host": host,
                "port": port,
                "timeout_ms": timeoutMs,
            ],
            timeout: 12.0
        )
        let streamID = (result["stream_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !streamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "proxy.open missing stream_id",
            ])
        }
        return streamID
    }

    func writeStream(streamID: String, data: Data) throws {
        _ = try call(
            method: "proxy.write",
            params: [
                "stream_id": streamID,
                "data_base64": data.base64EncodedString(),
            ],
            timeout: 8.0
        )
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (StreamEvent) -> Void
    ) throws {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "proxy.stream.subscribe requires stream_id",
            ])
        }

        stateQueue.sync {
            streamSubscriptions[trimmedStreamID] = StreamSubscription(queue: queue, handler: onEvent)
        }

        do {
            _ = try call(
                method: "proxy.stream.subscribe",
                params: ["stream_id": trimmedStreamID],
                timeout: 8.0
            )
        } catch {
            unregisterStream(streamID: trimmedStreamID)
            throw error
        }
    }

    func unregisterStream(streamID: String) {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else { return }
        _ = stateQueue.sync {
            streamSubscriptions.removeValue(forKey: trimmedStreamID)
        }
    }

    func closeStream(streamID: String) {
        unregisterStream(streamID: streamID)
        _ = try? call(
            method: "proxy.close",
            params: ["stream_id": streamID],
            timeout: 4.0
        )
    }

    private func call(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let pendingCall = pendingCalls.register()
        let requestID = pendingCall.id

        let payload: Data
        do {
            payload = try Self.encodeJSON([
                "id": requestID,
                "method": method,
                "params": params,
            ])
        } catch {
            pendingCalls.remove(pendingCall)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to encode daemon RPC request \(method): \(error.localizedDescription)",
            ])
        }

        do {
            try writeQueue.sync {
                try writePayload(payload)
            }
        } catch {
            pendingCalls.remove(pendingCall)
            throw error
        }

        let response: [String: Any]
        switch pendingCalls.wait(for: pendingCall, timeout: timeout) {
        case .timedOut:
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC timeout waiting for \(method) response",
            ])
        case .failure(let failure):
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 12, userInfo: [
                NSLocalizedDescriptionKey: failure,
            ])
        case .missing:
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC \(method) returned empty response",
            ])
        case .response(let pendingResponse):
            response = pendingResponse
        }

        let ok = (response["ok"] as? Bool) ?? false
        if ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        let errorObject = (response["error"] as? [String: Any]) ?? [:]
        let code = (errorObject["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "rpc_error"
        let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon RPC call failed"
        throw NSError(domain: "cmux.remote.daemon.rpc", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "\(method) failed (\(code)): \(message)",
        ])
    }

    private func writePayload(_ payload: Data) throws {
        let stdinHandle: FileHandle = stateQueue.sync {
            self.stdinHandle ?? FileHandle.nullDevice
        }
        if stdinHandle === FileHandle.nullDevice {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "daemon transport is not connected",
            ])
        }
        do {
            try stdinHandle.write(contentsOf: payload)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch {
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "failed writing daemon RPC request: \(error.localizedDescription)",
            ])
        }
    }

    private func consumeStdoutData(_ data: Data) {
        guard !data.isEmpty else {
            signalPendingFailureLocked("daemon transport closed stdout")
            return
        }

        stdoutBuffer.append(data)
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            stdoutBuffer.removeAll(keepingCapacity: false)
            signalPendingFailureLocked("daemon transport stdout exceeded \(Self.maxStdoutBufferBytes) bytes without message framing")
            process?.terminate()
            return
        }
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)

            if let carriageIndex = lineData.lastIndex(of: 0x0D), carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard !lineData.isEmpty else { continue }

            guard let payload = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any] else {
                continue
            }

            if let responseID = Self.responseID(in: payload) {
                _ = pendingCalls.resolve(id: responseID, payload: payload)
                continue
            }

            consumeEventPayload(payload)
        }
    }

    private func consumeStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 8192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8192)
        }
    }

    private func consumeEventPayload(_ payload: [String: Any]) {
        guard let eventName = (payload["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !eventName.isEmpty,
              let streamID = (payload["stream_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !streamID.isEmpty else {
            return
        }

        let subscription: StreamSubscription?
        let event: StreamEvent?
        switch eventName {
        case "proxy.stream.data":
            subscription = streamSubscriptions[streamID]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.eof":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            event = .eof(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.error":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            let detail = ((payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "stream error"
            event = .error(detail)

        default:
            return
        }

        guard let subscription, let event else { return }
        subscription.queue.async {
            subscription.handler(event)
        }
    }

    private func handleProcessTermination(_ process: Process) {
        let shouldNotify: Bool = {
            guard self.process === process else { return false }
            return !isClosed && shouldReportTermination
        }()
        let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport exited with status \(process.terminationStatus)"

        isClosed = true
        self.process = nil
        stdinHandle = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        streamSubscriptions.removeAll(keepingCapacity: false)
        signalPendingFailureLocked(detail)

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }

    private func stop(suppressTerminationCallback: Bool) {
        let captured: (Process?, FileHandle?, FileHandle?, FileHandle?, Bool, String) = stateQueue.sync {
            let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport stopped"
            let shouldNotify = !suppressTerminationCallback && !isClosed
            shouldReportTermination = !suppressTerminationCallback
            if isClosed {
                return (nil, nil, nil, nil, false, detail)
            }

            isClosed = true
            signalPendingFailureLocked("daemon transport stopped")
            let capturedProcess = process
            let capturedStdin = stdinHandle
            let capturedStdout = stdoutHandle
            let capturedStderr = stderrHandle

            process = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            streamSubscriptions.removeAll(keepingCapacity: false)
            return (capturedProcess, capturedStdin, capturedStdout, capturedStderr, shouldNotify, detail)
        }

        captured.2?.readabilityHandler = nil
        captured.3?.readabilityHandler = nil
        try? captured.1?.close()
        try? captured.2?.close()
        try? captured.3?.close()
        if let process = captured.0, process.isRunning {
            process.terminate()
        }
        if captured.4 {
            onUnexpectedTermination(captured.5)
        }
    }

    private func signalPendingFailureLocked(_ message: String) {
        pendingCalls.failAll(message)
    }

    private static func responseID(in payload: [String: Any]) -> Int? {
        if let intValue = payload["id"] as? Int {
            return intValue
        }
        if let numberValue = payload["id"] as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func decodeBase64Data(_ value: Any?) -> Data {
        guard let encoded = value as? String, !encoded.isEmpty else { return Data() }
        return Data(base64Encoded: encoded) ?? Data()
    }

    private static func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func daemonArguments(configuration: WorkspaceRemoteConfiguration, remotePath: String) -> [String] {
        let script = "exec \(shellSingleQuoted(remotePath)) serve --stdio"
        // Use non-login sh so remote ~/.profile noise does not interfere with daemon transport startup.
        let command = "sh -c \(shellSingleQuoted(script))"
        return ["-T", "-S", "none"]
            + sshCommonArguments(configuration: configuration, batchMode: true)
            + ["-o", "RequestTTY=no", configuration.destination, command]
    }

    private static let batchSSHControlOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    private static func sshCommonArguments(configuration: WorkspaceRemoteConfiguration, batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            // Batch helpers should reuse an existing ControlPath if one was configured,
            // but must never try to negotiate a new master connection.
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static func backgroundSSHOptions(_ options: [String]) -> [String] {
        normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func bestErrorLine(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}

enum RemoteLoopbackHTTPRequestRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"
    private static let requestLineMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "PRI"]

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        rewriteIfNeeded(data: data, aliasHost: aliasHost, allowIncompleteHeadersAtEOF: false)
    }

    static func rewriteIfNeeded(data: Data, aliasHost: String, allowIncompleteHeadersAtEOF: Bool) -> Data {
        let headerData: Data
        let remainder: Data

        if let headerRange = data.range(of: headerDelimiter) {
            headerData = Data(data[..<headerRange.upperBound])
            remainder = Data(data[headerRange.upperBound...])
        } else if allowIncompleteHeadersAtEOF {
            headerData = data
            remainder = Data()
        } else {
            return data
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        guard let requestLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard requestLineLooksHTTP(lines[requestLineIndex]) else { return data }

        let rewrittenRequestLine = rewriteRequestLine(lines[requestLineIndex], aliasHost: aliasHost)
        if rewrittenRequestLine != lines[requestLineIndex] {
            lines[requestLineIndex] = rewrittenRequestLine
        }

        for index in (requestLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + remainder
    }

    private static func requestLineLooksHTTP(_ requestLine: String) -> Bool {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        return requestLineMethods.contains(method)
    }

    private static func rewriteRequestLine(_ requestLine: String, aliasHost: String) -> String {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return requestLine }

        var components = URLComponents(string: String(parts[1]))
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return requestLine
        }
        components?.host = canonicalLoopbackHost
        guard let rewrittenURL = components?.string else { return requestLine }

        var rewritten = parts
        rewritten[1] = Substring(rewrittenURL)
        let leadingTrivia = requestLine.prefix { $0.isWhitespace || $0.isNewline }
        let trailingTrivia = String(requestLine.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leadingTrivia) + rewritten.joined(separator: " ") + trailingTrivia
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "host":
            guard let rewrittenHost = rewriteHostValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenHost)"
        case "origin", "referer":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        default:
            return line
        }
    }

    private static func rewriteHostValue(_ value: String, aliasHost: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            guard BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
                return nil
            }
            let remainder = String(trimmed[closing...].dropFirst())
            return canonicalLoopbackHost + remainder
        }

        if let colonIndex = trimmed.lastIndex(of: ":"), !trimmed[..<colonIndex].contains(":") {
            let host = String(trimmed[..<colonIndex])
            guard BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
                return nil
            }
            return canonicalLoopbackHost + trimmed[colonIndex...]
        }

        guard BrowserInsecureHTTPSettings.normalizeHost(trimmed) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        return canonicalLoopbackHost
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        components?.host = canonicalLoopbackHost
        return components?.string
    }
}

struct RemoteLoopbackHTTPRequestStreamRewriter {
    private static let maxHeaderBytes = 64 * 1024
    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let aliasHost: String
    private var pendingHeaderBytes = Data()
    private var hasForwardedHeaders = false

    init(aliasHost: String) {
        self.aliasHost = aliasHost
    }

    mutating func rewriteNextChunk(_ data: Data, eof: Bool) -> Data {
        guard !hasForwardedHeaders else { return data }

        pendingHeaderBytes.append(data)
        if pendingHeaderBytes.count > Self.maxHeaderBytes {
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        guard pendingHeaderBytes.range(of: Self.headerDelimiter) != nil else {
            guard eof else { return Data() }
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        hasForwardedHeaders = true
        let payload = pendingHeaderBytes
        pendingHeaderBytes = Data()
        return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: payload,
            aliasHost: aliasHost
        )
    }
}

enum RemoteLoopbackHTTPResponseRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        guard let headerRange = data.range(of: headerDelimiter) else { return data }
        let headerData = Data(data[..<headerRange.upperBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard lines[statusLineIndex].uppercased().hasPrefix("HTTP/") else { return data }

        for index in (statusLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + data[headerRange.upperBound...]
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "location", "content-location", "origin", "referer", "access-control-allow-origin":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        case "set-cookie":
            guard let rewrittenCookie = rewriteCookieValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenCookie)"
        default:
            return line
        }
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(canonicalLoopbackHost) else {
            return nil
        }
        components?.host = aliasHost
        return components?.string
    }

    private static func rewriteCookieValue(_ value: String, aliasHost: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        var didRewrite = false
        let rewrittenParts = parts.map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("domain=") else { return part }
            let domainValue = String(trimmed.dropFirst("domain=".count))
            guard BrowserInsecureHTTPSettings.normalizeHost(domainValue) == BrowserInsecureHTTPSettings.normalizeHost(canonicalLoopbackHost) else {
                return part
            }
            didRewrite = true
            let leadingWhitespace = part.prefix { $0.isWhitespace }
            return "\(leadingWhitespace)Domain=\(aliasHost)"
        }

        return didRewrite ? rewrittenParts.joined(separator: ";") : nil
    }
}

private final class WorkspaceRemoteDaemonProxyTunnel {
    private final class ProxySession {
        private static let maxHandshakeBytes = 64 * 1024
        private static let remoteLoopbackProxyAliasHost = "c11-loopback.localtest.me"

        private enum HandshakeProtocol {
            case undecided
            case socks5
            case connect
        }

        private enum SocksStage {
            case greeting
            case request
        }

        private struct SocksRequest {
            let host: String
            let port: Int
            let command: UInt8
            let consumedBytes: Int
        }

        let id = UUID()

        private let connection: NWConnection
        private let rpcClient: WorkspaceRemoteDaemonRPCClient
        private let queue: DispatchQueue
        private let onClose: (UUID) -> Void

        private var isClosed = false
        private var protocolKind: HandshakeProtocol = .undecided
        private var socksStage: SocksStage = .greeting
        private var handshakeBuffer = Data()
        private var streamID: String?
        private var localInputEOF = false
        private var rewritesLoopbackHTTPHeaders = false
        private var loopbackRequestHeaderRewriter: RemoteLoopbackHTTPRequestStreamRewriter?
        private var pendingRemoteHTTPHeaderBytes = Data()
        private var hasForwardedRemoteHTTPHeaders = false

        init(
            connection: NWConnection,
            rpcClient: WorkspaceRemoteDaemonRPCClient,
            queue: DispatchQueue,
            onClose: @escaping (UUID) -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "proxy client connection failed: \(error)")
                case .cancelled:
                    self.close(reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(reason: nil)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    if self.streamID == nil {
                        if self.handshakeBuffer.count + data.count > Self.maxHandshakeBytes {
                            self.close(reason: "proxy handshake exceeded \(Self.maxHandshakeBytes) bytes")
                            return
                        }
                        self.handshakeBuffer.append(data)
                        self.processHandshakeBuffer()
                    } else {
                        self.forwardToRemote(data, eof: isComplete)
                    }
                }

                if isComplete {
                    // Treat local EOF as a half-close: keep remote read loop alive so we can
                    // drain upstream response bytes (for example curl closing write-side after
                    // sending an HTTP request through SOCKS/CONNECT).
                    self.localInputEOF = true
                    if self.streamID != nil, data?.isEmpty ?? true {
                        self.forwardToRemote(Data(), eof: true, allowAfterEOF: true)
                    }
                    if self.streamID == nil {
                        self.close(reason: nil)
                    }
                    return
                }
                if let error {
                    self.close(reason: "proxy client receive error: \(error)")
                    return
                }

                self.receiveNext()
            }
        }

        private func processHandshakeBuffer() {
            guard !isClosed else { return }
            while streamID == nil {
                switch protocolKind {
                case .undecided:
                    guard let first = handshakeBuffer.first else { return }
                    protocolKind = (first == 0x05) ? .socks5 : .connect
                case .socks5:
                    if !processSocksHandshakeStep() {
                        return
                    }
                case .connect:
                    if !processConnectHandshakeStep() {
                        return
                    }
                }
            }
        }

        private func processSocksHandshakeStep() -> Bool {
            switch socksStage {
            case .greeting:
                guard handshakeBuffer.count >= 2 else { return false }
                let methodCount = Int(handshakeBuffer[1])
                let total = 2 + methodCount
                guard handshakeBuffer.count >= total else { return false }

                let methods = [UInt8](handshakeBuffer[2..<total])
                handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
                socksStage = .request

                if !methods.contains(0x00) {
                    sendAndClose(Data([0x05, 0xFF]))
                    return false
                }
                sendLocal(Data([0x05, 0x00]))
                return true

            case .request:
                let request: SocksRequest
                do {
                    guard let parsed = try parseSocksRequest(from: handshakeBuffer) else { return false }
                    request = parsed
                } catch {
                    sendAndClose(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                let pending = handshakeBuffer.count > request.consumedBytes
                    ? Data(handshakeBuffer[request.consumedBytes...])
                    : Data()
                handshakeBuffer = Data()
                guard request.command == 0x01 else {
                    sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                openRemoteStream(
                    host: request.host,
                    port: request.port,
                    successResponse: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    failureResponse: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    pendingPayload: pending
                )
                return false
            }
        }

        private func parseSocksRequest(from data: Data) throws -> SocksRequest? {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 0x05 else {
                throw NSError(domain: "cmux.remote.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS version"])
            }

            let command = bytes[1]
            let addressType = bytes[3]
            var cursor = 4
            let host: String

            switch addressType {
            case 0x01:
                guard bytes.count >= cursor + 4 + 2 else { return nil }
                let octets = bytes[cursor..<(cursor + 4)].map { String($0) }
                host = octets.joined(separator: ".")
                cursor += 4

            case 0x03:
                guard bytes.count >= cursor + 1 else { return nil }
                let length = Int(bytes[cursor])
                cursor += 1
                guard bytes.count >= cursor + length + 2 else { return nil }
                let hostData = Data(bytes[cursor..<(cursor + length)])
                host = String(data: hostData, encoding: .utf8) ?? ""
                cursor += length

            case 0x04:
                guard bytes.count >= cursor + 16 + 2 else { return nil }
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { target in
                    for i in 0..<16 {
                        target[i] = bytes[cursor + i]
                    }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let pointer = withUnsafePointer(to: &address) {
                    inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
                }
                host = pointer != nil ? String(cString: text) : ""
                cursor += 16

            default:
                throw NSError(domain: "cmux.remote.proxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS address type"])
            }

            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "cmux.remote.proxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty SOCKS host"])
            }
            guard bytes.count >= cursor + 2 else { return nil }
            let port = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2

            guard port > 0 && port <= 65535 else {
                throw NSError(domain: "cmux.remote.proxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS port"])
            }

            return SocksRequest(host: host, port: port, command: command, consumedBytes: cursor)
        }

        private func processConnectHandshakeStep() -> Bool {
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerRange = handshakeBuffer.range(of: marker) else { return false }

            let headerData = Data(handshakeBuffer[..<headerRange.upperBound])
            let pending = headerRange.upperBound < handshakeBuffer.count
                ? Data(handshakeBuffer[headerRange.upperBound...])
                : Data()
            handshakeBuffer = Data()
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            guard let (host, port) = Self.parseConnectAuthority(parts[1]) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            openRemoteStream(
                host: host,
                port: port,
                successResponse: Self.httpResponse(status: "200 Connection Established", closeAfterResponse: false),
                failureResponse: Self.httpResponse(status: "502 Bad Gateway", closeAfterResponse: true),
                pendingPayload: pending
            )
            return false
        }

        private func openRemoteStream(
            host: String,
            port: Int,
            successResponse: Data,
            failureResponse: Data,
            pendingPayload: Data
        ) {
            guard !isClosed else { return }
            do {
                rewritesLoopbackHTTPHeaders =
                    BrowserInsecureHTTPSettings.normalizeHost(host)
                    == BrowserInsecureHTTPSettings.normalizeHost(Self.remoteLoopbackProxyAliasHost)
                loopbackRequestHeaderRewriter = rewritesLoopbackHTTPHeaders
                    ? RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: Self.remoteLoopbackProxyAliasHost)
                    : nil
                pendingRemoteHTTPHeaderBytes = Data()
                hasForwardedRemoteHTTPHeaders = false
                let targetHost = Self.normalizedProxyTargetHost(host)
                let streamID = try rpcClient.openStream(host: targetHost, port: port)
                self.streamID = streamID
                try rpcClient.attachStream(streamID: streamID, queue: queue) { [weak self] event in
                    self?.handleRemoteStreamEvent(streamID: streamID, event: event)
                }
                connection.send(content: successResponse, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if !pendingPayload.isEmpty {
                        self.forwardToRemote(pendingPayload, allowAfterEOF: true)
                    }
                })
            } catch {
                sendAndClose(failureResponse)
            }
        }

        private func forwardToRemote(_ data: Data, eof: Bool = false, allowAfterEOF: Bool = false) {
            guard !isClosed else { return }
            guard !localInputEOF || allowAfterEOF else { return }
            guard let streamID else { return }
            do {
                let outgoingData: Data
                if rewritesLoopbackHTTPHeaders {
                    outgoingData = loopbackRequestHeaderRewriter?.rewriteNextChunk(data, eof: eof) ?? data
                } else {
                    outgoingData = data
                }
                guard !outgoingData.isEmpty else { return }
                try rpcClient.writeStream(streamID: streamID, data: outgoingData)
            } catch {
                close(reason: "proxy.write failed: \(error.localizedDescription)")
            }
        }

        private func handleRemoteStreamEvent(
            streamID: String,
            event: WorkspaceRemoteDaemonRPCClient.StreamEvent
        ) {
            guard !isClosed else { return }
            guard self.streamID == streamID else { return }

            switch event {
            case .data(let data):
                forwardRemotePayloadToLocal(data, eof: false)

            case .eof(let data):
                forwardRemotePayloadToLocal(data, eof: true)

            case .error(let detail):
                close(reason: "proxy.stream failed: \(detail)")
            }
        }

        private func forwardRemotePayloadToLocal(_ data: Data, eof: Bool) {
            let localData = rewriteRemoteResponseIfNeeded(data, eof: eof)
            if !localData.isEmpty {
                connection.send(content: localData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if eof {
                        self.close(reason: nil)
                    }
                })
                return
            }

            if eof {
                close(reason: nil)
            }
        }

        private func rewriteRemoteResponseIfNeeded(_ data: Data, eof: Bool) -> Data {
            guard rewritesLoopbackHTTPHeaders else { return data }
            guard !data.isEmpty else { return data }
            guard !hasForwardedRemoteHTTPHeaders else { return data }

            pendingRemoteHTTPHeaderBytes.append(data)
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard pendingRemoteHTTPHeaderBytes.range(of: marker) != nil else {
                guard eof else { return Data() }
                hasForwardedRemoteHTTPHeaders = true
                let payload = pendingRemoteHTTPHeaderBytes
                pendingRemoteHTTPHeaderBytes = Data()
                return payload
            }

            hasForwardedRemoteHTTPHeaders = true
            let payload = pendingRemoteHTTPHeaderBytes
            pendingRemoteHTTPHeaderBytes = Data()
            return RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: Self.remoteLoopbackProxyAliasHost
            )
        }

        private func close(reason: String?) {
            guard !isClosed else { return }
            isClosed = true

            let streamID = self.streamID
            self.streamID = nil

            if let streamID {
                rpcClient.closeStream(streamID: streamID)
            }
            connection.cancel()
            onClose(id)
        }

        private func sendLocal(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.close(reason: "proxy client send error: \(error)")
                }
            })
        }

        private func sendAndClose(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close(reason: nil)
            })
        }

        private static func parseConnectAuthority(_ authority: String) -> (host: String, port: Int)? {
            let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]") else { return nil }
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
                let portStart = trimmed.index(after: closing)
                guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
                let portString = String(trimmed[trimmed.index(after: portStart)...])
                guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
                return (host, port)
            }

            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            let portString = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
            return (host, port)
        }

        private static func normalizedProxyTargetHost(_ host: String) -> String {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            // BrowserPanel rewrites loopback URLs to this alias so proxy routing works.
            // Resolve it back to true loopback before dialing from the remote daemon.
            if normalized == remoteLoopbackProxyAliasHost {
                return "127.0.0.1"
            }
            return host
        }

        private static func httpResponse(status: String, closeAfterResponse: Bool = true) -> Data {
            var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
            if closeAfterResponse {
                text += "Connection: close\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let localPort: Int
    private let onFatalError: (String) -> Void
    private let queue = DispatchQueue(label: "com.stage11.c11.remote-ssh.daemon-tunnel.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var rpcClient: WorkspaceRemoteDaemonRPCClient?
    private var sessions: [UUID: ProxySession] = [:]
    private var isStopped = false

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.localPort = localPort
        self.onFatalError = onFatalError
    }

    func start() throws {
        var capturedError: Error?
        queue.sync {
            guard !isStopped else {
                capturedError = NSError(domain: "cmux.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                let client = WorkspaceRemoteDaemonRPCClient(
                    configuration: configuration,
                    remotePath: remotePath
                ) { [weak self] detail in
                    self?.queue.async {
                        self?.failLocked("Remote daemon transport failed: \(detail)")
                    }
                }
                try client.start()

                let listener = try Self.makeLoopbackListener(port: localPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.acceptConnectionLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        self?.handleListenerStateLocked(state)
                    }
                }

                self.rpcClient = client
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                capturedError = error
                stopLocked(notify: false)
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    func stop() {
        queue.sync {
            stopLocked(notify: false)
        }
    }

    private func handleListenerStateLocked(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .failed(let error):
            failLocked("Local proxy listener failed: \(error)")
        default:
            break
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        guard let rpcClient else {
            connection.cancel()
            return
        }

        let session = ProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }

    private func failLocked(_ detail: String) {
        guard !isStopped else { return }
        stopLocked(notify: false)
        onFatalError(detail)
    }

    private func stopLocked(notify: Bool) {
        guard !isStopped else { return }
        isStopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }

        rpcClient?.stop()
        rpcClient = nil
    }

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        guard let localPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "cmux.remote.proxy", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "invalid local proxy port \(port)",
            ])
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: localPort)
        return try NWListener(using: parameters)
    }
}

private final class WorkspaceRemoteProxyBroker {
    enum Update {
        case connecting
        case ready(BrowserProxyEndpoint)
        case error(String)
    }

    final class Lease {
        private let key: String
        private let subscriberID: UUID
        private weak var broker: WorkspaceRemoteProxyBroker?
        private var isReleased = false

        fileprivate init(key: String, subscriberID: UUID, broker: WorkspaceRemoteProxyBroker) {
            self.key = key
            self.subscriberID = subscriberID
            self.broker = broker
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            broker?.release(key: key, subscriberID: subscriberID)
        }

        deinit {
            release()
        }
    }

    private final class Entry {
        let configuration: WorkspaceRemoteConfiguration
        var remotePath: String
        var tunnel: WorkspaceRemoteDaemonProxyTunnel?
        var endpoint: BrowserProxyEndpoint?
        var restartWorkItem: DispatchWorkItem?
        var subscribers: [UUID: (Update) -> Void] = [:]

        init(configuration: WorkspaceRemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    static let shared = WorkspaceRemoteProxyBroker()

    private let queue = DispatchQueue(label: "com.stage11.c11.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]

    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping (Update) -> Void
    ) -> Lease {
        queue.sync {
            let key = Self.transportKey(for: configuration)
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartWorkItem == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return Lease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    private func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    private func startEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil

        let localPort: Int
        if let forcedLocalPort = entry.configuration.localProxyPort {
            // Internal deterministic test hook used by docker regressions to force bind conflicts.
            localPort = forcedLocalPort
        } else {
            guard let allocatedPort = Self.allocateLoopbackPort() else {
                notifyLocked(
                    entry,
                    update: .error("Failed to allocate local proxy port\(Self.retrySuffix(delay: 3.0))")
                )
                scheduleRestartLocked(key: key, entry: entry, delay: 3.0)
                return
            }
            localPort = allocatedPort
        }

        do {
            let tunnel = WorkspaceRemoteDaemonProxyTunnel(
                configuration: entry.configuration,
                remotePath: entry.remotePath,
                localPort: localPort
            ) { [weak self] detail in
                self?.queue.async {
                    self?.handleTunnelFailureLocked(key: key, detail: detail)
                }
            }
            try tunnel.start()
            entry.tunnel = tunnel
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: localPort)
            entry.endpoint = endpoint
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry)
            let detail = "Failed to start local daemon proxy: \(error.localizedDescription)"
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: 3.0))"))
            scheduleRestartLocked(key: key, entry: entry, delay: 3.0)
        }
    }

    private func handleTunnelFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: 3.0))"))
        scheduleRestartLocked(key: key, entry: entry, delay: 3.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, delay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentEntry = self.entries[key] else { return }
            currentEntry.restartWorkItem = nil
            guard !currentEntry.subscribers.isEmpty else {
                self.teardownEntryLocked(key: key, entry: currentEntry)
                return
            }
            self.notifyLocked(currentEntry, update: .connecting)
            self.startEntryLocked(key: key, entry: currentEntry)
        }

        entry.restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil
        stopEntryRuntimeLocked(entry)
        entries.removeValue(forKey: key)
    }

    private func stopEntryRuntimeLocked(_ entry: Entry) {
        entry.tunnel?.stop()
        entry.tunnel = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: Update) {
        for callback in entry.subscribers.values {
            callback(update)
        }
    }

    private static func transportKey(for configuration: WorkspaceRemoteConfiguration) -> String {
        configuration.proxyBrokerTransportKey
    }

    private static func allocateLoopbackPort() -> Int? {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }
}

// Kept as a refusing compatibility endpoint; this version never starts a relay listener.
final class WorkspaceRemoteCLIRelayServer {
    final class Session {
        private enum Phase {
            case awaitingAuth
            case awaitingCommand
            case closed
        }

        private let connection: NWConnection
        private let relayID: String
        private let relayToken: Data
        private let queue: DispatchQueue
        private let onClose: () -> Void
        private let challengeProtocol = "cmux-relay-auth"
        private let challengeVersion = 1
        private let minimumFailureDelay: TimeInterval = 0.05
        private let maximumFrameBytes = 16 * 1024

        private var buffer = Data()
        private var phase: Phase = .awaitingAuth
        private var challengeNonce = ""
        private var challengeSentAt = Date()
        private var isClosed = false

        init(
            connection: NWConnection,
            relayID: String,
            relayToken: Data,
            queue: DispatchQueue,
            onClose: @escaping () -> Void
        ) {
            self.connection = connection
            self.relayID = relayID
            self.relayToken = relayToken
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleState(state)
                }
            }
            connection.start(queue: queue)
        }

        func stop() {
            close()
        }

        private func handleState(_ state: NWConnection.State) {
            guard !isClosed else { return }
            switch state {
            case .ready:
                sendChallenge()
                receive()
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }

        private func sendChallenge() {
            challengeSentAt = Date()
            challengeNonce = Self.randomHex(byteCount: 16)
            let challenge: [String: Any] = [
                "protocol": challengeProtocol,
                "version": challengeVersion,
                "relay_id": relayID,
                "nonce": challengeNonce,
            ]
            sendJSONLine(challenge) { _ in }
        }

        private func receive() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumFrameBytes) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if error != nil {
                        self.close()
                        return
                    }
                    if let data, !data.isEmpty {
                        self.buffer.append(data)
                        if self.buffer.count > self.maximumFrameBytes {
                            self.sendFailureAndClose()
                            return
                        }
                        self.processBufferedLines()
                    }
                    if isComplete {
                        self.close()
                        return
                    }
                    if !self.isClosed {
                        self.receive()
                    }
                }
            }
        }

        private func processBufferedLines() {
            while let newlineIndex = buffer.firstIndex(of: 0x0A), !isClosed {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch phase {
                case .awaitingAuth:
                    handleAuthLine(line)
                case .awaitingCommand:
                    handleCommandLine(Data(lineData) + Data([0x0A]))
                case .closed:
                    return
                }
            }
        }

        private func handleAuthLine(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receivedRelayID = object["relay_id"] as? String,
                  receivedRelayID == relayID,
                  let macHex = object["mac"] as? String,
                  let receivedMAC = Self.hexData(from: macHex)
            else {
                sendFailureAndClose()
                return
            }

            let message = Self.authMessage(relayID: relayID, nonce: challengeNonce, version: challengeVersion)
            let expectedMAC = Self.authMAC(token: relayToken, message: message)
            guard Self.constantTimeEqual(receivedMAC, expectedMAC) else {
                sendFailureAndClose()
                return
            }

            phase = .awaitingCommand
            sendJSONLine(["ok": true]) { [weak self] _ in
                self?.queue.async {
                    self?.processBufferedLines()
                }
            }
        }

        private func handleCommandLine(_ commandLine: Data) {
            // Authentication never enables remote commands in this version.
            phase = .closed
            sendJSONLine([
                "ok": false,
                "error": [
                    "code": "remote_commands_disabled",
                    "message": "c11 commands are not available over c11 ssh in this version",
                ],
            ]) { [weak self] _ in
                self?.queue.async { self?.close() }
            }
        }

        private func sendFailureAndClose() {
            let elapsed = Date().timeIntervalSince(challengeSentAt)
            let delay = max(0, minimumFailureDelay - elapsed)
            phase = .closed
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendJSONLine(["ok": false]) { [weak self] _ in
                    self?.queue.async {
                        self?.close()
                    }
                }
            }
        }

        private func sendJSONLine(_ object: [String: Any], completion: @escaping (NWError?) -> Void) {
            guard !isClosed else {
                completion(nil)
                return
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
                completion(nil)
                return
            }
            connection.send(content: payload + Data([0x0A]), completion: .contentProcessed(completion))
        }

        private func close() {
            guard !isClosed else { return }
            isClosed = true
            phase = .closed
            connection.stateUpdateHandler = nil
            connection.cancel()
            onClose()
        }

        private static func authMessage(relayID: String, nonce: String, version: Int) -> Data {
            Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        }

        private static func authMAC(token: Data, message: Data) -> Data {
            let key = SymmetricKey(data: token)
            let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
            return Data(code)
        }

        private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
            guard lhs.count == rhs.count else { return false }
            var diff: UInt8 = 0
            for index in lhs.indices {
                diff |= lhs[index] ^ rhs[index]
            }
            return diff == 0
        }

        fileprivate static func hexData(from string: String) -> Data? {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count.isMultiple(of: 2), !normalized.isEmpty else { return nil }
            var data = Data(capacity: normalized.count / 2)
            var cursor = normalized.startIndex
            while cursor < normalized.endIndex {
                let next = normalized.index(cursor, offsetBy: 2)
                guard let byte = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
                data.append(byte)
                cursor = next
            }
            return data
        }

        private static func randomHex(byteCount: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

    }

    func start() throws -> Int {
        throw NSError(domain: "c11.remote.relay", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "c11 commands are not available over c11 ssh in this version",
        ])
    }
}

final class WorkspaceRemoteSessionController {
    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    private struct RemoteBootstrapState {
        let platform: RemotePlatform
        let binaryExists: Bool
    }

    private struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.remote-ssh.\(UUID().uuidString)", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private weak var workspace: Workspace?
    private let configuration: WorkspaceRemoteConfiguration
    private let controllerID: UUID

    private var isStopping = false
    private var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    private var proxyEndpoint: BrowserProxyEndpoint?
    private var daemonReady = false
    private var daemonBootstrapVersion: String?
    private var daemonRemotePath: String?
    private var reconnectRetryCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var heartbeatCount: Int = 0
    private var connectionAttemptStartedAt: Date?


    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    private func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        reconnectWorkItem = nil
        let connectDetail: String
        let bootstrapDetail: String
        if reconnectRetryCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let hello = try bootstrapDaemonLocked()
            guard hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) else {
                throw NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability)",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            recordHeartbeatActivityLocked()
            startProxyLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    private func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = WorkspaceRemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    private func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectRetryCount = 0
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let nextRetry = scheduleReconnectLocked(delay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: nextRetry, delay: 2.0)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    @discardableResult
    private func scheduleReconnectLocked(delay: TimeInterval) -> Int {
        guard !isStopping else { return reconnectRetryCount }
        reconnectWorkItem?.cancel()
        reconnectRetryCount += 1
        let retryNumber = reconnectRetryCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return retryNumber
    }

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let controllerID = self.controllerID
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    private func publishPortsSnapshotLocked() {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemotePortsSnapshot(
                detected: [],
                forwarded: [],
                conflicts: [],
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
        }
    }

    private static let remotePlatformProbeOSMarker = "__CMUX_REMOTE_OS__="
    private static let remotePlatformProbeArchMarker = "__CMUX_REMOTE_ARCH__="
    private static let remotePlatformProbeExistsMarker = "__CMUX_REMOTE_EXISTS__="

    private func sshCommonArguments(batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private func backgroundSSHOptions(_ options: [String]) -> [String] {
        let batchSSHControlOptionKeys: Set<String> = [
            "controlmaster",
            "controlpersist",
        ]
        return normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func scpExec(arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "cmux.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            captureQueue.sync {
                stdoutData = data
            }
            captureGroup.leave()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            captureQueue.sync {
                stderrData = data
            }
            captureGroup.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        _ = captureGroup.wait(timeout: .now() + 2.0)
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(Self.debugLogSnippet(stdout)) " +
            "stderr=\(Self.debugLogSnippet(stderr))"
        )
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = Self.remoteDaemonVersion()
        let bootstrapState = try probeRemoteBootstrapStateLocked(version: version)
        let platform = bootstrapState.platform
        let remotePath = Self.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)
        let explicitOverrideBinary = Self.explicitRemoteDaemonBinaryURL()
        let forceExplicitOverrideInstall = explicitOverrideBinary != nil
        debugLog(
            "remote.bootstrap.platform os=\(platform.goOS) arch=\(platform.goArch) " +
            "version=\(version) remotePath=\(remotePath) " +
            "allowLocalBuildFallback=\(Self.allowLocalDaemonBuildFallback() ? 1 : 0) " +
            "explicitOverride=\(forceExplicitOverrideInstall ? 1 : 0)"
        )

        let hadExistingBinary = bootstrapState.binaryExists
        debugLog("remote.bootstrap.binaryExists remotePath=\(remotePath) exists=\(hadExistingBinary ? 1 : 0)")
        if forceExplicitOverrideInstall || !hadExistingBinary {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        var hello: DaemonHello
        do {
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        } catch {
            guard hadExistingBinary else {
                throw error
            }
            debugLog(
                "remote.bootstrap.helloRetry remotePath=\(remotePath) " +
                "detail=\(error.localizedDescription)"
            )
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }
        if hadExistingBinary, !hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) {
            debugLog("remote.bootstrap.capabilityMissing remotePath=\(remotePath) capabilities=\(hello.capabilities.joined(separator: ","))")
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }

        debugLog(
            "remote.bootstrap.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) remotePath=\(hello.remotePath)"
        )
        if let connectionAttemptStartedAt {
            debugLog(
                "remote.timing.bootstrap.ready elapsedMs=\(Int(Date().timeIntervalSince(connectionAttemptStartedAt) * 1000)) " +
                "\(debugConfigSummary())"
            )
        }
        return hello
    }

    static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        """
        relay_socket='127.0.0.1:\(relayPort)'
        socket_addr_file="$HOME/.cmux/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$HOME/.cmux/relay/\(relayPort).auth" "$HOME/.cmux/relay/\(relayPort).daemon_path"
        """
    }

    private func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = """
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$cmux_uname_arch"
        case "$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" in
          linux|darwin|freebsd) cmux_go_os="$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
          *) exit 70 ;;
        esac
        case "$(printf '%s' "$cmux_uname_arch" | tr '[:upper:]' '[:lower:]')" in
          x86_64|amd64) cmux_go_arch=amd64 ;;
          aarch64|arm64) cmux_go_arch=arm64 ;;
          armv7l) cmux_go_arch=arm ;;
          *) exit 71 ;;
        esac
        cmux_remote_path="$HOME/.cmux/bin/c11d-remote/\(version)/${cmux_go_os}-${cmux_go_arch}/c11d-remote"
        if [ -x "$cmux_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 20)

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unameOS = lines.first { $0.hasPrefix(Self.remotePlatformProbeOSMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeOSMarker.count)) }
        let unameArch = lines.first { $0.hasPrefix(Self.remotePlatformProbeArchMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeArchMarker.count)) }
        guard let unameOS, let unameArch else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        guard let goOS = Self.mapUnameOS(unameOS),
              let goArch = Self.mapUnameArch(unameArch) else {
            throw NSError(domain: "cmux.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(unameOS)/\(unameArch)",
            ])
        }

        let binaryExists = lines.first { $0.hasPrefix(Self.remotePlatformProbeExistsMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeExistsMarker.count)) == "yes" }
        if result.status != 0, binaryExists == nil {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote daemon state: \(detail)",
            ])
        }

        return RemoteBootstrapState(
            platform: RemotePlatform(goOS: goOS, goArch: goArch),
            binaryExists: binaryExists ?? false
        )
    }

    static let remoteDaemonManifestInfoKey = "CMUXRemoteDaemonManifestJSON"

    static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        guard let rawManifest = infoDictionary?[remoteDaemonManifestInfoKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private static func remoteDaemonManifest() -> WorkspaceRemoteDaemonManifest? {
        remoteDaemonManifest(from: Bundle.main.infoDictionary)
    }

    private static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
        StateDirectoryMigration.ensureMigrated(fileManager: fileManager)
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupportRoot
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try remoteDaemonCacheRoot(fileManager: fileManager)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("c11d-remote", isDirectory: false)
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["C11_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
            || environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    private static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        let value = environment["C11_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? environment["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = value, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("c11d-remote", isDirectory: false)
    }

    private func downloadRemoteDaemonBinaryLocked(entry: WorkspaceRemoteDaemonManifest.Entry, version: String) throws -> URL {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "cmux.remote.daemon", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("c11/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadedURL: URL?
        var downloadError: Error?
        session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "cmux.remote.daemon", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }.resume()
        _ = semaphore.wait(timeout: .now() + 75.0)
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "cmux.remote.daemon", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        let downloadedSHA = try Self.sha256Hex(forFile: downloadedURL)
        guard downloadedSHA == entry.sha256.lowercased() else {
            throw NSError(domain: "cmux.remote.daemon", code: 28, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName)",
            ])
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return cacheURL
    }

    private func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let explicitBinary = Self.explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            debugLog("remote.build.explicit path=\(explicitBinary.path)")
            return explicitBinary
        }

        if let manifest = Self.remoteDaemonManifest(),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: manifest.appVersion, goOS: goOS, goArch: goArch)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cachedSHA = try Self.sha256Hex(forFile: cacheURL)
                if cachedSHA == entry.sha256.lowercased(),
                   FileManager.default.isExecutableFile(atPath: cacheURL.path) {
                    debugLog("remote.build.cached path=\(cacheURL.path)")
                    return cacheURL
                }
                try? FileManager.default.removeItem(at: cacheURL)
            }
            let downloadedURL = try downloadRemoteDaemonBinaryLocked(entry: entry, version: manifest.appVersion)
            debugLog("remote.build.downloaded path=\(downloadedURL.path)")
            return downloadedURL
        }

        guard Self.allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified c11d-remote manifest for \(goOS)-\(goArch). Use a release/nightly build, or set C11_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate c11 repo root for dev-only c11d-remote build fallback",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "cmux.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "cmux.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required for the dev-only c11d-remote build fallback",
            ])
        }

        let output = Self.versionedRemoteDaemonBuildURL(goOS: goOS, goArch: goArch, version: version)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", output.path, "./cmd/c11d-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build c11d-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "cmux.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "c11d-remote build output is not executable",
            ])
        }
        debugLog("remote.build.output path=\(output.path)")
        return output
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(Self.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(Self.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let scpSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var scpArgs: [String] = ["-q"]
        if !hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
            scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        scpArgs += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in scpSSHOptions {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload c11d-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(Self.shellSingleQuoted(remoteTempPath)) && \
        mv \(Self.shellSingleQuoted(remoteTempPath)) \(Self.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(Self.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(Self.shellSingleQuoted(request)) | \(Self.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "c11d-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        dlog(message())
#endif
    }

    private func debugConfigSummary() -> String {
        let controlPath = Self.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }

    private func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(Self.shellSingleQuoted)
            .joined(separator: " ")
    }

    private static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/bin/sh
        echo 'c11 commands are not available over c11 ssh in this version' >&2
        exit 1
        """
    }

    private static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    private static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    private static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    private static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    private static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    private static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
        guard let repoRoot = findRepoRoot() else { return nil }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: daemonRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: daemonRoot.path + "/", with: "")
            if relativePath == "go.mod" || relativePath == "go.sum" || relativePath.hasSuffix(".go") {
                relativePaths.append(relativePath)
            }
        }

        guard !relativePaths.isEmpty else { return nil }

        let digest = SHA256.hash(data: relativePaths.sorted().reduce(into: Data()) { partialResult, relativePath in
            let fileURL = daemonRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            partialResult.append(Data(relativePath.utf8))
            partialResult.append(0)
            partialResult.append(fileData)
            partialResult.append(0)
        })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/c11d-remote/\(version)/\(goOS)-\(goArch)/c11d-remote"
    }

    private static func which(_ executable: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = String(component) + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = c11Env("C11_REMOTE_DAEMON_SOURCE_ROOT", in: environment),
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        // `CMUXTERM_REPO_ROOT` predates the `CMUX_`/`C11_` twin scheme (note the
        // `CMUXTERM_` prefix), so its canonical twin is read explicitly here.
        if let envRoot = environment["C11_REPO_ROOT"] ?? environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

    private static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    private static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState {
    let value: Double
    let label: String?
    /// TEL-2: wall-clock stamp of when this progress value was written. Defaulted
    /// to `Date()` so the synthesized memberwise initializer keeps every existing
    /// `SidebarProgressState(value:label:)` call site compiling while stamping each
    /// fresh write "now".
    var timestamp: Date = Date()
}

struct SidebarGitBranchState {
    let branch: String
    let isDirty: Bool
}

enum WorkspaceRemoteConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

enum WorkspaceRemoteDaemonState: String {
    case unavailable
    case bootstrapping
    case ready
    case error
}

struct WorkspaceRemoteDaemonStatus: Equatable {
    var state: WorkspaceRemoteDaemonState = .unavailable
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String] = []
    var remotePath: String?

    func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}

struct WorkspaceRemoteConfiguration: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let localProxyPort: Int?
    let relayPort: Int?
    let relayID: String?
    let relayToken: String?
    let localSocketPath: String?
    let terminalStartupCommand: String?

    var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }

    var proxyBrokerTransportKey: String {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedIdentity = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedLocalProxyPort = localProxyPort.map(String.init) ?? ""
        let normalizedOptions = Self.proxyBrokerSSHOptions(sshOptions).joined(separator: "\u{1f}")
        return [normalizedDestination, normalizedPort, normalizedIdentity, normalizedOptions, normalizedLocalProxyPort]
            .joined(separator: "\u{1e}")
    }

    private static func proxyBrokerSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }.filter { option in
            proxyBrokerSSHOptionKey(option) != "controlpath"
        }
    }

    private static func proxyBrokerSSHOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }
}

enum SidebarPullRequestStatus: String {
    case open
    case merged
    case closed
}

enum SidebarPullRequestChecksStatus: String {
    case pass
    case fail
    case pending
}

private func normalizedSidebarBranchName(_ branch: String?) -> String? {
    guard let branch else { return nil }
    let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

struct SidebarPullRequestState: Equatable {
    let number: Int
    let label: String
    let url: URL
    let status: SidebarPullRequestStatus
    let branch: String?
    let checks: SidebarPullRequestChecksStatus?

    init(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) {
        self.number = number
        self.label = label
        self.url = url
        self.status = status
        self.branch = normalizedSidebarBranchName(branch)
        self.checks = checks
    }
}

enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    // (C11-106) `struct BranchDirectoryEntry` and
    // `static func orderedUniqueBranchDirectoryEntries(...)` were
    // retired alongside `sidebarBranchDirectoryEntriesInDisplayOrder`
    // — they fed the legacy AC24-retired text branch+directory row.
    // The worktree+branch chips that replaced that row consume
    // `WorktreeChipRow` directly via `WorktreeChipProjector`. Grep
    // confirms no other consumer; both `c11-logic` and `c11-unit`
    // compile after removal.

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniquePullRequests(
        orderedPanelIds: [UUID],
        tabPullRequests: [UUID: SidebarPullRequestState],
        fallbackPullRequest: SidebarPullRequestState?
    ) -> [SidebarPullRequestState] {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .merged: return 3
            case .open: return 2
            case .closed: return 1
            }
        }

        func checksPriority(_ checks: SidebarPullRequestChecksStatus?) -> Int {
            switch checks {
            case .fail: return 3
            case .pending: return 2
            case .pass: return 1
            case nil: return 0
            }
        }

        func normalizedReviewURLKey(for url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }

            // Treat URL variants that differ only by query/fragment as the same review item.
            components.query = nil
            components.fragment = nil
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            var path = components.path
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            return "\(scheme)://\(host)\(port)\(path)"
        }

        func reviewKey(for state: SidebarPullRequestState) -> String {
            "\(state.label.lowercased())#\(state.number)|\(normalizedReviewURLKey(for: state.url))"
        }

        var orderedKeys: [String] = []
        var pullRequestsByKey: [String: SidebarPullRequestState] = [:]

        for panelId in orderedPanelIds {
            guard let state = tabPullRequests[panelId] else { continue }
            let key = reviewKey(for: state)
            if pullRequestsByKey[key] == nil {
                orderedKeys.append(key)
                pullRequestsByKey[key] = state
                continue
            }
            guard let existing = pullRequestsByKey[key] else { continue }
            if statusPriority(state.status) > statusPriority(existing.status) {
                pullRequestsByKey[key] = state
            } else if state.status == existing.status,
                      checksPriority(state.checks) > checksPriority(existing.checks) {
                pullRequestsByKey[key] = state
            }
        }

        if orderedKeys.isEmpty, let fallbackPullRequest {
            return [fallbackPullRequest]
        }

        return orderedKeys.compactMap { pullRequestsByKey[$0] }
    }
}

struct ClosedBrowserTabRestoreSnapshot {
    let workspaceId: UUID
    let url: URL?
    let profileID: UUID?
    let originalPaneId: UUID
    let originalTabIndex: Int
    let fallbackSplitOrientation: SplitOrientation?
    let fallbackSplitInsertFirst: Bool
    let fallbackAnchorPaneId: UUID?
}

/// C11-134: per-type surface counts carried by `surface.shape` breadcrumbs.
struct TabShapeCounts: Equatable {
    var terminals = 0
    var browsers = 0
    var markdown = 0
}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var groupId: UUID? = nil
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    @Published var currentDirectory: String
    /// Stable project-level cwd. Every new terminal surface in the workspace
    /// starts here (see `newSurfaceWorkingDirectory`). Unlike
    /// `currentDirectory`, this does not follow shell navigation.
    @Published private(set) var rootDirectory: String?
    /// C11-238: armed while the workspace has no root, so the first cwd its
    /// focused shell reports (other than home or `/`) becomes the root. Any
    /// root assignment or clear disarms it, so auto-adoption never overrides
    /// the operator.
    private(set) var rootAdoptionArmed: Bool = false

    /// Publishes the new `customColor` value whenever it changes via `setCustomColor`.
    /// Used by `WorkspaceContentView` to re-apply bonsplit chrome (divider color, frame
    /// tint) without waiting for a full SwiftUI render pass. The plumbed `applyGhosttyChrome`
    /// already runs a no-op guard, so rapid changes are safe.
    let customColorDidChange = PassthroughSubject<String?, Never>()

    /// KVO observer on `UserDefaults.standard.chromeScalePreset`. Keeps the
    /// Bonsplit configuration in sync with the persisted App Chrome UI Scale
    /// preset for any writer (Settings UI, `defaults write`, future migrations).
    /// Workspace itself is `@MainActor final class : ObservableObject`, not an
    /// NSObject subclass, so KVO has to live on this composed helper. (C11-6)
    private var chromeScaleObserver: ChromeScaleObserver?

    /// Keeps the Bonsplit Browser / Markdown spawn buttons in sync with the
    /// persisted surface-availability toggles for any writer (Settings UI,
    /// `defaults write`). Same composed-NSObject KVO pattern as
    /// `chromeScaleObserver`.
    private var tabAvailabilityObserver: TabAvailabilityObserver?

    /// Keeps the Bonsplit "N: " tab-ordinal prefix in sync with the persisted
    /// "Show surface IDs in tab titles" toggle for any writer (Settings UI,
    /// `defaults write`). Same composed-NSObject KVO pattern as
    /// `chromeScaleObserver`.
    private var tabOrdinalDisplayObserver: TabOrdinalDisplayObserver?
    private var tabLayoutObserver: TabLayoutObserver?

    /// Operator-authored workspace metadata (e.g. "description", "icon").
    /// Workspace-scoped; not to be confused with surface-scoped
    /// `SurfaceMetadataStore`. Persisted across restart via
    /// `SessionWorkspaceSnapshot.metadata`.
    @Published var metadata: [String: String] = [:]
    private(set) var preferredBrowserProfileID: UUID?

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any TabContent] = [:] {
        didSet {
            for tabID in panels.keys where oldValue[tabID] == nil {
                JournalCoordinator.shared.register(tabID: tabID, workspaceID: id)
            }
            for tabID in oldValue.keys where panels[tabID] == nil {
                // A tab move may already have installed its new workspace target.
                if JournalCoordinator.shared.target(tabID: tabID) == id { JournalCoordinator.shared.remove(tabID: tabID) }
                journalByTab.removeValue(forKey: tabID)
            }
        }
    }
    private(set) var journalByTab: [UUID: JournalSnapshot] = [:]

    func setJournalSnapshot(_ value: JournalSnapshot?, forTab tabID: UUID) {
        guard panels[tabID] != nil else { return }
        journalByTab[tabID] = value
        syncSurfaceTabActivityStateForTab(tabID)
        objectWillChange.send()
    }

    /// C11-163 events stream: single create/close chokepoint. Subscribing to
    /// `$panels` and diffing keys catches every surface lifecycle transition
    /// through one path — split, tab, restore, reattach, rollback, bulk
    /// teardown, detach — so no emit site can be missed (amendments C, D). A
    /// `@Published` property can't carry a `didSet` observer, hence the Combine
    /// subscription. `lastKnownPanelIds` is the diff baseline.
    private var panelEventsCancellable: AnyCancellable?
    private var lastKnownTabIds: Set<UUID> = []

    /// Monotonically incrementing token used by the sidebar workspace row to
    /// observe focus flashes targeting any panel in this workspace. Bumped
    /// from `triggerFocusFlash(panelId:)` so a single fan-out drives the
    /// pane content flash, the Bonsplit tab strip flash, and the sidebar
    /// row pulse together. Visual-only; never affects selection.
    @Published private(set) var sidebarFlashToken: Int = 0

    /// CMUX-10: hex color (sRGB w/ alpha) used by the sidebar workspace row
    /// pulse. Set in `runFlashPulse` from the per-call `FlashAppearance` so
    /// `c11 trigger-flash --color "#FF00FF"` tints the sidebar pulse, not
    /// just the terminal pane ring. Stored as a hex string so it can fold
    /// cleanly into `TabItemView.==` without touching `NSColor` reference
    /// equality. nil → fall back to the default sidebar-fill color.
    @Published private(set) var sidebarFlashColorHex: String?

    /// CMUX-10: state for in-flight persistent flashes (one entry per panel).
    /// The Timer is process-local; the manifest is not abused for per-frame
    /// state (per Plan note: write `flash_state=persistent` once on start,
    /// clear once on cancel). Operator/agent visibility comes from the
    /// metadata key, not from persistent timers.
    struct PersistentFlashState {
        let appearance: FlashAppearance
        let timer: Timer
        let startedAt: Date
        var lastBreadcrumbAt: Date?
    }

    @Published private(set) var persistentFlashTabs: [UUID: PersistentFlashState] = [:]

    /// C11-25: workspace-level operator hibernate flag. True when the
    /// operator has explicitly hibernated this workspace via the
    /// "Hibernate Workspace" context menu (or socket equivalent). Survives
    /// `c11 snapshot` / `restore` via the canonical `lifecycle_state`
    /// metadata mirror on each panel — the workspace flag is rebuilt on
    /// restore from "any panel hibernated".
    @Published var isHibernated: Bool = false

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var tabSubscriptions: [UUID: AnyCancellable] = [:]

    /// C11-13 Stage 2: per-workspace mailbox dispatcher. Lazily started by
    /// `startMailboxDispatcher()` (TabManager calls this after wiring a new
    /// workspace into the tab strip); stopped on deinit.
    private var mailboxDispatcher: MailboxDispatcher?

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    private var isProgrammaticSplit = false
    private var debugStressPreloadSelectionDepth = 0

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    private var lastTerminalConfigInheritanceTabId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    private var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    private var terminalInheritanceFontPointsByTabId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    var onClosedBrowserTab: ((ClosedBrowserTabRestoreSnapshot) -> Void)?
    weak var owningWorkspaceManager: WorkspaceManager?

    /// Workspace-scoped presenter for pane-anchored interactions (close-confirm,
    /// rename, custom-color, socket-triggered agent consent). Per-panel FIFO
    /// queue + soft cap lives inside the runtime. Views observe `.active`.
    let paneInteractionRuntime = AreaInteractionRuntime()

    /// Pane-scoped (rather than panel-scoped) presenter. Shares the same runtime
    /// implementation, but its overlays mount over the entire pane — tab strip
    /// included — so a pane-close confirmation visibly spans every tab it's
    /// about to remove. Keyed by `PaneID.id` (the runtime's `panelId` argument
    /// is just an opaque UUID; using a separate instance keeps panel teardown
    /// from clearing pane-scoped state and vice versa).
    let areaCloseInteractionRuntime = AreaInteractionRuntime()

    /// Mounts pane-scoped overlays as AppKit subviews of the workspace window's
    /// themeFrame so they render above the `WindowTerminalPortal` host (and
    /// thus above terminal/browser portal content). Driven by anchor frames
    /// pushed in from `PaneInteractionOverlayHostView` per pane.
    lazy var areaCloseOverlayController = AreaCloseOverlayController(
        runtime: areaCloseInteractionRuntime
    )

    /// Workspace-scoped close-confirmation runtime. Distinct keyspace from
    /// `paneInteractionRuntime` (panel-keyed) and `paneCloseInteractionRuntime`
    /// (pane-keyed) so the workspace overlay's lifecycle never collides with
    /// pane-scoped interactions. Only `.confirm` is supported here.
    let workspaceCloseInteractionRuntime = WorkspaceCloseInteractionRuntime()

    /// Mounts the workspace-scoped close-confirmation overlay (a near-black
    /// scrim covering the workspace content area only) as an AppKit subview
    /// of the window's themeFrame, above all portal-hosted content. Anchor
    /// frame pushed in from `WorkspaceCloseOverlayHostView` rendered inside
    /// `WorkspaceContentView` so the cover excludes the sidebar by
    /// construction.
    lazy var workspaceCloseOverlayController = WorkspaceCloseOverlayController(
        runtime: workspaceCloseInteractionRuntime
    )


    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let bonsplitTab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return tabIdFromBonsplitTabId(bonsplitTab.id)
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalTab: TerminalTab? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalTab else {
            return nil
        }
        return panel
    }

    func effectiveSelectedTabId(inPane paneId: PaneID) -> UUID? {
        bonsplitController.selectedTab(inPane: paneId).flatMap { tabIdFromBonsplitTabId($0.id) }
    }

    enum FocusTabTrigger {
        case standard
        case terminalFirstResponder
    }

    /// Published directory for each panel
    @Published var tabDirectories: [UUID: String] = [:]
    @Published var tabTitles: [UUID: String] = [:]
    @Published private(set) var tabCustomTitles: [UUID: String] = [:]
    /// Per-surface custom color, normalized as `#RRGGBB`. Identity marker for
    /// individual pane tabs; distinct from workspace-level `customColor` which
    /// drives sidebar/theme chrome. See ticket C11-10.
    @Published private(set) var tabCustomColors: [UUID: String] = [:]
    /// M7 per-surface title-bar collapse state (in-memory, session-scoped).
    @Published var titleBarCollapsed: [UUID: Bool] = [:]
    /// M7 per-surface flag: user explicitly collapsed this surface (suppresses auto-expand).
    @Published var titleBarUserCollapsed: Set<UUID> = []
    /// M7 workspace-scoped visibility for surface title bars (default: visible).
    @Published var titleBarVisible: Bool = true
    @Published private(set) var pinnedTabIds: Set<UUID> = []
    @Published private(set) var manualUnreadTabIds: Set<UUID> = []
    private var manualUnreadMarkedAt: [UUID: Date] = [:]
    /// When each surface entered the state its tab sheet row shows (working,
    /// waiting, flagged, idle, cold). Written at the transitions the workspace
    /// already sees; not published, nothing renders from it directly.
    var tabSheetStatusEntered: [UUID: TabSheetStatusEntry] = [:]
    nonisolated private static let manualUnreadFocusGraceInterval: TimeInterval = 0.2
    nonisolated private static let manualUnreadClearDelayAfterFocusFlash: TimeInterval = 0.2
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var metadataBlocks: [String: SidebarMetadataBlock] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    /// TEL-4: per-surface derived-liveness state, the @Published bridge the
    /// sidebar observes. Written by `setDerivedActivity` (which
    /// `SurfaceLivenessDeriver` calls from the derived-liveness backend) and
    /// pruned alongside the other per-surface metadata. Absence of a key means
    /// "no derived signal yet."
    @Published var derivedActivityByTab: [UUID: SidebarActivityState] = [:]
    /// Main-actor render cache for canonical attention metadata. The metadata
    /// store remains authoritative; views consume this immutable projection.
    @Published private(set) var attentionByTab: [UUID: TabAttentionSnapshot] = [:]
    /// Live-agent dormancy is a reversible presentation projection, kept
    /// separate from the durable working/idle metadata truth.
    @Published private(set) var coldAgentSurfaceIds: Set<UUID> = []
    /// Foreground-process classifications from `AgentDetector`. Durable
    /// `terminal_type` metadata describes resumable identity; this live map
    /// decides whether that identity is currently an agent or a plain shell.
    @Published private(set) var detectedTerminalTypesByTab: [UUID: String] = [:]
    @Published var gitBranch: SidebarGitBranchState?
    @Published var tabGitBranches: [UUID: SidebarGitBranchState] = [:]
    /// C11-104 — per-panel resolved worktree+branch context for the
    /// sidebar chips. Written by `TabManager.applyWorkspaceGitMetadataSnapshot`
    /// from the off-main probe. Nil signals "not a git directory."
    @Published var tabGitContexts: [UUID: ResolvedGitContext?] = [:]
    @Published var pullRequest: SidebarPullRequestState?
    @Published var tabPullRequests: [UUID: SidebarPullRequestState] = [:]
    @Published var tabListeningPorts: [UUID: [Int]] = [:]
    @Published var remoteConfiguration: WorkspaceRemoteConfiguration?
    @Published var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected
    @Published var remoteConnectionDetail: String?
    @Published var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
    @Published var remoteDetectedPorts: [Int] = []
    @Published var remoteForwardedPorts: [Int] = []
    @Published var remotePortConflicts: [Int] = []
    @Published var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published var remoteHeartbeatCount: Int = 0
    @Published var remoteLastHeartbeatAt: Date?
    @Published var listeningPorts: [Int] = []
    @Published private(set) var activeRemoteTerminalSessionCount: Int = 0
    var tabTTYNames: [UUID: String] = [:]
    private var remoteSessionController: WorkspaceRemoteSessionController?
    fileprivate var activeRemoteSessionControllerID: UUID?
    private var remoteLastErrorFingerprint: String?
    private var remoteLastDaemonErrorFingerprint: String?
    private var remoteLastPortConflictFingerprint: String?
    private var activeRemoteTerminalSurfaceIds: Set<UUID> = []

    private static let remoteErrorStatusKey = "remote.error"
    private static let remotePortConflictStatusKey = "remote.port_conflicts"
    private static let remoteHeartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var tabShellActivityStates: [UUID: TabShellActivityState] = [:]
    /// When each panel's shell last started or finished a command (tab sheet
    /// `active` for plain terminals). Plain store, not published.
    var tabShellEdgeAt: [UUID: Date] = [:]
    /// Per-tab queue of framed `<c11-msg>` blocks that arrived while the
    /// recipient was busy, plus the agent turn edges that gate them. Flushed
    /// at an agent's prompt edge or a shell's return to `.promptIdle` (see
    /// `flushBufferedMailboxStdin`). Main-actor-confined.
    private var mailboxStdinBuffer = MailboxStdinBuffer()
    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    var agentPIDs: [String: pid_t] = [:]
    /// Runtime-only attribution for the currently registered PID. Unknown
    /// attribution must never clear a sibling tab's attention.
    private var agentPIDTabs: [String: (pid: pid_t, tabId: UUID)] = [:]

    func registerAgentPID(_ pid: pid_t, key: String, tabId: UUID?) {
        agentPIDs[key] = pid
        if let tabId, panels[tabId] != nil {
            agentPIDTabs[key] = (pid, tabId)
        } else {
            agentPIDTabs.removeValue(forKey: key)
        }
    }

    @discardableResult
    func removeAgentPID(key: String) -> UUID? {
        let pid = agentPIDs.removeValue(forKey: key)
        let association = agentPIDTabs.removeValue(forKey: key)
        guard let association, association.pid == pid else { return nil }
        return association.tabId
    }

    func clearAgentPIDs() {
        agentPIDs.removeAll()
        agentPIDTabs.removeAll()
    }
    private var restoredTerminalScrollbackByTabId: [UUID: String] = [:]

    private static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    private var preservesSSHTerminalConnection: Bool {
        activeRemoteTerminalSessionCount > 0
            && remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasProxyOnlyRemoteSidebarError: Bool {
        guard let entry = statusEntries[Self.remoteErrorStatusKey]?.value else { return false }
        return entry.lowercased().contains("remote proxy unavailable")
    }

    var focusedSurfaceId: UUID? { focusedPanelId }
    private var processTitle: String
    private var stableDefaultTitle: String?

    private enum TabKind {
        static let terminal = "terminal"
        static let browser = "browser"
        static let markdown = "markdown"
    }

    enum TabShellActivityState: String {
        case unknown
        case promptIdle
        case commandRunning
    }

    nonisolated static func resolveCloseConfirmation(
        shellActivityState: TabShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }

    // MARK: - Initialization

    private static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            // §5.3 v1: the A-button tooltip carries the resolved default config's
            // name · model · effort (C11-179), read from the saved-config library
            // and resolved through the overlay for the display axes.
            newAgent: DefaultAgentResolver.resolvedDefaultTooltip(
                userDefault: DefaultAgentConfigStore.shared.current
            ),
            chooseAgent: String(localized: "workspace.tooltip.chooseAgent", defaultValue: "Choose Agent to Launch…"),
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip(
                String(localized: "workspace.tooltip.newTerminal", defaultValue: "New Terminal")
            ),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip(
                String(localized: "workspace.tooltip.newBrowser", defaultValue: "New Browser")
            ),
            newMarkdown: String(localized: "workspace.tooltip.newMarkdown", defaultValue: "New Markdown"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip(
                String(localized: "workspace.tooltip.splitRight", defaultValue: "Split Right")
            ),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip(
                String(localized: "workspace.tooltip.splitDown", defaultValue: "Split Down")
            ),
            newTab: String(localized: "workspace.tooltip.newTab", defaultValue: "New Tab"),
            closePane: String(localized: "workspace.tooltip.closePane", defaultValue: "Close Area")
        )
    }

    private static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            context: nil,
            tokens: ChromeScaleTokens.resolved(from: .standard)
        )
    }

    static func bonsplitChromeHex(backgroundColor: NSColor, backgroundOpacity: Double) -> String {
        let themedColor = GhosttyBackgroundTheme.color(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    /// Agent-state palette shared by sidebar workspace pulse marks, the card
    /// agent rollup bar, and bonsplit surface-tab activity chips.
    ///
    /// running/idle/cold are a neutral white-to-gray ramp (running most present,
    /// cold most receded) so `waiting` gold stays the only chromatic mark in the
    /// chrome: the brand's deliberate "needs you" signal.
    nonisolated static func resolvedSurfaceTabActivityColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.TabActivityColors {
        if backgroundColor.isLightColor {
            return .init(
                runningHex: "#1D2024",
                idleHex: "#585D66",
                coldHex: "#8D939C",
                waitingHex: "#9B7415",
                waitingInkHex: "#FFFDF8"
            )
        }
        return .init(
            runningHex: "#E8E8E8",
            idleHex: "#9AA0A9",
            coldHex: "#62676F",
            waitingHex: "#D0AA45",
            waitingInkHex: "#08090B"
        )
    }

    /// Resolved theme-aware divider presentation for bonsplit. `borderHex` encodes
    /// RGBA so the alpha from `$workspaceColor.mix(...)` survives into bonsplit.
    private struct BonsplitDividerResolution {
        var borderHex: String?
        var thicknessPt: CGFloat?
    }

    private static func resolvedDividerPresentation(
        context: ThemeContext?
    ) -> BonsplitDividerResolution {
        guard let context else { return BonsplitDividerResolution() }
        let manager = ThemeManager.shared
        guard manager.isEnabled else { return BonsplitDividerResolution() }

        let color: NSColor? = manager.resolve(.dividers_color, context: context)
        let thickness: CGFloat? = manager.resolve(.dividers_thicknessPt, context: context)

        return BonsplitDividerResolution(
            borderHex: color?.hexString(includeAlpha: (color?.alphaComponent ?? 1.0) < 0.999),
            thicknessPt: thickness
        )
    }

    private static func resolvedActiveIndicatorHex(context: ThemeContext?) -> String? {
        guard let context else { return nil }
        let manager = ThemeManager.shared
        guard manager.isEnabled else { return nil }
        guard let color: NSColor = manager.resolve(.tabBar_activeIndicator, context: context) else {
            return nil
        }
        return color.hexString(includeAlpha: color.alphaComponent < 0.999)
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double,
        context: ThemeContext?,
        tokens: ChromeScaleTokens = .standard
    ) -> BonsplitConfiguration.Appearance {
        let divider = resolvedDividerPresentation(context: context)
        let activeIndicatorHex = resolvedActiveIndicatorHex(context: context)
        var appearance = BonsplitConfiguration.Appearance(
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: Self.bonsplitChromeHex(
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                ),
                borderHex: divider.borderHex,
                activeIndicatorHex: activeIndicatorHex
            ),
            tabActivityColors: Self.resolvedSurfaceTabActivityColors(from: backgroundColor),
            dividerStyle: .init(thicknessPt: divider.thicknessPt)
        )
        Self.applyChromeScale(tokens, to: &appearance)
        return appearance
    }

    /// Pure helper. No `GhosttyApp.shared`, no `UserDefaults`, no
    /// `NotificationCenter` — just in/out value-type mutation. Both the static
    /// factory and the live-update path call this so behavior is identical and
    /// testable in isolation. (C11-6)
    ///
    /// `nonisolated` because the function touches no main-actor state — pure
    /// value-type mutation — so the actor inheritance from `Workspace` is
    /// incidental, not load-bearing. Without this, `WorkspaceApplyChromeScaleTests`
    /// fails to compile under Swift 6 strict concurrency: XCTestCase methods
    /// are non-main-actor by default, and calling a `@MainActor`-isolated
    /// static method from a synchronous context is a compile error.
    nonisolated static func applyChromeScale(
        _ tokens: ChromeScaleTokens,
        to appearance: inout BonsplitConfiguration.Appearance
    ) {
        appearance.tabBarHeight              = tokens.surfaceTabBarHeight
        appearance.tabTitleFontSize          = tokens.surfaceTabTitle
        appearance.tabMinWidth               = tokens.surfaceTabMinWidth
        appearance.tabMaxWidth               = tokens.surfaceTabMaxWidth
        appearance.tabIconSize               = tokens.surfaceTabIcon
        appearance.tabItemHeight             = tokens.surfaceTabItemHeight
        appearance.tabHorizontalPadding      = tokens.surfaceTabHorizontalPadding
        appearance.tabCloseIconSize          = tokens.surfaceTabCloseIconSize
        appearance.tabContentSpacing         = tokens.surfaceTabContentSpacing
        appearance.tabDirtyIndicatorSize     = tokens.surfaceTabDirtyIndicatorSize
        appearance.tabNotificationBadgeSize  = tokens.surfaceTabNotificationBadgeSize
        appearance.tabActiveIndicatorHeight  = tokens.surfaceTabActiveIndicatorHeight
        appearance.splitToolbarButtonIconSize  = tokens.splitToolbarButtonIcon
        appearance.splitToolbarButtonFrameSize = tokens.splitToolbarButtonFrame
        appearance.splitToolbarSeparatorHeight = tokens.splitToolbarSeparatorHeight
    }

    /// Live-update path for chrome-scale changes. Mirrors `applyGhosttyChrome`'s
    /// shape: pull current appearance, mutate via the pure helper, no-op guard
    /// across every routed knob, then assign back. Called by the KVO observer
    /// on `UserDefaults.standard.chromeScalePreset`. (C11-6)
    func applyChromeScale(reason: String = "unspecified") {
        let tokens = ChromeScaleTokens.resolved(from: .standard)
        var next = bonsplitController.configuration.appearance
        Workspace.applyChromeScale(tokens, to: &next)
        let current = bonsplitController.configuration.appearance
        let unchanged =
            current.tabBarHeight              == next.tabBarHeight &&
            current.tabTitleFontSize          == next.tabTitleFontSize &&
            current.tabMinWidth               == next.tabMinWidth &&
            current.tabMaxWidth               == next.tabMaxWidth &&
            current.tabIconSize               == next.tabIconSize &&
            current.tabItemHeight             == next.tabItemHeight &&
            current.tabHorizontalPadding      == next.tabHorizontalPadding &&
            current.tabCloseIconSize          == next.tabCloseIconSize &&
            current.tabContentSpacing         == next.tabContentSpacing &&
            current.tabDirtyIndicatorSize     == next.tabDirtyIndicatorSize &&
            current.tabNotificationBadgeSize  == next.tabNotificationBadgeSize &&
            current.tabActiveIndicatorHeight  == next.tabActiveIndicatorHeight &&
            current.splitToolbarButtonIconSize  == next.splitToolbarButtonIconSize &&
            current.splitToolbarButtonFrameSize == next.splitToolbarButtonFrameSize &&
            current.splitToolbarSeparatorHeight == next.splitToolbarSeparatorHeight
        guard !unchanged else { return }
        var nextConfiguration = bonsplitController.configuration
        nextConfiguration.appearance = next
        bonsplitController.configuration = nextConfiguration
    }

    /// Live-update path for the surface-availability toggles. Pulls the current
    /// Bonsplit configuration, recomputes the Browser / Markdown spawn-button
    /// visibility from `SurfaceTypeAvailability`, and reassigns only on a real
    /// change so redundant toggles don't churn the configuration. Existing
    /// surfaces are untouched — this only governs the spawn affordances.
    func applySurfaceAvailability() {
        let browserOn = TabTypeAvailability.isEnabled(.browser)
        let markdownOn = TabTypeAvailability.isMarkdownSpawnButtonVisible()
        var next = bonsplitController.configuration
        guard next.showsBrowserSpawnButton != browserOn
            || next.showsMarkdownSpawnButton != markdownOn else { return }
        next.showsBrowserSpawnButton = browserOn
        next.showsMarkdownSpawnButton = markdownOn
        bonsplitController.configuration = next
    }

    /// Live-update path for the "Show surface IDs in tab titles" toggle.
    /// Flips `Appearance.showTabOrdinals`; tabs already carry their
    /// `displayOrdinal`, so the prefix appears/disappears in a single
    /// configuration reassignment with no title re-push.
    func applyTabOrdinalDisplay() {
        let showIds = TabOrdinalDisplaySettings.showsSurfaceIds()
        var next = bonsplitController.configuration
        guard next.appearance.showTabOrdinals != showIds else { return }
        next.appearance.showTabOrdinals = showIds
        bonsplitController.configuration = next
    }

    /// Live-update path for the Tab layout setting (Tabs | Rail).
    func applyTabLayout() {
        let layout = TabLayoutSettings.bonsplitLayout(TabLayoutSettings.mode())
        var next = bonsplitController.configuration
        guard next.appearance.tabLayout != layout else { return }
        next.appearance.tabLayout = layout
        bonsplitController.configuration = next
        TabRailTipCenter.shared.scheduleRefresh()
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        applyGhosttyChrome(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            reason: reason
        )
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        var nextHex = Self.bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        let useThemeM1bPath = ThemeAppStorage.bool(
            forKey: ThemeAppStorage.Keys.m1bBonsplitAppearanceMigrated,
            default: false
        )

        // Theme-resolved divider presentation threads through the M2a bonsplit
        // `DividerStyle` seam. Resolution uses the workspace's current `customColor`
        // so `$workspaceColor.mix($background, 0.65)` picks up the live tint.
        var nextBorderHex: String? = nil
        var nextThicknessPt: CGFloat? = nil
        var nextActiveIndicatorHex: String? = nil
        if ThemeManager.shared.isEnabled {
            let context = ThemeManager.shared.makeContext(
                workspaceColor: customColor,
                colorScheme: ThemeManager.currentColorScheme()
            )
            if useThemeM1bPath,
               let themed: NSColor = ThemeManager.shared.resolve(.tabBar_background, context: context) {
                nextHex = themed.hexString(includeAlpha: themed.alphaComponent < 0.999)
            }
            if let dividerColor: NSColor = ThemeManager.shared.resolve(.dividers_color, context: context) {
                nextBorderHex = dividerColor.hexString(includeAlpha: dividerColor.alphaComponent < 0.999)
            }
            nextThicknessPt = ThemeManager.shared.resolve(.dividers_thicknessPt, context: context)
            if let activeIndicatorColor: NSColor = ThemeManager.shared.resolve(.tabBar_activeIndicator, context: context) {
                nextActiveIndicatorHex = activeIndicatorColor.hexString(includeAlpha: activeIndicatorColor.alphaComponent < 0.999)
            }
        }

        let currentAppearance = bonsplitController.configuration.appearance
        let currentChromeColors = currentAppearance.chromeColors
        let currentActivityColors = currentAppearance.tabActivityColors
        let nextActivityColors = Self.resolvedSurfaceTabActivityColors(
            from: NSColor(hex: nextHex) ?? backgroundColor
        )
        let currentThickness = currentAppearance.dividerStyle.thicknessPt

        // No-op guard spans background, divider color, divider thickness, and
        // active tab indicator so
        // rapid `customColorDidChange` / `ghosttyDefaultBackgroundDidChange` fires don't cause
        // redundant chrome mutations. Each axis is compared independently — any drift on any
        // axis triggers the update.
        let backgroundMatches = currentChromeColors.backgroundHex == nextHex
        let borderMatches = currentChromeColors.borderHex == nextBorderHex
        let thicknessMatches = currentThickness == nextThicknessPt
        let activeIndicatorMatches = currentChromeColors.activeIndicatorHex == nextActiveIndicatorHex
        let activityColorsMatch =
            currentActivityColors.runningHex == nextActivityColors.runningHex &&
            currentActivityColors.idleHex == nextActivityColors.idleHex &&
            currentActivityColors.coldHex == nextActivityColors.coldHex &&
            currentActivityColors.waitingHex == nextActivityColors.waitingHex &&
            currentActivityColors.waitingInkHex == nextActivityColors.waitingInkHex
        let isNoOp = backgroundMatches && borderMatches && thicknessMatches && activeIndicatorMatches && activityColorsMatch

        if GhosttyApp.shared.backgroundLogEnabled {
            let currentBackgroundHex = currentChromeColors.backgroundHex ?? "nil"
            let currentBorderHex = currentChromeColors.borderHex ?? "nil"
            let currentActiveIndicatorHex = currentChromeColors.activeIndicatorHex ?? "nil"
            let currentThicknessLog = currentThickness.map { String(format: "%.2f", $0) } ?? "nil"
            let nextThicknessLog = nextThicknessPt.map { String(format: "%.2f", $0) } ?? "nil"
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) m1b=\(useThemeM1bPath) customColor=\(customColor ?? "nil") currentBg=\(currentBackgroundHex) nextBg=\(nextHex) currentBorder=\(currentBorderHex) nextBorder=\(nextBorderHex ?? "nil") currentActiveIndicator=\(currentActiveIndicatorHex) nextActiveIndicator=\(nextActiveIndicatorHex ?? "nil") currentThickness=\(currentThicknessLog) nextThickness=\(nextThicknessLog) noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }

        var nextAppearance = currentAppearance
        nextAppearance.chromeColors.backgroundHex = nextHex
        nextAppearance.chromeColors.borderHex = nextBorderHex
        nextAppearance.chromeColors.activeIndicatorHex = nextActiveIndicatorHex
        nextAppearance.tabActivityColors = nextActivityColors
        nextAppearance.dividerStyle.thicknessPt = nextThicknessPt

        var nextConfiguration = bonsplitController.configuration
        nextConfiguration.appearance = nextAppearance
        bonsplitController.configuration = nextConfiguration

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil") resultingBorder=\(bonsplitController.configuration.appearance.chromeColors.borderHex ?? "nil") resultingActiveIndicator=\(bonsplitController.configuration.appearance.chromeColors.activeIndicatorHex ?? "nil") resultingThickness=\(bonsplitController.configuration.appearance.dividerStyle.thicknessPt.map { String(format: "%.2f", $0) } ?? "nil")"
            )
        }
    }

    init(
        id: UUID? = nil,
        title: String = "Terminal",
        stableDefaultTitle: String? = nil,
        workingDirectory: String? = nil,
        rootDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: ghostty_surface_config_s? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:]
    ) {
        // Tier 1 persistence, Phase 1.5: accept an optional restore-time id so
        // workspace UUIDs can survive across app restarts. Nil mints a fresh
        // UUID (the normal creation path); a supplied id is used as-is (the
        // restore path in `TabManager.restoreSessionSnapshot`).
        self.id = id ?? UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        let trimmedStableDefaultTitle = stableDefaultTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.stableDefaultTitle = trimmedStableDefaultTitle.isEmpty ? nil : trimmedStableDefaultTitle
        self.title = title
        self.customTitle = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        let normalizedRoot = Self.normalizedRootDirectory(rootDirectory)
        self.rootDirectory = normalizedRoot
        self.rootAdoptionArmed = normalizedRoot == nil

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Avoid re-reading/parsing Ghostty config on every new workspace; this hot path
        // runs for socket/CLI workspace creation and can cause visible typing lag.
        // At Workspace.init time the custom color is not yet set, so initial bonsplit
        // appearance uses the theme's default context (workspaceColor=nil). The first
        // `applyGhosttyChrome` call — triggered on workspace mount — re-applies with the
        // actual custom color once the Workspace is installed in the sidebar.
        var appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            context: nil,
            tokens: ChromeScaleTokens.resolved(from: .standard)
        )
        // C11-41: tab bar chrome state was removed; always show the full tab bar.
        appearance.showsTabBar = true
        appearance.showTabOrdinals = TabOrdinalDisplaySettings.showsSurfaceIds()
        appearance.tabLayout = TabLayoutSettings.bonsplitLayout(TabLayoutSettings.mode())
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            // Keep Bonsplit's X enabled even when this is the only pane —
            // the workspace handler intercepts the request and resets the
            // pane (close all tabs + open a fresh terminal) instead of
            // tearing the workspace down. Bonsplit refuses to actually
            // remove the last pane, which is the right contract.
            allowCloseLastPane: true,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            // C11-184: leading activity state, trailing always-visible close X,
            // and the two-item right-click menu (Close Tab, Close Pane).
            simplifiedTabContextMenu: true,
            // Hide the Browser / Markdown spawn buttons when the operator has
            // disabled those surface types. `applySurfaceAvailability()` keeps
            // these live as the toggles change.
            showsBrowserSpawnButton: TabTypeAvailability.isEnabled(.browser),
            showsMarkdownSpawnButton: TabTypeAvailability.isMarkdownSpawnButtonVisible(),
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()
        bonsplitController.tabColorPalette = Self.bonsplitTabColorPalette()

        // Subscribe to UserDefaults.standard.chromeScalePreset so chrome scale
        // changes from any writer (Settings UI, `defaults write`, future
        // migrations) propagate to this Workspace's Bonsplit configuration.
        // The observer is constructed AFTER bonsplitController so its callback
        // can safely read/write `bonsplitController.configuration`. (C11-6)
        self.chromeScaleObserver = ChromeScaleObserver { [weak self] in
            self?.applyChromeScale(reason: "userdefaults-change")
        }

        // Mirror the chrome-scale observer: react to surface-availability
        // toggles so the Browser / Markdown spawn buttons appear/disappear
        // live, without an app restart.
        self.tabAvailabilityObserver = TabAvailabilityObserver { [weak self] in
            self?.applySurfaceAvailability()
        }

        // React to the "Show surface IDs in tab titles" toggle live.
        self.tabOrdinalDisplayObserver = TabOrdinalDisplayObserver { [weak self] in
            self?.applyTabOrdinalDisplay()
        }

        // Remember a toggled rail: the fingerprint sees the new set, so the
        // autosave pass this asks for writes it.
        bonsplitController.onRailToggled = { _, _ in
            AppDelegate.shared?.requestSessionAutosave(source: "rail.toggle")
        }

        // React to the Tab layout setting (Tabs | Rail) live.
        self.tabLayoutObserver = TabLayoutObserver { [weak self] in
            self?.applyTabLayout()
        }

        // The rail tip reads overflow, the count-cell anchor, and the sheet.
        // Any area can record an overflow day; only the front one shows the tip.
        bonsplitController.onTabStripOverflow = { [weak self] paneId, overflowing in
            guard let self else { return }
            TabRailTipCenter.shared.noteOverflow(workspace: self, paneId: paneId, overflowing: overflowing)
        }
        bonsplitController.onCountCellAnchor = { [weak self] paneId, view in
            guard let self else { return }
            TabRailTipCenter.shared.noteAnchor(workspace: self, paneId: paneId, view: view)
        }
        bonsplitController.onTabSheetOpenChanged = { [weak self] paneId, open in
            guard let self else { return }
            TabRailTipCenter.shared.noteSheet(workspace: self, paneId: paneId, open: open)
        }

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeBonsplitTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalTab = TerminalTab(
            workspaceId: self.id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: configTemplate,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
            portOrdinal: portOrdinal,
            initialCommand: initialTerminalCommand,
            initialInput: initialTerminalInput,
            initialEnvironmentOverrides: initialTerminalEnvironment
        )
        panels[terminalTab.id] = terminalTab
        // Initialization bypasses panels.didSet. Register the first tab through
        // the same identity-only seam used by later inserts and restored tabs.
        JournalCoordinator.shared.register(tabID: terminalTab.id, workspaceID: self.id)
        tabTitles[terminalTab.id] = terminalTab.displayTitle
        seedTerminalInheritanceFontPoints(panelId: terminalTab.id, configTemplate: configTemplate)

        // Create initial tab in bonsplit and store the mapping
        var initialBonsplitTabId: TabID?
        if let bonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: title),
            icon: "terminal.fill",
            kind: TabKind.terminal,
            isDirty: false,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: terminalTab.id)
        ) {
            bonsplitTabIdToTabId[bonsplitTabId] = terminalTab.id
            initialBonsplitTabId = bonsplitTabId
        }

        // Close the default Welcome tab(s)
        for welcomeBonsplitTabId in welcomeBonsplitTabIds {
            bonsplitController.closeTab(welcomeBonsplitTabId)
        }

        bonsplitController.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }
        bonsplitController.onTabCloseRequest = { [weak self] bonsplitTabId, _ in
            self?.markExplicitClose(bonsplitTabId: bonsplitTabId)
        }
        bonsplitController.surfaceRefProvider = { [weak self] bonsplitTabId in
            guard let self, let panelId = self.tabIdFromBonsplitTabId(bonsplitTabId) else { return nil }
            return TerminalController.shared.surfaceRefOnly(forSurfaceUUID: panelId)
        }
        installTabSheetDetailProviders()

        // Set ourselves as delegate
        bonsplitController.delegate = self
        // The initial root area predates delegate installation. Later areas
        // are registered by didSplitPane, including session/blueprint restore.
        for paneId in bonsplitController.allPaneIds {
            _ = TerminalController.shared.v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
        }

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialBonsplitTabId {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialBonsplitTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialBonsplitTabId)
        }

        // C11-134: breadcrumb this workspace's surface shape (per-type panel
        // counts) whenever it changes, so Sentry hang reports can answer "how
        // many browser surfaces were open?". Counts only — never titles or
        // URLs. removeDuplicates keeps it to genuine state changes; debounce
        // coalesces bulk transitions like session restore.
        surfaceShapeBreadcrumbCancellable = $panels
            .map { panels -> TabShapeCounts in
                var counts = TabShapeCounts()
                for panel in panels.values {
                    switch panel.panelType {
                    case .terminal: counts.terminals += 1
                    case .browser: counts.browsers += 1
                    case .markdown: counts.markdown += 1
                    }
                }
                return counts
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] counts in
                guard let self else { return }
                sentryBreadcrumb("surface.shape", category: "shape", data: [
                    "workspace": String(self.id.uuidString.prefix(8)),
                    "terminals": counts.terminals,
                    "browsers": counts.browsers,
                    "markdown": counts.markdown,
                ])
            }

        // C11-163: emit surface.created / surface.closed by diffing $panels.
        // Subscribing fires once synchronously with the current set (the seed
        // terminal), then on every subsequent mutation — a single chokepoint
        // that no create/close/reattach/teardown path can bypass. No debounce:
        // events must be observable within 1s (EVT-6).
        panelEventsCancellable = $panels
            .sink { [weak self] newPanels in
                self?.reconcileTabEvents(newPanels)
            }
    }

    deinit {
        activeRemoteSessionControllerID = nil
        remoteSessionController?.stop()
        mailboxDispatcher?.stop()
        // CMUX-10: invalidate any in-flight persistent-flash timers so the
        // run loop drops its retain on them. Direct invalidate here rather
        // than `cancelAllPersistentFlashes()` — the panel/pane/teardown paths
        // already remove surface metadata, and routing through the metadata
        // store during deallocation is unnecessary noise. `Workspace` is
        // `@MainActor` so the last release must run on main; `assumeIsolated`
        // lets the iso-checker see that.
        MainActor.assumeIsolated {
            for state in persistentFlashTabs.values {
                state.timer.invalidate()
            }
            persistentFlashTabs.removeAll()
        }
    }

    /// C11-163: diff the panel set against the last-known ids and publish
    /// surface lifecycle events. Runs synchronously inside `$panels` delivery
    /// (main actor); `EventEmitter.emit` is fire-and-forget so this never
    /// blocks. A rolled-back create surfaces as a balanced created→closed pair;
    /// a cross-pane detach→reattach as closed→created (amendment D move policy).
    private func reconcileTabEvents(_ newTabs: [UUID: any TabContent]) {
        let newIds = Set(newTabs.keys)
        guard newIds != lastKnownTabIds else { return }
        for createdId in newIds.subtracting(lastKnownTabIds) {
            guard let panel = newTabs[createdId] else { continue }
            // This callback runs in @Published.willSet. Register the supplied
            // new tab directly; self.panels still contains the old collection.
            _ = TerminalController.shared.v2EnsureHandleRef(kind: .surface, uuid: createdId)
            EventEmitter.shared.emitSurfaceCreated(
                workspace: id,
                surface: createdId,
                kind: panel.panelType.rawValue,
                title: panel.displayTitle
            )
        }
        for closedId in lastKnownTabIds.subtracting(newIds) {
            EventEmitter.shared.emitSurfaceClosed(workspace: id, surface: closedId)
        }
        lastKnownTabIds = newIds
    }

    /// Creates a per-workspace mailbox dispatcher bound to this workspace's
    /// UUID and starts watching `$C11_STATE/workspaces/<id>/mailboxes/_outbox/`.
    /// Idempotent. A no-op `silent` handler is registered so topic-silent
    /// flows work before Step 10 lands the real stdin handler.
    ///
    /// The `stdin` handler writes via `TextBoxSubmit.send(_:via:)` rather
    /// than raw `sendText`. Ghostty wraps `sendText` bytes in bracketed-paste
    /// markers (`ESC[200~…ESC[201~`), and bracketed paste is specifically
    /// designed so embedded `\n`/`\r` do NOT auto-execute — line discipline
    /// (zsh ZLE, bash readline) and TUI raw-mode input handlers only submit
    /// when a real Return arrives outside the paste. So `sendText` alone
    /// leaves the framed `<c11-msg>` block sitting in the recipient's
    /// input buffer without ever reaching the agent. `TextBoxSubmit.send`
    /// bracketed-pastes the content and then dispatches a synthetic Return
    /// key (with the 200 ms gap Claude CLI's paste-processing requires),
    /// which submits the multi-line block as one user turn for TUI
    /// recipients (Claude Code, codex) and as a (failing) command for
    /// cooked-mode shells — the latter being undefined behavior anyway,
    /// since `mailbox.delivery=stdin` only makes sense on agent surfaces.
    func startMailboxDispatcher() {
        guard mailboxDispatcher == nil else { return }
        let stateURL: URL
        do {
            stateURL = try MailboxLayout.defaultStateURL()
        } catch {
            return
        }
        let resolver = MailboxTabResolver(workspaceId: self.id) { [weak self] in
            guard let self else { return [] }
            // `panels` is @Published. Read it from main to avoid the SwiftUI/Combine
            // non-main warning under Swift 5.10+; dispatch volume is low enough
            // that the bounded hop is invisible.
            if Thread.isMainThread {
                return Array(self.panels.keys)
            }
            var result: [UUID] = []
            DispatchQueue.main.sync { result = Array(self.panels.keys) }
            return result
        }
        let dispatcher = MailboxDispatcher(
            workspaceId: self.id,
            stateURL: stateURL,
            resolver: resolver
        )
        dispatcher.registerHandler(name: "silent") { _, _, _ in
            .init(outcome: .ok)
        }
        let stdinHandler = StdinMailboxHandler { [weak self] surfaceId, envelopeId, recipientName, text in
            guard let self else { return .surfaceNotFound }
            return self.deliverOrBufferMailboxStdin(
                surfaceId: surfaceId,
                envelopeId: envelopeId,
                recipientName: recipientName,
                block: text
            )
        }
        dispatcher.registerHandler(
            name: "stdin",
            stdinHandler.asDispatcherFunction()
        )
        dispatcher.start()
        mailboxDispatcher = dispatcher
    }

    /// Decide whether to push a framed `<c11-msg>` block into the recipient
    /// PTY now or buffer it (gate rules: `MailboxStdinBuffer`). Runs on the
    /// main actor (the handler's writer hop) and does no file I/O: a push
    /// claims its envelopes off-main (`startMailboxPush`). The dispatcher has
    /// already copied the envelope into the recipient's filesystem inbox, so
    /// a buffered (or even dropped) block is still reachable via
    /// `c11 mailbox recv --drain`.
    ///
    /// `.ok` means the push has started; if it cannot finish, a later
    /// `skipped`, `claim_failed` or `closed` line in the dispatch log says
    /// why, and `mailbox.delivered` `via: "push"` fires only once the submit
    /// Return is dispatched.
    func deliverOrBufferMailboxStdin(
        surfaceId: UUID,
        envelopeId: String,
        recipientName: String,
        block: String
    ) -> StdinMailboxHandler.WriteOutcome {
        guard let panel = panels[surfaceId] else { return .surfaceNotFound }
        guard let terminalTab = panel as? TerminalTab else { return .surfaceNotTerminal }

        let isAgentKind = AreaSizePolicy.isAgentKind(surfaceActivityTerminalKind(panelId: surfaceId))
        let entry = MailboxStdinBuffer.Entry(
            id: envelopeId,
            recipientName: recipientName,
            block: block,
            bufferedAt: Date()
        )
        var decision = mailboxStdinBuffer.decide(
            surfaceId: surfaceId,
            isAgentKind: isAgentKind,
            agentOwnsTerminal: mailboxAgentOwnsTerminal(surfaceId: surfaceId),
            lastOperatorKeyAt: terminalTab.surface.lastOperatorKeyAt
        )
        // Another writer is between its paste and its Return: wait.
        if terminalTab.surface.isInputTransactionActive { decision = .buffer }
        let immediate = decision == .injectNow
            && mailboxStdinBuffer.pendingCount(surfaceId: surfaceId) == 0
        if let evicted = mailboxStdinBuffer.enqueue(surfaceId: surfaceId, entry: entry) {
            mailboxDispatcher?.logStdinLifecycle(
                id: evicted.id,
                recipient: evicted.recipientName,
                outcome: .evicted
            )
        }
        if decision == .injectNow {
            startMailboxPush(
                surfaceId: surfaceId,
                trigger: .agentPrompt,
                immediateId: immediate ? envelopeId : nil
            )
        }
        return immediate ? .ok(bytes: block.utf8.count) : .buffered(bytes: block.utf8.count)
    }

    /// Flush buffered `<c11-msg>` blocks for a tab that just reached a safe
    /// moment: an agent's prompt edge or a shell's return to `.promptIdle`.
    private func flushBufferedMailboxStdin(
        surfaceId: UUID,
        trigger: MailboxStdinBuffer.FlushTrigger
    ) {
        startMailboxPush(surfaceId: surfaceId, trigger: trigger, immediateId: nil)
    }

    /// Serial queue for the push's inbox claims and claim rollbacks. Serial,
    /// so a rollback always lands before the next push's claim of the same
    /// envelope.
    private static let mailboxPushIOQueue = DispatchQueue(
        label: "com.stage11.c11.mailbox.push-io",
        qos: .utility
    )

    /// One push, in C3 order: (main) re-check the gate and take the queued
    /// entries → (off-main) claim each envelope from the inbox → (main) paste
    /// the claimed blocks as one paste and one submit → (after the Return is
    /// dispatched) emit `mailbox.delivered`; if it never is, undo the claims.
    /// Only one push per tab is in flight; anything arriving meanwhile
    /// buffers behind it.
    private func startMailboxPush(
        surfaceId: UUID,
        trigger: MailboxStdinBuffer.FlushTrigger,
        immediateId: String?
    ) {
        guard mailboxStdinBuffer.pendingCount(surfaceId: surfaceId) > 0,
              !mailboxStdinBuffer.isPushInFlight(surfaceId: surfaceId),
              let terminalTab = panels[surfaceId] as? TerminalTab else { return }
        if trigger == .agentPrompt {
            // Only while the tab's interactive agent owns its terminal, at
            // its prompt, with no draft (see `MailboxStdinBuffer.decide`).
            guard !terminalTab.surface.isInputTransactionActive,
                  mailboxStdinBuffer.decide(
                      surfaceId: surfaceId,
                      isAgentKind: true,
                      agentOwnsTerminal: mailboxAgentOwnsTerminal(surfaceId: surfaceId),
                      lastOperatorKeyAt: terminalTab.surface.lastOperatorKeyAt
                  ) == .injectNow else { return }
        }
        guard let dispatcher = mailboxDispatcher else { return }

        let flush = mailboxStdinBuffer.drainForFlush(surfaceId: surfaceId, now: Date(), trigger: trigger)
        for entry in flush.expired {
            dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .expired)
        }
        let entries = flush.fresh
        guard !entries.isEmpty else { return }

        mailboxStdinBuffer.beginPush(surfaceId: surfaceId)
        let admittedTurn = mailboxStdinBuffer.agentTurn(surfaceId: surfaceId)
        let admittedInputEpoch = terminalTab.surface.inputTransactionEpoch
        let inbox = MailboxLayout.inboxURL(state: dispatcher.stateURL, workspaceId: id, tabId: surfaceId)
        Self.mailboxPushIOQueue.async { [weak self] in
            var claimed: [MailboxStdinBuffer.Entry] = []
            for entry in entries {
                switch MailboxIO.claimResult(id: entry.id, inbox: inbox) {
                case .claimed:
                    claimed.append(entry)
                case .gone:
                    // A drain took it first: nothing to type for it.
                    dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .skipped)
                case .failed(let code):
                    // The envelope stays in the inbox root for the drain floor.
                    dispatcher.logStdinClaimFailed(id: entry.id, recipient: entry.recipientName, errno: code)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        Self.undoMailboxClaims(claimed, inbox: inbox)
                        return
                    }
                    self.finishMailboxPush(
                        surfaceId: surfaceId,
                        claimed: claimed,
                        trigger: trigger,
                        admittedTurn: admittedTurn,
                        admittedInputEpoch: admittedInputEpoch,
                        immediateId: immediateId,
                        inbox: inbox,
                        dispatcher: dispatcher
                    )
                }
            }
        }
    }

    private func finishMailboxPush(
        surfaceId: UUID,
        claimed: [MailboxStdinBuffer.Entry],
        trigger: MailboxStdinBuffer.FlushTrigger,
        admittedTurn: MailboxStdinBuffer.AgentTurn?,
        admittedInputEpoch: UInt64,
        immediateId: String?,
        inbox: URL,
        dispatcher: MailboxDispatcher
    ) {
        guard !claimed.isEmpty else {
            mailboxStdinBuffer.endPush(surfaceId: surfaceId, typedAt: nil)
            retryMailboxPush(surfaceId: surfaceId)
            return
        }
        guard let terminalTab = panels[surfaceId] as? TerminalTab else {
            // The tab closed during the claim: put the mail back for a drain.
            Self.undoMailboxClaims(claimed, inbox: inbox)
            for entry in claimed {
                dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .closed)
            }
            mailboxStdinBuffer.endPush(surfaceId: surfaceId, typedAt: nil)
            return
        }
        // Re-check on main for the same recipient kind the push was admitted
        // as: the agent can exit, start a turn, or the operator can start a
        // draft while the claims run.
        var verdict = mailboxPushVerdict(
            surfaceId: surfaceId,
            terminalTab: terminalTab,
            trigger: trigger,
            admittedTurn: admittedTurn
        )
        // Another writer started (or is still) writing since admission: its
        // text may be in the input line. Wait for the next edge.
        if verdict == .paste,
           terminalTab.surface.isInputTransactionActive
            || terminalTab.surface.inputTransactionEpoch != admittedInputEpoch {
            verdict = .requeue
        }
        switch verdict {
        case .drop:
            Self.undoMailboxClaims(claimed, inbox: inbox)
            for entry in claimed {
                dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .expired)
            }
            mailboxStdinBuffer.endPush(surfaceId: surfaceId, typedAt: nil)
            retryMailboxPush(surfaceId: surfaceId)
            return
        case .requeue:
            Self.undoMailboxClaims(claimed, inbox: inbox)
            let evicted = mailboxStdinBuffer.requeueFront(surfaceId: surfaceId, entries: claimed)
            for entry in claimed where !evicted.contains(entry) {
                dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .buffered)
            }
            for entry in evicted {
                dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .evicted)
            }
            mailboxStdinBuffer.endPush(surfaceId: surfaceId, typedAt: nil)
            retryMailboxPush(surfaceId: surfaceId)
            return
        case .paste:
            break
        }

        let pastedAt = Date()
        // The same paste + delayed Return `c11 send` uses; safe for a
        // background tab with no window. Reports whether the Return went out.
        // The full verdict runs again just before the Return: the agent may
        // have exited, lost the terminal, started a turn, or the operator may
        // have typed inside the paste-settle window. A bracketed paste alone
        // never executes, so withholding the Return keeps it inert.
        // `.requeue` until the re-check runs: if the input slot was taken
        // after all (the paste never happened), the mail waits, not drops.
        var preReturnVerdict: MailboxStdinBuffer.PushVerdict = .requeue
        let stillTheRecipient: () -> Bool = { [weak self, weak terminalTab] in
            guard let self, let terminalTab else {
                preReturnVerdict = .drop
                return false
            }
            preReturnVerdict = self.mailboxPushVerdict(
                surfaceId: surfaceId,
                terminalTab: terminalTab,
                trigger: trigger,
                admittedTurn: admittedTurn
            )
            return preReturnVerdict == .paste
        }
        terminalTab.surface.sendSubmitFormText(
            MailboxStdinBuffer.joinedBlock(claimed),
            shouldSubmit: stillTheRecipient
        ) { [weak self] dispatched in
            if dispatched {
                for entry in claimed {
                    EventEmitter.shared.emitMailboxDelivered(
                        workspace: self?.id ?? dispatcher.workspaceId,
                        id: entry.id,
                        recipient: entry.recipientName,
                        surface: surfaceId,
                        via: "push"
                    )
                    if entry.id != immediateId {
                        dispatcher.logStdinLifecycle(
                            id: entry.id,
                            recipient: entry.recipientName,
                            outcome: .flushed,
                            bytes: entry.block.utf8.count
                        )
                    }
                }
            } else {
                // No submit reached the agent: the mail is not delivered.
                Self.undoMailboxClaims(claimed, inbox: inbox)
                let tabStillThere = (self?.panels[surfaceId] as? TerminalTab) != nil
                if tabStillThere, preReturnVerdict == .requeue, let self {
                    // Same agent, gate closed (a draft, a new turn): wait for
                    // the next edge. Receivers dedupe by id if the operator
                    // submits the pasted text themselves.
                    let evicted = self.mailboxStdinBuffer.requeueFront(surfaceId: surfaceId, entries: claimed)
                    for entry in claimed where !evicted.contains(entry) {
                        dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .buffered)
                    }
                    for entry in evicted {
                        dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: .evicted)
                    }
                } else {
                    // `expired` when the agent is gone or no longer owns the
                    // terminal, `closed` when the tab or surface went away.
                    let outcome: MailboxDispatchLog.HandlerOutcome =
                        tabStillThere && preReturnVerdict == .drop ? .expired : .closed
                    for entry in claimed {
                        dispatcher.logStdinLifecycle(id: entry.id, recipient: entry.recipientName, outcome: outcome)
                    }
                }
            }
            guard let self else { return }
            self.mailboxStdinBuffer.endPush(surfaceId: surfaceId, typedAt: dispatched ? pastedAt : nil)
            if !dispatched {
                self.retryMailboxPush(surfaceId: surfaceId)
            }
        }
    }

    /// After a push ends without typing, retry whatever is still queued: an
    /// agent that still owns its terminal re-checks its gate; otherwise the
    /// queue drops (the inbox keeps it).
    private func retryMailboxPush(surfaceId: UUID) {
        let trigger: MailboxStdinBuffer.FlushTrigger =
            mailboxAgentOwnsTerminal(surfaceId: surfaceId) ? .agentPrompt : .shellPrompt
        startMailboxPush(surfaceId: surfaceId, trigger: trigger, immediateId: nil)
    }

    /// The kernel's answer to "is this tab's interactive agent the process
    /// reading its terminal right now?" (`MailboxAgentForeground`).
    private func mailboxAgentOwnsTerminal(surfaceId: UUID) -> Bool {
        MailboxAgentForeground.agentOwnsTerminal(
            process: mailboxStdinBuffer.agentProcess(surfaceId: surfaceId),
            tabTTYName: tabTTYNames[surfaceId]
        )
    }

    /// The push re-check, against live state, for the recipient kind the
    /// push was admitted as. Used after the claim hop and before the Return.
    private func mailboxPushVerdict(
        surfaceId: UUID,
        terminalTab: TerminalTab,
        trigger: MailboxStdinBuffer.FlushTrigger,
        admittedTurn: MailboxStdinBuffer.AgentTurn?
    ) -> MailboxStdinBuffer.PushVerdict {
        mailboxStdinBuffer.pushVerdict(
            surfaceId: surfaceId,
            admittedAs: trigger,
            admittedTurn: admittedTurn,
            lastOperatorKeyAt: terminalTab.surface.lastOperatorKeyAt,
            surfaceAttached: terminalTab.surface.surface != nil,
            agentOwnsTerminal: trigger == .agentPrompt ? mailboxAgentOwnsTerminal(surfaceId: surfaceId) : true
        )
    }

    private static func undoMailboxClaims(_ entries: [MailboxStdinBuffer.Entry], inbox: URL) {
        guard !entries.isEmpty else { return }
        mailboxPushIOQueue.async {
            for entry in entries {
                MailboxIO.unclaim(id: entry.id, inbox: inbox)
            }
        }
    }

    /// An agent lifecycle edge for the mailbox gate. `reported` edges come
    /// from explicit turn-end and turn-start reports (`report_agent_activity`
    /// without `--source=notification`, the Codex turn-complete notify);
    /// `submit` is a Return typed into the tab. Notification-inferred
    /// idleness is deliberately not an input here. `at` is the edge's own
    /// event time, captured before any thread hop.
    func noteMailboxAgentLifecycle(
        surfaceId: UUID,
        source: AgentLifecycleSource,
        activity: SidebarActivityState,
        at eventAt: Date = Date(),
        agentPid: pid_t? = nil
    ) {
        guard panels[surfaceId] != nil else { return }
        switch source {
        case .reported:
            if let agentPid {
                // Pin the process by its start time, read now while it reports.
                let startTime = MailboxAgentForeground.processTerminalInfo(pid: agentPid)?.startTime
                mailboxStdinBuffer.noteAgentProcess(
                    surfaceId: surfaceId,
                    process: .init(pid: agentPid, startTime: startTime)
                )
            }
            mailboxStdinBuffer.noteAgentTurn(surfaceId: surfaceId, atPrompt: activity == .idle, at: eventAt)
            if activity == .idle {
                flushBufferedMailboxStdin(surfaceId: surfaceId, trigger: .agentPrompt)
            }
        case .submit:
            mailboxStdinBuffer.noteSubmit(surfaceId: surfaceId, at: eventAt)
        case .headless:
            // A headless run nested in the tab (`claude -p` from the agent's
            // own shell tool) must not unseat the interactive agent that still
            // owns the terminal; it only marks a tab with no such agent.
            guard !mailboxAgentOwnsTerminal(surfaceId: surfaceId) else { return }
            mailboxStdinBuffer.noteAgentProcess(surfaceId: surfaceId, process: nil)
            mailboxStdinBuffer.noteAgentTurn(surfaceId: surfaceId, atPrompt: false, at: eventAt)
        case .inferred:
            return
        }
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    private var bonsplitTabIdToTabId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (e.g., Cmd+W "Close Tab?") so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseBonsplitTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmBonsplitTabIds: Set<TabID> = []

    /// Tab IDs whose next close attempt should be treated as an explicit
    /// workspace-close gesture from the user (the tab-strip X button, or Cmd+W when
    /// the shortcut preference is set to close the workspace on the last surface),
    /// rather than an internal close/move flow.
    private var explicitUserCloseBonsplitTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    private var postCloseSelectBonsplitTabId: [TabID: TabID] = [:]
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    private var pendingAreaCloseTabIds: [UUID: [UUID]] = [:]
    private var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserTabRestoreSnapshot] = [:]
    private var isApplyingTabSelection = false
    private struct PendingTabSelectionRequest {
        let bonsplitTabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: TabFocusIntent?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }
    private var pendingTabSelection: PendingTabSelectionRequest?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    private var debugLastDidMoveTabTimestamp: TimeInterval = 0
    private var debugDidMoveTabEventCount: UInt64 = 0
#endif
    private var layoutFollowUpObservers: [NSObjectProtocol] = []
    private var layoutFollowUpPanelsCancellable: AnyCancellable?
    private var surfaceShapeBreadcrumbCancellable: AnyCancellable?
    private var layoutFollowUpTimeoutWorkItem: DispatchWorkItem?
    private var layoutFollowUpReason: String?
    private var layoutFollowUpTerminalFocusTabId: UUID?
    private var layoutFollowUpBrowserTabId: UUID?
    private var layoutFollowUpBrowserExitFocusTabId: UUID?
    private var layoutFollowUpNeedsGeometryPass = false
    private var layoutFollowUpAttemptScheduled = false
    private var layoutFollowUpAttemptVersion: Int = 0
    private var layoutFollowUpStalledAttemptCount = 0
#if DEBUG
    private var debugLayoutFlushCount: UInt64 = 0
#endif
    private var isAttemptingLayoutFollowUp = false
    private var isNormalizingPinnedTabOrder = false
    private var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    private var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    private struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    struct DetachedTabTransfer {
        let panelId: UUID
        let panel: any TabContent
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let cachedTitle: String?
        let customTitle: String?
        let customColor: String?
        let manuallyUnread: Bool
        let terminalType: String?
        let terminalTypeSource: MetadataSource?
        let derivedActivity: SidebarActivityState?
        let derivedActivitySource: MetadataSource?
        let isAgentCold: Bool
        let detectedTerminalType: String?
        let activityState: BonsplitTabActivityState?
        let attention: TabAttentionSnapshot
        /// When the surface entered its sheet-visible state, so a moved tab keeps its clock.
        let tabSheetStatusEntered: TabSheetStatusEntry?
        /// The last command start/finish, so a moved terminal keeps its `active` clock.
        let shellEdgeAt: Date?
    }

    private var detachingBonsplitTabIds: Set<TabID> = []
    private var pendingDetachedSurfaces: [TabID: DetachedTabTransfer] = [:]
    private var activeDetachCloseTransactions: Int = 0
    private var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }

#if DEBUG
    private func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func tabIdFromBonsplitTabId(_ bonsplitTabId: TabID) -> UUID? {
        bonsplitTabIdToTabId[bonsplitTabId]
    }

    func markExplicitClose(bonsplitTabId: TabID) {
        explicitUserCloseBonsplitTabIds.insert(bonsplitTabId)
    }

    func bonsplitTabIdFromTabId(_ panelId: UUID) -> TabID? {
        bonsplitTabIdToTabId.first { $0.value == panelId }?.key
    }

    /// Resolve the bonsplit pane hosting the given panel.
    ///
    /// Walks `bonsplitController.allPaneIds` searching for a pane whose tabs
    /// include the panel's surface id. Used by split primitives to find the
    /// source pane of a split and by `WorkspaceLayoutExecutor` to resolve the
    /// pane that hosts a just-created panel for pane-metadata writes.
    ///
    /// O(panes * tabsPerPane) worst case; workspaces in the field have
    /// single-digit pane counts so the cost is negligible.
    func paneIdForTab(_ panelId: UUID) -> PaneID? {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else { return nil }
        for paneId in bonsplitController.allPaneIds {
            if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == bonsplitTabId }) {
                return paneId
            }
        }
        return nil
    }

    /// C11-228: drive each panel's lifecycle (active ↔ throttled) from the
    /// model on selection edges. `TerminalPanelView` also drives it, but a
    /// deselected workspace's subtree sits in a hidden hosting controller whose
    /// body often never re-evaluates, so its `false` edge was lost. Uses the
    /// view's visibility rule; `applyVisibility` is idempotent and keeps
    /// operator-pinned `hibernated`, so firing from both paths is safe.
    func applyPanelVisibility(workspaceVisible: Bool) {
        let focusedId = focusedPanelId
        for paneId in bonsplitController.allPaneIds {
            let selectedBonsplitTabId = bonsplitController.selectedTab(inPane: paneId)?.id
            for bonsplitTab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { continue }
                let isVisible = WorkspaceContentView.panelVisibleInUI(
                    isWorkspaceVisible: workspaceVisible,
                    isSelectedInPane: bonsplitTab.id == selectedBonsplitTabId,
                    isFocused: panelId == focusedId
                )
                switch panels[panelId] {
                case let terminal as TerminalTab:
                    terminal.applyVisibility(isVisible)
                case let browser as BrowserTab:
                    browser.applyVisibility(isVisible)
                default:
                    break
                }
            }
        }
    }

    private func installBrowserTabSubscription(_ browserTab: BrowserTab) {
        let subscription = Publishers.CombineLatest3(
            browserTab.$pageTitle.removeDuplicates(),
            browserTab.$isLoading.removeDuplicates(),
            browserTab.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserTab] _, isLoading, favicon in
            guard let self = self,
                  let browserTab = browserTab,
                  let bonsplitTabId = self.bonsplitTabIdFromTabId(browserTab.id) else { return }
            guard let existing = self.bonsplitController.tab(bonsplitTabId) else { return }

            let nextTitle = browserTab.displayTitle
            if self.tabTitles[browserTab.id] != nextTitle {
                self.tabTitles[browserTab.id] = nextTitle
            }
            let resolvedTitle = self.resolvedTabTitle(panelId: browserTab.id, fallback: nextTitle)
            let sidebarLabel = TitleFormatting.sidebarLabel(from: resolvedTitle)
            let titleUpdate: String? = existing.title == sidebarLabel ? nil : sidebarLabel
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading

            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                bonsplitTabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.tabCustomTitles[browserTab.id] != nil,
                isLoading: loadingUpdate,
                detail: titleUpdate == nil
                    ? nil
                    : self.tabDetailReplacingTitle(bonsplitTabId: bonsplitTabId, with: resolvedTitle)
            )
        }
        tabSubscriptions[browserTab.id] = subscription
        if browserTab.sticksAsPreferred {
            setPreferredBrowserProfileID(browserTab.profileID)
        }
    }

    func setPreferredBrowserProfileID(_ profileID: UUID?) {
        guard let profileID else {
            preferredBrowserProfileID = nil
            return
        }
        guard BrowserProfileStore.shared.profileDefinition(id: profileID) != nil else { return }
        preferredBrowserProfileID = profileID
    }

    private func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID {
        func available(_ profileID: UUID?) -> UUID? {
            guard let profileID,
                  BrowserProfileStore.shared.profileDefinition(id: profileID) != nil,
                  !BrowserProfileStore.shared.isReserved(profileID) else { return nil }
            return profileID
        }

        if let profileID = available(preferredProfileID) {
            return profileID
        }
        if let sourcePanelId,
           let sourceBrowserPanel = browserPanel(for: sourcePanelId),
           sourceBrowserPanel.sticksAsPreferred,
           let profileID = available(sourceBrowserPanel.profileID) {
            return profileID
        }
        if let profileID = available(preferredBrowserProfileID) {
            return profileID
        }
        return available(BrowserProfileStore.shared.effectiveLastUsedProfileID)
            ?? BrowserProfileStore.shared.builtInDefaultProfileID
    }

    private func declareMarkdownTitleFromTab(_ markdownTab: MarkdownTab) {
        guard let path = markdownTab.filePath, !path.isEmpty else { return }
        let title = markdownTab.displayTitle
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try? TabMetadataStore.shared.setMetadata(
            workspaceId: id,
            surfaceId: markdownTab.id,
            partial: ["title": title],
            mode: .merge,
            source: .declare
        )
        syncTabTitleFromMetadata(panelId: markdownTab.id)
    }

    private func installMarkdownTabSubscription(_ markdownTab: MarkdownTab) {
        // Declare the filename as the surface manifest title synchronously so
        // `cmux get-metadata --key title` reflects it right after open,
        // without waiting on Combine's main-queue delivery.
        declareMarkdownTitleFromTab(markdownTab)

        let subscription = markdownTab.$displayTitle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownTab] newTitle in
                guard let self,
                      let markdownTab else { return }

                // Keep the declared title in sync when the panel's filename
                // changes (e.g. via the empty-state bind flow). Source
                // `.declare` yields to an explicit `cmux set-title`.
                if markdownTab.filePath != nil,
                   !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try? TabMetadataStore.shared.setMetadata(
                        workspaceId: self.id,
                        surfaceId: markdownTab.id,
                        partial: ["title": newTitle],
                        mode: .merge,
                        source: .declare
                    )
                    self.syncTabTitleFromMetadata(panelId: markdownTab.id)
                    return
                }

                guard let bonsplitTabId = self.bonsplitTabIdFromTabId(markdownTab.id),
                      let existing = self.bonsplitController.tab(bonsplitTabId) else { return }

                if self.tabTitles[markdownTab.id] != newTitle {
                    self.tabTitles[markdownTab.id] = newTitle
                }
                let resolvedTitle = self.resolvedTabTitle(panelId: markdownTab.id, fallback: newTitle)
                let sidebarLabel = TitleFormatting.sidebarLabel(from: resolvedTitle)
                guard existing.title != sidebarLabel else { return }
                self.bonsplitController.updateTab(
                    bonsplitTabId,
                    title: sidebarLabel,
                    hasCustomTitle: self.tabCustomTitles[markdownTab.id] != nil,
                    detail: self.tabDetailReplacingTitle(bonsplitTabId: bonsplitTabId, with: resolvedTitle)
                )
            }
        tabSubscriptions[markdownTab.id] = subscription
    }

    private func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    private func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        for panel in panels.values {
            guard let browserTab = panel as? BrowserTab else { continue }
            browserTab.setRemoteWorkspaceStatus(snapshot)
        }
    }

    // MARK: - Panel Access

    func panel(for bonsplitTabId: TabID) -> (any TabContent)? {
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTabId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalTab? {
        panels[panelId] as? TerminalTab
    }

    func browserPanel(for panelId: UUID) -> BrowserTab? {
        panels[panelId] as? BrowserTab
    }

    /// C11-25 commit 8: rehydrate workspace + panel lifecycle state from
    /// `lifecycle_state` canonical metadata after a `c11 restore` /
    /// blueprint apply. Called by `WorkspaceLayoutExecutor` once all
    /// surfaces and metadata are materialized.
    ///
    /// For browser panels with `lifecycle_state == "hibernated"`:
    ///   `setHibernated(true)` re-triggers the snapshot+terminate path
    ///   so the restored panel ends up in the same operator-pinned
    ///   state. Snapshots are in-memory only in C11-25, so the
    ///   placeholder will render a neutral background until the
    ///   operator resumes — operator accepted in §0a.
    ///
    /// For terminals/markdown the canonical metadata is preserved but
    /// no runtime change is dispatched (auto-throttle handles
    /// visibility; explicit terminal hibernate is deferred).
    ///
    /// `isHibernated` is rebuilt from "any browser panel hibernated".
    func restoreLifecycleStateFromMetadata() {
        var anyHibernated = false
        for (panelId, panel) in panels {
            let snapshot = TabMetadataStore.shared.getMetadata(
                workspaceId: id,
                surfaceId: panelId
            )
            guard let stateStr = snapshot.metadata[MetadataKey.lifecycleState] as? String,
                  let state = TabLifecycleState(rawValue: stateStr) else {
                continue
            }
            if state == .hibernated {
                anyHibernated = true
                if let browser = panel as? BrowserTab {
                    browser.setHibernated(true)
                }
            }
        }
        if isHibernated != anyHibernated {
            isHibernated = anyHibernated
        }
    }

    /// C11-25: hibernate every browser panel in the workspace and flip
    /// the workspace-level flag. Terminals stay on the auto-throttle
    /// path (workspace deselect already pauses libghostty rendering;
    /// SIGSTOP for terminals is deferred). Markdown surfaces are
    /// unaffected. Idempotent.
    func hibernate() {
        for panel in panels.values {
            if let browser = panel as? BrowserTab {
                browser.setHibernated(true)
            }
        }
        isHibernated = true
    }

    /// C11-25: resume the workspace. Browser panels transition out of
    /// `.hibernated` (back to `.active`); the auto-throttle path takes
    /// it from there based on visibility. Idempotent.
    func resume() {
        for panel in panels.values {
            if let browser = panel as? BrowserTab {
                browser.setHibernated(false)
            }
        }
        isHibernated = false
    }

    func markdownTab(for panelId: UUID) -> MarkdownTab? {
        panels[panelId] as? MarkdownTab
    }

    private func tabKind(for panel: any TabContent) -> String {
        switch panel.panelType {
        case .terminal:
            return TabKind.terminal
        case .browser:
            return TabKind.browser
        case .markdown:
            return TabKind.markdown
        }
    }

    func resolvedTabTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = tabCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    private func syncPinnedStateForTab(_ bonsplitTabId: TabID, panelId: UUID) {
        let isPinned = pinnedTabIds.contains(panelId)
        if let panel = panels[panelId] {
            bonsplitController.updateTab(
                bonsplitTabId,
                kind: .some(tabKind(for: panel)),
                isPinned: isPinned
            )
        } else {
            bonsplitController.updateTab(bonsplitTabId, isPinned: isPinned)
        }
    }

    private func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forWorkspaceId: id, surfaceId: panelId) ?? false
    }

    func attentionSnapshot(panelId: UUID) -> TabAttentionSnapshot {
        attentionByTab[panelId]
            ?? TabAttentionSnapshot(
                workspaceId: id,
                surfaceId: panelId,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: false
            )
    }

    func setAttentionSnapshot(_ snapshot: TabAttentionSnapshot?, forSurface surfaceId: UUID) {
        if let snapshot, snapshot.isFlagged || snapshot.suppressed {
            if attentionByTab[surfaceId] != snapshot {
                attentionByTab[surfaceId] = snapshot
            }
        } else {
            attentionByTab.removeValue(forKey: surfaceId)
        }
        syncSurfaceTabActivityStateForTab(surfaceId)
        (panels[surfaceId] as? TerminalTab)?.surface.hostedView.updateFlagBanner()
    }

    /// `terminalKind` lets a caller that has already read the surface's kind
    /// hand it in. The sidebar roster reads it for its agent test and would
    /// otherwise pay for the same lookup twice per surface, per evaluation.
    func resolvedSurfaceTabActivityState(
        panelId: UUID,
        hasExactSurfaceNotification: Bool? = nil,
        terminalKind: String?? = nil
    ) -> BonsplitTabActivityState? {
        let attention = attentionSnapshot(panelId: panelId)
        return TabActivityResolver.resolve(
            hasExactSurfaceNotification: hasExactSurfaceNotification ?? hasUnreadNotification(panelId: panelId),
            hasJournalAttention: journalByTab[panelId]?.paintsAttention == true,
            derivedActivity: derivedActivityByTab[panelId],
            isCold: coldAgentSurfaceIds.contains(panelId),
            terminalType: terminalKind ?? surfaceActivityTerminalKind(panelId: panelId),
            flagged: attention.isFlagged,
            suppressed: attention.suppressed
        )
    }

    func resolvedSurfaceTabActivityPresentation(
        panelId: UUID,
        activityState: BonsplitTabActivityState?
    ) -> BonsplitTabActivityPresentation? {
        let attention = attentionSnapshot(panelId: panelId)
        let help = resolvedAgentActivityHelp(
            panelId: panelId,
            activityState: activityState
        )
        guard help != nil || attention.isFlagged || attention.suppressed else {
            return nil
        }
        return BonsplitTabActivityPresentation(
            colorOverrideHex: attention.isFlagged ? "#9D8AD9" : nil,
            motion: attention.isFlagged
                ? (activityState == .waiting ? .binaryFlash : .breathe)
                : nil,
            alternateCoreColorHex: attention.isFlagged && activityState == .waiting
                ? "#FFFFFF"
                : nil,
            suppressesDefaultMotion: attention.isFlagged || attention.suppressed,
            accessibilityValue: help?.accessibilityValue,
            help: help?.help
        )
    }

    func resolvedAgentActivityHelp(
        panelId: UUID,
        activityState: BonsplitTabActivityState?
    ) -> AgentActivityHelpProjection? {
        let state: WorkspacePulseState
        switch activityState {
        case .waiting: state = .waiting
        case .running: state = .working
        case .idle: state = .idle
        case .cold: state = .cold
        case nil: return nil
        }
        let attention = attentionSnapshot(panelId: panelId)
        let lastActivityAt = TabActivityTracker.shared.lastActivity(
            for: panelId.uuidString
        )
        let waitingStartedAt = state == .waiting
            ? AppDelegate.shared?.notificationStore?.unreadNotificationCreatedAt(
                forWorkspaceId: id,
                surfaceId: panelId
            )
            : nil
        return AgentActivityHelpProjection.project(
            state: state,
            lastActivityAt: lastActivityAt,
            waitingStartedAt: waitingStartedAt,
            coldAfterSeconds: SidebarAgentColdSettings.thresholdSeconds(),
            flagReason: attention.flagReason,
            flagRaisedAt: attention.flagRaisedAt,
            suppressed: attention.suppressed,
            journal: journalByTab[panelId]
        )
    }

    func tabActivityDetailsSnapshot(
        panelId: UUID
    ) -> TabActivityDetailsSnapshot {
        let activityState = resolvedSurfaceTabActivityState(panelId: panelId)
        let activityHelp = resolvedAgentActivityHelp(
            panelId: panelId,
            activityState: activityState
        )
        return TabActivityDetailsSnapshot(
            activityHelp: activityHelp,
            createdAt: panels[panelId]?.createdAt,
            lastActivityAt: activityHelp?.lastActivityAt
                ?? TabActivityTracker.shared.lastActivity(for: panelId.uuidString),
            lastSeenAt: TabSeenTracker.shared.storedLastSeenAt(panelId: panelId),
            isBeingSeen: TabSeenTracker.shared.isBeingSeen(panelId: panelId)
        )
    }

    func syncSurfaceTabActivityStateForTab(
        _ panelId: UUID,
        hasExactSurfaceNotification: Bool? = nil
    ) {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId),
              let existing = bonsplitController.tab(bonsplitTabId) else { return }
        let hasExact = hasExactSurfaceNotification ?? hasUnreadNotification(panelId: panelId)
        let activityState = resolvedSurfaceTabActivityState(
            panelId: panelId,
            hasExactSurfaceNotification: hasExact
        )
        let activityPresentation = resolvedSurfaceTabActivityPresentation(
            panelId: panelId,
            activityState: activityState
        )
        let shouldShowLegacyUnread = manualUnreadTabIds.contains(panelId)
        recordTabSheetStatusTransition(panelId: panelId, activity: activityState)
        syncSurfaceTabDetailForTab(panelId)
        guard existing.activityState != activityState
            || existing.activityPresentation != activityPresentation
            || existing.showsNotificationBadge != shouldShowLegacyUnread else { return }
        bonsplitController.updateTab(
            bonsplitTabId,
            showsNotificationBadge: shouldShowLegacyUnread,
            activityState: .some(activityState),
            activityPresentation: .some(activityPresentation)
        )
    }

    func syncSurfaceTabActivityStates() {
        for panelId in bonsplitTabIdToTabId.values {
            syncSurfaceTabActivityStateForTab(panelId)
        }
    }

    private func syncUnreadBadgeStateForTab(_ panelId: UUID) {
        syncSurfaceTabActivityStateForTab(panelId)
    }

    private func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let bonsplitTabs = bonsplitController.tabs(inPane: paneId)
        let pinnedBonsplitTabs = bonsplitTabs.filter { bonsplitTab in
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return false }
            return pinnedTabIds.contains(panelId)
        }
        let unpinnedBonsplitTabs = bonsplitTabs.filter { bonsplitTab in
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return true }
            return !pinnedTabIds.contains(panelId)
        }
        let desiredOrder = pinnedBonsplitTabs + unpinnedBonsplitTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentBonsplitTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentBonsplitTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    private func insertionIndexToRight(of anchorBonsplitTabId: TabID, inPane paneId: PaneID) -> Int {
        let bonsplitTabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = bonsplitTabs.firstIndex(where: { $0.id == anchorBonsplitTabId }) else { return bonsplitTabs.count }
        let pinnedCount = bonsplitTabs.reduce(into: 0) { count, bonsplitTab in
            if let panelId = tabIdFromBonsplitTabId(bonsplitTab.id), pinnedTabIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, bonsplitTabs.count)
        return max(rawTarget, pinnedCount)
    }

    func setTabCustomTitle(panelId: UUID, title: String?) {
        guard panels[panelId] != nil else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = tabCustomTitles[panelId]
        if trimmed.isEmpty {
            if previous != nil {
                tabCustomTitles.removeValue(forKey: panelId)
            }
            _ = try? TabMetadataStore.shared.clearMetadata(
                workspaceId: id,
                surfaceId: panelId,
                keys: ["title"],
                source: .explicit
            )
        } else {
            if previous != trimmed {
                tabCustomTitles[panelId] = trimmed
            }
            _ = try? TabMetadataStore.shared.setMetadata(
                workspaceId: id,
                surfaceId: panelId,
                partial: ["title": trimmed],
                mode: .merge,
                source: .explicit
            )
        }

        syncTabTitleFromMetadata(panelId: panelId)
    }

    /// Set or clear the surface tab color for a panel. Pass nil or an empty/whitespace
    /// string to clear; otherwise the input is normalized to `#RRGGBB` via
    /// `WorkspaceTabColorSettings.normalizedHex`. Invalid hex inputs are ignored
    /// (state unchanged) so callers can pass user input directly.
    func setTabCustomColor(panelId: UUID, color: String?) {
        guard panels[panelId] != nil else { return }
        let next: String?
        if let raw = color?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let normalized = WorkspaceColorSettings.normalizedHex(raw) else { return }
            next = normalized
        } else {
            next = nil
        }
        let previous = tabCustomColors[panelId]
        guard previous != next else { return }
        if let next {
            tabCustomColors[panelId] = next
        } else {
            tabCustomColors.removeValue(forKey: panelId)
        }
        if let bonsplitTabId = bonsplitTabIdFromTabId(panelId) {
            bonsplitController.updateTab(bonsplitTabId, customColorHex: .some(next))
        }
    }

    /// Returns the current normalized surface tab color for a panel, or nil if
    /// none is set.
    func tabCustomColor(panelId: UUID) -> String? {
        tabCustomColors[panelId]
    }

    func isTabPinned(_ panelId: UUID) -> Bool {
        pinnedTabIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return tabKind(for: panel)
    }

    func requestBackgroundTerminalSurfaceStartIfNeeded() {
        for terminalPanel in panels.values.compactMap({ $0 as? TerminalTab }) {
            terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    @discardableResult
    func preloadTerminalPanelForDebugStress(
        bonsplitTabId: TabID,
        inPane paneId: PaneID
    ) -> TerminalTab? {
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTabId),
              let terminalTab = panels[panelId] as? TerminalTab else {
            return nil
        }

        debugStressPreloadSelectionDepth += 1
        defer { debugStressPreloadSelectionDepth -= 1 }
        let isVisibleSelection =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == bonsplitTabId &&
            terminalTab.surface.isViewInWindow &&
            terminalTab.hostedView.superview != nil

        if isVisibleSelection {
            terminalTab.requestViewReattach()
            scheduleTerminalGeometryReconcile()
        }
        terminalTab.surface.requestBackgroundSurfaceStartIfNeeded()
        return terminalTab
    }

    func scheduleDebugStressTerminalGeometryReconcile() {
        scheduleTerminalGeometryReconcile()
    }

    func hasLoadedTerminalSurface() -> Bool {
        let terminalTabs = panels.values.compactMap { $0 as? TerminalTab }
        guard !terminalTabs.isEmpty else { return true }
        return terminalTabs.contains { $0.surface.surface != nil }
    }

    func tabTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = tabTitles[panelId] ?? panel.displayTitle
        return resolvedTabTitle(panelId: panelId, fallback: fallback)
    }

    func setTabPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedTabIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedTabIds.insert(panelId)
        } else {
            pinnedTabIds.remove(panelId)
        }

        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(bonsplitTabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markTabUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        guard manualUnreadTabIds.insert(panelId).inserted else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForTab(panelId)
    }

    func markTabRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        AppDelegate.shared?.notificationStore?.markRead(forWorkspaceId: id, surfaceId: panelId)
        clearManualUnread(panelId: panelId)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveUnread = manualUnreadTabIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForTab(panelId)
    }

    static func shouldClearManualUnread(
        previousFocusedPanelId: UUID?,
        nextFocusedPanelId: UUID,
        isManuallyUnread: Bool,
        markedAt: Date?,
        now: Date = Date(),
        sameTabGraceInterval: TimeInterval = manualUnreadFocusGraceInterval
    ) -> Bool {
        guard isManuallyUnread else { return false }

        if let previousFocusedPanelId, previousFocusedPanelId != nextFocusedPanelId {
            return true
        }

        guard let markedAt else { return true }
        return now.timeIntervalSince(markedAt) >= sameTabGraceInterval
    }

    static func shouldShowUnreadIndicator(hasUnreadNotification: Bool, isManuallyUnread: Bool) -> Bool {
        hasUnreadNotification || isManuallyUnread
    }

    // MARK: - Title Management

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil, stableDefaultTitle == nil else { return }
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        let next: String?
        if let hex {
            next = WorkspaceColorSettings.normalizedHex(hex)
        } else {
            next = nil
        }
        guard customColor != next else { return }
        customColor = next
        customColorDidChange.send(next)
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = stableDefaultTitle ?? processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    /// Set or clear the stable root (socket `workspace.set_root`, the GUI
    /// affordance, creation). Either way auto-adoption is disarmed: a clear
    /// sticks, and a set root is never replaced by a shell report.
    func setRootDirectory(_ directory: String?) {
        rootDirectory = Self.normalizedRootDirectory(directory)
        rootAdoptionArmed = false
    }

    /// Session restore: keep the persisted root. A rootless snapshot stays
    /// armed unless the operator had cleared the root (legacy snapshots carry
    /// no flag and count as armed).
    private func restoreRootDirectory(_ directory: String?, adoptionArmed: Bool?) {
        rootDirectory = Self.normalizedRootDirectory(directory)
        rootAdoptionArmed = rootDirectory == nil && (adoptionArmed ?? true)
    }

    /// C11-238: adopt a shell-reported cwd as the root of a rootless workspace.
    /// Called only for real shell reports (`TabManager.updateSurfaceDirectory`),
    /// never for restore writes or git probes. Only the focused surface counts;
    /// home and `/` are where a fresh shell lands, not a project, so adoption
    /// waits for the first other directory. Remote workspaces report remote
    /// paths and never adopt.
    @discardableResult
    func adoptReportedDirectoryAsRootIfNeeded(panelId: UUID, directory: String) -> Bool {
        guard rootAdoptionArmed, rootDirectory == nil, remoteConfiguration == nil else { return false }
        if let focusedPanelId, focusedPanelId != panelId { return false }
        guard let candidate = Self.normalizedRootDirectory(directory),
              !Self.isShellLandingDirectory(candidate) else { return false }
        rootDirectory = candidate
        rootAdoptionArmed = false
#if DEBUG
        dlog("workspace.root.adopt workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) root=\(candidate)")
#endif
        return true
    }

    /// True when the root is set and still an existing directory.
    var rootDirectoryExists: Bool {
        Self.usableRootDirectory(rootDirectory) != nil
    }

    /// The one missing-root rule: a root counts only while it is still an
    /// existing directory (worktree roots get pruned). Shared by the new-surface
    /// seam, the socket `agent.launch` resolver, and new-workspace placement.
    nonisolated static func usableRootDirectory(_ root: String?) -> String? {
        guard let root, isExistingDirectory(root) else { return nil }
        return root
    }

    nonisolated static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    nonisolated private static func isShellLandingDirectory(_ path: String) -> Bool {
        let home = NSString(string: FileManager.default.homeDirectoryForCurrentUser.path).standardizingPath
        return path == "/" || path == home
    }

    nonisolated private static func normalizedRootDirectory(_ directory: String?) -> String? {
        guard let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return NSString(string: trimmed).standardizingPath
    }

    /// Merge operator-authored entries into `metadata` (workspace-scoped).
    /// Trimmed empty values clear their keys; trimmed non-empty values
    /// overwrite. Mirrors the shape of `SessionWorkspaceSnapshot.metadata`
    /// at the plan/snapshot boundary so `WorkspaceLayoutExecutor` and
    /// Phase 1 Snapshot restore can land values through one setter.
    func setOperatorMetadata(_ entries: [String: String]) {
        guard !entries.isEmpty else { return }
        var next = metadata
        for (rawKey, rawValue) in entries {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                next.removeValue(forKey: key)
            } else {
                next[key] = trimmed
            }
        }
        if next != metadata {
            metadata = next
        }
    }

    // MARK: - Directory Updates

    func updateTabDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if tabDirectories[panelId] != trimmed {
            tabDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId, currentDirectory != trimmed {
            currentDirectory = trimmed
        }
    }

    func updateTabShellActivityState(panelId: UUID, state: TabShellActivityState) {
        guard panels[panelId] != nil else { return }
        let previousState = tabShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return }
        tabShellActivityStates[panelId] = state
        // Tab sheet `active` for plain terminals: a command starting or finishing.
        tabShellEdgeAt[panelId] = Date()
#if DEBUG
        dlog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
        // A recipient returning to its prompt is the safe moment to inject any
        // blocks buffered while it was busy. Whatever agent ran in the tab has
        // exited, so its turn edges and agent-gated blocks no longer apply.
        // Shell-integration state is not reliable while an agent runs (a
        // launched agent's tab can read `promptIdle`), so the kernel decides:
        // only when the tab's agent no longer owns the terminal is it gone.
        if state == .promptIdle, !mailboxAgentOwnsTerminal(surfaceId: panelId) {
            mailboxStdinBuffer.forgetAgent(surfaceId: panelId)
            flushBufferedMailboxStdin(surfaceId: panelId, trigger: .shellPrompt)
        }
        // TEL-3: feed the shell-activity transition into the derived-liveness
        // backend, which resolves it (with its own debounce/heuristics) back
        // into `derivedActivityBySurface` via `setDerivedActivity`.
        TabLivenessDeriver.onShellActivityChanged(
            surfaceId: panelId,
            workspaceId: id,
            state: state,
            workspace: self
        )
    }

    // MARK: - TEL-4 Derived Activity

    /// TEL-4: main-actor setter for a surface's derived-liveness state. Passing
    /// `nil` removes the key (surface has no derived signal); any other value
    /// overwrites it. The enclosing type is `@MainActor`, so this publishes on
    /// the main actor. Cheap and I/O-free.
    func setDerivedActivity(_ state: SidebarActivityState?, forSurface surfaceId: UUID) {
        let changed: Bool
        if let state {
            if derivedActivityByTab[surfaceId] != state {
                derivedActivityByTab[surfaceId] = state
                changed = true
            } else {
                changed = false
            }
        } else if derivedActivityByTab[surfaceId] != nil {
            derivedActivityByTab.removeValue(forKey: surfaceId)
            changed = true
        } else {
            changed = false
        }
        if changed {
            syncSurfaceTabActivityStateForTab(surfaceId)
        }
    }

    /// Update the live dormancy projection for one agent surface.
    func setAgentCold(_ isCold: Bool, forSurface surfaceId: UUID) {
        let changed: Bool
        if isCold {
            changed = coldAgentSurfaceIds.insert(surfaceId).inserted
        } else {
            changed = coldAgentSurfaceIds.remove(surfaceId) != nil
        }
        if changed {
            syncSurfaceTabActivityStateForTab(surfaceId)
        }
    }

    /// Install the detector's current foreground-process classification.
    /// `"shell"` is authoritative evidence that the agent process exited;
    /// `"unknown"` is not, because an agent may temporarily foreground an
    /// unrecognized child command.
    func setDetectedTerminalType(_ terminalType: String?, forSurface surfaceId: UUID) {
        let normalized = terminalType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized?.isEmpty == false ? normalized : nil
        let changed: Bool
        if let value {
            if detectedTerminalTypesByTab[surfaceId] != value {
                detectedTerminalTypesByTab[surfaceId] = value
                changed = true
            } else {
                changed = false
            }
        } else {
            changed = detectedTerminalTypesByTab.removeValue(forKey: surfaceId) != nil
        }
        if changed {
            syncSurfaceTabActivityStateForTab(surfaceId)
        }
    }

    /// TEL-4: workspace-level rollup of per-surface derived activity. `.working`
    /// if ANY surface is working, else `.idle` if any surface is idle, else
    /// `nil` when there are no derived signals at all.
    var aggregatedDerivedActivity: SidebarActivityState? {
        var sawIdle = false
        for state in derivedActivityByTab.values {
            switch state {
            case .working:
                return .working
            case .idle:
                sawIdle = true
            }
        }
        return sawIdle ? .idle : nil
    }

    func tabNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: tabShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func updateTabGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = tabGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != branch
        if existing?.branch != branch || existing?.isDirty != isDirty {
            tabGitBranches[panelId] = state
        }
        if branchChanged {
            tabPullRequests.removeValue(forKey: panelId)
            if panelId == focusedPanelId {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId {
            gitBranch = state
        }
    }

    func clearTabGitBranch(panelId: UUID) {
        tabGitBranches.removeValue(forKey: panelId)
        tabPullRequests.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            gitBranch = nil
            pullRequest = nil
        }
    }

    /// C11-104 — write the resolved worktree+branch chip context for a
    /// panel. Nil means "not a git directory"; we still write the nil
    /// entry so the sidebar can render the absence (no chips) instead
    /// of a stale prior value.
    func updateTabGitContext(panelId: UUID, context: ResolvedGitContext?) {
        // Flatten the subscript's outer optional so "missing key" and
        // "key present with nil value" compare identically.
        let prior: ResolvedGitContext? = tabGitContexts[panelId] ?? nil
        if prior == context { return }
        tabGitContexts[panelId] = context
    }

    func clearTabGitContext(panelId: UUID) {
        tabGitContexts.removeValue(forKey: panelId)
    }

    func updateTabPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) {
        let existing = tabPullRequests[panelId]
        let normalizedBranch = normalizedSidebarBranchName(branch)
        let currentPanelBranch = normalizedSidebarBranchName(tabGitBranches[panelId]?.branch)
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.branch
        }()
        let resolvedChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.checks
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: resolvedBranch,
            checks: resolvedChecks
        )
        if existing != state {
            tabPullRequests[panelId] = state
        }
        if panelId == focusedPanelId {
            pullRequest = state
        }
    }

    func clearTabPullRequest(panelId: UUID) {
        tabPullRequests.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            pullRequest = nil
        }
    }

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        clearAgentPIDs()
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        tabGitBranches.removeAll()
        tabGitContexts.removeAll()
        pullRequest = nil
        tabPullRequests.removeAll()
        tabListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
        resetBrowserPanelsForContextChange(reason: reason)
    }

    func resetBrowserPanelsForContextChange(reason: String) {
        let browserTabs = panels.values.compactMap { $0 as? BrowserTab }
        guard !browserTabs.isEmpty else { return }

#if DEBUG
        dlog(
            "workspace.contextReset.browserPanels workspace=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(browserTabs.count)"
        )
#endif

        for browserTab in browserTabs {
            browserTab.resetForWorkspaceContextChange(reason: reason)
            let nextTitle = browserTab.displayTitle
            _ = updateTabTitle(panelId: browserTab.id, title: nextTitle)

            guard let bonsplitTabId = bonsplitTabIdFromTabId(browserTab.id),
                  let existing = bonsplitController.tab(bonsplitTabId) else {
                continue
            }

            let faviconUpdate: Data?? = existing.iconImageData == nil ? nil : .some(nil)
            let loadingUpdate: Bool? = existing.isLoading ? false : nil

            guard faviconUpdate != nil || loadingUpdate != nil else {
                continue
            }

            bonsplitController.updateTab(
                bonsplitTabId,
                iconImageData: faviconUpdate,
                hasCustomTitle: tabCustomTitles[browserTab.id] != nil,
                isLoading: loadingUpdate
            )
        }
    }

    @discardableResult
    func updateTabTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false

        if tabTitles[panelId] != trimmed {
            tabTitles[panelId] = trimmed
            didMutate = true
        }

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let bonsplitTabId = bonsplitTabIdFromTabId(panelId),
           let panel = panels[panelId] {
            let baseTitle = tabTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedTabTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                bonsplitTabId,
                title: TitleFormatting.sidebarLabel(from: resolvedTitle),
                hasCustomTitle: tabCustomTitles[panelId] != nil,
                detail: tabDetailReplacingTitle(bonsplitTabId: bonsplitTabId, with: resolvedTitle)
            )
            // [TextBox] Keep TerminalPanel.title in sync so TextBox key
            // routing can detect running apps (Claude Code, Codex) via
            // the title regex when `SurfaceMetadataStore.terminal_type`
            // has not yet been classified. See plan §4.4 (title-sync hook).
            if let terminalTab = panel as? TerminalTab {
                terminalTab.updateTitle(trimmed)
            }
        }

        // If this is the only panel and no custom/default title, update workspace title.
        // Stable default workspace names keep the process title as secondary surface state.
        if panels.count == 1, customTitle == nil {
            if stableDefaultTitle == nil, self.title != trimmed {
                self.title = trimmed
                didMutate = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

        return didMutate
    }

    // MARK: - [TextBox] TextBox Input toggle (plan §4.4)

    /// Toggle the TextBox Input for this workspace's terminal panels.
    ///
    /// `scope` decides whether we operate on the focused panel only or
    /// on every terminal panel in this workspace (§8 Q9 locked:
    /// "current workspace"). Behavior within each panel depends on the
    /// user's `TextBoxInputSettings.shortcutBehavior`:
    ///
    /// - `.toggleDisplay`: flip `panel.isTextBoxActive` (show ⇄ hide).
    /// - `.toggleFocus`: keep the TextBox visible, swap first responder
    ///   between the InputTextView and the terminal surface.
    ///
    /// Focus changes are dispatched with `DispatchQueue.main.async` to
    /// avoid reentering first-responder machinery mid-event.
    func toggleTextBoxMode(_ scope: TextBoxToggleTarget) {
        let terminalTabs = panels.values.compactMap { $0 as? TerminalTab }
        guard !terminalTabs.isEmpty else { return }

        let behavior = TextBoxInputSettings.shortcutBehavior()
        let targets: [TerminalTab]

        switch scope {
        case .all:
            targets = terminalTabs
        case .active:
            if let focusedId = focusedPanelIdForTextBoxToggle(),
               let panel = panels[focusedId] as? TerminalTab {
                targets = [panel]
            } else {
                targets = terminalTabs
            }
        }

        switch behavior {
        case .toggleDisplay:
            let shouldShow = !targets.allSatisfy { $0.isTextBoxActive }
            for panel in targets {
                panel.isTextBoxActive = shouldShow
            }
            if shouldShow {
                focusInputTextView(in: targets, retriesRemaining: 4)
            }
        case .toggleFocus:
            // Keep the box visible; swap focus between TextBox and terminal.
            let wasAllVisible = targets.allSatisfy { $0.isTextBoxActive }
            for panel in targets where !panel.isTextBoxActive {
                panel.isTextBoxActive = true
            }
            if !wasAllVisible {
                // First press summoned the TextBox from hidden — focus it, don't
                // swap back to the terminal (the InputTextView may not be mounted
                // yet, so retry briefly until SwiftUI wires it up).
                focusInputTextView(in: targets, retriesRemaining: 4)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let active = self.firstResponderTextBox() {
                        // Focus is in a TextBox — move it back to that panel's terminal.
                        let panel = targets.first { $0.inputTextView === active }
                            ?? terminalTabs.first { $0.inputTextView === active }
                        panel?.surface.focusTerminalView()
                    } else {
                        // Focus is in the terminal (or elsewhere) — move it into the TextBox.
                        guard let firstTarget = targets.first,
                              let view = firstTarget.inputTextView else { return }
                        view.window?.makeFirstResponder(view)
                    }
                }
            }
        }
    }

    /// Move first responder into the first target panel's InputTextView, retrying
    /// briefly if SwiftUI has not yet mounted the container. Used after showing
    /// the TextBox from hidden, where `inputTextView` is nil until the next
    /// render pass wires it up via `onInputTextViewCreated`.
    private func focusInputTextView(in targets: [TerminalTab], retriesRemaining: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.firstResponderTextBox() != nil { return }
            if let firstTarget = targets.first, let view = firstTarget.inputTextView {
                view.window?.makeFirstResponder(view)
                return
            }
            if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.focusInputTextView(in: targets, retriesRemaining: retriesRemaining - 1)
                }
            }
        }
    }

    /// Returns the focused panel ID if it belongs to this workspace and
    /// is a TerminalPanel. Resolved by walking the current main window's
    /// first responder back to a GhosttyNSView, matching the pattern used
    /// by `AppDelegate.focusedTerminalShortcutContext`.
    private func focusedPanelIdForTextBoxToggle() -> UUID? {
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard let responder = targetWindow?.firstResponder else { return nil }
        // If the first responder is an InputTextView, walk its panel back via inputTextView.
        if let inputView = responder as? InputTextView {
            for (panelId, panel) in panels {
                if let terminalTab = panel as? TerminalTab,
                   terminalTab.inputTextView === inputView {
                    return panelId
                }
            }
            return nil
        }
        // Otherwise try the terminal surface responder chain.
        var node: NSResponder? = responder
        while let current = node {
            if let view = current as? NSView,
               let surfaceView = view as? GhosttyNSView,
               let surfaceId = surfaceView.terminalSurface?.id,
               panels[surfaceId] is TerminalTab {
                return surfaceId
            }
            node = current.nextResponder
        }
        return nil
    }

    /// Returns the InputTextView currently holding first responder in
    /// this workspace's key window, if any.
    private func firstResponderTextBox() -> InputTextView? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return window?.firstResponder as? InputTextView
    }

    // MARK: - M7 title bar integration

    /// Apply `title` from the M2 metadata blob into `panelTitles` render cache
    /// and propagate it into bonsplit + workspace title mirrors.
    /// Safe to call on main thread; expected call path: after a `set_metadata`
    /// that touched `title`.
    func syncTabTitleFromMetadata(panelId: UUID) {
        let resolvedTitle: String
        let metadataTitle = TabMetadataStore.shared
            .getMetadata(workspaceId: id, surfaceId: panelId)
            .metadata[MetadataKey.title] as? String
        if let meta = metadataTitle,
           !meta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTitle = meta
        } else if let fallback = panels[panelId]?.displayTitle {
            resolvedTitle = fallback
        } else {
            return
        }

        let trimmed = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, tabTitles[panelId] != trimmed {
            tabTitles[panelId] = trimmed
        }

        if let bonsplitTabId = bonsplitTabIdFromTabId(panelId),
           let panel = panels[panelId] {
            let baseTitle = tabTitles[panelId] ?? panel.displayTitle
            let sidebarLabel = TitleFormatting.sidebarLabel(from: resolvedTabTitle(panelId: panelId, fallback: baseTitle))
            bonsplitController.updateTab(
                bonsplitTabId,
                title: sidebarLabel,
                hasCustomTitle: tabCustomTitles[panelId] != nil,
                detail: tabDetailReplacingTitle(
                    bonsplitTabId: bonsplitTabId,
                    with: resolvedTabTitle(panelId: panelId, fallback: baseTitle)
                )
            )
        }

        if panels.count == 1, customTitle == nil {
            if processTitle != trimmed {
                processTitle = trimmed
            }
            if stableDefaultTitle == nil, self.title != trimmed {
                self.title = trimmed
            }
        }
    }

    /// Auto-expand the title bar when a description transitions from empty → non-empty,
    /// unless the user has explicitly collapsed this surface in the current session.
    func maybeAutoExpandTitleBar(panelId: UUID) {
        guard !titleBarUserCollapsed.contains(panelId) else { return }
        if titleBarCollapsed[panelId] != false {
            titleBarCollapsed[panelId] = false
        }
    }

    /// Read the current M7 title-bar state for a surface as a SwiftUI view state.
    func tabTitleBarState(panelId: UUID) -> TabTitleBarState {
        // Sidebar-hot: called for every agent surface of every workspace on
        // each sidebar body evaluation. Ask for the two keys it reads rather
        // than a whole converted source map.
        let snapshot = TabMetadataStore.shared.getMetadata(
            workspaceId: id,
            surfaceId: panelId,
            keys: [MetadataKey.title, MetadataKey.description]
        )
        let title = snapshot.metadata[MetadataKey.title] as? String
        let description = snapshot.metadata[MetadataKey.description] as? String
        return TabTitleBarState(
            title: title,
            description: description,
            titleSource: Self.extractSource(snapshot.sources[MetadataKey.title]),
            descriptionSource: Self.extractSource(snapshot.sources[MetadataKey.description]),
            visible: titleBarVisible,
            collapsed: titleBarCollapsed[panelId] ?? true
        )
    }

    private static func extractSource(_ entry: [String: Any]?) -> MetadataSource? {
        guard let name = entry?["source"] as? String else { return nil }
        return MetadataSource(rawValue: name)
    }

    /// Toggle per-surface collapse. User-initiated toggles mark the surface so
    /// auto-expand no longer applies for the remainder of the session.
    func toggleSurfaceTitleBarCollapsed(panelId: UUID) {
        let current = titleBarCollapsed[panelId] ?? true
        titleBarCollapsed[panelId] = !current
        titleBarUserCollapsed.insert(panelId)
    }

    /// Read the current M7 title-bar state for a surface as a socket-ready dict.
    func titleBarStatePayload(panelId: UUID) -> [String: Any] {
        let snapshot = TabMetadataStore.shared.getMetadata(workspaceId: id, surfaceId: panelId)
        var payload: [String: Any] = [:]
        payload["surface_id"] = panelId.uuidString
        let descriptionString = snapshot.metadata[MetadataKey.description] as? String
        if let title = snapshot.metadata[MetadataKey.title] as? String {
            payload["title"] = title
            if let info = snapshot.sources[MetadataKey.title] {
                if let src = info["source"] { payload["title_source"] = src }
                if let ts = info["ts"] { payload["title_ts"] = ts }
            }
            payload["sidebar_label"] = TitleFormatting.sidebarLabel(from: title)
        }
        if let description = descriptionString {
            payload["description"] = description
            if let info = snapshot.sources[MetadataKey.description] {
                if let src = info["source"] { payload["description_source"] = src }
                if let ts = info["ts"] { payload["description_ts"] = ts }
            }
        }
        let collapsed = titleBarCollapsed[panelId] ?? true
        payload["collapsed"] = collapsed
        payload["effective_collapsed"] = collapsed || (descriptionString?.isEmpty ?? true)
        payload["visible"] = titleBarVisible
        return payload
    }

    /// Tier 1 Phase 2: re-install persisted metadata from a session snapshot
    /// after `restorePane` rebuilds the panel set. Silent — restore bypasses
    /// the precedence chain (the snapshot IS the prior session's source of
    /// truth). Runs before `pruneSurfaceMetadata` so anything not in the
    /// current panel set gets cleaned up on the same tick.
    /// Persisted-metadata marker written by builds that record launch-stamped
    /// models at the `heuristic` tier. Never enters the live store.
    nonisolated static let modelTieringMarkerKey = "c11.model_tiering"

    /// Snapshots written before launch stamps moved to the `heuristic` tier hold
    /// the launch's model at `declare`, which would outrank a detected model
    /// forever. A snapshot without the tiering marker predates the change, so its
    /// `model`/`model_label` are demoted to the launch-stamp tier. Later snapshots
    /// carry the marker and restore verbatim (an agent's own `set-agent --model`
    /// stays `declare`).
    nonisolated static func migrateLaunchStampTiers(
        values: inout [String: Any],
        sources: inout [String: TabMetadataStore.SourceRecord]
    ) {
        let migrated = values.removeValue(forKey: modelTieringMarkerKey) != nil
        sources.removeValue(forKey: modelTieringMarkerKey)
        guard !migrated else { return }
        for key in [MetadataKey.model, MetadataKey.modelLabel] {
            if let record = sources[key], record.source == .declare {
                sources[key] = TabMetadataStore.SourceRecord(source: .heuristic, ts: record.ts)
            }
        }
    }

    private func restoreSurfaceMetadataFromSnapshot(
        panels snapshotTabs: [SessionTabSnapshot]
    ) {
        for tabSnapshot in snapshotTabs {
            guard let persistedValues = tabSnapshot.metadata else { continue }
            let persistedSources = tabSnapshot.metadataSources ?? [:]
            let tabId = tabSnapshot.id
            guard panels[tabId] != nil else { continue }
            var values = PersistedMetadataBridge.decodeValues(persistedValues)
            var sources = PersistedMetadataBridge.decodeSources(persistedSources)
            // CMUX-10: persistent-flash timers are process-local and never
            // survive a restart. Drop any persisted `flash_state` entry on
            // restore so external agents reading `surface.get_metadata`
            // do not see an attention state with no live timer behind it.
            values.removeValue(forKey: FlashState.metadataKey)
            sources.removeValue(forKey: FlashState.metadataKey)
            Self.migrateLaunchStampTiers(values: &values, sources: &sources)
            // Persisted derived liveness is not evidence from this app instance.
            // Exact journal replay will repaint an unresolved ask asynchronously.
            if sources[MetadataKey.activity]?.source == .derived,
               tabSnapshot.surfaceConversations?.active?.isEligibleCausalOwner == true {
                values.removeValue(forKey: MetadataKey.activity)
                sources.removeValue(forKey: MetadataKey.activity)
            }
            TabMetadataStore.shared.restoreFromSnapshot(
                workspaceId: id,
                surfaceId: tabId,
                values: values,
                sources: sources
            )
            TabAttentionService.shared.syncFromMetadata(
                workspaceId: id,
                surfaceId: tabId
            )
            if let rawActivity = values[MetadataKey.activity] as? String,
               let activity = SidebarActivityState(rawValue: rawActivity) {
                derivedActivityByTab[tabId] = activity
            } else {
                derivedActivityByTab.removeValue(forKey: tabId)
            }
        }
    }

    /// CMUX-11 Phase 3: re-install persisted pane metadata after the layout
    /// is rebuilt. Each leaf entry pairs a freshly minted `PaneID` with the
    /// snapshot that created it; we rehydrate `PaneMetadataStore` under the
    /// new pane UUID, preserving the original `(source, ts)` records so the
    /// precedence chain survives the restart. Silent — same contract as the
    /// surface restore path.
    private func restoreAreaMetadataFromSnapshot(
        leafEntries: [SessionAreaRestoreEntry]
    ) {
        for entry in leafEntries {
            guard let persistedValues = entry.snapshot.metadata,
                  !persistedValues.isEmpty else { continue }
            let persistedSources = entry.snapshot.metadataSources ?? [:]
            // CMUX-11 Phase 3 acceptance: enforce the 64 KiB per-pane cap on
            // restore so a hand-edited or version-skewed snapshot cannot
            // rehydrate an over-cap blob and leave the live store violating
            // its own invariant. Drops largest-encoded keys first; survivors
            // dictate which sidecar entries we install.
            let cappedValues = PersistedMetadataBridge.enforceSizeCap(
                persistedValues,
                entityKind: "pane",
                entityId: entry.paneId.id
            )
            guard !cappedValues.isEmpty else { continue }
            let alignedSources = persistedSources.filter { cappedValues.keys.contains($0.key) }
            let values = PersistedMetadataBridge.decodeValues(cappedValues)
            let sources = PersistedMetadataBridge.decodeSources(alignedSources)
            AreaMetadataStore.shared.restoreFromSnapshot(
                workspaceId: id,
                paneId: entry.paneId.id,
                values: values,
                sources: sources
            )
        }
    }

    /// CMUX-11 Phase 3: drop pane metadata entries for panes no longer in the
    /// live set. Called from production session restore so a snapshot that
    /// loads with fewer panes than the live state (or a partially-failed
    /// restore) doesn't leave orphan rows in the singleton store. The
    /// DEBUG `debugForceMetadataSaveAndLoad` rail bypasses this path; it
    /// drains stale state by clearing per-pane before replay instead.
    func prunePaneMetadata(validPaneIds: Set<UUID>) {
        AreaMetadataStore.shared.pruneWorkspace(
            workspaceId: id,
            validPaneIds: validPaneIds
        )
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        tabDirectories = tabDirectories.filter { validSurfaceIds.contains($0.key) }
        tabTitles = tabTitles.filter { validSurfaceIds.contains($0.key) }
        tabCustomTitles = tabCustomTitles.filter { validSurfaceIds.contains($0.key) }
        tabCustomColors = tabCustomColors.filter { validSurfaceIds.contains($0.key) }
        pinnedTabIds = pinnedTabIds.filter { validSurfaceIds.contains($0) }
        manualUnreadTabIds = manualUnreadTabIds.filter { validSurfaceIds.contains($0) }
        tabGitBranches = tabGitBranches.filter { validSurfaceIds.contains($0.key) }
        tabGitContexts = tabGitContexts.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        tabListeningPorts = tabListeningPorts.filter { validSurfaceIds.contains($0.key) }
        tabTTYNames = tabTTYNames.filter { validSurfaceIds.contains($0.key) }
        tabShellActivityStates = tabShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        tabShellEdgeAt = tabShellEdgeAt.filter { validSurfaceIds.contains($0.key) }
        // TEL-4: drop derived-activity for surfaces that no longer exist so the
        // @Published map doesn't leak stale liveness for pruned surfaces.
        derivedActivityByTab = derivedActivityByTab.filter { validSurfaceIds.contains($0.key) }
        attentionByTab = attentionByTab.filter { validSurfaceIds.contains($0.key) }
        coldAgentSurfaceIds = coldAgentSurfaceIds.filter { validSurfaceIds.contains($0) }
        detectedTerminalTypesByTab = detectedTerminalTypesByTab.filter {
            validSurfaceIds.contains($0.key)
        }
        mailboxStdinBuffer.retainOnly(surfaceIds: validSurfaceIds)
        tabPullRequests = tabPullRequests.filter { validSurfaceIds.contains($0.key) }
        TabAttentionService.shared.prune(
            workspaceId: id,
            validSurfaceIds: validSurfaceIds
        )
        titleBarCollapsed = titleBarCollapsed.filter { validSurfaceIds.contains($0.key) }
        titleBarUserCollapsed = titleBarUserCollapsed.filter { validSurfaceIds.contains($0) }
        tabSheetStatusEntered = tabSheetStatusEntered.filter { validSurfaceIds.contains($0.key) }
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(tabListeningPorts.values.flatMap { $0 }).union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedTabIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { tabIdFromBonsplitTabId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: tabGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedTabIds())
    }

    // (C11-106) `sidebarBranchDirectoryEntriesInDisplayOrder` (both
    // overloads) was retired here. AC24 (C11-104) replaced the legacy
    // text branch+directory sidebar row with the worktree+branch chip
    // row; no production caller for these helpers survived. See the
    // dead-code-cleanup commit on this branch for the safety protocol
    // (grep → compile both `c11-logic` and `c11-unit` schemes → audit
    // snapshot-restore + persistence migration paths).

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = tabPullRequests.filter { panelId, state in
            guard let pullRequestBranch = normalizedSidebarBranchName(state.branch) else {
                return true
            }
            return normalizedSidebarBranchName(tabGitBranches[panelId]?.branch) == pullRequestBranch
        }
        return SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            tabPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedTabIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        statusEntries.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    var hasActiveRemoteTerminalSessions: Bool {
        activeRemoteTerminalSessionCount > 0
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
        } else {
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
        }
        return payload
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        remoteConfiguration = configuration
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        recomputeListeningPorts()

        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        guard autoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = WorkspaceRemoteSessionController(
            workspace: self,
            configuration: configuration,
            controllerID: controllerID
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        controller.start()
    }

    func reconnectRemoteConnection() {
        guard let configuration = remoteConfiguration else { return }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false) {
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        activeRemoteTerminalSurfaceIds.removeAll()
        activeRemoteTerminalSessionCount = 0
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionState = .disconnected
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            remoteConfiguration = nil
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
    }

    private func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard panels.isEmpty, remoteConfiguration != nil else { return }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    private func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalTab ? panelId : nil
        }
        guard terminalIds.count == 1, let initialPanelId = terminalIds.first else { return }
        trackRemoteTerminalSurface(initialPanelId)
    }

    private func trackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
    }

    private func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    private func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        let hasBrowserTabs = panels.values.contains { $0 is BrowserTab }
        if !hasBrowserTabs {
            if remoteConnectionState == .error || remoteDaemonStatus.state == .error || remoteConnectionState == .connecting {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?) {
        guard let relayPort,
              relayPort > 0,
              remoteConfiguration?.relayPort == relayPort else {
            return
        }
        untrackRemoteTerminalSurface(surfaceId)
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            state == .connecting && preservesSSHTerminalConnection && hasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if state == .error && proxyOnlyError && preservesSSHTerminalConnection {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = state
        }

        remoteConnectionState = effectiveState
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                AppDelegate.shared?.notificationStore?.addNotification(
                    workspaceId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail
                )
            }
            return
        }

        if !preserveConnectedStateForRetry && state != .error {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    fileprivate func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    fileprivate func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserTab = panel as? BrowserTab else { continue }
            browserTab.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    fileprivate func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    fileprivate func applyRemotePortsSnapshot(detected: [Int], forwarded: [Int], conflicts: [Int], target: String) {
        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    private func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
    }

    // MARK: - Panel Operations

    private func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: ghostty_surface_config_s?
    ) {
        guard let fontPoints = configTemplate?.font_size, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByTabId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    private func resolvedTerminalInheritanceFontPoints(
        for terminalTab: TerminalTab,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: ghostty_surface_config_s
    ) -> Float? {
        let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
        if let rooted = terminalInheritanceFontPointsByTabId[terminalTab.id], rooted > 0 {
            if let runtimePoints, abs(runtimePoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimePoints
            }
            return rooted
        }
        if inheritedConfig.font_size > 0 {
            return inheritedConfig.font_size
        }
        return runtimePoints
    }

    private func rememberTerminalConfigInheritanceSource(_ terminalTab: TerminalTab) {
        lastTerminalConfigInheritanceTabId = terminalTab.id
        if let sourceSurface = terminalTab.surface.surface,
           let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface) {
            let existing = terminalInheritanceFontPointsByTabId[terminalTab.id]
            if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
                terminalInheritanceFontPointsByTabId[terminalTab.id] = runtimePoints
            }
            lastTerminalConfigInheritanceFontPoints =
                terminalInheritanceFontPointsByTabId[terminalTab.id] ?? runtimePoints
        }
    }

    func lastRememberedTerminalTabForConfigInheritance() -> TerminalTab? {
        guard let panelId = lastTerminalConfigInheritanceTabId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    private func terminalTabConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalTab] {
        var candidates: [TerminalTab] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalTab?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedTabId = tabIdFromBonsplitTabId(selectedSurfaceId),
           let selectedTerminalTab = terminalPanel(for: selectedTabId) {
            appendCandidate(selectedTerminalTab)
        }

        if let focusedTerminalTab {
            appendCandidate(focusedTerminalTab)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalTabForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for bonsplitTab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalTab })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalTabForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalTab? {
        terminalTabConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    private func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> ghostty_surface_config_s? {
        // Walk candidates in priority order and use the first panel with a live surface.
        // This avoids returning nil when the top candidate exists but is not attached yet.
        for terminalPanel in terminalTabConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            guard let sourceSurface = terminalPanel.surface.surface else { continue }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.font_size = rootedFontPoints
                terminalInheritanceFontPointsByTabId[terminalPanel.id] = rootedFontPoints
            }
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.font_size > 0 {
                lastTerminalConfigInheritanceFontPoints = config.font_size
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = ghostty_surface_config_new()
            config.font_size = fallbackFontPoints
#if DEBUG
            dlog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontPoints))"
            )
#endif
            return config
        }

        return nil
    }

    // MARK: - Size-aware split policy

    /// The result of evaluating a split request against the active size policy.
    struct SplitSizeEvaluation {
        let decision: AreaSizePolicy.Decision
        /// The pane that would be split — the fallback target when the decision is `addTab`.
        let targetPaneId: PaneID
        let sourceKind: String?
        let kindLabel: String
    }

    /// Read a surface's declared `terminal_type` (canonical metadata key), if any.
    func surfaceTerminalKind(panelId: UUID) -> String? {
        TabMetadataStore.shared.metadataValue(
            workspaceId: id,
            surfaceId: panelId,
            key: MetadataKey.terminalType
        ) as? String
    }

    /// Terminal kind used only for live agent-state presentation.
    ///
    /// A detected shell means the prior agent process exited, so the surface
    /// is now an ordinary terminal even though its durable resume identity is
    /// retained. A recognized agent classification wins. Unknown child
    /// commands fall back to the durable declaration to avoid roster flicker.
    func surfaceActivityTerminalKind(panelId: UUID) -> String? {
        TabActivityTerminalKindResolver.resolve(
            detectedTerminalType: detectedTerminalTypesByTab[panelId],
            declaredTerminalType: surfaceTerminalKind(panelId: panelId)
        )
    }

    /// Optional per-surface minimum override (`min_cols` / `min_rows` metadata) —
    /// lets a status strip or log tail declare itself usable smaller than its kind default.
    private func surfaceMinCellsOverride(panelId: UUID) -> (cols: Int?, rows: Int?) {
        let md = TabMetadataStore.shared.getMetadata(workspaceId: id, surfaceId: panelId).metadata
        func intVal(_ key: String) -> Int? {
            if let i = md[key] as? Int { return i }
            if let n = md[key] as? NSNumber { return n.intValue }
            if let s = md[key] as? String { return Int(s) }
            return nil
        }
        return (intVal("min_cols"), intVal("min_rows"))
    }

    /// The source pane's current font cell size **in points**, falling back to a
    /// default when the surface has not reported metrics yet or is not a terminal.
    ///
    /// Ghostty reports the cell size in backing pixels, while pane frames from
    /// `layoutSnapshot()` are in AppKit points, so divide by the backing scale
    /// factor to keep the two in the same unit before deriving columns × rows.
    private func sourceCellSize(panelId: UUID) -> CGSize {
        guard let host = terminalPanel(for: panelId)?.hostedView else {
            return AreaSizePolicy.fallbackCellSize
        }
        let cs = host.cellSize
        guard cs.width > 0, cs.height > 0 else { return AreaSizePolicy.fallbackCellSize }
        let scale = host.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let s = scale > 0 ? scale : 2.0
        return CGSize(width: cs.width / s, height: cs.height / s)
    }

    /// Evaluate a split request against the active size policy. Returns nil when the
    /// pane's geometry is not yet known (no layout) — callers should then proceed
    /// without size enforcement rather than block.
    func evaluateSplitSize(
        sourcePanelId: UUID,
        requested: SplitAxis,
        newIsTerminal: Bool,
        force: Bool
    ) -> SplitSizeEvaluation? {
        guard let paneId = paneIdForTab(sourcePanelId) else { return nil }
        let snapshot = bonsplitController.layoutSnapshot()
        guard let geom = snapshot.panes.first(where: { $0.paneId == paneId.id.uuidString }) else {
            return nil
        }
        let frame = CGSize(width: geom.frame.width, height: geom.frame.height)
        guard frame.width > 0, frame.height > 0 else { return nil }

        let kind = surfaceTerminalKind(panelId: sourcePanelId)
        let cell = sourceCellSize(panelId: sourcePanelId)

        // Existing child keeps the source kind (with optional metadata override).
        let baseMin = AreaSizePolicy.minCells(forKind: kind)
        let (ovCols, ovRows) = surfaceMinCellsOverride(panelId: sourcePanelId)
        let minCells = AreaCellSize(cols: ovCols ?? baseMin.cols, rows: ovRows ?? baseMin.rows)
        let minExistingPts = AreaSizePolicy.points(minCells, cellSize: cell)

        // New child: a terminal split inherits the source kind (the orchestrator
        // fan-out case — every spawned agent pane must stay usable); a browser /
        // markdown pane uses the point floor.
        let minNewPts: CGSize
        if newIsTerminal {
            minNewPts = minExistingPts
        } else {
            minNewPts = CGSize(
                width: max(minExistingPts.width, AreaSizePolicy.nonTerminalMinPoints.width),
                height: max(minExistingPts.height, AreaSizePolicy.nonTerminalMinPoints.height)
            )
        }
        let minPts = CGSize(
            width: max(minExistingPts.width, minNewPts.width),
            height: max(minExistingPts.height, minNewPts.height)
        )

        let decision = AreaSizePolicy.decide(
            paneFrame: frame,
            requested: requested,
            minPoints: minPts,
            mode: AreaSizeSettings.effectiveMode(),
            force: force
        )
        return SplitSizeEvaluation(
            decision: decision,
            targetPaneId: paneId,
            sourceKind: kind,
            kindLabel: AreaSizePolicy.kindLabel(forKind: kind)
        )
    }

    /// Create a new split with a terminal panel.
    ///
    /// If `workingDirectory` is provided and non-empty, it wins over the
    /// workspace root and the source panel's cwd (see
    /// `newSurfaceWorkingDirectory`). `WorkspaceLayoutExecutor` uses it to honor
    /// explicit `SurfaceSpec.workingDirectory` values in a `WorkspaceApplyPlan`.
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialInput: String? = nil
    ) -> TerminalTab? {
        guard let paneId = paneIdForTab(panelId) else { return nil }
        let inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()

        // One cwd rule for every new surface (C11-238): caller override, then
        // the workspace root, then the source panel's cwd, then home.
        let cwdResolution = newSurfaceWorkingDirectory(explicit: workingDirectory, sourcePanelId: panelId)
        let splitWorkingDirectory = cwdResolution.path
#if DEBUG
        dlog(
            "split.cwd panelId=\(panelId.uuidString.prefix(5)) source=\(cwdResolution.source?.rawValue ?? "home") root=\(rootDirectory ?? "nil") resolved=\(splitWorkingDirectory)"
        )
#endif

        // Create the new terminal panel.
        let newTab = TerminalTab(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: splitWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: remoteTerminalStartupCommand,
            initialInput: initialInput
        )
        panels[newTab.id] = newTab
        tabTitles[newTab.id] = newTab.displayTitle
        if remoteTerminalStartupCommand != nil {
            trackRemoteTerminalSurface(newTab.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newTab.id, configTemplate: inheritedConfig)

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newBonsplitTab = Bonsplit.Tab(
            title: newTab.displayTitle,
            icon: newTab.displayIcon,
            kind: TabKind.terminal,
            isDirty: newTab.isDirty,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: newTab.id)
        )
        bonsplitTabIdToTabId[newBonsplitTab.id] = newTab.id
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalTab?.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newBonsplitTab, insertFirst: insertFirst) != nil else {
            panels.removeValue(forKey: newTab.id)
            tabTitles.removeValue(forKey: newTab.id)
            bonsplitTabIdToTabId.removeValue(forKey: newBonsplitTab.id)
            if remoteTerminalStartupCommand != nil {
                untrackRemoteTerminalSurface(newTab.id)
            }
            terminalInheritanceFontPointsByTabId.removeValue(forKey: newTab.id)
            return nil
        }

#if DEBUG
        dlog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
#endif

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(newTab.id, previousHostedView: previousHostedView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newTab.id,
                previousHostedView: previousHostedView
            )
        }

        return newTab
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        initialInput: String? = nil,
        startupEnvironment: [String: String] = [:],
        panelId: UUID? = nil,
        createdAt: Date? = Date()
    ) -> TerminalTab? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalTab?.hostedView

        // The pane's own terminal is the tier-3 source, matching the config
        // inheritance source. Resolve before `inheritedTerminalConfig`, which
        // records the inheritance source as a side effect.
        let cwdSourcePanelId = terminalTabForConfigInheritance(inPane: paneId)?.id
        let resolvedWorkingDirectory = newSurfaceWorkingDirectory(
            explicit: workingDirectory,
            sourcePanelId: cwdSourcePanelId
        ).path
        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()

        // Create new terminal panel
        let newTab = TerminalTab(
            id: panelId,
            createdAt: createdAt,
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: resolvedWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: remoteTerminalStartupCommand,
            initialInput: initialInput,
            additionalEnvironment: startupEnvironment
        )
        panels[newTab.id] = newTab
        tabTitles[newTab.id] = newTab.displayTitle
        if remoteTerminalStartupCommand != nil {
            trackRemoteTerminalSurface(newTab.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newTab.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        guard let newBonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: newTab.displayTitle),
            icon: newTab.displayIcon,
            kind: TabKind.terminal,
            isDirty: newTab.isDirty,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: newTab.id),
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newTab.id)
            tabTitles.removeValue(forKey: newTab.id)
            if remoteTerminalStartupCommand != nil {
                untrackRemoteTerminalSurface(newTab.id)
            }
            terminalInheritanceFontPointsByTabId.removeValue(forKey: newTab.id)
            return nil
        }

        bonsplitTabIdToTabId[newBonsplitTabId] = newTab.id

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newBonsplitTabId)
            newTab.focus()
            applyTabSelection(bonsplitTabId: newBonsplitTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newTab.id,
                previousHostedView: previousHostedView
            )
        }
        return newTab
    }

    private func remoteTerminalStartupCommand() -> String? {
        guard let command = remoteConfiguration?.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }

    /// C11-238: the one cwd rule for every new terminal surface in this
    /// workspace (tab, split, agent button, socket/CLI, repair paths).
    /// Precedence: explicit cwd, then the workspace root (skipped when it is no
    /// longer a directory), then the source surface's cwd (the focused surface
    /// when no source is named), then home. Always yields a path, so Ghostty's
    /// inherited config never picks the cwd of a new surface.
    func newSurfaceWorkingDirectory(
        explicit: String?,
        sourcePanelId: UUID?
    ) -> (path: String, source: AgentLaunchWorkingDirectorySource?) {
        // Only stat the root when it can win: an explicit cwd outranks it, and
        // restore and layout specs pass one for every surface they create.
        let hasExplicit = !(explicit?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let usableRoot = hasExplicit ? nil : Self.usableRootDirectory(rootDirectory)
#if DEBUG
        if !hasExplicit, usableRoot == nil, let rootDirectory {
            dlog("workspace.root.missing workspace=\(id.uuidString.prefix(5)) root=\(rootDirectory)")
        }
#endif
        let resolution = AgentLaunchWorkingDirectoryResolver.resolve(
            explicitCwd: explicit,
            workspaceRoot: usableRoot,
            launchingSurfaceCwd: hasExplicit ? nil : inheritedCwdForAgentLaunch(callerTabId: sourcePanelId)
        )
        return (
            resolution.path ?? FileManager.default.homeDirectoryForCurrentUser.path,
            resolution.source
        )
    }

    /// The cwd the tab-bar agent button and `default-agent launch` start a new
    /// agent in (the pane's terminal is the tier-3 source). Side-effect free,
    /// unlike the launch itself, so the A-button rail is testable.
    func agentLaunchWorkingDirectory(inPane pane: PaneID, explicit: String?) -> String {
        newSurfaceWorkingDirectory(
            explicit: explicit,
            sourcePanelId: terminalTabForConfigInheritance(inPane: pane)?.id
        ).path
    }

    /// The cwd inherited by a socket-launched agent. Prefer the exact calling
    /// surface when the CLI supplied its runtime identity; otherwise use the
    /// focused terminal. Shell-reported cwd wins over the requested startup cwd,
    /// with the workspace's last-known directory as the compatibility fallback.
    func inheritedCwdForAgentLaunch(callerTabId: UUID?) -> String? {
        let candidateId = callerTabId ?? focusedPanelId
        if let candidateId {
            if let reported = tabDirectories[candidateId]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !reported.isEmpty {
                return reported
            }
            if let requested = terminalPanel(for: candidateId)?
                .requestedWorkingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !requested.isEmpty {
                return requested
            }
        }
        let fallback = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    /// Create a new browser panel split
    /// - Parameter pendingHibernate: C11-25 fix S4+E1. When `true`, the
    ///   panel is constructed natively in `.hibernated` and the initial
    ///   URL navigate is suppressed. Used by `c11 restore` when the plan
    ///   declares `lifecycle_state == "hibernated"` for the surface.
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        sticksAsPreferred: Bool = true,
        focus: Bool = true,
        bypassInsecureHTTPHostOnce: String? = nil,
        pendingHibernate: Bool = false
    ) -> BrowserTab? {
        guard let paneId = paneIdForTab(panelId) else { return nil }

        // Create browser panel
        let browserTab = BrowserTab(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: panelId
            ),
            sticksAsPreferred: sticksAsPreferred,
            initialURL: url,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
            pendingHibernate: pendingHibernate
        )
        panels[browserTab.id] = browserTab
        tabTitles[browserTab.id] = browserTab.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newBonsplitTab = Bonsplit.Tab(
            title: browserTab.displayTitle,
            icon: browserTab.displayIcon,
            kind: TabKind.browser,
            isDirty: browserTab.isDirty,
            isLoading: browserTab.isLoading,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: browserTab.id)
        )
        bonsplitTabIdToTabId[newBonsplitTab.id] = browserTab.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newBonsplitTab, insertFirst: insertFirst) != nil else {
            bonsplitTabIdToTabId.removeValue(forKey: newBonsplitTab.id)
            panels.removeValue(forKey: browserTab.id)
            tabTitles.removeValue(forKey: browserTab.id)
            return nil
        }
        if browserTab.sticksAsPreferred {
            setPreferredBrowserProfileID(browserTab.profileID)
        }

        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalTab?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(browserTab.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserTab.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserTabSubscription(browserTab)
        browserTab.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserTab
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    /// - Parameter pendingHibernate: C11-25 fix S4+E1. When `true`, the
    ///   panel is constructed natively in `.hibernated` and the initial
    ///   URL navigate is suppressed. Used by `c11 restore` when the plan
    ///   declares `lifecycle_state == "hibernated"` for the surface.
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        preferredProfileID: UUID? = nil,
        sticksAsPreferred: Bool = true,
        bypassInsecureHTTPHostOnce: String? = nil,
        panelId: UUID? = nil,
        pendingHibernate: Bool = false,
        createdAt: Date? = Date()
    ) -> BrowserTab? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let sourcePanelId = effectiveSelectedTabId(inPane: paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalTab?.hostedView

        let browserTab = BrowserTab(
            id: panelId,
            createdAt: createdAt,
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            sticksAsPreferred: sticksAsPreferred,
            initialURL: url,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
            pendingHibernate: pendingHibernate
        )
        panels[browserTab.id] = browserTab
        tabTitles[browserTab.id] = browserTab.displayTitle

        guard let newBonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: browserTab.displayTitle),
            icon: browserTab.displayIcon,
            kind: TabKind.browser,
            isDirty: browserTab.isDirty,
            isLoading: browserTab.isLoading,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: browserTab.id),
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserTab.id)
            tabTitles.removeValue(forKey: browserTab.id)
            return nil
        }

        bonsplitTabIdToTabId[newBonsplitTabId] = browserTab.id
        if browserTab.sticksAsPreferred {
            setPreferredBrowserProfileID(browserTab.profileID)
        }

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            // Bonsplit takes an insertion index before removing the source tab.
            let targetIndex = bonsplitController.tabs(inPane: paneId).count
            _ = bonsplitController.reorderTab(newBonsplitTabId, toIndex: targetIndex)
        }

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newBonsplitTabId)
            browserTab.focus()
            applyTabSelection(bonsplitTabId: newBonsplitTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserTab.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserTabSubscription(browserTab)
        browserTab.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserTab
    }

    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String? = nil,
        focus: Bool = true
    ) -> MarkdownTab? {
        guard let paneId = paneIdForTab(panelId) else { return nil }

        let markdownTab = MarkdownTab(workspaceId: id, filePath: filePath)
        panels[markdownTab.id] = markdownTab
        tabTitles[markdownTab.id] = markdownTab.displayTitle

        let newBonsplitTab = Bonsplit.Tab(
            title: markdownTab.displayTitle,
            icon: markdownTab.displayIcon,
            kind: TabKind.markdown,
            isDirty: markdownTab.isDirty,
            isLoading: false,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: markdownTab.id)
        )
        bonsplitTabIdToTabId[newBonsplitTab.id] = markdownTab.id
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newBonsplitTab, insertFirst: insertFirst) != nil else {
            bonsplitTabIdToTabId.removeValue(forKey: newBonsplitTab.id)
            panels.removeValue(forKey: markdownTab.id)
            tabTitles.removeValue(forKey: markdownTab.id)
            return nil
        }

        let previousHostedView = focusedTerminalTab?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(markdownTab.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownTab.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownTabSubscription(markdownTab)
        return markdownTab
    }

    @discardableResult
    func newMarkdownTab(
        inPane paneId: PaneID,
        filePath: String? = nil,
        focus: Bool? = nil,
        panelId: UUID? = nil,
        createdAt: Date? = Date()
    ) -> MarkdownTab? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalTab?.hostedView

        let markdownTab = MarkdownTab(
            id: panelId,
            createdAt: createdAt,
            workspaceId: id,
            filePath: filePath
        )
        panels[markdownTab.id] = markdownTab
        tabTitles[markdownTab.id] = markdownTab.displayTitle

        guard let newBonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: markdownTab.displayTitle),
            icon: markdownTab.displayIcon,
            kind: TabKind.markdown,
            isDirty: markdownTab.isDirty,
            isLoading: false,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: markdownTab.id),
            inPane: paneId
        ) else {
            panels.removeValue(forKey: markdownTab.id)
            tabTitles.removeValue(forKey: markdownTab.id)
            return nil
        }

        bonsplitTabIdToTabId[newBonsplitTabId] = markdownTab.id
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newBonsplitTabId)
            applyTabSelection(bonsplitTabId: newBonsplitTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownTab.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownTabSubscription(markdownTab)
        return markdownTab
    }

    /// Tear down all panels in this workspace, freeing their Ghostty surfaces.
    /// Called before the workspace is removed from TabManager to ensure child
    /// processes receive SIGHUP even if ARC deallocation is delayed.
    func teardownAllPanels() {
        // Drain every pending pane interaction with .dismissed FIRST so any
        // in-flight presentConfirmClose / presentTextInput / socket pane.confirm
        // continuation resumes before the panel state disappears. Skipping this
        // leaks CheckedContinuations and blocks socket worker threads forever
        // (synthesis-standard §1.1, synthesis-critical §1.3).
        paneInteractionRuntime.clearAll()
        areaCloseInteractionRuntime.clearAll()
        areaCloseOverlayController.cleanup()
        workspaceCloseInteractionRuntime.clear()
        workspaceCloseOverlayController.cleanup()

        // CMUX-10: cancel every persistent-flash timer + manifest entry so
        // teardown does not leak repeating timers or stale `flash_state`
        // metadata. Must precede `panels.removeAll` since the cancel path
        // is keyed on panel id.
        cancelAllPersistentFlashes()

        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            tabSubscriptions.removeValue(forKey: panelId)
            PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            AgentDetector.shared.unregister(workspaceId: id, panelId: panelId)
            panel.close()
            // C11-243: workspace teardown; these panels are gone.
            TabSeenTracker.shared.forget(panelId: panelId)
        }

        panels.removeAll(keepingCapacity: false)
        bonsplitTabIdToTabId.removeAll(keepingCapacity: false)
        tabSubscriptions.removeAll(keepingCapacity: false)
        pruneSurfaceMetadata(validSurfaceIds: [])
        restoredTerminalScrollbackByTabId.removeAll(keepingCapacity: false)
        terminalInheritanceFontPointsByTabId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritanceTabId = nil
        lastTerminalConfigInheritanceFontPoints = nil
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closeTab(_ panelId: UUID, force: Bool = false) -> Bool {
        if let bonsplitTabId = bonsplitTabIdFromTabId(panelId) {
            if force {
                forceCloseBonsplitTabIds.insert(bonsplitTabId)
            }
            // Close the tab in bonsplit (this triggers delegate callback)
            return bonsplitController.closeTab(bonsplitTabId)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = cmuxOwningGhosttyView(
            for: NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        )?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            dlog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        if force {
            forceCloseBonsplitTabIds.insert(selected.id)
        }
        let closed = bonsplitController.closeTab(selected.id)
#if DEBUG
        dlog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0)"
        )
#endif
        return closed
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == bonsplitTabId })
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == bonsplitTabId })
    }

    /// Returns the nearest right-side sibling pane for browser placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = browserPathToArea(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    /// Returns the top-right pane in the current split tree.
    /// When a workspace is already split, sidebar PR opens should reuse an existing pane
    /// instead of creating additional right splits.
    func topRightBrowserReusePane() -> PaneID? {
        let paneIds = bonsplitController.allPaneIds
        guard paneIds.count > 1 else { return nil }

        let paneById = Dictionary(uniqueKeysWithValues: paneIds.map { ($0.id.uuidString, $0) })
        var paneBounds: [String: CGRect] = [:]
        browserCollectNormalizedPaneBounds(
            node: bonsplitController.treeSnapshot(),
            availableRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            into: &paneBounds
        )

        guard !paneBounds.isEmpty else {
            return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
        }

        let epsilon = 0.000_1
        let rightMostX = paneBounds.values.map(\.maxX).max() ?? 0

        let sortedCandidates = paneBounds
            .filter { _, rect in abs(rect.maxX - rightMostX) <= epsilon }
            .sorted { lhs, rhs in
                if abs(lhs.value.minY - rhs.value.minY) > epsilon {
                    return lhs.value.minY < rhs.value.minY
                }
                if abs(lhs.value.minX - rhs.value.minX) > epsilon {
                    return lhs.value.minX > rhs.value.minX
                }
                return lhs.key < rhs.key
            }

        for candidate in sortedCandidates {
            if let pane = paneById[candidate.key] {
                return pane
            }
        }

        return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    private enum BrowserAreaBranch {
        case first
        case second
    }

    private struct BrowserAreaBreadcrumb {
        let split: ExternalSplitNode
        let branch: BrowserAreaBranch
    }

    private func browserPathToArea(targetPaneId: String, node: ExternalTreeNode) -> [BrowserAreaBreadcrumb]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = browserPathToArea(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append(BrowserAreaBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = browserPathToArea(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append(BrowserAreaBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    private func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    private func browserCollectNormalizedPaneBounds(
        node: ExternalTreeNode,
        availableRect: CGRect,
        into output: inout [String: CGRect]
    ) {
        switch node {
        case .pane(let paneNode):
            output[paneNode.id] = availableRect
        case .split(let splitNode):
            let divider = min(max(splitNode.dividerPosition, 0), 1)
            let firstRect: CGRect
            let secondRect: CGRect

            if splitNode.orientation.lowercased() == "vertical" {
                // Stacked split: first = top, second = bottom
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width,
                    height: availableRect.height * divider
                )
                secondRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY + (availableRect.height * divider),
                    width: availableRect.width,
                    height: availableRect.height * (1 - divider)
                )
            } else {
                // Side-by-side split: first = left, second = right
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width * divider,
                    height: availableRect.height
                )
                secondRect = CGRect(
                    x: availableRect.minX + (availableRect.width * divider),
                    y: availableRect.minY,
                    width: availableRect.width * (1 - divider),
                    height: availableRect.height
                )
            }

            browserCollectNormalizedPaneBounds(node: splitNode.first, availableRect: firstRect, into: &output)
            browserCollectNormalizedPaneBounds(node: splitNode.second, availableRect: secondRect, into: &output)
        }
    }

    private struct BrowserCloseFallbackPlan {
        let orientation: SplitOrientation
        let insertFirst: Bool
        let anchorPaneId: UUID?
    }

    private func stageClosedBrowserRestoreSnapshotIfNeeded(for bonsplitTab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
              let browserPanel = browserPanel(for: panelId),
              let bonsplitTabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == bonsplitTab.id }) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: bonsplitTab.id)
            return
        }

        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let resolvedURL = browserPanel.currentURL
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))

        pendingClosedBrowserRestoreSnapshots[bonsplitTab.id] = ClosedBrowserTabRestoreSnapshot(
            workspaceId: id,
            url: resolvedURL,
            profileID: browserPanel.profileID,
            originalPaneId: pane.id,
            originalTabIndex: bonsplitTabIndex,
            fallbackSplitOrientation: fallbackPlan?.orientation,
            fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
            fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
        )
    }

    private func clearStagedClosedBrowserRestoreSnapshot(for bonsplitTabId: TabID) {
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: bonsplitTabId)
    }

    private func browserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> BrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: browserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: browserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.first) {
                return nested
            }
            return browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.second)
        }
    }

    private func browserPaneCenter(_ pane: ExternalPaneNode) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    private func browserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = browserPaneCenter(lhs)
                let rhsCenter = browserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(bonsplitTabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(bonsplitTabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int) -> Bool {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else { return false }
        guard bonsplitController.reorderTab(bonsplitTabId, toIndex: index) else { return false }

        if let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(bonsplitTabId: bonsplitTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachTab(panelId: UUID) -> DetachedTabTransfer? {
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else { return nil }
        guard panels[panelId] != nil else { return nil }
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        dlog(
            "split.detach.begin ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(bonsplitTabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(activeDetachCloseTransactions) " +
            "pendingDetached=\(pendingDetachedSurfaces.count)"
        )
#endif

        detachingBonsplitTabIds.insert(bonsplitTabId)
        forceCloseBonsplitTabIds.insert(bonsplitTabId)
        activeDetachCloseTransactions += 1
        defer { activeDetachCloseTransactions = max(0, activeDetachCloseTransactions - 1) }
        guard bonsplitController.closeTab(bonsplitTabId) else {
            detachingBonsplitTabIds.remove(bonsplitTabId)
            pendingDetachedSurfaces.removeValue(forKey: bonsplitTabId)
            forceCloseBonsplitTabIds.remove(bonsplitTabId)
#if DEBUG
            dlog(
                "split.detach.fail ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(bonsplitTabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        let detached = pendingDetachedSurfaces.removeValue(forKey: bonsplitTabId)
#if DEBUG
        dlog(
            "split.detach.end ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(bonsplitTabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
    }

    @discardableResult
    func attachDetachedTab(
        _ detached: DetachedTabTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
#if DEBUG
        let attachStart = ProcessInfo.processInfo.systemUptime
        dlog(
            "split.attach.begin ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0)"
        )
#endif
        guard bonsplitController.allPaneIds.contains(paneId) else {
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=invalidPane elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }
        guard panels[detached.panelId] == nil else {
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=panelExists elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        panels[detached.panelId] = detached.panel
        if let terminalTab = detached.panel as? TerminalTab {
            terminalTab.updateWorkspaceId(id)
        } else if let browserTab = detached.panel as? BrowserTab {
            browserTab.reattachToWorkspace(
                id,
                isRemoteWorkspace: isRemoteWorkspace,
                remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
                proxyEndpoint: remoteProxyEndpoint,
                remoteStatus: browserRemoteWorkspaceStatusSnapshot()
            )
            installBrowserTabSubscription(browserTab)
        }

        if let directory = detached.directory {
            tabDirectories[detached.panelId] = directory
        }
        if let cachedTitle = detached.cachedTitle {
            tabTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            tabCustomTitles[detached.panelId] = customTitle
        }
        if let customColor = detached.customColor {
            tabCustomColors[detached.panelId] = customColor
        } else {
            tabCustomColors.removeValue(forKey: detached.panelId)
        }
        if detached.isPinned {
            pinnedTabIds.insert(detached.panelId)
        } else {
            pinnedTabIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadTabIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadTabIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }
        if let terminalType = detached.terminalType {
            _ = TabMetadataStore.shared.setInternal(
                workspaceId: id,
                surfaceId: detached.panelId,
                key: MetadataKey.terminalType,
                value: terminalType,
                source: detached.terminalTypeSource ?? .heuristic
            )
        }
        if let entered = detached.tabSheetStatusEntered {
            tabSheetStatusEntered[detached.panelId] = entered
        }
        if let edge = detached.shellEdgeAt {
            tabShellEdgeAt[detached.panelId] = edge
        }
        if let derivedActivity = detached.derivedActivity {
            derivedActivityByTab[detached.panelId] = derivedActivity
            _ = TabMetadataStore.shared.setInternal(
                workspaceId: id,
                surfaceId: detached.panelId,
                key: MetadataKey.activity,
                value: derivedActivity.rawValue,
                source: detached.derivedActivitySource ?? .derived
            )
        } else {
            derivedActivityByTab.removeValue(forKey: detached.panelId)
        }
        let restoredAttention = TabAttentionSnapshot(
            workspaceId: id,
            surfaceId: detached.panelId,
            flagReason: detached.attention.flagReason,
            flagRaisedAt: detached.attention.flagRaisedAt,
            suppressed: detached.attention.suppressed
        )
        TabAttentionService.shared.restore(restoredAttention)
        if detached.isAgentCold {
            coldAgentSurfaceIds.insert(detached.panelId)
        } else {
            coldAgentSurfaceIds.remove(detached.panelId)
        }
        if let detectedTerminalType = detached.detectedTerminalType {
            detectedTerminalTypesByTab[detached.panelId] = detectedTerminalType
        } else {
            detectedTerminalTypesByTab.removeValue(forKey: detached.panelId)
        }

        guard let newBonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: detached.title),
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            showsNotificationBadge: detached.manuallyUnread,
            isLoading: detached.isLoading,
            isPinned: detached.isPinned,
            customColorHex: detached.customColor,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: detached.panelId),
            activityState: detached.activityState,
            activityPresentation: resolvedSurfaceTabActivityPresentation(
                panelId: detached.panelId,
                activityState: detached.activityState
            ),
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            tabDirectories.removeValue(forKey: detached.panelId)
            tabTitles.removeValue(forKey: detached.panelId)
            tabCustomTitles.removeValue(forKey: detached.panelId)
            tabCustomColors.removeValue(forKey: detached.panelId)
            pinnedTabIds.remove(detached.panelId)
            manualUnreadTabIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            derivedActivityByTab.removeValue(forKey: detached.panelId)
            coldAgentSurfaceIds.remove(detached.panelId)
            detectedTerminalTypesByTab.removeValue(forKey: detached.panelId)
            TabAttentionService.shared.remove(workspaceId: id, surfaceId: detached.panelId)
            tabSubscriptions.removeValue(forKey: detached.panelId)
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=createTabFailed elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        bonsplitTabIdToTabId[newBonsplitTabId] = detached.panelId
        if let index {
            _ = bonsplitController.reorderTab(newBonsplitTabId, toIndex: index)
        }
        syncPinnedStateForTab(newBonsplitTabId, panelId: detached.panelId)
        syncSurfaceTabActivityStateForTab(detached.panelId)
        normalizePinnedTabs(in: paneId)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newBonsplitTabId)
            detached.panel.focus()
            applyTabSelection(bonsplitTabId: newBonsplitTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

#if DEBUG
        dlog(
            "split.attach.end ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "tab=\(newBonsplitTabId.uuid.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5)) " +
            "index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: attachStart))"
        )
#endif
        return detached.panelId
    }
    // MARK: - Focus Management

    private func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView? = nil,
        trigger: FocusTabTrigger = .standard
    ) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let triggerLabel = trigger == .terminalFirstResponder ? "firstResponder" : "standard"
        dlog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane) trigger=\(triggerLabel)")
        FocusLogStore.shared.append(
            "Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane) trigger=\(triggerLabel)"
        )
#endif
        guard let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalTab?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == bonsplitTabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == bonsplitTabId
        }()
        let shouldSuppressReentrantRefocus = trigger == .terminalFirstResponder && selectionAlreadyConverged
#if DEBUG
        let targetPaneShort = targetPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let focusedPaneShort = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabShort = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        let currentPanelShort = currentlyFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.panel.begin workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) trigger=\(String(describing: trigger)) " +
            "targetPane=\(targetPaneShort) focusedPane=\(focusedPaneShort) selectedTab=\(selectedTabShort) " +
            "converged=\(selectionAlreadyConverged ? 1 : 0) " +
            "currentPanel=\(currentPanelShort)"
        )
        if shouldSuppressReentrantRefocus {
            dlog(
                "focus.panel.skipReentrant panel=\(panelId.uuidString.prefix(5)) " +
                "reason=firstResponderAlreadyConverged"
            )
        }
#endif

        if let targetPaneId, !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.focusPane workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(targetPaneId.id.uuidString.prefix(5))"
            )
#endif
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.selectTab workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) tab=\(bonsplitTabId.uuid.uuidString.prefix(5))"
            )
#endif
            bonsplitController.selectTab(bonsplitTabId)
        }

        if let targetPaneId {
            let activationIntent = panels[panelId]?.preferredFocusIntentForActivation()
            applyTabSelection(
                bonsplitTabId: bonsplitTabId,
                inPane: targetPaneId,
                reassertAppKitFocus: !shouldSuppressReentrantRefocus,
                focusIntent: activationIntent,
                previousTerminalHostedView: previousTerminalHostedView
            )
        }

        if let browserTab = panels[panelId] as? BrowserTab {
            maybeAutoFocusBrowserAddressBarOnTabFocus(browserTab, trigger: trigger)
        }

        if trigger == .terminalFirstResponder,
           panels[panelId] is TerminalTab {
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
        }
    }

    private func maybeAutoFocusBrowserAddressBarOnTabFocus(
        _ browserTab: BrowserTab,
        trigger: FocusTabTrigger
    ) {
        guard trigger == .standard else { return }
        guard !isCommandPaletteVisibleForWorkspaceWindow() else { return }
        guard !browserTab.shouldSuppressOmnibarAutofocus() else { return }
        guard browserTab.isShowingNewTabPage || browserTab.preferredURLStringForOmnibar() == nil else { return }

        _ = browserTab.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: browserTab.id)
    }

    private func isCommandPaletteVisibleForWorkspaceWindow() -> Bool {
        guard let app = AppDelegate.shared else {
            return false
        }

        if let manager = app.workspaceManagerFor(workspaceId: id),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func moveFocus(direction: NavigationDirection) {
        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let bonsplitTabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(bonsplitTabId: bonsplitTabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let bonsplitTabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(bonsplitTabId: bonsplitTabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let bonsplitTabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(bonsplitTabId: bonsplitTabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let bonsplitTabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < bonsplitTabs.count else { return }
        bonsplitController.selectTab(bonsplitTabs[index].id)

        if let bonsplitTabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(bonsplitTabId: bonsplitTabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let bonsplitTabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = bonsplitTabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let bonsplitTabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(bonsplitTabId: bonsplitTabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil) -> TerminalTab? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId, focus: focus)
    }

    @discardableResult
    func clearSplitZoom() -> Bool {
        bonsplitController.clearPaneZoom()
    }

    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool {
        let wasSplitZoomed = bonsplitController.isSplitZoomed
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        focusPanel(panelId)
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "workspace.toggleSplitZoom")
        if let browserPanel = browserPanel(for: panelId) {
            browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                inPane: paneId,
                reason: "workspace.toggleSplitZoom"
            )
        }
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.toggleSplitZoom",
            browserPanelId: browserPanel(for: panelId) != nil ? panelId : nil,
            browserExitFocusPanelId: (wasSplitZoomed && !bonsplitController.isSplitZoomed) ? panelId : nil,
            includeGeometry: true
        )
        return true
    }

    // MARK: - Context Menu Shortcuts

    static func buildContextMenuShortcuts() -> [TabContextAction: KeyboardShortcut] {
        var shortcuts: [TabContextAction: KeyboardShortcut] = [:]
        let mappings: [(TabContextAction, KeyboardShortcutSettings.Action)] = [
            (.rename, .renameTab),
            (.toggleZoom, .toggleSplitZoom),
            (.newTerminalToRight, .newSurface),
        ]
        for (contextAction, settingsAction) in mappings {
            let stored = KeyboardShortcutSettings.shortcut(for: settingsAction)
            if let key = stored.keyEquivalent {
                shortcuts[contextAction] = KeyboardShortcut(key, modifiers: stored.eventModifiers)
            }
        }
        // C11-26: ⌘W routes through AppDelegate's keyDown handler, not a
        // SwiftUI .keyboardShortcut on a Button. Surface the hint in the
        // context menu anyway so the gesture is discoverable. Hardcoded
        // because there's no KeyboardShortcutSettings.Action for it.
        shortcuts[.closeTab] = KeyboardShortcut("w", modifiers: .command)
        return shortcuts
    }

    /// Snapshot of the workspace tab color palette mapped into the Bonsplit
    /// menu shape. Built once at workspace init; the user-defaults-backed
    /// palette can grow during a session, but we accept the slight staleness
    /// here in exchange for not adding a defaults observer in slice 4. A
    /// follow-up can refresh this on UserDefaults change if needed.
    static func bonsplitTabColorPalette() -> [BonsplitTabColorMenuItem] {
        WorkspaceColorSettings.palette().map { entry in
            BonsplitTabColorMenuItem(
                id: entry.id,
                label: entry.name,
                hex: entry.hex
            )
        }
    }

    // MARK: - Flash/Notification Support

    /// CMUX-10: typed values for the `flash_state` surface-manifest key.
    /// The JSON wire format stays a plain string ("persistent"), so existing
    /// socket clients (CLI, Python e2e, agent polling) keep working unchanged.
    /// The enum exists only to narrow the in-process write/read sites so a
    /// future second state value cannot drift across call sites as a typo.
    enum FlashState: String {
        case persistent

        /// Manifest key under which the value is written. Centralized here so
        /// the start, cancel, and session-restore paths all reference the
        /// same constant instead of repeating the literal.
        static let metadataKey = "flash_state"
    }

    /// Single fan-out for a focus flash. Drives, in order:
    ///   (a) the targeted panel's pane-content flash (existing behavior),
    ///   (b) the Bonsplit tab strip — scrolls the matching tab into view and
    ///       plays a brief pulse on it (visual-only; selection is unchanged),
    ///   (c) the sidebar workspace row — gentle accent pulse so the operator
    ///       can locate the workspace at a glance even when viewing another.
    /// Gated on `NotificationPaneFlashSettings` so disabling the user-facing
    /// "Pane Flash" toggle silences all three channels consistently.
    func triggerFocusFlash(panelId: UUID) {
        triggerFocusFlash(panelId: panelId, appearance: FlashAppearance.current(envelope: .paneRing))
    }

    /// CMUX-10: variant that threads a per-call appearance (color override
    /// from the CLI / socket) through to the pane and sidebar render paths.
    /// Bonsplit's `flashTab` does not accept a color callback, so the tab-
    /// strip pulse stays on the bonsplit-internal accent and is intentionally
    /// not retinted here.
    func triggerFocusFlash(panelId: UUID, appearance: FlashAppearance, persistent: Bool = false) {
        guard NotificationAreaFlashSettings.isEnabled() else { return }

        // CMUX-10: persistent on the focused surface in the focused window
        // degrades to a one-shot. Persistence is "look at this when you
        // eventually look back" — meaningless when the operator is already
        // looking. The color override is still honored.
        if persistent && isFocusedTargetForPersistentFlash(panelId: panelId) {
            runFlashPulse(panelId: panelId, appearance: appearance)
            return
        }

        runFlashPulse(panelId: panelId, appearance: appearance)

        guard persistent else { return }

        // Replace any existing timer for this panel before installing a new one,
        // so back-to-back persistent triggers don't leak timers.
        if let existing = persistentFlashTabs[panelId] {
            existing.timer.invalidate()
        }

        let interval = appearance.envelope.duration + 0.6
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard var state = self.persistentFlashTabs[panelId] else { return }
                let now = Date()
                let lastEmittedAt = state.lastBreadcrumbAt ?? state.startedAt
                if state.lastBreadcrumbAt == nil || now.timeIntervalSince(lastEmittedAt) >= 60 {
                    sentryBreadcrumb("flash.persistent.tick", category: "flash", data: [
                        "panelId": panelId.uuidString,
                        "seconds_active": Int(now.timeIntervalSince(state.startedAt)),
                        "seconds_since_last_tick_breadcrumb": Int(now.timeIntervalSince(lastEmittedAt)),
                        "app_active": NSApp?.isActive ?? false
                    ])
                    state.lastBreadcrumbAt = now
                    self.persistentFlashTabs[panelId] = state
                }
                self.runFlashPulse(panelId: panelId, appearance: appearance)
            }
        }
        persistentFlashTabs[panelId] = PersistentFlashState(
            appearance: appearance,
            timer: timer,
            startedAt: Date(),
            lastBreadcrumbAt: nil
        )

        // Manifest overlay: write once on start so external agents asking
        // "is this surface still calling for attention?" can find out via
        // get-metadata without subscribing to per-frame state. Failure is
        // non-fatal (the timer still drives the visual pulse) but the
        // manifest contract is briefly out of sync, so log instead of
        // silently swallowing.
        do {
            try TabMetadataStore.shared.setMetadata(
                workspaceId: id,
                surfaceId: panelId,
                partial: [FlashState.metadataKey: FlashState.persistent.rawValue],
                mode: .merge,
                source: .declare
            )
        } catch {
#if DEBUG
            dlog("flash.manifest.set workspace=\(id.uuidString.prefix(8)) panel=\(panelId.uuidString.prefix(8)) error=\(error)")
#endif
        }
    }

    /// CMUX-10: clear a persistent flash on a single panel. Idempotent —
    /// safe to call from click-to-dismiss handlers without checking state.
    func cancelPersistentFlash(panelId: UUID) {
        guard let state = persistentFlashTabs.removeValue(forKey: panelId) else { return }
        state.timer.invalidate()
        do {
            try TabMetadataStore.shared.clearMetadata(
                workspaceId: id,
                surfaceId: panelId,
                keys: [FlashState.metadataKey],
                source: .declare
            )
        } catch {
#if DEBUG
            dlog("flash.manifest.clear workspace=\(id.uuidString.prefix(8)) panel=\(panelId.uuidString.prefix(8)) error=\(error)")
#endif
        }
    }

    /// CMUX-10: clear all persistent flashes on this workspace. Used by the
    /// sidebar-row tap-to-dismiss path so clicking a workspace clears any
    /// pending persistent flashes inside it.
    func cancelAllPersistentFlashes() {
        guard !persistentFlashTabs.isEmpty else { return }
        let panelIds = Array(persistentFlashTabs.keys)
        for panelId in panelIds {
            cancelPersistentFlash(panelId: panelId)
        }
    }

    /// CMUX-10: shared fan-out used by both one-shot and persistent flash
    /// pulses. Stays small to keep pulse-firing predictable; lifecycle and
    /// timer management live in `triggerFocusFlash` / `cancelPersistentFlash`.
    private func runFlashPulse(panelId: UUID, appearance: FlashAppearance) {
        panels[panelId]?.triggerFlash(appearance: appearance)
        if let bonsplitTabId = bonsplitTabIdFromTabId(panelId) {
            bonsplitController.flashTab(bonsplitTabId)
        }
        // CMUX-10: thread the per-call appearance into the sidebar pulse so
        // `--color` tints the workspace row, not just the terminal pane ring.
        // Stored as a hex string so `TabItemView.==` can fold it in without
        // tripping NSColor reference equality.
        sidebarFlashColorHex = appearance.color.hexString(includeAlpha: true)
        sidebarFlashToken &+= 1
    }

    /// CMUX-10: true when a persistent-flash request would target the panel
    /// the operator is already looking at — i.e. this workspace is selected,
    /// the panel is the focused panel, and the focused window owns the app.
    /// Used to degrade `--persistent` to a one-shot pulse in that case.
    private func isFocusedTargetForPersistentFlash(panelId: UUID) -> Bool {
        guard let workspaceManager = AppDelegate.shared?.workspaceManager else { return false }
        guard workspaceManager.selectedWorkspaceId == self.id else { return false }
        guard self.focusedPanelId == panelId else { return false }
        guard NSApp.isActive else { return false }
        return true
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard terminalPanel(for: panelId) != nil else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        triggerFocusFlash(panelId: panelId)
    }

    func triggerDebugFlash(panelId: UUID) {
        triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: true)
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalTab else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    func hideAllBrowserPortalViews() {
        for panel in panels.values {
            guard let browser = panel as? BrowserTab else { continue }
            browser.hideBrowserPortalView(source: "workspaceRetire")
        }
    }

    // MARK: - Utility

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalTab() -> TerminalTab {
        let workingDirectory = newSurfaceWorkingDirectory(explicit: nil, sourcePanelId: focusedPanelId).path
        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        let newTab = TerminalTab(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal
        )
        panels[newTab.id] = newTab
        tabTitles[newTab.id] = newTab.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newTab.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        if let newBonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: newTab.displayTitle),
            icon: newTab.displayIcon,
            kind: TabKind.terminal,
            isDirty: newTab.isDirty,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: newTab.id)
        ) {
            bonsplitTabIdToTabId[newBonsplitTabId] = newTab.id
        }

        return newTab
    }

    /// Whether closing this whole workspace asks first. Only a lone idle
    /// terminal closes without asking; a pinned workspace, several surfaces,
    /// a browser or markdown surface, or anything running all ask, because
    /// a closed workspace cannot be reopened.
    func needsConfirmCloseWorkspace() -> Bool {
        if isPinned { return true }
        guard panels.count == 1, panels.values.first is TerminalTab else { return true }
        return needsConfirmClose()
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for (panelId, panel) in panels {
            if let terminalTab = panel as? TerminalTab,
               tabNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalTab.needsConfirmClose()) {
                return true
            }
        }
        return false
    }

    private func reconcileFocusState() {
        guard isSelectedInOwningWindowForReconciliation, !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedBonsplitTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedTabId = tabIdFromBonsplitTabId(focusedBonsplitTab.id),
           panels[mappedTabId] != nil {
            targetPanelId = mappedTabId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedBonsplitTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedTabId = tabIdFromBonsplitTabId(selectedBonsplitTab.id),
                      panels[mappedTabId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedBonsplitTab.id)
                targetPanelId = mappedTabId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackBonsplitTabId = bonsplitTabIdFromTabId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackBonsplitTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackBonsplitTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalTab = targetPanel as? TerminalTab {
            terminalTab.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = tabDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = tabGitBranches[targetPanelId]
        pullRequest = tabPullRequests[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    private func scheduleFocusReconcile() {
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    private func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        layoutFollowUpReason = reason
        if let browserPanelId {
            layoutFollowUpBrowserTabId = browserPanelId
        }
        if let browserExitFocusPanelId {
            layoutFollowUpBrowserExitFocusTabId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusTabId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall count.
        // Incrementing the version causes old closures to exit early; clearing the flag
        // allows scheduleLayoutFollowUpAttempt() below to enqueue a fresh asyncAfter(0).
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false

        if layoutFollowUpTimeoutWorkItem == nil {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        // Defer the full-window layout flush until the current layout pass unwinds.
        // Structural callers can arrive from SwiftUI geometry updates, where a
        // synchronous displayIfNeeded() re-enters AppKit layout.
        scheduleLayoutFollowUpAttempt()
    }

    private func installLayoutFollowUpObservers() {
        guard layoutFollowUpTimeoutWorkItem == nil else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.wakeLayoutFollowUpForStructuralEvent()
        }

        // Do not observe NSWindow.didUpdateNotification: AppKit posts it on
        // every tracking tick (including terminal scroll), which previously
        // pumped the all-window flush for each tick. Structural observers below
        // plus the bounded retry loop provide convergence without that firehose.
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = $panels
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    private func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearLayoutFollowUp()
        }
        layoutFollowUpTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func clearLayoutFollowUp() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        layoutFollowUpTimeoutWorkItem = nil
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusTabId = nil
        layoutFollowUpBrowserTabId = nil
        layoutFollowUpBrowserExitFocusTabId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    /// Structural events are edge-triggered, so reset a pending stall backoff
    /// and run the next attempt promptly instead of letting the old delayed
    /// closure hold the follow-up open near its timeout.
    private func wakeLayoutFollowUpForStructuralEvent() {
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        layoutFollowUpStalledAttemptCount = 0
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        scheduleLayoutFollowUpAttempt()
    }

    private func scheduleLayoutFollowUpAttempt() {
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        let version = layoutFollowUpAttemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpAttemptVersion == version else { return }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    private func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    private func flushWorkspaceWindowLayouts() {
#if DEBUG
        let flushStart = CACurrentMediaTime()
        debugLayoutFlushCount &+= 1
        let flushCount = debugLayoutFlushCount
        let flushReason = layoutFollowUpReason ?? "nil"
        let windowCount = NSApp.windows.count
        // Measure at the actual flush boundary, including attempts that return
        // immediately after convergence. Attempt-only logs miss those flushes.
        defer {
            let flushMs = (CACurrentMediaTime() - flushStart) * 1000
            dlog(
                "ws.layoutFollowUp.flush workspace=\(id.uuidString) " +
                "count=\(flushCount) windows=\(windowCount) " +
                "flushMs=\(String(format: "%.3f", flushMs)) reason=\(flushReason)"
            )
        }
#endif
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    private func browserPortalAnchorReady(for browserTab: BrowserTab) -> Bool {
        let anchorView = browserTab.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    private func browserPortalReady(for browserTab: BrowserTab) -> Bool {
        browserPortalAnchorReady(for: browserTab) &&
            browserTab.webView.window != nil &&
            browserTab.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserTab.webView, boundTo: browserTab.portalAnchorView)
    }

    private func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId),
              let paneId = paneId(forPanelId: panelId),
              let bonsplitTabId = bonsplitTabIdFromTabId(panelId) else {
            return false
        }
        let selectionConverged =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == bonsplitTabId
        return !selectionConverged || !browserPortalAnchorReady(for: browserPanel)
    }

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusTabId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func browserPanelNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpBrowserTabId,
              let browserPanel = browserPanel(for: panelId) else {
            return false
        }
        return !browserPortalReady(for: browserPanel)
    }

    private func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutWorkItem != nil, !isAttemptingLayoutFollowUp else { return }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }
#if DEBUG
        let attemptStart = CACurrentMediaTime()
#endif

        flushWorkspaceWindowLayouts()
#if DEBUG
        let postFlushMs = (CACurrentMediaTime() - attemptStart) * 1000
#endif

        // A queued layout pass can outlive workspace selection. Keep background
        // geometry/startup work, but discard its obsolete first-responder intent.
        if !isSelectedInOwningWindowForReconciliation {
            layoutFollowUpTerminalFocusTabId = nil
            layoutFollowUpBrowserExitFocusTabId = nil
        }

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = browserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = layoutFollowUpBrowserExitFocusTabId != nil

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusTabId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusTabId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusTabId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()

        let reason = layoutFollowUpReason ?? "workspace.layout"
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
        let browserVisibilityPending = browserPortalVisibilityNeedsFollowUp()

        if let browserPanelId = layoutFollowUpBrowserTabId {
            if let browserPanel = browserPanel(for: browserPanelId) {
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let wasReady = browserPortalReady(for: browserPanel)
                if anchorReady && !wasReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
                }
                let isReady = browserPortalReady(for: browserPanel)
                if isReady,
                   (!wasReady || BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.containerHidden == true) {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                }
                if isReady {
                    layoutFollowUpBrowserTabId = nil
                }
            } else {
                layoutFollowUpBrowserTabId = nil
            }
        }

        if let browserExitFocusPanelId = layoutFollowUpBrowserExitFocusTabId {
            if browserSplitZoomExitFocusNeedsFollowUp(panelId: browserExitFocusPanelId) {
                if browserPanel(for: browserExitFocusPanelId) != nil {
                    focusPanel(browserExitFocusPanelId)
                    scheduleFocusReconcile()
                } else {
                    layoutFollowUpBrowserExitFocusTabId = nil
                }
            } else {
                layoutFollowUpBrowserExitFocusTabId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = layoutFollowUpBrowserExitFocusTabId != nil
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
        } else {
            layoutFollowUpStalledAttemptCount += 1
        }
        // Keep retrying while work remains, including on stall. The delay is
        // exponentially backed off to 250 ms and bounded by the two-second
        // follow-up timeout. Structural events preempt that backoff above.
        scheduleLayoutFollowUpAttempt()
#if DEBUG
        let totalMs = (CACurrentMediaTime() - attemptStart) * 1000
        dlog(
            "ws.layoutFollowUp.attempt workspace=\(id.uuidString.prefix(5)) " +
            "totalMs=\(String(format: "%.2f", totalMs)) " +
            "flushMs=\(String(format: "%.2f", postFlushMs)) " +
            "didMakeProgress=\(didMakeProgress ? 1 : 0) needsMoreWork=\(needsMoreWork ? 1 : 0) " +
            "stalled=\(layoutFollowUpStalledAttemptCount) reason=\(layoutFollowUpReason ?? "nil")"
        )
#endif
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false
#if DEBUG
        let passStart = CACurrentMediaTime()
        var refreshedCount = 0
        var skippedCount = 0
#endif

        // `attemptEventDrivenLayoutFollowUp` already flushes all window layouts via
        // `flushWorkspaceWindowLayouts()` before invoking this pass, so we do not re-flush
        // here. Phase 3 — removing the duplicate `layoutSubtreeIfNeeded` loop saves a
        // full-window layout pass on every reconcile attempt.

        for panel in panels.values {
            guard let terminalTab = panel as? TerminalTab else { continue }
            let hostedView = terminalTab.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalTab.surface.surface != nil
            let isAttached = terminalTab.surface.isViewInWindow && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalTab.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            //
            // Phase 3 — only refresh when the surface is actually attachable. The
            // `forceRefresh()` body already early-returns on detached / zero-bounds
            // views, but skipping the call entirely avoids the per-panel dlog
            // emission and the entry into the Ghostty C bridge during the cascade
            // of follow-up passes that fire on every workspace switch.
            if terminalTab.surface.surface != nil, isAttached, hasUsableBounds {
                terminalTab.surface.forceRefresh()
#if DEBUG
                refreshedCount += 1
#endif
            } else {
#if DEBUG
                skippedCount += 1
#endif
            }
            if terminalTab.surface.surface == nil, isAttached && hasUsableBounds {
                terminalTab.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }
#if DEBUG
        let passMs = (CACurrentMediaTime() - passStart) * 1000
        dlog(
            "ws.geometryReconcile.pass workspace=\(id.uuidString.prefix(5)) " +
            "ms=\(String(format: "%.2f", passMs)) refreshed=\(refreshedCount) skipped=\(skippedCount) " +
            "needsFollowUp=\(needsFollowUpPass ? 1 : 0)"
        )
#endif

        return needsFollowUpPass
    }

    private func scheduleTerminalGeometryReconcile() {
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.geometry",
            includeGeometry: true
        )
    }

    private var isSelectedInOwningWindowForReconciliation: Bool {
        // The active app manager may belong to a different window. Resolve this
        // workspace's owner, including registered-window fallback during moves.
        guard let manager = owningWorkspaceManager ?? AppDelegate.shared?.workspaceManagerFor(workspaceId: id) else {
            return false
        }
        return manager.selectedWorkspaceId == id
    }

#if DEBUG
    var debugLayoutFollowUpSnapshotForTesting: (flushCount: UInt64, active: Bool) {
        (debugLayoutFlushCount, layoutFollowUpTimeoutWorkItem != nil)
    }

    func debugBeginDeferredLayoutFollowUpForTesting(includeGeometry: Bool = false) {
        beginEventDrivenLayoutFollowUp(reason: "test.deferred.layout", includeGeometry: includeGeometry)
    }

    func debugClearLayoutFollowUpForTesting() {
        clearLayoutFollowUp()
    }

    func debugRunLayoutFollowUpForTesting(terminalFocusPanelId: UUID? = nil) {
        beginEventDrivenLayoutFollowUp(
            reason: "test.workspace.layout",
            terminalFocusPanelId: terminalFocusPanelId
        )
        // Production callers observe the deferred attempt on the next run-loop
        // turn. This DEBUG-only seam intentionally drains one attempt directly
        // so its synchronous focus/visibility assertions keep their existing
        // contract without making the production begin path re-entrant again.
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        attemptEventDrivenLayoutFollowUp()
        reconcileFocusState()
    }
#endif

    private func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        // Bonsplit retains a selected tab in every hidden workspace. Those tabs
        // are not visible UI and must not be reactivated by delayed layout work.
        guard isSelectedInOwningWindowForReconciliation else { return [] }
        let renderedPaneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        var visiblePanelIds: Set<UUID> = []

        for paneId in renderedPaneIds {
            let selectedBonsplitTab = bonsplitController.selectedTab(inPane: paneId) ?? bonsplitController.tabs(inPane: paneId).first
            guard let selectedBonsplitTab,
                  let tabId = tabIdFromBonsplitTabId(selectedBonsplitTab.id),
                  panels[tabId] != nil else {
                continue
            }
            visiblePanelIds.insert(tabId)
        }

        if let focusedPanelId,
           panels[focusedPanelId] != nil,
           let focusedPaneId = paneId(forPanelId: focusedPanelId),
           renderedPaneIds.contains(where: { $0.id == focusedPaneId.id }) {
            visiblePanelIds.insert(focusedPanelId)
        }

        return visiblePanelIds
    }

    @discardableResult
    private func reconcileTerminalPortalVisibilityForCurrentRenderedLayout() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let terminalTab = panel as? TerminalTab else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalTab.id)
            if terminalTab.hostedView.debugPortalVisibleInUI != shouldBeVisible {
                terminalTab.hostedView.setVisibleInUI(shouldBeVisible)
                didChange = true
            }
            let shouldBeActive = shouldBeVisible && focusedPanelId == terminalTab.id
            if terminalTab.hostedView.debugPortalActive != shouldBeActive {
                terminalTab.hostedView.setActive(shouldBeActive)
                didChange = true
            }
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: terminalTab.hostedView,
                visibleInUI: shouldBeVisible
            )
        }

        return didChange
    }

    private func terminalPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let terminalTab = panel as? TerminalTab else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalTab.id)
            let hostedView = terminalTab.hostedView

            if shouldBeVisible {
                if hostedView.isHidden || !terminalTab.surface.isViewInWindow || hostedView.superview == nil {
                    return true
                }
            } else if !hostedView.isHidden {
                return true
            }
        }

        return false
    }

    @discardableResult
    private func reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: String) -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let browserTab = panel as? BrowserTab else { continue }
            let shouldBeVisible = visiblePanelIds.contains(browserTab.id)
            let anchorView = browserTab.portalAnchorView
            let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browserTab.webView)
            if shouldBeVisible {
                if snapshot?.visibleInUI == false {
                    BrowserWindowPortalRegistry.updateEntryVisibility(
                        for: browserTab.webView,
                        visibleInUI: true,
                        zPriority: 2
                    )
                    didChange = true
                }
                let anchorReady = browserPortalAnchorReady(for: browserTab)
                let portalReady = browserPortalReady(for: browserTab)
                if anchorReady && !portalReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(anchorView)
                    if browserPortalReady(for: browserTab) {
                        BrowserWindowPortalRegistry.refresh(
                            webView: browserTab.webView,
                            reason: reason
                        )
                        didChange = true
                    }
                } else if anchorReady && snapshot?.containerHidden == true {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserTab.webView,
                        reason: reason
                    )
                    didChange = true
                }
            } else {
                let portalNeedsHide =
                    snapshot?.visibleInUI == true ||
                    snapshot?.containerHidden == false
                if portalNeedsHide {
                    if snapshot?.visibleInUI == true {
                        BrowserWindowPortalRegistry.updateEntryVisibility(
                            for: browserTab.webView,
                            visibleInUI: false,
                            zPriority: 0
                        )
                    }
                    BrowserWindowPortalRegistry.hide(
                        webView: browserTab.webView,
                        source: reason
                    )
                    didChange = true
                }
            }
        }

        return didChange
    }

    private func browserPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let browserTab = panel as? BrowserTab else { continue }
            guard visiblePanelIds.contains(browserTab.id) else { continue }
            let anchorView = browserTab.portalAnchorView
            let anchorReady =
                anchorView.window != nil &&
                anchorView.superview != nil &&
                anchorView.bounds.width > 1 &&
                anchorView.bounds.height > 1
            if !anchorReady ||
                browserTab.webView.window == nil ||
                browserTab.webView.superview == nil ||
                !BrowserWindowPortalRegistry.isWebView(browserTab.webView, boundTo: anchorView) {
                return true
            }
        }

        return false
    }

    private func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                panel.hostedView.reconcileGeometryNow()
                if panel.surface.surface != nil {
                    panel.surface.forceRefresh()
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
    }

    private func closeTabs(_ bonsplitTabIds: [TabID], skipPinned: Bool = true) {
        for bonsplitTabId in bonsplitTabIds {
            if skipPinned,
               let panelId = tabIdFromBonsplitTabId(bonsplitTabId),
               pinnedTabIds.contains(panelId) {
                continue
            }
            _ = bonsplitController.closeTab(bonsplitTabId)
        }
    }

    private func bonsplitTabIdsToLeft(of anchorBonsplitTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let bonsplitTabs = bonsplitController.tabs(inPane: paneId)
        guard let index = bonsplitTabs.firstIndex(where: { $0.id == anchorBonsplitTabId }) else { return [] }
        return Array(bonsplitTabs.prefix(index).map(\.id))
    }

    private func bonsplitTabIdsToRight(of anchorBonsplitTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let bonsplitTabs = bonsplitController.tabs(inPane: paneId)
        guard let index = bonsplitTabs.firstIndex(where: { $0.id == anchorBonsplitTabId }),
              index + 1 < bonsplitTabs.count else { return [] }
        return Array(bonsplitTabs.suffix(from: index + 1).map(\.id))
    }

    private func bonsplitTabIdsToCloseOthers(of anchorBonsplitTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId)
            .map(\.id)
            .filter { $0 != anchorBonsplitTabId }
    }

    private func createTerminalToRight(of anchorBonsplitTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorBonsplitTabId, inPane: paneId)
        guard let newTab = newTerminalSurface(inPane: paneId, focus: true) else { return }
        _ = reorderSurface(panelId: newTab.id, toIndex: targetIndex)
    }

    private func createBrowserToRight(of anchorBonsplitTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorBonsplitTabId, inPane: paneId)
        let preferredProfileID = tabIdFromBonsplitTabId(anchorBonsplitTabId).flatMap { browserPanel(for: $0)?.profileID }
        guard let newTab = newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: preferredProfileID
        ) else { return }
        _ = reorderSurface(panelId: newTab.id, toIndex: targetIndex)
    }

    private func duplicateBrowserToRight(anchorBonsplitTabId: TabID, inPane paneId: PaneID) {
        guard let tabId = tabIdFromBonsplitTabId(anchorBonsplitTabId),
              let browser = browserPanel(for: tabId) else { return }
        let targetIndex = insertionIndexToRight(of: anchorBonsplitTabId, inPane: paneId)
        guard let newTab = newBrowserSurface(
            inPane: paneId,
            url: browser.currentURL,
            focus: true,
            preferredProfileID: browser.profileID
        ) else { return }
        _ = reorderSurface(panelId: newTab.id, toIndex: targetIndex)
    }

    private func promptRenamePanel(bonsplitTabId: TabID) {
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTabId),
              let panel = panels[panelId] else { return }
        let currentTitle = tabCustomTitles[panelId] ?? tabTitles[panelId] ?? panel.displayTitle

        if AreaInteractionFeatureFlag.isEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let value = await self.presentTextInput(
                    panelId: panelId,
                    title: String(
                        localized: "dialog.renameTab.title",
                        defaultValue: "Rename Tab"
                    ),
                    message: String(
                        localized: "dialog.renameTab.message",
                        defaultValue: "Any text works. Longer titles are easier to find when many tabs are open."
                    ),
                    defaultValue: currentTitle,
                    placeholder: String(
                        localized: "dialog.renameTab.placeholder",
                        defaultValue: "Tab name"
                    ),
                    confirmLabel: String(
                        localized: "alert.renameWorkspace.rename",
                        defaultValue: "Rename"
                    ),
                    validate: { _ in nil }
                )
                guard let value else { return }
                // Acceptance-time revalidation: the panel may have closed while the
                // card was visible between present and submit.
                guard self.panels[panelId] != nil else { return }
                self.setTabCustomTitle(panelId: panelId, title: value)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.renameTab.title",
            defaultValue: "Rename Tab"
        )
        alert.informativeText = String(
            localized: "dialog.renameTab.message",
            defaultValue: "Any text works. Longer titles are easier to find when many tabs are open."
        )
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(
            localized: "dialog.renameTab.placeholder",
            defaultValue: "Tab name"
        )
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(
            localized: "alert.renameWorkspace.rename",
            defaultValue: "Rename"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.pane.confirm.cancel",
            defaultValue: "Cancel"
        ))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setTabCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private enum TabMoveDestination {
        case newWorkspaceInCurrentWindow
        case selectedWorkspaceInNewWindow
        case existingWorkspace(UUID)
    }

    private func promptMovePanel(bonsplitTabId: TabID) {
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTabId),
              let app = AppDelegate.shared else { return }

        let currentWindowId = app.workspaceManagerFor(workspaceId: id).flatMap { app.windowId(for: $0) }
        let workspaceTargets = app.workspaceMoveTargets(
            excludingWorkspaceId: id,
            referenceWindowId: currentWindowId
        )

        var options: [(title: String, destination: TabMoveDestination)] = [
            ("New Workspace in Current Window", .newWorkspaceInCurrentWindow),
            ("Selected Workspace in New Window", .selectedWorkspaceInNewWindow),
        ]
        options.append(contentsOf: workspaceTargets.map { target in
            (target.label, .existingWorkspace(target.workspaceId))
        })

        let alert = NSAlert()
        alert.messageText = "Move Tab"
        alert.informativeText = "Choose a destination for this tab."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedIndex = max(0, min(popup.indexOfSelectedItem, options.count - 1))
        let destination = options[selectedIndex].destination

        let moved: Bool
        switch destination {
        case .newWorkspaceInCurrentWindow:
            guard let manager = app.workspaceManagerFor(workspaceId: id) else { return }
            let workspace = manager.addWorkspace(select: true)
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspace.id,
                focus: true,
                focusWindow: false
            )

        case .selectedWorkspaceInNewWindow:
            let newWindowId = app.createMainWindow()
            guard let destinationManager = app.workspaceManagerFor(windowId: newWindowId),
                  let destinationWorkspaceId = destinationManager.selectedWorkspaceId else {
                return
            }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: destinationWorkspaceId,
                focus: true,
                focusWindow: true
            )
            if !moved {
                _ = app.closeMainWindow(windowId: newWindowId)
            }

        case .existingWorkspace(let workspaceId):
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        }

        if !moved {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Move Failed"
            failure.informativeText = "cmux could not move this tab to the selected destination."
            failure.addButton(withTitle: "OK")
            _ = failure.runModal()
        }
    }

    private func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        guard let app = AppDelegate.shared else { return false }
#if DEBUG
        let dropStart = ProcessInfo.processInfo.systemUptime
#endif

        let targetPane: PaneID
        let targetIndex: Int?
        let splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
#if DEBUG
        let destinationLabel: String
#endif

        switch request.destination {
        case .insert(let paneId, let index):
            targetPane = paneId
            targetIndex = index
            splitTarget = nil
#if DEBUG
            destinationLabel = "insert pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil")"
#endif
        case .split(let paneId, let orientation, let insertFirst):
            targetPane = paneId
            targetIndex = nil
            splitTarget = (orientation, insertFirst)
#if DEBUG
            destinationLabel = "split pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation.rawValue) insertFirst=\(insertFirst ? 1 : 0)"
#endif
        }

        #if DEBUG
        dlog(
            "split.externalDrop.begin ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "sourcePane=\(request.sourcePaneId.id.uuidString.prefix(5)) destination=\(destinationLabel)"
        )
        #endif
        let moved = app.moveBonsplitTab(
            bonsplitTabId: request.tabId.uuid,
            toWorkspace: id,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: true,
            focusWindow: true
        )
#if DEBUG
        dlog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }

}

// MARK: - BonsplitDelegate

extension Workspace: BonsplitDelegate {
    @MainActor
    private func shouldCloseWorkspaceOnLastSurface(for bonsplitTabId: TabID) -> Bool {
        let manager = owningWorkspaceManager ?? AppDelegate.shared?.workspaceManagerFor(workspaceId: id) ?? AppDelegate.shared?.workspaceManager
        guard panels.count <= 1,
              tabIdFromBonsplitTabId(bonsplitTabId) != nil,
              let manager,
              manager.workspaces.contains(where: { $0.id == id }) else {
            return false
        }
        return true
    }

    @MainActor
    private func confirmClosePanel(for bonsplitTabId: TabID) async -> Bool {
        // Route through the workspace-scoped pane-interaction runtime so the
        // confirmation appears as an overlay anchored to the panel being closed,
        // rather than a window-centered NSAlert (plan §3.4, §4.3). Falls back to
        // the legacy NSAlert when the feature is disabled or no panel is
        // resolvable (defensive; the tab was already deselected).
        if AreaInteractionFeatureFlag.isEnabled,
           let panelId = tabIdFromBonsplitTabId(bonsplitTabId) {
            return await presentConfirmClose(
                panelId: panelId,
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                source: .local
            )
        }

        // Legacy NSAlert path — kept as a rollback/fallback. Cancel is the
        // first button, so Return and Escape keep the tab; closing takes a click.
        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        alert.informativeText = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
            .hasDestructiveAction = true

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertSecondButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Present a .confirm pane interaction on the given panel and await the
    /// user's decision. Returns `true` only on explicit accept — .cancelled and
    /// .dismissed both map to `false` so callers don't fire close actions on a
    /// panel whose state may have drifted (§2 acceptance-time revalidation).
    /// It closes one tab, so the card starts on Close.
    @MainActor
    func presentConfirmClose(
        panelId: UUID,
        title: String,
        message: String,
        source: InteractionSource,
        dedupeToken: String? = nil
    ) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let content = ConfirmContent(
                title: title,
                message: message.isEmpty ? nil : message,
                confirmLabel: String(localized: "dialog.pane.confirm.close", defaultValue: "Close"),
                cancelLabel: String(localized: "dialog.pane.confirm.cancel", defaultValue: "Cancel"),
                role: .destructive,
                defaultSelection: .confirm,
                source: source,
                completion: { result in
                    cont.resume(returning: result == .confirmed)
                }
            )
            paneInteractionRuntime.present(
                panelId: panelId,
                interaction: .confirm(content),
                dedupeToken: dedupeToken
            )
        }
    }

    /// Present the workspace-scoped close confirmation overlay and await the
    /// user's decision. Returns `true` only on explicit accept — `.cancelled`
    /// and `.dismissed` both map to `false` so callers don't fire teardown on
    /// a workspace whose state may have drifted (e.g. closed mid-prompt).
    ///
    /// The overlay is anchored on this workspace's content area (sidebar
    /// stays visible). At most one workspace-close interaction can be active
    /// per workspace; re-presenting while one is live dismisses the existing
    /// one with `.dismissed`. The card starts on Cancel unless
    /// `defaultsToClose`, which callers pass when the close takes one tab.
    @MainActor
    func presentConfirmCloseWorkspace(
        title: String,
        message: String,
        defaultsToClose: Bool = false,
        source: InteractionSource,
        dedupeToken: String? = nil
    ) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let content = ConfirmContent(
                title: title,
                message: message.isEmpty ? nil : message,
                confirmLabel: String(
                    localized: "dialog.closeWorkspace.confirmButton",
                    defaultValue: "Close Workspace"
                ),
                cancelLabel: String(
                    localized: "dialog.pane.confirm.cancel",
                    defaultValue: "Cancel"
                ),
                role: .destructive,
                style: .standard,
                defaultSelection: defaultsToClose ? .confirm : nil,
                source: source,
                completion: { result in
                    cont.resume(returning: result == .confirmed)
                }
            )
            workspaceCloseInteractionRuntime.present(
                content: content,
                dedupeToken: dedupeToken
            )
        }
    }

    /// Present a `.textInput` pane interaction on the given panel and await the
    /// user's submitted value. Returns `nil` if the user cancelled or the
    /// interaction was dismissed (panel torn down, workspace closed, etc.) so
    /// callers can no-op instead of applying stale input.
    ///
    /// `validate` is invoked on each submit attempt; returning a non-nil string
    /// keeps the card visible with the given error below the field and does not
    /// resolve the continuation. Return `nil` to accept the value.
    @MainActor
    func presentTextInput(
        panelId: UUID,
        title: String,
        message: String?,
        defaultValue: String,
        placeholder: String?,
        confirmLabel: String = String(
            localized: "dialog.pane.textInput.submit",
            defaultValue: "OK"
        ),
        cancelLabel: String = String(
            localized: "dialog.pane.confirm.cancel",
            defaultValue: "Cancel"
        ),
        validate: @escaping (String) -> String?,
        source: InteractionSource = .local,
        dedupeToken: String? = nil
    ) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let content = TextInputContent(
                title: title,
                message: message,
                placeholder: placeholder,
                defaultValue: defaultValue,
                confirmLabel: confirmLabel,
                cancelLabel: cancelLabel,
                validate: validate,
                source: source,
                completion: { result in
                    switch result {
                    case .submitted(let value): cont.resume(returning: value)
                    case .cancelled, .dismissed: cont.resume(returning: nil)
                    }
                }
            )
            paneInteractionRuntime.present(
                panelId: panelId,
                interaction: .textInput(content),
                dedupeToken: dedupeToken
            )
        }
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    private func applyTabSelection(
        bonsplitTabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool = true,
        focusIntent: TabFocusIntent? = nil,
        previousTerminalHostedView: GhosttySurfaceScrollView? = nil
    ) {
        pendingTabSelection = PendingTabSelectionRequest(
            bonsplitTabId: bonsplitTabId,
            pane: pane,
            reassertAppKitFocus: reassertAppKitFocus,
            focusIntent: focusIntent,
            previousTerminalHostedView: previousTerminalHostedView
        )
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(
                bonsplitTabId: request.bonsplitTabId,
                inPane: request.pane,
                reassertAppKitFocus: request.reassertAppKitFocus,
                focusIntent: request.focusIntent,
                previousTerminalHostedView: request.previousTerminalHostedView
            )
        }

        // C11-228: a tab selected inside a hidden workspace must stay throttled;
        // its view may never update (a new panel starts `.active`).
        if let owningWorkspaceManager {
            applyPanelVisibility(workspaceVisible: owningWorkspaceManager.selectedWorkspaceId == id)
        }

        // C11-243: tab switch / pane focus changes what the operator is seeing.
        TabSeenTracker.shared.refresh()
    }

    private func applyTabSelectionNow(
        bonsplitTabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool,
        focusIntent: TabFocusIntent?,
        previousTerminalHostedView: GhosttySurfaceScrollView?
    ) {
        let previousFocusedPanelId = focusedPanelId
#if DEBUG
        let focusedPaneBefore = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabBefore = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.split.apply.begin workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) tab=\(bonsplitTabId.uuid.uuidString.prefix(5)) " +
            "focusedPane=\(focusedPaneBefore) selectedTab=\(selectedTabBefore) " +
            "reassert=\(reassertAppKitFocus ? 1 : 0)"
        )
#endif
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == bonsplitTabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != bonsplitTabId {
                bonsplitController.selectTab(bonsplitTabId)
            }
        }

        let focusedPane: PaneID
        let selectedBonsplitTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentBonsplitTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedBonsplitTabId = currentBonsplitTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == bonsplitTabId }) {
            focusedPane = pane
            selectedBonsplitTabId = bonsplitTabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedBonsplitTabId)
        } else {
            return
        }

        // Focus the selected panel, but keep the previously focused terminal active while a
        // newly created split terminal is still unattached.
        guard let selectedTabId = tabIdFromBonsplitTabId(selectedBonsplitTabId) else {
            return
        }
        let effectiveFocusedTabId = effectiveSelectedTabId(inPane: focusedPane) ?? selectedTabId
        guard let panel = panels[effectiveFocusedTabId] else {
            return
        }

        if debugStressPreloadSelectionDepth > 0 {
            if let terminalTab = panel as? TerminalTab {
                terminalTab.requestViewReattach()
                scheduleTerminalGeometryReconcile()
                terminalTab.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        if shouldTreatCurrentEventAsExplicitFocusIntent() {
            markExplicitFocusIntent(on: effectiveFocusedTabId)
        }
        let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
        panel.prepareFocusIntentForActivation(activationIntent)
        let panelId = effectiveFocusedTabId

        syncPinnedStateForTab(selectedBonsplitTabId, panelId: selectedTabId)
        syncUnreadBadgeStateForTab(selectedTabId)

        // Unfocus all other panels
        for (id, p) in panels where id != effectiveFocusedTabId {
            p.unfocus()
        }

        if let focusWindow = activationWindow(for: panel) {
            yieldForeignOwnedFocusIfNeeded(
                in: focusWindow,
                targetPanelId: panelId,
                targetIntent: activationIntent
            )
        }

        activateTab(
            panel,
            focusIntent: activationIntent,
            reassertAppKitFocus: reassertAppKitFocus
        )
        let focusIntentAllowsBrowserOmnibarAutofocus =
            shouldTreatCurrentEventAsExplicitFocusIntent() ||
            TerminalController.socketCommandAllowsInAppFocusMutations()
        if let browserTab = panel as? BrowserTab,
           shouldAllowBrowserOmnibarAutofocus(for: activationIntent),
           previousFocusedPanelId != panelId || focusIntentAllowsBrowserOmnibarAutofocus {
            maybeAutoFocusBrowserAddressBarOnTabFocus(browserTab, trigger: .standard)
        }
        if let terminalTab = panel as? TerminalTab {
            rememberTerminalConfigInheritanceSource(terminalTab)
        }
        let isManuallyUnread = manualUnreadTabIds.contains(panelId)
        let markedAt = manualUnreadMarkedAt[panelId]
        if Self.shouldClearManualUnread(
            previousFocusedPanelId: previousFocusedPanelId,
            nextFocusedPanelId: panelId,
            isManuallyUnread: isManuallyUnread,
            markedAt: markedAt
        ) {
            triggerFocusFlash(panelId: panelId)
            let clearDelay = Self.manualUnreadClearDelayAfterFocusFlash
            if clearDelay <= 0 {
                clearManualUnread(panelId: panelId)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) { [weak self] in
                    self?.clearManualUnread(panelId: panelId)
                }
            }
        }

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if reassertAppKitFocus, let terminalTab = panel as? TerminalTab {
            if shouldMoveTerminalSurfaceFocus(for: activationIntent),
               !terminalTab.hostedView.isSurfaceViewFirstResponder() {
#if DEBUG
                let previousExists = previousTerminalHostedView != nil ? 1 : 0
                dlog(
                    "focus.split.moveFocus workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) previousExists=\(previousExists) " +
                    "to=\(panelId.uuidString.prefix(5))"
                )
#endif
                terminalTab.hostedView.moveFocus(from: previousTerminalHostedView)
            }
#if DEBUG
            dlog(
                "focus.split.ensureFocus workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(focusedPane.id.uuidString.prefix(5)) " +
                "tab=\(selectedBonsplitTabId.uuid.uuidString.prefix(5)) intent=\(String(describing: activationIntent))"
            )
#endif
            terminalTab.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }

        if shouldRestoreFocusIntentAfterActivation(activationIntent) {
            _ = panel.restoreFocusIntent(activationIntent)
        }

        // Update current directory if this is a terminal
        if let dir = tabDirectories[panelId] {
            currentDirectory = dir
        }
        gitBranch = tabGitBranches[panelId]
        pullRequest = tabPullRequests[panelId]

        // Post notification
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.workspaceId: self.id,
                GhosttyNotificationKey.surfaceId: panelId
            ]
        )
#if DEBUG
        let prevPanelShort = previousFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.split.apply.end workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) type=\(String(describing: type(of: panel))) " +
            "focusedPane=\(focusedPane.id.uuidString.prefix(5)) selectedTab=\(selectedBonsplitTabId.uuid.uuidString.prefix(5)) " +
            "prevPanel=\(prevPanelShort)"
        )
#endif
    }

    private func activateTab(
        _ panel: any TabContent,
        focusIntent: TabFocusIntent,
        reassertAppKitFocus: Bool
    ) {
        if let terminalTab = panel as? TerminalTab {
            let shouldFocusTerminalSurface = shouldMoveTerminalSurfaceFocus(for: focusIntent)
            terminalTab.surface.setFocus(shouldFocusTerminalSurface)
            terminalTab.hostedView.setActive(true)
            if reassertAppKitFocus && shouldFocusTerminalSurface {
                terminalTab.focus()
            }
            return
        }

        if let browserTab = panel as? BrowserTab {
            guard shouldFocusBrowserWebView(for: focusIntent) else { return }
            browserTab.focus()
            return
        }

        if reassertAppKitFocus {
            panel.focus()
        }
    }

    private func activationWindow(for panel: any TabContent) -> NSWindow? {
        if let terminalTab = panel as? TerminalTab {
            return terminalTab.surface.uiWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        if let browserTab = panel as? BrowserTab {
            return browserTab.webView.window ?? browserTab.portalAnchorView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func yieldForeignOwnedFocusIfNeeded(
        in window: NSWindow,
        targetPanelId: UUID,
        targetIntent: TabFocusIntent
    ) {
        guard let firstResponder = window.firstResponder else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            guard let ownedIntent = panel.ownedFocusIntent(for: firstResponder, in: window) else { continue }
#if DEBUG
            dlog(
                "focus.handoff.begin workspace=\(id.uuidString.prefix(5)) " +
                "fromPanel=\(panelId.uuidString.prefix(5)) toPanel=\(targetPanelId.uuidString.prefix(5)) " +
                "fromIntent=\(String(describing: ownedIntent)) toIntent=\(String(describing: targetIntent))"
            )
#endif
            _ = panel.yieldFocusIntent(ownedIntent, in: window)
            return
        }
    }

    private func shouldMoveTerminalSurfaceFocus(for intent: TabFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldFocusBrowserWebView(for intent: TabFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldAllowBrowserOmnibarAutofocus(for intent: TabFocusIntent) -> Bool {
        switch intent {
        case .browser(.webView), .panel:
            return true
        default:
            return false
        }
    }

    private func shouldRestoreFocusIntentAfterActivation(_ intent: TabFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField), .terminal(.findField):
            return true
        case .panel, .browser(.webView), .terminal(.surface):
            return false
        }
    }

    private func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    private func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    private func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
    }

    private func shouldTreatCurrentEventAsExplicitFocusIntent() -> Bool {
        guard let eventType = NSApp.currentEvent?.type else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel,
             .gesture, .magnify, .rotate, .swipe:
            return true
        default:
            return false
        }
    }

    private func markExplicitFocusIntent(on panelId: UUID) {
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab bonsplitTab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseSelection() {
            let bonsplitTabs = controller.tabs(inPane: pane)
            guard let idx = bonsplitTabs.firstIndex(where: { $0.id == bonsplitTab.id }) else {
                postCloseSelectBonsplitTabId.removeValue(forKey: bonsplitTab.id)
                return
            }

            if let selectedBonsplitTabId = controller.selectedTab(inPane: pane)?.id,
               selectedBonsplitTabId != bonsplitTab.id {
                postCloseSelectBonsplitTabId[bonsplitTab.id] = selectedBonsplitTabId
                return
            }

            let target: TabID? = {
                if idx + 1 < bonsplitTabs.count { return bonsplitTabs[idx + 1].id }
                if idx > 0 { return bonsplitTabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectBonsplitTabId[bonsplitTab.id] = target
            } else {
                postCloseSelectBonsplitTabId.removeValue(forKey: bonsplitTab.id)
            }
        }

        let explicitUserClose = explicitUserCloseBonsplitTabIds.remove(bonsplitTab.id) != nil

        if forceCloseBonsplitTabIds.contains(bonsplitTab.id) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: bonsplitTab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        if let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
           pinnedTabIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: bonsplitTab.id)
            NSSound.beep()
            return false
        }

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: bonsplitTab.id) {
            clearStagedClosedBrowserRestoreSnapshot(for: bonsplitTab.id)
            owningWorkspaceManager?.closeWorkspaceWithConfirmation(self)
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: bonsplitTab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        if tabNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            clearStagedClosedBrowserRestoreSnapshot(for: bonsplitTab.id)
            if pendingCloseConfirmBonsplitTabIds.contains(bonsplitTab.id) {
                return false
            }

            pendingCloseConfirmBonsplitTabIds.insert(bonsplitTab.id)
            let bonsplitTabId = bonsplitTab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.pendingCloseConfirmBonsplitTabIds.remove(bonsplitTabId) }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.tabIdFromBonsplitTabId(bonsplitTabId) != nil else { return }

                    // C11-117: clicking X on a background pane-tab anchors the
                    // confirm overlay on a panel that isn't on-screen (the pane
                    // only renders the selected tab's panel), so the operator
                    // doesn't see the dialog until they manually click the tab.
                    // Bring the tab to the front first so the overlay mounts
                    // where the operator is looking.
                    if self.bonsplitController.selectedTab(inPane: pane)?.id != bonsplitTabId {
                        self.bonsplitController.selectTab(bonsplitTabId)
                    }

                    let confirmed = await self.confirmClosePanel(for: bonsplitTabId)
                    guard confirmed else { return }

                    self.forceCloseBonsplitTabIds.insert(bonsplitTabId)
                    self.bonsplitController.closeTab(bonsplitTabId)
                }
            }

            return false
        }

        clearStagedClosedBrowserRestoreSnapshot(for: bonsplitTab.id)
        recordPostCloseSelection()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab bonsplitTabId: TabID, fromPane pane: PaneID) {
        forceCloseBonsplitTabIds.remove(bonsplitTabId)
        let selectBonsplitTabId = postCloseSelectBonsplitTabId.removeValue(forKey: bonsplitTabId)
        let closedBrowserRestoreSnapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: bonsplitTabId)
        let isDetaching = detachingBonsplitTabIds.remove(bonsplitTabId) != nil || isDetachingCloseTransaction

        // Clean up our panel
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            if !isDetaching {
                scheduleFocusReconcile()
            }
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let panel = panels[panelId]

        if isDetaching, let panel {
            let browserTab = panel as? BrowserTab
            let cachedTitle = tabTitles[panelId]
            let transferFallbackTitle = cachedTitle ?? panel.displayTitle
            pendingDetachedSurfaces[bonsplitTabId] = DetachedTabTransfer(
                panelId: panelId,
                panel: panel,
                title: resolvedTabTitle(panelId: panelId, fallback: transferFallbackTitle),
                icon: panel.displayIcon,
                iconImageData: browserTab?.faviconPNGData,
                kind: tabKind(for: panel),
                isLoading: browserTab?.isLoading ?? false,
                isPinned: pinnedTabIds.contains(panelId),
                directory: tabDirectories[panelId],
                cachedTitle: cachedTitle,
                customTitle: tabCustomTitles[panelId],
                customColor: tabCustomColors[panelId],
                manuallyUnread: manualUnreadTabIds.contains(panelId),
                terminalType: surfaceTerminalKind(panelId: panelId),
                terminalTypeSource: TabMetadataStore.shared.getSource(
                    workspaceId: id,
                    surfaceId: panelId,
                    key: MetadataKey.terminalType
                ),
                derivedActivity: derivedActivityByTab[panelId],
                derivedActivitySource: TabMetadataStore.shared.getSource(
                    workspaceId: id,
                    surfaceId: panelId,
                    key: MetadataKey.activity
                ),
                isAgentCold: coldAgentSurfaceIds.contains(panelId),
                detectedTerminalType: detectedTerminalTypesByTab[panelId],
                activityState: resolvedSurfaceTabActivityState(
                    panelId: panelId,
                    hasExactSurfaceNotification: false
                ),
                attention: attentionSnapshot(panelId: panelId),
                tabSheetStatusEntered: tabSheetStatusEntered[panelId],
                shellEdgeAt: tabShellEdgeAt[panelId]
            )
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserTab?(closedBrowserRestoreSnapshot)
            }
            panel?.close()
            // C11-243: the panel is gone for good (detach keeps its id and the stamp).
            TabSeenTracker.shared.forget(panelId: panelId)
        }

        // Resolve any pending pane interactions on this panel with .dismissed so
        // callers waiting on a continuation don't leak. Must precede the panel
        // entry removal so anything observing `panels[panelId]` during the drain
        // still resolves against a consistent view.
        paneInteractionRuntime.clear(panelId: panelId)

        // CMUX-10: clear any persistent-flash timer + manifest entry before
        // removing the panel. Without this, the repeating timer keeps firing
        // and increments `sidebarFlashToken` for a panel that no longer exists.
        cancelPersistentFlash(panelId: panelId)

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        bonsplitTabIdToTabId.removeValue(forKey: bonsplitTabId)
        tabDirectories.removeValue(forKey: panelId)
        tabGitBranches.removeValue(forKey: panelId)
        tabPullRequests.removeValue(forKey: panelId)
        tabTitles.removeValue(forKey: panelId)
        tabCustomTitles.removeValue(forKey: panelId)
        tabCustomColors.removeValue(forKey: panelId)
        pinnedTabIds.remove(panelId)
        manualUnreadTabIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        tabSubscriptions.removeValue(forKey: panelId)
        tabShellActivityStates.removeValue(forKey: panelId)
        tabShellEdgeAt.removeValue(forKey: panelId)
        derivedActivityByTab.removeValue(forKey: panelId)
        attentionByTab.removeValue(forKey: panelId)
        coldAgentSurfaceIds.remove(panelId)
        detectedTerminalTypesByTab.removeValue(forKey: panelId)
        mailboxStdinBuffer.removeSurface(panelId)
        tabTTYNames.removeValue(forKey: panelId)
        restoredTerminalScrollbackByTabId.removeValue(forKey: panelId)
        titleBarCollapsed.removeValue(forKey: panelId)
        titleBarUserCollapsed.remove(panelId)
        tabSheetStatusEntered.removeValue(forKey: panelId)
        TabAttentionService.shared.remove(workspaceId: id, surfaceId: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        AgentDetector.shared.unregister(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByTabId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritanceTabId == panelId {
            lastTerminalConfigInheritanceTabId = nil
        }
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        // Keep the workspace invariant for normal close paths.
        // Detach/move flows intentionally allow a temporary empty workspace so AppDelegate can
        // prune the source workspace/window after the tab is attached elsewhere.
        if panels.isEmpty {
            if isDetaching {
                scheduleTerminalGeometryReconcile()
                return
            }

            let replacement = createReplacementTerminalTab()
            if let replacementBonsplitTabId = bonsplitTabIdFromTabId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementBonsplitTabId)
                applyTabSelection(bonsplitTabId: replacementBonsplitTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        if let selectBonsplitTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectBonsplitTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectBonsplitTabId)
            applyTabSelection(bonsplitTabId: selectBonsplitTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedBonsplitTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
            // When closing the last tab in a pane, Bonsplit may focus a different pane and skip
            // emitting didSelectTab. Re-apply the focused selection so sidebar state stays in sync.
            applyTabSelection(bonsplitTabId: focusedBonsplitTabId, inPane: focusedPane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        scheduleTerminalGeometryReconcile()
        if !isDetaching {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab bonsplitTab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(bonsplitTabId: bonsplitTab.id, inPane: pane)
        TabRailTipCenter.shared.scheduleRefresh()
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab bonsplitTab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let sincePrev: String
        if debugLastDidMoveTabTimestamp > 0 {
            sincePrev = String(format: "%.2f", (now - debugLastDidMoveTabTimestamp) * 1000)
        } else {
            sincePrev = "first"
        }
        debugLastDidMoveTabTimestamp = now
        debugDidMoveTabEventCount += 1
        let movedPanelId = tabIdFromBonsplitTabId(bonsplitTab.id)
        let movedPanel = movedPanelId?.uuidString.prefix(5) ?? "unknown"
        let selectedBefore = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneBefore = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.moveTab idx=\(debugDidMoveTabEventCount) dtSincePrevMs=\(sincePrev) panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
        dlog(
            "split.moveTab.state.before idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedBefore) focusedPane=\(focusedPaneBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif
        applyTabSelection(bonsplitTabId: bonsplitTab.id, inPane: destination)
#if DEBUG
        let movedPanelIdAfter = tabIdFromBonsplitTabId(bonsplitTab.id)
#endif
        if let movedPanelId = tabIdFromBonsplitTabId(bonsplitTab.id) {
            scheduleMovedTerminalRefresh(panelId: movedPanelId)
        }
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelIdAfter != nil && movedPanelIdAfter == focusedPanelId) ? 1 : 0
        dlog(
            "split.moveTab.state.after idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedAfter) focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter) " +
            "movedFocused=\(movedPanelFocused)"
        )
#endif
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        TabRailTipCenter.shared.scheduleRefresh()
        // When a pane is focused, focus its selected tab's panel
        guard let bonsplitTab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        FocusLogStore.shared.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(bonsplitTab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(bonsplitTabId: bonsplitTab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
           let terminalTab = panels[panelId] as? TerminalTab {
            terminalTab.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        TabRailTipCenter.shared.notePaneClosed(workspace: self, paneId: paneId)
        // The pane is gone — drop any pending pane-scoped overlay (e.g. a stale
        // pane-close confirmation that survived the close path) so its
        // continuation resolves with .dismissed instead of leaking.
        areaCloseInteractionRuntime.clear(panelId: paneId.id)
        // Authoritative anchor cleanup for the close-pane overlay. AnchorView
        // dismantleNSView deliberately does NOT remove the anchor (SwiftUI
        // dismantles transient AnchorViews during sibling re-layout, and
        // removing on every dismantle orphans surviving panes). This is the
        // one place where we know the pane is actually gone.
        areaCloseOverlayController.removeAnchor(paneIdentity: paneId.id)
        // After Bonsplit removes a pane, surviving siblings get reflowed into
        // their new positions but the existing reportFrame paths (SwiftUI
        // updateNSView, AppKit viewDidMoveToWindow) all fire DURING the
        // reflow and capture transient/half-applied coordinates. Without
        // this nudge the controller's anchors map stays stale and the
        // confirmation overlay mounts at the wrong pane position. Triggers
        // twice (next tick + ~60ms) to cover multi-pass layouts.
        areaCloseOverlayController.refreshAllAnchorsAfterReflow()

        let closedPanelIds = pendingAreaCloseTabIds.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction

        if !closedPanelIds.isEmpty {
            for panelId in closedPanelIds {
                // Dismiss any pending pane interactions on this panel before
                // tearing it down so withCheckedContinuation callers resume
                // with .dismissed. Matches the cleanup invariant in
                // teardownAllPanels (synthesis-standard §1.1).
                paneInteractionRuntime.clear(panelId: panelId)
                // CMUX-10: drop any persistent-flash timer + manifest entry
                // before the panel disappears. Same invariant as the
                // single-panel close path above.
                cancelPersistentFlash(panelId: panelId)
                panels[panelId]?.close()
                panels.removeValue(forKey: panelId)
                // C11-243: pane closed for good; a detaching transaction keeps ids.
                if !isDetachingCloseTransaction {
                    TabSeenTracker.shared.forget(panelId: panelId)
                }
                untrackRemoteTerminalSurface(panelId)
                tabDirectories.removeValue(forKey: panelId)
                tabGitBranches.removeValue(forKey: panelId)
                tabPullRequests.removeValue(forKey: panelId)
                tabTitles.removeValue(forKey: panelId)
                tabCustomTitles.removeValue(forKey: panelId)
                tabCustomColors.removeValue(forKey: panelId)
                pinnedTabIds.remove(panelId)
                manualUnreadTabIds.remove(panelId)
                tabSubscriptions.removeValue(forKey: panelId)
                tabShellActivityStates.removeValue(forKey: panelId)
                tabShellEdgeAt.removeValue(forKey: panelId)
                derivedActivityByTab.removeValue(forKey: panelId)
                coldAgentSurfaceIds.remove(panelId)
                detectedTerminalTypesByTab.removeValue(forKey: panelId)
                mailboxStdinBuffer.removeSurface(panelId)
                tabTTYNames.removeValue(forKey: panelId)
                tabListeningPorts.removeValue(forKey: panelId)
                restoredTerminalScrollbackByTabId.removeValue(forKey: panelId)
                PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            AgentDetector.shared.unregister(workspaceId: id, panelId: panelId)
            }

            let closedSet = Set(closedPanelIds)
            bonsplitTabIdToTabId = bonsplitTabIdToTabId.filter { !closedSet.contains($0.value) }
            recomputeListeningPorts()
            clearRemoteConfigurationIfWorkspaceBecameLocal()

            if let focusedPane = bonsplitController.focusedPaneId,
               let focusedBonsplitTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
                applyTabSelection(bonsplitTabId: focusedBonsplitTabId, inPane: focusedPane)
            } else if shouldScheduleFocusReconcile {
                scheduleFocusReconcile()
            }
        }

        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let bonsplitTabs = controller.tabs(inPane: pane)
        for bonsplitTab in bonsplitTabs {
            if forceCloseBonsplitTabIds.contains(bonsplitTab.id) { continue }
            if let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
               let terminalPanel = terminalPanel(for: panelId),
               tabNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
                pendingAreaCloseTabIds.removeValue(forKey: pane.id)
                return false
            }
        }
        pendingAreaCloseTabIds[pane.id] = bonsplitTabs.compactMap { tabIdFromBonsplitTabId($0.id) }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
        _ = TerminalController.shared.v2EnsureHandleRef(kind: .pane, uuid: newPane.id)
#if DEBUG
        let panelKindForBonsplitTab: (TabID) -> String = { bonsplitTabId in
            guard let panelId = self.tabIdFromBonsplitTabId(bonsplitTabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalTab { return "terminal" }
            if panel is BrowserTab { return "browser" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let bonsplitTabs = controller.tabs(inPane: paneId)
            guard !bonsplitTabs.isEmpty else { return "-" }
            return bonsplitTabs.map { bonsplitTab in
                String(panelKindForBonsplitTab(bonsplitTab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForBonsplitTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForBonsplitTab($0.id) } ?? "none"
        dlog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        let rearmBrowserPortalHostReplacement: (PaneID, String) -> Void = { paneId, reason in
            for bonsplitTab in controller.tabs(inPane: paneId) {
                guard let panelId = self.tabIdFromBonsplitTabId(bonsplitTab.id),
                      let browserPanel = self.browserPanel(for: panelId) else {
                    continue
                }
                browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                    inPane: paneId,
                    reason: reason
                )
            }
        }
        rearmBrowserPortalHostReplacement(originalPane, "workspace.didSplit.original")
        rearmBrowserPortalHostReplacement(newPane, "workspace.didSplit.new")

        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalBonsplitTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalBonsplitTabs.contains { tabIdFromBonsplitTabId($0.id) != nil }
#if DEBUG
            dlog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalBonsplitTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderBonsplitTabs = originalBonsplitTabs.filter { tabIdFromBonsplitTabId($0.id) == nil }
#if DEBUG
                dlog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderBonsplitTabs.count)"
                )
#endif
                if let replacementBonsplitTab = placeholderBonsplitTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let workingDirectory = newSurfaceWorkingDirectory(
                        explicit: nil,
                        sourcePanelId: terminalTabForConfigInheritance(inPane: originalPane)?.id
                    ).path
                    let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

                    let replacementTab = TerminalTab(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        workingDirectory: workingDirectory,
                        portOrdinal: portOrdinal
                    )
                    panels[replacementTab.id] = replacementTab
                    tabTitles[replacementTab.id] = replacementTab.displayTitle
                    seedTerminalInheritanceFontPoints(panelId: replacementTab.id, configTemplate: inheritedConfig)
                    bonsplitTabIdToTabId[replacementBonsplitTab.id] = replacementTab.id

                    bonsplitController.updateTab(
                        replacementBonsplitTab.id,
                        title: TitleFormatting.sidebarLabel(from: replacementTab.displayTitle),
                        icon: .some(replacementTab.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(TabKind.terminal),
                        hasCustomTitle: false,
                        isDirty: replacementTab.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )

                    for extraPlaceholder in placeholderBonsplitTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    dlog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for bonsplitTab in controller.tabs(inPane: originalPane) {
                        if tabIdFromBonsplitTabId(bonsplitTab.id) == nil {
                            bonsplitController.closeTab(bonsplitTab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is a browser, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceBonsplitTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourceTabId = sourceBonsplitTabId.flatMap { tabIdFromBonsplitTabId($0) }

#if DEBUG
        dlog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourceTabId.map { String($0.uuidString.prefix(5)) } ?? "none")"
        )
#endif

        let workingDirectory = newSurfaceWorkingDirectory(explicit: nil, sourcePanelId: sourceTabId).path
        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: sourceTabId,
            inPane: originalPane
        )

        let newTab = TerminalTab(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal
        )
        panels[newTab.id] = newTab
        tabTitles[newTab.id] = newTab.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newTab.id, configTemplate: inheritedConfig)

        guard let newBonsplitTabId = bonsplitController.createTab(
            title: TitleFormatting.sidebarLabel(from: newTab.displayTitle),
            icon: newTab.displayIcon,
            kind: TabKind.terminal,
            isDirty: newTab.isDirty,
            isPinned: false,
            displayOrdinal: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: newTab.id),
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newTab.id)
            tabTitles.removeValue(forKey: newTab.id)
            terminalInheritanceFontPointsByTabId.removeValue(forKey: newTab.id)
            return
        }

        bonsplitTabIdToTabId[newBonsplitTabId] = newTab.id
        normalizePinnedTabs(in: newPane)
#if DEBUG
        dlog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newTab.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newBonsplitTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        // An explicit tab-bar spawn click ("A"/terminal/browser/markdown/"+") is an
        // unambiguous "open a new surface here and let me use it" gesture, so the new
        // surface must take focus immediately. Focus the clicked pane first — mirroring
        // how tapping a tab focuses its pane — so the surface creators (which default
        // `focus` to `focusedPaneId == pane`) reliably focus + select what they create.
        // Without this, clicking a spawn button in a pane that was NOT the focused pane
        // created the surface but left focus on the other pane, so the view never
        // switched to the new tab.
        bonsplitController.focusPane(pane)
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane)
        case "browser":
            // Defense in depth: the spawn button is already hidden when the
            // internal browser is disabled, but no-op safely if the request
            // reaches us anyway.
            guard TabTypeAvailability.isEnabled(.browser) else { return }
            _ = newBrowserSurface(inPane: pane)
        case "markdown":
            guard TabTypeAvailability.isEnabled(.markdown) else { return }
            _ = newMarkdownTab(inPane: pane)
        case "agent":
            launchDefaultAgentFromTabBar(inPane: pane)
        case "newTab":
            createNewTabOfFocusedKind(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane)
        }
    }

    /// Why a UI-initiated agent launch declined (C11-203 A1). Every non-launch
    /// return from `attemptAgentSurfaceLaunch` names itself, so no operator
    /// gesture can end in a silent no-op — the defect class the dead A button
    /// belonged to. Modeled on `AppDelegate.SavedConfigLaunchResult`, which the
    /// editor sheet already renders honestly.
    enum AgentLaunchDecline: Equatable {
        /// The resolved shell command was empty: a `custom` harness with no
        /// command of its own, or a harness whose Settings command was blanked.
        case emptyCommand(harness: String)
        /// `newTerminalSurface` refused to create the surface.
        case surfaceCreationFailed
        /// An explicit recipe the overlay resolver could not materialize (an
        /// unknown harness in a hand-edited `agent-configs.json`).
        case unresolvableRecipe(harness: String)

        /// One operator-facing sentence: what happened, and the next move.
        var message: String {
            switch self {
            case .emptyCommand(let harness):
                return String(
                    format: String(
                        localized: "agentLaunch.decline.emptyCommand",
                        defaultValue: "This config resolves to an empty command (%@) — set a launch command for it under Edit Launch Agents."
                    ),
                    harness
                )
            case .surfaceCreationFailed:
                return String(
                    localized: "agentLaunch.decline.surfaceFailed",
                    defaultValue: "Couldn't open a terminal tab for the agent — try again, or use a different area."
                )
            case .unresolvableRecipe(let harness):
                return String(
                    format: String(
                        localized: "agentLaunch.decline.unresolvableRecipe",
                        defaultValue: "c11 doesn't know the harness '%@' this config names — pick a known harness under Edit Launch Agents."
                    ),
                    harness
                )
            }
        }
    }

    /// The outcome of an agent-surface launch attempt (C11-203 A1).
    enum AgentTabLaunchOutcome: Equatable {
        case launched
        case declined(AgentLaunchDecline)

        var didLaunch: Bool { self == .launched }
        /// The decline reason, or `nil` when the launch happened.
        var decline: AgentLaunchDecline? {
            if case .declined(let reason) = self { return reason }
            return nil
        }
    }

    /// Launch an agent surface. Returns `true` when a launch was actually
    /// performed; `false` when it declined. Callers that can show the operator
    /// *why* should use `attemptAgentSurfaceLaunch` instead — this boolean
    /// wrapper exists for the paths (socket `agent.launch`, the CLI's
    /// new-surface path) that already report their own errors.
    @discardableResult
    func launchAgentSurface(inPane pane: PaneID, explicitAgent: AgentType? = nil, explicitConfig: SavedAgentConfig? = nil, workingDirectory: String? = nil, source: AgentLaunchSource = .aButton) -> Bool {
        attemptAgentTabLaunch(
            inPane: pane,
            explicitAgent: explicitAgent,
            explicitConfig: explicitConfig,
            workingDirectory: workingDirectory,
            source: source
        ).didLaunch
    }

    /// Create a new terminal and immediately send the configured agent launch
    /// command, reporting the decline reason when it doesn't happen (C11-203
    /// A1). Uses the same "queue sendText before ready, flush on ready" pattern
    /// as the welcome workspace. Every UI gesture routes through here so it can
    /// surface a reason instead of dying in a guard.
    ///
    /// `explicitAgent` lets the caller override the configured default —
    /// used by the right-click menu's "launch this one now" affordance and
    /// the `c11 default-agent launch --agent <type>` socket command.
    /// `explicitConfig` (C11-181) launches a *specific* saved config now — the
    /// A-button picker's "row click = launch". When set it takes precedence over
    /// `effectiveDefault()`; when both it and `explicitAgent` are nil the plain
    /// left-click path (launch `effectiveDefault()`) is unchanged.
    /// - Parameter workingDirectory: explicit cwd (`default-agent launch --cwd`).
    ///   Nil takes the workspace's new-surface rule: root, then the pane's
    ///   terminal, then home. The same path drives the project-config lookup
    ///   and the new shell, so they cannot disagree.
    /// - Parameter source: launch-stats provenance (C11-178). Defaults to
    ///   `.aButton` (the real UI spawn button); the CLI `default-agent launch`
    ///   new-surface path passes `.launchAgent` so button-clicks and CLI launches
    ///   are honestly distinguished in the stats rail.
    func attemptAgentTabLaunch(
        inPane pane: PaneID,
        explicitAgent: AgentType? = nil,
        explicitConfig: SavedAgentConfig? = nil,
        workingDirectory: String? = nil,
        source: AgentLaunchSource = .aButton
    ) -> AgentTabLaunchOutcome {
        let launchCwd = agentLaunchWorkingDirectory(inPane: pane, explicit: workingDirectory)
        let userDefault = DefaultAgentConfigStore.shared.current
        let projectConfig = DefaultAgentProjectConfig.find(from: launchCwd)

        // A plain left-click (no explicit agent) launches the saved-config
        // library's `effectiveDefault()` through the overlay resolver (C11-179).
        // An explicit agent (right-click "launch this kind" / socket) stays on
        // the raw-harness path. A custom-harness overlay the resolver can't
        // materialize falls back to the raw-harness default (design §5.6).
        let agent: AgentType
        let launch: ResolvedAgentLaunch
        let resolvedModel: String
        let resolvedEffort: String
        let resolvedSystemPromptMode: String?
        let savedConfigId: String?

        // A caller-chosen config (Settings "Save & Launch", C11-182; or the
        // C11-181 A-button picker) launches exactly that recipe. Otherwise a plain
        // left-click consults the saved-config library's `effectiveDefault()`; an
        // explicit agent keeps `nil` here and takes the raw-harness path below.
        let overlaySaved: SavedAgentConfig?
        if let explicitConfig {
            overlaySaved = explicitConfig
        } else if explicitAgent == nil {
            overlaySaved = AgentConfigLibraryStore.shared.effectiveDefault()
        } else {
            overlaySaved = nil
        }
        if let saved = overlaySaved,
           let overlay = DefaultAgentResolver.resolveOverlay(
               savedConfig: saved,
               userDefault: userDefault,
               projectConfig: projectConfig
           ) {
            agent = overlay.agent
            launch = overlay.launch
            resolvedModel = overlay.mergedConfig.model.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedEffort = overlay.mergedConfig.effort.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedSystemPromptMode = overlay.mergedConfig.systemPrompt?.mode.rawValue
            savedConfigId = saved.id.isEmpty ? nil : saved.id
        } else if let explicitConfig {
            // A caller asked to launch a specific recipe that the resolver could
            // not materialize (unknown harness in a hand-edited agent-configs.json).
            // Decline rather than silently launching the default agent instead.
            return .declined(.unresolvableRecipe(harness: explicitConfig.config.harness))
        } else {
            let resolved = DefaultAgentResolver.resolve(
                explicitAgent: explicitAgent,
                userDefault: userDefault,
                projectConfig: projectConfig
            )
            agent = resolved.agent
            launch = resolved.launch
            let cfg = projectConfig?.agents[agent] ?? userDefault.config(for: agent)
            resolvedModel = cfg.model.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedEffort = cfg.effort.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedSystemPromptMode = cfg.systemPrompt?.mode.rawValue
            savedConfigId = nil
        }

        guard !launch.command.isEmpty else {
            return .declined(.emptyCommand(harness: agent.rawValue))
        }
        guard let panel = newTerminalSurface(
            inPane: pane,
            workingDirectory: launchCwd,
            startupEnvironment: launch.envOverrides
        ) else {
            return .declined(.surfaceCreationFailed)
        }
        // By default no orientation prompt is baked (see `c11OrientPrompt`),
        // so the agent boots straight to ready with no dead-time. c11 stamps
        // the identity the sidebar needs itself — no agent round-trip: the
        // type comes from `AgentDetector`, and we stamp the overlay-resolved
        // model plus a placeholder title here. An operator who configured a
        // launch prompt still gets it delivered below (a staged file instruction for
        // claude-code, post-ready sendText for other TUIs is a follow-up).
        stampLaunchIdentity(surfaceId: panel.id, resolvedModel: resolvedModel)
        panel.submitConfiguredAgentLaunch(agent: agent, launch: launch) { [weak self, weak panel] in
            guard let self, let panel else { return false }
            return self.terminalPanel(for: panel.id) === panel
                && self.bonsplitController.allPaneIds.contains(pane)
        }
        // C11-178 rail-1: record the launch off the critical path, now with the
        // overlay-resolved axes + `config_id` + system-prompt mode (C11-179).
        recordAgentLaunchStats(
            harness: agent.rawValue,
            model: resolvedModel,
            effort: resolvedEffort,
            systemPromptMode: resolvedSystemPromptMode,
            configId: savedConfigId,
            source: source
        )
        // C11-179 (R2): keep `recent` in `agent-configs.json` current for
        // A-button-lineage launches. Durable telemetry only since C11-203 B2 —
        // nothing resolves through it — but it is still the record `c11 config
        // recent` / `--pin-current` read. Off-main, best-effort.
        recordOverlayRecent(
            harness: agent.rawValue,
            model: resolvedModel,
            effort: resolvedEffort,
            configId: savedConfigId
        )
        // The tooltip carries the resolved default (§5.3 v1). Cheap:
        // `refreshSplitButtonTooltips` diffs and no-ops when unchanged.
        refreshSplitButtonTooltips()
        return .launched
    }

    /// C11-178/179: emit a rail-1 launch-stats record for an A-button-lineage
    /// launch, carrying the overlay-resolved axes. Dispatched to a utility queue
    /// so no disk touches the launch path. `nil` store (state dir unavailable)
    /// is a silent no-op.
    private func recordAgentLaunchStats(
        harness: String,
        model: String,
        effort: String,
        systemPromptMode: String?,
        configId: String?,
        source: AgentLaunchSource
    ) {
        guard let store = AgentLaunchStatsStore.shared else { return }
        let resolved = ResolvedLaunch(
            harness: harness,
            model: model,
            effort: effort,
            systemPromptMode: systemPromptMode,
            configId: configId
        )
        DispatchQueue.global(qos: .utility).async {
            store.recordLaunch(resolved, source: source)
        }
    }

    /// C11-179 (R2): persist the observed launch as `recent` in
    /// `agent-configs.json`. Off-main, best-effort — a telemetry hiccup never
    /// fails a launch. Empty `harness` is a no-op guard.
    private func recordOverlayRecent(
        harness: String,
        model: String,
        effort: String,
        configId: String?
    ) {
        guard !harness.isEmpty else { return }
        let recent = RecentAgentConfig(
            configId: configId,
            harness: harness,
            model: model.isEmpty ? nil : model,
            effort: effort.isEmpty ? nil : effort,
            observedAt: Date(),
            source: "launch",
            fieldSources: ["model": "launch", "effort": "launch"]
        )
        DispatchQueue.global(qos: .utility).async {
            try? AgentConfigLibraryStore.shared.recordRecent(recent)
        }
    }

    /// Populate a freshly launched agent surface with the identity the sidebar
    /// would otherwise wait on the agent to report: the pinned model (which
    /// process detection can't infer) and a placeholder title. Written with
    /// source `.declare` so a later explicit `set-agent` / `set-title` from the
    /// agent or operator cleanly wins. The agent *type* is intentionally not
    /// stamped here — `AgentDetector` owns it authoritatively.
    func stampLaunchIdentity(
        surfaceId: UUID,
        resolvedModel: String
    ) {
        let partial: [String: Any] = [
            MetadataKey.title: String(
                localized: "agent.launch.placeholderTitle",
                defaultValue: "Awaiting first task"
            )
        ]
        _ = try? TabMetadataStore.shared.setMetadata(
            workspaceId: id,
            surfaceId: surfaceId,
            partial: partial,
            mode: .merge,
            source: .declare
        )
        // `resolvedModel` is the overlay-resolved model the launch actually used
        // (C11-179), so the chip shows what c11 launched with — including a
        // saved-config override, not just the harness base pin. It is a launch
        // stamp (tier `heuristic`): what c11 asked for, so a model detected from
        // the session files or declared by the agent outranks it.
        let model = resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            _ = try? TabMetadataStore.shared.setMetadata(
                workspaceId: id,
                surfaceId: surfaceId,
                partial: [MetadataKey.model: model],
                mode: .merge,
                source: .heuristic
            )
        }
        syncTabTitleFromMetadata(panelId: surfaceId)
        syncSurfaceTabActivityStateForTab(surfaceId)
    }

    /// Identity-at-birth stamp for `agent.launch` (`c11 launch-agent`). Unlike
    /// `stampLaunchIdentity` (A button), the caller *explicitly requested* this
    /// agent kind, so `terminal_type` is stamped as a declaration too — the
    /// same tier `c11 set-agent` writes, so a later explicit declaration still
    /// cleanly wins, and `AgentDetector`'s heuristic tier never fights it.
    /// Models that don't fit the canonical kebab grammar (e.g. `gpt-5.2`,
    /// `provider/model`) land on the non-canonical `model_label` display hint
    /// instead so the chip still shows them.
    func stampAgentLaunchIdentity(
        surfaceId: UUID,
        kind: String,
        model: String,
        task: String?,
        title: String?
    ) {
        var partial: [String: Any] = [
            MetadataKey.terminalType: kind,
            MetadataKey.title: title?.isEmpty == false
                ? title!
                : String(
                    localized: "agent.launch.placeholderTitle",
                    defaultValue: "Awaiting first task"
                )
        ]
        // The launch model is a stamp (tier `heuristic`), written below apart from
        // the declared identity: detection and `set-agent --model` outrank it.
        var launchModel: [String: Any] = [:]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            if trimmedModel.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
               trimmedModel.count <= 64 {
                launchModel[MetadataKey.model] = trimmedModel
            } else {
                launchModel[MetadataKey.modelLabel] = String(trimmedModel.prefix(16))
            }
        }
        if let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            partial[MetadataKey.task] = String(task.prefix(128))
        }
        _ = try? TabMetadataStore.shared.setMetadata(
            workspaceId: id,
            surfaceId: surfaceId,
            partial: partial,
            mode: .merge,
            source: .declare
        )
        if !launchModel.isEmpty {
            _ = try? TabMetadataStore.shared.setMetadata(
                workspaceId: id,
                surfaceId: surfaceId,
                partial: launchModel,
                mode: .merge,
                source: .heuristic
            )
        }
        syncTabTitleFromMetadata(panelId: surfaceId)
        syncSurfaceTabActivityStateForTab(surfaceId)
    }

    /// The A button's plain left-click (C11-203 A1). A launch that declines used
    /// to return into the void: no surface, no error, nothing on screen. Now the
    /// decline opens the picker carrying the reason as its notice bar — the
    /// operator sees *why* nothing launched and is already standing in the one
    /// surface that can fix it (pick another row, or Edit Launch Agents).
    private func launchDefaultAgentFromTabBar(inPane pane: PaneID) {
        let outcome = attemptAgentTabLaunch(inPane: pane)
        guard let decline = outcome.decline else { return }
        presentAgentPicker(
            inPane: pane,
            window: NSApp.currentEvent?.window,
            anchoringTo: nil,
            notice: decline.message
        )
    }

    func splitTabBar(_ controller: BonsplitController, didRightClickNewTabButton kind: String, inPane pane: PaneID, buttonScreenRect: CGRect) {
        // C11-181: a right-click on the A button opens the rich launch picker
        // popover — it replaces both the old 9-harness menu AND its
        // click-sets-default gesture (design §5/§8.8). The delegate fires
        // synchronously inside the right-click's own dispatch, so the current
        // event's window is the button's window.
        guard kind == "agent" else { return }
        presentAgentPicker(inPane: pane, window: NSApp.currentEvent?.window, anchoringTo: buttonScreenRect)
    }

    /// Present the tier-1 agent launch picker popover anchored to the A button
    /// (design §5.1). `anchorScreenRect` is the right-clicked button's frame;
    /// `nil` (⌘⇧A / menu / a declined left-click) anchors at the window's
    /// top-trailing corner. Row click = launch now; pin / ⌥-click = set default
    /// without launching (C11-181). `notice` seeds the inline notice bar, which
    /// is how a declined A-button launch explains itself (C11-203 A1).
    func presentAgentPicker(
        inPane pane: PaneID,
        window requestedWindow: NSWindow? = nil,
        anchoringTo anchorScreenRect: NSRect? = nil,
        notice: String? = nil
    ) {
        guard let window = requestedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        // Re-probe PATH on every open so a harness installed mid-session lights
        // its rows back up without an app relaunch.
        AgentHarnessInstallProbe.invalidate()

        let controller = AgentPickerController(model: makeAgentPickerModel())
        controller.rebuild = { [weak self] in self?.makeAgentPickerModel() }
        controller.onLaunch = { [weak self] config in
            // A deallocated workspace is still a decline, not a launch — say so
            // rather than closing the popover as if something happened.
            guard let self else { return AgentLaunchDecline.surfaceCreationFailed.message }
            // The A button belongs to a pane. Focus it at launch time so the
            // new agent cannot land as a hidden/background tab — but not at
            // popover-open time, so peeking at the picker from an unfocused
            // pane and pressing Esc doesn't steal the pane focus.
            self.bonsplitController.focusPane(pane)
            // A decline keeps the popover open and returns its reason; the
            // controller renders it in the notice bar (C11-203 A1).
            return self.attemptAgentTabLaunch(
                inPane: pane, explicitConfig: config, source: .aButton
            ).decline?.message
        }
        controller.onPin = { [weak self] config in
            do {
                try AgentConfigLibraryStore.shared.setDefault(configId: config.id)
            } catch {
                // Pinning an unlaunchable recipe is refused at the store; say so
                // rather than letting the ● quietly fail to move (C11-203 A2).
                return Workspace.pinRefusalMessage(for: error, configName: config.name)
            }
            self?.refreshSplitButtonTooltips()
            return nil
        }
        // Tier-2 ("Edit Launch Agents") is C11-182, now on main: it opens the
        // editor focused on the current default (or a new config when the
        // effective default is a transient with no id). `origin: .popover` lets
        // the sheet order Settings out on close.
        controller.onViewAll = { [weak self, weak window] in
            AgentPickerPresenter.shared.armReturnToPicker {
                guard let self, let window else { return }
                self.presentAgentPicker(inPane: pane, window: window, anchoringTo: nil)
            }
            let eff = AgentConfigLibraryStore.shared.effectiveDefault()
            let focus: AgentConfigEditorFocus = eff.id.isEmpty ? .new : .config(eff.id)
            AppDelegate.shared?.openAgentConfigEditor(focus: focus, origin: .popover)
        }
        // All refusals — not-installed, a declined launch, a refused pin — land
        // in the controller's inline notice bar (no beep, no silence).
        if let notice { controller.showNotice(notice) }

        AgentPickerPresenter.shared.present(controller: controller, in: window, anchoringTo: anchorScreenRect)
    }

    /// Operator-facing sentence for a refused pin (C11-203 A2).
    nonisolated static func pinRefusalMessage(for error: Error, configName: String) -> String {
        if let storeError = error as? AgentConfigLibraryStore.StoreError,
           case .configUnlaunchable = storeError {
            return String(
                format: String(
                    localized: "agentPicker.notice.pinUnlaunchable",
                    defaultValue: "'%@' can't launch as written, so it can't be the default — give it a launch command first."
                ),
                configName
            )
        }
        return String(
            format: String(
                localized: "agentPicker.notice.pinFailed",
                defaultValue: "Couldn't set '%@' as the default — please try again."
            ),
            configName
        )
    }

    /// Build the picker view-model from the current library, registry, a cached
    /// PATH install probe, and the (absent-today) cost catalog.
    private func makeAgentPickerModel() -> AgentPickerModel {
        let library = AgentConfigLibraryStore.shared.current
        let effective = AgentConfigLibraryStore.shared.effectiveDefault()
        let env = AgentPickerEnvironment(
            displayName: { kind in
                AgentRegistry.shared.manifest(forKind: kind)?.displayName
                    ?? AgentType(rawValue: kind)?.displayName ?? kind
            },
            provider: { AgentLaunchStats.provider(harness: $0, model: $1) },
            isInstalled: { AgentHarnessInstallProbe.isInstalled($0) },
            costFor: { ModelCostCatalogStore.shared?.cost(forModel: $0) }
        )
        return AgentPickerModel(library: library, effectiveDefault: effective, env: env)
    }

    func splitTabBar(_ controller: BonsplitController, didRequestClosePane pane: PaneID) {
        let bonsplitTabs = controller.tabs(inPane: pane)
        let paneCount = controller.allPaneIds.count
        let isOnlyPane = paneCount <= 1

        let tabTitles = bonsplitTabs.map { Self.paneCloseTabTitle(for: $0) }
        let title = Self.closePaneConfirmationTitle(tabCount: bonsplitTabs.count, isOnlyPane: isOnlyPane)
        let message = Self.closePaneConfirmationMessage(tabCount: bonsplitTabs.count, isOnlyPane: isOnlyPane)
        let confirmLabel = Self.closePaneConfirmLabel(tabCount: bonsplitTabs.count, isOnlyPane: isOnlyPane)
        let cancelLabel = String(
            localized: "workspace.closePane.alert.cancel",
            defaultValue: "Cancel"
        )

        let runtime = areaCloseInteractionRuntime
        let paneKey = pane.id
        Task { @MainActor [weak self] in
            let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let content = ConfirmContent(
                    title: title,
                    message: message,
                    detailLines: tabTitles,
                    confirmLabel: confirmLabel,
                    cancelLabel: cancelLabel,
                    role: .destructive,
                    style: .criticalDestructive,
                    defaultSelection: bonsplitTabs.count == 1 ? .confirm : nil,
                    source: .local,
                    completion: { result in
                        cont.resume(returning: result == .confirmed)
                    }
                )
                runtime.present(
                    panelId: paneKey,
                    interaction: .confirm(content),
                    dedupeToken: "workspace.closePane"
                )
            }
            guard confirmed, let self else { return }

            if isOnlyPane {
                // The pane structure stays (Bonsplit refuses to remove the
                // last pane and the workspace must always have one). Close
                // every tab in it without per-tab confirmation — the user
                // already accepted the bigger "close entire pane" action —
                // then drop a fresh terminal in so the operator isn't left
                // staring at the empty-pane chooser. Matches the user's ask:
                // X always does something, even on the root pane.
                let bonsplitTabsNow = self.bonsplitController.tabs(inPane: pane)
                for bonsplitTab in bonsplitTabsNow {
                    self.forceCloseBonsplitTabIds.insert(bonsplitTab.id)
                    _ = self.bonsplitController.closeTab(bonsplitTab.id)
                }
                _ = self.newTerminalSurface(inPane: pane)
            } else {
                guard self.bonsplitController.allPaneIds.contains(pane) else { return }
                // Pre-load forceCloseTabIds so Bonsplit's shouldClosePane veto
                // (which fires when any terminal in the pane is busy / not at
                // an idle prompt) doesn't silently swallow the close after the
                // user already confirmed the pane-level action. Mirrors the
                // isOnlyPane branch above.
                for bonsplitTab in self.bonsplitController.tabs(inPane: pane) {
                    self.forceCloseBonsplitTabIds.insert(bonsplitTab.id)
                }
                _ = self.bonsplitController.closePane(pane)
            }
        }
    }

    private static func paneCloseTabTitle(for bonsplitTab: Bonsplit.Tab) -> String {
        let trimmed = bonsplitTab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(
            localized: "workspace.closePane.alert.tab.untitled",
            defaultValue: "Untitled tab"
        )
    }

    private static func closePaneConfirmationTitle(tabCount: Int, isOnlyPane: Bool) -> String {
        // Always "entire pane" — the differentiator vs Close Tab is the
        // word "entire" (rendered with emphasis in the card view), so the
        // wording stays uniform across tab counts.
        _ = tabCount
        if isOnlyPane {
            return String(
                localized: "workspace.closePane.alert.title.only",
                defaultValue: "Reset entire area?"
            )
        }
        return String(
            localized: "workspace.closePane.alert.title",
            defaultValue: "Close this area?"
        )
    }

    private static func closePaneConfirmLabel(tabCount: Int, isOnlyPane: Bool) -> String {
        _ = tabCount
        if isOnlyPane {
            return String(
                localized: "workspace.closePane.alert.confirm.only",
                defaultValue: "Reset Entire Area"
            )
        }
        return String(
            localized: "workspace.closePane.alert.confirm",
            defaultValue: "Close Area"
        )
    }

    private static func closePaneConfirmationMessage(tabCount: Int, isOnlyPane: Bool) -> String {
        if isOnlyPane {
            if tabCount <= 0 {
                return String(
                    localized: "workspace.closePane.alert.body.only.empty",
                    defaultValue: "This area has no tabs. A new terminal will replace it."
                )
            }
            if tabCount == 1 {
                return String(
                    localized: "workspace.closePane.alert.body.only.one",
                    defaultValue: "Current tab that will be closed (a new terminal will replace it):"
                )
            }
            return String(
                localized: "workspace.closePane.alert.body.only.many",
                defaultValue: "Current tabs that will be closed (a new terminal will replace them):"
            )
        }

        if tabCount <= 0 {
            return String(
                localized: "workspace.closePane.alert.body.empty",
                defaultValue: "This area will be removed from the workspace. This cannot be undone."
            )
        }
        if tabCount == 1 {
            return String(
                localized: "workspace.closePane.alert.body.one",
                defaultValue: "Current tab that will be closed:"
            )
        }
        return String(
            localized: "workspace.closePane.alert.body.many",
            defaultValue: "Current tabs that will be closed:"
        )
    }

    /// Handle the "+" toolbar button: create a new tab in the given pane of
    /// the same kind as whatever surface is currently selected in that pane.
    /// Falls back to terminal when the pane has no selection or no matching
    /// panel type.
    private func createNewTabOfFocusedKind(inPane pane: PaneID) {
        let selectedPanelId = effectiveSelectedTabId(inPane: pane)
        let panel = selectedPanelId.flatMap { panels[$0] }
        switch panel?.panelType {
        case .browser where TabTypeAvailability.isEnabled(.browser):
            _ = newBrowserSurface(inPane: pane)
        case .markdown where TabTypeAvailability.isEnabled(.markdown):
            _ = newMarkdownTab(inPane: pane)
        case .terminal, .browser, .markdown, .none:
            // Terminal kinds, and any disabled non-terminal kind whose surface
            // is still open, fall back to a terminal so "+" stays useful.
            _ = newTerminalSurface(inPane: pane)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for bonsplitTab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            promptRenamePanel(bonsplitTabId: bonsplitTab.id)
        case .clearName:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            setTabCustomTitle(panelId: panelId, title: nil)
        case .closeTab:
            // Route through the same path as clicking the close X so the
            // shouldCloseTab gate (pin protection, dirty-confirm dialog,
            // workspace-on-last-surface routing) runs identically.
            markExplicitClose(bonsplitTabId: bonsplitTab.id)
            _ = controller.closeTab(bonsplitTab.id, inPane: pane)
        case .closePane:
            // Reuse the existing pane-close confirmation flow (same as
            // clicking the trailing-toolbar X on the tab bar). Handles the
            // only-pane-in-workspace degenerate case via "Reset entire pane?"
            // — the pane is reset with a fresh terminal rather than torn down.
            splitTabBar(controller, didRequestClosePane: pane)
        case .closeToLeft:
            closeTabs(bonsplitTabIdsToLeft(of: bonsplitTab.id, inPane: pane))
        case .closeToRight:
            closeTabs(bonsplitTabIdsToRight(of: bonsplitTab.id, inPane: pane))
        case .closeOthers:
            closeTabs(bonsplitTabIdsToCloseOthers(of: bonsplitTab.id, inPane: pane))
        case .move:
            promptMovePanel(bonsplitTabId: bonsplitTab.id)
        case .newTerminalToRight:
            createTerminalToRight(of: bonsplitTab.id, inPane: pane)
        case .newBrowserToRight:
            createBrowserToRight(of: bonsplitTab.id, inPane: pane)
        case .reload:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id),
                  let browser = browserPanel(for: panelId) else { return }
            browser.reload()
        case .duplicate:
            duplicateBrowserToRight(anchorBonsplitTabId: bonsplitTab.id, inPane: pane)
        case .togglePin:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            let shouldPin = !pinnedTabIds.contains(panelId)
            setTabPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            clearManualUnread(panelId: panelId)
        case .markAsUnread:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            markTabUnread(panelId)
        case .toggleZoom:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        case .clearColor:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            setTabCustomColor(panelId: panelId, color: nil)
        case .chooseCustomColor:
            guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
            promptCustomTabColor(panelId: panelId)
        case .surfaceDetails:
            showSurfaceDetails(forBonsplitTabId: bonsplitTab.id)
        case .copySurfaceRef:
            copySurfaceRef(forBonsplitTabId: bonsplitTab.id)
        @unknown default:
            break
        }
    }

    /// Copy the tab's `surface:N` handle to the clipboard and show a brief
    /// confirmation HUD. Routed from the tab right-click menu's copy item.
    func copySurfaceRef(forBonsplitTabId bonsplitTabId: TabID) {
        guard let panel = panel(for: bonsplitTabId) else { return }
        let ref = TerminalController.shared.surfaceRefOnly(forSurfaceUUID: panel.id)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ref, forType: .string)
        let copied = String(localized: "copyHUD.copiedPrefix", defaultValue: "Copied")
        CopyConfirmationHUD.show(message: "\(copied) \(ref)")
    }

    /// Open the Surface Details panel for the surface backing a tab. Routed
    /// from the tab right-click menu; the panel shows the `surface:N` /
    /// `tab:N` handles plus the surface metadata manifest.
    func showSurfaceDetails(forBonsplitTabId bonsplitTabId: TabID) {
        guard let panel = panel(for: bonsplitTabId) else { return }
        showSurfaceDetails(for: panel)
    }

    /// Open the Surface Details panel for a specific panel. Routed from the
    /// command palette (which targets the focused panel directly).
    func showSurfaceDetails(for panel: any TabContent) {
        let kind: TabManifestKind
        switch panel.panelType {
        case .terminal:
            kind = .terminal
        case .browser:
            kind = .browser
        case .markdown:
            kind = .markdown
        }
        TabManifestViewerWindowController.show(
            workspaceId: id,
            surfaceId: panel.id,
            kind: kind
        )
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTabColorPaletteEntry hex: String, for bonsplitTab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = tabIdFromBonsplitTabId(bonsplitTab.id) else { return }
        setTabCustomColor(panelId: panelId, color: hex)
    }

    private func promptCustomTabColor(panelId: UUID) {
        let seed = tabCustomColors[panelId] ?? "#1565C0"
        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.tabColor.title",
            defaultValue: "Custom Tab Color"
        )
        alert.informativeText = String(
            localized: "alert.tabColor.message",
            defaultValue: "Enter a hex color in the format #RRGGBB."
        )

        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(
            localized: "alert.tabColor.apply",
            defaultValue: "Apply"
        ))
        alert.addButton(withTitle: String(
            localized: "alert.tabColor.cancel",
            defaultValue: "Cancel"
        ))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let raw = input.stringValue
        guard let normalized = WorkspaceColorSettings.addCustomColor(raw) else {
            // Reuse the existing invalid-color path; mirror messaging used by
            // the workspace color flow so users see a consistent explanation.
            let invalid = NSAlert()
            invalid.alertStyle = .warning
            invalid.messageText = String(
                localized: "alert.invalidColor.title",
                defaultValue: "Invalid Color"
            )
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            invalid.informativeText = trimmed.isEmpty
                ? String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
                : String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
            invalid.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
            _ = invalid.runModal()
            return
        }
        setTabCustomColor(panelId: panelId, color: normalized)
        // Refresh the bonsplit palette so newly-added custom colors are
        // immediately visible in subsequent submenu opens.
        bonsplitController.tabColorPalette = Self.bonsplitTabColorPalette()
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        _ = snapshot
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
