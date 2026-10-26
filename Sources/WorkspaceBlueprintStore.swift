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

    // CLI/CMUXCLI+Blueprint.swift mirrors these reference rules; keep both in sync.
    static let starterLayoutFiles: [String: String] = [
        "starter:one-column": "basic-terminal", "one-column": "basic-terminal", "single": "basic-terminal",
        "starter:two-columns": "side-by-side", "two-columns": "side-by-side",
        "starter:quad": "quad-terminal", "quad": "quad-terminal",
        "starter:two-by-three": "two-by-three", "two-by-three": "two-by-three",
        "basic-terminal": "basic-terminal", "side-by-side": "side-by-side", "quad-terminal": "quad-terminal",
    ]

    static func normalizedLayoutReference(_ reference: String) -> String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func looksLikeLayoutPath(_ reference: String) -> Bool {
        let name = normalizedLayoutReference(reference)
        return name.contains("/") || name.hasPrefix("~") || name.hasPrefix(".")
            || name.hasSuffix(".json") || name.hasSuffix(".md")
    }

    static func defaultLayoutReference(explicit: String?, stored: String?) -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let stored {
            let name = normalizedLayoutReference(stored)
            if name.hasPrefix("starter:"), starterLayoutFiles[name] != nil { return name }
        }
        return "starter:one-column"
    }

    static let maximumMarkdownBlueprintBytes = 1_048_576
    static let maximumJSONBlueprintBytes = 16 * 1_048_576

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
        case sizeLimitExceeded(String, actual: Int, limit: Int)

        var code: String {
            switch self {
            case .createDirectoryFailed:  return "blueprint_dir_create_failed"
            case .encodeFailed:           return "blueprint_encode_failed"
            case .writeFailed:            return "blueprint_write_failed"
            case .readFailed:             return "blueprint_read_failed"
            case .decodeFailed:           return "blueprint_decode_failed"
            case .sizeLimitExceeded:      return "blueprint_size_limit_exceeded"
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
            case .sizeLimitExceeded(let path, let actual, let limit):
                return "blueprint at \(path) is \(actual) bytes; limit is \(limit) bytes"
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

    /// Starter layouts always come from the app bundle, never a repo or user file.
    func builtInEntry(named name: String) -> WorkspaceBlueprintIndex? {
        indexEntries(urls: builtInBlueprintURLs(), source: .builtIn)
            .first(where: { Self.normalizedLayoutReference($0.name) == Self.normalizedLayoutReference(name) })
    }

    func isReservedLayoutReference(_ reference: String) -> Bool {
        let name = Self.normalizedLayoutReference(reference)
        return name.hasPrefix("starter:") || name.hasPrefix("saved:")
            || Self.starterLayoutFiles[name] != nil || builtInEntry(named: name) != nil
    }

    /// Explicit saved files keep their identity; names prefer user and shipped
    /// blueprints over repo entries, with starter aliases reserved for built-ins.
    func resolveLayoutReference(_ reference: String, cwd: URL?) -> WorkspaceBlueprintIndex? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalizedLayoutReference(trimmed)
        if normalized.hasPrefix("saved:") {
            let url = String(trimmed.dropFirst("saved:".count))
            return merged(cwd: cwd).first(where: { $0.url == url })
        }
        if let name = Self.starterLayoutFiles[normalized] {
            return builtInEntry(named: name)
        }
        if let builtIn = builtInEntry(named: normalized) {
            return builtIn
        }
        if normalized.hasPrefix("starter:") { return nil }
        let matches = merged(cwd: cwd).filter { Self.normalizedLayoutReference($0.name) == normalized }
        return matches.first(where: { $0.source != .repo }) ?? matches.first
    }

    // MARK: - Read / Write

    /// Read and decode a blueprint, dispatching on extension: `.md` files
    /// are parsed by `WorkspaceBlueprintMarkdown`; everything else is read
    /// as JSON.
    func read(url: URL) throws -> WorkspaceBlueprintFile {
        let limit = Self.maximumBytes(for: url)
        let data: Data
        switch MailboxPanelMail.readRegularFilePrefix(
            path: url.path,
            limit: limit,
            followSymlinks: true
        ) {
        case .failure(let failure):
            let detail: String
            switch failure.kind {
            case .missing:
                detail = "file not found"
            case .notRegularFile:
                detail = "not a regular file"
            case .permissionDenied:
                detail = "permission denied"
            case .other:
                detail = failure.description
            }
            if failure.kind == .notRegularFile {
                throw StoreError.decodeFailed(url.path, underlying: detail)
            }
            throw StoreError.readFailed(url.path, underlying: detail)
        case .success(let read):
            guard !read.truncated else {
                throw StoreError.decodeFailed(
                    url.path,
                    underlying: "blueprint exceeds \(limit)-byte limit"
                )
            }
            data = read.data
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
        let limit = Self.maximumBytes(for: url)
        guard data.count <= limit else {
            throw StoreError.sizeLimitExceeded(url.path, actual: data.count, limit: limit)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(url.path, underlying: "\(error)")
        }
    }

    private static func maximumBytes(for url: URL) -> Int {
        url.pathExtension.lowercased() == "md"
            ? maximumMarkdownBlueprintBytes
            : maximumJSONBlueprintBytes
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
