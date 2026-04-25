import Foundation

/// Filesystem I/O for blueprint envelopes.
///
/// Three sources in priority order: per-repo (`.cmux/blueprints/` walked up
/// from a working directory), per-user (`~/.config/cmux/blueprints/`), and
/// built-in (app bundle `Blueprints/` subdirectory). `merged(cwd:)` combines
/// all three, per-repo first, sorted by modifiedAt desc within each group.
///
/// Not `@MainActor`. Socket handlers and CLI commands call this off the main
/// thread. Tests inject `directoryOverride:` so the real home dir never leaks
/// into CI.
struct WorkspaceBlueprintStore: Sendable {

    private let directoryOverride: URL?
    private let fileManager: FileManager

    init(directoryOverride: URL? = nil, fileManager: FileManager = .default) {
        self.directoryOverride = directoryOverride
        self.fileManager = fileManager
    }

    // MARK: - Error

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case createDirectoryFailed(String, underlying: String)
        case encodeFailed(String)
        case writeFailed(String, underlying: String)
        case readFailed(String, underlying: String)
        case decodeFailed(String, underlying: String)

        var code: String {
            switch self {
            case .createDirectoryFailed:  return "blueprint_dir_create_failed"
            case .encodeFailed:           return "blueprint_encode_failed"
            case .writeFailed:            return "blueprint_write_failed"
            case .readFailed:             return "blueprint_read_failed"
            case .decodeFailed:           return "blueprint_decode_failed"
            }
        }

        var description: String {
            switch self {
            case .createDirectoryFailed(let path, let err):
                return "blueprint dir create failed at \(path): \(err)"
            case .encodeFailed(let detail):
                return "blueprint encode failed: \(detail)"
            case .writeFailed(let path, let err):
                return "blueprint write failed at \(path): \(err)"
            case .readFailed(let path, let err):
                return "blueprint read failed at \(path): \(err)"
            case .decodeFailed(let path, let err):
                return "blueprint decode failed at \(path): \(err)"
            }
        }
    }

    // MARK: - Source discovery

    /// Scan `.cmux/blueprints/*.{json,md}` walking UP from `cwd` (git-discovery
    /// style) until the filesystem root or the user's home directory.
    func perRepoBlueprintURLs(cwd: URL) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser.standardized
        var candidate = cwd.standardized
        // Walk up, but never above home — stop on first hit rather than
        // accumulating from every ancestor to avoid shadowing surprises.
        while true {
            let dir = candidate.appendingPathComponent(".cmux/blueprints", isDirectory: true)
            if fileManager.fileExists(atPath: dir.path) {
                return blueprintURLs(in: dir)
            }
            // Stop at home or root.
            if candidate == home || candidate.path == "/" {
                break
            }
            let parent = candidate.deletingLastPathComponent().standardized
            // Detect that we've reached the root without hitting home.
            if parent == candidate {
                break
            }
            candidate = parent
        }
        return []
    }

    /// Scan `~/.config/cmux/blueprints/*.{json,md}`, or the override when set.
    func perUserBlueprintURLs() -> [URL] {
        let dir: URL
        if let override = directoryOverride {
            dir = override
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            dir = home.appendingPathComponent(".config/cmux/blueprints", isDirectory: true)
        }
        return blueprintURLs(in: dir)
    }

    /// Scan the app bundle's `Blueprints/` subdirectory, or the override's
    /// `Blueprints/` subdirectory when a `directoryOverride` is set.
    func builtInBlueprintURLs() -> [URL] {
        if let override = directoryOverride {
            let dir = override.appendingPathComponent("Blueprints", isDirectory: true)
            return blueprintURLs(in: dir)
        }
        var urls: [URL] = []
        for ext in ["json", "md"] {
            let found = Bundle.main.urls(
                forResourcesWithExtension: ext,
                subdirectory: "Blueprints"
            ) ?? []
            urls.append(contentsOf: found)
        }
        return urls
    }

    // MARK: - Merged list

    /// Recency-sorted (modifiedAt desc) merge of all three sources.
    /// Per-repo entries come first, then per-user, then built-in; within each
    /// group files are sorted by modifiedAt desc. Returns `[]` if all sources
    /// are empty; never throws — unreadable files are silently skipped.
    func merged(cwd: URL?) -> [WorkspaceBlueprintIndex] {
        var result: [WorkspaceBlueprintIndex] = []
        if let cwd {
            result.append(contentsOf: indexEntries(
                urls: perRepoBlueprintURLs(cwd: cwd),
                source: .repo
            ))
        }
        result.append(contentsOf: indexEntries(
            urls: perUserBlueprintURLs(),
            source: .user
        ))
        result.append(contentsOf: indexEntries(
            urls: builtInBlueprintURLs(),
            source: .builtIn
        ))
        return result
    }

    // MARK: - Read / Write

    func read(url: URL) throws -> WorkspaceBlueprintFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.readFailed(url.path, underlying: "\(error)")
        }
        do {
            return try JSONDecoder().decode(WorkspaceBlueprintFile.self, from: data)
        } catch {
            throw StoreError.decodeFailed(url.path, underlying: "\(error)")
        }
    }

    /// Atomic write. Directory is created on demand. Follows the same
    /// write-temp-then-move contract as `WorkspaceSnapshotStore`.
    func write(_ file: WorkspaceBlueprintFile, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw StoreError.createDirectoryFailed(parent.path, underlying: "\(error)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw StoreError.encodeFailed("\(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(url.path, underlying: "\(error)")
        }
    }

    // MARK: - Private helpers

    /// Collect `.json` and `.md` files from a directory. Returns `[]` silently
    /// if the directory doesn't exist.
    private func blueprintURLs(in directory: URL) -> [URL] {
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
        return entries.filter {
            guard (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            let ext = $0.pathExtension.lowercased()
            return ext == "json" || ext == "md"
        }
    }

    /// Build `WorkspaceBlueprintIndex` entries from a set of URLs. Reads each
    /// file's `name` and `description` from the JSON envelope; skips
    /// undecodable files silently. Sorted by modifiedAt desc.
    private func indexEntries(
        urls: [URL],
        source: WorkspaceBlueprintIndex.Source
    ) -> [WorkspaceBlueprintIndex] {
        var out: [WorkspaceBlueprintIndex] = []
        for url in urls {
            // modifiedAt from filesystem attributes; skip if unavailable.
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let modifiedAt = attrs[.modificationDate] as? Date else { continue }
            // For JSON files decode the envelope to get name/description.
            // Markdown blueprints use the filename stem as the name.
            let name: String
            let description: String?
            if url.pathExtension.lowercased() == "json" {
                guard let file = try? read(url: url) else { continue }
                name = file.name
                description = file.description
            } else {
                name = url.deletingPathExtension().lastPathComponent
                description = nil
            }
            out.append(WorkspaceBlueprintIndex(
                name: name,
                description: description,
                url: url.path,
                source: source,
                modifiedAt: modifiedAt
            ))
        }
        out.sort { $0.modifiedAt > $1.modifiedAt }
        return out
    }
}
