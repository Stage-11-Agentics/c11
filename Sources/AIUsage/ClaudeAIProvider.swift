import Foundation

enum ClaudeAIValidators {
    /// orgId: must be non-empty, contain only safe URL-path characters, and
    /// reject path traversal or scheme injection. We accept the typical UUID
    /// format and a small alphabet so future server-side changes do not break
    /// existing accounts, while still preventing `..`, `/`, `:`, `?`, `#`,
    /// whitespace, and control characters.
    static func isValidOrgId(_ orgId: String) -> Bool {
        guard !orgId.isEmpty else { return false }
        if orgId.contains("..") { return false }
        for scalar in orgId.unicodeScalars {
            if scalar.value < 0x21 { return false }
            switch scalar {
            case "/", ":", "?", "#", "%", " ":
                return false
            default:
                continue
            }
        }
        return true
    }

    /// sessionKey: non-empty, no separators that could break the Cookie
    /// header, no control characters. Accept an embedded `sessionKey=` prefix
    /// since users sometimes paste the full cookie segment.
    static func isValidSessionKey(_ sessionKey: String) -> Bool {
        guard !sessionKey.isEmpty else { return false }
        for scalar in sessionKey.unicodeScalars {
            if scalar.value < 0x21 || scalar.value == 0x7F { return false }
            if scalar == ";" || scalar == "," { return false }
        }
        return true
    }

    /// Strips one or more leading `sessionKey=` assignments so a user pasting
    /// the full cookie segment still works.
    static func strippedSessionKey(_ sessionKey: String) -> String {
        var value = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "sessionKey="
        while value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        return value
    }
}

extension Providers {
    static let claude: AIUsageProvider = AIUsageProvider(
        id: "claude",
        displayName: "Claude",
        keychainService: "com.stage11.c11.aiusage.claude-accounts",
        credentialFields: [
            AIUsageCredentialField(
                id: "sessionKey",
                label: String(
                    localized: "aiusage.claude.editor.sessionKey",
                    defaultValue: "Session key"
                ),
                placeholder: String(
                    localized: "aiusage.claude.editor.sessionKey.placeholder",
                    defaultValue: "sk-ant-sid01-..."
                ),
                isSecret: true,
                helpText: String(
                    localized: "aiusage.claude.editor.sessionKey.help",
                    defaultValue: "From claude.ai cookies"
                ),
                validate: ClaudeAIValidators.isValidSessionKey
            ),
            AIUsageCredentialField(
                id: "orgId",
                label: String(
                    localized: "aiusage.claude.editor.orgId",
                    defaultValue: "Organization ID"
                ),
                placeholder: String(
                    localized: "aiusage.claude.editor.orgId.placeholder",
                    defaultValue: "UUID"
                ),
                isSecret: false,
                helpText: String(
                    localized: "aiusage.claude.editor.orgId.help",
                    defaultValue: "From claude.ai network requests"
                ),
                validate: ClaudeAIValidators.isValidOrgId
            ),
        ],
        statusPageURL: URL(string: "https://status.claude.com/"),
        statusSectionTitle: String(
            localized: "aiusage.claude.status.section",
            defaultValue: "Claude.ai status"
        ),
        helpDocURL: URL(string: "https://github.com/Stage-11-Agentics/c11/blob/main/docs/ai-usage-monitoring.md#claude"),
        fetchUsage: ClaudeAIUsageFetcher.fetch,
        fetchStatus: {
            try await AIUsageStatusPagePoller.fetch(
                host: "status.claude.com",
                componentFilter: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"]
            )
        }
    )
}
