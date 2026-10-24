// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

enum SocketPasswordResolver {
    private static let service = "com.cmuxterm.app.socket-control"
    private static let account = "local-socket-password"
    // Must match the app's SocketControlPasswordStore.directoryName ("c11") so
    // the CLI reads the password file the app actually writes. The legacy name
    // was "c11mux"; the app moved to "c11" (StateDirectoryMigration.currentName)
    // and the app's symlink covers migrated machines, but a fresh install never
    // creates a `c11mux` dir — reading it there returned nil and the password
    // was silently invisible to the CLI. `legacyDirectoryName` stays as a
    // read-only fallback for any un-migrated checkout.
    private static let directoryName = "c11"
    private static let legacyDirectoryName = "c11mux"
    private static let fileName = "socket-control-password"

    static func resolve(explicit: String?, socketPath: String) -> String? {
        if let explicit = normalized(explicit) {
            return explicit
        }
        if let env = normalized(ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"]) {
            return env
        }
        if let filePassword = loadFromFile() {
            return filePassword
        }
        return loadFromKeychain(socketPath: socketPath)
    }

    /// Resolve credentials without allowing a keychain or filesystem stall to
    /// consume a synchronous Claude hook's aggregate deadline.
    static func resolve(explicit: String?, socketPath: String, deadline: Date?) -> String? {
        guard let deadline else {
            return resolve(explicit: explicit, socketPath: socketPath)
        }
        let read = PasswordRead()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            read.set(resolve(explicit: explicit, socketPath: socketPath))
            done.signal()
        }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        guard remaining > 0.01, done.wait(timeout: .now() + remaining) == .success else {
            return nil
        }
        return read.get()
    }

    private final class PasswordRead: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromFile() -> String? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        // Canonical "c11" dir first; fall back to the legacy "c11mux" dir for
        // un-migrated checkouts where the app's migration symlink is absent.
        for dir in [directoryName, legacyDirectoryName] {
            let passwordURL = appSupport
                .appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false)
            guard let data = try? Data(contentsOf: passwordURL),
                  let value = String(data: data, encoding: .utf8),
                  let normalizedValue = normalized(value) else {
                continue
            }
            return normalizedValue
        }
        return nil
    }

    static func keychainServices(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let scope = keychainScope(socketPath: socketPath, environment: environment) else {
            return [service]
        }
        return ["\(service).\(scope)", service]
    }

    private static func keychainScope(
        socketPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let tag = normalized(environment["CMUX_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["cmux-debug-", "cmux-"]
        for prefix in prefixes {
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".sock") else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: prefix.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -".sock".count)
            guard start < end else { continue }
            let rawScope = String(candidate[start..<end])
            let scoped = sanitizeScope(rawScope)
            if !scoped.isEmpty {
                return scoped
            }
        }
        return nil
    }

    private static func sanitizeScope(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mappedScalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "."
        }
        var normalizedScope = String(mappedScalars)
        normalizedScope = normalizedScope.replacingOccurrences(
            of: "\\.+",
            with: ".",
            options: .regularExpression
        )
        normalizedScope = normalizedScope.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedScope
    }

    private static func loadFromKeychain(socketPath: String) -> String? {
        for service in keychainServices(socketPath: socketPath) {
            let authContext = LAContext()
            authContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Never trigger keychain UI from CLI commands; fail fast instead.
                kSecUseAuthenticationContext as String: authContext,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                continue
            }
            guard status == errSecSuccess else {
                continue
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                continue
            }
            return password
        }
        return nil
    }
}

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

enum CLISocketPathResolver {
    // Must match the app's SocketControlSettings (socketDirectoryName "c11",
    // stableSocketFileName "c11.sock") so the CLI's implicit default and the
    // last-socket-path breadcrumb read the same location the app writes.
    private static let appSupportDirectoryName = "c11"
    private static let stableSocketFileName = "c11.sock"
    private static let lastSocketPathFileName = "last-socket-path"
    // The running app writes its breadcrumb to /tmp/c11-last-socket-path (see
    // SocketControlSettings.legacyLastSocketPathFile). The CLI must read the same
    // path; the older /tmp/cmux-last-socket-path is kept only for back-compat.
    private static let c11LastSocketPathFile = "/tmp/c11-last-socket-path"
    static let legacyDefaultSocketPath = "/tmp/cmux.sock"
    private static let fallbackSocketPath = "/tmp/cmux-debug.sock"
    private static let stagingSocketPath = "/tmp/cmux-staging.sock"
    private static let legacyLastSocketPathFile = "/tmp/cmux-last-socket-path"

    static var defaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        path == defaultSocketPath || path == legacyDefaultSocketPath
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(requestedPath: requestedPath, environment: environment))

        // Prefer sockets that are currently accepting connections.
        for path in candidates where canConnect(to: path) {
            return path
        }

        // If the listener is still starting, prefer existing socket files.
        for path in candidates where isSocketFile(path) {
            return path
        }

        return requestedPath
    }

    private static func candidatePaths(requestedPath: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []

        if let tag = normalized(environment["CMUX_TAG"]) {
            let slug = sanitizeTagSlug(tag)
            candidates.append("/tmp/cmux-debug-\(slug).sock")
            candidates.append("/tmp/cmux-\(slug).sock")
        }

        candidates.append(requestedPath)
        candidates.append(defaultSocketPath)
        candidates.append(legacyDefaultSocketPath)
        candidates.append(fallbackSocketPath)
        candidates.append(stagingSocketPath)
        candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        if let last = readLastSocketPath() {
            candidates.append(last)
        }
        return candidates
    }

    private static func readLastSocketPath() -> String? {
        return readLastSocketPathWithSource()?.value
    }

    private static func readLastSocketPathWithSource() -> (value: String, source: String)? {
        let primaryCandidate: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
            .path
        let candidates = [primaryCandidate, c11LastSocketPathFile, legacyLastSocketPathFile].compactMap { $0 }

        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data) {
                return (value: value, source: candidate)
            }
        }
        return nil
    }

    /// Best-effort attribution for an auto-discovered socket path.
    ///
    /// Returns a human-readable hint identifying *where* `resolvedPath` came
    /// from — the pointer file path when the resolver matched the
    /// `last-socket-path` breadcrumb, or a short `CMUX_TAG=...` tag when the
    /// path matches a tag-derived candidate. Returns `nil` when the source is
    /// unclear (default fallback, /tmp scan, etc.) so callers can fall back
    /// to a generic "(auto-discovered)" message.
    static func discoverySourceHint(resolvedPath: String, environment: [String: String]) -> String? {
        if let last = readLastSocketPathWithSource(), last.value == resolvedPath {
            return last.source
        }
        if let tag = normalized(environment["CMUX_TAG"]) {
            let slug = sanitizeTagSlug(tag)
            if resolvedPath == "/tmp/cmux-debug-\(slug).sock"
                || resolvedPath == "/tmp/cmux-\(slug).sock" {
                return "CMUX_TAG=\(tag)"
            }
        }
        return nil
    }

    private static func discoverTaggedSockets(limit: Int) -> [String] {
        var discovered: [(path: String, mtime: TimeInterval)] = []
        for directory in socketDiscoveryDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            discovered.reserveCapacity(min(limit, discovered.count + entries.count))
            for name in entries where (name.hasPrefix("cmux") || name.hasPrefix("c11")) && name.hasSuffix(".sock") {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if path == defaultSocketPath || path == legacyDefaultSocketPath || path == fallbackSocketPath || path == stagingSocketPath {
                    continue
                }
                let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
                discovered.append((path: path, mtime: modified))
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return dedupe(discovered.prefix(limit).map(\.path))
    }

    private static func isSocketFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private static func canConnect(to path: String) -> Bool {
        guard isSocketFile(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : slug
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableSocketDirectoryURL() -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    private static func socketDiscoveryDirectories() -> [String] {
        let appSupportSocketDirectory: String = stableSocketDirectoryURL()?.path ?? ""
        return dedupe([
            "/tmp",
            appSupportSocketDirectory,
        ])
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }
}

// Policy a sendV2 caller declares for how long the CLI will wait for the server response.
// Long-running operations (browser.wait, browser.download.wait, pane.confirm) use .none so
// their server-side timeouts control the wall-clock bound without a competing CLI deadline.
enum SocketDeadline {
    case `default`            // C11_DEFAULT_SOCKET_DEADLINE_MS / CMUX_ fallback / 10 s hard default
    case none                 // No CLI-side deadline; server timeout governs
    case custom(TimeInterval) // Explicit seconds (reserved for future use)
}
