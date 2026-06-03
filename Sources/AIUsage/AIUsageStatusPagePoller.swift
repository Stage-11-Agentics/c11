import Foundation

enum AIUsageStatusPageError: Error {
    case http(Int)
    case decoding
    case network(Error)
    case invalidHost(String)
}

enum AIUsageStatusPagePoller {
    static let allowedHosts: Set<String> = [
        "status.claude.com",
        "status.openai.com",
    ]

    static func fetch(host: String,
                      componentFilter: Set<String>? = nil) async throws -> [AIUsageIncident] {
        if host.contains("/") || host.contains(":") {
            throw AIUsageStatusPageError.invalidHost(host)
        }
        guard allowedHosts.contains(host) else {
            throw AIUsageStatusPageError.invalidHost(host)
        }
        guard let url = URL(string: "https://\(host)/api/v2/incidents.json") else {
            throw AIUsageStatusPageError.invalidHost(host)
        }

        let session = AIUsageHTTP.makeSession(timeout: 10)
        defer { session.invalidateAndCancel() }

        let payload: [String: Any]
        do {
            payload = try await AIUsageHTTP.getJSONObject(url: url, session: session)
        } catch let error as AIUsageHTTPError {
            switch error {
            case .http(let code): throw AIUsageStatusPageError.http(code)
            case .decoding: throw AIUsageStatusPageError.decoding
            case .badResponse: throw AIUsageStatusPageError.decoding
            case .network(let inner): throw AIUsageStatusPageError.network(inner)
            }
        } catch {
            throw AIUsageStatusPageError.network(error)
        }

        guard let raw = payload["incidents"] as? [[String: Any]] else {
            return []
        }

        var results: [AIUsageIncident] = []
        for entry in raw {
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else {
                continue
            }
            let status = entry["status"] as? String ?? ""
            let impact = entry["impact"] as? String ?? "none"
            switch status.lowercased() {
            case "resolved", "postmortem", "completed":
                continue
            default:
                break
            }
            if let filter = componentFilter, !filter.isEmpty {
                let components = entry["components"] as? [[String: Any]] ?? []
                if !components.isEmpty {
                    let names = components.compactMap { $0["name"] as? String }
                    if Set(names).isDisjoint(with: filter) {
                        continue
                    }
                }
            }
            let updatedAt = AIUsageISO8601DateParser.parse(entry["updated_at"] as? String)
            results.append(AIUsageIncident(
                id: id,
                name: name,
                status: status,
                impact: impact,
                updatedAt: updatedAt
            ))
        }
        return results
    }
}
