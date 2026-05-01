import Foundation
import Security

enum AIUsageKeychain {
    static func save(secret: AIUsageSecret, for accountId: UUID, service: String) async throws {
        try await detached {
            let payload = try JSONEncoder().encode(secret.fields)
            try writeAdd(payload: payload, accountId: accountId, service: service)
        }
    }

    static func update(secret: AIUsageSecret, for accountId: UUID, service: String) async throws {
        try await detached {
            let payload = try JSONEncoder().encode(secret.fields)
            try writeUpdate(payload: payload, accountId: accountId, service: service)
        }
    }

    static func load(for accountId: UUID, service: String) async throws -> AIUsageSecret {
        try await detached { () -> AIUsageSecret in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: accountId.uuidString,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else {
                    throw AIUsageStoreError.decoding
                }
                do {
                    let fields = try JSONDecoder().decode([String: String].self, from: data)
                    return AIUsageSecret(fields: fields)
                } catch {
                    throw AIUsageStoreError.decoding
                }
            case errSecItemNotFound:
                throw AIUsageStoreError.notFound
            default:
                throw AIUsageStoreError.keychain(status)
            }
        }
    }

    static func delete(for accountId: UUID, service: String) async throws {
        try await detached {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: accountId.uuidString,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                return
            default:
                throw AIUsageStoreError.keychain(status)
            }
        }
    }

    static func probePresence(for accountId: UUID, service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    static func probePresenceAsync(for accountId: UUID, service: String) async -> OSStatus {
        await withCheckedContinuation { cont in
            Task.detached(priority: .userInitiated) {
                cont.resume(returning: probePresence(for: accountId, service: service))
            }
        }
    }

    private static func writeAdd(payload: Data, accountId: UUID, service: String) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: payload,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            try writeUpdate(payload: payload, accountId: accountId, service: service)
        default:
            throw AIUsageStoreError.keychain(status)
        }
    }

    private static func writeUpdate(payload: Data, accountId: UUID, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try writeAdd(payload: payload, accountId: accountId, service: service)
        default:
            throw AIUsageStoreError.keychain(status)
        }
    }

    private static func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try body()
            }.value
        } onCancel: {
            // Keychain calls are short-lived; cancellation surfaces via task value.
        }
    }
}
