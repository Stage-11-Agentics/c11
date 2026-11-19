import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// C11H-365 (N12): a resume types its recorded folder into a shell, where
    /// a control byte is an editing key even inside quotes. A cwd holding any
    /// C0 byte or DEL is refused before anything is stored.
    nonisolated static func v2ConversationCwdRefusal(_ cwd: String?) -> V2CallResult? {
        guard let cwd, containsTerminalControlByte(cwd) else { return nil }
        return .err(code: "invalid_cwd", message: "cwd holds a control byte; c11 never types one into a resume", data: nil)
    }

    /// v2 dispatch slice for the `conversation.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchConversation(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "conversation.capture_runtime":
            return v2Result(id: id, self.v2ConversationCaptureRuntime(params: params))
        case "conversation.claim":
            return v2Result(id: id, self.v2ConversationClaim(params: params))
        case "conversation.push":
            return v2Result(id: id, self.v2ConversationPush(params: params))
        case "conversation.tombstone":
            return v2Result(id: id, self.v2ConversationTombstone(params: params))
        case "conversation.list":
            return v2Result(id: id, self.v2ConversationList(params: params))
        case "conversation.get":
            return v2Result(id: id, self.v2ConversationGet(params: params))
        case "conversation.clear":
            return v2Result(id: id, self.v2ConversationClear(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    /// Conversation wrapper calls carry a literal panel UUID, which can be
    /// resolved without touching AppKit. Keep legacy handle refs working with
    /// one short main-actor lookup, but keep the high-frequency OpenCode route
    /// stream off main.
    private nonisolated func v2ResolveConversationSurfaceOnWorker(
        params: [String: Any]
    ) -> Result<UUID, V2CallResult> {
        if let rawSurfaceID = v2String(params, "surface_id"),
           let surfaceID = UUID(uuidString: rawSurfaceID) {
            return .success(surfaceID)
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated { self.v2ResolveSurfaceForConversation(params: params) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.v2ResolveSurfaceForConversation(params: params) }
        }
    }

    /// OpenCode claims authenticate both the TUI process and the target
    /// terminal panel. This lookup is launch-time only; fail closed when the
    /// live panel or its shell-reported tty is unavailable.
    private nonisolated func v2OpenCodePanelTTYDeviceForClaim(surfaceId: UUID) -> UInt32? {
        let resolveOnMain = {
            MainActor.assumeIsolated { () -> UInt32? in
                let params: [String: Any] = ["surface_id": surfaceId.uuidString]
                guard case .success = self.v2ResolveLiveTerminalSurfaceForRuntimeCapture(params: params),
                      let app = AppDelegate.shared,
                      let located = app.locateSurface(surfaceId: surfaceId),
                      let workspace = located.workspaceManager.workspaces.first(where: { $0.id == located.workspaceId }),
                      let ttyName = workspace.panelTTYNames[surfaceId],
                      let device = TerminalPIDResolver.ttyDevice(for: ttyName) else { return nil }
                return UInt32(truncatingIfNeeded: device)
            }
        }
        if Thread.isMainThread { return resolveOnMain() }
        return DispatchQueue.main.sync(execute: resolveOnMain)
    }

    /// Accept an exact Codex conversation id reported by a tool subprocess
    /// running inside the target Codex session. Kind and provenance are fixed
    /// by this dedicated method; callers cannot relabel the report.
    private func v2ConversationCaptureRuntime(params: [String: Any]) -> V2CallResult {
        if ConversationStorePolicy.isDisabled {
            return .ok(["disabled": true, "kill_switch": "CMUX_DISABLE_CONVERSATION_STORE"])
        }
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(code: "invalid_id", message: "id required", data: nil)
        }
        guard let strategy = ConversationStrategyRegistry.v1.strategy(forKind: "codex"),
              strategy.isValidId(id) else {
            return .err(
                code: "invalid_id_grammar",
                message: "id does not match the codex strategy's grammar",
                data: ["kind": "codex"]
            )
        }
        // C11H-365 (N12): checked before the panel lookup, which needs a live
        // terminal: the check reads only the request.
        let cwd = v2String(params, "cwd")
        if let refusal = Self.v2ConversationCwdRefusal(cwd) { return refusal }
        let surfaceResult = v2ResolveLiveTerminalSurfaceForRuntimeCapture(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "panel resolution", data: nil)
        }
        let result = conversationStoreSync { store in
            await store.captureRuntimeEnv(
                surfaceId: surfaceId.uuidString,
                id: id,
                cwd: cwd
            )
        }
        guard let result else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        return .ok([
            "surface_id": surfaceId.uuidString,
            "kind": result.ref.kind,
            "id": result.ref.id,
            "captured_via": result.ref.capturedVia.rawValue,
            "state": result.ref.state.rawValue,
            "outcome": result.outcome.rawValue,
            "affected_surface_ids": result.affectedSurfaceIds
        ])
    }

    nonisolated func v2ConversationClaim(params: [String: Any]) -> V2CallResult {
        if ConversationStorePolicy.isDisabled {
            return .ok(["disabled": true, "kill_switch": "CMUX_DISABLE_CONVERSATION_STORE"])
        }
        guard let kind = v2String(params, "kind"), !kind.isEmpty else {
            return .err(code: "invalid_kind", message: "kind required", data: nil)
        }
        let surfaceResult = v2ResolveConversationSurfaceOnWorker(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "panel resolution", data: nil)
        }
        let cwd = v2String(params, "cwd")
        if let refusal = Self.v2ConversationCwdRefusal(cwd) { return refusal }
        let placeholder = v2String(params, "placeholder_id")
            ?? "wrapper-claim:\(surfaceId.uuidString):\(Int(Date().timeIntervalSince1970))"
        let expectedResumeId = v2String(params, "expected_resume_id")
        if let expectedResumeId {
            let valid = (kind == "codex" && UUID(uuidString: expectedResumeId) != nil)
                || (kind == "opencode" && isValidOpencodeSessionId(expectedResumeId))
            guard valid else {
                return .err(
                    code: "invalid_expected_resume_id",
                    message: "expected_resume_id must match the selected kind's session ID format",
                    data: nil
                )
            }
        }
        let interactivePID: Int32?
        let interactiveProcessStartTime: UInt64?
        if params["interactive_pid"] != nil {
            guard kind == "opencode", let rawPID = v2Int(params, "interactive_pid"),
                  rawPID > 0, rawPID <= Int(Int32.max) else {
                return .err(code: "invalid_interactive_pid",
                            message: "interactive_pid is supported only for a positive OpenCode TUI pid",
                            data: nil)
            }
            let claimedTuiPID = Int32(rawPID)
            guard let panelTTYDevice = v2OpenCodePanelTTYDeviceForClaim(surfaceId: surfaceId) else {
                return .err(code: "invalid_interactive_pid",
                            message: "OpenCode claims require a live target terminal with a known tty",
                            data: nil)
            }
            guard MailboxNativeDoorbell.verifiedOpenCodeTUIClaim(
                peerPID: SocketCommandContext.current?.callerPID,
                claimedTuiPID: claimedTuiPID,
                peerTTYDevice: SocketCommandContext.current?.callerTTYDevice,
                panelTTYDevice: panelTTYDevice
            ) else {
                return .err(code: "invalid_interactive_pid",
                            message: "interactive_pid must identify the foreground OpenCode TUI for the target panel terminal",
                            data: nil)
            }
            guard let tuiProcess = MailboxAgentForeground.processTerminalInfo(pid: claimedTuiPID),
                  !tuiProcess.isZombie, tuiProcess.startTime > 0 else {
                return .err(code: "invalid_interactive_pid",
                            message: "interactive_pid no longer identifies a live OpenCode TUI",
                            data: nil)
            }
            interactivePID = claimedTuiPID
            interactiveProcessStartTime = tuiProcess.startTime
        } else {
            interactivePID = nil
            interactiveProcessStartTime = nil
        }
        guard kind != "opencode" || interactivePID != nil else {
            return .err(
                code: "invalid_interactive_pid",
                message: "OpenCode lifecycle claims require an authenticated foreground TUI process",
                data: ["surface_id": surfaceId.uuidString]
            )
        }
        let openCodeRecoveryPayload: [String: PersistedJSONValue]?
        let recoveryClaimParameters: [(String, String)] = [
            ("recovery_home", ConversationLifecyclePayloadKey.openCodeRecoveryHome),
            ("recovery_xdg_data_home", ConversationLifecyclePayloadKey.openCodeRecoveryXDGDataHome),
            ("recovery_database_override", ConversationLifecyclePayloadKey.openCodeRecoveryDatabaseOverride),
        ]
        if kind == "opencode", let interactivePID, let interactiveProcessStartTime {
            var recoveryPayload: [String: PersistedJSONValue] = [
                ConversationLifecyclePayloadKey.openCodeRecoveryContextVersion: .number(1),
                ConversationLifecyclePayloadKey.openCodeTuiProcessStartTime: .number(Double(interactiveProcessStartTime))
            ]
            for (parameter, key) in recoveryClaimParameters {
                guard let raw = params[parameter] else { continue }
                guard let value = raw as? String,
                      value.utf8.count <= 4_096,
                      !value.contains("\0") else {
                    return .err(
                        code: "invalid_recovery_context",
                        message: "OpenCode recovery path metadata must be a bounded string",
                        data: ["key": parameter]
                    )
                }
                recoveryPayload[key] = .string(value)
            }
            openCodeRecoveryPayload = recoveryPayload
        } else {
            if recoveryClaimParameters.contains(where: { params[$0.0] != nil }) {
                return .err(
                    code: "invalid_recovery_context",
                    message: "OpenCode recovery context requires an authenticated TUI claim",
                    data: nil
                )
            }
            openCodeRecoveryPayload = nil
        }
        let expiresAt: Date?
        if params["expires_at_epoch_ms"] != nil {
            guard let epochMilliseconds = v2Int(params, "expires_at_epoch_ms"),
                  epochMilliseconds > 0 else {
                return .err(
                    code: "invalid_expiry",
                    message: "expires_at_epoch_ms must be a positive integer",
                    data: nil
                )
            }
            let seconds = Double(epochMilliseconds) / 1_000
            guard seconds.isFinite, seconds <= 253_402_300_799 else {
                return .err(
                    code: "invalid_expiry",
                    message: "expires_at_epoch_ms is outside the supported date range",
                    data: nil
                )
            }
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else {
            expiresAt = nil
        }
        if kind == "opencode", expectedResumeId != nil, expiresAt == nil {
            return .err(code: "expiry_required",
                        message: "OpenCode resume reservations require expires_at_epoch_ms",
                        data: nil)
        }
        if kind == "opencode", expectedResumeId != nil,
           let expiresAt, expiresAt.timeIntervalSinceNow > 300 {
            return .err(code: "expiry_too_long",
                        message: "OpenCode resume reservations are limited to five minutes",
                        data: nil)
        }
        if kind == "opencode", let interactivePID {
            if let expiresAt, expiresAt <= Date() {
                return .err(code: "request_expired",
                            message: "claim expired before the store mutation boundary",
                            data: nil)
            }
            // Close any persisted exact-route typed gate as soon as this fresh
            // foreground claim is verified, before waiting on ConversationStore.
            _ = ConversationStorePanelRefCache.shared.beginOpenCodeClaim(
                surfaceId: surfaceId,
                tuiPID: interactivePID
            )
        }

        let ref: ConversationRef
        if let expiresAt {
            let result = conversationStoreSync { store in
                await store.claim(
                    surfaceId: surfaceId.uuidString,
                    kind: kind,
                    cwd: cwd,
                    placeholderId: placeholder,
                    expectedResumeId: expectedResumeId,
                    interactivePID: interactivePID,
                    openCodeRecoveryPayload: openCodeRecoveryPayload,
                    expiresAt: expiresAt
                )
            }
            guard let result else {
                return .err(code: "internal_error", message: "store timeout", data: nil)
            }
            switch result {
            case .accepted(let accepted):
                ref = accepted
            case .expired:
                return .err(
                    code: "request_expired",
                    message: "claim expired before the store mutation boundary",
                    data: nil
                )
            }
        } else {
            guard let legacyRef = conversationStoreSync({ store in
                await store.claim(
                    surfaceId: surfaceId.uuidString,
                    kind: kind,
                    cwd: cwd,
                    placeholderId: placeholder,
                    expectedResumeId: expectedResumeId,
                    interactivePID: interactivePID,
                    openCodeRecoveryPayload: openCodeRecoveryPayload
                )
            }) else {
                return .err(code: "internal_error", message: "store timeout", data: nil)
            }
            ref = legacyRef
        }
        // Only an acknowledged claim bumps the activity floor. An expired
        // request is a complete no-op, including side-channel mutations.
        PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        return .ok([
            "surface_id": surfaceId.uuidString,
            "kind": ref.kind,
            "id": ref.id,
            "placeholder": ref.placeholder,
            "captured_via": ref.capturedVia.rawValue,
            "state": ref.state.rawValue
        ])
    }

    nonisolated func v2ConversationPush(params: [String: Any]) -> V2CallResult {
        if ConversationStorePolicy.isDisabled {
            return .ok(["disabled": true, "kill_switch": "CMUX_DISABLE_CONVERSATION_STORE"])
        }
        guard let kind = v2String(params, "kind"), !kind.isEmpty else {
            return .err(code: "invalid_kind", message: "kind required", data: nil)
        }
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(code: "invalid_id", message: "id required", data: nil)
        }
        guard let sourceStr = v2String(params, "source"),
              let source = CaptureSource(rawValue: sourceStr),
              source == .hook || source == .scrape || source == .manual else {
            return .err(code: "invalid_source",
                        message: "source must be one of hook, scrape, manual; runtimeEnv is reserved for conversation.capture_runtime and wrapperClaim for conversation.claim",
                        data: nil)
        }
        // Validate id grammar against the strategy if registered.
        let registry = ConversationStrategyRegistry.v1
        if let strategy = registry.strategy(forKind: kind), !strategy.isValidId(id) {
            return .err(code: "invalid_id_grammar",
                        message: "id does not match the \(kind) strategy's grammar",
                        data: ["kind": kind])
        }
        // Handle refs are backed by the live c11 model, so resolve them in a
        // short main-thread slice. Actor-store waits below remain on the socket
        // worker and cannot freeze the UI.
        let surfaceResult: Result<UUID, V2CallResult>
        surfaceResult = v2ResolveConversationSurfaceOnWorker(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "panel resolution", data: nil)
        }
        let cwd = v2String(params, "cwd")
        if let refusal = Self.v2ConversationCwdRefusal(cwd) { return refusal }
        let reason = v2String(params, "diagnostic_reason")
        let displayedRoot = params["displayed_root"] as? Bool ?? false
        let displayedRouteState = v2String(params, "displayed_route_state")
        let routeGenerationValue = v2Int(params, "displayed_route_generation")
        let hasDisplayedRouteMutation = displayedRoot || displayedRouteState != nil
        guard params["displayed_route_state"] == nil || displayedRouteState != nil,
              !(displayedRoot && displayedRouteState != nil) else {
            return .err(code: "invalid_displayed_route_state",
                        message: "displayed_route_state must be pending, child, or no-route and cannot be combined with displayed_root",
                        data: nil)
        }
        guard params["displayed_route_generation"] == nil
                || routeGenerationValue.map({ $0 > 0 }) == true,
              hasDisplayedRouteMutation == (routeGenerationValue != nil) else {
            return .err(code: "invalid_displayed_route_generation",
                        message: "displayed route mutations require a positive displayed_route_generation",
                        data: nil)
        }
        let routeGeneration = routeGenerationValue.map { Int64($0) }
        guard !displayedRoot || (kind == "opencode" && source == .hook) else {
            return .err(code: "invalid_displayed_root",
                        message: "displayed_root is reserved for OpenCode TUI root capture",
                        data: nil)
        }
        if let displayedRouteState,
           (kind != "opencode" || source != .hook || !["pending", "child", "no-route"].contains(displayedRouteState)) {
            return .err(
                code: "invalid_displayed_route_state",
                message: "displayed_route_state is reserved for OpenCode TUI route state",
                data: nil
            )
        }
        let stateRaw = (v2String(params, "state") ?? "alive").lowercased()
        // C11-24 review (I2): strict validation. Silent fallthrough to
        // .alive swallowed typos ("susended" → .alive) and corrupted the
        // state machine.
        let state: ConversationState
        switch stateRaw {
        case "ended": state = .unknown // SessionEnd → unknown; next-launch scrape reclassifies
        case "alive": state = .alive
        case "suspended": state = .suspended
        case "tombstoned": state = .tombstoned
        case "unknown": state = .unknown
        case "unsupported": state = .unsupported
        default:
            return .err(code: "invalid_state",
                        message: "state must be one of alive, suspended, ended, tombstoned, unknown, unsupported",
                        data: ["state": stateRaw])
        }
        // C11-24 review (I1): payload coercion + size cap.
        // - Bool bridges to NSNumber on Apple platforms; the previous
        //   ordering (NSNumber before Bool) silently coerced
        //   `{"is_async": true}` to `.number(1.0)`. Check Bool first via
        //   CFBoolean type id.
        // - The else-branch is now an explicit reject so nested
        //   objects/arrays/null don't disappear.
        // - Cap the total serialised payload at 64 KiB to match the
        //   metadata path; oversized hook input shouldn't be allowed to
        //   land in the snapshot.
        let payload: [String: PersistedJSONValue]?
        if let dict = params["payload"] as? [String: Any] {
            if let reservedKey = dict.keys.first(where: {
                ConversationLifecyclePayloadKey.genericPushReservedKeys.contains($0)
            }) {
                return .err(
                    code: "reserved_payload_key",
                    message: "payload key is written only by the authenticated conversation claim",
                    data: ["key": reservedKey]
                )
            }
            var out: [String: PersistedJSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                if let b = conversationBoolValue(v) {
                    out[k] = .bool(b)
                } else if let s = v as? String {
                    out[k] = .string(s)
                } else if let n = v as? NSNumber {
                    out[k] = .number(n.doubleValue)
                } else {
                    return .err(code: "invalid_payload",
                                message: "payload values must be string, number, or bool",
                                data: ["key": k])
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               data.count > Self.conversationPayloadMaxBytes {
                return .err(code: "payload_too_large",
                            message: "payload exceeds 64 KiB cap",
                            data: ["bytes": data.count])
            }
            payload = out
        } else if params["payload"] != nil {
            return .err(code: "invalid_payload",
                        message: "payload must be an object",
                        data: nil)
        } else {
            payload = nil
        }

        if displayedRoot {
            // SocketCommandContext is thread-local. Capture the authenticated
            // peer before conversationStoreSync moves work to a detached task.
            let callerPID = SocketCommandContext.current?.callerPID
            guard let routeGeneration,
                  ConversationStorePanelRefCache.shared.beginOpenCodeRouteChange(
                    surfaceId: surfaceId,
                    tuiPID: callerPID,
                    routeGeneration: routeGeneration,
                    capturesRoot: true,
                    targetID: id
                  ) else {
                return .err(code: "stale_route_generation",
                            message: "OpenCode route capture is older than the latest displayed route",
                            data: ["surface_id": surfaceId.uuidString])
            }
            let storeResult: DisplayedOpenCodeCaptureResult? = conversationStoreSync { store in
                await store.captureDisplayedOpenCodeRoot(
                    surfaceId: surfaceId.uuidString,
                    id: id,
                    cwd: cwd,
                    callerPID: callerPID,
                    routeGeneration: routeGeneration
                )
            }
            guard let result = storeResult else {
                return .err(code: "internal_error", message: "store timeout", data: nil)
            }
            switch result {
            case .conflict(let owners, let preservedRef):
                var response: [String: Any] = [
                    "surface_id": surfaceId.uuidString,
                    "kind": kind,
                    "id": id,
                    "outcome": "identity_conflict",
                    "owner_surface_ids": owners
                ]
                // Conflict polling stays off-main. Journal target identity
                // and panel metadata are lock-backed; names do not authorize
                // routing, which uses the authenticated cache alone.
                if let owner = ConversationStorePanelRefCache.shared.mailboxOwner(surfaceId: surfaceId),
                   owner.panelID != surfaceId,
                   let workspace = JournalCoordinator.shared.target(panelID: owner.panelID) {
                    let title = PanelMetadataStore.shared.metadataValue(workspaceId: workspace,
                        surfaceId: owner.panelID, key: MetadataKey.title) as? String ?? ""
                    let name = title.isEmpty ? "id:\(owner.panelID.uuidString)" : title
                    response["mailbox_owner"] = ["panel_id": owner.panelID.uuidString,
                        "workspace_id": workspace.uuidString, "name": name, "session_id": owner.sessionID]
                    response["mailbox_owner_notice"] = String(format: String(
                        localized: "mailbox.opencode.shared-owner",
                        defaultValue: "Shared OpenCode session. Mail and recv use %@ (%@)."
                    ), name, owner.panelID.uuidString)
                }
                if let preservedRef {
                    response["preserved_state"] = preservedRef.state.rawValue
                    if !preservedRef.placeholder { response["preserved_id"] = preservedRef.id }
                }
                return .ok(response)
            case .unauthorized:
                return .err(code: "displayed_root_caller_mismatch",
                            message: "displayed-root capture must come from the OpenCode TUI process reserved by this panel",
                            data: ["surface_id": surfaceId.uuidString])
            case .staleRouteGeneration:
                return .err(code: "stale_route_generation",
                            message: "OpenCode route capture is older than the latest displayed route",
                            data: ["surface_id": surfaceId.uuidString])
            case .accepted(let ref):
                PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
                DispatchQueue.main.async {
                    guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId),
                          let workspace = located.workspaceManager.workspaces.first(where: { $0.id == located.workspaceId }) else {
                        return
                    }
                    workspace.recheckMailboxDoorbellAfterOpenCodeRouteBound(surfaceId: surfaceId)
                }
                return .ok([
                    "surface_id": surfaceId.uuidString,
                    "kind": ref.kind,
                    "id": ref.id,
                    "captured_via": ref.capturedVia.rawValue,
                    "state": ref.state.rawValue,
                    "outcome": "accepted"
                ])
            }
        }

        if let displayedRouteState {
            // Preserve the socket peer across the detached actor hop just as
            // for root capture above.
            let callerPID = SocketCommandContext.current?.callerPID
            guard let routeGeneration,
                  ConversationStorePanelRefCache.shared.beginOpenCodeRouteChange(
                    surfaceId: surfaceId,
                    tuiPID: callerPID,
                    routeGeneration: routeGeneration,
                    capturesRoot: false,
                    targetID: id
                  ) else {
                return .err(code: "stale_route_generation",
                            message: "OpenCode route update is older than the latest displayed route",
                            data: ["surface_id": surfaceId.uuidString])
            }
            let storeResult: OpenCodeUnboundRouteResult? = conversationStoreSync { store in
                await store.markDisplayedOpenCodeRouteUnbound(
                    surfaceId: surfaceId.uuidString,
                    id: id,
                    cwd: cwd,
                    routeState: displayedRouteState,
                    callerPID: callerPID,
                    routeGeneration: routeGeneration
                )
            }
            guard let result = storeResult else {
                return .err(code: "internal_error", message: "store timeout", data: nil)
            }
            switch result {
            case .unauthorized:
                return .err(code: "displayed_route_caller_mismatch",
                            message: "displayed-route state must come from the OpenCode TUI process reserved by this panel",
                            data: ["surface_id": surfaceId.uuidString])
            case .staleRouteGeneration:
                return .err(code: "stale_route_generation",
                            message: "OpenCode route update is older than the latest displayed route",
                            data: ["surface_id": surfaceId.uuidString])
            case .accepted(let ref):
                PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
                return .ok([
                    "surface_id": surfaceId.uuidString,
                    "kind": ref.kind,
                    "id": ref.id,
                    "displayed_id": id,
                    "placeholder": ref.placeholder,
                    "state": ref.state.rawValue,
                    "outcome": "unbound"
                ])
            }
        }

        let storeResult: ConversationRef?? = conversationStoreSync { store in
            await store.push(
                surfaceId: surfaceId.uuidString,
                kind: kind,
                id: id,
                source: source,
                cwd: cwd,
                state: state,
                diagnosticReason: reason,
                payload: payload,
                sessionEnded: stateRaw == "ended"
            )
        }
        guard case .some(let maybeRef) = storeResult else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        guard let ref = maybeRef else {
            return .err(
                code: "protected_route",
                message: "generic conversation pushes cannot replace an authenticated OpenCode v2 route or write claim metadata",
                data: ["surface_id": surfaceId.uuidString]
            )
        }
        PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        return .ok([
            "surface_id": surfaceId.uuidString,
            "kind": ref.kind,
            "id": ref.id,
            "captured_via": ref.capturedVia.rawValue,
            "state": ref.state.rawValue
        ])
    }

    private func v2ConversationTombstone(params: [String: Any]) -> V2CallResult {
        // C11-24 review (B4): the CLI requires --kind and --id and the
        // operator typically targets a specific stale ref. Tombstoning
        // the active ref unconditionally is a footgun: typing
        // `c11 conversation tombstone --kind codex --id <old>` from a
        // surface whose active ref is now a different conversation used
        // to wipe the current one. Validate kind+id against the active
        // ref before mutating.
        guard let kind = v2String(params, "kind"), !kind.isEmpty else {
            return .err(code: "invalid_kind", message: "kind required", data: nil)
        }
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(code: "invalid_id", message: "id required", data: nil)
        }
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "panel resolution", data: nil)
        }
        let reason = v2String(params, "reason")
        // The bridge wraps each result in Optional (nil = store timeout),
        // and `active(for:)` itself returns Optional. Unwrap both.
        let activeOpt: ConversationRef?? = conversationStoreSync { store in
            await store.active(for: surfaceId.uuidString)
        }
        guard case .some(let maybeActive) = activeOpt else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        guard let active = maybeActive else {
            return .err(code: "not_found",
                        message: "no active conversation for panel",
                        data: ["surface_id": surfaceId.uuidString])
        }
        if active.kind != kind || active.id != id {
            return .err(code: "id_mismatch",
                        message: "active ref kind/id does not match request",
                        data: [
                            "surface_id": surfaceId.uuidString,
                            "active_kind": active.kind,
                            "active_id": active.id,
                            "requested_kind": kind,
                            "requested_id": id
                        ])
        }
        _ = conversationStoreSync { store -> Void in
            await store.tombstone(surfaceId: surfaceId.uuidString, reason: reason)
        }
        return .ok([
            "surface_id": surfaceId.uuidString,
            "kind": kind,
            "id": id,
            "result": "tombstoned"
        ])
    }

    func v2ConversationList(params: [String: Any]) -> V2CallResult {
        let snap = conversationStoreSync { store in
            await store.snapshot()
        }
        return Self.conversationListPayload(
            snapshot: snap,
            isDisabled: ConversationStorePolicy.isDisabled,
            surfaceFilter: v2UUID(params, "surface_id")
        )
    }

    /// A nil snapshot is the 2 s store timeout. An empty list would look like
    /// "no live sessions" and `find --open` could resume a second copy.
    nonisolated static func conversationListPayload(
        snapshot: [String: PanelConversations]?,
        isDisabled: Bool,
        surfaceFilter: UUID?
    ) -> V2CallResult {
        guard let snap = snapshot else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        var entries: [[String: Any]] = []
        for (sid, surfaceConv) in snap {
            if let surfaceFilter, sid != surfaceFilter.uuidString { continue }
            if let active = surfaceConv.active {
                entries.append([
                    "surface_id": sid,
                    "kind": active.kind,
                    "id": active.id,
                    "placeholder": active.placeholder,
                    "captured_via": active.capturedVia.rawValue,
                    "state": active.state.rawValue,
                    "captured_at": active.capturedAt.timeIntervalSince1970,
                    "diagnostic_reason": active.diagnosticReason ?? NSNull(),
                    "cwd": active.cwd ?? NSNull()
                ])
            }
        }
        // C11-24 review (M3): expose kill-switch state so operators
        // diagnosing "why isn't my session resuming?" can confirm
        // whether the store path is even active. `find --open` refuses
        // when this flag is true.
        return .ok([
            "conversations": entries,
            "is_disabled": isDisabled
        ])
    }

    func v2ConversationGet(params: [String: Any]) -> V2CallResult {
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "panel resolution", data: nil)
        }
        let surfaceConv = conversationStoreSync { store in
            await store.conversations(for: surfaceId.uuidString)
        }
        guard let surfaceConv else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        var out: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "active": NSNull(),
            "can_resume": false,
            "history": surfaceConv.history.map { conversationRefAsDict($0) }
        ]
        if let active = surfaceConv.active {
            out["active"] = conversationRefAsDict(active)
            let registry = ConversationStrategyRegistry.v1
            if let strategy = registry.strategy(forKind: active.kind) {
                if case .skip = strategy.resume(ref: active) {
                    out["can_resume"] = false
                } else {
                    out["can_resume"] = true
                }
            }
        }
        return .ok(out)
    }

    /// `conversation.resume` (C11-468): rerun this launch's resume decision
    /// for the panels it skipped, or for one named panel, and type the command
    /// only into a panel nobody has used since launch. Runs on the socket
    /// worker: the store read and any transcript stat stay off main; one main
    /// hop resolves targets, decides, and schedules the staggered typing.
    nonisolated func v2ConversationResume(params: [String: Any]) -> V2CallResult {
        if ConversationStorePolicy.isDisabled {
            return .ok(["disabled": true, "kill_switch": "CMUX_DISABLE_CONVERSATION_STORE"])
        }
        let allSkipped = v2Bool(params, "all_skipped") ?? false
        let dryRun = v2Bool(params, "dry_run") ?? false
        let namesPanel = params["surface_id"] != nil
        guard allSkipped != namesPanel else {
            return .err(
                code: "invalid_params",
                message: "pass exactly one of --panel <ref> or --all-skipped",
                data: nil
            )
        }

        let mode = StartupConversationAudit.shared.mode
        let registry = ConversationStrategyRegistry.v1
        let storeRead = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var conversations: [String: PanelConversations]?
        Task.detached(priority: .userInitiated) {
            conversations = await ConversationStore.shared.snapshot()
            storeRead.signal()
        }
        guard storeRead.wait(timeout: .now() + 2.0) == .success, let conversations else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        // A dirty launch needs transcript evidence. Refs whose crash-recovery
        // diagnostic no longer says (a later push replaced it) are statted
        // here, off main.
        var evidence: [String: ResumeTranscriptEvidence] = [:]
        if mode == .dirty {
            let filesystem = DefaultConversationFilesystem()
            for (surfaceId, panel) in conversations {
                guard let ref = panel.active,
                      Workspace.transcriptEvidence(for: ref, mode: mode) == .unavailable,
                      let exists = registry.strategy(forKind: ref.kind)?
                        .transcriptExists(for: ref, filesystem: filesystem) else { continue }
                evidence[surfaceId] = exists ? .verified : .missing
            }
        }

        let main = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult = .err(code: "internal_error", message: "resume", data: nil)
        Task { @MainActor in
            defer { main.signal() }
            result = self.conversationResumeOnMain(
                params: params,
                allSkipped: allSkipped,
                dryRun: dryRun,
                mode: mode,
                registry: registry,
                conversations: conversations,
                evidence: evidence
            )
        }
        main.wait()
        return result
    }

    /// C11H-196: `c11 restore status`. One main hop reads every panel's
    /// restore record; nothing is focused, shown or changed.
    nonisolated func v2RestoreStatus() -> V2CallResult {
        return Self.restoreMainHop(label: "restore status") { Self.restoreStatusOnMain() }
    }

    /// One main hop with a 5 s claim: whichever side claims first wins. A hop
    /// that never started by the deadline never runs (no late scheduling after
    /// the CLI was told it timed out); one that started is waited for.
    nonisolated static func restoreMainHop(label: String, _ work: @escaping @MainActor () -> V2CallResult) -> V2CallResult {
        let main = DispatchSemaphore(value: 0)
        let claim = BoundedLifecycleDeadline()
        nonisolated(unsafe) var result: V2CallResult = .err(code: "internal_error", message: label, data: nil)
        Task { @MainActor in
            defer { main.signal() }
            guard claim.expire() else { return }
            result = work()
        }
        guard main.wait(timeout: .now() + 5) == .success else {
            if claim.expire() { return .err(code: "timeout", message: "\(label) timed out; nothing was changed", data: nil) }
            main.wait()
            return result
        }
        return result
    }

    @MainActor
    static func restoreStatusOnMain() -> V2CallResult {
        guard let app = AppDelegate.shared else { return .err(code: "unavailable", message: "app not ready", data: nil) }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var rows: [[String: Any]] = []
        var statuses: [HCHostEndStatus] = []
        for workspace in app.allMainWindowWorkspaces() {
            for (panelId, panel) in workspace.panels.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let terminal = panel as? TerminalPanel, let status = terminal.hcHostEnd else { continue }
                statuses.append(status)
                rows.append([
                    "panel_id": panelId.uuidString,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_title": workspace.title,
                    "panel_title": terminal.displayTitle,
                    "state": status.recordState,
                    "phase": status.stateToken,
                    "reason": status.reasonToken as Any? ?? NSNull(),
                    "cause": status.causeToken,
                    "signal": status.signal.map { Int($0) } as Any? ?? NSNull(),
                    "ended_at": formatter.string(from: status.endedAt),
                    "conversation_id": status.conversation?.id as Any? ?? NSNull(),
                    "conversation_kind": status.conversation?.kind as Any? ?? NSNull(),
                    "offers_resume": status.offersResume,
                    "shown": terminal.surface.isShownInRealWindow,
                ])
            }
        }
        let summary = HCRestoreProgress.summary(statuses)
        return .ok([
            "summary": [
                "total": summary.total, "pending": summary.pending, "resuming": summary.resuming,
                "resumed": summary.resumed, "failed": summary.failed, "skipped": summary.skipped,
                "need_you": summary.needYou, "finished": summary.isFinished,
            ],
            "panels": rows,
        ])
    }

    /// C11H-196: `c11 restore run`. For a panel whose record offers a resume
    /// (failed or skipped with a saved conversation): its fresh terminal starts
    /// in the background through the staggered queue and the resume is typed
    /// once, under the same guards as the automatic path. A panel resumed,
    /// resuming or still pending is refused, so a second run changes nothing.
    nonisolated func v2RestoreRun(params: [String: Any]) -> V2CallResult {
        let all = v2Bool(params, "all") ?? false
        let dryRun = v2Bool(params, "dry_run") ?? false
        guard all != (params["surface_id"] != nil) else {
            return .err(code: "invalid_params", message: "pass exactly one of --panel <ref> or --all", data: nil)
        }
        return Self.restoreMainHop(label: "restore run") { self.restoreRunOnMain(params: params, all: all, dryRun: dryRun) }
    }

    @MainActor
    private func restoreRunOnMain(params: [String: Any], all: Bool, dryRun: Bool) -> V2CallResult {
        guard let app = AppDelegate.shared else { return .err(code: "unavailable", message: "app not ready", data: nil) }
        var targets: [(Workspace, UUID)] = []
        if all {
            for workspace in app.allMainWindowWorkspaces() {
                for (panelId, panel) in workspace.panels.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    if let terminal = panel as? TerminalPanel, terminal.hcHostEnd?.offersResume == true {
                        targets.append((workspace, panelId))
                    }
                }
            }
        } else {
            if let rejected = v2RejectUnresolvedTargetRefs(params) { return rejected }
            guard let panelId = v2UUID(params, "surface_id"),
                  let workspace = app.allMainWindowWorkspaces().first(where: { $0.panels[panelId] != nil }) else {
                return .err(code: "not_found", message: "panel is not present in this c11 instance", data: nil)
            }
            targets.append((workspace, panelId))
        }
        var rows: [[String: Any]] = []
        for (workspace, panelId) in targets {
            let terminal = workspace.panels[panelId] as? TerminalPanel
            var row: [String: Any] = [
                "panel_id": panelId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "panel_title": terminal?.displayTitle as Any? ?? NSNull(),
                "conversation_id": terminal?.hcHostEnd?.conversation?.id as Any? ?? NSNull(),
            ]
            guard let terminal, let status = terminal.hcHostEnd else {
                row["outcome"] = "refused"
                row["reason"] = String(localized: "hc.hostEnd.notEnded", defaultValue: "This panel has no ended session to resume.")
                rows.append(row)
                continue
            }
            row["state"] = status.recordState
            guard status.offersResume else {
                row["outcome"] = status.recordState == "resumed" ? "already_resumed" : "not_needed"
                rows.append(row)
                continue
            }
            if dryRun {
                row["outcome"] = "would_resume"
            } else if let refusal = workspace.resumeHostEndedConversation(panelId: panelId) {
                row["outcome"] = "refused"
                row["reason"] = refusal
            } else {
                row["outcome"] = "scheduled"
            }
            rows.append(row)
        }
        return .ok(["dry_run": dryRun, "panels": rows])
    }

    private func conversationResumeOnMain(
        params: [String: Any],
        allSkipped: Bool,
        dryRun: Bool,
        mode: ResumeRecoveryMode,
        registry: ConversationStrategyRegistry,
        conversations: [String: PanelConversations],
        evidence: [String: ResumeTranscriptEvidence]
    ) -> V2CallResult {
        guard let app = AppDelegate.shared else {
            return .err(code: "unavailable", message: "app not ready", data: nil)
        }
        var targets: [(workspace: Workspace, panelId: UUID)] = []
        if allSkipped {
            for workspace in app.allMainWindowWorkspaces() {
                for (panelId, outcome) in workspace.launchResumeOutcomes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    if case .skipped = outcome { targets.append((workspace, panelId)) }
                }
            }
        } else {
            if let rejected = v2RejectUnresolvedTargetRefs(params) { return rejected }
            guard let panelId = v2UUID(params, "surface_id"),
                  let workspace = app.allMainWindowWorkspaces().first(where: { $0.panels[panelId] != nil }) else {
                return .err(code: "not_found", message: "panel is not present in this c11 instance", data: nil)
            }
            guard workspace.panels[panelId] is TerminalPanel else {
                return .err(code: "invalid_panel", message: "conversation resume targets terminal panels", data: nil)
            }
            targets.append((workspace, panelId))
        }

        var rows: [[String: Any]] = []
        var scheduled = 0
        for (workspace, panelId) in targets {
            // C11H-98: one target's whole decision lives in Workspace, so the
            // live-agent keep before any decision is testable without an app.
            rows.append(workspace.conversationResumeTarget(
                panelId: panelId,
                conversation: conversations[panelId.uuidString]?.active,
                registry: registry,
                mode: mode,
                transcriptEvidence: evidence[panelId.uuidString],
                dryRun: dryRun,
                conversationsBySurface: conversations,
                liveWriters: { ref in
                    app.liveAttributedAgentSurfaceIds(matching: ref, excluding: panelId, conversationsBySurface: conversations)
                },
                schedule: { plan in
                    // Staggered like restore, through the same guarded
                    // submission, which rechecks everything at typing time.
                    workspace.dispatchRestartCommands(
                        [plan],
                        firstAt: .now() + Double(scheduled) * SessionPersistencePolicy.agentRestartStagger,
                        idleShellRequired: true,
                        launchScoped: false
                    )
                    scheduled += 1
                }
            ))
        }
        return .ok([
            "mode": mode.rawValue,
            "dry_run": dryRun,
            "panels": rows,
        ])
    }

    private func v2ConversationClear(params: [String: Any]) -> V2CallResult {
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "panel resolution", data: nil)
        }
        _ = conversationStoreSync { store -> Void in
            await store.clear(surfaceId: surfaceId.uuidString)
        }
        PanelActivityTracker.shared.clear(surfaceId: surfaceId.uuidString)
        return .ok([
            "surface_id": surfaceId.uuidString,
            "result": "cleared"
        ])
    }
}
