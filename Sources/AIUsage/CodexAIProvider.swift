import Foundation

extension Providers {
    static let codex: AIUsageProvider = AIUsageProvider(
        id: "codex",
        displayName: "Codex",
        keychainService: "com.stage11.c11.aiusage.codex-accounts",
        credentialFields: [],
        statusPageURL: URL(string: "https://status.openai.com/"),
        statusSectionTitle: String(
            localized: "aiusage.codex.status.section",
            defaultValue: "Codex status"
        ),
        helpDocURL: URL(string: "https://github.com/Stage-11-Agentics/c11/blob/main/docs/ai-usage-monitoring.md#codex"),
        fetchUsage: { account, _ in
            try await CodexLocalUsageFetcher.fetchUsage(account: account)
        },
        fetchStatus: {
            try await AIUsageStatusPagePoller.fetch(
                host: "status.openai.com",
                componentFilter: ["Codex Web", "Codex API", "CLI", "VS Code extension", "App"]
            )
        }
    )
}
