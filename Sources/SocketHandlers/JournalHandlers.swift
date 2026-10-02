import Foundation
import CoreFoundation

extension TerminalController {
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
            let result = try JournalCoordinator.shared.append(draft, interactivePID: pid)
            let bytes = try JSONEncoder().encode(result.receipt)
            let receipt = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            return .ok(receipt)
        } catch {
            let code = (error as? JournalError)?.rawValue ?? JournalError.unavailable.rawValue
            return .err(code: code, message: code, data: nil)
        }
    }
}
