import Foundation

/// ISO-8601 date formatter with fractional seconds (Trident I9). Phase 1
/// plan dictated "ISO-8601 with fractional seconds", but the default
/// `.iso8601` strategy drops subsecond precision — a `createdAt` from
/// `Date()` (nanosecond precision) re-serialised at second precision
/// breaks round-trip equality. Shared by both encode and decode sites in
/// the store and envelope Codable paths.
let workspaceSnapshotDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Filesystem I/O for snapshot envelopes. Writes always go to
/// `~/.c11-snapshots/` (the rename from `cmux` → `c11` is the one-way
/// door). Reads support a backwards-compat fallback to `~/.cmux-snapshots/`
/// so operators who piloted an earlier iteration don't lose files; `c11
/// list-snapshots` merges both locations and tags legacy rows.
///
/// Atomic writes use `Data.write(to:options:)` with `.atomic`. File names
/// are `<snapshot_id>.json` — the ULID stem is authoritative; renames on
/// disk would desync the envelope's `snapshot_id` and must be avoided.
///
/// Not `@MainActor`. Socket handlers call this off the main thread; tests
/// inject a `directoryOverride:` so the real home dir never leaks into
/// CI.
struct WorkspaceSnapshotStore: Sendable {

    private let currentDirectory: URL
    private let legacyDirectory: URL
    private let fileManager: FileManager

    init(
        currentDirectory: URL = WorkspaceSnapshotStore.defaultDirectory(),
        legacyDirectory: URL = WorkspaceSnapshotStore.defaultLegacyDirectory(),
        fileManager: FileManager = .default
    ) {
        self.currentDirectory = currentDirectory
        self.legacyDirectory = legacyDirectory
        self.fileManager = fileManager
    }

    // MARK: - Default locations

    /// `~/.c11-snapshots/`. Writes always land here.
    static func defaultDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".c11-snapshots", isDirectory: true)
    }

    /// `~/.cmux-snapshots/`. Read-only legacy path.
    static func defaultLegacyDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cmux-snapshots", isDirectory: true)
    }

    // MARK: - Write

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case createDirectoryFailed(String, underlying: String)
        case encodeFailed(String)
        case writeFailed(String, underlying: String)
        case readFailed(String, underlying: String)
        case decodeFailed(String, underlying: String)
        case notFound(String)
        case invalidSnapshotId(String)
        case pathEscapesSnapshotRoots(String)

        var code: String {
            switch self {
            case .createDirectoryFailed:   return "snapshot_dir_create_failed"
            case .encodeFailed:            return "snapshot_encode_failed"
            case .writeFailed:             return "snapshot_write_failed"
            case .readFailed:              return "snapshot_read_failed"
            case .decodeFailed:            return "snapshot_decode_failed"
            case .notFound:                return "snapshot_not_found"
            case .invalidSnapshotId:       return "invalid_snapshot_id"
            case .pathEscapesSnapshotRoots: return "path_escapes_snapshot_roots"
            }
        }

        var description: String {
            switch self {
            case .createDirectoryFailed(let path, let err):
                return "snapshot dir create failed at \(path): \(err)"
            case .encodeFailed(let detail):
                return "snapshot encode failed: \(detail)"
            case .writeFailed(let path, let err):
                return "snapshot write failed at \(path): \(err)"
            case .readFailed(let path, let err):
                return "snapshot read failed at \(path): \(err)"
            case .decodeFailed(let path, let err):
                return "snapshot decode failed at \(path): \(err)"
            case .notFound(let id):
                return "snapshot id '\(id)' not found under ~/.c11-snapshots or ~/.cmux-snapshots"
            case .invalidSnapshotId(let id):
                return "snapshot id '\(id)' is not a safe filename stem"
            case .pathEscapesSnapshotRoots(let path):
                return "resolved path '\(path)' escapes the snapshot roots"
            }
        }
    }

    // MARK: - Snapshot-id safety

    /// Grammar for a safe snapshot-id filename stem: at least one character,
    /// Crockford-base32-ish alphabet + a few delimiters, bounded length.
    /// Rejects path separators, `..`, dots, and anything that could escape
    /// the destination directory when appended verbatim.
    private static let safeSnapshotIdPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,128}$", options: [])
    }()

    static func isSafeSnapshotId(_ candidate: String) -> Bool {
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        return safeSnapshotIdPattern.firstMatch(in: candidate, options: [], range: range) != nil
    }

    /// Write `snapshot` to `<currentDirectory>/<snapshot.snapshot_id>.json`,
    /// or to an explicit path. Returns the resolved path. Atomic write;
    /// directory is created on demand.
    ///
    /// **Do not call this path from socket handlers.** An arbitrary
    /// `explicitPath` is an arbitrary-file-write primitive — a malicious
    /// agent could overwrite `~/.claude/settings.json` with snapshot
    /// JSON. This entry point exists for the CLI (`c11 snapshot --out
    /// <path>`) where the caller holds real shell permissions already.
    /// Socket handlers must call `writeToDefaultDirectory(_:)` instead.
    @discardableResult
    func write(_ snapshot: WorkspaceSnapshotFile, to explicitPath: URL? = nil) throws -> URL {
        let target: URL
        if let explicitPath {
            target = explicitPath
        } else {
            target = currentDirectory.appendingPathComponent("\(snapshot.snapshotId).json")
        }
        let parent = target.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw StoreError.createDirectoryFailed(parent.path, underlying: "\(error)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(workspaceSnapshotDateFormatter.string(from: date))
        }
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw StoreError.encodeFailed("\(error)")
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw StoreError.writeFailed(target.path, underlying: "\(error)")
        }
        return target
    }

    /// Socket-safe write: always lands at
    /// `<currentDirectory>/<snapshot_id>.json`. The snapshot id must be
    /// a safe filename stem; rejects anything that could traverse out of
    /// the destination directory (`..`, `/`, embedded dots, etc.).
    ///
    /// Socket handlers (`snapshot.create`) must go through here. An agent
    /// that can talk to the v2 socket cannot supply a caller-chosen path,
    /// so this primitive cannot be turned into an arbitrary-file-write
    /// vector.
    @discardableResult
    func writeToDefaultDirectory(_ snapshot: WorkspaceSnapshotFile) throws -> URL {
        guard WorkspaceSnapshotStore.isSafeSnapshotId(snapshot.snapshotId) else {
            throw StoreError.invalidSnapshotId(snapshot.snapshotId)
        }
        return try write(
            snapshot,
            to: currentDirectory.appendingPathComponent("\(snapshot.snapshotId).json")
        )
    }

    // MARK: - Read

    /// Read and decode a snapshot from an absolute URL. Does not consult the
    /// id-based lookup — see `read(byId:)` for that.
    func read(from url: URL) throws -> WorkspaceSnapshotFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.readFailed(url.path, underlying: "\(error)")
        }
        let decoder = JSONDecoder()
        // Match the encoder: parse with fractional-seconds first, fall
        // back to second-precision for legacy `~/.cmux-snapshots/` files
        // written by the earlier pilot build.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = workspaceSnapshotDateFormatter.date(from: raw) {
                return date
            }
            let legacy = ISO8601DateFormatter()
            legacy.formatOptions = [.withInternetDateTime]
            if let date = legacy.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 date string, got '\(raw)'"
            )
        }
        do {
            return try decoder.decode(WorkspaceSnapshotFile.self, from: data)
        } catch {
            throw StoreError.decodeFailed(url.path, underlying: "\(error)")
        }
    }

    /// Resolve an id to a path (current dir first, then legacy). Returns the
    /// first match. Throws `.notFound` when neither path exists.
    ///
    /// Validates the id against `isSafeSnapshotId`, then verifies the
    /// realpath after resolution lives under one of the configured
    /// snapshot roots. Belt and braces: the filename-stem check catches
    /// the common `"../../etc/passwd"` case, and the realpath check
    /// catches symlink escapes where the file name looks safe but the
    /// resolved file lives elsewhere on disk (e.g. a symlinked legacy
    /// directory pointing outside home).
    func resolvePath(byId snapshotId: String) throws -> URL {
        guard WorkspaceSnapshotStore.isSafeSnapshotId(snapshotId) else {
            throw StoreError.invalidSnapshotId(snapshotId)
        }
        let primary = currentDirectory.appendingPathComponent("\(snapshotId).json")
        if fileManager.fileExists(atPath: primary.path) {
            try assertPathUnderSnapshotRoots(primary)
            return primary
        }
        let legacy = legacyDirectory.appendingPathComponent("\(snapshotId).json")
        if fileManager.fileExists(atPath: legacy.path) {
            try assertPathUnderSnapshotRoots(legacy)
            return legacy
        }
        throw StoreError.notFound(snapshotId)
    }

    /// Read a snapshot by id, checking `~/.c11-snapshots/` then the legacy
    /// directory. Throws `.notFound` if neither has it.
    func read(byId snapshotId: String) throws -> WorkspaceSnapshotFile {
        try read(from: resolvePath(byId: snapshotId))
    }

    /// Verify that `url` resolves to a file under either `currentDirectory`
    /// or `legacyDirectory`. Uses `URL.standardized.resolvingSymlinksInPath()`
    /// on both sides so the comparison is on canonical paths, not string
    /// prefixes. Rejects escapes in two classes:
    ///
    /// 1. Lexical — a snapshot id containing `..` segments. The
    ///    `isSafeSnapshotId` pre-check normally filters these before we
    ///    ever get here, but the defence holds even if that filter is
    ///    bypassed.
    /// 2. Symlink — a file whose name looks safe but whose realpath
    ///    points outside the snapshot roots (e.g. a symlink farm inside
    ///    the legacy directory).
    private func assertPathUnderSnapshotRoots(_ url: URL) throws {
        let resolvedTarget = url.standardized.resolvingSymlinksInPath().path
        let roots = [currentDirectory, legacyDirectory].map {
            $0.standardized.resolvingSymlinksInPath().path
        }
        for root in roots {
            // Append a trailing separator to ensure `/a/b` does not match
            // `/a/bc`. Comparing the normalised forms of `$root + "/"`
            // against the resolved file path gives a proper containment
            // check.
            let rootWithSeparator = root.hasSuffix("/") ? root : root + "/"
            if resolvedTarget.hasPrefix(rootWithSeparator) {
                return
            }
        }
        throw StoreError.pathEscapesSnapshotRoots(resolvedTarget)
    }

    // MARK: - List

    /// Merge entries from the current directory + legacy directory into one
    /// list. Each entry carries its source. Sorted by `createdAt` descending
    /// (newest first) so `c11 list-snapshots` reads top-to-bottom.
    func list() throws -> [WorkspaceSnapshotIndex] {
        var result: [WorkspaceSnapshotIndex] = []
        result.append(contentsOf: enumerate(
            directory: currentDirectory,
            source: .current
        ))
        // Only walk the legacy path if it's not the same as the current —
        // test harnesses commonly override both to the same tmp dir.
        if legacyDirectory != currentDirectory {
            result.append(contentsOf: enumerate(
                directory: legacyDirectory,
                source: .legacy
            ))
        }
        result.sort { $0.createdAt > $1.createdAt }
        return result
    }

    /// Walk a directory and emit one `WorkspaceSnapshotIndex` per decodable
    /// `.json` file. Malformed files are skipped silently; the listing's
    /// job is to show what's usable, not to surface every parse error.
    /// (Callers who want strict-mode reads call `read(from:)` directly.)
    private func enumerate(
        directory: URL,
        source: WorkspaceSnapshotIndex.Source
    ) -> [WorkspaceSnapshotIndex] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
        var out: [WorkspaceSnapshotIndex] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let snapshot = try? read(from: url) else { continue }
            out.append(WorkspaceSnapshotIndex(
                snapshotId: snapshot.snapshotId,
                path: url.path,
                createdAt: snapshot.createdAt,
                workspaceTitle: snapshot.plan.workspace.title,
                surfaceCount: snapshot.plan.surfaces.count,
                origin: snapshot.origin,
                source: source
            ))
        }
        return out
    }
}
