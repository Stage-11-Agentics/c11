import Foundation

enum CodexAIValidators {
    /// Codex access tokens are JWTs (3 base64url-encoded segments
    /// separated by `.`). The first segment must start with `eyJ`
    /// (the URL-safe encoding of `{"`).
    static func isValidAccessToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        guard segments[0].hasPrefix("eyJ") else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=.")
        for scalar in trimmed.unicodeScalars {
            if !allowed.contains(scalar) { return false }
        }
        return true
    }

    /// Optional account id. Empty is accepted (request omits the header).
    /// Reject the `null` sentinel and any embedded whitespace.
    static func isValidAccountId(_ value: String) -> Bool {
        if value.isEmpty { return true }
        let lowered = value.lowercased()
        if lowered == "null" { return false }
        for scalar in value.unicodeScalars {
            if scalar.value < 0x21 || scalar.value == 0x7F {
                return false
            }
        }
        return true
    }
}

extension Providers {
    static let codex: AIUsageProvider = AIUsageProvider(
        id: "codex",
        displayName: "Codex",
        keychainService: "com.stage11.c11.aiusage.codex-accounts",
        credentialFields: [
            AIUsageCredentialField(
                id: "accessToken",
                label: String(
                    localized: "aiusage.codex.editor.accessToken",
                    defaultValue: "Access token"
                ),
                placeholder: String(
                    localized: "aiusage.codex.editor.accessToken.placeholder",
                    defaultValue: "eyJhbGciOi..."
                ),
                isSecret: true,
                helpText: String(
                    localized: "aiusage.codex.editor.accessToken.help",
                    defaultValue: "Run: jq -r .tokens.access_token < ~/.codex/auth.json"
                ),
                validate: CodexAIValidators.isValidAccessToken
            ),
            AIUsageCredentialField(
                id: "accountId",
                label: String(
                    localized: "aiusage.codex.editor.accountId",
                    defaultValue: "Account ID (optional)"
                ),
                placeholder: String(
                    localized: "aiusage.codex.editor.accountId.placeholder",
                    defaultValue: "abcd-1234-..."
                ),
                isSecret: false,
                helpText: String(
                    localized: "aiusage.codex.editor.accountId.help",
                    defaultValue: "Run: jq -r .tokens.account_id < ~/.codex/auth.json (leave blank if empty)"
                ),
                validate: CodexAIValidators.isValidAccountId
            ),
        ],
        statusPageURL: URL(string: "https://status.openai.com/"),
        statusSectionTitle: String(
            localized: "aiusage.codex.status.section",
            defaultValue: "Codex status"
        ),
        helpDocURL: URL(string: "https://github.com/Stage-11-Agentics/c11/blob/main/docs/ai-usage-monitoring.md#codex"),
        fetchUsage: CodexAIUsageFetcher.fetch,
        fetchStatus: {
            try await AIUsageStatusPagePoller.fetch(
                host: "status.openai.com",
                componentFilter: ["Codex Web", "Codex API", "CLI", "VS Code extension", "App"]
            )
        }
    )
}
