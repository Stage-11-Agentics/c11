import Foundation

/// Value-only copy. No Workspace, Panel, view, store or mutable collection
/// escapes the main-thread capture. Projection and encoding run on the worker.
struct FleetSnapshot {
    struct Panel {
        let windowId: UUID
        let workspaceId: UUID
        let workspaceTitle: String
        let panelId: UUID
        let panelTitle: String
        let detectedKind: String?
        let activity: SidebarActivityState?
        let cold: Bool
        let unreadNotification: Bool
        let journalAttention: Bool
        let parentPanelId: UUID?
        let lastTurnEndedMs: Int64?
        let promptCache: PromptCacheObservation?
        let promptCacheUnknown: Bool
        let unreadMail: Int?
        let lastSeenAt: Date?
        let beingSeen: Bool
    }

    let capturedAt: Date
    let metadata: PanelMetadataStore.ReadSnapshot
    let panels: [Panel]
    let workspaceCount: Int
    let windowCount: Int
    let mainCopyDurationMs: Double

    func document() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = panels.compactMap { panel in
            let values = metadata.metadata[panel.workspaceId]?[panel.panelId] ?? [:]
            let sources = metadata.sources[panel.workspaceId]?[panel.panelId] ?? [:]
            let kind = PanelActivityTerminalKindResolver.resolve(
                detectedTerminalType: panel.detectedKind,
                declaredTerminalType: values[MetadataKey.terminalType] as? String
            )
            guard AreaSizePolicy.isAgentKind(kind) else { return nil }
            let model = AgentModelPrecedence.effective(
                model: values[MetadataKey.model] as? String,
                modelSource: sources[MetadataKey.model]?.source,
                modelLabel: values[MetadataKey.modelLabel] as? String,
                labelSource: sources[MetadataKey.modelLabel]?.source,
                detected: values[AgentModelDetector.MetadataKeys.detected] as? String
            )
            let reason = values[MetadataKey.flag] as? String
            let delegated = values[MetadataKey.suppressed] as? Bool ?? false
            let activity = PanelActivityResolver.resolve(
                hasExactSurfaceNotification: panel.unreadNotification,
                hasJournalAttention: panel.journalAttention,
                derivedActivity: panel.activity, isCold: panel.cold,
                terminalType: kind, flagged: reason != nil, suppressed: delegated
            )
            let lifecycle: String?
            switch activity {
            case .running: lifecycle = "working"
            case .waiting: lifecycle = "waiting"
            case .idle: lifecycle = "idle"
            case .cold: lifecycle = "cold"
            case nil: lifecycle = nil
            }
            var flagKind: [String: Any]?
            if let kind = PanelFlagKind.fromJSON(values[MetadataKey.flagKind]) {
                flagKind = kind.jsonObject
                flagKind?["emoji"] = kind.emoji as Any? ?? NSNull()
            }
            let cache = TerminalController.promptCacheField(
                panel.promptCache, reportedUnknown: panel.promptCacheUnknown, now: capturedAt, formatter: formatter)
            var cacheFields = cache as? [String: Any]
            if cacheFields != nil {
                for key in ["basis", "lifetime_seconds", "requested_at", "cold_at", "reset", "prompt_tokens", "misses"]
                where cacheFields?[key] == nil { cacheFields?[key] = NSNull() }
            }
            return [
                "window_id": panel.windowId.uuidString,
                "workspace_id": panel.workspaceId.uuidString,
                "workspace_title": panel.workspaceTitle,
                "panel_id": panel.panelId.uuidString,
                "panel_title": panel.panelTitle,
                "agent_type": kind as Any? ?? NSNull(),
                "model": model.model as Any? ?? NSNull(),
                "model_label": model.label as Any? ?? NSNull(),
                "lifecycle": lifecycle as Any? ?? NSNull(),
                "flag": reason != nil,
                "flag_reason": reason as Any? ?? NSNull(),
                "flag_kind": flagKind as Any? ?? NSNull(),
                "delegated": delegated,
                "delegated_by": values[MetadataKey.delegatedBy] as? String as Any? ?? NSNull(),
                "parent_panel_id": panel.parentPanelId?.uuidString as Any? ?? NSNull(),
                "last_turn_end": panel.lastTurnEndedMs.map {
                    formatter.string(from: Date(timeIntervalSince1970: Double($0) / 1000))
                } as Any? ?? NSNull(),
                "prompt_cache": cacheFields as Any? ?? NSNull(),
                "mailbox_address": values[MetadataKey.mailboxAddress] as? String as Any? ?? NSNull(),
                "mailbox_unread_count": panel.unreadMail as Any? ?? NSNull(),
                "description": values[MetadataKey.description] as? String as Any? ?? NSNull(),
                "last_seen_at": panel.lastSeenAt.map { formatter.string(from: $0) } as Any? ?? NSNull(),
                "being_seen": panel.beingSeen,
            ]
        }
        return [
            "schema_version": 1,
            "scope": "agents",
            "captured_at": formatter.string(from: capturedAt),
            "main_copy_duration_ms": mainCopyDurationMs,
            "serialization_on_main_thread": Thread.isMainThread,
            "window_count": windowCount,
            "workspace_count": workspaceCount,
            "panels": rows.sorted { ($0["panel_id"] as? String ?? "") < ($1["panel_id"] as? String ?? "") },
        ]
    }
}

extension TerminalController {
    /// A single async main copy is necessary for the live graph and its UI-owned
    /// caches. Everything else stays on the requesting worker, including JSON.
    nonisolated func v2FleetWorker(id: Any?, params: [String: Any], timeout: TimeInterval = 8) -> String {
        guard CapabilityFeatures.current.supports(.fleet) else {
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
        guard params.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "system.fleet takes no parameters")
        }
        // Initialize the registry before main capture (it may load manifests).
        _ = AgentIdentityPolicy.recognizedKinds
        let operation = SelectionReadOperation<FleetSnapshot>(timeout: timeout)
        let capture = {
            MainActor.assumeIsolated {
                guard operation.beginCapture() else { return }
                operation.complete(self.captureFleetSnapshot())
            }
        }
        if Thread.isMainThread { capture() } else { DispatchQueue.main.async(execute: capture) }
        guard let snapshot = operation.wait() else {
            return v2Error(id: id, code: "main_thread_timeout", message: String(
                localized: "browser.profile.error.mainThreadTimeout", defaultValue: "Main thread did not respond within deadline"))
        }
        let response = v2Ok(id: id, result: snapshot.document())
        guard operation.canPublish else {
            return v2Error(id: id, code: "main_thread_timeout", message: String(
                localized: "browser.profile.error.mainThreadTimeout", defaultValue: "Main thread did not respond within deadline"))
        }
        return response
    }

    func captureFleetSnapshot(mailboxBadges: MailboxBadgeStore = .shared) -> FleetSnapshot {
        let start = DispatchTime.now().uptimeNanoseconds
        let now = Date()
        let metadata = PanelMetadataStore.shared.readSnapshot()
        let workspaces = AppDelegate.shared?.fleetWorkspaces() ?? []
        var panels: [FleetSnapshot.Panel] = []
        panels.reserveCapacity(workspaces.count * 4)
        for (windowId, workspace) in workspaces {
            for panel in workspace.panels.values {
                guard panel.panelType == .terminal else { continue }
                let id = panel.id
                panels.append(.init(
                    windowId: windowId, workspaceId: workspace.id, workspaceTitle: workspace.title,
                    panelId: id, panelTitle: workspace.panelTitle(panelId: id) ?? panel.displayTitle,
                    detectedKind: workspace.detectedTerminalTypesByPanel[id],
                    activity: workspace.derivedActivityByPanel[id],
                    cold: workspace.coldAgentSurfaceIds.contains(id),
                    unreadNotification: AppDelegate.shared?.notificationStore?
                        .hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: id) ?? false,
                    journalAttention: workspace.journalByPanel[id]?.paintsAttention == true,
                    parentPanelId: PanelLineage.shared.parentPanelId(panelId: id),
                    lastTurnEndedMs: JournalCoordinator.shared.cachedLastTurnEndedMs(panelID: id),
                    promptCache: PromptCacheSources.observation(forPanel: id, now: now),
                    promptCacheUnknown: PromptCacheSources.reportsUnknown(forPanel: id),
                    unreadMail: mailboxBadges.knownSummary(panelId: id)?.unread,
                    lastSeenAt: PanelSeenTracker.shared.lastSeenAt(panelId: id),
                    beingSeen: PanelSeenTracker.shared.isBeingSeen(panelId: id)
                ))
            }
        }
        return FleetSnapshot(
            capturedAt: now, metadata: metadata, panels: panels,
            workspaceCount: workspaces.count, windowCount: Set(workspaces.map(\.windowId)).count,
            mainCopyDurationMs: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
