import Foundation
import CoreFoundation

extension TerminalController {
    nonisolated func v2JournalStatus(params: [String: Any]) -> V2CallResult {
        guard params.isEmpty else {
            return .err(code: "invalid_params", message: "journal.status takes no parameters", data: nil)
        }
        do {
            return .ok(try JournalCoordinator.shared.runtimeStatus())
        } catch {
            let code = (error as? JournalError)?.rawValue ?? JournalError.unavailable.rawValue
            return .err(code: code, message: code, data: nil)
        }
    }

    // Worker-only: ownership uses the ConversationStore actor, SQLite uses its utility queue.
    nonisolated func v2JournalAppend(params: [String: Any]) -> V2CallResult {
        guard Set(params.keys).isSubset(of: ["event", "interactive_pid"]), let object = params["event"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .err(code: JournalError.invalidEvent.rawValue, message: JournalError.invalidEvent.rawValue, data: nil)
        }
        do {
            let draft = try JournalDraft.decode(data)
            let pid: Int32?
            if let raw = params["interactive_pid"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.int32Value), number.int32Value > 1 else {
                    throw JournalError.invalidEvent
                }
                pid = number.int32Value
            } else { pid = nil }
            adoptLostJournalOwner(draft, interactivePID: pid)
            let result = try JournalCoordinator.shared.append(draft, interactivePID: pid)
            let bytes = try JSONEncoder().encode(result.receipt)
            let receipt = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            return .ok(receipt)
        } catch {
            let code = (error as? JournalError)?.rawValue ?? JournalError.unavailable.rawValue
            return .err(code: code, message: code, data: nil)
        }
    }

    /// SessionStart's `conversation.push` can miss its socket window while c11
    /// is busy. Nothing else reports the id, so the panel would keep its
    /// wrapper placeholder for life: no owner, no snapshot, no agent PID, and
    /// mail that never rings (C11-580). A later hook from the same interactive
    /// session names the id, so it recovers the owner before its own append.
    /// A panel whose owner is known pays two lock reads and nothing else. On
    /// an ownerless panel the hook's process must still be the panel's live
    /// interactive agent, and the store refuses an observation older than the
    /// panel's newest wrapper claim, so a late hook from an exited Claude
    /// cannot claim the next launch. A session a real ref refused is not
    /// tried again.
    private nonisolated func adoptLostJournalOwner(_ draft: JournalDraft, interactivePID: Int32?) {
        guard let owner = draft.adoptableOwner(interactivePID: interactivePID), let pid = interactivePID,
              JournalCoordinator.shared.target(panelID: owner.panelID) != nil,
              JournalCoordinator.shared.exactOwner(panelID: owner.panelID) == nil,
              !JournalCoordinator.shared.ownerRecoveryRefused(owner),
              JournalOwnerRecovery.isLiveSource(JournalOwnerRecovery.processInfo(pid: pid), emittedAtMs: draft.emittedAtMs),
              !ConversationStorePolicy.isDisabled,
              ConversationStrategyRegistry.v1.strategy(forKind: owner.agentKind)?.isValidId(owner.sessionID) != false
        else { return }
        let observedAtMs = draft.emittedAtMs
        let outcome = conversationStoreSync { store in
            await store.adoptHookSession(
                surfaceId: owner.panelID.uuidString,
                kind: owner.agentKind,
                id: owner.sessionID,
                observedAtMs: observedAtMs
            )
        }
        if outcome == .refusedByRealRef { JournalCoordinator.shared.noteOwnerRecoveryRefused(owner) }
    }

    nonisolated func v2JournalClear(params: [String: Any]) -> V2CallResult {
        guard Set(params.keys) == Set(["yes"]), (params["yes"] as? Bool) == true else {
            return .err(code: "invalid_params", message: "journal.clear requires yes=true", data: nil)
        }
        do {
            try JournalCoordinator.shared.clear()
            return .ok(["cleared": true])
        } catch {
            let code = (error as? JournalError)?.rawValue ?? JournalError.unavailable.rawValue
            return .err(code: code, message: code, data: nil)
        }
    }
}
