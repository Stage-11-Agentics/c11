import Foundation

extension TerminalController {
    // Worker-only: ownership uses the ConversationStore actor, SQLite uses its utility queue.
    nonisolated func v2JournalAppend(params: [String: Any]) -> V2CallResult {
        guard Set(params.keys) == ["event"], let object = params["event"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .err(code: JournalError.invalidEvent.rawValue, message: JournalError.invalidEvent.rawValue, data: nil)
        }
        do {
            let draft = try JournalDraft.decode(data)
            let result = try JournalCoordinator.shared.append(draft)
            let bytes = try JSONEncoder().encode(result.receipt)
            let receipt = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            return .ok(receipt)
        } catch {
            let code = (error as? JournalError)?.rawValue ?? JournalError.unavailable.rawValue
            return .err(code: code, message: code, data: nil)
        }
    }
}
