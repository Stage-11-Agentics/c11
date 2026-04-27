import Foundation

enum CodexAIUsageFetchError: Error, LocalizedError, AIUsageAppOwnedError {
    case invalidAccessToken
    case invalidAccountId
    case httpAuth(Int)
    case http404
    case http(Int)
    case badResponse
    case decoding
    case network

    var isAppOwned: Bool { true }

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return String(
                localized: "aiusage.codex.error.invalidAccessToken",
                defaultValue: "Access token is not valid."
            )
        case .invalidAccountId:
            return String(
                localized: "aiusage.codex.error.invalidAccountId",
                defaultValue: "Account ID is not valid."
            )
        case .httpAuth(let status):
            let format = String(
                localized: "aiusage.codex.error.httpAuth",
                defaultValue: "Sign-in expired (status %lld). Re-enter your access token."
            )
            return String(format: format, locale: .current, Int(status))
        case .http404:
            return String(
                localized: "aiusage.codex.error.http404",
                defaultValue: "Codex usage endpoint not found. The account may not have access."
            )
        case .http(let status):
            let format = String(
                localized: "aiusage.codex.error.http",
                defaultValue: "Codex returned status %lld."
            )
            return String(format: format, locale: .current, Int(status))
        case .badResponse:
            return String(
                localized: "aiusage.codex.error.badResponse",
                defaultValue: "Unexpected response from Codex."
            )
        case .decoding:
            return String(
                localized: "aiusage.codex.error.decoding",
                defaultValue: "Could not read Codex usage payload."
            )
        case .network:
            return String(
                localized: "aiusage.codex.error.network",
                defaultValue: "Network error while contacting Codex."
            )
        }
    }
}

enum CodexAIUsageFetcher {
    static let fetch: @Sendable (AIUsageSecret) async throws -> AIUsageWindows = { secret in
        guard let token = secret.fields["accessToken"], CodexAIValidators.isValidAccessToken(token) else {
            throw CodexAIUsageFetchError.invalidAccessToken
        }
        let accountId = secret.fields["accountId"] ?? ""
        guard CodexAIValidators.isValidAccountId(accountId) else {
            throw CodexAIUsageFetchError.invalidAccountId
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexAIUsageFetchError.badResponse
        }

        var headers: [String: String] = ["Authorization": "Bearer \(token)"]
        if !accountId.isEmpty {
            headers["chatgpt-account-id"] = accountId
        }

        let session = AIUsageHTTP.makeSession(timeout: 10)
        defer { session.invalidateAndCancel() }

        let payload: [String: Any]
        do {
            payload = try await AIUsageHTTP.getJSONObject(url: url, headers: headers, session: session)
        } catch let error as AIUsageHTTPError {
            switch error {
            case .http(let code) where code == 401 || code == 403:
                throw CodexAIUsageFetchError.httpAuth(code)
            case .http(404):
                throw CodexAIUsageFetchError.http404
            case .http(let code):
                throw CodexAIUsageFetchError.http(code)
            case .badResponse:
                throw CodexAIUsageFetchError.badResponse
            case .decoding:
                throw CodexAIUsageFetchError.decoding
            case .network:
                throw CodexAIUsageFetchError.network
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAIUsageFetchError.network
        }

        guard let rateLimit = payload["rate_limit"] as? [String: Any] else {
            throw CodexAIUsageFetchError.decoding
        }
        let session5h = try parseWindow(rateLimit["primary_window"] as? [String: Any])
        let session7d = try parseWindow(rateLimit["secondary_window"] as? [String: Any])
        return AIUsageWindows(session: session5h, week: session7d)
    }

    private static func parseWindow(_ raw: [String: Any]?) throws -> AIUsageWindow {
        guard let raw else { throw CodexAIUsageFetchError.decoding }

        let usedRaw = raw["used_percent"]
        let utilization = clamp(toNumber(usedRaw))

        guard let limit = raw["limit_window_seconds"] as? NSNumber else {
            throw CodexAIUsageFetchError.decoding
        }
        let windowSeconds = limit.doubleValue
        guard windowSeconds > 0 else {
            throw CodexAIUsageFetchError.decoding
        }

        let resetsAt: Date?
        if let after = raw["reset_after_seconds"] as? NSNumber {
            let value = after.doubleValue
            if value < 0 {
                throw CodexAIUsageFetchError.decoding
            }
            resetsAt = Date(timeIntervalSinceNow: value)
        } else if raw["reset_after_seconds"] == nil
                || raw["reset_after_seconds"] is NSNull {
            resetsAt = nil
        } else {
            throw CodexAIUsageFetchError.decoding
        }

        return AIUsageWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowSeconds: windowSeconds
        )
    }

    private static func toNumber(_ value: Any?) -> Int {
        if value is Bool { return 0 }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}
