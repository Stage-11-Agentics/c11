import Foundation

/// Filesystem I/O for blueprint envelopes.
///
/// Three sources in priority order: per-repo (walks up from a working
/// directory checking `.c11/blueprints/` then `.cmux/blueprints/`),
/// per-user (`~/.config/c11/blueprints/` plus the legacy
/// `~/.config/cmux/blueprints/`), and built-in (app bundle `Blueprints/`
/// subdirectory). `merged(cwd:)` combines all three, per-repo first,
/// sorted by modifiedAt desc within each group.
///
/// Files may be either JSON (`.json`) or Markdown (`.md`). Read/write
/// dispatch happens on the URL's extension; the parser for the markdown
/// form lives in `WorkspaceBlueprintMarkdown.swift`.
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

    /// Walk UP from `cwd` (git-discovery style) and at the first ancestor
    /// that has either `.c11/blueprints/` or `.cmux/blueprints/` collect
    /// blueprints from both. `.c11/` entries appear first in the returned
    /// list so the picker shows the c11-canonical directory above the
    /// legacy one when both exist at the same ancestor.
    func perRepoBlueprintURLs(cwd: URL) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser.standardized
        var candidate = cwd.standardized
        while true {
            let c11Dir = candidate.appendingPathComponent(".c11/blueprints", isDirectory: true)
            let cmuxDir = candidate.appendingPathComponent(".cmux/blueprints", isDirectory: true)
            let c11Exists = fileManager.fileExists(atPath: c11Dir.path)
            let cmuxExists = fileManager.fileExists(atPath: cmuxDir.path)
            if c11Exists || cmuxExists {
                var out: [URL] = []
                if c11Exists { out.append(contentsOf: blueprintURLs(in: c11Dir)) }
                if cmuxExists { out.append(contentsOf: blueprintURLs(in: cmuxDir)) }
                return out
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

    /// Scan `~/.config/c11/blueprints/*.{json,md}` and the legacy
    /// `~/.config/cmux/blueprints/` path. The c11 directory ships first so
    /// the picker prefers canonically-named files when both exist. The
    /// `directoryOverride:` test seam returns just that directory unchanged.
    func perUserBlueprintURLs() -> [URL] {
        if let override = directoryOverride {
            return blueprintURLs(in: override)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let primary = home.appendingPathComponent(".config/c11/blueprints", isDirectory: true)
        let legacy = home.appendingPathComponent(".config/cmux/blueprints", isDirectory: true)
        return blueprintURLs(in: primary) + blueprintURLs(in: legacy)
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

    /// Read and decode a blueprint, dispatching on extension: `.md` files
    /// are parsed by `WorkspaceBlueprintMarkdown`; everything else is read
    /// as JSON.
    func read(url: URL) throws -> WorkspaceBlueprintFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.readFailed(url.path, underlying: "\(error)")
        }
        if url.pathExtension.lowercased() == "md" {
            do {
                return try WorkspaceBlueprintMarkdown.parse(data)
            } catch {
                throw StoreError.decodeFailed(url.path, underlying: "\(error)")
            }
        }
        do {
            return try JSONDecoder().decode(WorkspaceBlueprintFile.self, from: data)
        } catch {
            throw StoreError.decodeFailed(url.path, underlying: "\(error)")
        }
    }

    /// Atomic write. Directory is created on demand. Encoding dispatches on
    /// the destination URL's extension: `.md` files round-trip through
    /// `WorkspaceBlueprintMarkdown`, everything else through `JSONEncoder`.
    /// Follows the same write-temp-then-move contract as
    /// `WorkspaceSnapshotStore`.
    func write(_ file: WorkspaceBlueprintFile, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw StoreError.createDirectoryFailed(parent.path, underlying: "\(error)")
        }
        let data: Data
        if url.pathExtension.lowercased() == "md" {
            do {
                data = try WorkspaceBlueprintMarkdown.serialize(file)
            } catch {
                throw StoreError.encodeFailed("\(error)")
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                data = try encoder.encode(file)
            } catch {
                throw StoreError.encodeFailed("\(error)")
            }
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

    /// Build `WorkspaceBlueprintIndex` entries from a set of URLs. Decodes
    /// each file's envelope (JSON or Markdown frontmatter) to populate
    /// `name` and `description`; falls back to the filename stem when a
    /// markdown file's frontmatter is missing or unparseable. Skips
    /// undecodable JSON files silently. Sorted by modifiedAt desc.
    private func indexEntries(
        urls: [URL],
        source: WorkspaceBlueprintIndex.Source
    ) -> [WorkspaceBlueprintIndex] {
        var out: [WorkspaceBlueprintIndex] = []
        for url in urls {
            // modifiedAt from filesystem attributes; skip if unavailable.
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let modifiedAt = attrs[.modificationDate] as? Date else { continue }
            let ext = url.pathExtension.lowercased()
            let name: String
            let description: String?
            if ext == "md" {
                if let file = try? read(url: url), !file.name.isEmpty {
                    name = file.name
                    description = file.description
                } else {
                    name = url.deletingPathExtension().lastPathComponent
                    description = nil
                }
            } else {
                guard let file = try? read(url: url) else { continue }
                name = file.name
                description = file.description
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
