import Foundation

/// Source precedence for metadata writes (c11mux Module 2).
///
/// Writers declare a `source` per call. The precedence chain is
/// `explicit > declare > osc > heuristic`. A lower-precedence write is
/// rejected per-key (soft reject: `applied: false`, `reason: lower_precedence`).
/// Canonical-key namespace (c11mux Module 2).
/// String constants for the canonical metadata keys rendered in the sidebar
/// and title bar. Non-canonical keys accept any JSON value and are opaque to
/// c11mux. See `docs/c11mux-module-2-metadata-spec.md`.
public enum MetadataKey {
    public static let role = "role"
    public static let status = "status"
    public static let task = "task"
    public static let model = "model"
    public static let progress = "progress"
    public static let terminalType = "terminal_type"
    public static let title = "title"
    public static let description = "description"

    /// Non-canonical display hint used by M3's sidebar chip.
    public static let modelLabel = "model_label"

    public static let canonical: Set<String> = [
        role, status, task, model, progress, terminalType, title, description
    ]

    public static let canonicalTerminalTypes: Set<String> = [
        "claude-code", "codex", "kimi", "opencode", "shell", "unknown"
    ]
}

public enum MetadataSource: String, CaseIterable, Codable, Sendable {
    case explicit
    case declare
    case osc
    case heuristic

    public var precedence: Int {
        switch self {
        case .heuristic: return 0
        case .osc:       return 1
        case .declare:   return 2
        case .explicit:  return 3
        }
    }

    /// Alias for `precedence`. Kept so call sites that read `rank` keep working.
    public var rank: Int { precedence }
}

/// Per-surface JSON metadata store (c11mux Module 2 storage primitive).
///
/// Each surface owns two parallel dictionaries:
///   - `metadata`        — free-form JSON object, capped at 64 KiB serialized.
///   - `metadata_sources` — parallel dictionary whose values are
///     `{source, ts}` records identifying who wrote each key.
///
/// The store is *in-memory only*. Consumers that need durability persist
/// externally. Entries are pruned when surfaces close (see
/// `Workspace.pruneSurfaceMetadata`).
final class SurfaceMetadataStore: @unchecked Sendable {
    static let shared = SurfaceMetadataStore()

    // MARK: - Constants

    static let payloadCapBytes: Int = 64 * 1024

    struct SourceRecord {
        let source: MetadataSource
        let ts: Double

        func toJSON() -> [String: Any] {
            return ["source": source.rawValue, "ts": ts]
        }
    }

    enum WriteError: Error {
        case invalidJSON(String)
        case payloadTooLarge
        case reservedKeyInvalidType(String, String)
        case invalidMode(String)
        case invalidSource(String)
        case invalidKeysParam
        case replaceRequiresExplicit
        case encodeFailed

        var code: String {
            switch self {
            case .invalidJSON: return "invalid_json"
            case .payloadTooLarge: return "payload_too_large"
            case .reservedKeyInvalidType: return "reserved_key_invalid_type"
            case .invalidMode: return "invalid_mode"
            case .invalidSource: return "invalid_source"
            case .invalidKeysParam: return "invalid_keys_param"
            case .replaceRequiresExplicit: return "replace_requires_explicit"
            case .encodeFailed: return "encode_error"
            }
        }

        var message: String {
            switch self {
            case .invalidJSON(let d): return d
            case .payloadTooLarge: return "metadata payload would exceed 64 KiB cap"
            case .reservedKeyInvalidType(let k, let d): return "reserved key '\(k)' violates its type rule: \(d)"
            case .invalidMode(let d): return "invalid mode: \(d)"
            case .invalidSource(let d): return "invalid source: \(d)"
            case .invalidKeysParam: return "keys must be an array of strings"
            case .replaceRequiresExplicit: return "mode 'replace' requires source 'explicit'"
            case .encodeFailed: return "failed to encode metadata"
            }
        }

        var detailData: Any? {
            switch self {
            case .reservedKeyInvalidType(let k, _): return ["key": k]
            default: return nil
            }
        }
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "com.cmux.surface-metadata", qos: .userInitiated)

    /// Per-workspace per-surface blob.
    private var metadata: [UUID: [UUID: [String: Any]]] = [:]

    /// Per-workspace per-surface parallel source sidecar.
    private var sources: [UUID: [UUID: [String: SourceRecord]]] = [:]

    // MARK: - Canonical key validation

    /// Reserved canonical keys. Keys not in this set accept any JSON value.
    static let reservedKeys: Set<String> = [
        "role",
        "status",
        "task",
        "model",
        "progress",
        "terminal_type",
        "title",
        "description"
    ]

    static func validateReservedKey(_ key: String, _ value: Any) -> WriteError? {
        switch key {
        case "role":
            return validateKebab(key: key, value: value, maxLen: 64)
        case "status":
            return validateString(key: key, value: value, maxLen: 32)
        case "task":
            return validateString(key: key, value: value, maxLen: 128)
        case "model":
            return validateKebab(key: key, value: value, maxLen: 64)
        case "progress":
            guard let num = value as? NSNumber, !(num is Bool) else {
                return .reservedKeyInvalidType(key, "expected number")
            }
            let d = num.doubleValue
            guard d.isFinite, d >= 0.0, d <= 1.0 else {
                return .reservedKeyInvalidType(key, "expected 0.0–1.0")
            }
            return nil
        case "terminal_type":
            return validateKebab(key: key, value: value, maxLen: 32)
        case "title":
            return validateString(key: key, value: value, maxLen: 256)
        case "description":
            return validateString(key: key, value: value, maxLen: 2048)
        default:
            return nil
        }
    }

    private static func validateString(key: String, value: Any, maxLen: Int) -> WriteError? {
        guard let s = value as? String else {
            return .reservedKeyInvalidType(key, "expected string")
        }
        if s.count > maxLen {
            return .reservedKeyInvalidType(key, "exceeds max length \(maxLen)")
        }
        return nil
    }

    private static let kebabPattern: NSRegularExpression = {
        // ^[a-z][a-z0-9-]*$
        return try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]*$", options: [])
    }()

    private static func validateKebab(key: String, value: Any, maxLen: Int) -> WriteError? {
        guard let s = value as? String else {
            return .reservedKeyInvalidType(key, "expected string")
        }
        if s.isEmpty {
            return .reservedKeyInvalidType(key, "empty string")
        }
        if s.count > maxLen {
            return .reservedKeyInvalidType(key, "exceeds max length \(maxLen)")
        }
        let range = NSRange(location: 0, length: (s as NSString).length)
        if kebabPattern.firstMatch(in: s, options: [], range: range) == nil {
            return .reservedKeyInvalidType(key, "must be lowercase kebab-case [a-z][a-z0-9-]*")
        }
        return nil
    }

    // MARK: - Public API

    /// Result of a set/clear operation.
    struct WriteResult {
        /// per-key applied flag.
        var applied: [String: Bool] = [:]
        /// per-key rejection reason (populated when applied == false).
        var reasons: [String: String] = [:]
        /// Post-op snapshot of the full surface metadata blob.
        var metadata: [String: Any] = [:]
        /// Post-op snapshot of the sidecar.
        var sources: [String: [String: Any]] = [:]
    }

    /// Merge or replace a partial metadata object on a surface.
    ///
    /// - Parameters:
    ///   - workspaceId: Workspace UUID.
    ///   - surfaceId: Surface UUID.
    ///   - partial: Partial (or full, for replace) JSON object.
    ///   - mode: `.merge` or `.replace`.
    ///   - source: Writer source.
    /// - Returns: per-key applied flags + reasons + post-op snapshot.
    func setMetadata(
        workspaceId: UUID,
        surfaceId: UUID,
        partial: [String: Any],
        mode: WriteMode,
        source: MetadataSource
    ) throws -> WriteResult {
        return try queue.sync {
            try setMetadataLocked(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                partial: partial,
                mode: mode,
                source: source
            )
        }
    }

    enum WriteMode: String {
        case merge
        case replace
    }

    /// Returns the current metadata for the surface (empty dict if none).
    func getMetadata(workspaceId: UUID, surfaceId: UUID) -> (metadata: [String: Any], sources: [String: [String: Any]]) {
        return queue.sync {
            let md = metadata[workspaceId]?[surfaceId] ?? [:]
            let src = sources[workspaceId]?[surfaceId]
                .map { m in m.mapValues { $0.toJSON() } } ?? [:]
            return (md, src)
        }
    }

    /// Returns whether a specific key is currently set on a surface, and its source.
    func getSource(workspaceId: UUID, surfaceId: UUID, key: String) -> MetadataSource? {
        return queue.sync {
            return sources[workspaceId]?[surfaceId]?[key]?.source
        }
    }

    /// Clear specific keys (or the entire blob when `keys == nil`).
    /// `keys == nil` requires `source == .explicit`.
    func clearMetadata(
        workspaceId: UUID,
        surfaceId: UUID,
        keys: [String]?,
        source: MetadataSource
    ) throws -> WriteResult {
        return try queue.sync {
            var result = WriteResult()
            if keys == nil {
                guard source == .explicit else {
                    throw WriteError.replaceRequiresExplicit
                }
                metadata[workspaceId]?[surfaceId] = [:]
                sources[workspaceId]?[surfaceId] = [:]
                result.metadata = [:]
                result.sources = [:]
                return result
            }

            var blob = metadata[workspaceId]?[surfaceId] ?? [:]
            var sblob = sources[workspaceId]?[surfaceId] ?? [:]

            for key in keys! {
                if let cur = sblob[key] {
                    if source.precedence < cur.source.precedence {
                        result.applied[key] = false
                        result.reasons[key] = "lower_precedence"
                        continue
                    }
                }
                blob.removeValue(forKey: key)
                sblob.removeValue(forKey: key)
                result.applied[key] = true
            }

            metadata[workspaceId, default: [:]][surfaceId] = blob
            sources[workspaceId, default: [:]][surfaceId] = sblob
            result.metadata = blob
            result.sources = sblob.mapValues { $0.toJSON() }
            return result
        }
    }

    /// Restore metadata + sources for a surface from a session snapshot
    /// (Tier 1 Phase 2). Bypasses the precedence chain — the snapshot IS
    /// the prior session's source of truth. A `.heuristic` value in the
    /// snapshot restores as `.heuristic` with its original `ts`, even if
    /// the newly-initialized surface has already written a `.declare`
    /// value to the same key: the snapshot wins.
    ///
    /// Silent by design. The store has no observer infrastructure today;
    /// any consumer wanting post-restore data queries it on demand.
    /// Adding a notification pipeline is Phase 3 scope.
    func restoreFromSnapshot(
        workspaceId: UUID,
        surfaceId: UUID,
        values: [String: Any],
        sources: [String: SourceRecord]
    ) {
        queue.sync {
            metadata[workspaceId, default: [:]][surfaceId] = values
            self.sources[workspaceId, default: [:]][surfaceId] = sources
        }
    }

    /// Remove all metadata for a surface. Called from `pruneSurfaceMetadata`
    /// when a surface closes. Bypasses precedence (the surface is gone).
    func removeSurface(workspaceId: UUID, surfaceId: UUID) {
        queue.async { [self] in
            metadata[workspaceId]?.removeValue(forKey: surfaceId)
            sources[workspaceId]?.removeValue(forKey: surfaceId)
        }
    }

    /// Remove metadata for any surfaces not in the `validSurfaceIds` set.
    /// Called from `Workspace.pruneSurfaceMetadata`.
    func pruneWorkspace(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        queue.async { [self] in
            if var wsMetadata = metadata[workspaceId] {
                wsMetadata = wsMetadata.filter { validSurfaceIds.contains($0.key) }
                metadata[workspaceId] = wsMetadata
            }
            if var wsSources = sources[workspaceId] {
                wsSources = wsSources.filter { validSurfaceIds.contains($0.key) }
                sources[workspaceId] = wsSources
            }
        }
    }

    /// Remove all metadata for a workspace.
    func removeWorkspace(workspaceId: UUID) {
        queue.async { [self] in
            metadata.removeValue(forKey: workspaceId)
            sources.removeValue(forKey: workspaceId)
        }
    }

    // MARK: - Internal write path (used by heuristic — no socket round-trip)

    /// Write a single key with precedence gating. Returns `true` if applied.
    /// Used by M1's AgentDetector.
    @discardableResult
    func setInternal(
        workspaceId: UUID,
        surfaceId: UUID,
        key: String,
        value: Any,
        source: MetadataSource
    ) -> Bool {
        return queue.sync {
            var blob = metadata[workspaceId]?[surfaceId] ?? [:]
            var sblob = sources[workspaceId]?[surfaceId] ?? [:]

            if let cur = sblob[key], source.precedence < cur.source.precedence {
                return false
            }
            if SurfaceMetadataStore.validateReservedKey(key, value) != nil {
                return false
            }
            // Avoid churn on no-op same-source same-value writes.
            if let existing = blob[key], sameJSONValue(existing, value), sblob[key]?.source == source {
                return false
            }
            blob[key] = value
            sblob[key] = SourceRecord(source: source, ts: Date().timeIntervalSince1970)

            if let encoded = try? JSONSerialization.data(withJSONObject: blob, options: []),
               encoded.count > SurfaceMetadataStore.payloadCapBytes {
                return false
            }

            metadata[workspaceId, default: [:]][surfaceId] = blob
            sources[workspaceId, default: [:]][surfaceId] = sblob
            return true
        }
    }

    // MARK: - Locked merge helper

    private func setMetadataLocked(
        workspaceId: UUID,
        surfaceId: UUID,
        partial: [String: Any],
        mode: WriteMode,
        source: MetadataSource
    ) throws -> WriteResult {
        if mode == .replace, source != .explicit {
            throw WriteError.replaceRequiresExplicit
        }

        // Pre-validate every reserved key *before* taking the mutation path so
        // a single bad value aborts the whole write (matches M2 spec).
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

        if mode == .replace {
            blob = [:]
            sblob = [:]
        } else {
            blob = metadata[workspaceId]?[surfaceId] ?? [:]
            sblob = sources[workspaceId]?[surfaceId] ?? [:]
        }

        let ts = Date().timeIntervalSince1970

        for (k, v) in partial {
            if mode == .merge, let cur = sblob[k], source.precedence < cur.source.precedence {
                result.applied[k] = false
                result.reasons[k] = "lower_precedence"
                continue
            }
            blob[k] = v
            sblob[k] = SourceRecord(source: source, ts: ts)
            result.applied[k] = true
        }

        // Size check after merge.
        guard let encoded = try? JSONSerialization.data(withJSONObject: blob, options: []) else {
            throw WriteError.encodeFailed
        }
        if encoded.count > SurfaceMetadataStore.payloadCapBytes {
            throw WriteError.payloadTooLarge
        }

        metadata[workspaceId, default: [:]][surfaceId] = blob
        sources[workspaceId, default: [:]][surfaceId] = sblob

        result.metadata = blob
        result.sources = sblob.mapValues { $0.toJSON() }
        return result
    }

    // MARK: - Value equality for dedupe

    private func sameJSONValue(_ a: Any, _ b: Any) -> Bool {
        if let sa = a as? String, let sb = b as? String { return sa == sb }
        if let na = a as? NSNumber, let nb = b as? NSNumber { return na == nb }
        if let ba = a as? Bool, let bb = b as? Bool { return ba == bb }
        // Fall through to JSON serialization comparison for complex types.
        let da = try? JSONSerialization.data(withJSONObject: ["v": a], options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: ["v": b], options: [.sortedKeys])
        return da == db
    }
}

public extension MetadataSource {
    init?(string s: String?) {
        guard let s, let v = MetadataSource(rawValue: s) else { return nil }
        self = v
    }
}
