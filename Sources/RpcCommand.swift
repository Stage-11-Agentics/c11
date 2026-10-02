import Foundation

/// Validates the raw local call before socket discovery or connection.
/// Params remain the caller's JSON; no send-text escapes or ID rewriting apply.
enum RpcCommand {
    struct ValidationError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ args: [String]) throws -> (method: String, params: [String: Any]) {
        let positional = args.filter { $0 != "--json" }
        guard (1...2).contains(positional.count),
              let method = positional.first, !method.isEmpty,
              method.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ValidationError(description: String(localized: "cli.rpc.usage", defaultValue: "rpc requires a method name and an optional JSON object."))
        }
        guard positional.count == 2 else { return (method, [:]) }
        guard let data = positional[1].data(using: .utf8),
              let params = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            throw ValidationError(description: String(localized: "cli.rpc.payload", defaultValue: "rpc payload must be a JSON object."))
        }
        return (method, params)
    }
}
