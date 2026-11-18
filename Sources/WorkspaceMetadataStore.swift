import Foundation

/// Workspace-scoped JSON and provenance. Authored values and the current
/// C11.md fallback are separate, so clearing an override reveals today's file.
/// A second instance, `groups`, holds the same object for workspace groups,
/// keyed by group UUID. Groups have no root, so they never get a file default.
final class WorkspaceMetadataStore: @unchecked Sendable {
    enum Scope: String, Sendable {
        case workspace
        case workspaceGroup = "workspace_group"
    }
    static let shared = WorkspaceMetadataStore()
    static let groups = WorkspaceMetadataStore(scope: .workspaceGroup)
    static let payloadCapBytes = 64 * 1024
    static let didChangeNotification = Notification.Name("c11.workspaceMetadataDidChange")
    typealias WriteMode = PanelMetadataStore.WriteMode
    typealias WriteResult = PanelMetadataStore.WriteResult
    typealias WriteError = PanelMetadataStore.WriteError
    typealias SourceRecord = PanelMetadataStore.SourceRecord

    enum TargetError: Error {
        case notFound
        var code: String { "not_found" }
        var message: String { "Workspace not found" }
    }

    struct ReadSnapshot {
        let metadata: [UUID: [String: Any]]
        let sources: [UUID: [String: [String: Any]]]
        let revision: UInt64
    }
    /// The session writer uses this seam so a failed restore cannot overwrite
    /// its input with an empty or lossy projection on the next autosave.
    struct PersistenceSnapshot: Equatable {
        var metadata: [String: String]?
        var metadataValues: [String: PersistedJSONValue]?
        var metadataSources: [String: PersistedMetadataSource]?
    }
    struct Change {
        var scope: Scope = .workspace
        /// The workspace, or for scope `workspaceGroup` the group.
        let workspaceId: UUID
        let changedKeys: [String]
        let removedKeys: [String]
        let source: String
        let revision: UInt64
        let current: [String: Any]
        let prior: [String: Any]
    }
    private struct Entry {
        var values: [String: Any] = [:]
        var sources: [String: SourceRecord] = [:]
        var preservedSnapshot: PersistenceSnapshot?
        var captainDefault: String?
        var captainPath: String?
        var captainTimestamp: Double = 0

        var effective: (metadata: [String: Any], sources: [String: [String: Any]]) {
            var metadata = values
            var provenance = sources.mapValues { $0.toJSON() }
            if let captainDefault,
               (sources[WorkspaceMetadataKey.captain]?.source.precedence ?? -1) < MetadataSource.derived.precedence {
                metadata[WorkspaceMetadataKey.captain] = captainDefault
                var record: [String: Any] = ["source": MetadataSource.derived.rawValue, "ts": captainTimestamp,
                                             "origin": "C11.md"]
                if let captainPath { record["path"] = captainPath }
                provenance[WorkspaceMetadataKey.captain] = record
            }
            return (metadata, provenance)
        }
    }

    private let queue = DispatchQueue(label: "c11.workspace-metadata")
    private var entries: [UUID: Entry] = [:]
    private var registered: [UUID: UInt64] = [:]
    private var registrationRevision: UInt64 = 0
    private var revision: UInt64 = 0
    private let restoreObject: ([String: Any]) throws -> [String: Any]
    private let eventSink: ((Change) -> Void)?
    let scope: Scope

    init(scope: Scope = .workspace,
         restoreObject: (([String: Any]) throws -> [String: Any])? = nil,
         eventSink: ((Change) -> Void)? = nil) {
        self.scope = scope
        self.restoreObject = restoreObject ?? Self.validatedRestoreObject
        self.eventSink = eventSink
    }

    @discardableResult
    func register(workspaceId: UUID) -> UInt64 {
        queue.sync {
            registrationRevision &+= 1
            registered[workspaceId] = registrationRevision
            return registrationRevision
        }
    }
    func contains(workspaceId: UUID) -> Bool { registrationGeneration(workspaceId: workspaceId) != nil }
    func registrationGeneration(workspaceId: UUID) -> UInt64? { queue.sync { registered[workspaceId] } }
    func currentRevision() -> UInt64 { queue.sync { revision } }
    func readSnapshot() -> ReadSnapshot {
        queue.sync {
            let effective = entries.mapValues { $0.effective }
            return ReadSnapshot(metadata: effective.mapValues { $0.metadata },
                                sources: effective.mapValues { $0.sources }, revision: revision)
        }
    }
    func getMetadata(workspaceId: UUID) -> (metadata: [String: Any], sources: [String: [String: Any]]) {
        queue.sync { (entries[workspaceId] ?? Entry()).effective }
    }
    /// Persistence and blueprints carry authored data only, never file defaults.
    func getAuthoredMetadata(workspaceId: UUID) -> (metadata: [String: Any], sources: [String: [String: Any]]) {
        queue.sync {
            let entry = entries[workspaceId] ?? Entry()
            return (entry.values, entry.sources.mapValues { $0.toJSON() })
        }
    }
    func persistenceSnapshot(workspaceId: UUID) -> PersistenceSnapshot {
        queue.sync {
            let entry = entries[workspaceId] ?? Entry()
            if let preserved = entry.preservedSnapshot { return preserved }
            let sources = entry.sources.mapValues { $0.toJSON() }
            let legacy = entry.values.compactMapValues { $0 as? String }
            return PersistenceSnapshot(metadata: legacy.isEmpty ? nil : legacy,
                metadataValues: PersistedMetadataBridge.encodeValues(entry.values, sources: sources),
                metadataSources: PersistedMetadataBridge.encodeSources(sources))
        }
    }

    @discardableResult
    func setMetadata(workspaceId: UUID, partial: [String: Any], mode: WriteMode = .merge,
                     source: MetadataSource = .explicit, requireRegistered: Bool = false,
                     expectedGeneration: UInt64? = nil) throws -> WriteResult {
        if mode == .replace && source != .explicit { throw WriteError.replaceRequiresExplicit }
        if source == .derived { throw WriteError.invalidSource(source.rawValue) }
        let normalized = try Self.validateMetadata(partial)
        return try queue.sync {
            if requireRegistered && registered[workspaceId] == nil { throw TargetError.notFound }
            if let expectedGeneration, registered[workspaceId] != expectedGeneration { throw TargetError.notFound }
            let previous = entries[workspaceId] ?? Entry()
            let prior = previous.effective
            var next = previous
            var result = WriteResult()
            if mode == .replace { next.values = [:]; next.sources = [:] }
            for (key, value) in normalized {
                let currentSource = prior.sources[key]?["source"] as? String
                if mode == .merge, let currentSource, let existing = MetadataSource(rawValue: currentSource),
                   existing.precedence > source.precedence {
                    result.applied[key] = false
                    result.reasons[key] = "lower_precedence"
                    continue
                }
                result.applied[key] = true
                let unchanged = Self.equal(previous.values[key], value) && previous.sources[key]?.source == source
                next.values[key] = value
                next.sources[key] = unchanged ? previous.sources[key] : SourceRecord(source: source, ts: Date().timeIntervalSince1970)
            }
            _ = try Self.validatedObject(next.values)
            _ = try Self.validatedObject(next.effective.metadata)
            next.preservedSnapshot = mode == .replace ? nil : Self.updatedPreservedSnapshot(previous: previous, next: next)
            commit(workspaceId: workspaceId, previous: previous, next: next, source: source.rawValue)
            return complete(result, prior: prior.metadata, current: next.effective)
        }
    }

    @discardableResult
    func clearMetadata(workspaceId: UUID, keys: [String]? = nil, source: MetadataSource = .explicit,
                       requireRegistered: Bool = false, expectedGeneration: UInt64? = nil) throws -> WriteResult {
        if keys == nil && source != .explicit { throw WriteError.replaceRequiresExplicit }
        if source == .derived { throw WriteError.invalidSource(source.rawValue) }
        for key in keys ?? [] { try WorkspaceMetadataValidator.validateKey(key) }
        return try queue.sync {
            if requireRegistered && registered[workspaceId] == nil { throw TargetError.notFound }
            if let expectedGeneration, registered[workspaceId] != expectedGeneration { throw TargetError.notFound }
            let previous = entries[workspaceId] ?? Entry()
            let prior = previous.effective
            var next = previous
            var result = WriteResult()
            for key in keys ?? Array(previous.values.keys) {
                if let raw = prior.sources[key]?["source"] as? String,
                   let existing = MetadataSource(rawValue: raw), existing.precedence > source.precedence {
                    result.applied[key] = false
                    result.reasons[key] = "lower_precedence"
                    continue
                }
                result.applied[key] = true
                next.values.removeValue(forKey: key)
                next.sources.removeValue(forKey: key)
            }
            _ = try Self.validatedObject(next.effective.metadata)
            next.preservedSnapshot = keys == nil ? nil : Self.updatedPreservedSnapshot(previous: previous, next: next)
            commit(workspaceId: workspaceId, previous: previous, next: next, source: source.rawValue)
            return complete(result, prior: prior.metadata, current: next.effective)
        }
    }

    /// The parser has already validated the file value. Invalid file content
    /// behaves as no fallback; it can never erase the authored override.
    func setCaptainDefault(workspaceId: UUID, address: String?, path: String?) {
        guard scope == .workspace else { return }
        let address = address.flatMap { try? WorkspaceMetadataValidator.normalizedCaptain($0) }
        queue.sync {
            guard registered[workspaceId] != nil else { return }
            let previous = entries[workspaceId] ?? Entry()
            var next = previous
            guard previous.captainDefault != address || previous.captainPath != path else { return }
            next.captainDefault = address
            next.captainPath = address == nil ? nil : path
            next.captainTimestamp = Date().timeIntervalSince1970
            // Preserve the newest hidden fallback even while overridden. An
            // effective file update must obey the same object cap as a write.
            guard (try? Self.validatedObject(next.effective.metadata)) != nil else { return }
            commit(workspaceId: workspaceId, previous: previous, next: next, source: MetadataSource.derived.rawValue)
        }
    }

    /// Old sessions import the exact string map as explicit. New sessions use
    /// metadataValues even when empty; provenance timestamps survive unchanged.
    func restoreMetadata(workspaceId: UUID, legacy: [String: String]?,
                         values: [String: PersistedJSONValue]?, sources: [String: PersistedMetadataSource]?) throws {
        let decoded: [String: Any] = values.map(PersistedMetadataBridge.decodeValues) ?? (legacy ?? [:]).mapValues { $0 as Any }
        let snapshot = PersistenceSnapshot(metadata: legacy, metadataValues: values, metadataSources: sources)
        do {
            // Do all throwing work before changing live state. The recovery
            // commit uses only decoded value types, not a partially validated map.
            let validated = try restoreObject(decoded)
            commitRestore(workspaceId: workspaceId, values: validated, snapshot: snapshot, preserve: false)
        } catch {
            commitRestore(workspaceId: workspaceId, values: decoded, snapshot: snapshot, preserve: true)
            throw error
        }
    }

    private static func validatedRestoreObject(_ decoded: [String: Any]) throws -> [String: Any] {
        // Migration is not an authoring operation. Older internal writers had
        // fewer key/value restrictions (and no whole-object cap). Preserve their
        // strings exactly, even for a name that is canonical in this build.
        // Future writes still validate the entire resulting object's size.
        guard JSONSerialization.isValidJSONObject(decoded) else {
            throw WriteError.invalidJSON(String(localized: "workspace.metadata.restore.finiteJSON", defaultValue: "Restored metadata must contain only finite JSON values"))
        }
        let data = try JSONSerialization.data(withJSONObject: decoded)
        guard let validated = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriteError.encodeFailed
        }
        return validated
    }

    private func commitRestore(workspaceId: UUID, values: [String: Any], snapshot: PersistenceSnapshot, preserve: Bool) {
        let restoredSources = PersistedMetadataBridge.decodeSources(snapshot.metadataSources ?? [:])
        queue.sync {
            let previous = entries[workspaceId] ?? Entry()
            var next = previous
            next.values = values
            next.sources = values.mapValues { _ in SourceRecord(source: .explicit, ts: 0) }
            next.preservedSnapshot = preserve ? snapshot : nil
            if snapshot.metadataValues != nil {
                for key in values.keys {
                    if let source = restoredSources[key] {
                        if source.source == .derived {
                            next.values.removeValue(forKey: key)
                            next.sources.removeValue(forKey: key)
                        } else {
                            next.sources[key] = source
                        }
                    }
                }
            }
            commit(workspaceId: workspaceId, previous: previous, next: next, source: "restore", emitEvent: false)
        }
    }

    /// A later merge/clear changes only its authored keys in the recovery
    /// payload. Untouched legacy strings and raw provenance remain exact.
    /// Explicit replace/clear-all intentionally discard the retained payload.
    private static func updatedPreservedSnapshot(previous: Entry, next: Entry) -> PersistenceSnapshot? {
        guard var snapshot = previous.preservedSnapshot else { return nil }
        let changed = Set(previous.values.keys).union(next.values.keys).filter {
            !equal(previous.values[$0], next.values[$0]) ||
                !equal(previous.sources[$0]?.toJSON(), next.sources[$0]?.toJSON())
        }
        guard !changed.isEmpty else { return snapshot }
        var values = snapshot.metadataValues ?? (snapshot.metadata ?? [:]).mapValues { .string($0) }
        var legacy = snapshot.metadata ?? [:]
        var sources = snapshot.metadataSources ?? [:]
        for key in changed {
            if let value = next.values[key] {
                values[key] = PersistedMetadataBridge.encodeValues([key: value])[key]
                legacy[key] = value as? String
                if let record = next.sources[key] {
                    sources[key] = PersistedMetadataSource(source: record.source.rawValue, ts: record.ts)
                }
            } else {
                values.removeValue(forKey: key)
                legacy.removeValue(forKey: key)
                sources.removeValue(forKey: key)
            }
        }
        snapshot.metadata = snapshot.metadata == nil && legacy.isEmpty ? nil : legacy
        snapshot.metadataValues = values
        snapshot.metadataSources = snapshot.metadataSources == nil && sources.isEmpty ? nil : sources
        return snapshot
    }

    /// Safe for Release diagnostics: never interpolate an Error description,
    /// metadata key/value, or caller-controlled NSError domain.
    static func rejectionCategory(_ error: Error) -> String {
        if let error = error as? WriteError { return error.code }
        if let error = error as? WorkspaceMetadataValidator.ValidationError { return error.code }
        if let error = error as? TargetError { return error.code }
        return "metadata_restore_failed"
    }

    func removeWorkspace(workspaceId: UUID) {
        queue.sync {
            registered.removeValue(forKey: workspaceId)
            guard entries.removeValue(forKey: workspaceId) != nil else { return }
            revision &+= 1
        }
    }

    static func validateMetadata(_ values: [String: Any]) throws -> [String: Any] {
        var normalized: [String: Any] = [:]
        for (key, value) in values {
            normalized[key] = try WorkspaceMetadataValidator.normalizedValue(key: key, value: value)
        }
        // Freeze caller-owned mutable Foundation containers before committing.
        return try validatedObject(normalized)
    }

    private static func validatedObject(_ values: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(values) else { throw WriteError.invalidJSON(String(localized: "workspace.metadata.finiteJSON", defaultValue: "Metadata must contain only finite JSON values")) }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard data.count <= payloadCapBytes else { throw WriteError.payloadTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriteError.encodeFailed }
        return object
    }
    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (try? JSONSerialization.data(withJSONObject: [a], options: [.sortedKeys])) ==
            (try? JSONSerialization.data(withJSONObject: [b], options: [.sortedKeys]))
    }
    private func complete(_ result: WriteResult, prior: [String: Any],
                          current: (metadata: [String: Any], sources: [String: [String: Any]])) -> WriteResult {
        var result = result
        result.metadata = current.metadata
        result.sources = current.sources
        result.priorValues = prior
        result.removedKeys = Set(prior.keys).subtracting(current.metadata.keys)
        return result
    }
    private func commit(workspaceId: UUID, previous: Entry, next: Entry, source: String, emitEvent: Bool = true) {
        let before = previous.effective
        let after = next.effective
        let authoredChanged = !Self.equal(previous.values, next.values) ||
            !Self.equal(previous.sources.mapValues { $0.toJSON() }, next.sources.mapValues { $0.toJSON() })
        let fallbackChanged = previous.captainDefault != next.captainDefault || previous.captainPath != next.captainPath
        guard authoredChanged || fallbackChanged || previous.preservedSnapshot != next.preservedSnapshot else { return }
        entries[workspaceId] = next
        revision &+= 1
        let committedRevision = revision
        let changedKeys = Set(before.metadata.keys).union(after.metadata.keys).filter {
            !Self.equal(before.metadata[$0], after.metadata[$0]) || !Self.equal(before.sources[$0], after.sources[$0])
        }.sorted()
        let removedKeys = Set(before.metadata.keys).subtracting(after.metadata.keys).sorted()
        // Main dispatch guarantees observers never run inside this transaction
        // or synchronously call back into a locked store.
        let scope = self.scope
        DispatchQueue.main.async {
            // A group change names its group, never a workspace, so per-workspace
            // observers keyed on `workspaceId` ignore it.
            let idKey = scope == .workspace ? "workspaceId" : "groupId"
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                userInfo: [idKey: workspaceId, "scope": scope.rawValue, "revision": committedRevision,
                           "changedKeys": changedKeys, "removedKeys": removedKeys, "source": source])
            if emitEvent && !changedKeys.isEmpty {
                if let eventSink = self.eventSink {
                    eventSink(Change(scope: scope, workspaceId: workspaceId, changedKeys: changedKeys, removedKeys: removedKeys,
                        source: source, revision: committedRevision, current: after.metadata, prior: before.metadata))
                } else if scope == .workspaceGroup {
                    EventEmitter.shared.emitWorkspaceGroupMetadataChanged(group: workspaceId,
                        changedKeys: changedKeys, removedKeys: removedKeys, source: source,
                        revision: committedRevision, current: after.metadata, prior: before.metadata)
                } else {
                    EventEmitter.shared.emitWorkspaceMetadataChanged(workspace: workspaceId,
                        changedKeys: changedKeys, removedKeys: removedKeys, source: source,
                        revision: committedRevision, current: after.metadata, prior: before.metadata)
                }
            }
        }
    }
}
