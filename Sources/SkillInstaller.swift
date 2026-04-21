import Foundation
import CryptoKit

// MARK: - Public types

enum SkillInstallerTarget: String, CaseIterable {
    case claude
    case codex
    case kimi
    case opencode

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        case .opencode: return "OpenCode"
        }
    }

    /// Root config dir conventionally used by each TUI (`~/.claude`, `~/.codex`, …).
    func configRoot(home: URL) -> URL {
        home.appendingPathComponent(".\(rawValue)", isDirectory: true)
    }

    /// Destination skills dir (`~/.claude/skills`, `~/.codex/skills`, …).
    func skillsDir(home: URL) -> URL {
        configRoot(home: home).appendingPathComponent("skills", isDirectory: true)
    }

    /// True when the TUI's config root exists — the only signal c11 uses
    /// to infer that a user cares about a given tool.
    func isDetected(home: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: configRoot(home: home).path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}

struct SkillInstallerPackage: Equatable {
    let name: String
    let sourceDir: URL
}

struct SkillInstallerRecord: Codable, Equatable {
    /// Bumped when the on-disk manifest schema changes in a backwards-incompatible way.
    static let schemaVersion = 1

    let schema: Int
    let packageName: String
    let installedAt: String
    let appVersion: String
    let appBuild: String
    let commitShort: String
    let sourceContentHash: String

    enum CodingKeys: String, CodingKey {
        case schema = "c11_skill_schema"
        case packageName = "package"
        case installedAt = "installed_at"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case commitShort = "commit"
        case sourceContentHash = "source_sha256"
    }
}

enum SkillInstallerState: String, Equatable {
    case notInstalled
    case installedCurrent
    case installedOutdated
    case installedNoManifest
    case schemaMismatch
}

struct SkillInstallerPackageStatus: Equatable {
    let package: SkillInstallerPackage
    let target: SkillInstallerTarget
    let destinationDir: URL
    let state: SkillInstallerState
    let record: SkillInstallerRecord?
    let sourceContentHash: String
}

struct SkillInstallerApplyResult: Equatable {
    let target: SkillInstallerTarget
    let installed: [String]
    let refreshed: [String]
    let skipped: [String]
    let destDir: URL
}

struct SkillInstallerRemoveResult: Equatable {
    let target: SkillInstallerTarget
    let removed: [String]
    let skipped: [String]
    let destDir: URL
}

struct SkillInstallerError: Error, CustomStringConvertible {
    enum Code: String {
        case noSourceFound
        case sourceNotReadable
        case targetNotDetected
        case destUnwritable
        case destNotManaged
        case copyFailed
        case manifestMalformed
        case emptyPackageSet
    }
    let code: Code
    let message: String
    let path: String?

    init(code: Code, message: String, path: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
    }

    var description: String { message }
}

// MARK: - SkillInstaller namespace

enum SkillInstaller {
    static let manifestFilename = ".c11-skill.json"

    // MARK: Source discovery

    /// Locate the bundled `skills/` directory. Tries (in order):
    ///   1) adjacent to the executable's `Contents/Resources/skills/` (shipped .app)
    ///   2) walking up from the executable to find `<repo>/skills/` (dev)
    ///   3) `C11_SKILLS_SOURCE` (or `CMUX_SKILLS_SOURCE`) env var as an explicit override
    static func defaultSourceURL(
        executableURL: URL?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = env["C11_SKILLS_SOURCE"] ?? env["CMUX_SKILLS_SOURCE"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                return url.standardizedFileURL
            }
        }

        guard let executableURL else { return nil }
        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                let bundled = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true)
                if fileManager.fileExists(atPath: bundled.path) {
                    return bundled.standardizedFileURL
                }
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoSkills = current.appendingPathComponent("skills", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoSkills.path) {
                return repoSkills.standardizedFileURL
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// Each direct child of `sourceDir` that contains a `SKILL.md` is a skill
    /// candidate. If `sourceDir/MANIFEST.json` declares an `installable` list,
    /// that list filters the candidates (so maintainer-only skills like
    /// `release` are not pushed to user machines). Packages are returned in
    /// stable alphabetical order.
    static func discoverPackages(
        sourceDir: URL,
        fileManager: FileManager = .default
    ) throws -> [SkillInstallerPackage] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw SkillInstallerError(
                code: .noSourceFound,
                message: "Bundled skills directory not found at \(sourceDir.path)."
            )
        }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SkillInstallerError(
                code: .sourceNotReadable,
                message: "Cannot enumerate skills source: \(error.localizedDescription)"
            )
        }

        let allowlist: Set<String>? = try readInstallableAllowlist(sourceDir: sourceDir, fileManager: fileManager)

        let packages: [SkillInstallerPackage] = children.compactMap { url in
            var childIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &childIsDir), childIsDir.boolValue else {
                return nil
            }
            let skillMd = url.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillMd.path) else { return nil }
            let name = url.lastPathComponent
            if let allowlist, !allowlist.contains(name) { return nil }
            return SkillInstallerPackage(name: name, sourceDir: url.standardizedFileURL)
        }
        return packages.sorted { $0.name < $1.name }
    }

    /// Returns the `installable` allowlist from `MANIFEST.json`, or nil if the
    /// manifest file is absent (in which case every direct-child package is
    /// installable). A present-but-malformed manifest throws — failing closed
    /// so a packaging mistake can never silently broaden what c11 ships.
    private static func readInstallableAllowlist(
        sourceDir: URL,
        fileManager: FileManager
    ) throws -> Set<String>? {
        let manifest = sourceDir.appendingPathComponent("MANIFEST.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            throw SkillInstallerError(
                code: .manifestMalformed,
                message: "Cannot read \(manifest.path): \(error.localizedDescription)",
                path: manifest.path
            )
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SkillInstallerError(
                code: .manifestMalformed,
                message: "\(manifest.path) is not valid JSON: \(error.localizedDescription)",
                path: manifest.path
            )
        }
        guard let dict = obj as? [String: Any] else {
            throw SkillInstallerError(
                code: .manifestMalformed,
                message: "\(manifest.path) must be a JSON object.",
                path: manifest.path
            )
        }
        guard let raw = dict["installable"] else {
            // `installable` key missing — treat as "no filtering" to stay
            // forward-compatible with manifests that only carry metadata.
            return nil
        }
        guard let list = raw as? [String] else {
            throw SkillInstallerError(
                code: .manifestMalformed,
                message: "\(manifest.path) 'installable' must be an array of strings.",
                path: manifest.path
            )
        }
        return Set(list)
    }

    // MARK: Hashing

    /// Deterministic SHA-256 over a directory. Each file contributes
    ///   UInt64BE(path_len) || path_bytes || UInt64BE(content_len) || content_bytes
    /// to a running SHA-256. Length-prefixing ensures the hash is unambiguous
    /// for arbitrary file bytes — two different directory shapes cannot
    /// produce colliding byte streams the way NUL-delimited framing could.
    ///
    /// - Parameters:
    ///   - dir: directory to hash.
    ///   - skipInstallerManifest: when true, the on-disk manifest file
    ///     (`.c11-skill.json`) at the top level is excluded from the hash.
    ///     Used on destination dirs so the manifest's presence doesn't
    ///     invalidate a comparison against the source hash. Defaults to false
    ///     so source hashes include every file (including dotfiles) and
    ///     changes to hidden source files perturb the hash as expected.
    static func contentHash(
        of dir: URL,
        skipInstallerManifest: Bool = false,
        fileManager: FileManager = .default
    ) throws -> String {
        let base = dir.standardizedFileURL
        let basePath = base.path
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw SkillInstallerError(
                code: .sourceNotReadable,
                message: "Cannot enumerate directory: \(base.path)"
            )
        }
        var entries: [(rel: String, absolute: URL)] = []
        for case let fileURL as URL in enumerator {
            let resolved = fileURL.standardizedFileURL
            let rel = String(resolved.path.dropFirst(basePath.count).drop(while: { $0 == "/" }))
            if rel.isEmpty { continue }
            if skipInstallerManifest && rel == manifestFilename { continue }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            entries.append((rel, resolved))
        }
        entries.sort { $0.rel < $1.rel }

        var hasher = SHA256()
        for entry in entries {
            let relBytes = Data(entry.rel.utf8)
            hasher.update(data: uint64BigEndian(UInt64(relBytes.count)))
            hasher.update(data: relBytes)
            let fileData = try Data(contentsOf: entry.absolute)
            hasher.update(data: uint64BigEndian(UInt64(fileData.count)))
            hasher.update(data: fileData)
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func uint64BigEndian(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    // MARK: Status

    static func status(
        for target: SkillInstallerTarget,
        home: URL,
        sourceDir: URL,
        fileManager: FileManager = .default
    ) throws -> [SkillInstallerPackageStatus] {
        let packages = try discoverPackages(sourceDir: sourceDir, fileManager: fileManager)
        let destRoot = target.skillsDir(home: home)
        return try packages.map { package in
            let destDir = destRoot.appendingPathComponent(package.name, isDirectory: true)
            let sourceHash = try contentHash(of: package.sourceDir, fileManager: fileManager)
            let manifest = destDir.appendingPathComponent(manifestFilename, isDirectory: false)
            var destExists: ObjCBool = false
            let destPresent = fileManager.fileExists(atPath: destDir.path, isDirectory: &destExists) && destExists.boolValue
            let manifestPresent = fileManager.fileExists(atPath: manifest.path)

            if !destPresent {
                return SkillInstallerPackageStatus(
                    package: package,
                    target: target,
                    destinationDir: destDir,
                    state: .notInstalled,
                    record: nil,
                    sourceContentHash: sourceHash
                )
            }
            if !manifestPresent {
                return SkillInstallerPackageStatus(
                    package: package,
                    target: target,
                    destinationDir: destDir,
                    state: .installedNoManifest,
                    record: nil,
                    sourceContentHash: sourceHash
                )
            }
            let record: SkillInstallerRecord
            do {
                let data = try Data(contentsOf: manifest)
                record = try JSONDecoder().decode(SkillInstallerRecord.self, from: data)
            } catch {
                return SkillInstallerPackageStatus(
                    package: package,
                    target: target,
                    destinationDir: destDir,
                    state: .installedNoManifest,
                    record: nil,
                    sourceContentHash: sourceHash
                )
            }
            if record.schema != SkillInstallerRecord.schemaVersion {
                return SkillInstallerPackageStatus(
                    package: package,
                    target: target,
                    destinationDir: destDir,
                    state: .schemaMismatch,
                    record: record,
                    sourceContentHash: sourceHash
                )
            }
            if record.packageName != package.name {
                // Manifest's package doesn't match the directory it lives in —
                // treat as tampered/unmanaged.
                return SkillInstallerPackageStatus(
                    package: package,
                    target: target,
                    destinationDir: destDir,
                    state: .installedNoManifest,
                    record: record,
                    sourceContentHash: sourceHash
                )
            }
            // Idempotency: `.installedCurrent` iff the manifest says our source
            // hash AND the on-disk destination content (excluding the
            // manifest itself) also hashes to our source hash. If either
            // diverges — manifest lies, or user edited a file — treat as
            // outdated so the next install refreshes.
            let destHash: String
            do {
                destHash = try contentHash(
                    of: destDir,
                    skipInstallerManifest: true,
                    fileManager: fileManager
                )
            } catch {
                return SkillInstallerPackageStatus(
                    package: package,
                    target: target,
                    destinationDir: destDir,
                    state: .installedOutdated,
                    record: record,
                    sourceContentHash: sourceHash
                )
            }
            let matches = (record.sourceContentHash == sourceHash) && (destHash == sourceHash)
            let state: SkillInstallerState = matches ? .installedCurrent : .installedOutdated
            return SkillInstallerPackageStatus(
                package: package,
                target: target,
                destinationDir: destDir,
                state: state,
                record: record,
                sourceContentHash: sourceHash
            )
        }
    }

    // MARK: Install

    struct AppIdentity {
        let version: String
        let build: String
        let commitShort: String

        static var current: AppIdentity {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
            let build = (info["CFBundleVersion"] as? String) ?? "0"
            let commit = (info["CMUXCommit"] as? String) ?? ""
            return AppIdentity(version: version, build: build, commitShort: commit)
        }
    }

    /// Copy every bundled package into `<home>/.<target>/skills/<package>/`, writing
    /// a manifest per package. Idempotent: packages whose source hash matches the
    /// manifest are skipped unless `force` is true.
    static func install(
        target: SkillInstallerTarget,
        home: URL,
        sourceDir: URL,
        force: Bool,
        appIdentity: AppIdentity = .current,
        now: () -> Date = Date.init,
        fileManager: FileManager = .default
    ) throws -> SkillInstallerApplyResult {
        let statuses = try status(for: target, home: home, sourceDir: sourceDir, fileManager: fileManager)
        if statuses.isEmpty {
            throw SkillInstallerError(
                code: .emptyPackageSet,
                message: "No installable skill packages found in \(sourceDir.path). Check the bundled skills/MANIFEST.json.",
                path: sourceDir.path
            )
        }
        let destRoot = target.skillsDir(home: home)
        do {
            try fileManager.createDirectory(at: destRoot, withIntermediateDirectories: true)
        } catch {
            throw SkillInstallerError(
                code: .destUnwritable,
                message: "Cannot create \(destRoot.path): \(error.localizedDescription)",
                path: destRoot.path
            )
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: now())

        var installed: [String] = []
        var refreshed: [String] = []
        var skipped: [String] = []

        for st in statuses {
            let dest = st.destinationDir
            let isUpToDate = (st.state == .installedCurrent)
            if isUpToDate && !force {
                skipped.append(st.package.name)
                continue
            }

            // Safety: a destination directory without a valid c11 manifest
            // is presumed user-owned — refuse to clobber it unless the
            // operator explicitly passes --force. `.schemaMismatch` means an
            // older manifest version that we can't safely migrate; treat the
            // same way. This is the symmetry referenced by `remove()`: if a
            // directory is unsafe to uninstall, it is unsafe to replace.
            if (st.state == .installedNoManifest || st.state == .schemaMismatch) && !force {
                throw SkillInstallerError(
                    code: .destNotManaged,
                    message: "\(dest.path) already exists but is not a c11-managed skill. Re-run with --force to replace it.",
                    path: dest.path
                )
            }

            // Remove any prior copy to avoid leaving orphaned files behind.
            if fileManager.fileExists(atPath: dest.path) {
                do {
                    try fileManager.removeItem(at: dest)
                } catch {
                    throw SkillInstallerError(
                        code: .copyFailed,
                        message: "Cannot remove existing \(dest.path): \(error.localizedDescription)",
                        path: dest.path
                    )
                }
            }
            do {
                try fileManager.copyItem(at: st.package.sourceDir, to: dest)
            } catch {
                throw SkillInstallerError(
                    code: .copyFailed,
                    message: "Cannot copy \(st.package.name) to \(dest.path): \(error.localizedDescription)",
                    path: dest.path
                )
            }

            let record = SkillInstallerRecord(
                schema: SkillInstallerRecord.schemaVersion,
                packageName: st.package.name,
                installedAt: timestamp,
                appVersion: appIdentity.version,
                appBuild: appIdentity.build,
                commitShort: appIdentity.commitShort,
                sourceContentHash: st.sourceContentHash
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: dest.appendingPathComponent(manifestFilename, isDirectory: false), options: .atomic)

            switch st.state {
            case .notInstalled:
                installed.append(st.package.name)
            case .installedCurrent, .installedOutdated, .installedNoManifest, .schemaMismatch:
                refreshed.append(st.package.name)
            }
        }

        return SkillInstallerApplyResult(
            target: target,
            installed: installed,
            refreshed: refreshed,
            skipped: skipped,
            destDir: destRoot
        )
    }

    // MARK: Remove

    /// Remove c11-installed skill packages from a target. Only removes a
    /// package dir if its `.c11-skill.json` manifest is present — protects
    /// directories the user created themselves.
    static func remove(
        target: SkillInstallerTarget,
        home: URL,
        sourceDir: URL,
        fileManager: FileManager = .default
    ) throws -> SkillInstallerRemoveResult {
        let packages = try discoverPackages(sourceDir: sourceDir, fileManager: fileManager)
        let destRoot = target.skillsDir(home: home)
        var removed: [String] = []
        var skipped: [String] = []

        for pkg in packages {
            let dest = destRoot.appendingPathComponent(pkg.name, isDirectory: true)
            let manifest = dest.appendingPathComponent(manifestFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: dest.path) else {
                skipped.append(pkg.name)
                continue
            }
            guard fileManager.fileExists(atPath: manifest.path) else {
                // User-owned; don't touch.
                skipped.append(pkg.name)
                continue
            }
            // Decode and verify the manifest before deleting: a file named
            // `.c11-skill.json` alone is not proof of c11 ownership.
            // Require current schema and a matching package name, or skip.
            let record: SkillInstallerRecord
            do {
                let data = try Data(contentsOf: manifest)
                record = try JSONDecoder().decode(SkillInstallerRecord.self, from: data)
            } catch {
                skipped.append(pkg.name)
                continue
            }
            guard record.schema == SkillInstallerRecord.schemaVersion,
                  record.packageName == pkg.name else {
                skipped.append(pkg.name)
                continue
            }
            do {
                try fileManager.removeItem(at: dest)
            } catch {
                throw SkillInstallerError(
                    code: .copyFailed,
                    message: "Cannot remove \(dest.path): \(error.localizedDescription)",
                    path: dest.path
                )
            }
            removed.append(pkg.name)
        }
        return SkillInstallerRemoveResult(
            target: target,
            removed: removed,
            skipped: skipped,
            destDir: destRoot
        )
    }
}
