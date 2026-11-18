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
    private static let service = C11Identity.keychainService
    private static let account = "local-socket-password"
    // c11 reads only its own password file. c11 and c11mux directories are
    // another product's state and are not a fallback.
    private static let directoryName = C11Identity.passwordDirectoryName
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
        let passwordURL = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: passwordURL),
              let value = String(data: data, encoding: .utf8),
              let normalizedValue = normalized(value) else {
            return nil
        }
        return normalizedValue
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
        if let tag = normalized(environment["C11_TAG"] ?? environment["CMUX_TAG"]) {
            let scoped = sanitizeScope(tag)
            if !scoped.isEmpty {
                return scoped
            }
        }

        let candidate = URL(fileURLWithPath: socketPath).lastPathComponent
        let prefixes = ["c11-debug-", "c11-"]
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
        #if !(canImport(Security) && canImport(LocalAuthentication))
        return nil
        #else
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
        #endif
    }
}

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
    /// A socket variable names a path that is not c11's (C11H-282). The path
    /// is kept, never swapped for discovery, and `SocketClient` refuses it.
    case refusedEnvironment
}

/// The socket variables, read in precedence order (C11H-282). The first one
/// naming c11's own socket is used. One naming another product's socket (the
/// c11h line's, cmux's) is skipped: its terminals export it, and terminals c11
/// adopted from c11h still carry it. The first naming any other path is
/// refused when the CLI would connect, with a message naming the variable, the
/// path and the rule, so a script never drives a different c11 without a word.
enum CLISocketEnvironmentOverride: Equatable {
    static let keys = ["C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET"]

    case none
    case own(key: String, path: String)
    case foreign(key: String, path: String)

    /// The environment before `mirrorC11CmuxEnv` copied each `CMUX_` variable
    /// to its `C11_` twin. Only the refusal's wording reads it.
    static var launchEnvironment: [String: String]?

    static func read(_ environment: [String: String]) -> CLISocketEnvironmentOverride {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            switch C11Identity.socketOverrideKind(raw) {
            case .own: return .own(key: key, path: raw)
            case .otherProduct: continue
            case .foreign: return .foreign(key: namedKey(key, path: raw), path: raw)
            }
        }
        return .none
    }

    /// A 1.x script sets `CMUX_SOCKET_PATH`; the mirror puts the same path in
    /// `C11_SOCKET_PATH`, which wins. Name the variable the caller set.
    private static func namedKey(_ key: String, path: String) -> String {
        guard let launch = launchEnvironment else { return key }
        let setAtLaunch = { (name: String) in
            launch[name]?.trimmingCharacters(in: .whitespacesAndNewlines) == path
        }
        if setAtLaunch(key) { return key }
        return keys.first(where: setAtLaunch) ?? key
    }

    var ownPath: String? {
        if case .own(_, let path) = self { return path }
        return nil
    }

    var refusalMessage: String? {
        guard case .foreign(let key, let path) = self else { return nil }
        return Self.refusalMessage(key: key, path: path)
    }

    static func refusalMessage(key: String, path: String) -> String {
        String(
            localized: "cli.socket.overrideRefused",
            defaultValue: "\(key)=\(path) is not a c11 socket, so c11 will not use it. A c11 socket is in ~/Library/Application Support/c11/, or in /tmp named c11.sock, c11-*.sock or c11.*.sock. Rename the socket, or pass --socket \(path) to use this path."
        )
    }
}

enum CLISocketPathResolver {
    // Matches C11Identity: Application Support/c11/c11.sock, with
    // /tmp/c11.sock only when Application Support cannot be resolved.
    // c11 and cmux sockets are never candidates.
    private static let lastSocketPathFileName = "last-socket-path"
    static let legacyDefaultSocketPath = C11Identity.tmpStableSocketPath

    static var defaultSocketPath: String {
        if let directory = stableSocketDirectoryURL() {
            return directory
                .appendingPathComponent(C11Identity.stableSocketFileName, isDirectory: false)
                .path
        }
        return C11Identity.tmpStableSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        path == defaultSocketPath || path == C11Identity.tmpStableSocketPath
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if source == .explicitFlag || source == .refusedEnvironment {
            return requestedPath
        }
        if source == .environment, C11Identity.isOwnSocketPath(requestedPath) {
            return requestedPath
        }
        let listings = socketListings()
        let breadcrumbs = breadcrumbFiles()
        let unprobed = C11Identity.ImplicitSocketDiscovery(
            environment: environment,
            defaultPath: defaultSocketPath,
            socketListings: listings,
            breadcrumbFiles: breadcrumbs
        )
        let candidates = C11Identity.implicitSocketCandidates(unprobed)
        var connectable: Set<String> = []
        var existing: Set<String> = []
        for path in candidates {
            if canConnect(to: path) {
                connectable.insert(path)
            } else if isSocketFile(path) {
                existing.insert(path)
            }
        }
        return C11Identity.resolveImplicitSocket(C11Identity.ImplicitSocketDiscovery(
            environment: environment,
            defaultPath: defaultSocketPath,
            socketListings: listings,
            breadcrumbFiles: breadcrumbs,
            connectable: connectable,
            existingSocketFiles: existing
        ))
    }

    static func discoverySourceHint(resolvedPath: String, environment: [String: String]) -> String? {
        if let last = readLastSocketPathWithSource(), last.value == resolvedPath {
            return last.source
        }
        for key in ["C11_TAG", "CMUX_TAG"] {
            guard let tag = normalized(environment[key]) else { continue }
            let slug = C11Identity.sanitizeTagSlug(tag)
            if resolvedPath == C11Identity.taggedDebugSocketPath(slug: slug)
                || resolvedPath == C11Identity.userSocketPath(stem: "c11-\(slug)")
                || resolvedPath == C11Identity.legacyTaggedDebugSocketPath(slug: slug)
                || resolvedPath == "/tmp/c11-\(slug).sock" {
                return "\(key)=\(tag)"
            }
        }
        return nil
    }

    private static func readLastSocketPathWithSource() -> (value: String, source: String)? {
        var candidates = [C11Identity.userLastSocketPathFile, C11Identity.lastSocketPathFile]
        if let directory = stableSocketDirectoryURL() {
            candidates.insert(
                directory.appendingPathComponent(lastSocketPathFileName, isDirectory: false).path,
                at: 0
            )
        }
        for candidate in candidates where C11Identity.isC11BreadcrumbFile(candidate) {
            guard let data = C11UserRuntime.readBreadcrumb(at: candidate),
                  let value = normalized(data),
                  C11Identity.isOwnSocketPath(value) else {
                continue
            }
            return (value: value, source: candidate)
        }
        return nil
    }

    private static func socketListings() -> [String: [String]] {
        var listings: [String: [String]] = [:]
        for directory in [C11UserRuntime.directoryPath(), "/tmp", "/private/tmp"] {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                listings[directory] = names
            }
        }
        if let directory = stableSocketDirectoryURL()?.path,
           let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
            listings[directory] = names
        }
        return listings
    }

    private static func breadcrumbFiles() -> [String: String] {
        var files: [String: String] = [:]
        var paths = [C11Identity.userLastSocketPathFile, C11Identity.lastSocketPathFile]
        if let directory = stableSocketDirectoryURL() {
            paths.append(directory.appendingPathComponent(lastSocketPathFileName, isDirectory: false).path)
        }
        // A breadcrumb is read only when it is our own regular file (C11H-364).
        for path in paths where C11Identity.isC11BreadcrumbFile(path) {
            if let data = C11UserRuntime.readBreadcrumb(at: path) {
                files[path] = data
            }
        }
        return files
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
        // A listener another account runs is never a discovery candidate (C11H-364).
        return result == 0 && C11UserRuntime.peerIsUser(fd, expected: SocketClient.expectedPeerUserID)
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
        return appSupportDirectory.appendingPathComponent(C11Identity.socketDirectoryName, isDirectory: true)
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
