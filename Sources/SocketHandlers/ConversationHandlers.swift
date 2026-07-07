import AppKit
import Foundation

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `conversation.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchConversation(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
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

    private func v2ConversationClaim(params: [String: Any]) -> V2CallResult {
        if ConversationStorePolicy.isDisabled {
            return .ok(["disabled": true, "kill_switch": "CMUX_DISABLE_CONVERSATION_STORE"])
        }
        guard let kind = v2String(params, "kind"), !kind.isEmpty else {
            return .err(code: "invalid_kind", message: "kind required", data: nil)
        }
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "surface resolution", data: nil)
        }
        let cwd = v2String(params, "cwd")
        let placeholder = v2String(params, "placeholder_id")
            ?? "wrapper-claim:\(surfaceId.uuidString):\(Int(Date().timeIntervalSince1970))"

        let result = conversationStoreSync { store in
            await store.claim(
                surfaceId: surfaceId.uuidString,
                kind: kind,
                cwd: cwd,
                placeholderId: placeholder
            )
        }
        // Bump the surface activity timestamp; the wrapper-claim establishes
        // the lower bound used by the Codex scrape filter.
        SurfaceActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        guard let ref = result else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
        return .ok([
            "surface_id": surfaceId.uuidString,
            "kind": ref.kind,
            "id": ref.id,
            "placeholder": ref.placeholder,
            "captured_via": ref.capturedVia.rawValue,
            "state": ref.state.rawValue
        ])
    }

    private func v2ConversationPush(params: [String: Any]) -> V2CallResult {
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
              let source = CaptureSource(rawValue: sourceStr) else {
            return .err(code: "invalid_source",
                        message: "source must be one of hook, scrape, manual, wrapperClaim",
                        data: nil)
        }
        // Validate id grammar against the strategy if registered.
        let registry = ConversationStrategyRegistry.v1
        if let strategy = registry.strategy(forKind: kind), !strategy.isValidId(id) {
            return .err(code: "invalid_id_grammar",
                        message: "id does not match the \(kind) strategy's grammar",
                        data: ["kind": kind])
        }
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "surface resolution", data: nil)
        }
        let cwd = v2String(params, "cwd")
        let reason = v2String(params, "diagnostic_reason")
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

        let ref = conversationStoreSync { store in
            await store.push(
                surfaceId: surfaceId.uuidString,
                kind: kind,
                id: id,
                source: source,
                cwd: cwd,
                state: state,
                diagnosticReason: reason,
                payload: payload
            )
        }
        SurfaceActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        guard let ref else {
            return .err(code: "internal_error", message: "store timeout", data: nil)
        }
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
            return .err(code: "internal_error", message: "surface resolution", data: nil)
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
                        message: "no active conversation for surface",
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

    private func v2ConversationList(params: [String: Any]) -> V2CallResult {
        let snap = conversationStoreSync { store in
            await store.snapshot()
        } ?? [:]
        let surfaceFilter = v2UUID(params, "surface_id")
        var entries: [[String: Any]] = []
        for (sid, surfaceConv) in snap {
            if let f = surfaceFilter, sid != f.uuidString { continue }
            if let active = surfaceConv.active {
                entries.append([
                    "surface_id": sid,
                    "kind": active.kind,
                    "id": active.id,
                    "placeholder": active.placeholder,
                    "captured_via": active.capturedVia.rawValue,
                    "state": active.state.rawValue,
                    "captured_at": active.capturedAt.timeIntervalSince1970,
                    "diagnostic_reason": v2OrNull(active.diagnosticReason),
                    "cwd": v2OrNull(active.cwd)
                ])
            }
        }
        // C11-24 review (M3): expose kill-switch state so operators
        // diagnosing "why isn't my session resuming?" can confirm
        // whether the store path is even active.
        return .ok([
            "conversations": entries,
            "is_disabled": ConversationStorePolicy.isDisabled
        ])
    }

    private func v2ConversationGet(params: [String: Any]) -> V2CallResult {
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "surface resolution", data: nil)
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

    private func v2ConversationClear(params: [String: Any]) -> V2CallResult {
        let surfaceResult = v2ResolveSurfaceForConversation(params: params)
        guard case .success(let surfaceId) = surfaceResult else {
            if case .failure(let err) = surfaceResult { return err }
            return .err(code: "internal_error", message: "surface resolution", data: nil)
        }
        _ = conversationStoreSync { store -> Void in
            await store.clear(surfaceId: surfaceId.uuidString)
        }
        SurfaceActivityTracker.shared.clear(surfaceId: surfaceId.uuidString)
        return .ok([
            "surface_id": surfaceId.uuidString,
            "result": "cleared"
        ])
    }
}
