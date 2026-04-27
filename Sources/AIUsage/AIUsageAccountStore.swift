import Foundation
import Combine
import os.log

@MainActor
final class AIUsageAccountStore: ObservableObject {
    static let shared = AIUsageAccountStore()

    @Published private(set) var accounts: [AIUsageAccount] = []

    static let defaultIndexKey = "c11.aiusage.accounts.index"

    private static let log = OSLog(subsystem: "com.stage11.c11", category: "aiusage")

    private let userDefaults: UserDefaults
    private let indexKey: String
    private let keychainServiceResolver: (String) -> String

    private init() {
        self.userDefaults = .standard
        self.indexKey = Self.defaultIndexKey
        self.keychainServiceResolver = Self.defaultResolver
        load()
        Task { [weak self] in await self?.pruneOrphanAccountsIfNeeded() }
    }

    init(userDefaults: UserDefaults,
         indexKey: String,
         keychainServiceResolver: ((String) -> String)? = nil) {
        self.userDefaults = userDefaults
        self.indexKey = indexKey
        self.keychainServiceResolver = keychainServiceResolver ?? Self.defaultResolver
        load()
    }

    private static let defaultResolver: (String) -> String = { providerId in
        AIUsageRegistry.provider(id: providerId)?.keychainService
            ?? "com.stage11.c11.aiusage.\(providerId)-accounts"
    }

    func reload() {
        load()
        Task { [weak self] in await self?.pruneOrphanAccountsIfNeeded() }
    }

    func add(providerId: String, displayName: String, secret: AIUsageSecret) async throws {
        let provider = AIUsageRegistry.provider(id: providerId)
        let service = keychainServiceResolver(providerId)
        let account = AIUsageAccount(
            providerId: providerId,
            displayName: displayName,
            keychainService: provider?.credentialFields.isEmpty == true ? nil : service
        )

        if provider?.credentialFields.isEmpty != true {
            try await AIUsageKeychain.save(secret: secret, for: account.id, service: service)
        }

        var next = accounts
        next.append(account)
        do {
            try persist(next)
            accounts = next
        } catch {
            if provider?.credentialFields.isEmpty != true {
                try? await AIUsageKeychain.delete(for: account.id, service: service)
            }
            throw error
        }
    }

    func addLocalAccount(providerId: String, displayName: String, sessionTokenLimit: Int) throws {
        let account = AIUsageAccount(
            providerId: providerId,
            displayName: displayName,
            sessionTokenLimit: sessionTokenLimit
        )
        var next = accounts
        next.append(account)
        try persist(next)
        accounts = next
    }

    func update(id: UUID, displayName: String, secret: AIUsageSecret) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AIUsageStoreError.notFound
        }
        let existing = accounts[index]
        let provider = AIUsageRegistry.provider(id: existing.providerId)

        if provider?.credentialFields.isEmpty == true {
            var next = accounts
            next[index].displayName = displayName
            try persist(next)
            accounts = next
            return
        }

        let service = existing.keychainService ?? keychainServiceResolver(existing.providerId)

        let previousSecret: AIUsageSecret?
        do {
            previousSecret = try await AIUsageKeychain.load(for: id, service: service)
        } catch AIUsageStoreError.notFound {
            previousSecret = nil
        } catch {
            throw error
        }

        try await AIUsageKeychain.update(secret: secret, for: id, service: service)

        var next = accounts
        next[index].displayName = displayName
        next[index].keychainService = service
        do {
            try persist(next)
            accounts = next
        } catch {
            if let previous = previousSecret {
                try? await AIUsageKeychain.update(secret: previous, for: id, service: service)
            }
            throw error
        }
    }

    func updateLocalAccount(id: UUID, displayName: String, sessionTokenLimit: Int) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AIUsageStoreError.notFound
        }
        var next = accounts
        next[index].displayName = displayName
        next[index].sessionTokenLimit = sessionTokenLimit
        try persist(next)
        accounts = next
    }

    func remove(id: UUID) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AIUsageStoreError.notFound
        }
        let existing = accounts[index]
        let provider = AIUsageRegistry.provider(id: existing.providerId)

        if provider?.credentialFields.isEmpty != true {
            let service = existing.keychainService ?? keychainServiceResolver(existing.providerId)
            try await AIUsageKeychain.delete(for: id, service: service)
        }

        var next = accounts
        next.remove(at: index)
        try persist(next)
        accounts = next
    }

    func secret(for id: UUID) async throws -> AIUsageSecret {
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw AIUsageStoreError.notFound
        }
        let service = account.keychainService ?? keychainServiceResolver(account.providerId)
        return try await AIUsageKeychain.load(for: id, service: service)
    }

    private func load() {
        if let data = userDefaults.data(forKey: indexKey) {
            do {
                accounts = try JSONDecoder().decode([AIUsageAccount].self, from: data)
            } catch {
                os_log(.error, log: Self.log,
                       "aiusage: failed to decode account index, %{public}@",
                       String(describing: error))
                accounts = []
            }
        } else {
            accounts = []
        }

        let hasClaudeAccount = accounts.contains {
            $0.providerId == Providers.claude.id
        }
        if !hasClaudeAccount {
            let claudeDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/projects")
            if FileManager.default.fileExists(atPath: claudeDir.path) {
                let auto = AIUsageAccount(
                    providerId: Providers.claude.id,
                    displayName: "Claude Code"
                )
                accounts.append(auto)
                try? persist(accounts)
            }
        }

        let hasCodexAccount = accounts.contains { $0.providerId == Providers.codex.id }
        if !hasCodexAccount {
            let codexDB = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite")
            if FileManager.default.fileExists(atPath: codexDB.path) {
                let auto = AIUsageAccount(id: UUID(), providerId: Providers.codex.id, displayName: "Codex")
                accounts.append(auto)
                try? persist(accounts)
            }
        }
    }

    private func persist(_ next: [AIUsageAccount]) throws {
        let data = try JSONEncoder().encode(next)
        userDefaults.set(data, forKey: indexKey)
    }

    func pruneOrphanAccountsIfNeeded() async {
        let snapshot = accounts
        var removeIds: Set<UUID> = []
        for account in snapshot {
            let provider = AIUsageRegistry.provider(id: account.providerId)
            if provider?.credentialFields.isEmpty == true { continue }
            let service = account.keychainService ?? keychainServiceResolver(account.providerId)
            let status = await AIUsageKeychain.probePresenceAsync(for: account.id, service: service)
            if status == errSecItemNotFound {
                removeIds.insert(account.id)
            }
        }
        guard !removeIds.isEmpty else { return }

        let keep = accounts.filter { !removeIds.contains($0.id) }
        accounts = keep
        try? persist(keep)
        os_log(.info, log: Self.log,
               "aiusage: pruned %ld orphan account(s) from index",
               removeIds.count)
    }
}
