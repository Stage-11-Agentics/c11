import Foundation
#if DEBUG
import Bonsplit
#endif

/// Codable JSON value used to persist `SurfaceMetadataStore` contents across
/// c11mux restarts. Numbers are stored as `Double`; consumers needing integer
/// fidelity must convert explicitly. `Bool` is distinct from number on the
/// wire and on the Swift side, matching JSON semantics.
enum PersistedJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([PersistedJSONValue])
    case object([String: PersistedJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Decode Bool before Double: JSON `true`/`false` are bools, numbers
        // are numbers, and JSONDecoder respects the distinction. Keeping this
        // order ensures a persisted `.bool(true)` never surfaces as `.number`.
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .number(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([PersistedJSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: PersistedJSONValue].self) {
            self = .object(object)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "PersistedJSONValue: unsupported JSON shape"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let d): try container.encode(d)
        case .bool(let b):   try container.encode(b)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null:          try container.encodeNil()
        }
    }
}

/// Codable sidecar preserving the `(source, ts)` record alongside a persisted
/// metadata value so the precedence chain survives a restart.
struct PersistedMetadataSource: Codable, Sendable, Equatable {
    /// `MetadataSource` raw value: `"explicit" | "declare" | "osc" | "heuristic"`.
    /// Unknown strings decode cleanly (no Codable error); the bridge downgrades
    /// them to `.heuristic` with a debug log on the way back into the store.
    var source: String
    /// Seconds since 1970, matching `SurfaceMetadataStore.SourceRecord.ts`.
    var ts: TimeInterval
}

// MARK: - Persist-direction bridge ([String: Any] → persisted)

enum PersistedMetadataBridge {
    /// Rollback safety net. When `CMUX_DISABLE_METADATA_PERSIST=1` is in
    /// the app's launch environment, metadata is omitted from snapshots
    /// on write and ignored on restore. App-launch-scope only — the CLI
    /// is a separate process, so setting the var on a `cmux` invocation
    /// has no effect. Deletable in a followup PR once Phase 2 is stable.
    static var isPersistDisabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_DISABLE_METADATA_PERSIST"] == "1"
    }

    /// Enforce the 64 KiB per-entity cap at the persistence boundary.
    /// Bug-guard only — the live store already caps writes. If exceeded,
    /// drop keys (largest encoded first) until under cap, logging each
    /// drop. Never throws.
    ///
    /// `entityKind` and `entityId` are diagnostic only — they appear in the
    /// debug log so reviewers can tell a surface drop apart from a pane drop.
    /// The cap value is identical for both stores
    /// (`SurfaceMetadataStore.payloadCapBytes == PaneMetadataStore.payloadCapBytes`),
    /// so the same enforcement path is reused.
    static func enforceSizeCap(
        _ values: [String: PersistedJSONValue],
        entityKind: String,
        entityId: UUID
    ) -> [String: PersistedJSONValue] {
        var current = values
        while let data = try? JSONEncoder().encode(current),
              data.count > SurfaceMetadataStore.payloadCapBytes {
            // Drop the largest single-key encoding. Deterministic tie-break
            // by sorted key name so the behavior is test-stable.
            let sizedKeys: [(key: String, size: Int)] = current.keys.sorted().map { key in
                let wrapper: [String: PersistedJSONValue] = [key: current[key]!]
                let size = (try? JSONEncoder().encode(wrapper).count) ?? 0
                return (key, size)
            }
            guard let victim = sizedKeys.max(by: { $0.size < $1.size }) else { break }
            #if DEBUG
            dlog(
                "metadata.persist.overcap.drop \(entityKind)=\(entityId.uuidString.prefix(8)) " +
                "key=\(victim.key) droppedSize=\(victim.size)"
            )
            #endif
            current.removeValue(forKey: victim.key)
            if current.isEmpty { break }
        }
        return current
    }

    /// Back-compat shim for the original surface-only signature. Existing
    /// callers keep working unchanged; new pane-side callers go through the
    /// `entityKind:entityId:` form directly.
    static func enforceSizeCap(
        _ values: [String: PersistedJSONValue],
        surfaceId: UUID
    ) -> [String: PersistedJSONValue] {
        return enforceSizeCap(values, entityKind: "surface", entityId: surfaceId)
    }

    /// Coerce a live metadata blob into its persisted representation.
    /// Values that cannot be represented as JSON are dropped with a debug
    /// log; the rest of the blob survives. Never throws — snapshot writes
    /// must be side-effect-free with respect to persistence failures.
    static func encodeValues(
        _ values: [String: Any],
        surfaceIdForLog: UUID? = nil
    ) -> [String: PersistedJSONValue] {
        var result: [String: PersistedJSONValue] = [:]
        for (key, value) in values {
            if let persisted = encode(value: value, key: key, surfaceIdForLog: surfaceIdForLog) {
                result[key] = persisted
            }
        }
        return result
    }

    /// Convert sidecar entries as returned by
    /// `SurfaceMetadataStore.getMetadata().sources` (`[String: [String: Any]]`
    /// via `SourceRecord.toJSON()`) into persisted form.
    static func encodeSources(
        _ sources: [String: [String: Any]]
    ) -> [String: PersistedMetadataSource] {
        var result: [String: PersistedMetadataSource] = [:]
        for (key, record) in sources {
            guard let source = record["source"] as? String else { continue }
            let ts = (record["ts"] as? Double) ?? 0.0
            result[key] = PersistedMetadataSource(source: source, ts: ts)
        }
        return result
    }

    // MARK: - Restore-direction bridge (persisted → [String: Any])

    static func decodeValues(_ persisted: [String: PersistedJSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in persisted {
            result[key] = decode(value: value)
        }
        return result
    }

    /// Convert persisted sidecar into live `SourceRecord`s. Unknown source
    /// raw values are downgraded to `.heuristic` with a debug log — this
    /// matches the precedence contract (an unreadable origin can never
    /// outrank a new `.explicit` write).
    static func decodeSources(
        _ persisted: [String: PersistedMetadataSource]
    ) -> [String: SurfaceMetadataStore.SourceRecord] {
        var result: [String: SurfaceMetadataStore.SourceRecord] = [:]
        for (key, ps) in persisted {
            let source: MetadataSource
            if let known = MetadataSource(rawValue: ps.source) {
                source = known
            } else {
                #if DEBUG
                dlog("metadata.restore.unknownSource key=\(key) raw=\(ps.source) fallback=heuristic")
                #endif
                source = .heuristic
            }
            result[key] = SurfaceMetadataStore.SourceRecord(source: source, ts: ps.ts)
        }
        return result
    }

    // MARK: - Internals

    private static func encode(
        value: Any,
        key: String,
        surfaceIdForLog: UUID?
    ) -> PersistedJSONValue? {
        if value is NSNull {
            return .null
        }

        // Bool must be checked before NSNumber. Swift's `as? Bool` matches
        // NSNumber(value: 0) and NSNumber(value: 1) as well as actual bools,
        // so a naive Bool-first check would misencode plain numbers. CFBoolean
        // is the concrete bridged type JSONSerialization emits for JSON
        // `true`/`false`, and native Swift `Bool` bridges to it at the CF
        // level; both share `CFBooleanGetTypeID()`.
        let cfTypeID = CFGetTypeID(value as CFTypeRef)
        if cfTypeID == CFBooleanGetTypeID() {
            if let b = value as? Bool {
                return .bool(b)
            }
        }

        if let n = value as? NSNumber {
            let d = n.doubleValue
            guard d.isFinite else {
                #if DEBUG
                dlog("metadata.persist.drop key=\(key) reason=non_finite value=\(d)")
                #endif
                return nil
            }
            return .number(d)
        }

        // Native Swift numeric types (not bridged via NSNumber — rare, but
        // possible if a caller writes a Swift `Int` directly into the
        // `[String: Any]` dictionary without letting ObjC bridging happen).
        if let i = value as? Int    { return .number(Double(i)) }
        if let d = value as? Double {
            guard d.isFinite else {
                #if DEBUG
                dlog("metadata.persist.drop key=\(key) reason=non_finite value=\(d)")
                #endif
                return nil
            }
            return .number(d)
        }
        if let f = value as? Float {
            let d = Double(f)
            guard d.isFinite else {
                #if DEBUG
                dlog("metadata.persist.drop key=\(key) reason=non_finite value=\(d)")
                #endif
                return nil
            }
            return .number(d)
        }

        if let s = value as? String {
            return .string(s)
        }

        if let arr = value as? [Any] {
            var out: [PersistedJSONValue] = []
            out.reserveCapacity(arr.count)
            for (idx, element) in arr.enumerated() {
                if let p = encode(value: element, key: "\(key)[\(idx)]", surfaceIdForLog: surfaceIdForLog) {
                    out.append(p)
                } else {
                    // An element dropped: keep the array but preserve length
                    // by substituting null, since JSON arrays are position-
                    // sensitive (consumer code may index into them).
                    out.append(.null)
                }
            }
            return .array(out)
        }

        if let obj = value as? [String: Any] {
            return .object(encodeValues(obj, surfaceIdForLog: surfaceIdForLog))
        }

        #if DEBUG
        dlog("metadata.persist.drop key=\(key) type=\(String(describing: type(of: value)))")
        #endif
        return nil
    }

    private static func decode(value: PersistedJSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .number(let d):
            return d
        case .string(let s):
            return s
        case .array(let a):
            return a.map(decode(value:))
        case .object(let o):
            return decodeValues(o)
        }
    }
}
