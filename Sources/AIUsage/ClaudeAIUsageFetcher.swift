import Foundation

enum ClaudeAIUsageFetchError: Error, LocalizedError, AIUsageAppOwnedError {
    case invalidOrgId
    case invalidSessionKey
    case httpAuth(Int)
    case http(Int)
    case badResponse
    case decoding
    case network

    var isAppOwned: Bool { true }

    var errorDescription: String? {
        switch self {
        case .invalidOrgId:
            return String(
                localized: "aiusage.claude.error.invalidOrgId",
                defaultValue: "Organization ID is not valid."
            )
        case .invalidSessionKey:
            return String(
                localized: "aiusage.claude.error.invalidSessionKey",
                defaultValue: "Session key is not valid."
            )
        case .httpAuth(let status):
            let format = String(
                localized: "aiusage.claude.error.httpAuth",
                defaultValue: "Sign-in expired (status %lld). Re-enter your session key."
            )
            return String(format: format, locale: .current, Int(status))
        case .http(let status):
            let format = String(
                localized: "aiusage.claude.error.http",
                defaultValue: "Claude returned status %lld."
            )
            return String(format: format, locale: .current, Int(status))
        case .badResponse:
            return String(
                localized: "aiusage.claude.error.badResponse",
                defaultValue: "Unexpected response from Claude."
            )
        case .decoding:
            return String(
                localized: "aiusage.claude.error.decoding",
                defaultValue: "Could not read Claude usage payload."
            )
        case .network:
            return String(
                localized: "aiusage.claude.error.network",
                defaultValue: "Network error while contacting Claude."
            )
        }
    }
}

enum ClaudeAIUsageFetcher {
    private static let sessionWindowSeconds: TimeInterval = 18_000
    private static let weekWindowSeconds: TimeInterval = 604_800

    static let fetch: @Sendable (AIUsageSecret) async throws -> AIUsageWindows = { secret in
        guard let orgIdRaw = secret.fields["orgId"], ClaudeAIValidators.isValidOrgId(orgIdRaw) else {
            throw ClaudeAIUsageFetchError.invalidOrgId
        }
        guard let sessionKeyRaw = secret.fields["sessionKey"],
              ClaudeAIValidators.isValidSessionKey(sessionKeyRaw) else {
            throw ClaudeAIUsageFetchError.invalidSessionKey
        }

        let stripped = ClaudeAIValidators.strippedSessionKey(sessionKeyRaw)
        guard !stripped.isEmpty else {
            throw ClaudeAIUsageFetchError.invalidSessionKey
        }

        guard let escaped = orgIdRaw.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
              let url = URL(string: "https://claude.ai/api/organizations/\(escaped)/usage") else {
            throw ClaudeAIUsageFetchError.invalidOrgId
        }

        let session = AIUsageHTTP.makeSession(timeout: 10)
        defer { session.invalidateAndCancel() }

        let payload: [String: Any]
        do {
            payload = try await AIUsageHTTP.getJSONObject(
                url: url,
                headers: ["Cookie": "sessionKey=\(stripped)"],
                session: session
            )
        } catch let error as AIUsageHTTPError {
            switch error {
            case .http(let code) where code == 401 || code == 403:
                throw ClaudeAIUsageFetchError.httpAuth(code)
            case .http(let code):
                throw ClaudeAIUsageFetchError.http(code)
            case .badResponse:
                throw ClaudeAIUsageFetchError.badResponse
            case .decoding:
                throw ClaudeAIUsageFetchError.decoding
            case .network:
                throw ClaudeAIUsageFetchError.network
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeAIUsageFetchError.network
        }

        let session5h = try parseWindow(
            payload["five_hour"] as? [String: Any],
            windowSeconds: sessionWindowSeconds
        )
        let session7d = try parseWindow(
            payload["seven_day"] as? [String: Any],
            windowSeconds: weekWindowSeconds
        )
        return AIUsageWindows(session: session5h, week: session7d)
    }

    private static func parseWindow(_ raw: [String: Any]?,
                                    windowSeconds: TimeInterval) throws -> AIUsageWindow {
        guard let raw else { throw ClaudeAIUsageFetchError.decoding }
        let utilization = try parseUtilization(raw["utilization"])
        let resetsAt = AIUsageISO8601DateParser.parse(raw["resets_at"] as? String)
        return AIUsageWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowSeconds: windowSeconds
        )
    }

    private static func parseUtilization(_ raw: Any?) throws -> Int {
        if raw is Bool { throw ClaudeAIUsageFetchError.decoding }
        if let int = raw as? Int {
            return clamp(int)
        }
        if let number = raw as? NSNumber {
            // Reject fractional values
            let double = number.doubleValue
            if double != Double(Int(double)) {
                throw ClaudeAIUsageFetchError.decoding
            }
            return clamp(Int(double))
        }
        throw ClaudeAIUsageFetchError.decoding
    }

    private static func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}
