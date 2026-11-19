import Foundation

extension TerminalController {
    /// Worker-owned attention methods. Parsing and validation happen here;
    /// the only main hop resolves the live surface and commits the already
    /// validated mutation. The semaphore guarantees commit-before-response.
    nonisolated func v2FlagWorker(
        method: String,
        params: [String: Any],
        legacyMethod: String? = nil
    ) -> V2CallResult {
        if method.hasPrefix("flag.kind.") {
            return v2FlagKindWorker(method: method, params: params)
        }
        if method == "flag.list" {
            return v2FlagListWorker()
        }
        let validated: ValidatedFlagMutation
        switch Self.v2ValidateFlagMutation(method: method, params: params, legacyMethod: legacyMethod) {
        case .invalid(let error): return error
        case .valid(let value): validated = value
        }
        let tracksDelegateOwner = validated.tracksDelegateOwner
        let trimmedSurface = validated.surface
        let actor = validated.actor
        let callerPanelId = validated.callerPanelId
        let commit = FailClosedCommitGate<V2CallResult> {
            MainActor.assumeIsolated {
                guard let surfaceId = self.v2UUIDAny(trimmedSurface) else {
                    return .err(
                        code: "invalid_params",
                        message: "panel_id must be a UUID or panel ref",
                        data: nil
                    )
                }
                let preferredWorkspaceId = self.v2UUIDAny(params["workspace_id"])
                if let callerPanelId,
                   AppDelegate.shared?.workspaceContainingPanel(
                       panelId: callerPanelId,
                       preferredWorkspaceId: nil
                   ) == nil {
                    return .err(
                        code: "caller_surface_not_found",
                        message: "Calling panel not found",
                        data: nil
                    )
                }
                if tracksDelegateOwner,
                   PanelAttentionDelegationPolicy.isSelfDelegation(
                       callerPanelId: callerPanelId,
                       targetPanelId: surfaceId
                   ) {
                    return .err(
                        code: "self_delegation",
                        message: "A panel cannot delegate itself",
                        data: nil
                    )
                }
                guard let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: surfaceId,
                    preferredWorkspaceId: preferredWorkspaceId
                ) else {
                    return .err(code: "surface_not_found", message: "Panel not found", data: nil)
                }
                let workspace = located.workspace
                do {
                    let write: PanelMetadataStore.WriteResult
                    switch method {
                    case "flag.raise":
                        write = try Self.commitFlagRaise(
                            validated,
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            title: workspace.panelTitle(panelId: surfaceId)
                                ?? workspace.panels[surfaceId]?.displayTitle
                        )
                    case "flag.lower":
                        write = try PanelAttentionService.shared.lower(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                        workspace.recheckMailboxDoorbellAfterFlagLower(surfaceId: surfaceId)
                    case "flag.undelegate":
                        write = try PanelAttentionService.shared.undelegate(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            by: actor
                        )
                    case "flag.delegate":
                        write = try PanelAttentionService.shared.delegate(
                            workspaceId: workspace.id,
                            surfaceId: surfaceId,
                            ownerPanelId: tracksDelegateOwner ? callerPanelId : nil,
                            by: actor
                        )
                    default:
                        return .err(code: "method_not_found", message: "Unknown method", data: nil)
                    }
                    let snapshot = PanelMetadataStore.shared.attentionSnapshot(
                        workspaceId: workspace.id,
                        surfaceId: surfaceId
                    )
                    return .ok([
                        "workspace_id": workspace.id.uuidString,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspace.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceId),
                        "flag": self.v2OrNull(snapshot.flagReason),
                        "kind": snapshot.flagKind?.jsonObject ?? NSNull(),
                        "flag_raised_at": self.v2OrNull(snapshot.flagRaisedAt.map(EventEnvelope.formatTimestamp)),
                        "caller_surface_id": self.v2OrNull(
                            snapshot.flagCallerPanelId?.uuidString
                        ),
                        "delegated": snapshot.delegated,
                        "delegated_by": self.v2OrNull(snapshot.delegatedBy?.uuidString),
                        "suppressed": snapshot.delegated,
                        "applied": write.applied
                    ])
                } catch let error as PanelMetadataStore.WriteError {
                    return .err(code: "invalid_params", message: error.message, data: error.detailData)
                } catch {
                    return .err(code: "internal_error", message: "\(error)", data: nil)
                }
            }
        }
        commit.enqueueOnMain()
        return commit.wait(timeout: 8) ?? .err(
            code: "main_thread_timeout",
            message: "main thread did not begin the attention mutation before the deadline",
            data: nil
        )
    }

    enum FlagMutationValidation {
        case valid(ValidatedFlagMutation)
        case invalid(V2CallResult)
    }

    /// C11H-246: everything a flag write is checked for before its main hop,
    /// for a local caller and a relayed one alike (`C11RelayPolicy.admit`
    /// has already rewritten a relayed request's actor and caller).
    struct ValidatedFlagMutation {
        let method: String
        let surface: String
        let actor: PanelAttentionActor
        let reason: String?
        let kind: PanelFlagKind?
        let callerPanelId: UUID?
        let tracksDelegateOwner: Bool
        /// The machine a relayed request came from; nil on this Mac.
        let sourceHost: String?
    }

    nonisolated static func v2ValidateFlagMutation(
        method: String,
        params: [String: Any],
        legacyMethod: String? = nil
    ) -> FlagMutationValidation {
        var validated: ValidatedFlagMutation?
        let failure: V2CallResult? = {
            let tracksDelegateOwner = method == "flag.delegate"
            let isLegacyOwnerlessSuppression = legacyMethod == "flag.suppress"

            guard let rawSurface = params["surface_id"] as? String else {
                return .err(
                    code: params["surface_id"] == nil ? "missing_ref" : "invalid_params",
                    message: "panel_id is required and must be a UUID",
                    data: nil
                )
            }
            let trimmedSurface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSurface.isEmpty else {
                return .err(code: "empty_ref", message: "panel_id must not be empty", data: nil)
            }
            let actor: PanelAttentionActor
            if let rawActor = params["by"] as? String {
                guard rawActor == "operator" || rawActor == "agent",
                      let parsed = PanelAttentionActor(rawValue: rawActor) else {
                    return .err(
                        code: "invalid_params",
                        message: "by must be one of: operator, agent",
                        data: nil
                    )
                }
                actor = parsed
            } else {
                actor = .agent
            }

            var validatedReason: String?
            var validatedKind: PanelFlagKind?
            var callerPanelId: UUID?
            if method == "flag.raise" || tracksDelegateOwner {
                if method == "flag.raise" {
                    switch PanelAttentionReason.validate(params["reason"]) {
                    case .success(let reason):
                        validatedReason = reason
                    case .failure(let error):
                        return .err(code: "invalid_params", message: error.message, data: error.detailData)
                    }
                    if let rawKind = params["kind"], !(rawKind is NSNull) {
                        guard let kindID = rawKind as? String,
                              let kind = PanelFlagKindRegistry.shared.kind(id: kindID) else {
                            return .err(
                                code: "invalid_params",
                                message: "kind must be the id of a registered flag kind",
                                data: nil
                            )
                        }
                        validatedKind = kind
                    }
                }
                if let rawCaller = params["caller_surface_id"] as? String {
                    let trimmedCaller = rawCaller.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedCaller.isEmpty, let parsed = UUID(uuidString: trimmedCaller) else {
                        return .err(
                            code: "invalid_params",
                            message: "caller_panel_id must be a UUID",
                            data: nil
                        )
                    }
                    callerPanelId = parsed
                } else if params["caller_surface_id"] != nil {
                    return .err(
                        code: "invalid_params",
                        message: "caller_panel_id must be a UUID",
                        data: nil
                    )
                }
                if PanelAttentionDelegationPolicy.requiresCaller(
                    actor: actor,
                    callerPanelId: callerPanelId,
                    isLegacyOwnerlessSuppression: isLegacyOwnerlessSuppression
                ) {
                    return .err(
                        code: "missing_caller_surface",
                        message: tracksDelegateOwner
                            ? "agent delegation requires caller_panel_id"
                            : "agent-raised flags require caller_panel_id",
                        data: nil
                    )
                }
            }
            // C11H-246: the machine a relayed raise came from (nil on this Mac).
            // The relay executor sets it on this worker thread; read it before
            // the main hop, which runs without the request context.
            validated = ValidatedFlagMutation(
                method: method,
                surface: trimmedSurface,
                actor: actor,
                reason: validatedReason,
                kind: validatedKind,
                callerPanelId: callerPanelId,
                tracksDelegateOwner: tracksDelegateOwner,
                sourceHost: SocketCommandContext.current?.relayMachine
            )
            return nil
        }()
        if let failure { return .invalid(failure) }
        guard let validated else {
            return .invalid(.err(code: "internal_error", message: "flag validation produced no request", data: nil))
        }
        return .valid(validated)
    }

    /// The one commit every `flag.raise` makes once its panel is resolved.
    @MainActor
    static func commitFlagRaise(
        _ request: ValidatedFlagMutation,
        workspaceId: UUID,
        surfaceId: UUID,
        title: String?
    ) throws -> PanelMetadataStore.WriteResult {
        try PanelAttentionService.shared.raise(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            reason: request.reason ?? "",
            kind: request.kind,
            callerPanelId: request.callerPanelId,
            by: request.actor,
            title: title,
            sourceHost: request.sourceHost
        )
    }

    nonisolated private func v2FlagListWorker() -> V2CallResult {
        let commit = FailClosedCommitGate<V2CallResult> {
            MainActor.assumeIsolated {
                let flags = PanelAttentionIndex.shared.oldestFlags.map { snapshot in
                    [
                        "workspace_id": snapshot.workspaceId.uuidString,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: snapshot.workspaceId),
                        "surface_id": snapshot.surfaceId.uuidString,
                        "surface_ref": self.v2Ref(kind: .surface, uuid: snapshot.surfaceId),
                        "reason": snapshot.flagReason ?? "",
                        "kind": snapshot.flagKind?.jsonObject ?? NSNull(),
                        "raised_at": snapshot.flagRaisedAt.map(EventEnvelope.formatTimestamp) ?? "",
                        "caller_surface_id": self.v2OrNull(
                            snapshot.flagCallerPanelId?.uuidString
                        ),
                        "delegated": snapshot.delegated,
                        "delegated_by": self.v2OrNull(snapshot.delegatedBy?.uuidString),
                        "suppressed": snapshot.delegated
                    ]
                }
                return .ok(["flags": flags, "count": flags.count])
            }
        }
        commit.enqueueOnMain()
        return commit.wait(timeout: 8) ?? .err(
            code: "main_thread_timeout",
            message: "main thread did not begin the attention read before the deadline",
            data: nil
        )
    }

    nonisolated private func v2FlagKindWorker(
        method: String,
        params: [String: Any]
    ) -> V2CallResult {
        let registry = PanelFlagKindRegistry.shared
        switch method {
        case "flag.kind.list":
            let flagSound = NotificationSoundChannel.flag.choice(defaults: .standard)
            let kinds = registry.all().map { kind -> [String: Any] in
                var object = kind.registryJSONObject
                object["built_in"] = PanelFlagKindRegistry.isBuiltIn(kind.id)
                // C11H-226: null last_raised_at and 0 when never raised.
                let usage = registry.usage(id: kind.id)
                object["last_raised_at"] = usage.map { Self.flagKindTimestamp($0.lastRaisedAt) } ?? NSNull()
                object["raise_count"] = usage?.raiseCount ?? 0
                Self.addFlagKindSoundFields(to: &object, id: kind.id, registry: registry, flagSound: flagSound)
                return object
            }
            return .ok(["kinds": kinds, "count": kinds.count])
        case "flag.kind.set":
            guard let id = params["id"] as? String else {
                return .err(code: "invalid_params", message: "id is required", data: nil)
            }
            // C11H-319: `sound` alone changes only an existing kind's sound;
            // `flag` clears it (the kind then uses the flag sound). A sound name
            // is checked now; a path is imported (off main, here) only after
            // the kind checks pass, so a refused call stores nothing.
            var soundValue: String?
            if let rawSound = params["sound"], !(rawSound is NSNull) {
                guard let value = rawSound as? String else {
                    return .err(code: "invalid_params", message: "sound must be a string", data: nil)
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased() != Self.flagKindInheritSound,
                   !NotificationSoundChoice.looksLikePath(trimmed),
                   NotificationSoundChoice(rawValue: trimmed) == nil {
                    return .err(
                        code: "invalid_params",
                        message: NotificationSoundInput.Failure.unknownSound(trimmed).message,
                        data: nil
                    )
                }
                soundValue = trimmed
            }
            // C11H-330: whole seconds in 1...600, or null/absent for never.
            // Checked before anything is stored, like the sound name.
            var evaporateSeconds: Int?
            if let raw = params["evaporate_seconds"], !(raw is NSNull) {
                guard let value = PanelFlagKind.wholeSeconds(raw),
                      PanelFlagKind.evaporateSecondsRange.contains(value) else {
                    return .err(
                        code: "invalid_params",
                        message: "evaporate_seconds must be a whole number from 1 to 600, or null",
                        data: nil
                    )
                }
                evaporateSeconds = value
            }
            // C11H-330: evaporate_seconds belongs to the kind, so it needs a
            // full kind (name and color) and is never dropped by a sound-only set.
            let definesKind = params["name"] != nil || params["color"] != nil || params["emoji"] != nil
                || params["evaporate_seconds"] != nil
            let kind: PanelFlagKind?
            if definesKind {
                guard let name = params["name"] as? String,
                      let colorRaw = params["color"] as? String,
                      let color = PanelFlagColorToken(rawValue: colorRaw) else {
                    return .err(
                        code: "invalid_params",
                        message: "id, name, and color (\(PanelFlagColorToken.namesList)) are required",
                        data: nil
                    )
                }
                let emoji: String?
                if let rawEmoji = params["emoji"], !(rawEmoji is NSNull) {
                    guard let value = rawEmoji as? String else {
                        return .err(code: "invalid_params", message: "emoji must be a string", data: nil)
                    }
                    emoji = value
                } else {
                    emoji = nil
                }
                let candidate = PanelFlagKind(
                    id: id, name: name, color: color, emoji: emoji, evaporateSeconds: evaporateSeconds
                )
                guard candidate.isValid else {
                    return .err(
                        code: "invalid_params",
                        message: PanelFlagKindRegistryError.invalidKind.message,
                        data: nil
                    )
                }
                kind = candidate
            } else {
                guard soundValue != nil else {
                    return .err(
                        code: "invalid_params",
                        message: "id, name, and color (\(PanelFlagColorToken.namesList)) are required, or id and sound",
                        data: nil
                    )
                }
                guard registry.kind(id: id) != nil else {
                    return .err(
                        code: "not_found",
                        message: "no flag kind '\(id)'; pass --name and --color to create it",
                        data: nil
                    )
                }
                kind = nil
            }
            var soundChange: NotificationSoundChoice?? = nil
            if let soundValue {
                if soundValue.lowercased() == Self.flagKindInheritSound {
                    soundChange = .some(nil)
                } else {
                    switch NotificationSoundInput.choice(from: soundValue, allowsNone: true, store: .shared) {
                    case .success(let choice): soundChange = .some(choice)
                    case .failure(let failure):
                        return .err(code: "invalid_params", message: failure.message, data: nil)
                    }
                }
            }
            // AGENTS.md: UserDefaults is written on main only.
            let commit = FailClosedCommitGate<V2CallResult> {
                do {
                    if let kind { try registry.set(kind) }
                    if let soundChange { try registry.setSound(id: id, soundChange) }
                } catch let error as PanelFlagKindRegistryError {
                    return .err(code: "invalid_params", message: error.message, data: nil)
                } catch {
                    return .err(code: "internal_error", message: "failed to save flag kinds", data: nil)
                }
                guard let saved = registry.kind(id: id) else {
                    return .err(code: "internal_error", message: "failed to save flag kinds", data: nil)
                }
                var object = saved.registryJSONObject
                object["built_in"] = PanelFlagKindRegistry.isBuiltIn(saved.id)
                Self.addFlagKindSoundFields(
                    to: &object, id: id, registry: registry,
                    flagSound: NotificationSoundChannel.flag.choice(defaults: .standard)
                )
                return .ok(["kind": object])
            }
            commit.enqueueOnMain()
            guard let committed = commit.wait(timeout: 8) else {
                return .err(
                    code: "main_thread_timeout",
                    message: "main thread did not begin the flag kind write before the deadline",
                    data: nil
                )
            }
            // C11H-319: playback copies follow the sounds in use (off main, here).
            if soundChange != nil { NotificationSoundPlayback.sync() }
            return committed
        case "flag.kind.rm":
            guard let id = params["id"] as? String else {
                return .err(code: "invalid_params", message: "id is required", data: nil)
            }
            let hadSound = registry.sound(id: id) != nil
            let commit = FailClosedCommitGate<V2CallResult> {
                do {
                    let existed = try registry.remove(id: id)
                    let effective = registry.kind(id: id)
                    var result: [String: Any] = [
                        "id": id,
                        "removed": existed && !PanelFlagKindRegistry.isBuiltIn(id),
                        "reset_to_default": existed && PanelFlagKindRegistry.isBuiltIn(id),
                    ]
                    result["kind"] = effective?.registryJSONObject ?? NSNull()
                    return .ok(result)
                } catch let error as PanelFlagKindRegistryError {
                    return .err(code: "invalid_params", message: error.message, data: nil)
                } catch {
                    return .err(code: "internal_error", message: "failed to remove flag kind", data: nil)
                }
            }
            commit.enqueueOnMain()
            guard let committed = commit.wait(timeout: 8) else {
                return .err(
                    code: "main_thread_timeout",
                    message: "main thread did not begin the flag kind removal before the deadline",
                    data: nil
                )
            }
            if hadSound { NotificationSoundPlayback.sync() }
            return committed
        default:
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }

    /// C11H-319: `flag-kind set --sound flag` clears a kind's own sound.
    nonisolated static let flagKindInheritSound = "flag"

    /// `sound`: the operator's choice for the kind (null when it uses the
    /// flag sound); `effective_sound`: what a raise of it asks for now.
    nonisolated static func addFlagKindSoundFields(
        to object: inout [String: Any],
        id: String,
        registry: PanelFlagKindRegistry,
        flagSound: NotificationSoundChoice
    ) {
        let own = registry.sound(id: id)
        object["sound"] = own?.rawValue ?? NSNull()
        object["effective_sound"] = (own ?? flagSound).rawValue
    }

    /// ISO 8601 with the Mac's own offset, so a reader sees local time.
    nonisolated static func flagKindTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
