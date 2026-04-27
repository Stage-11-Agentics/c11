import AppKit
import Combine
import Foundation
import os.log

struct AIUsageFetchTimeoutError: Error, LocalizedError, C11AppOwnedError {
    var isAppOwned: Bool { true }

    var errorDescription: String? {
        String(
            localized: "aiusage.error.timeout",
            defaultValue: "Request timed out."
        )
    }
}

@MainActor
final class AIUsagePoller: ObservableObject {
    static let shared = AIUsagePoller()

    @Published private(set) var snapshots: [UUID: AIUsageSnapshot] = [:]
    @Published private(set) var fetchErrors: [UUID: String] = [:]
    @Published private(set) var incidents: [String: [AIUsageIncident]] = [:]
    @Published private(set) var statusLoaded: [String: Bool] = [:]
    @Published private(set) var statusFetchFailed: [String: Bool] = [:]
    @Published private(set) var statusHasSucceeded: [String: Bool] = [:]
    @Published private(set) var isRefreshing: Bool = false

    private let log = OSLog(subsystem: "com.stage11.c11", category: "aiusage")
    private let store: AIUsageAccountStore
    private let providersResolver: () -> [AIUsageProvider]
    private let providerByIdResolver: (String) -> AIUsageProvider?
    private let tickInterval: TimeInterval
    private let perFetchTimeout: TimeInterval
    private let visibilityProvider: () -> Bool

    // Test seam.
    private let tickBody: (@MainActor (_ force: Bool) async -> Void)?

    private var timer: DispatchSourceTimer?
    private var occlusionObserver: NSObjectProtocol?
    private var inFlightTask: Task<Void, Never>?
    private var hasPendingTick: Bool = false
    private var pendingForce: Bool = false
    private var taskGeneration: Int = 0
    private var tickCounter: Int = 0
    private var hasStarted: Bool = false

    private convenience init() {
        self.init(
            store: AIUsageAccountStore.shared,
            providersResolver: { AIUsageRegistry.all },
            providerByIdResolver: { AIUsageRegistry.provider(id: $0) },
            tickInterval: 60,
            perFetchTimeout: 20,
            visibilityProvider: {
                NSApp?.occlusionState.contains(.visible) ?? true
            },
            tickBody: nil
        )
    }

    init(store: AIUsageAccountStore,
         providersResolver: @escaping () -> [AIUsageProvider],
         providerByIdResolver: @escaping (String) -> AIUsageProvider?,
         tickInterval: TimeInterval = 60,
         perFetchTimeout: TimeInterval = 20,
         visibilityProvider: @escaping () -> Bool = { true },
         tickBody: (@MainActor (Bool) async -> Void)? = nil) {
        self.store = store
        self.providersResolver = providersResolver
        self.providerByIdResolver = providerByIdResolver
        self.tickInterval = tickInterval
        self.perFetchTimeout = perFetchTimeout
        self.visibilityProvider = visibilityProvider
        self.tickBody = tickBody
    }

    func start() {
        guard timer == nil else { return }
        hasStarted = true
        let queue = DispatchQueue(label: "com.stage11.c11.aiusage.timer", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleTick(force: false)
            }
        }
        self.timer = timer
        timer.resume()

        if occlusionObserver == nil {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.visibilityProvider() == true {
                        self?.scheduleTick(force: false)
                    }
                }
            }
        }

        scheduleTick(force: true)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        inFlightTask?.cancel()
        inFlightTask = nil
        hasPendingTick = false
        pendingForce = false
        isRefreshing = false
        hasStarted = false
    }

    func refreshNow() {
        guard hasStarted else { return }
        scheduleTick(force: true)
    }

    private func scheduleTick(force: Bool) {
        if !force, !visibilityProvider() {
            isRefreshing = false
            return
        }
        if inFlightTask != nil {
            hasPendingTick = true
            pendingForce = pendingForce || force
            return
        }
        taskGeneration &+= 1
        let generation = taskGeneration
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runTick(force: force, generation: generation)
            guard self.taskGeneration == generation else { return }
            self.inFlightTask = nil
            if self.hasPendingTick {
                self.hasPendingTick = false
                let nextForce = self.pendingForce
                self.pendingForce = false
                self.scheduleTick(force: nextForce)
            } else {
                self.isRefreshing = false
            }
        }
        inFlightTask = task
    }

    private func runTick(force: Bool, generation: Int) async {
        if let body = tickBody {
            await body(force)
            return
        }
        tickCounter &+= 1

        let accountsBefore = store.accounts
        guard !accountsBefore.isEmpty else {
            snapshots = [:]
            fetchErrors = [:]
            incidents = [:]
            statusLoaded = [:]
            statusFetchFailed = [:]
            statusHasSucceeded = [:]
            return
        }

        var newSnapshots: [UUID: AIUsageSnapshot] = [:]
        var newErrors: [UUID: String] = [:]

        for account in accountsBefore {
            guard let provider = providerByIdResolver(account.providerId) else {
                continue
            }
            let secret: AIUsageSecret
            do {
                secret = try await store.secret(for: account.id)
            } catch {
                newErrors[account.id] = localizedFetchErrorMessage(error)
                continue
            }
            do {
                let windows = try await runWithTimeout(perFetchTimeout) {
                    try await provider.fetchUsage(secret)
                }
                if generation != taskGeneration { return }
                newSnapshots[account.id] = AIUsageSnapshot(
                    accountId: account.id,
                    providerId: account.providerId,
                    displayName: account.displayName,
                    session: windows.session,
                    week: windows.week,
                    fetchedAt: Date()
                )
            } catch {
                if generation != taskGeneration { return }
                newErrors[account.id] = localizedFetchErrorMessage(error)
                os_log(.info, log: log, "aiusage fetch failed: domain=%{public}@",
                       (error as NSError).domain)
            }
        }

        let liveAccounts = Set(store.accounts.map { $0.id })
        let liveProviderIds = Set(store.accounts.map { $0.providerId })
        snapshots = newSnapshots.filter { liveAccounts.contains($0.key) }
        fetchErrors = newErrors.filter { liveAccounts.contains($0.key) }

        let shouldFetchStatus = force || tickCounter == 1 || tickCounter % 5 == 0
        if shouldFetchStatus {
            for provider in providersResolver() where liveProviderIds.contains(provider.id) {
                guard let fetchStatus = provider.fetchStatus else { continue }
                statusLoaded[provider.id] = (statusLoaded[provider.id] ?? false)
                do {
                    let result = try await runWithTimeout(perFetchTimeout) {
                        try await fetchStatus()
                    }
                    if generation != taskGeneration { return }
                    incidents[provider.id] = result
                    statusLoaded[provider.id] = true
                    statusFetchFailed[provider.id] = false
                    statusHasSucceeded[provider.id] = true
                } catch {
                    if generation != taskGeneration { return }
                    statusLoaded[provider.id] = true
                    statusFetchFailed[provider.id] = true
                    incidents[provider.id] = nil
                }
            }
        }
    }

    private func runWithTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AIUsageFetchTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func localizedFetchErrorMessage(_ error: Error) -> String {
        if let storeError = error as? AIUsageStoreError {
            return storeError.errorDescription ?? genericFetchFailureString()
        }
        if error is AIUsageFetchTimeoutError {
            return AIUsageFetchTimeoutError().errorDescription ?? genericFetchFailureString()
        }
        if let local = error as? LocalizedError,
           let isAppOwned = (error as? C11AppOwnedError)?.isAppOwned,
           isAppOwned,
           let description = local.errorDescription {
            return description
        }
        return genericFetchFailureString()
    }

    private func genericFetchFailureString() -> String {
        String(
            localized: "aiusage.error.fetchFailedGeneric",
            defaultValue: "Could not fetch usage."
        )
    }
}
