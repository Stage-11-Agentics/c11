import Foundation

extension Providers {
    static let claude: AIUsageProvider = AIUsageProvider(
        id: "claude",
        displayName: "Claude",
        keychainService: "com.stage11.c11.aiusage.claude-accounts",
        credentialFields: [],
        statusPageURL: URL(string: "https://status.claude.com/"),
        statusSectionTitle: String(
            localized: "aiusage.claude.status.section",
            defaultValue: "Claude.ai status"
        ),
        helpDocURL: URL(string: "https://github.com/Stage-11-Agentics/c11/blob/main/docs/ai-usage-monitoring.md#claude"),
        fetchUsage: { account, _ in
            try await ClaudeLocalUsageFetcher.fetchUsage(account: account)
        },
        fetchStatus: {
            try await AIUsageStatusPagePoller.fetch(
                host: "status.claude.com",
                componentFilter: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"]
            )
        }
    )
}
