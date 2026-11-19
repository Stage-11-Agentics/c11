import CryptoKit
import Foundation

/// C11H-392: the files a Linux machine needs from c11, its hc and the relay
/// CLI, which c11.app does not carry. Each is named in the app's own
/// `Contents/Resources/remote-artifacts.json` by its SHA-256 (the release step,
/// `scripts/c11-remote-artifacts.sh stamp`, writes it before the app is
/// signed, so the signature seals it) and comes from one of three sources,
/// each checked against that hash before it is used: c11's own cache
/// (`~/Library/Application Support/c11/remote-artifacts/<sha256>/<name>`,
/// hashed again on every use), a folder the operator names (QA, or a machine
/// with no network), or the release asset the manifest names. A file already
/// on the far machine is never a source for them: Add Machine resolves both
/// here before it writes anything there, keeps a far hc that already hashes to
/// the pin (as for a Mac), sends the CLI every time, and the far `install`
/// checks the hash again.
struct HCRemoteArtifact: Equatable, Sendable {
    /// `linux-x86_64`.
    let platform: String
    /// `herdr-core` or `c11`.
    let name: String
    let version: String
    let sha256: String
    /// The release asset's file name.
    let asset: String
    let url: String
}

enum HCRemoteArtifactError: Error, Equatable, Sendable {
    /// This build carries no manifest for the platform (a dev build that was not stamped).
    case noManifest(platform: String)
    case notInManifest(platform: String, name: String)
    /// The operator named a folder and none of its files is this artifact:
    /// c11 does not go to the network instead.
    case notInFolder(name: String, folder: String)
    case downloadFailed(name: String, reason: String)
    case hashMismatch(name: String, found: String, expected: String)
    case cacheFailed(name: String, reason: String)

    var code: String {
        switch self {
        case .noManifest: return "remote_artifacts_missing"
        case .notInManifest: return "remote_artifacts_missing"
        case .notInFolder: return "remote_artifact_not_in_folder"
        case .downloadFailed: return "remote_artifact_download_failed"
        case .hashMismatch: return "remote_artifact_hash_mismatch"
        case .cacheFailed: return "remote_artifact_cache_failed"
        }
    }
}

struct HCRemoteArtifactManifest: Equatable, Sendable {
    static let resourceName = "remote-artifacts.json"
    static let platforms: Set<String> = ["linux-x86_64"]
    static let names: Set<String> = ["herdr-core", "c11"]

    let artifacts: [HCRemoteArtifact]

    static func url(bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(resourceName)
    }

    static func load(bundle: URL) -> HCRemoteArtifactManifest? {
        guard let data = try? Data(contentsOf: url(bundle: bundle)) else { return nil }
        return parse(data)
    }

    /// The format version, a JSON integer: `true` or `1.5` is not 1.
    private struct Version: Decodable { let version: Int }

    /// The whole file or nothing: one malformed entry refuses the manifest.
    static func parse(_ data: Data) -> HCRemoteArtifactManifest? {
        guard (try? JSONDecoder().decode(Version.self, from: data))?.version == 1,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["artifacts"] as? [[String: Any]] else { return nil }
        var artifacts: [HCRemoteArtifact] = []
        for entry in entries {
            guard let platform = entry["platform"] as? String, platforms.contains(platform),
                  let name = entry["name"] as? String, names.contains(name),
                  let version = entry["version"] as? String, version.range(of: #"^[0-9A-Za-z._-]{1,64}$"#, options: .regularExpression) != nil,
                  let sha = entry["sha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let asset = entry["asset"] as? String, asset.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
                  let url = entry["url"] as? String, let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
                  !artifacts.contains(where: { $0.platform == platform && $0.name == name }) else { return nil }
            artifacts.append(HCRemoteArtifact(platform: platform, name: name, version: version, sha256: sha, asset: asset, url: url))
        }
        return artifacts.isEmpty ? nil : HCRemoteArtifactManifest(artifacts: artifacts)
    }

    func artifact(platform: String, name: String) -> HCRemoteArtifact? {
        artifacts.first { $0.platform == platform && $0.name == name }
    }

    /// C11H-397: this app's own Linux hc pin, from its signed manifest, read
    /// once on first use; nil for a build that names no Linux files.
    static let bundledLinuxHCPin: String? = load(bundle: Bundle.main.bundleURL)?
        .artifact(platform: "linux-x86_64", name: "herdr-core")?.sha256
}

/// Finds, checks and caches the artifacts. Synchronous; callers keep it off the main thread.
struct HCRemoteArtifactStore: Sendable {
    /// Why a fetch made no file.
    struct FetchFailure: Error, Equatable, Sendable { let reason: String }
    /// Downloads `url` to a temporary file and returns it, or why not.
    typealias Fetch = @Sendable (_ url: URL, _ timeout: TimeInterval) -> Result<URL, FetchFailure>

    static let overrideVariable = "C11_REMOTE_ARTIFACTS_URL"
    /// No artifact is larger; a bigger file in an import folder is not read.
    static let maximumBytes = 256 << 20

    let cacheRoot: URL
    let fetch: Fetch
    /// QA (`C11_REMOTE_ARTIFACTS_URL`): another base the assets are fetched
    /// from by name, http or https. Safe because the hash, not the place, is
    /// what is trusted.
    let overrideBase: URL?

    init(cacheRoot: URL, fetch: @escaping Fetch = HCRemoteArtifactStore.download,
         overrideBase: URL? = HCRemoteArtifactStore.overrideBase(ProcessInfo.processInfo.environment)) {
        self.cacheRoot = cacheRoot
        self.fetch = fetch
        self.overrideBase = overrideBase
    }

    static func cacheRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(C11Identity.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("remote-artifacts", isDirectory: true)
    }

    static func overrideBase(_ environment: [String: String]) -> URL? {
        guard let raw = environment[overrideVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        return url
    }

    func cachedURL(_ artifact: HCRemoteArtifact) -> URL {
        cacheRoot.appendingPathComponent(artifact.sha256, isDirectory: true).appendingPathComponent(artifact.name)
    }

    func sourceURL(_ artifact: HCRemoteArtifact) -> URL? {
        if let overrideBase { return overrideBase.appendingPathComponent(artifact.asset) }
        return URL(string: artifact.url)
    }

    /// The cached file, after the import folder or a download put it there
    /// when it was missing or did not hash to the pin.
    func resolve(_ artifact: HCRemoteArtifact, importDirectory: URL? = nil) -> Result<URL, HCRemoteArtifactError> {
        let cached = cachedURL(artifact)
        if let bytes = Self.regularFile(cached), Self.sha256(bytes) == artifact.sha256 { return .success(cached) }
        if FileManager.default.fileExists(atPath: cached.path) || Self.isSymlink(cached) {
            // Partial, tampered or not a plain file: never used, replaced.
            try? FileManager.default.removeItem(at: cached)
        }
        if let importDirectory {
            // A folder the operator named is the only source: no match is a
            // named refusal, never a quiet download instead.
            guard let bytes = Self.matching(artifact.sha256, in: importDirectory) else {
                return .failure(.notInFolder(name: artifact.name, folder: importDirectory.path))
            }
            return store(bytes, for: artifact)
        }
        guard let source = sourceURL(artifact) else {
            return .failure(.downloadFailed(name: artifact.name, reason: "no source"))
        }
        switch fetch(source, Self.downloadTimeout) {
        case .failure(let failure):
            return .failure(.downloadFailed(name: artifact.name, reason: failure.reason))
        case .success(let file):
            defer { try? FileManager.default.removeItem(at: file) }
            guard let bytes = Self.regularFile(file) else {
                return .failure(.downloadFailed(name: artifact.name, reason: "the download left no file"))
            }
            let found = Self.sha256(bytes)
            guard found == artifact.sha256 else {
                return .failure(.hashMismatch(name: artifact.name, found: found, expected: artifact.sha256))
            }
            return store(bytes, for: artifact)
        }
    }

    /// Writes bytes already checked against the pin, then reads them back.
    private func store(_ bytes: Data, for artifact: HCRemoteArtifact) -> Result<URL, HCRemoteArtifactError> {
        let cached = cachedURL(artifact)
        let folder = cached.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            for directory in [cacheRoot, folder] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let partial = folder.appendingPathComponent(".\(artifact.name).\(UUID().uuidString)")
            try bytes.write(to: partial, options: [.withoutOverwriting])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            // One rename(2) replaces the target atomically, so a concurrent
            // resolve of the same artifact never finds it missing or in the way.
            if rename(partial.path, cached.path) != 0 {
                let reason = String(cString: strerror(errno))
                try? manager.removeItem(at: partial)
                return .failure(.cacheFailed(name: artifact.name, reason: reason))
            }
        } catch {
            return .failure(.cacheFailed(name: artifact.name, reason: error.localizedDescription))
        }
        guard let back = Self.regularFile(cached), Self.sha256(back) == artifact.sha256 else {
            return .failure(.cacheFailed(name: artifact.name, reason: "the cached copy did not read back"))
        }
        return .success(cached)
    }

    /// The first regular file directly in `directory` whose bytes hash to
    /// `sha256`. The folder itself may be a symlink (an operator naming a
    /// linked `~/Downloads` is ordinary); a member that is a symlink, or
    /// anything but a regular file, is skipped. The hash is the trust.
    static func matching(_ sha256: String, in directory: URL) -> Data? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names.sorted() {
            if let bytes = regularFile(directory.appendingPathComponent(name)), Self.sha256(bytes) == sha256 { return bytes }
        }
        return nil
    }

    /// A regular file's bytes, read without following a symlink; nil for
    /// anything else or anything over `maximumBytes`.
    static func regularFile(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximumBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return data
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The longest one download may run: the CLI is about 65 MiB, so this
    /// allows a slow line. A transfer that stalls for `downloadIdleTimeout`
    /// ends sooner.
    static let downloadTimeout: TimeInterval = 1800
    static let downloadIdleTimeout: TimeInterval = 60

    /// A redirect is followed only to https. The manifest's URLs are https and
    /// only the QA base may start a download over http; no redirect leads to
    /// http, `file:` or any other scheme, whatever the first URL was.
    static func followsRedirect(to url: URL?) -> Bool { url?.scheme?.lowercased() == "https" }

    /// The default fetch: one ephemeral download, nothing stored but the file.
    static let download: Fetch = downloader()

    /// Where a download is when a test's hook runs: its handler just called,
    /// or already keeping the file it was given.
    enum DownloadPhase: Sendable { case completed, keeping }

    /// The downloader. A test stands in for the network (`protocolClasses`),
    /// names the folder kept files go to, shortens how long the caller waits
    /// for a handler (`waitBudget`, from the download's `timeout`), and holds a
    /// handler at a phase (`hook`).
    static func downloader(protocolClasses: [AnyClass] = [],
                           temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                           waitBudget: @escaping @Sendable (TimeInterval) -> TimeInterval = { $0 + 5 },
                           hook: (@Sendable (DownloadPhase) -> Void)? = nil) -> Fetch {
        #if os(macOS)
        let stand = ProtocolClasses(protocolClasses)
        return { url, timeout in
            let configuration = sessionConfiguration(timeout: timeout)
            if !stand.classes.isEmpty { configuration.protocolClasses = stand.classes + (configuration.protocolClasses ?? []) }
            let redirects = RedirectPolicy()
            let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let box = DownloadBox()
            let done = DispatchSemaphore(value: 0)
            let task = session.downloadTask(with: url) { file, response, error in
                defer { done.signal() }
                hook?(.completed)
                box.finish {
                    if let refused = redirects.refused { return .failure(FetchFailure(reason: "a redirect to \(refused) was refused")) }
                    if let error { return .failure(FetchFailure(reason: error.localizedDescription)) }
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        return .failure(FetchFailure(reason: "HTTP \(http.statusCode)"))
                    }
                    guard let file else { return .failure(FetchFailure(reason: "no file")) }
                    hook?(.keeping)
                    // The task's file is removed when this handler returns: move it first.
                    let kept = temporaryDirectory.appendingPathComponent("c11-artifact-\(UUID().uuidString)")
                    do { try FileManager.default.moveItem(at: file, to: kept); return .success(kept) }
                    catch { return .failure(FetchFailure(reason: error.localizedDescription)) }
                }
            }
            task.resume()
            guard done.wait(timeout: .now() + waitBudget(timeout)) == .success else {
                // Abandoned: a handler that runs later keeps nothing, and a
                // file it already kept is removed here.
                box.abandon()
                task.cancel()
                return .failure(FetchFailure(reason: "timed out"))
            }
            return box.result ?? .failure(FetchFailure(reason: "timed out"))
        }
        #else
        return { _, _ in .failure(FetchFailure(reason: "downloads are made by c11 on a Mac")) }
        #endif
    }

    #if os(macOS)
    /// One download's session: `timeout` caps the whole transfer, and one that
    /// receives nothing for `downloadIdleTimeout` ends sooner.
    static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(timeout, downloadIdleTimeout)
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    private final class ProtocolClasses: @unchecked Sendable {
        let classes: [AnyClass]
        init(_ classes: [AnyClass]) { self.classes = classes }
    }

    /// One download's outcome, written once by its handler unless abandoned.
    private final class DownloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<URL, FetchFailure>?
        private var abandoned = false

        var result: Result<URL, FetchFailure>? { lock.lock(); defer { lock.unlock() }; return outcome }

        func finish(_ make: () -> Result<URL, FetchFailure>) {
            lock.lock(); defer { lock.unlock() }
            guard !abandoned else { return }
            outcome = make()
        }

        func abandon() {
            lock.lock(); defer { lock.unlock() }
            abandoned = true
            if case .success(let kept)? = outcome { try? FileManager.default.removeItem(at: kept) }
            outcome = nil
        }
    }

    /// Follows a redirect only where `followsRedirect` allows, and remembers
    /// the scheme it refused so the failure names it.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var refusedScheme: String?

        var refused: String? { lock.lock(); defer { lock.unlock() }; return refusedScheme }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if HCRemoteArtifactStore.followsRedirect(to: request.url) { completionHandler(request); return }
            lock.lock(); refusedScheme = request.url?.scheme ?? "a URL with no scheme"; lock.unlock()
            completionHandler(nil)
        }
    }
    #endif
}
