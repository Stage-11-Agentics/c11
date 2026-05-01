import Foundation

struct AIUsageAccount: Identifiable, Equatable, Codable {
    let id: UUID
    let providerId: String
    var displayName: String
    var keychainService: String?
    var sessionTokenLimit: Int = 0

    init(id: UUID = UUID(),
         providerId: String,
         displayName: String,
         keychainService: String? = nil,
         sessionTokenLimit: Int = 0) {
        self.id = id
        self.providerId = providerId
        self.displayName = displayName
        self.keychainService = keychainService
        self.sessionTokenLimit = sessionTokenLimit
    }
}

struct AIUsageSecret: Codable, Sendable, CustomStringConvertible,
                     CustomDebugStringConvertible, CustomReflectable {
    let fields: [String: String]

    init(fields: [String: String]) {
        self.fields = fields
    }

    var description: String {
        let keys = fields.keys.sorted()
        let body = keys.map { "\($0): <redacted>" }.joined(separator: ", ")
        return "AIUsageSecret(\(body))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        let children: [Mirror.Child] = fields.keys.sorted().map { key in
            (label: key, value: "<redacted>")
        }
        return Mirror(self, children: children, displayStyle: .struct)
    }
}

enum AIUsageStoreError: Error, LocalizedError, C11AppOwnedError {
    case keychain(OSStatus)
    case decoding
    case notFound

    var isAppOwned: Bool { true }

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let format = String(
                localized: "aiusage.store.error.keychainStatus",
                defaultValue: "Keychain error (status %lld)."
            )
            return String(format: format, locale: .current, Int(status))
        case .decoding:
            return String(
                localized: "aiusage.store.error.decoding",
                defaultValue: "Saved credential could not be read."
            )
        case .notFound:
            return String(
                localized: "aiusage.store.error.notFound",
                defaultValue: "Credential not found."
            )
        }
    }
}
