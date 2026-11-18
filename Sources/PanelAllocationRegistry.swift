import Foundation

/// One port range handed to a workspace's terminals as `CMUX_PORT`,
/// `CMUX_PORT_END` and `CMUX_PORT_RANGE`. Stored as the exact values a
/// process received, never as an ordinal recomputed from current settings.
struct PortReservation: Codable, Hashable, Sendable {
    let start: Int
    /// Inclusive.
    let end: Int

    var size: Int { end - start + 1 }
    var isValid: Bool { start >= 1 && end <= PortReservation.maxPort && end >= start }

    func overlaps(_ other: PortReservation) -> Bool {
        start <= other.end && other.start <= end
    }

    static let maxPort = 65_535
}

/// The operator's Port Base / Port Range settings at the moment a new range
/// is allocated. Existing reservations never change when these do. The base
/// is c11's own (`C11Identity`, 29100 by default, read only from this app's
/// defaults), never c11's 9100.
struct PortAllocationSettings: Equatable, Sendable {
    let base: Int
    let size: Int

    static let `default` = PortAllocationSettings(base: C11Identity.defaultPortBase, size: 10)

    static func current(defaults: UserDefaults = .standard) -> PortAllocationSettings {
        let size = defaults.integer(forKey: "cmuxPortRange")
        return PortAllocationSettings(
            base: C11Identity.portBase(defaults: defaults),
            size: size > 0 ? size : Self.default.size
        )
    }
}

/// Something the registry could not keep exactly. Every one is logged and
/// shown to the operator once; none is ever resolved by handing a number or
/// range that a surviving shell may hold to a different panel.
enum PanelAllocationIssue: Equatable, Sendable {
    /// The file could not be decoded. It was moved aside, never overwritten.
    case unreadableFile(quarantinedAs: String?)
    /// Written by a newer build. Moved aside, never overwritten.
    case unsupportedVersion(Int, quarantinedAs: String?)
    /// Two panels claimed one number. Both records were dropped; the number
    /// stays under the high-water mark, so it is never minted again.
    case conflictingPanelNumber(Int)
    case invalidPanelRecord(UUID)
    /// Two workspaces claimed overlapping ranges. The later one was dropped
    /// and allocates a fresh range at its next terminal.
    case conflictingWorkspacePorts(UUID)
    case invalidWorkspacePorts(UUID)
    /// No free range is left below port 65535 for the current settings.
    case portsExhausted(workspaceId: UUID)
    /// A saved session had panels but no allocation file: it was saved by a
    /// build that numbered panels per launch, so earlier numbers are unknown.
    case migratedWithoutAllocations
    case writeFailed(String)
}

/// The whole allocation policy as a value. Keyed by UUID only, so window,
/// workspace and panel order never change a number or a range.
struct PanelAllocationLedger: Equatable, Sendable {
    struct PanelRecord: Equatable, Sendable {
        let number: Int
        /// The exact range in this panel's last spawn environment. nil until
        /// a terminal spawns (browser and markdown panels never get one).
        var ports: PortReservation?
        /// A terminal that can outlive the app (an hc persistent session).
        /// Its record survives a restore that does not claim it (an orphan
        /// for Recovered); a local exec shell's record does not.
        var outlivesApp: Bool
    }

    /// Highest panel number ever minted. Never lowered, so closed numbers
    /// and gaps are never reused.
    private(set) var panelHighWater: Int = 0
    private(set) var panels: [UUID: PanelRecord] = [:]
    private(set) var workspacePorts: [UUID: PortReservation] = [:]
    private var panelIdByNumber: [Int: UUID] = [:]
    /// Ranges given back by closed panels and workspaces during this app run.
    /// A closed exec shell's background jobs (`nohup`, a dev server) can keep
    /// using them, so they are never handed out again in this process, as on
    /// main. Not persisted: a fresh launch starts without them, as before.
    private(set) var retiredRanges: Set<PortReservation> = []

    init() {}

    func record(for panelId: UUID) -> PanelRecord? { panels[panelId] }
    func panelId(forNumber number: Int) -> UUID? { panelIdByNumber[number] }

    /// Every range a live or possibly-live process may hold.
    var reservedRanges: [PortReservation] {
        Array(Set(workspacePorts.values).union(panels.values.compactMap(\.ports)).union(retiredRanges))
    }

    /// The panel's number, minting `panelHighWater + 1` for an unknown UUID.
    mutating func number(for panelId: UUID) -> (number: Int, minted: Bool) {
        if let existing = panels[panelId] { return (existing.number, false) }
        let number = panelHighWater + 1
        panelHighWater = number
        panels[panelId] = PanelRecord(number: number, ports: nil, outlivesApp: false)
        panelIdByNumber[number] = panelId
        return (number, true)
    }

    /// The workspace's recorded range, or a new first-fit range of the
    /// current settings that overlaps nothing reserved. nil when exhausted.
    mutating func ports(
        forWorkspace workspaceId: UUID,
        settings: PortAllocationSettings
    ) -> (ports: PortReservation?, allocated: Bool) {
        if let existing = workspacePorts[workspaceId] { return (existing, false) }
        guard let fresh = Self.firstFreeRange(settings: settings, reserved: reservedRanges) else {
            return (nil, false)
        }
        workspacePorts[workspaceId] = fresh
        return (fresh, true)
    }

    /// Records what a spawning panel's environment received.
    @discardableResult
    mutating func recordSpawn(
        panelId: UUID,
        ports: PortReservation?,
        outlivesApp: Bool
    ) -> Bool {
        _ = number(for: panelId)
        guard var record = panels[panelId] else { return false }
        let before = record
        record.ports = ports
        record.outlivesApp = outlivesApp
        panels[panelId] = record
        return record != before
    }

    @discardableResult
    mutating func release(panels panelIds: Set<UUID>) -> Bool {
        var changed = false
        for panelId in panelIds {
            guard let removed = panels.removeValue(forKey: panelId) else { continue }
            if let ports = removed.ports { retiredRanges.insert(ports) }
            if panelIdByNumber[removed.number] == panelId {
                panelIdByNumber.removeValue(forKey: removed.number)
            }
            changed = true
        }
        return changed
    }

    @discardableResult
    mutating func release(workspaces workspaceIds: Set<UUID>) -> Bool {
        var changed = false
        for workspaceId in workspaceIds {
            guard let ports = workspacePorts.removeValue(forKey: workspaceId) else { continue }
            retiredRanges.insert(ports)
            changed = true
        }
        return changed
    }

    /// After the restored graph is complete: local panels that did not
    /// come back died with the previous app, so their records go. Persistent
    /// ones may still be running and stay reserved until Recovered or an
    /// explicit end releases them. Workspaces that did not come back go too;
    /// a range a kept panel still holds stays reserved through that panel.
    @discardableResult
    mutating func reconcileAfterRestore(livePanels: Set<UUID>, liveWorkspaces: Set<UUID>) -> Bool {
        let stalePanels = Set(panels.compactMap { id, record in
            !livePanels.contains(id) && !record.outlivesApp ? id : nil
        })
        let staleWorkspaces = Set(workspacePorts.keys).subtracting(liveWorkspaces)
        let releasedPanels = release(panels: stalePanels)
        let releasedWorkspaces = release(workspaces: staleWorkspaces)
        return releasedPanels || releasedWorkspaces
    }

    /// Lowest aligned slot of `settings` that overlaps no reserved range and
    /// ends at or below port 65535. Never wraps.
    static func firstFreeRange(
        settings: PortAllocationSettings,
        reserved: [PortReservation]
    ) -> PortReservation? {
        guard settings.base >= 1, settings.size >= 1 else { return nil }
        let sorted = reserved.sorted { $0.start < $1.start }
        var slot = 0
        var index = 0
        while true {
            let (offset, offsetOverflow) = slot.multipliedReportingOverflow(by: settings.size)
            let (start, startOverflow) = settings.base.addingReportingOverflow(offset)
            guard !offsetOverflow, !startOverflow else { return nil }
            let end = start + settings.size - 1
            guard end <= PortReservation.maxPort, end >= start else { return nil }
            // Ranges before `index` all end below an earlier, smaller start.
            while index < sorted.count, sorted[index].end < start { index += 1 }
            if index < sorted.count, sorted[index].start <= end {
                // Jump past the blocking range in one step.
                let blockedEnd = sorted[index].end
                let next = blockedEnd >= settings.base
                    ? (blockedEnd - settings.base) / settings.size + 1
                    : slot + 1
                slot = max(slot + 1, next)
                continue
            }
            return PortReservation(start: start, end: end)
        }
    }

    // MARK: - Persistence form

    struct File: Codable, Equatable, Sendable {
        struct Panel: Codable, Equatable, Sendable {
            let id: UUID
            let number: Int
            let ports: PortReservation?
            let outlivesApp: Bool
        }
        struct Workspace: Codable, Equatable, Sendable {
            let id: UUID
            let ports: PortReservation
        }
        let version: Int
        let panelHighWater: Int
        let panels: [Panel]
        let workspaces: [Workspace]
    }

    static let fileVersion = 1

    var file: File {
        File(
            version: Self.fileVersion,
            panelHighWater: panelHighWater,
            panels: panels
                .map { File.Panel(id: $0.key, number: $0.value.number, ports: $0.value.ports, outlivesApp: $0.value.outlivesApp) }
                .sorted { $0.number < $1.number },
            workspaces: workspacePorts
                .map { File.Workspace(id: $0.key, ports: $0.value) }
                .sorted { $0.ports.start < $1.ports.start }
        )
    }

    /// Rebuilds a ledger from disk. Anything inconsistent is dropped and
    /// reported; the high-water mark always covers every number seen, so a
    /// dropped number is never minted for another panel.
    static func validated(_ file: File) -> (ledger: PanelAllocationLedger, issues: [PanelAllocationIssue]) {
        var ledger = PanelAllocationLedger()
        var issues: [PanelAllocationIssue] = []
        let maxNumber = file.panels.map(\.number).max() ?? 0
        ledger.panelHighWater = max(file.panelHighWater, maxNumber, 0)

        var claims: [Int: Int] = [:]
        var seenIds: Set<UUID> = []
        var duplicateIds: Set<UUID> = []
        for panel in file.panels {
            claims[panel.number, default: 0] += 1
            if !seenIds.insert(panel.id).inserted { duplicateIds.insert(panel.id) }
        }
        for number in claims.filter({ $0.value > 1 }).keys.sorted() {
            issues.append(.conflictingPanelNumber(number))
        }
        for panel in file.panels {
            if claims[panel.number, default: 0] > 1 { continue }
            guard panel.number >= 1, !duplicateIds.contains(panel.id),
                  panel.ports?.isValid ?? true else {
                issues.append(.invalidPanelRecord(panel.id))
                continue
            }
            ledger.panels[panel.id] = PanelRecord(number: panel.number, ports: panel.ports, outlivesApp: panel.outlivesApp)
            ledger.panelIdByNumber[panel.number] = panel.id
        }

        var acceptedWorkspaces: [PortReservation] = []
        for workspace in file.workspaces.sorted(by: { $0.ports.start < $1.ports.start }) {
            guard workspace.ports.isValid, ledger.workspacePorts[workspace.id] == nil else {
                issues.append(.invalidWorkspacePorts(workspace.id))
                continue
            }
            if acceptedWorkspaces.contains(where: { $0.overlaps(workspace.ports) }) {
                issues.append(.conflictingWorkspacePorts(workspace.id))
                continue
            }
            acceptedWorkspaces.append(workspace.ports)
            ledger.workspacePorts[workspace.id] = workspace.ports
        }
        return (ledger, issues)
    }
}

/// Writes ledger snapshots on a serial utility queue: temp file, fsync,
/// atomic rename, directory fsync. Newer snapshots replace unwritten older
/// ones. Never touched from the main thread except to enqueue.
final class PanelAllocationWriter: @unchecked Sendable {
    typealias Write = @Sendable (PanelAllocationLedger.File, URL) throws -> Void

    private let queue: DispatchQueue
    private let fileURL: URL?
    private let write: Write
    private let lock = NSLock()
    private var pending: (file: PanelAllocationLedger.File, generation: UInt64)?
    private var isDraining = false
    private var durableGeneration: UInt64 = 0
    private var failedGeneration: UInt64 = 0
    private var waiters: [(generation: UInt64, resume: @Sendable (Bool) -> Void)] = []
    var onFailure: (@Sendable (String) -> Void)?

    init(
        fileURL: URL?,
        queue: DispatchQueue = DispatchQueue(label: "com.stage11.c11.panel-allocations", qos: .utility),
        write: @escaping Write = PanelAllocationWriter.atomicWrite
    ) {
        self.fileURL = fileURL
        self.queue = queue
        self.write = write
    }

    func schedule(_ file: PanelAllocationLedger.File, generation: UInt64) {
        lock.lock()
        pending = (file, generation)
        let shouldStart = !isDraining
        isDraining = true
        lock.unlock()
        if shouldStart { queue.async { [self] in drain() } }
    }

    /// True once `generation` (or a newer snapshot) is on disk. False when
    /// the write covering it failed; a later successful write still counts.
    func waitUntilDurable(_ generation: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if durableGeneration >= generation {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            if failedGeneration >= generation, !isDraining {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            waiters.append((generation, { continuation.resume(returning: $0) }))
            lock.unlock()
        }
    }

    /// Caller holds `lock` and the drain is idle: no write can still cover
    /// these waiters, so each resolves now from what is known.
    private func settleWaitersLocked() -> [(@Sendable (Bool) -> Void, Bool)] {
        var settled: [(@Sendable (Bool) -> Void, Bool)] = []
        var remaining: [(generation: UInt64, resume: @Sendable (Bool) -> Void)] = []
        for waiter in waiters {
            if waiter.generation <= durableGeneration {
                settled.append((waiter.resume, true))
            } else if waiter.generation <= failedGeneration {
                settled.append((waiter.resume, false))
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        return settled
    }

    /// Test seam: waiters registered and not yet resolved.
    var pendingWaiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func isDurable(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return durableGeneration >= generation
    }

    /// Clean shutdown: wait for the queue to finish whatever is scheduled.
    func flushSynchronously() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                // Going idle and settling waiters happen under one lock, so a
                // waiter that registered after a failure was published (while
                // the drain was still running) is never left suspended.
                isDraining = false
                let settled = settleWaitersLocked()
                lock.unlock()
                for (resume, value) in settled { resume(value) }
                return
            }
            pending = nil
            lock.unlock()

            var failure: String?
            if let fileURL {
                do { try write(next.file, fileURL) } catch { failure = String(describing: error) }
            }

            lock.lock()
            var ready: [@Sendable (Bool) -> Void] = []
            var remaining: [(generation: UInt64, resume: @Sendable (Bool) -> Void)] = []
            if failure == nil {
                durableGeneration = max(durableGeneration, next.generation)
                for waiter in waiters {
                    if waiter.generation <= durableGeneration { ready.append(waiter.resume) } else { remaining.append(waiter) }
                }
            } else {
                failedGeneration = max(failedGeneration, next.generation)
                // A newer pending snapshot may still succeed for these.
                if pending == nil {
                    for waiter in waiters {
                        if waiter.generation <= failedGeneration { ready.append(waiter.resume) } else { remaining.append(waiter) }
                    }
                } else {
                    remaining = waiters
                }
            }
            waiters = remaining
            let failureHandler = onFailure
            lock.unlock()
            for resume in ready { resume(failure == nil) }
            if let failure { failureHandler?(failure) }
        }
    }

    static let atomicWrite: Write = { file, url in
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let directoryFD = open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            fsync(directoryFD)
            close(directoryFD)
        }
    }
}

/// Durable panel numbers (`panel:N`, `C11_PANEL_NUM`) and port reservations
/// (`CMUX_PORT…`). Loaded on first use, so nothing can mint a number before
/// the persisted state is in memory. Main-actor state is dictionaries only;
/// disk writes run on the writer's queue.
@MainActor
final class PanelAllocationRegistry {
    static let shared = PanelAllocationRegistry(
        fileURL: PanelAllocationRegistry.defaultFileURL(),
        sessionSnapshotURL: PanelAllocationRegistry.defaultFileURL() == nil
            ? nil
            : SessionPersistenceStore.defaultSnapshotFileURL()
    )

    struct LaunchAllocation: Equatable, Sendable {
        let panelNumber: Int
        let ports: PortReservation?
        /// Pass to `waitUntilDurable` before a launch that may outlive the app.
        let generation: UInt64
    }

    private let fileURL: URL?
    /// The saved session next to the allocation file. A session on disk with
    /// no allocation file was written by a build that numbered per launch.
    private let sessionSnapshotURL: URL?
    private let portSettingsProvider: () -> PortAllocationSettings
    let writer: PanelAllocationWriter
    private var storage: PanelAllocationLedger?
    private var portSettingsStorage: PortAllocationSettings?
    private var fileExisted = false
    private var generation: UInt64 = 0
    private var pendingIssues: [PanelAllocationIssue] = []
    private var reportedExhaustion: Set<UUID> = []
    private let now: () -> Date

    init(
        fileURL: URL?,
        sessionSnapshotURL: URL? = nil,
        portSettings: @escaping () -> PortAllocationSettings = { PortAllocationSettings.current() },
        writer: PanelAllocationWriter? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.sessionSnapshotURL = sessionSnapshotURL
        self.portSettingsProvider = portSettings
        self.writer = writer ?? PanelAllocationWriter(fileURL: fileURL)
        self.now = now
        self.writer.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.report(.writeFailed(message)) }
            }
        }
    }

    // MARK: Reads

    var ledger: PanelAllocationLedger {
        loadIfNeeded()
        return storage ?? PanelAllocationLedger()
    }

    func record(for panelId: UUID) -> PanelAllocationLedger.PanelRecord? { ledger.record(for: panelId) }
    func panelId(forNumber number: Int) -> UUID? { ledger.panelId(forNumber: number) }

    // MARK: Mutations

    /// The panel's durable number, minting one above the high-water mark for
    /// a UUID never seen before.
    func panelNumber(for panelId: UUID) -> Int {
        if let existing = ledger.record(for: panelId) { return existing.number }
        return mutate { $0.number(for: panelId) }.number
    }

    /// Number and ports for a terminal about to spawn, recorded on the panel.
    func allocationForLaunch(
        panelId: UUID,
        workspaceId: UUID,
        outlivesApp: Bool = false
    ) -> LaunchAllocation {
        let settings = portSettings
        let (number, ports) = mutate { ledger -> (Int, PortReservation?) in
            let number = ledger.number(for: panelId).number
            let ports = ledger.ports(forWorkspace: workspaceId, settings: settings).ports
            ledger.recordSpawn(panelId: panelId, ports: ports, outlivesApp: outlivesApp)
            return (number, ports)
        }
        if ports == nil, reportedExhaustion.insert(workspaceId).inserted {
            report(.portsExhausted(workspaceId: workspaceId))
        }
        return LaunchAllocation(panelNumber: number, ports: ports, generation: generation)
    }

    nonisolated func waitUntilDurable(_ allocation: LaunchAllocation) async -> Bool {
        await writer.waitUntilDurable(allocation.generation)
    }

    func releasePanels(_ panelIds: Set<UUID>) {
        guard panelIds.contains(where: { ledger.record(for: $0) != nil }) else { return }
        mutate { _ = $0.release(panels: panelIds) }
    }

    func releaseWorkspaces(_ workspaceIds: Set<UUID>) {
        guard workspaceIds.contains(where: { ledger.workspacePorts[$0] != nil }) else { return }
        mutate { _ = $0.release(workspaces: workspaceIds) }
    }

    /// A restore replaced these panels (the launch placeholder, or a graph
    /// an explicit restore displaced). A local shell among them died with its
    /// surface, so its record goes now and its number names nothing; a
    /// terminal that outlives the app keeps its record for Recovered.
    func releaseDisplacedPanels(_ panelIds: Set<UUID>) {
        let local = Set(panelIds.filter { ledger.record(for: $0)?.outlivesApp == false })
        releasePanels(local)
    }

    /// Call once the startup graph is complete in every window.
    func reconcileAfterRestore(livePanels: Set<UUID>, liveWorkspaces: Set<UUID>) {
        loadIfNeeded()
        var candidate = ledger
        guard candidate.reconcileAfterRestore(livePanels: livePanels, liveWorkspaces: liveWorkspaces) else { return }
        storage = candidate
        persist()
    }

    /// Once set (after the startup notice), new issues go straight to the
    /// operator instead of waiting in `takeIssues`.
    var issueSink: ((PanelAllocationIssue) -> Void)?

    /// Issues not yet shown to the operator. Each is returned once.
    func takeIssues() -> [PanelAllocationIssue] {
        loadIfNeeded()
        defer { pendingIssues.removeAll() }
        return pendingIssues
    }

    func flushSynchronously() {
        writer.flushSynchronously()
    }

    // MARK: Internals

    private var portSettings: PortAllocationSettings {
        // Snapshotted once per launch, as before, so one launch is consistent.
        if let portSettingsStorage { return portSettingsStorage }
        let settings = portSettingsProvider()
        portSettingsStorage = settings
        return settings
    }

    /// Applies a mutation in place and schedules a write when it changed
    /// anything. The ledger is small; comparing it is cheaper than a write.
    private func mutate<T>(_ body: (inout PanelAllocationLedger) -> T) -> T {
        loadIfNeeded()
        var ledger = storage ?? PanelAllocationLedger()
        let before = ledger
        let result = body(&ledger)
        let changed = ledger != before
        storage = ledger
        if changed { persist() }
        return result
    }

    private func persist() {
        guard let storage else { return }
        generation &+= 1
        writer.schedule(storage.file, generation: generation)
    }

    private func report(_ issue: PanelAllocationIssue) {
        NSLog("panel.allocations.issue %@", String(describing: issue))
        if let issueSink { issueSink(issue) } else { pendingIssues.append(issue) }
    }

    private func loadIfNeeded() {
        guard storage == nil else { return }
        storage = PanelAllocationLedger()
        guard let fileURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            fileExisted = FileManager.default.fileExists(atPath: fileURL.path)
            if fileExisted {
                report(.unreadableFile(quarantinedAs: quarantine(fileURL)))
            } else if let sessionSnapshotURL,
                      FileManager.default.fileExists(atPath: sessionSnapshotURL.path) {
                // Decided at load, before anything mints or restores, so no
                // later ordering can hide it.
                report(.migratedWithoutAllocations)
            }
            return
        }
        fileExisted = true
        struct VersionProbe: Decodable { let version: Int }
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           probe.version > PanelAllocationLedger.fileVersion {
            report(.unsupportedVersion(probe.version, quarantinedAs: quarantine(fileURL)))
            return
        }
        guard let file = try? JSONDecoder().decode(PanelAllocationLedger.File.self, from: data) else {
            report(.unreadableFile(quarantinedAs: quarantine(fileURL)))
            return
        }
        let (ledger, issues) = PanelAllocationLedger.validated(file)
        storage = ledger
        issues.forEach(report)
    }

    /// Moves a file this build cannot use out of the way, so the next write
    /// does not destroy what a newer build or a person might still need.
    private func quarantine(_ url: URL) -> String? {
        let stamp = Int(now().timeIntervalSince1970)
        let base = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target.lastPathComponent
        } catch {
            return nil
        }
    }

    nonisolated static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        // Unit tests must never touch an installed build's allocations.
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return nil
        }
        guard let sessionURL = SessionPersistenceStore.defaultSnapshotFileURL() else { return nil }
        let name = sessionURL.lastPathComponent
        let suffix = name.hasPrefix("session-") ? String(name.dropFirst("session-".count)) : name
        return sessionURL.deletingLastPathComponent()
            .appendingPathComponent("panel-allocations-\(suffix)", isDirectory: false)
    }
}

// MARK: - App wiring

extension PanelAllocationRegistry {
    /// Panels closed for good release their record. Moves and app
    /// termination never fire this observer, so a surviving or moving
    /// panel keeps its number and range.
    static func installCloseObserver(lineage: PanelLineage = .shared) {
        lineage.addPanelClosedForGoodObserver { panelIds in
            PanelAllocationRegistry.shared.releasePanels(panelIds)
        }
    }

    /// A workspace or window closed by the operator or an agent. Ignored while
    /// the app terminates: quitting keeps every reservation for the restore.
    func releaseWorkspacesClosedForGood(_ workspaceIds: Set<UUID>, isTerminatingApp: Bool) {
        guard PanelCloseForGoodPolicy.shouldFire(isDetaching: false, isTerminatingApp: isTerminatingApp) else { return }
        releaseWorkspaces(workspaceIds)
    }

    /// One operator-facing line per issue, for the startup notice.
    static func operatorDescription(_ issue: PanelAllocationIssue) -> String {
        switch issue {
        case .unreadableFile, .unsupportedVersion:
            return String(
                localized: "panelAllocations.issue.unreadable",
                defaultValue: "The saved panel numbers could not be read. The file was set aside and numbering started over; shells from before this launch may report an old panel number."
            )
        case .conflictingPanelNumber(let number):
            return String(
                localized: "panelAllocations.issue.conflictingNumber",
                defaultValue: "Two panels claimed panel \(number). Neither keeps it, and it will not be given to another panel."
            )
        case .invalidPanelRecord, .invalidWorkspacePorts, .conflictingWorkspacePorts:
            return String(
                localized: "panelAllocations.issue.invalidRecord",
                defaultValue: "Some saved panel numbers or port ranges were inconsistent and were dropped. Those panels get new numbers or ports."
            )
        case .portsExhausted:
            return String(
                localized: "panelAllocations.issue.portsExhausted",
                defaultValue: "No free port range is left, so new terminals in a workspace start without CMUX_PORT. Close unused workspaces or change Port Base and Port Range in Settings."
            )
        case .migratedWithoutAllocations:
            return String(
                localized: "panelAllocations.issue.migrated",
                defaultValue: "This session was saved by a build that renumbered panels at every launch, so panel numbers started over. From now on they survive restarts."
            )
        case .writeFailed:
            return String(
                localized: "panelAllocations.issue.writeFailed",
                defaultValue: "Panel numbers and port ranges could not be saved. They may change after the next restart."
            )
        }
    }
}
