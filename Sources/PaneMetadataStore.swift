import Foundation
#if DEBUG
import Bonsplit
#endif

/// Per-pane JSON metadata store (CMUX-11 Phase 1).
///
/// Mirrors `SurfaceMetadataStore` but keys by `(workspaceId, paneId)` instead
/// of `(workspaceId, surfaceId)`. The first consumer is a free-form pane
/// title carrying lineage (`Parent :: Child :: Grandchild`); the store is
/// built for parity so future pane-level metadata (status/role/progress) can
/// land without a second migration.
///
/// Source precedence reuses the surface store's `MetadataSource` chain
/// (`explicit > declare > osc > heuristic`). In practice only `.explicit`
/// writes flow through this store today (agents and operators); the OSC and
/// heuristic layers don't apply to panes in v1.
///
/// In-memory only in Phase 1. Phase 3 wires persistence through the existing
/// `PersistedJSONValue` / `PersistedMetadataSource` rails introduced for
/// surfaces by Tier 1 Phase 2.
final class PaneMetadataStore: @unchecked Sendable {
    static let shared = PaneMetadataStore()

    // MARK: - Constants

    /// Same 64 KiB per-pane cap used for surfaces.
    static let payloadCapBytes: Int = SurfaceMetadataStore.payloadCapBytes

    /// Reserved canonical keys recognised at the pane layer. Title and
    /// description start; the rest of the surface canonical set is allowed
    /// for future use without a schema bump and validates against the same
    /// rules. Keys outside this set accept any JSON value.
    static let reservedKeys: Set<String> = SurfaceMetadataStore.reservedKeys

    typealias SourceRecord = SurfaceMetadataStore.SourceRecord
    typealias WriteError = SurfaceMetadataStore.WriteError
    typealias WriteMode = SurfaceMetadataStore.WriteMode
    typealias WriteResult = SurfaceMetadataStore.WriteResult

    // MARK: - State

    private let queue = DispatchQueue(label: "com.stage11.c11.pane-metadata", qos: .userInitiated)

    /// `[workspaceId: [paneId: blob]]`.
    private var metadata: [UUID: [UUID: [String: Any]]] = [:]

    /// Parallel `(source, ts)` sidecar.
    private var sources: [UUID: [UUID: [String: SourceRecord]]] = [:]

    /// Monotonic revision counter — same contract as the surface store. Bumped
    /// on every mutation that changes state, never on idempotent writes or
    /// rejected lower-precedence writes. Read by the autosave fingerprint so
    /// metadata-only mutations between 8 s ticks still trigger a write.
    private var paneMetadataStoreRevision: UInt64 = 0

    // MARK: - Public API

    func setMetadata(
        workspaceId: UUID,
        paneId: UUID,
        partial: [String: Any],
        mode: WriteMode,
        source: MetadataSource
    ) throws -> WriteResult {
        return try queue.sync {
            try setMetadataLocked(
                workspaceId: workspaceId,
                paneId: paneId,
                partial: partial,
                mode: mode,
                source: source
            )
        }
    }

    func getMetadata(workspaceId: UUID, paneId: UUID) -> (metadata: [String: Any], sources: [String: [String: Any]]) {
        return queue.sync {
            let md = metadata[workspaceId]?[paneId] ?? [:]
            let src = sources[workspaceId]?[paneId]
                .map { m in m.mapValues { $0.toJSON() } } ?? [:]
            return (md, src)
        }
    }

    /// Read the monotonic revision counter. Mirrors
    /// `SurfaceMetadataStore.currentRevision()` so the autosave fingerprint
    /// can fold pane-metadata churn into the same tick decision.
    func currentRevision() -> UInt64 {
        return queue.sync { paneMetadataStoreRevision }
    }

    func getSource(workspaceId: UUID, paneId: UUID, key: String) -> MetadataSource? {
        return queue.sync {
            return sources[workspaceId]?[paneId]?[key]?.source
        }
    }

    /// Clear specific keys (or the whole blob when `keys == nil`).
    /// `keys == nil` requires `source == .explicit`, mirroring surfaces.
    func clearMetadata(
        workspaceId: UUID,
        paneId: UUID,
        keys: [String]?,
        source: MetadataSource
    ) throws -> WriteResult {
        return try queue.sync {
            var result = WriteResult()
            if keys == nil {
                guard source == .explicit else {
                    throw WriteError.replaceRequiresExplicit
                }
                let existing = metadata[workspaceId]?[paneId] ?? [:]
                let existingSrc = sources[workspaceId]?[paneId] ?? [:]
                metadata[workspaceId]?[paneId] = [:]
                sources[workspaceId]?[paneId] = [:]
                result.metadata = [:]
                result.sources = [:]
                if !existing.isEmpty || !existingSrc.isEmpty {
                    paneMetadataStoreRevision &+= 1
                }
                return result
            }

            var blob = metadata[workspaceId]?[paneId] ?? [:]
            var sblob = sources[workspaceId]?[paneId] ?? [:]
            var removedAny = false

            for key in keys! {
                if let cur = sblob[key] {
                    if source.precedence < cur.source.precedence {
                        result.applied[key] = false
                        result.reasons[key] = "lower_precedence"
                        continue
                    }
                }
                let hadValue = blob.removeValue(forKey: key) != nil
                let hadSource = sblob.removeValue(forKey: key) != nil
                if hadValue || hadSource { removedAny = true }
                result.applied[key] = true
            }

            metadata[workspaceId, default: [:]][paneId] = blob
            sources[workspaceId, default: [:]][paneId] = sblob
            result.metadata = blob
            result.sources = sblob.mapValues { $0.toJSON() }
            if removedAny { paneMetadataStoreRevision &+= 1 }
            return result
        }
    }

    /// Restore a pane's metadata from a session snapshot. Bypasses the
    /// precedence chain — the snapshot is the prior session's source of
    /// truth — but post-restore writes still respect precedence against the
    /// restored record. Same contract as `SurfaceMetadataStore`.
    func restoreFromSnapshot(
        workspaceId: UUID,
        paneId: UUID,
        values: [String: Any],
        sources: [String: SourceRecord]
    ) {
        queue.sync {
            metadata[workspaceId, default: [:]][paneId] = values
            self.sources[workspaceId, default: [:]][paneId] = sources
            paneMetadataStoreRevision &+= 1
        }
    }

    /// Drop a single pane's metadata. Called when a pane closes for good.
    func removePane(workspaceId: UUID, paneId: UUID) {
        queue.async { [self] in
            metadata[workspaceId]?.removeValue(forKey: paneId)
            sources[workspaceId]?.removeValue(forKey: paneId)
        }
    }

    /// Prune any panes not in `validPaneIds`. Called from workspace cleanup
    /// the way `SurfaceMetadataStore.pruneWorkspace` is.
    func pruneWorkspace(workspaceId: UUID, validPaneIds: Set<UUID>) {
        queue.async { [self] in
            if var wsMetadata = metadata[workspaceId] {
                wsMetadata = wsMetadata.filter { validPaneIds.contains($0.key) }
                metadata[workspaceId] = wsMetadata
            }
            if var wsSources = sources[workspaceId] {
                wsSources = wsSources.filter { validPaneIds.contains($0.key) }
                sources[workspaceId] = wsSources
            }
        }
    }

    /// Drop all pane metadata for a workspace.
    func removeWorkspace(workspaceId: UUID) {
        queue.async { [self] in
            metadata.removeValue(forKey: workspaceId)
            sources.removeValue(forKey: workspaceId)
        }
    }

    /// Single-key write with precedence gating. Mirrors
    /// `SurfaceMetadataStore.setInternal` for symmetry; pane callers will
    /// almost always use `setMetadata` directly with `source: .explicit`.
    @discardableResult
    func setInternal(
        workspaceId: UUID,
        paneId: UUID,
        key: String,
        value: Any,
        source: MetadataSource
    ) -> Bool {
        return queue.sync {
            var blob = metadata[workspaceId]?[paneId] ?? [:]
            var sblob = sources[workspaceId]?[paneId] ?? [:]

            if let cur = sblob[key], source.precedence < cur.source.precedence {
                return false
            }
            if SurfaceMetadataStore.validateReservedKey(key, value) != nil {
                return false
            }
            if let existing = blob[key], sameJSONValue(existing, value), sblob[key]?.source == source {
                return false
            }
            blob[key] = value
            sblob[key] = SourceRecord(source: source, ts: Date().timeIntervalSince1970)

            if let encoded = try? JSONSerialization.data(withJSONObject: blob, options: []),
               encoded.count > PaneMetadataStore.payloadCapBytes {
                return false
            }

            metadata[workspaceId, default: [:]][paneId] = blob
            sources[workspaceId, default: [:]][paneId] = sblob
            paneMetadataStoreRevision &+= 1
            return true
        }
    }

    // MARK: - Locked merge helper

    private func setMetadataLocked(
        workspaceId: UUID,
        paneId: UUID,
        partial: [String: Any],
        mode: WriteMode,
        source: MetadataSource
    ) throws -> WriteResult {
        if mode == .replace, source != .explicit {
            throw WriteError.replaceRequiresExplicit
        }

        for (k, v) in partial {
            if SurfaceMetadataStore.reservedKeys.contains(k) {
                if let err = SurfaceMetadataStore.validateReservedKey(k, v) {
                    throw err
                }
            }
        }

        var blob: [String: Any]
        var sblob: [String: SourceRecord]
        var result = WriteResult()

        // Capture prior values for every key in the incoming partial, regardless
        // of mode. Agents use this to implement read-then-write without a
        // separate round trip. Only keys that previously existed are included;
        // absence in `priorValues` means the key was unset.
        let priorSnapshot = metadata[workspaceId]?[paneId] ?? [:]
        for k in partial.keys {
            if let prior = priorSnapshot[k] {
                result.priorValues[k] = prior
            }
        }

        if mode == .replace {
            blob = [:]
            sblob = [:]
        } else {
            blob = metadata[workspaceId]?[paneId] ?? [:]
            sblob = sources[workspaceId]?[paneId] ?? [:]
        }

        let ts = Date().timeIntervalSince1970
        var mutated = false

        if mode == .replace {
            let priorBlob = metadata[workspaceId]?[paneId] ?? [:]
            let priorSrc = sources[workspaceId]?[paneId] ?? [:]
            if !priorBlob.isEmpty || !priorSrc.isEmpty { mutated = true }
        }

        for (k, v) in partial {
            if mode == .merge, let cur = sblob[k], source.precedence < cur.source.precedence {
                result.applied[k] = false
                result.reasons[k] = "lower_precedence"
                continue
            }
            let existing = blob[k]
            let existingSource = sblob[k]?.source
            let isSameWrite = existing.map { sameJSONValue($0, v) } ?? false
                && existingSource == source
            if isSameWrite {
                result.applied[k] = true
                continue
            }
            blob[k] = v
            sblob[k] = SourceRecord(source: source, ts: ts)
            result.applied[k] = true
            mutated = true
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: blob, options: []) else {
            throw WriteError.encodeFailed
        }
        if encoded.count > PaneMetadataStore.payloadCapBytes {
            throw WriteError.payloadTooLarge
        }

        metadata[workspaceId, default: [:]][paneId] = blob
        sources[workspaceId, default: [:]][paneId] = sblob

        result.metadata = blob
        result.sources = sblob.mapValues { $0.toJSON() }
        if mutated { paneMetadataStoreRevision &+= 1 }
        return result
    }

    // MARK: - Value equality for dedupe

    private func sameJSONValue(_ a: Any, _ b: Any) -> Bool {
        if let sa = a as? String, let sb = b as? String { return sa == sb }
        if let na = a as? NSNumber, let nb = b as? NSNumber { return na == nb }
        if let ba = a as? Bool, let bb = b as? Bool { return ba == bb }
        let da = try? JSONSerialization.data(withJSONObject: ["v": a], options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: ["v": b], options: [.sortedKeys])
        return da == db
    }
}
