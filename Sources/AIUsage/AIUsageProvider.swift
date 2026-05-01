import Foundation

struct AIUsageWindow: Sendable, Equatable {
    let utilization: Int
    let resetsAt: Date?
    let windowSeconds: TimeInterval
    var tokensUsed: Int = 0
    var costUSD: Double = 0.0
}

struct AIUsageWindows: Sendable, Equatable {
    let session: AIUsageWindow
    let week: AIUsageWindow
}

struct AIUsageSnapshot: Sendable, Equatable {
    let accountId: UUID
    let providerId: String
    let displayName: String
    let session: AIUsageWindow
    let week: AIUsageWindow
    let fetchedAt: Date
}

struct AIUsageIncident: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let status: String
    let impact: String
    let updatedAt: Date?
}

struct AIUsageCredentialField: Identifiable, Sendable {
    let id: String
    let label: String
    let placeholder: String
    let isSecret: Bool
    let helpText: String?
    let validate: (@Sendable (String) -> Bool)?

    init(id: String,
         label: String,
         placeholder: String,
         isSecret: Bool,
         helpText: String? = nil,
         validate: (@Sendable (String) -> Bool)? = nil) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.isSecret = isSecret
        self.helpText = helpText
        self.validate = validate
    }
}

struct AIUsageProvider: Identifiable, Sendable {
    let id: String
    let displayName: String
    let keychainService: String
    let credentialFields: [AIUsageCredentialField]
    let statusPageURL: URL?
    let statusSectionTitle: String
    let helpDocURL: URL?
    let fetchUsage: @Sendable (AIUsageAccount, AIUsageSecret) async throws -> AIUsageWindows
    let fetchStatus: (@Sendable () async throws -> [AIUsageIncident])?
}
