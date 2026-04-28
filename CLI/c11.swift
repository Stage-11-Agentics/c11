import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

struct CLIError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

/// Returns true when a `CLIError` represents "c11 app isn't reachable on its
/// control socket" — used by advisory pathways (like the claude-hook dispatch)
/// that should no-op rather than surface an error when nothing is listening.
///
/// c11 is single-user: the claude-hook writer treats "another uid owns the
/// socket", "an orphaned socket file exists but no listener accepts", and
/// "permission denied on the socket directory" all as "no live c11 app on
/// this machine for me" — advisory, not failure. If multi-user support ever
/// lands, revisit and split `failed` from advisory.
///
/// The string-based predicate lives in `Sources/CLIAdvisoryConnectivity.swift`
/// so it can be unit-tested in the app test target without dragging `CLIError`
/// (CLI-local) into the c11 module.
func isAdvisoryHookConnectivityError(_ error: CLIError) -> Bool {
    CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(message: error.message)
}

// Mirrors CMUX_* ↔ C11_* env vars so callers can use either prefix.
// Why: binary rename from `cmux` to `c11` keeps both namespaces live during transition.
func mirrorC11CmuxEnv() {
    let env = ProcessInfo.processInfo.environment
    for (key, value) in env {
        if key.hasPrefix("CMUX_") {
            let mirror = "C11_" + String(key.dropFirst(5))
            if env[mirror] == nil { setenv(mirror, value, 1) }
        } else if key.hasPrefix("C11_") {
            let mirror = "CMUX_" + String(key.dropFirst(4))
            if env[mirror] == nil { setenv(mirror, value, 1) }
        }
    }
}

private final class CLISocketSentryTelemetry {
    private let command: String
    private let subcommand: String
    private let socketPath: String
    private let envSocketPath: String?
    private let workspaceId: String?
    private let surfaceId: String?
    private let disabledByEnv: Bool

#if canImport(Sentry)
    private static let startupLock = NSLock()
    private static var started = false
    private static let dsn = "https://ce836c6e3462a139dcd469f5e4d3ceec@o4511028450295808.ingest.us.sentry.io/4511028453900288"

    private static func currentSentryReleaseName() -> String? {
        guard let bundleIdentifier = currentSentryBundleIdentifier(),
              let version = currentBundleVersionValue(forKey: "CFBundleShortVersionString"),
              let build = currentBundleVersionValue(forKey: "CFBundleVersion")
        else {
            return nil
        }
        return "\(bundleIdentifier)@\(version)+\(build)"
    }

    private static func currentSentryBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = currentSentryBundle()?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private static func currentBundleVersionValue(forKey key: String) -> String? {
        guard let value = currentSentryBundle()?.infoDictionary?[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func currentSentryBundle() -> Bundle? {
        if Bundle.main.bundleIdentifier?.isEmpty == false {
            return Bundle.main
        }

        guard let executableURL = currentExecutableURL() else {
            return Bundle.main
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app", let bundle = Bundle(url: current) {
                return bundle
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app", let bundle = Bundle(url: appURL) {
                    return bundle
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return Bundle.main
    }

    private static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
            }
        }

        return Bundle.main.executableURL?.standardizedFileURL
    }

    private static func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }
#endif

    init(command: String, commandArgs: [String], socketPath: String, processEnv: [String: String]) {
        self.command = command.lowercased()
        self.subcommand = commandArgs.first?.lowercased() ?? "help"
        self.socketPath = socketPath
        self.envSocketPath = processEnv["CMUX_SOCKET_PATH"] ?? processEnv["CMUX_SOCKET"]
        self.workspaceId = processEnv["CMUX_WORKSPACE_ID"]
        self.surfaceId = processEnv["CMUX_SURFACE_ID"]
        self.disabledByEnv =
            processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||
            processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1"
    }

    func breadcrumb(_ message: String, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        Self.ensureStarted()
        var payload = baseContext()
        for (key, value) in data {
            payload[key] = value
        }
        let crumb = Breadcrumb(level: .info, category: "cmux.cli")
        crumb.message = message
        crumb.data = payload
        SentrySDK.addBreadcrumb(crumb)
#endif
    }

    func captureError(stage: String, error: Error) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        Self.ensureStarted()
        var context = baseContext()
        context["stage"] = stage
        context["error"] = String(describing: error)
        for (key, value) in socketDiagnostics() {
            context[key] = value
        }
        let subcommand = self.subcommand
        let command = self.command
        _ = SentrySDK.capture(error: error) { scope in
            scope.setLevel(.error)
            scope.setTag(value: "cmux-cli", key: "component")
            scope.setTag(value: command, key: "cli_command")
            scope.setTag(value: subcommand, key: "cli_subcommand")
            scope.setContext(value: context, key: "cli_socket")
        }
        SentrySDK.flush(timeout: 2.0)
#endif
    }

    private var shouldEmit: Bool {
        !disabledByEnv
    }

    private func baseContext() -> [String: Any] {
        var context: [String: Any] = [
            "command": command,
            "subcommand": subcommand,
            "requested_socket_path": socketPath,
            "env_socket_path": envSocketPath ?? "<unset>"
        ]
        if let workspaceId {
            context["workspace_id"] = workspaceId
        }
        if let surfaceId {
            context["surface_id"] = surfaceId
        }
        return context
    }

    private func socketDiagnostics() -> [String: Any] {
        var context: [String: Any] = [
            "cwd": FileManager.default.currentDirectoryPath,
            "uid": Int(getuid()),
            "euid": Int(geteuid())
        ]

        var st = stat()
        if lstat(socketPath, &st) == 0 {
            context["socket_exists"] = true
            context["socket_mode"] = String(format: "%o", Int(st.st_mode & 0o7777))
            context["socket_owner_uid"] = Int(st.st_uid)
            context["socket_owner_gid"] = Int(st.st_gid)
            context["socket_file_type"] = Self.fileTypeDescription(mode: st.st_mode)
        } else {
            let code = errno
            context["socket_exists"] = false
            context["socket_errno"] = Int(code)
            context["socket_errno_description"] = String(cString: strerror(code))
        }

        let tmpSockets = Self.discoverSockets(in: "/tmp", limit: 10)
        if !tmpSockets.isEmpty {
            context["tmp_cmux_sockets"] = tmpSockets
        }
        let taggedSockets = tmpSockets.filter { $0 != CLISocketPathResolver.legacyDefaultSocketPath }
        if CLISocketPathResolver.isImplicitDefaultPath(socketPath),
           (envSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           !taggedSockets.isEmpty {
            context["possible_root_cause"] = "CMUX_SOCKET_PATH/CMUX_SOCKET missing while tagged sockets exist"
        }

        return context
    }

    private static func fileTypeDescription(mode: mode_t) -> String {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFSOCK):
            return "socket"
        case mode_t(S_IFREG):
            return "regular"
        case mode_t(S_IFDIR):
            return "directory"
        case mode_t(S_IFLNK):
            return "symlink"
        default:
            return "other"
        }
    }

    private static func discoverSockets(in directory: String, limit: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var sockets: [String] = []
        for name in entries.sorted() {
            guard name.hasPrefix("cmux"), name.hasSuffix(".sock") else { continue }
            let fullPath = URL(fileURLWithPath: directory)
                .appendingPathComponent(name, isDirectory: false)
                .path
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
            sockets.append(fullPath)
            if sockets.count >= limit {
                break
            }
        }
        return sockets
    }

#if canImport(Sentry)
    private static func ensureStarted() {
        startupLock.lock()
        defer { startupLock.unlock() }
        guard !started else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = currentSentryReleaseName()
#if DEBUG
            options.environment = "development-cli"
#else
            options.environment = "production-cli"
#endif
            options.debug = false
            options.sendDefaultPii = true
            options.attachStacktrace = true
            options.tracesSampleRate = 0.0
        }
        started = true
    }
#endif
}

struct WindowInfo {
    let index: Int
    let id: String
    let key: Bool
    let selectedWorkspaceId: String?
    let workspaceCount: Int
}

struct NotificationInfo {
    let id: String
    let workspaceId: String
    let surfaceId: String?
    let isRead: Bool
    let title: String
    let subtitle: String
    let body: String
}

private struct ClaudeHookParsedInput {
    let rawInput: String
    let object: [String: Any]?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
}

private struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var pid: Int?
    var lastSubtitle: String?
    var lastBody: String?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

private final class ClaudeHookSessionStore {
    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7

    private let statePath: String
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let overridePath = processEnv["CMUX_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.statePath = NSString(string: overridePath).expandingTildeInPath
        } else {
            self.statePath = NSString(string: Self.defaultStatePath).expandingTildeInPath
        }
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            state.sessions[normalized]
        }
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        pid: Int? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: nil,
                pid: nil,
                lastSubtitle: nil,
                lastBody: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            if !surfaceId.isEmpty {
                record.surfaceId = surfaceId
            }
            if let cwd = normalizeOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            if let subtitle = normalizeOptional(lastSubtitle) {
                record.lastSubtitle = subtitle
            }
            if let body = normalizeOptional(lastBody) {
                record.lastBody = body
            }
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    func consume(
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?
    ) throws -> ClaudeHookSessionRecord? {
        let normalizedSessionId = normalizeOptional(sessionId)
        let normalizedWorkspace = normalizeOptional(workspaceId)
        let normalizedSurface = normalizeOptional(surfaceId)
        return try withLockedState { state in
            if let normalizedSessionId,
               let removed = state.sessions.removeValue(forKey: normalizedSessionId) {
                return removed
            }

            guard let fallback = fallbackRecord(
                sessions: Array(state.sessions.values),
                workspaceId: normalizedWorkspace,
                surfaceId: normalizedSurface
            ) else {
                return nil
            }
            state.sessions.removeValue(forKey: fallback.sessionId)
            return fallback
        }
    }

    private func fallbackRecord(
        sessions: [ClaudeHookSessionRecord],
        workspaceId: String?,
        surfaceId: String?
    ) -> ClaudeHookSessionRecord? {
        if let surfaceId {
            let matches = sessions.filter { $0.surfaceId == surfaceId }
            return matches.max(by: { $0.updatedAt < $1.updatedAt })
        }
        if let workspaceId {
            let matches = sessions.filter { $0.workspaceId == workspaceId }
            if matches.count == 1 {
                return matches[0]
            }
        }
        return nil
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
        let lockPath = statePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Claude hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Claude hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = loadUnlocked()
        pruneExpired(&state)
        let result = try body(&state)
        try saveUnlocked(state)
        return result
    }

    private func loadUnlocked() -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let decoded = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return ClaudeHookSessionStoreFile()
        }
        return decoded
    }

    private func saveUnlocked(_ state: ClaudeHookSessionStoreFile) throws {
        let stateURL = URL(fileURLWithPath: statePath)
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func pruneExpired(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
    }

    private func normalizeSessionId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

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
    private static let directoryName = "c11mux"
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

    private static func normalized(_ value: String?) -> String? {
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
        guard let data = try? Data(contentsOf: passwordURL) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(value)
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

private enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

private enum CLISocketPathResolver {
    private static let appSupportDirectoryName = "cmux"
    private static let stableSocketFileName = "cmux.sock"
    private static let lastSocketPathFileName = "last-socket-path"
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
        let primaryCandidate: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
            .path
        let candidates = [primaryCandidate, legacyLastSocketPathFile].compactMap { $0 }

        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data) {
                return value
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
            for name in entries where name.hasPrefix("cmux") && name.hasSuffix(".sock") {
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

    private static func normalized(_ value: String?) -> String? {
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

final class SocketClient {
    // Stable string used at both the throw site and the catch site in sendV2.
    // Extracting it prevents the catch clause from silently missing the timeout
    // if the throw-site message is ever edited.
    fileprivate static let commandTimedOutMessage = "Command timed out"

    private let path: String
    private var socketFD: Int32 = -1

    // Default deadline: 10 s, tunable via env. Dual-read: C11_* primary, CMUX_* compat.
    // Legacy CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC (seconds) honoured for backward compat.
    private static let configuredDefaultDeadlineSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        for key in ["C11_DEFAULT_SOCKET_DEADLINE_MS", "CMUX_DEFAULT_SOCKET_DEADLINE_MS"] {
            if let raw = env[key], let ms = Double(raw), ms > 0 { return ms / 1000 }
        }
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"], let s = Double(raw), s > 0 { return s }
        return 10.0
    }()

    // C11_TRACE=1 (or CMUX_TRACE=1) prints per-request start/end/timing lines to stderr.
    private static let traceEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["C11_TRACE"] == "1" || env["CMUX_TRACE"] == "1"
    }()

    private static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    func connect() throws {
        if socketFD >= 0 { return }
        try connectOnce()
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    // Backward-compat overload: uses the configured default deadline.
    func send(command: String) throws -> String {
        try send(command: command, responseTimeout: Self.configuredDefaultDeadlineSeconds)
    }

    // responseTimeout: nil = no SO_RCVTIMEO (unbounded); >0 = initial-read deadline in seconds.
    func send(command: String, responseTimeout: TimeInterval?) throws -> String {
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let payload = command + "\n"
        try payload.withCString { ptr in
            let sent = Darwin.write(socketFD, ptr, strlen(ptr))
            if sent < 0 {
                throw CLIError(message: "Failed to write to socket")
            }
        }

        var data = Data()
        var sawNewline = false

        while true {
            try configureReceiveTimeout(
                sawNewline ? Self.multilineResponseIdleTimeoutSeconds : responseTimeout
            )

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        break
                    }
                    throw CLIError(message: SocketClient.commandTimedOutMessage)
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    private func connectOnce() throws {
        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }

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
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw CLIError(
            message: "Failed to connect to socket at \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
        )
    }

    // timeout == nil clears SO_RCVTIMEO (no deadline). timeout > 0 sets the deadline.
    private func configureReceiveTimeout(_ timeout: TimeInterval?) throws {
        var interval: timeval
        if let t = timeout, t > 0 {
            interval = timeval(
                tv_sec: Int(t.rounded(.down)),
                tv_usec: __darwin_suseconds_t((t - floor(t)) * 1_000_000)
            )
        } else {
            interval = timeval(tv_sec: 0, tv_usec: 0)
        }
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to configure socket receive timeout")
        }
    }

    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        let client = SocketClient(path: path)
        if (try? client.connect()) != nil {
            return client
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "c11 app did not start in time (socket not found at \(path))")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "c11 app did not start in time (socket not found at \(path))")
        }

        let queue = DispatchQueue(label: "com.stage11.c11.cli.socket-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var connected = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func attemptConnect() {
            guard !connected else { return }
            if (try? client.connect()) != nil {
                connected = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            attemptConnect()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            attemptConnect()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            client.close()
            throw CLIError(message: "c11 app did not start in time (socket not found at \(path))")
        }

        source.cancel()
        return client
    }

    static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.stage11.c11.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    func sendV2(method: String, params: [String: Any] = [:], deadline: SocketDeadline = .default) throws -> [String: Any] {
        let effectiveTimeout: TimeInterval?
        switch deadline {
        case .default: effectiveTimeout = Self.configuredDefaultDeadlineSeconds
        case .none: effectiveTimeout = nil
        case .custom(let t): effectiveTimeout = t > 0 ? t : nil
        }

        let startTime = Date()
        var traceStatus = "ok"

        if Self.traceEnabled {
            let refs = refTokens(from: params).joined(separator: " ")
            let refsStr = refs.isEmpty ? "" : "(\(refs)) "
            FileHandle.standardError.write(
                Data("[c11-trace] -> \(method) \(refsStr)socket=\(path)\n".utf8)
            )
        }
        defer {
            if Self.traceEnabled {
                let ms = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
                FileHandle.standardError.write(
                    Data("[c11-trace] <- \(method) elapsed=\(ms)ms status=\(traceStatus)\n".utf8)
                )
            }
        }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            traceStatus = "error"
            throw CLIError(message: "Failed to encode v2 request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let requestLine = String(data: requestData, encoding: .utf8) else {
            traceStatus = "error"
            throw CLIError(message: "Failed to encode v2 request")
        }

        let raw: String
        do {
            raw = try send(command: requestLine, responseTimeout: effectiveTimeout)
        } catch let err as CLIError where err.message == SocketClient.commandTimedOutMessage {
            traceStatus = "timeout"
            let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
            throw CLIError(message: timeoutMessage(method: method, params: params, elapsedMs: elapsedMs))
        } catch {
            traceStatus = "error"
            throw error
        }

        // The server may return plain-text errors (e.g., "ERROR: Access denied ...")
        // before the JSON protocol starts. Surface these directly instead of letting
        // JSONSerialization throw a confusing parse error.
        if raw.hasPrefix("ERROR:") {
            traceStatus = "error"
            throw CLIError(message: raw)
        }

        guard let responseData = raw.data(using: .utf8) else {
            traceStatus = "error"
            throw CLIError(message: "Invalid UTF-8 v2 response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            traceStatus = "error"
            throw CLIError(message: "Invalid v2 response: \(raw)")
        }

        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            // Normalize server-side main_thread_timeout to the same parseable c11: timeout:
            // envelope as a client-side SO_RCVTIMEO, so automation can parse both paths uniformly.
            // The 8 s server deadline is intentionally shorter than the 10 s CLI deadline, so this
            // is the expected production timeout path under a saturated main thread.
            if code == "main_thread_timeout" {
                traceStatus = "timeout"
                let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
                throw CLIError(message: timeoutMessage(method: method, params: params, elapsedMs: elapsedMs))
            }
            traceStatus = "error"
            throw CLIError(message: "\(code): \(message)")
        }

        traceStatus = "error"
        throw CLIError(message: "v2 request failed")
    }

    // Shared builder for both trace output and timeout error messages.
    // Extracts workspace/surface/pane/panel refs from params into "key=value" tokens.
    private func refTokens(from params: [String: Any]) -> [String] {
        var parts: [String] = []
        if let ws = params["workspace_id"] as? String { parts.append("workspace=\(ws)") }
        if let surf = params["surface_id"] as? String { parts.append("surface=\(surf)") }
        if let pane = params["pane_id"] as? String { parts.append("pane=\(pane)") }
        if let panel = params["panel_id"] as? String { parts.append("panel=\(panel)") }
        return parts
    }

    private func timeoutMessage(method: String, params: [String: Any], elapsedMs: Int) -> String {
        var parts = ["method=\(method)"] + refTokens(from: params)
        parts.append("socket=\(path)")
        parts.append("elapsed_ms=\(elapsedMs)")
        return "c11: timeout: \(parts.joined(separator: " "))"
    }
}

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum CLIProcessRunner {
    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return CLIProcessResult(status: 1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .success {
            return
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}

struct CMUXCLI {
    let args: [String]

    private static let debugLastSocketHintPath = "/tmp/cmux-last-socket-path"

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func pathIsSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func debugSocketPathFromHintFile() -> String? {
#if DEBUG
        guard let raw = try? String(contentsOfFile: debugLastSocketHintPath, encoding: .utf8) else {
            return nil
        }
        guard let hinted = normalizedEnvValue(raw),
              hinted.hasPrefix("/tmp/cmux-debug"),
              hinted.hasSuffix(".sock"),
              pathIsSocket(hinted) else {
            return nil
        }
        return hinted
#else
        return nil
#endif
    }

    private static func defaultSocketPath(environment: [String: String]) -> String {
        if let explicit = normalizedEnvValue(environment["CMUX_SOCKET_PATH"]) {
            return explicit
        }
#if DEBUG
        if let hinted = debugSocketPathFromHintFile() {
            return hinted
        }
        return "/tmp/cmux-debug.sock"
#else
        return "/tmp/cmux.sock"
#endif
    }

    func run() throws {
        let processEnv = ProcessInfo.processInfo.environment
        let envSocketPath: String? = {
            for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
                guard let raw = processEnv[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()
        var socketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        var socketPathSource: CLISocketPathSource
        if let envSocketPath {
            socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            socketPathSource = .implicitDefault
        }
        var jsonOutput = false
        var idFormatArg: String? = nil
        var windowId: String? = nil
        var socketPasswordArg: String? = nil

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--socket" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--socket requires a path")
                }
                socketPath = args[index + 1]
                socketPathSource = .explicitFlag
                index += 2
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormatArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "--window" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--window requires a window id")
                }
                windowId = args[index + 1]
                index += 2
                continue
            }
            if arg == "--password" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--password requires a value")
                }
                socketPasswordArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "-v" || arg == "--version" {
                print(versionSummary())
                return
            }
            if arg == "-h" || arg == "--help" {
                print(usage())
                return
            }
            break
        }

        guard index < args.count else {
            print(usage())
            throw CLIError(message: "Missing command")
        }

        let command = args[index]
        let commandArgs = Array(args[(index + 1)...])
        let cliTelemetry = CLISocketSentryTelemetry(
            command: command,
            commandArgs: commandArgs,
            socketPath: socketPath,
            processEnv: processEnv
        )
        let resolvedSocketPath = CLISocketPathResolver.resolve(
            requestedPath: socketPath,
            source: socketPathSource,
            environment: processEnv
        )

        if command == "version" {
            print(versionSummary())
            return
        }

        if command == "remote-daemon-status" {
            try runRemoteDaemonStatus(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        // If the argument looks like a path (not a known command), open a workspace there.
        if looksLikePath(command) {
            try openPath(command, socketPath: resolvedSocketPath)
            return
        }

        // Check for --help/-h on subcommands before connecting to the socket,
        // so help text is available even when cmux is not running.
        if command != "__tmux-compat",
           command != "claude-teams",
           (commandArgs.contains("--help") || commandArgs.contains("-h")) {
            if dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {
                return
            }
            print("Unknown command '\(command)'. Run 'c11 help' to see available commands.")
            return
        }

        if command == "welcome" {
            printWelcome()
            return
        }

        if command == "shortcuts" {
            try runShortcuts(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "feedback" {
            try runFeedback(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "terminal-theme" {
            try runThemes(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "claude-teams" {
            try runClaudeTeams(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "skill" {
            try runSkillCommand(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        if command == "install" || command == "uninstall" {
            // Integration installers (Module 4) are filesystem-local; they do
            // not connect to the running cmux socket. Exit codes are carried
            // via a dedicated thrown error type that CMUXTermMain routes to
            // the proper numeric exit.
            try runIntegrationInstallerCommand(
                command: command,
                commandArgs: commandArgs,
                jsonOutput: jsonOutput
            )
            return
        }

        let client = SocketClient(path: resolvedSocketPath)
        if resolvedSocketPath != socketPath {
            cliTelemetry.breadcrumb(
                "socket.path.autodiscovered",
                data: [
                    "requested_path": socketPath,
                    "resolved_path": resolvedSocketPath
                ]
            )
        }
        cliTelemetry.breadcrumb(
            "socket.connect.attempt",
            data: [
                "command": command,
                "path": resolvedSocketPath
            ]
        )
        do {
            try client.connect()
            cliTelemetry.breadcrumb("socket.connect.success", data: ["path": resolvedSocketPath])
        } catch {
            cliTelemetry.breadcrumb("socket.connect.failure", data: ["path": resolvedSocketPath])
            cliTelemetry.captureError(stage: "socket_connect", error: error)
            // Advisory commands (claude-hook) should never error a Claude Code
            // banner on every prompt just because c11 isn't listening. Exit
            // cleanly when the eager connect fails for a connectivity reason.
            // Real hook bugs still propagate from inside the subcommand.
            if command == "claude-hook",
               let cliError = error as? CLIError,
               isAdvisoryHookConnectivityError(cliError) {
                cliTelemetry.breadcrumb("claude-hook.socket-unreachable")
                return
            }
            throw error
        }
        defer { client.close() }

        try authenticateClientIfNeeded(
            client,
            explicitPassword: socketPasswordArg,
            socketPath: resolvedSocketPath
        )

        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)

        // If the user explicitly targets a window, focus it first so commands route correctly.
        if let windowId {
            let normalizedWindow = try normalizeWindowHandle(windowId, client: client) ?? windowId
            _ = try client.sendV2(method: "window.focus", params: ["window_id": normalizedWindow])
        }

        switch command {
        case "ping":
            let response = try sendV1Command("ping", client: client)
            print(response)

        case "capabilities":
            let response = try client.sendV2(method: "system.capabilities")
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "brand":
            let response = try client.sendV2(method: "system.brand")
            if jsonOutput || hasFlag(commandArgs, name: "--json") {
                print(jsonString(response))
            } else {
                printBrandHuman(response)
            }

        case "identify":
            var params: [String: Any] = [:]
            let includeCaller = !hasFlag(commandArgs, name: "--no-caller")
            if includeCaller {
                let idWsFlag = optionValue(commandArgs, name: "--workspace")
                let workspaceArg = idWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
                let surfaceArg = optionValue(commandArgs, name: "--surface") ?? (idWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
                if workspaceArg != nil || surfaceArg != nil {
                    let workspaceId = try normalizeWorkspaceHandle(
                        workspaceArg,
                        client: client,
                        allowCurrent: surfaceArg != nil
                    )
                    var caller: [String: Any] = [:]
                    if let workspaceId {
                        caller["workspace_id"] = workspaceId
                    }
                    if surfaceArg != nil {
                        guard let surfaceId = try normalizeSurfaceHandle(
                            surfaceArg,
                            client: client,
                            workspaceHandle: workspaceId
                        ) else {
                            throw CLIError(message: "Invalid surface handle")
                        }
                        caller["surface_id"] = surfaceId
                    }
                    if !caller.isEmpty {
                        params["caller"] = caller
                    }
                }
            }
            let response = try client.sendV2(method: "system.identify", params: params)
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "list-windows":
            let response = try sendV1Command("list_windows", client: client)
            if jsonOutput {
                let windows = parseWindows(response)
                let payload = windows.map { item -> [String: Any] in
                    var dict: [String: Any] = [
                        "index": item.index,
                        "id": item.id,
                        "key": item.key,
                        "workspace_count": item.workspaceCount,
                    ]
                    dict["selected_workspace_id"] = item.selectedWorkspaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "current-window":
            let response = try sendV1Command("current_window", client: client)
            if jsonOutput {
                print(jsonString(["window_id": response]))
            } else {
                print(response)
            }

        case "new-window":
            let response = try sendV1Command("new_window", client: client)
            print(response)

        case "focus-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "focus-window requires --window")
            }
            let response = try sendV1Command("focus_window \(target)", client: client)
            print(response)

        case "close-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "close-window requires --window")
            }
            let response = try sendV1Command("close_window \(target)", client: client)
            print(response)

        case "move-workspace-to-window":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "move-workspace-to-window requires --workspace")
            }
            guard let windowRaw = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "move-workspace-to-window requires --window")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let payload = try client.sendV2(method: "workspace.move_to_window", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace", "window"]))

        case "move-surface":
            try runMoveSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-surface":
            try runReorderSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspace":
            try runReorderWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "workspace-action":
            try runWorkspaceAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "tab-action":
            try runTabAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "rename-tab":
            try runRenameTab(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "set-title":
            try runSetTitle(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-description":
            try runSetDescription(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-titlebar-state":
            try runGetTitleBarState(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "list-workspaces":
            let payload = try client.sendV2(method: "workspace.list")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                if workspaces.isEmpty {
                    print("No workspaces")
                } else {
                    for ws in workspaces {
                        let selected = (ws["selected"] as? Bool) == true
                        let handle = textHandle(ws, idFormat: idFormat)
                        let title = (ws["title"] as? String) ?? ""
                        let remoteTag: String = {
                            guard let remote = ws["remote"] as? [String: Any],
                                  (remote["enabled"] as? Bool) == true else {
                                return ""
                            }
                            let state = (remote["state"] as? String) ?? "unknown"
                            return "  [ssh:\(state)]"
                        }()
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        let titlePart = title.isEmpty ? "" : "  \(title)"
                        print("\(prefix)\(handle)\(titlePart)\(remoteTag)\(selTag)")
                    }
                }
            }

        case "ssh":
            try runSSH(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "ssh-session-end":
            try runSSHSessionEnd(commandArgs: commandArgs, client: client)

        case "workspace":
            // CMUX-37: `c11 workspace <subcommand>`. Subcommands added across
            // phases: apply (Phase 0), new + export-blueprint (Phase 2).
            guard let sub = commandArgs.first else {
                throw CLIError(message: "workspace: missing subcommand. Known subcommands: apply, new, export-blueprint")
            }
            let subArgs = Array(commandArgs.dropFirst())
            switch sub {
            case "apply":
                try runWorkspaceApply(
                    subArgs,
                    client: client,
                    commandLabel: "workspace apply",
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
            case "new":
                try runWorkspaceBlueprintNew(
                    subArgs,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
            case "export-blueprint":
                try runWorkspaceExportBlueprint(
                    subArgs,
                    client: client,
                    jsonOutput: jsonOutput
                )
            default:
                throw CLIError(message: "workspace: unknown subcommand '\(sub)'. Known subcommands: apply, new, export-blueprint")
            }

        case "workspace-apply":
            // Back-compat alias for the Phase 0 `c11 workspace apply` form
            // that shipped before the review cycle 1 rename. Prefer the
            // subcommand form going forward.
            try runWorkspaceApply(
                commandArgs,
                client: client,
                commandLabel: "workspace-apply",
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        case "snapshot":
            // CMUX-37 Phase 1: `c11 snapshot [--workspace <ref>] [--out <path>]`
            // captures the current workspace (or a named one) to
            // `~/.c11-snapshots/<ulid>.json`. Backed by the `snapshot.create`
            // v2 method.
            try runSnapshotCreate(
                commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "restore":
            // CMUX-37 Phase 1: `c11 restore <snapshot-id|path>`. Reads
            // `C11_SESSION_RESUME` / `CMUX_SESSION_RESUME` at this site and,
            // when set, threads the `phase1` restart registry into
            // `snapshot.restore` so cc terminals resume via
            // `cc --resume <session-id>`.
            try runSnapshotRestore(
                commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        case "list-snapshots":
            // CMUX-37 Phase 1: `c11 list-snapshots [--json]`. Merges
            // `~/.c11-snapshots/` + legacy `~/.cmux-snapshots/`.
            try runListSnapshots(
                commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "new-workspace":
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
            let (layoutOpt, remaining) = parseOption(rem1, name: "--layout")
            if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --command <text>, --cwd <path>, --layout <path|name>")
            }
            var params: [String: Any] = [:]
            if let cwdOpt {
                let resolved = resolvePath(cwdOpt)
                params["cwd"] = resolved
            }
            if let layoutRef = layoutOpt {
                // Resolve blueprint path or name -> {plan: ...} dict for workspace.create layout param.
                params["layout"] = try resolveBlueprintPlan(layoutRef, client: client)
            }
            let response = try client.sendV2(method: "workspace.create", params: params)
            let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            print("OK \(wsId)")
            if let commandText = commandOpt, !wsId.isEmpty {
                let text = unescapeSendText(commandText + "\\n")
                let sendParams: [String: Any] = ["text": text, "workspace_id": wsId]
                _ = try client.sendV2(method: "surface.send_text", params: sendParams)
            }

        case "new-split":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let (sfArg, rem2) = parseOption(rem1, name: "--surface")
            let (titleArg, rem3) = parseOption(rem2, name: "--title")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = sfArg ?? panelArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            guard let direction = rem3.first else {
                throw CLIError(message: "new-split requires a direction")
            }
            var params: [String: Any] = ["direction": direction]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            if let titleArg, !titleArg.isEmpty { params["title"] = titleArg }
            let payload = try client.sendV2(method: "surface.split", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panes":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let panes = payload["panes"] as? [[String: Any]] ?? []
                if panes.isEmpty {
                    print("No panes")
                } else {
                    for pane in panes {
                        let focused = (pane["focused"] as? Bool) == true
                        let handle = textHandle(pane, idFormat: idFormat)
                        let count = pane["surface_count"] as? Int ?? 0
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        print("\(prefix)\(handle)  [\(count) surface\(count == 1 ? "" : "s")]\(focusTag)")
                    }
                }
            }

        case "list-pane-surfaces":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let paneRaw = optionValue(commandArgs, name: "--pane")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.surfaces", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces in pane")
                } else {
                    for surface in surfaces {
                        let selected = (surface["selected"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        print("\(prefix)\(handle)  \(title)\(selTag)")
                    }
                }
            }

        case "tree":
            try runTreeCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let paneRaw = optionValue(commandArgs, name: "--pane") ?? commandArgs.first else {
                throw CLIError(message: "focus-pane requires --pane <id|ref>")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane", "workspace"]))

        case "new-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let direction = optionValue(commandArgs, name: "--direction") ?? "right"
            let url = optionValue(commandArgs, name: "--url")
            let file = optionValue(commandArgs, name: "--file")
            let title = optionValue(commandArgs, name: "--title")
            var params: [String: Any] = ["direction": direction]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            if let file { params["file"] = file }
            if let title, !title.isEmpty { params["title"] = title }
            let payload = try client.sendV2(method: "pane.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "new-surface":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let type = optionValue(commandArgs, name: "--type")
            let paneRaw = optionValue(commandArgs, name: "--pane")
            let url = optionValue(commandArgs, name: "--url")
            let file = optionValue(commandArgs, name: "--file")
            let noFocus = commandArgs.contains("--no-focus")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            if let file { params["file"] = file }
            if noFocus { params["focus"] = false }
            let payload = try client.sendV2(method: "surface.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace"]))

        case "close-surface":
            let csWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = csWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? (csWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "pane-confirm":
            // Present a confirmation dialog anchored on a specific panel and wait for
            // the user's decision. Maps to the pane.confirm socket method (plan §3.6).
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "pane-confirm requires --panel <id|ref>")
            }
            guard let title = optionValue(commandArgs, name: "--title") else {
                throw CLIError(message: "pane-confirm requires --title <text>")
            }
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            let panelId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId)
            var params: [String: Any] = ["title": title]
            if let panelId { params["panel_id"] = panelId }
            if let wsId { params["workspace_id"] = wsId }
            if let message = optionValue(commandArgs, name: "--message") {
                params["message"] = message
            }
            if commandArgs.contains("--destructive") {
                params["role"] = "destructive"
            }
            if let timeoutStr = optionValue(commandArgs, name: "--timeout") {
                // Fail loudly on unparseable input instead of silently dropping
                // the flag — "cmux pane-confirm ... --timeout abc" used to wait
                // forever.
                guard let timeout = Double(timeoutStr) else {
                    throw CLIError(message: "pane-confirm: invalid --timeout '\(timeoutStr)' (expected a number in seconds)")
                }
                params["timeout"] = timeout
            }
            if let confirmLabel = optionValue(commandArgs, name: "--confirm-label") {
                params["confirm_label"] = confirmLabel
            }
            if let cancelLabel = optionValue(commandArgs, name: "--cancel-label") {
                params["cancel_label"] = cancelLabel
            }
            let payload = try client.sendV2(method: "pane.confirm", params: params, deadline: .none)
            // Exit code maps to outcome: 0=ok, 2=cancel, 3=dismissed, 1=error.
            // Note: socket reports timeout as "dismissed" (exit 3); the user
            // cannot distinguish a timeout from a panel-teardown from the CLI.
            let outcome = (payload["result"] as? [String: Any])?["result"] as? String
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else if let outcome {
                print(outcome)
            } else {
                print(jsonString(payload))
            }
            switch outcome {
            case "ok": exit(0)
            case "cancel": exit(2)
            case "dismissed": exit(3)
            default: exit(1)
            }

        case "drag-surface-to-split":
            let (surfaceArg, rem0) = parseOption(commandArgs, name: "--surface")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let surface = surfaceArg ?? panelArg
            guard let surface else {
                throw CLIError(message: "drag-surface-to-split requires --surface <id|index>")
            }
            guard let direction = rem1.first else {
                throw CLIError(message: "drag-surface-to-split requires a direction")
            }
            let response = try sendV1Command("drag_surface_to_split \(surface) \(direction)", client: client)
            print(response)

        case "refresh-surfaces":
            let response = try sendV1Command("refresh_surfaces", client: client)
            print(response)

        case "surface-health":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.health", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let inWindow = surface["in_window"]
                        let inWindowStr: String
                        if let b = inWindow as? Bool {
                            inWindowStr = " in_window=\(b)"
                        } else {
                            inWindowStr = ""
                        }
                        print("\(handle)  type=\(sType)\(inWindowStr)")
                    }
                }
            }

        case "debug-terminals":
            let unexpected = commandArgs.filter { $0 != "--" }
            if let extra = unexpected.first {
                throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
            }
            let payload = try client.sendV2(method: "debug.terminals")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print(formatDebugTerminalsPayload(payload, idFormat: idFormat))
            }

        case "trigger-flash":
            let tfWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = tfWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--surface") ?? optionValue(commandArgs, name: "--panel") ?? (tfWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.trigger_flash", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panels":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "surface.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No surfaces")
                } else {
                    for surface in surfaces {
                        let focused = (surface["focused"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                        print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                    }
                }
            }

        case "focus-panel":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "focus-panel requires --panel")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "close-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "close-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "select-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "select-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.select", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "rename-workspace", "rename-window":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
            let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "\(command) requires a title")
            }
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let params: [String: Any] = ["title": title, "workspace_id": wsId]
            let payload = try client.sendV2(method: "workspace.rename", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "current-workspace":
            let response = try sendV1Command("current_workspace", client: client)
            if jsonOutput {
                print(jsonString(["workspace_id": response]))
            } else {
                print(response)
            }

        case "read-screen":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let trailing = rem2.filter { $0 != "--scrollback" }
            if !trailing.isEmpty {
                throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
            }

            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "send":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            // Require explicit surface targeting. Shell-integrated callers inside a c11
            // surface have CMUX_SURFACE_ID set automatically. External callers must pass
            // --surface. The windowId path is excluded: --window without --surface still
            // routes to ws.focusedPanelId, which is the ambient misdirection we're removing.
            guard sfArg != nil
                || ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                throw CLIError(message: "send requires --surface <id|ref> (or run inside a c11 surface so CMUX_SURFACE_ID is set)")
            }
            let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
            // Require explicit surface targeting (same policy as send).
            // windowId alone is excluded for the same reason: it still routes to focusedPanelId.
            guard sfArg != nil
                || ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] != nil else {
                throw CLIError(message: "send-key requires --surface <id|ref> (or run inside a c11 surface so CMUX_SURFACE_ID is set)")
            }
            let keyArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            guard let key = keyArgs.first else { throw CLIError(message: "send-key requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-panel requires --panel")
            }
            let rawText = rem1.dropFirst(rem1.first == "--" ? 1 : 0).joined(separator: " ")
            guard !rawText.isEmpty else { throw CLIError(message: "send-panel requires text") }
            let text = unescapeSendText(rawText)
            var params: [String: Any] = ["text": text]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key-panel":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArg, rem1) = parseOption(rem0, name: "--panel")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            guard let panelArg else {
                throw CLIError(message: "send-key-panel requires --panel")
            }
            let skpArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            let key = skpArgs.first ?? ""
            guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "notify":
            let title = optionValue(commandArgs, name: "--title") ?? "Notification"
            let subtitle = optionValue(commandArgs, name: "--subtitle") ?? ""
            let body = optionValue(commandArgs, name: "--body") ?? ""

            let notifyWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = notifyWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--surface") ?? (notifyWsFlag == nil && windowId == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = ["title": title, "subtitle": subtitle, "body": body]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let method = sfId != nil ? "notification.create_for_surface" : "notification.create"
            let payload = try client.sendV2(method: method, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-notifications":
            let response = try sendV1Command("list_notifications", client: client)
            if jsonOutput {
                let notifications = parseNotifications(response)
                let payload = notifications.map { item in
                    var dict: [String: Any] = [
                        "id": item.id,
                        "workspace_id": item.workspaceId,
                        "is_read": item.isRead,
                        "title": item.title,
                        "subtitle": item.subtitle,
                        "body": item.body
                    ]
                    dict["surface_id"] = item.surfaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "clear-notifications":
            var socketCmd = "clear_notifications"
            if let wsFlag = optionValue(commandArgs, name: "--workspace") {
                let wsId = try resolveWorkspaceId(wsFlag, client: client)
                socketCmd += " --tab=\(wsId)"
            } else if windowId == nil,
                      let envWs = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
                      let wsId = try? resolveWorkspaceId(envWs, client: client) {
                socketCmd += " --tab=\(wsId)"
            }
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "set-status":
            let response = try forwardSidebarMetadataCommand(
                "set_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-status":
            let response = try forwardSidebarMetadataCommand(
                "clear_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-status":
            let response = try forwardSidebarMetadataCommand(
                "list_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "set-progress":
            let response = try forwardSidebarMetadataCommand(
                "set_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-progress":
            let response = try forwardSidebarMetadataCommand(
                "clear_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "log":
            let response = try forwardSidebarMetadataCommand(
                "log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-log":
            let response = try forwardSidebarMetadataCommand(
                "clear_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-log":
            let response = try forwardSidebarMetadataCommand(
                "list_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "sidebar-state":
            // --json emits the v2 sidebar.state response (includes agent_chip).
            if commandArgs.contains("--json") || jsonOutput {
                let (workspaceRaw, _) = parseOption(commandArgs, name: "--workspace")
                var params: [String: Any] = [:]
                if let workspaceRaw {
                    if let ws = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                        params["workspace_id"] = ws
                    }
                } else if let envWs = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
                          let ws = try normalizeWorkspaceHandle(envWs, client: client) {
                    params["workspace_id"] = ws
                }
                let payload = try client.sendV2(method: "sidebar.state", params: params)
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let response = try forwardSidebarMetadataCommand(
                    "sidebar_state",
                    commandArgs: commandArgs,
                    client: client,
                    windowOverride: windowId
                )
                print(response)
            }

        case "set-agent":
            try runSetAgentCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-metadata":
            try runSetMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "get-metadata":
            try runGetMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "clear-metadata":
            try runClearMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-workspace-metadata":
            try runSetWorkspaceMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "get-workspace-metadata":
            try runGetWorkspaceMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "clear-workspace-metadata":
            try runClearWorkspaceMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-workspace-description":
            try runSetWorkspaceCanonicalKeyCommand(
                key: "description",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-workspace-icon":
            try runSetWorkspaceCanonicalKeyCommand(
                key: "icon",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "conversation":
            try runConversationCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "claude-hook":
            cliTelemetry.breadcrumb("claude-hook.dispatch")
            do {
                try runClaudeHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry)
                cliTelemetry.breadcrumb("claude-hook.completed")
            } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
                // claude-hook is advisory — it signals c11 about Claude Code
                // lifecycle events (prompt submitted, notification, etc.) so
                // the sidebar can update. When c11 isn't running (socket
                // missing / refused / path orphaned from a crashed process),
                // there's nothing to signal. Exit cleanly so Claude Code
                // doesn't surface a hook-error banner on every prompt. Real
                // hook bugs (malformed input, logic errors) still propagate.
                cliTelemetry.breadcrumb("claude-hook.socket-unreachable")
            } catch {
                cliTelemetry.breadcrumb("claude-hook.failure")
                cliTelemetry.captureError(stage: "claude_hook_dispatch", error: error)
                throw error
            }

        case "set-app-focus":
            guard let value = commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
            let response = try sendV1Command("set_app_focus \(value)", client: client)
            print(response)

        case "simulate-app-active":
            let response = try sendV1Command("simulate_app_active", client: client)
            print(response)

        case "__tmux-compat":
            try runClaudeTeamsTmuxCompat(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "capture-pane",
             "resize-pane",
             "pipe-pane",
             "wait-for",
             "swap-pane",
             "break-pane",
             "join-pane",
             "last-window",
             "last-pane",
             "next-window",
             "previous-window",
             "find-window",
             "clear-history",
             "set-hook",
             "popup",
             "bind-key",
             "unbind-key",
             "copy-mode",
             "set-buffer",
             "paste-buffer",
             "list-buffers",
             "respawn-pane",
             "display-message":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "help":
            print(usage())

        // Browser commands
        case "browser":
            try runBrowserCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Legacy aliases shimmed onto the v2 browser command surface.
        case "open-browser":
            try runBrowserCommand(commandArgs: ["open"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "navigate":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["navigate"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-back":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["back"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-forward":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["forward"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-reload":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["reload"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-url":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["get-url"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-webview":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["focus-webview"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "is-webview-focused":
            let bridged = replaceToken(commandArgs, from: "--panel", to: "--surface")
            try runBrowserCommand(commandArgs: ["is-webview-focused"] + bridged, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Markdown commands
        case "markdown":
            try runMarkdownCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "markdown-content":
            try runMarkdownGetContentCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // c11 chrome theme commands.
        case "themes":
            try runUiThemes(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                allowAuthoringHelpers: false
            )

        // Legacy UI / theme commands (CMUX-35)
        case "ui":
            try runUi(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)

        case "workspace-color":
            try runWorkspaceColor(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)

        // C11-13 Stage 2: inter-agent mailbox (send/recv/trace/tail + helpers).
        case "mailbox":
            try runMailboxCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
    }

    private func localizedBlueprintSourceLabel(_ raw: String) -> String {
        switch raw {
        case "repo":
            return String(localized: "workspace.blueprint.source.repo", defaultValue: "repo")
        case "user":
            return String(localized: "workspace.blueprint.source.user", defaultValue: "user")
        case "built-in":
            return String(localized: "workspace.blueprint.source.builtIn", defaultValue: "built-in")
        default:
            return raw
        }
    }

    private func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    /// Shared implementation for `c11 workspace apply` and its back-compat
    /// alias `c11 workspace-apply`. Reads a JSON `WorkspaceApplyPlan` from a
    /// file path (or `-` for stdin), POSTs it via `workspace.apply`, and
    /// prints the `ApplyResult`. `commandLabel` is threaded into error
    /// messages so operators know which spelling they invoked.
    private func runWorkspaceApply(
        _ args: [String],
        client: SocketClient,
        commandLabel: String,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (fileOpt, remaining) = parseOption(args, name: "--file")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "\(commandLabel): unknown flag '\(unknown)'. Known flags: --file <path|->")
        }
        guard let fileArg = fileOpt else {
            throw CLIError(message: "\(commandLabel) requires --file <path|->")
        }
        let planData: Data
        if fileArg == "-" {
            planData = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let resolvedPath = resolvePath(fileArg)
            guard let data = FileManager.default.contents(atPath: resolvedPath) else {
                throw CLIError(message: "\(commandLabel): could not read '\(resolvedPath)'")
            }
            planData = data
        }
        guard let planObject = try? JSONSerialization.jsonObject(with: planData, options: []) else {
            throw CLIError(message: "\(commandLabel): --file contents are not valid JSON")
        }
        let payload = try client.sendV2(method: "workspace.apply", params: ["plan": planObject])
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let ref = (payload["workspaceRef"] as? String) ?? "?"
            let surfaceRefs = payload["surfaceRefs"] as? [String: String] ?? [:]
            let paneRefs = payload["paneRefs"] as? [String: String] ?? [:]
            let warnings = payload["warnings"] as? [String] ?? []
            let failures = payload["failures"] as? [[String: Any]] ?? []
            print("OK workspace=\(ref) surfaces=\(surfaceRefs.count) panes=\(paneRefs.count)")
            if !warnings.isEmpty {
                print("warnings: \(warnings.count)")
                for w in warnings { print("  - \(w)") }
            }
            if !failures.isEmpty {
                print("failures: \(failures.count)")
                for f in failures {
                    let code = (f["code"] as? String) ?? "?"
                    let step = (f["step"] as? String) ?? "?"
                    let msg = (f["message"] as? String) ?? ""
                    print("  - [\(code)] \(step): \(msg)")
                }
            }
        }
    }

    // MARK: - CMUX-37 Phase 2: blueprint commands

    /// `c11 workspace new [--blueprint <path>]`. Without `--blueprint` drops
    /// into an interactive picker that calls `workspace.list_blueprints` and
    /// lets the user choose by number. With `--blueprint <path>` reads the
    /// `WorkspaceBlueprintFile` JSON directly and applies its plan.
    private func runWorkspaceBlueprintNew(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (blueprintOpt, remaining) = parseOption(args, name: "--blueprint")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace new: unknown flag '\(unknown)'. Known flags: --blueprint <path>")
        }

        if jsonOutput && blueprintOpt == nil {
            print(#"{"ok": false, "error": {"code": "PICKER_NOT_SUPPORTED_IN_JSON_MODE", "message": "--json requires --blueprint; interactive picker is not available in JSON mode"}}"#)
            return
        }

        let planObject: Any
        if let bpArg = blueprintOpt {
            let resolved = resolvePath(bpArg)
            guard let data = FileManager.default.contents(atPath: resolved) else {
                throw CLIError(message: "workspace new: could not read '\(resolved)'")
            }
            guard
                let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let plan = file["plan"]
            else {
                throw CLIError(message: "workspace new: '\(resolved)' is not a valid blueprint file (missing 'plan' key)")
            }
            planObject = plan
        } else {
            planObject = try workspaceBlueprintPicker(client: client, jsonOutput: jsonOutput)
        }

        let payload = try client.sendV2(method: "workspace.apply", params: ["plan": planObject])
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let ref = (payload["workspaceRef"] as? String) ?? "?"
            let surfaceRefs = payload["surfaceRefs"] as? [String: String] ?? [:]
            let paneRefs = payload["paneRefs"] as? [String: String] ?? [:]
            let warnings = payload["warnings"] as? [String] ?? []
            let failures = payload["failures"] as? [[String: Any]] ?? []
            print("OK workspace=\(ref) surfaces=\(surfaceRefs.count) panes=\(paneRefs.count)")
            if !warnings.isEmpty {
                for w in warnings { print("  warning: \(w)") }
            }
            if !failures.isEmpty {
                for f in failures {
                    let code = (f["code"] as? String) ?? "?"
                    let step = (f["step"] as? String) ?? "?"
                    let msg = (f["message"] as? String) ?? ""
                    print("  failure: [\(code)] \(step): \(msg)")
                }
            }
        }
    }

    /// Fetches `workspace.list_blueprints`, prints a numbered picker, reads
    /// from stdin, and returns the selected plan object ready for
    /// `workspace.apply`. Throws `CLIError` on cancel ("q") or invalid input.
    private func workspaceBlueprintPicker(client: SocketClient, jsonOutput: Bool) throws -> Any {
        let cwd = FileManager.default.currentDirectoryPath
        let payload = try client.sendV2(method: "workspace.list_blueprints", params: ["cwd": cwd])
        guard let blueprints = payload["blueprints"] as? [[String: Any]], !blueprints.isEmpty else {
            throw CLIError(message: String(localized: "workspace.blueprint.picker.noBlueprints",
                defaultValue: "workspace new: no blueprints found. Use --blueprint <path> to apply one directly."))
        }

        let maxBracketLen = blueprints.map {
            let src = $0["source"] as? String ?? ""
            return localizedBlueprintSourceLabel(src).count + 2 // +2 for "[]"
        }.max() ?? 0

        for (i, bp) in blueprints.enumerated() {
            let source = bp["source"] as? String ?? ""
            let name = bp["name"] as? String ?? "(unnamed)"
            let desc = bp["description"] as? String
            let bracketLabel = "[\(localizedBlueprintSourceLabel(source))]"
            let label = bracketLabel.padding(toLength: maxBracketLen, withPad: " ", startingAt: 0)
            let num = String(i + 1).leftPadded(to: String(blueprints.count).count)
            if let d = desc {
                print("  \(label)  \(num)  \(name) — \(d)")
            } else {
                print("  \(label)  \(num)  \(name)")
            }
        }
        print("")
        print(String(localized: "workspace.blueprint.picker.prompt",
            defaultValue: "Enter number to apply, or q to cancel: "), terminator: "")
        fflush(stdout)

        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(message: "workspace new: cancelled")
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "q" || trimmed == "Q" {
            throw CLIError(message: "workspace new: cancelled")
        }
        guard let idx = Int(trimmed), idx >= 1, idx <= blueprints.count else {
            throw CLIError(message: "workspace new: invalid selection '\(trimmed)'")
        }

        let chosen = blueprints[idx - 1]
        guard let url = chosen["url"] as? String else {
            throw CLIError(message: "workspace new: selected blueprint has no url")
        }
        let resolved = resolvePath(url)
        guard let data = FileManager.default.contents(atPath: resolved) else {
            throw CLIError(message: "workspace new: could not read blueprint at '\(resolved)'")
        }
        guard
            let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plan = file["plan"]
        else {
            throw CLIError(message: "workspace new: '\(resolved)' is not a valid blueprint file (missing 'plan' key)")
        }
        return plan
    }

    /// Resolve a blueprint reference (file path or name) to a layout dict
    /// `{plan: ...}` suitable for `workspace.create`'s `layout` param.
    private func resolveBlueprintPlan(_ ref: String, client: SocketClient) throws -> [String: Any] {
        let pathToTry = resolvePath(ref)
        if FileManager.default.fileExists(atPath: pathToTry) {
            guard let data = FileManager.default.contents(atPath: pathToTry) else {
                throw CLIError(message: "new-workspace: could not read blueprint file '\(pathToTry)'")
            }
            guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CLIError(message: "new-workspace: blueprint file '\(pathToTry)' is not a valid JSON object")
            }
            guard let plan = file["plan"] else {
                throw CLIError(message: "new-workspace: blueprint file '\(pathToTry)' does not contain a 'plan' key")
            }
            return ["plan": plan]
        }
        // Not a direct path — search by name in the blueprint store.
        let cwd = FileManager.default.currentDirectoryPath
        let payload = try client.sendV2(method: "workspace.list_blueprints", params: ["cwd": cwd])
        let blueprints = payload["blueprints"] as? [[String: Any]] ?? []
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = blueprints.first(where: { ($0["name"] as? String) == trimmed }),
              let url = match["url"] as? String,
              let data = FileManager.default.contents(atPath: resolvePath(url)),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = file["plan"] else {
            throw CLIError(message: "new-workspace: blueprint '\(ref)' not found (tried as path and name)")
        }
        return ["plan": plan]
    }

    /// `c11 workspace export-blueprint --name <name> [--workspace <ref>]
    /// [--description <text>] [--out <path>] [--force]`. Captures the current
    /// (or named) workspace as a `WorkspaceBlueprintFile` JSON and writes it.
    /// Without `--out`, prints the default path written by the socket handler.
    /// `--force` allows overwriting an existing blueprint with the same name.
    private func runWorkspaceExportBlueprint(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceOpt, a1) = parseOption(args, name: "--workspace")
        let (nameOpt, a2) = parseOption(a1, name: "--name")
        let (descOpt, a3) = parseOption(a2, name: "--description")
        let (outOpt, a4) = parseOption(a3, name: "--out")
        let forceFlag = a4.contains("--force")
        let a5 = a4.filter { $0 != "--force" }
        if let unknown = a5.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace export-blueprint: unknown flag '\(unknown)'. Known flags: --workspace <ref>, --name <name>, --description <text>, --out <path>, --force")
        }
        guard let name = nameOpt else {
            throw CLIError(message: "workspace export-blueprint: --name <name> is required")
        }

        var params: [String: Any] = ["name": name]
        if let wsRaw = workspaceOpt {
            params["workspace_id"] = try resolveWorkspaceId(wsRaw, client: client)
        }
        if let desc = descOpt {
            params["description"] = desc
        }
        if forceFlag {
            params["force"] = true
        }

        let payload = try client.sendV2(method: "workspace.export_blueprint", params: params)
        var resolvedPath = (payload["path"] as? String) ?? "?"

        if let outRaw = outOpt {
            let src = URL(fileURLWithPath: resolvedPath)
            let dst = URL(fileURLWithPath: resolvePath(outRaw))
            do {
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: src, to: dst)
                resolvedPath = dst.path
            } catch {
                throw CLIError(message: "workspace export-blueprint: --out move failed: \(error)")
            }
        }

        if jsonOutput {
            var mutable = payload
            mutable["path"] = resolvedPath
            print(jsonString(mutable))
        } else {
            print("OK blueprint=\(name) path=\(resolvedPath)")
        }
    }

    // MARK: - CMUX-37 Phase 1: snapshot commands

    /// `c11 snapshot [--workspace <ref>] [--out <path>] [--all] [--json]`. Defaults
    /// to the current workspace (`$CMUX_WORKSPACE_ID`). Prints the resolved
    /// path + snapshot id. Backed by `snapshot.create` v2.
    ///
    /// `--out <path>` is honoured in the CLI process, not over the socket.
    /// The socket always writes to the default directory (B3: socket-initiated
    /// captures cannot choose their destination). After the socket returns,
    /// the CLI — running with the user's real FS permissions — moves the
    /// emitted file to the requested path.
    ///
    /// `--all` captures every open workspace. Mutually exclusive with
    /// `--workspace` and `--out`.
    private func runSnapshotCreate(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceOpt, afterWorkspace) = parseOption(args, name: "--workspace")
        let (outOpt, afterOut) = parseOption(afterWorkspace, name: "--out")
        let (afterAll, hasAll) = parseFlag(afterOut, name: "--all")
        if let unknown = afterAll.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "snapshot: unknown flag '\(unknown)'. Known flags: --workspace <ref>, --out <path>, --all")
        }

        if hasAll {
            if workspaceOpt != nil {
                throw CLIError(message: "snapshot: --all and --workspace are mutually exclusive")
            }
            if outOpt != nil {
                throw CLIError(message: "snapshot: --all and --out are mutually exclusive")
            }
            let payload = try client.sendV2(method: "snapshot.create", params: ["all": true])
            let snapshots = payload["snapshots"] as? [[String: Any]] ?? []
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            var anyFailure = false
            for snap in snapshots {
                let wsRef = (snap["workspace_ref"] as? String) ?? "?"
                if let err = snap["error"] as? String {
                    print("ERROR workspace=\(wsRef) reason=\(err)")
                    anyFailure = true
                } else {
                    let id = (snap["snapshot_id"] as? String) ?? "?"
                    let path = (snap["path"] as? String) ?? "?"
                    let count = (snap["surface_count"] as? Int) ?? 0
                    print("OK snapshot=\(id) surfaces=\(count) workspace=\(wsRef) path=\(path)")
                }
            }
            if anyFailure {
                throw CLIError(message: "snapshot --all: one or more workspaces failed to write")
            }
            return
        }

        var params: [String: Any] = [:]
        if let wsRaw = workspaceOpt {
            // Route through the standard resolver so `workspace:2`
            // (index-form ref), `workspace:<uuid>` (handle-form ref), bare
            // UUID, and bare integer index all work — matches what the
            // help text advertises (Trident I3). `parseUUIDFromRef` only
            // knew the UUID shapes.
            params["workspace_id"] = try resolveWorkspaceId(wsRaw, client: client)
        }
        let payload = try client.sendV2(method: "snapshot.create", params: params)
        let id = (payload["snapshot_id"] as? String) ?? "?"
        var resolvedPath = (payload["path"] as? String) ?? "?"
        let count = (payload["surface_count"] as? Int) ?? 0
        let wsRef = (payload["workspace_ref"] as? String) ?? "?"
        if let outRaw = outOpt {
            let src = URL(fileURLWithPath: resolvedPath)
            let dst = URL(fileURLWithPath: resolvePath(outRaw))
            do {
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: src, to: dst)
                resolvedPath = dst.path
            } catch {
                throw CLIError(message: "snapshot: --out move failed: \(error)")
            }
        }
        if jsonOutput {
            var mutable = payload
            mutable["path"] = resolvedPath
            print(jsonString(mutable))
            return
        }
        print("OK snapshot=\(id) surfaces=\(count) workspace=\(wsRef) path=\(resolvedPath)")
    }

    /// `c11 restore <snapshot-id-or-path> [--json]`. Reads
    /// `C11_SESSION_RESUME` / `CMUX_SESSION_RESUME` at this site only;
    /// when set (any non-empty non-"0"/"false" value) threads
    /// `{"restart_registry": "phase1"}` into the v2 call so cc terminals
    /// resume via `cc --resume <session-id>`.
    ///
    /// Path targets are resolved in the CLI process, not over the socket
    /// (B3: the socket never reads caller-supplied paths — it would turn
    /// the restore handler into an arbitrary-.json-parser primitive). The
    /// CLI reads the file with the user's real FS permissions, extracts
    /// the `snapshot_id`, plants the file under
    /// `~/.c11-snapshots/<snapshot_id>.json` if it isn't already there,
    /// and then submits `snapshot.restore` by id.
    private func runSnapshotRestore(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        // `--select` was advertised in help but silently ignored — the
        // socket focus policy (`CLAUDE.md` "Socket focus policy" section)
        // forbids `snapshot.restore` from stealing focus, and
        // `v2SnapshotRestore` cleared `options.select` unconditionally.
        // Per Trident I4 option (b), drop the promise rather than grant a
        // focus-intent exception. The flag is no longer accepted.
        //
        // I2: `--in-place` / `--replace` (aliases) replaces the current
        // workspace's content with the restored plan instead of creating
        // a fresh workspace. Without it, running `c11 restore <id>` twice
        // produces two duplicate workspaces.
        var inPlace = false
        var positional: [String] = []
        for arg in args {
            switch arg {
            case "--in-place", "--replace":
                inPlace = true
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "restore: unknown flag '\(arg)'. Known flags: --in-place / --replace")
                }
                positional.append(arg)
            }
        }
        guard let target = positional.first else {
            throw CLIError(message: "restore: missing snapshot id or path")
        }
        if positional.count > 1 {
            throw CLIError(message: "restore: unexpected trailing argument '\(positional[1])'")
        }
        var params: [String: Any] = [:]
        // Path-like targets (absolute / `~` / extension `.json`) get
        // resolved in the CLI. Everything else is treated as a snapshot
        // id and submitted as-is; the handler's traversal guard catches
        // any shenanigans there.
        if target.hasPrefix("/")
            || target.lowercased().hasSuffix(".json")
            || target.hasPrefix("~")
            || target.contains("/") {
            let resolvedPath = resolvePath(target)
            let snapshotId = try importSnapshotFileForRestore(pathOnDisk: resolvedPath)
            params["snapshot_id"] = snapshotId
        } else {
            params["snapshot_id"] = target
        }
        // Env gate: mirrored by `mirrorC11CmuxEnv()` so either variable works.
        let env = ProcessInfo.processInfo.environment
        let raw = env["C11_SESSION_RESUME"] ?? env["CMUX_SESSION_RESUME"]
        if let raw, isTruthyFlag(raw) {
            params["restart_registry"] = "phase1"
        }
        if inPlace {
            params["in_place"] = true
            // Resolve the target workspace. Destructive commands must
            // prefer the caller's own workspace (CMUX_WORKSPACE_ID /
            // C11_WORKSPACE_ID) per the socket focus policy in CLAUDE.md:
            // a background agent running `c11 restore --in-place` should
            // replace its own workspace, not whatever the operator
            // currently has selected. Only when the CLI is invoked
            // outside a c11 surface (no env) do we fall back to
            // `workspace.current`.
            let callerWs = env["CMUX_WORKSPACE_ID"] ?? env["C11_WORKSPACE_ID"]
            if let trimmed = callerWs?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty,
               UUID(uuidString: trimmed) != nil {
                params["target_workspace_id"] = trimmed
            } else {
                let currentPayload = try client.sendV2(method: "workspace.current", params: [:])
                if let wsId = currentPayload["workspace_id"] as? String,
                   UUID(uuidString: wsId) != nil {
                    params["target_workspace_id"] = wsId
                } else if let ref = currentPayload["workspace_ref"] as? String,
                          let uuid = parseUUIDFromRef(ref) {
                    params["target_workspace_id"] = uuid.uuidString
                } else {
                    throw CLIError(message: "restore: --in-place could not resolve the target workspace (set CMUX_WORKSPACE_ID or invoke from a c11 surface)")
                }
            }
        }
        let payload = try client.sendV2(method: "snapshot.restore", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let ref = (payload["workspaceRef"] as? String) ?? "?"
        let surfaceRefs = payload["surfaceRefs"] as? [String: String] ?? [:]
        let paneRefs = payload["paneRefs"] as? [String: String] ?? [:]
        let warnings = payload["warnings"] as? [String] ?? []
        let failures = payload["failures"] as? [[String: Any]] ?? []
        print("OK workspace=\(ref) surfaces=\(surfaceRefs.count) panes=\(paneRefs.count)")
        if !warnings.isEmpty {
            print("warnings: \(warnings.count)")
            for w in warnings { print("  - \(w)") }
        }
        if !failures.isEmpty {
            print("failures: \(failures.count)")
            for f in failures {
                let code = (f["code"] as? String) ?? "?"
                let step = (f["step"] as? String) ?? "?"
                let msg = (f["message"] as? String) ?? ""
                print("  - [\(code)] \(step): \(msg)")
            }
        }
    }

    /// Read a snapshot file at `pathOnDisk`, extract `snapshot_id`, and
    /// ensure a copy exists under `~/.c11-snapshots/<snapshot_id>.json` so
    /// the v2 handler's id-based lookup can find it. Returns the
    /// snapshot_id.
    ///
    /// Exists because the socket rejects caller-supplied paths (B3). The
    /// CLI holds the user's real FS permissions, so reading and copying
    /// the file here is safe in a way reading via the socket is not.
    private func importSnapshotFileForRestore(pathOnDisk: String) throws -> String {
        let srcURL = URL(fileURLWithPath: pathOnDisk)
        let data: Data
        do {
            data = try Data(contentsOf: srcURL)
        } catch {
            throw CLIError(message: "restore: failed to read '\(pathOnDisk)': \(error)")
        }
        let snapshotId: String
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any],
                  let id = dict["snapshot_id"] as? String,
                  !id.isEmpty else {
                throw CLIError(message: "restore: file '\(pathOnDisk)' is not a valid snapshot envelope (missing snapshot_id)")
            }
            snapshotId = id
        } catch let err as CLIError {
            throw err
        } catch {
            throw CLIError(message: "restore: file '\(pathOnDisk)' is not valid JSON: \(error)")
        }
        // Reject traversal-shaped ids before we touch disk — matches the
        // grammar the v2 handler enforces on the other side.
        let idRange = NSRange(location: 0, length: (snapshotId as NSString).length)
        let safePattern = try NSRegularExpression(
            pattern: "^[A-Za-z0-9_-]{1,128}$",
            options: []
        )
        if safePattern.firstMatch(in: snapshotId, options: [], range: idRange) == nil {
            throw CLIError(message: "restore: snapshot_id '\(snapshotId)' is not a safe filename stem")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent(".c11-snapshots", isDirectory: true)
        let destURL = defaultDir.appendingPathComponent("\(snapshotId).json")
        // If the user passed in a path that already is the default
        // location, there's nothing to copy.
        if destURL.standardizedFileURL.path == srcURL.standardizedFileURL.path {
            return snapshotId
        }
        do {
            try FileManager.default.createDirectory(
                at: defaultDir,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: destURL)
        } catch {
            throw CLIError(message: "restore: failed to stage '\(pathOnDisk)' into ~/.c11-snapshots/: \(error)")
        }
        return snapshotId
    }

    /// `c11 list-snapshots [--json]`. Columns:
    /// SNAPSHOT_ID, CREATED_AT, WORKSPACE_TITLE, SURFACES, ORIGIN, SOURCE.
    ///
    /// `--json` is accepted both as a global pre-subcommand flag (handled
    /// by the main parser and threaded in via `jsonOutput`) and as a
    /// subcommand-local flag. The help text advertises
    /// `c11 list-snapshots --json`; callers writing that literally should
    /// not have to know about the global/local distinction.
    private func runListSnapshots(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var localJson = false
        for arg in args {
            switch arg {
            case "--json":
                localJson = true
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "list-snapshots: unknown flag '\(arg)'. Known flags: --json")
                }
                throw CLIError(message: "list-snapshots: unexpected argument '\(arg)'")
            }
        }
        let wantJson = jsonOutput || localJson
        let payload = try client.sendV2(method: "snapshot.list", params: [:])
        guard let snapshotsAny = payload["snapshots"] as? [[String: Any]] else {
            if wantJson {
                print(jsonString(payload))
                return
            }
            print("no snapshots")
            return
        }
        if wantJson {
            print(jsonString(payload))
            return
        }
        if snapshotsAny.isEmpty {
            print("no snapshots")
            return
        }
        // Format fixed-width columns. Titles are free-form so we truncate
        // long ones rather than bloat the row. `%s` does not work with
        // Swift `String` (only with `CVarArg`-bridged `NSString`), so pad
        // natively via `String.padding(toLength:withPad:startingAt:)` —
        // emits garbage or crashes with the printf-style form (Trident I5).
        let rows: [(String, String, String, String, String, String)] = snapshotsAny.map { entry in
            let id = (entry["snapshot_id"] as? String) ?? "?"
            let created = (entry["created_at"] as? String) ?? "?"
            let origin = (entry["origin"] as? String) ?? "?"
            let source = (entry["source"] as? String) ?? "current"
            // I8: unreadable rows carry a `{"status": "unreadable", "reason": "..."}`
            // payload under `readability`. Show `UNREADABLE` in the title
            // column and `?` in the surfaces column so operators can see
            // the bad file without losing sight of the healthy rows. The
            // reason is preserved on the wire (`--json`) for machine
            // consumers.
            let readability = entry["readability"] as? [String: Any]
            if (readability?["status"] as? String) == "unreadable" {
                let unreadableLabel = String(localized: "cli.listSnapshots.column.unreadable",
                                             defaultValue: "UNREADABLE")
                return (id, created, truncate(unreadableLabel, max: 32), "?", origin, source)
            }
            let title = (entry["workspace_title"] as? String) ?? "(no title)"
            let surfaces = (entry["surface_count"] as? Int).map(String.init) ?? "?"
            return (id, created, truncate(title, max: 32), surfaces, origin, source)
        }
        func pad(_ s: String, _ width: Int) -> String {
            if s.count >= width { return s }
            return s + String(repeating: " ", count: width - s.count)
        }
        print(
            pad("SNAPSHOT_ID", 26) + "  "
            + pad("CREATED_AT", 24) + "  "
            + pad("WORKSPACE_TITLE", 32) + "  "
            + pad("SURFACES", 8) + "  "
            + pad("ORIGIN", 12) + "  "
            + pad("SOURCE", 8)
        )
        for r in rows {
            print(
                pad(r.0, 26) + "  "
                + pad(r.1, 24) + "  "
                + pad(r.2, 32) + "  "
                + pad(r.3, 8) + "  "
                + pad(r.4, 12) + "  "
                + pad(r.5, 8)
            )
        }
        // I8: after the main table, show the reason for each unreadable
        // row so operators have enough to investigate (the path and the
        // parse error). The tabular form keeps `UNREADABLE` in the title
        // column; the per-row reason goes here.
        let unreadables = snapshotsAny.compactMap { entry -> (String, String, String)? in
            guard let readability = entry["readability"] as? [String: Any],
                  (readability["status"] as? String) == "unreadable" else { return nil }
            let id = (entry["snapshot_id"] as? String) ?? "?"
            let path = (entry["path"] as? String) ?? "?"
            let reason = (readability["reason"] as? String) ?? ""
            return (id, path, reason)
        }
        if !unreadables.isEmpty {
            let prefix = String(localized: "cli.listSnapshots.unreadable.prefix",
                                defaultValue: "unreadable: ")
            print("")
            for (id, path, reason) in unreadables {
                print("  \(prefix)\(id) [\(path)]: \(reason)")
            }
        }
    }

    /// `parseUUIDFromRef("workspace:abc…")` → UUID. Also accepts a bare
    /// UUID string. Returns nil on anything else.
    private func parseUUIDFromRef(_ raw: String) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) { return uuid }
        if let colon = trimmed.firstIndex(of: ":") {
            let suffix = String(trimmed[trimmed.index(after: colon)...])
            return UUID(uuidString: suffix)
        }
        return nil
    }

    /// Truthiness rule used by `C11_SESSION_RESUME`: any non-empty value
    /// that isn't `"0"` or `"false"` (case-insensitive) counts as on.
    private func isTruthyFlag(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty { return false }
        return v != "0" && v != "false" && v != "no" && v != "off"
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<idx]) + "…"
    }

    private func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    private func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown Commands

    private func runMarkdownCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        // Parse routing flags
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--surface")
        let (paneOpt, argsAfterPane) = parseOption(argsAfterSurface, name: "--pane")
        args = argsAfterPane

        // Determine subcommand. Explicit "open" is supported, otherwise treat
        // a single positional argument as shorthand path.
        let subArgs: [String]
        if let first = args.first, first.lowercased() == "open" {
            subArgs = Array(args.dropFirst())
        } else if args.count == 1, let first = args.first, !first.hasPrefix("-") {
            subArgs = [first]
        } else {
            // Allow path-like first tokens (e.g. plan.md) with trailing args
            // so we can surface specific trailing-arg/flag errors below.
            if let first = args.first, first.hasPrefix("-") {
                throw CLIError(
                    message:
                        "markdown open: unknown flag '\(first)'. Usage: c11 markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]"
                )
            } else if let first = args.first, looksLikePath(first) || first.contains(".") {
                subArgs = args
            } else if let first = args.first {
                throw CLIError(message: "Unknown markdown subcommand: \(first). Usage: c11 markdown open <path>")
            } else {
                subArgs = []
            }
        }

        guard let rawPath = subArgs.first, !rawPath.isEmpty else {
            throw CLIError(message: "markdown open requires a file path. Usage: c11 markdown open <path>")
        }
        let trailingArgs = Array(subArgs.dropFirst())
        if let unknownFlag = trailingArgs.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(
                message:
                    "markdown open: unknown flag '\(unknownFlag)'. Usage: c11 markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]"
            )
        }
        if let extraArg = trailingArgs.first {
            throw CLIError(
                message:
                    "markdown open: unexpected argument '\(extraArg)'. Usage: c11 markdown open <path> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]"
            )
        }

        let absolutePath = resolvePath(rawPath)

        // Build params
        var params: [String: Any] = ["path": absolutePath]
        if let surfaceRaw = surfaceOpt {
            if let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = surface
            }
        }
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        if let workspaceRaw {
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
        }
        if let windowRaw = windowOpt {
            if let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
        }
        if let paneRaw = paneOpt {
            let workspaceHandle = params["workspace_id"] as? String
            if let pane = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle) {
                params["pane_id"] = pane
            }
        }

        let payload = try client.sendV2(method: "markdown.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let filePath = (payload["path"] as? String) ?? absolutePath
            print("OK surface=\(surfaceText) pane=\(paneText) path=\(filePath)")
        }
    }

    // MARK: - M6 markdown.get_content

    private func runMarkdownGetContentCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (surfaceOpt, _) = parseOption(commandArgs, name: "--surface")
        let surfaceArg = surfaceOpt ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let surfaceArg else {
            throw CLIError(message: "markdown-content requires --surface <handle> (or CMUX_SURFACE_ID env)")
        }
        guard let surface = try normalizeSurfaceHandle(surfaceArg, client: client) else {
            throw CLIError(message: "markdown-content: invalid surface handle")
        }
        let params: [String: Any] = ["surface_id": surface]
        let payload = try client.sendV2(method: "markdown.get_content", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        if (payload["truncated"] as? Bool) == true {
            let reason = (payload["reason"] as? String) ?? "truncated"
            print("TRUNCATED \(reason)")
            return
        }
        if let content = payload["content"] as? String {
            print(content)
        }
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    private func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    /// Open a path in cmux by creating a new workspace with the given directory.
    /// Launches the app if it isn't already running.
    private func openPath(_ path: String, socketPath: String) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            // It's a file; use its parent directory
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        // Try connecting to the socket. If it fails, launch the app and retry.
        let client = SocketClient(path: socketPath)
        if (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            defer { launchedClient.close() }
            let params: [String: Any] = ["cwd": directory]
            let response = try launchedClient.sendV2(method: "workspace.create", params: params)
            let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            if !wsRef.isEmpty {
                print("OK \(wsRef)")
            }
            try activateApp()
            return
        }
        defer { client.close() }

        let params: [String: Any] = ["cwd": directory]
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        // Bring the app to front
        try activateApp()
    }

    private func runFeedback(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (emailOpt, rem0) = parseOption(commandArgs, name: "--email")
        let (bodyOpt, rem1) = parseOption(rem0, name: "--body")
        let (imagePaths, rem2) = parseRepeatedOption(rem1, name: "--image")
        let remaining = rem2.filter { $0 != "--" }

        if let unknown = remaining.first {
            throw CLIError(message: "feedback: unknown flag '\(unknown)'. Known flags: --email <email>, --body <text>, --image <path>")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        if emailOpt == nil && bodyOpt == nil && imagePaths.isEmpty {
            var params: [String: Any] = [:]
            let env = ProcessInfo.processInfo.environment
            if let workspaceId = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
                params["activate"] = false
            } else {
                params["activate"] = true
            }
            let response = try client.sendV2(method: "feedback.open", params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print("OK")
            }
            return
        }

        guard let email = emailOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            throw CLIError(message: "feedback requires --email <email> when sending feedback")
        }
        guard let body = bodyOpt, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CLIError(message: "feedback requires --body <text> when sending feedback")
        }

        let resolvedImages = imagePaths.map(resolvePath)
        let response = try client.sendV2(method: "feedback.submit", params: [
            "email": email,
            "body": body,
            "image_paths": resolvedImages,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "settings.open", params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    private func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    private func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }
    }

    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "c11"]
        try process.run()
        process.waitUntilExit()
    }

    private func activateApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "c11"]
        try process.run()
        process.waitUntilExit()
    }

    private func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    private func sendV1Command(_ command: String, client: SocketClient) throws -> String {
        let response = try client.send(command: command)
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: response)
        }
        return response
    }

    private func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    private func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
    }

    private func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    private func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "window.current")
            return (current["window_ref"] as? String) ?? (current["window_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid window handle: \(trimmed) (expected UUID, ref like window:1, or index)")
        }

        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        for item in windows where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Window index not found")
    }

    private func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "workspace.current")
            return (current["workspace_ref"] as? String) ?? (current["workspace_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid workspace handle: \(trimmed) (expected UUID, ref like workspace:1, or index)")
        }

        if let windowHandle {
            // Caller scoped to a specific window — list only that window's workspaces.
            let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowHandle])
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == wantedIndex {
                return (item["ref"] as? String) ?? (item["id"] as? String)
            }
        } else {
            // No window filter: scan all windows so --workspace 1 finds the correct workspace
            // even if it lives in a different window than the socket's default context.
            let windowsPayload = try client.sendV2(method: "window.list")
            let windows = windowsPayload["windows"] as? [[String: Any]] ?? []
            for window in windows {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where intFromAny(item["index"]) == wantedIndex {
                    return (item["ref"] as? String) ?? (item["id"] as? String)
                }
            }
        }
        throw CLIError(message: "Workspace index not found")
    }

    private func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["pane_ref"] as? String) ?? (focused["pane_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid pane handle: \(trimmed) (expected UUID, ref like pane:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "pane.list", params: params)
        let items = listed["panes"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Pane index not found")
    }

    private func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_ref"] as? String) ?? (focused["surface_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid surface handle: \(trimmed) (expected UUID, ref like surface:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let items = listed["surfaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Surface index not found")
    }

    private func canonicalSurfaceHandleFromTabInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "tab",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    private func normalizeTabHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromTabInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            allowFocused: false
        )
    }

    private func displayTabHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "surface",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "tab:\(ordinal)"
    }

    private func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["tab_id"] as? String) ?? (payload["surface_id"] as? String)
        let refRaw = (payload["tab_ref"] as? String) ?? (payload["surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    private func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

    private func debugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func debugBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return parseBoolString(string)
        }
        return nil
    }

    private func debugFlag(_ value: Any?) -> String {
        guard let bool = debugBool(value) else { return "nil" }
        return bool ? "1" : "0"
    }

    private func formatDebugRect(_ value: Any?) -> String? {
        guard let rect = value as? [String: Any],
              let x = doubleFromAny(rect["x"]),
              let y = doubleFromAny(rect["y"]),
              let width = doubleFromAny(rect["width"]),
              let height = doubleFromAny(rect["height"]) else {
            return nil
        }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", x, y, width, height)
    }

    private func formatDebugPorts(_ value: Any?) -> String {
        guard let array = value as? [Any], !array.isEmpty else { return "[]" }
        let ports = array
            .compactMap { intFromAny($0) }
            .map(String.init)
        return ports.isEmpty ? "[]" : ports.joined(separator: ",")
    }

    private func formatDebugList(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        let items = array.compactMap { item -> String? in
            if let string = item as? String {
                return string
            }
            return debugString(item)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: ">")
    }

    private func formatDebugAge(_ value: Any?) -> String? {
        guard let seconds = doubleFromAny(value) else { return nil }
        return String(format: "%.3fs", seconds)
    }

    private func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        guard !terminals.isEmpty else { return "No terminal surfaces" }

        return terminals.map { item in
            let index = intFromAny(item["index"]) ?? 0
            let surface = formatHandle(item, kind: "surface", idFormat: idFormat) ?? "?"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "nil"
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "nil"
            let pane = formatHandle(item, kind: "pane", idFormat: idFormat) ?? "nil"
            let bonsplitTab = debugString(item["bonsplit_tab_id"]) ?? "nil"
            let lastKnownWorkspace = debugString(item["last_known_workspace_ref"]) ?? debugString(item["last_known_workspace_id"]) ?? "nil"
            let titleSuffix: String = {
                guard let title = debugString(item["surface_title"]), !title.isEmpty else { return "" }
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return " \"\(escaped)\""
            }()
            let branchLabel: String = {
                guard let branch = debugString(item["git_branch"]), !branch.isEmpty else { return "nil" }
                return debugBool(item["git_dirty"]) == true ? "\(branch)*" : branch
            }()
            let teardownLabel: String = {
                guard debugBool(item["teardown_requested"]) == true else { return "nil" }
                let reason = debugString(item["teardown_requested_reason"]) ?? "requested"
                let age = formatDebugAge(item["teardown_requested_age_seconds"]) ?? "unknown"
                return "\(reason)@\(age)"
            }()
            let portalHostLabel: String = {
                let hostId = debugString(item["portal_host_id"]) ?? "nil"
                let area = doubleFromAny(item["portal_host_area"]).map { String(format: "%.1f", $0) } ?? "nil"
                let inWindow = debugFlag(item["portal_host_in_window"])
                return "\(hostId)/win=\(inWindow)/area=\(area)"
            }()
            let windowMetaLabel: String = {
                let title = debugString(item["window_title"]) ?? "nil"
                let windowClass = debugString(item["window_class"]) ?? "nil"
                let controllerClass = debugString(item["window_controller_class"]) ?? "nil"
                let delegateClass = debugString(item["window_delegate_class"]) ?? "nil"
                return "title=\(title) class=\(windowClass) controller=\(controllerClass) delegate=\(delegateClass)"
            }()

            let line1 =
                "[\(index)] \(surface)\(titleSuffix) " +
                "mapped=\(debugFlag(item["mapped"])) tree=\(debugFlag(item["tree_visible"])) " +
                "window=\(window) workspace=\(workspace) pane=\(pane) bonsplitTab=\(bonsplitTab) " +
                "ctx=\(debugString(item["surface_context"]) ?? "nil")"

            let line2 =
                "    runtime=\(debugFlag(item["runtime_surface_ready"])) " +
                "focused=\(debugFlag(item["surface_focused"])) " +
                "selected=\(debugFlag(item["surface_selected_in_pane"])) " +
                "pinned=\(debugFlag(item["surface_pinned"])) " +
                "terminal=\(debugString(item["terminal_object_ptr"]) ?? "nil") " +
                "hosted=\(debugString(item["hosted_view_ptr"]) ?? "nil") " +
                "ghostty=\(debugString(item["ghostty_surface_ptr"]) ?? "nil") " +
                "portal=\(debugString(item["portal_binding_state"]) ?? "nil")#\(debugString(item["portal_binding_generation"]) ?? "nil") " +
                "teardown=\(teardownLabel)"

            let line3 =
                "    tty=\(debugString(item["tty"]) ?? "nil") " +
                "cwd=\(debugString(item["current_directory"]) ?? debugString(item["requested_working_directory"]) ?? "nil") " +
                "branch=\(branchLabel) " +
                "ports=\(formatDebugPorts(item["listening_ports"])) " +
                "visible=\(debugFlag(item["hosted_view_visible_in_ui"])) " +
                "inWindow=\(debugFlag(item["hosted_view_in_window"])) " +
                "superview=\(debugFlag(item["hosted_view_has_superview"])) " +
                "hidden=\(debugFlag(item["hosted_view_hidden"])) " +
                "ancestorHidden=\(debugFlag(item["hosted_view_hidden_or_ancestor_hidden"])) " +
                "firstResponder=\(debugFlag(item["surface_view_first_responder"])) " +
                "windowNum=\(debugString(item["window_number"]) ?? "nil") " +
                "windowKey=\(debugFlag(item["window_key"])) " +
                "frame=\(formatDebugRect(item["hosted_view_frame_in_window"]) ?? "nil")"

            let line4 =
                "    created=\(formatDebugAge(item["surface_age_seconds"]) ?? "nil") " +
                "runtimeCreated=\(formatDebugAge(item["runtime_surface_age_seconds"]) ?? "nil") " +
                "lastWorkspace=\(lastKnownWorkspace) " +
                "initialCommand=\(debugString(item["initial_command"]) ?? "nil") " +
                "portalHost=\(portalHostLabel)"

            let line5 =
                "    window=\(windowMetaLabel) " +
                "chain=\(formatDebugList(item["hosted_view_superview_chain"]) ?? "nil")"

            return [line1, line2, line3, line4, line5].joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func runMoveSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
        guard let surfaceRaw else {
            throw CLIError(message: "move-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let windowRaw = optionValue(commandArgs, name: "--window")
        let paneRaw = optionValue(commandArgs, name: "--pane")
        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, allowFocused: false)
        let paneHandle = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle)
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let paneHandle { params["pane_id"] = paneHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }

        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let focusRaw = optionValue(commandArgs, name: "--focus") {
            guard let focus = parseBoolString(focusRaw) else {
                throw CLIError(message: "--focus must be true|false")
            }
            params["focus"] = focus
        }

        let payload = try client.sendV2(method: "surface.move", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? commandArgs.first
        guard let surfaceRaw else {
            throw CLIError(message: "reorder-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }

        let payload = try client.sendV2(method: "surface.reorder", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runReorderWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? commandArgs.first
        guard let workspaceRaw else {
            throw CLIError(message: "reorder-workspace requires --workspace <id|ref|index>")
        }

        let windowRaw = optionValue(commandArgs, name: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-workspace")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-workspace")
        let beforeHandle = try normalizeWorkspaceHandle(beforeRaw, client: client, windowHandle: windowHandle)
        let afterHandle = try normalizeWorkspaceHandle(afterRaw, client: client, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_workspace_id"] = beforeHandle }
        if let afterHandle { params["after_workspace_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }

        let payload = try client.sendV2(method: "workspace.reorder", params: params)
        let summary = "OK workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown") index=\(payload["index"] ?? "?")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")

        var positional = rem2
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }

        let payload = try client.sendV2(method: "workspace.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runTabAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")

        var positional = rem5
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "tab-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tab-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let tabArg = tabOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowOverride == nil
                ? (ProcessInfo.processInfo.environment["CMUX_TAB_ID"] ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
                : nil)

        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        let allowFocusedFallback = (workspaceId == nil)
        let surfaceId = try normalizeTabHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "tab-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["surface_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let payload = try client.sendV2(method: "tab.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let tabHandle = formatTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("tab=\(tabHandle)")
        }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let created = formatCreatedTabHandle(payload, idFormat: idFormat) {
            summaryParts.append("created=\(created)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    private func runRenameTab(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")

        if rem3.contains("--action") {
            throw CLIError(message: "rename-tab does not accept --action (it always performs rename)")
        }
        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-tab: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem3
            .dropFirst(rem3.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-tab requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let tabOpt {
            forwarded += ["--tab", tabOpt]
        } else if let surfaceOpt {
            forwarded += ["--surface", surfaceOpt]
        }

        try runTabAction(
            commandArgs: forwarded,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }

    // MARK: - M7: Surface title bar CLI

    private func runSetTitle(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        try runSetTitleBarText(
            key: "title",
            commandArgs: commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    private func runSetDescription(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        try runSetTitleBarText(
            key: "description",
            commandArgs: commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    private func runSetTitleBarText(
        key: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let commandName = key == "title" ? "set-title" : "set-description"

        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (surfaceOpt, rem1) = parseOption(rem0, name: "--surface")
        let (fromFileOpt, rem2) = parseOption(rem1, name: "--from-file")
        let (sourceOpt, rem3) = parseOption(rem2, name: "--source")

        var autoExpand = true
        var remaining: [String] = []
        for arg in rem3 {
            if arg == "--auto-expand=false" {
                autoExpand = false
            } else if arg == "--auto-expand=true" {
                autoExpand = true
            } else {
                remaining.append(arg)
            }
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "\(commandName): unknown flag '\(unknown)'")
        }

        let value: String
        if let fromFileOpt {
            value = try readFromFileArgument(fromFileOpt, commandName: commandName)
        } else {
            let positional = remaining
                .dropFirst(remaining.first == "--" ? 1 : 0)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value = positional
        }

        if key == "title" && value.isEmpty {
            throw CLIError(message: "missing_title: \(commandName) requires a non-empty title (or --from-file <path>). To clear: c11 clear-metadata --key title")
        }

        let surfaceRaw = surfaceOpt ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        let workspaceRaw = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let workspaceId = try resolveWorkspaceId(workspaceRaw, client: client)
        let surfaceId = try resolveSurfaceId(surfaceRaw, workspaceId: workspaceId, client: client)

        let source = sourceOpt?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "explicit"

        var params: [String: Any] = [
            "surface_id": surfaceId,
            "workspace_id": workspaceId,
            "mode": "merge",
            "source": source,
            "metadata": [key: value]
        ]
        if key == "description" && !autoExpand {
            params["auto_expand"] = false
        }

        let payload = try client.sendV2(method: "surface.set_metadata", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let applied = (payload["applied"] as? [String: Any])?[key] as? Bool ?? false
            let reason = (payload["reasons"] as? [String: Any])?[key] as? String
            if applied {
                print("OK \(key) applied=true source=\(source)")
            } else {
                let reasonText = reason ?? "unknown"
                FileHandle.standardError.write(Data("Error: \(key) applied=false reason=\(reasonText)\n".utf8))
                exit(1)
            }
        }
    }

    private func runGetTitleBarState(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (surfaceOpt, remaining) = parseOption(rem0, name: "--surface")

        if let unknown = remaining.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "get-titlebar-state: unknown flag '\(unknown)'")
        }

        let surfaceRaw = surfaceOpt ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        let workspaceRaw = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let workspaceId = try resolveWorkspaceId(workspaceRaw, client: client)
        let surfaceId = try resolveSurfaceId(surfaceRaw, workspaceId: workspaceId, client: client)

        let params: [String: Any] = [
            "surface_id": surfaceId,
            "workspace_id": workspaceId
        ]
        let payload = try client.sendV2(method: "surface.get_titlebar_state", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceStr = (payload["surface_id"] as? String) ?? surfaceId
            var lines: [String] = ["surface=\(surfaceStr)"]
            if let title = payload["title"] as? String {
                let src = (payload["title_source"] as? String) ?? "?"
                lines.append("title=\(title)   [\(src)]")
            }
            if let desc = payload["description"] as? String {
                let src = (payload["description_source"] as? String) ?? "?"
                lines.append("description=\(desc)   [\(src)]")
            }
            let collapsed = (payload["collapsed"] as? Bool) ?? true
            let visible = (payload["visible"] as? Bool) ?? true
            lines.append("collapsed=\(collapsed)  visible=\(visible)")
            if let sidebar = payload["sidebar_label"] as? String {
                lines.append("sidebar_label=\(sidebar)")
            }
            print(lines.joined(separator: "\n"))
        }
    }

    private func readFromFileArgument(_ path: String, commandName: String) throws -> String {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = URL(fileURLWithPath: resolvePath(path))
        do {
            let data = try Data(contentsOf: url)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CLIError(message: "\(commandName): unable to read --from-file '\(path)': \(error)")
        }
    }

    struct SSHCommandOptions {
        let destination: String
        let port: Int?
        let identityFile: String?
        let workspaceName: String?
        let sshOptions: [String]
        let extraArguments: [String]
        let localSocketPath: String
        let remoteRelayPort: Int
    }

    private struct RemoteDaemonManifest: Decodable {
        struct Entry: Decodable {
            let goOS: String
            let goArch: String
            let assetName: String
            let downloadURL: String
            let sha256: String
        }

        let schemaVersion: Int
        let appVersion: String
        let releaseTag: String
        let releaseURL: String
        let checksumsAssetName: String
        let checksumsURL: String
        let entries: [Entry]

        func entry(goOS: String, goArch: String) -> Entry? {
            entries.first { $0.goOS == goOS && $0.goArch == goArch }
        }
    }

    private func generateRemoteRelayPort() -> Int {
        // Random port in the ephemeral range (49152-65535)
        Int.random(in: 49152...65535)
    }

    private func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CLIError(message: "failed to generate SSH relay credential")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func runSSH(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let sshStartedAt = Date()
        // Use the socket path from this invocation (supports --socket overrides).
        let localSocketPath = client.socketPath
        let remoteRelayPort = generateRemoteRelayPort()
        let relayID = UUID().uuidString.lowercased()
        let relayToken = try randomHex(byteCount: 32)
        let sshOptions = try parseSSHCommandOptions(commandArgs, localSocketPath: localSocketPath, remoteRelayPort: remoteRelayPort)
        func logSSHTiming(_ stage: String, extra: String = "") {
            let elapsedMs = Int(Date().timeIntervalSince(sshStartedAt) * 1000)
            let suffix = extra.isEmpty ? "" : " \(extra)"
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "stage=\(stage) elapsedMs=\(elapsedMs)\(suffix)"
            )
        }

        logSSHTiming("parsed")
        let terminfoSource = localXtermGhosttyTerminfoSource()
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "stage=terminfo elapsedMs=0 mode=deferred term=xterm-256color " +
            "source=\(terminfoSource == nil ? 0 : 1)"
        )
        let shellFeaturesValue = scopedGhosttyShellFeaturesValue()
        let initialSSHCommand = buildSSHCommandText(sshOptions)
        let remoteTerminalBootstrapScript = sshOptions.extraArguments.isEmpty
            ? buildInteractiveRemoteShellScript(
                remoteRelayPort: sshOptions.remoteRelayPort,
                shellFeatures: shellFeaturesValue,
                terminfoSource: terminfoSource
            )
            : nil
        let remoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript
        )
        let initialSSHStartupCommand = try buildSSHStartupCommand(
            sshCommand: initialSSHCommand,
            shellFeatures: "",
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let remoteTerminalSSHStartupCommand = try buildSSHStartupCommand(
            sshCommand: remoteTerminalSSHCommand,
            shellFeatures: shellFeaturesValue,
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let remoteSSHOptions = effectiveSSHOptions(
            sshOptions.sshOptions,
            remoteRelayPort: sshOptions.remoteRelayPort
        )

        cliDebugLog(
            "cli.ssh.start target=\(sshOptions.destination) port=\(sshOptions.port.map(String.init) ?? "nil") " +
            "relayPort=\(sshOptions.remoteRelayPort) localSocket=\(sshOptions.localSocketPath) " +
            "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
            "workspaceName=\(sshOptions.workspaceName?.replacingOccurrences(of: " ", with: "_") ?? "nil") " +
            "extraArgs=\(sshOptions.extraArguments.count)"
        )

        let workspaceCreateParams: [String: Any] = [
            "initial_command": initialSSHStartupCommand,
        ]

        let workspaceCreateStartedAt = Date()
        let workspaceCreate = try client.sendV2(method: "workspace.create", params: workspaceCreateParams)
        guard let workspaceId = workspaceCreate["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        let workspaceWindowId = (workspaceCreate["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cliDebugLog(
            "cli.ssh.workspace.created workspace=\(String(workspaceId.prefix(8))) " +
            "window=\(workspaceWindowId.map { String($0.prefix(8)) } ?? "nil")"
        )
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "workspace=\(String(workspaceId.prefix(8))) stage=workspace.create elapsedMs=\(Int(Date().timeIntervalSince(workspaceCreateStartedAt) * 1000))"
        )
        let configuredPayload: [String: Any]
        do {
            if let workspaceName = sshOptions.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceName.isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": workspaceName,
                ])
            }

            var configureParams: [String: Any] = [
                "workspace_id": workspaceId,
                "destination": sshOptions.destination,
                "auto_connect": true,
            ]
            if let port = sshOptions.port {
                configureParams["port"] = port
            }
            if let identityFile = normalizedSSHIdentityPath(sshOptions.identityFile) {
                configureParams["identity_file"] = identityFile
            }
            if !remoteSSHOptions.isEmpty {
                configureParams["ssh_options"] = remoteSSHOptions
            }
            if sshOptions.remoteRelayPort > 0 {
                configureParams["relay_port"] = sshOptions.remoteRelayPort
                configureParams["relay_id"] = relayID
                configureParams["relay_token"] = relayToken
                configureParams["local_socket_path"] = sshOptions.localSocketPath
            }
            configureParams["terminal_startup_command"] = remoteTerminalSSHStartupCommand

            cliDebugLog(
                "cli.ssh.remote.configure workspace=\(String(workspaceId.prefix(8))) " +
                "target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
                "sshOptions=\(remoteSSHOptions.joined(separator: "|"))"
            )
            let configureStartedAt = Date()
            // deadline: .none — SSH handshake and relay negotiation can exceed 10 s on slow
            // VPNs or distant hosts; the server governs the timeout for this operation.
            configuredPayload = try client.sendV2(method: "workspace.remote.configure", params: configureParams, deadline: .none)
            var selectParams: [String: Any] = ["workspace_id": workspaceId]
            if let workspaceWindowId, !workspaceWindowId.isEmpty {
                selectParams["window_id"] = workspaceWindowId
            }
            _ = try client.sendV2(method: "workspace.select", params: selectParams)
            let remoteState = ((configuredPayload["remote"] as? [String: Any])?["state"] as? String) ?? "unknown"
            cliDebugLog(
                "cli.ssh.remote.configure.ok workspace=\(String(workspaceId.prefix(8))) state=\(remoteState)"
            )
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "workspace=\(String(workspaceId.prefix(8))) stage=workspace.remote.configure elapsedMs=\(Int(Date().timeIntervalSince(configureStartedAt) * 1000))"
            )
        } catch {
            cliDebugLog(
                "cli.ssh.remote.configure.error workspace=\(String(workspaceId.prefix(8))) error=\(String(describing: error))"
            )
            do {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            } catch {
                let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            throw error
        }

        var payload = configuredPayload

        payload["ssh_command"] = initialSSHCommand
        payload["ssh_startup_command"] = initialSSHStartupCommand
        payload["ssh_terminal_command"] = remoteTerminalSSHCommand
        payload["ssh_terminal_startup_command"] = remoteTerminalSSHStartupCommand
        payload["ssh_env_overrides"] = [
            "GHOSTTY_SHELL_FEATURES": shellFeaturesValue,
        ]
        payload["remote_relay_port"] = remoteRelayPort
        logSSHTiming("complete", extra: "workspace=\(String(workspaceId.prefix(8)))")
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId
            let remote = payload["remote"] as? [String: Any]
            let state = (remote?["state"] as? String) ?? "unknown"
            print("OK workspace=\(workspaceHandle) target=\(sshOptions.destination) state=\(state)")
        }
    }

    private func parseSSHCommandOptions(_ commandArgs: [String], localSocketPath: String = "", remoteRelayPort: Int = 0) throws -> SSHCommandOptions {
        var destination: String?
        var port: Int?
        var identityFile: String?
        var workspaceName: String?
        var sshOptions: [String] = []
        var extraArguments: [String] = []

        var passthrough = false
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if passthrough {
                extraArguments.append(arg)
                index += 1
                continue
            }

            switch arg {
            case "--":
                passthrough = true
                index += 1
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh: --port must be 1-65535")
                }
                port = parsed
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --name requires a workspace title")
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--ssh-option":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --ssh-option requires a value")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sshOptions.append(value)
                }
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "ssh: unknown flag '\(arg)'")
                }
                if destination == nil {
                    if arg.hasPrefix("-") {
                        throw CLIError(
                            message: "ssh: destination must be <user@host>. Use --port/--identity/--ssh-option for SSH flags and `--` for remote command args."
                        )
                    }
                    destination = arg
                } else {
                    extraArguments.append(arg)
                }
                index += 1
            }
        }

        guard let destination else {
            throw CLIError(message: "ssh requires a destination (example: c11 ssh user@host)")
        }
        return SSHCommandOptions(
            destination: destination,
            port: port,
            identityFile: identityFile,
            workspaceName: workspaceName,
            sshOptions: sshOptions,
            extraArguments: extraArguments,
            localSocketPath: localSocketPath,
            remoteRelayPort: remoteRelayPort
        )
    }

    func buildSSHCommandText(
        _ options: SSHCommandOptions,
        remoteBootstrapScript: String? = nil
    ) -> String {
        var parts = baseSSHArguments(options)
        let trimmedRemoteBootstrap = remoteBootstrapScript?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if options.extraArguments.isEmpty {
            if let trimmedRemoteBootstrap, !trimmedRemoteBootstrap.isEmpty {
                let remoteCommand = sshPercentEscapedRemoteCommand(
                    encodedRemoteBootstrapCommand(trimmedRemoteBootstrap)
                )
                parts += ["-o", "RemoteCommand=\(remoteCommand)"]
            }
            if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
                parts.append("-tt")
            }
            parts.append(options.destination)
        } else {
            parts.append(options.destination)
            parts.append(contentsOf: options.extraArguments)
        }
        return parts.map(shellQuote).joined(separator: " ")
    }

    private func effectiveSSHOptions(_ options: [String], remoteRelayPort: Int? = nil) -> [String] {
        var merged = sshOptionsWithControlSocketDefaults(options, remoteRelayPort: remoteRelayPort)
        if !hasSSHOptionKey(merged, key: "StrictHostKeyChecking") {
            merged.append("StrictHostKeyChecking=accept-new")
        }
        return merged
    }

    func buildInteractiveRemoteShellScript(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let remoteTerminalLines = interactiveRemoteTerminalSetupLines(terminfoSource: terminfoSource)
        let remoteEnvExportLines = interactiveRemoteShellExportLines(shellFeatures: shellFeatures)
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        let shellStateDir = "$HOME/.cmux/relay/\(max(remoteRelayPort, 0)).shell"
        let commonShellLines = remoteTerminalLines
            + remoteEnvExportLines
            + ["export PATH=\"$HOME/.cmux/bin:$PATH\""]
            + (relaySocket.map { ["export CMUX_SOCKET_PATH=\($0)"] } ?? [])
            + [
                "hash -r >/dev/null 2>&1 || true",
                "rehash >/dev/null 2>&1 || true",
            ]
        let zshEnvLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshenv\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshenv\"",
            "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export CMUX_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi",
            "export ZDOTDIR=\"\(shellStateDir)\"",
        ]
        let zshProfileLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zprofile\" ] && source \"$CMUX_REAL_ZDOTDIR/.zprofile\"",
        ]
        let zshRCLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshrc\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshrc\"",
        ] + commonShellLines
        let zshLoginLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zlogin\" ] && source \"$CMUX_REAL_ZDOTDIR/.zlogin\"",
        ]
        let bashRCLines = [
            "if [ -f \"$HOME/.bash_profile\" ]; then . \"$HOME/.bash_profile\"; elif [ -f \"$HOME/.bash_login\" ]; then . \"$HOME/.bash_login\"; elif [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + commonShellLines
        let relayWarmupLines = interactiveRemoteRelayWarmupLines(remoteRelayPort: remoteRelayPort)

        var outerLines: [String] = [
            "CMUX_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    mkdir -p \"$HOME/.cmux/relay\"",
            "    cmux_shell_dir=\"\(shellStateDir)\"",
            "    mkdir -p \"$cmux_shell_dir\"",
            "    cat > \"$cmux_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$cmux_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$cmux_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshRCLines)
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$cmux_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshLoginLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$cmux_shell_dir/.zshenv\" \"$cmux_shell_dir/.zprofile\" \"$cmux_shell_dir/.zshrc\" \"$cmux_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export CMUX_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$cmux_shell_dir\"",
            "    exec \"$CMUX_LOGIN_SHELL\" -il",
            "    ;;",
            "  bash)",
            "    mkdir -p \"$HOME/.cmux/relay\"",
            "    cmux_shell_dir=\"\(shellStateDir)\"",
            "    mkdir -p \"$cmux_shell_dir\"",
            "    cat > \"$cmux_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: bashRCLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$cmux_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    exec \"$CMUX_LOGIN_SHELL\" --rcfile \"$cmux_shell_dir/.bashrc\" -i",
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: commonShellLines)
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines += [
            "exec \"$CMUX_LOGIN_SHELL\" -i",
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    func buildInteractiveRemoteShellCommand(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let script = buildInteractiveRemoteShellScript(
            remoteRelayPort: remoteRelayPort,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        return "/bin/sh -c \(shellQuote(script))"
    }

    private func interactiveRemoteTerminalSetupLines(terminfoSource: String?) -> [String] {
        var lines: [String] = [
            "cmux_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  cmux_term='xterm-ghostty'",
            "fi",
            "export TERM=\"$cmux_term\"",
        ]
        guard let terminfoSource else { return lines }
        let trimmedTerminfoSource = terminfoSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminfoSource.isEmpty else { return lines }
        lines += [
            "if [ \"$cmux_term\" != 'xterm-ghostty' ]; then",
            "  (",
            "    command -v tic >/dev/null 2>&1 || exit 0",
            "    mkdir -p \"$HOME/.terminfo\" 2>/dev/null || exit 0",
            "    cat <<'CMUXTERMINFO' | tic -x - >/dev/null 2>&1",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  ) >/dev/null 2>&1 &",
            "fi",
        ]
        return lines
    }

    private func interactiveRemoteShellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = Self.normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = Self.normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = Self.normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    private func interactiveRemoteRelayWarmupLines(remoteRelayPort: Int) -> [String] {
        guard remoteRelayPort > 0 else { return [] }
        return []
    }

    private func baseSSHArguments(_ options: SSHCommandOptions) -> [String] {
        let effectiveSSHOptions = effectiveSSHOptions(
            options.sshOptions,
            remoteRelayPort: options.remoteRelayPort
        )
        var parts: [String] = ["ssh"]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SetEnv") {
            parts += ["-o", "SetEnv COLORTERM=truecolor"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SendEnv") {
            parts += ["-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
        }
        if let port = options.port {
            parts += ["-p", String(port)]
        }
        if let identityFile = normalizedSSHIdentityPath(options.identityFile) {
            parts += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            parts += ["-o", option]
        }
        return parts
    }

    private func localXtermGhosttyTerminfoSource() -> String? {
        let result = runProcess(
            executablePath: "/usr/bin/infocmp",
            arguments: ["-0", "-x", "xterm-ghostty"]
        )
        guard result.status == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func sshOptionsWithControlSocketDefaults(
        _ options: [String],
        remoteRelayPort: Int? = nil
    ) -> [String] {
        var merged: [String] = []
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            merged.append(trimmed)
        }
        if !hasSSHOptionKey(merged, key: "ControlMaster") {
            merged.append("ControlMaster=auto")
        }
        if !hasSSHOptionKey(merged, key: "ControlPersist") {
            merged.append("ControlPersist=600")
        }
        if !hasSSHOptionKey(merged, key: "ControlPath") {
            merged.append("ControlPath=\(defaultSSHControlPathTemplate(remoteRelayPort: remoteRelayPort))")
        }
        return merged
    }

    private func scopedGhosttyShellFeaturesValue() -> String {
        let rawExisting = ProcessInfo.processInfo.environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    func encodedRemoteBootstrapCommand(_ remoteBootstrapScript: String) -> String {
        let encodedScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        return [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$cmux_tmp\" || { rm -f \"$cmux_tmp\"; exit 1; }",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "rm -f \"$cmux_tmp\"",
            "exit $cmux_status",
        ].joined(separator: "; ")
    }

    func sshPercentEscapedRemoteCommand(_ remoteCommand: String) -> String {
        remoteCommand.replacingOccurrences(of: "%", with: "%%")
    }

    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int
    ) throws -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        scriptLines += [
            "CMUX_SSH_SESSION_ENDED=0",
            "cmux_ssh_session_end() { if [ \"${CMUX_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; CMUX_SSH_SESSION_ENDED=1; \(lifecycleCleanup); }",
            "trap 'cmux_ssh_session_end' EXIT HUP INT TERM",
        ]
        scriptLines.append("command \(sshCommand)")
        scriptLines += [
            "cmux_ssh_status=$?",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_session_end",
            "exit $cmux_ssh_status",
        ]
        let script = scriptLines.joined(separator: "\n")
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort)
    }

    private func writeSSHStartupScript(_ scriptBody: String, remoteRelayPort: Int) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }

    private func buildSSHSessionEndShellCommand(remoteRelayPort: Int) -> String {
        [
            "if [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${CMUX_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${CMUX_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "\"${CMUX_BUNDLED_CLI_PATH}\" --socket \"${CMUX_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v c11 >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "c11 ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v cmux >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "cmux ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }

    private func runSSHSessionEnd(commandArgs: [String], client: SocketClient) throws {
        guard let relayPortRaw = optionValue(commandArgs, name: "--relay-port"),
              let relayPort = Int(relayPortRaw),
              relayPort > 0 else {
            throw CLIError(message: "ssh-session-end requires --relay-port <port>")
        }
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceRaw = optionValue(commandArgs, name: "--surface") ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
        guard let workspaceRaw,
              let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client),
              !workspaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --workspace or CMUX_WORKSPACE_ID")
        }
        guard let surfaceRaw,
              let surfaceId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceId),
              !surfaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --surface or CMUX_SURFACE_ID")
        }
        _ = try client.sendV2(method: "workspace.remote.terminal_session_end", params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "relay_port": relayPort,
        ])
    }

    private func runRemoteDaemonStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let requestedOS = optionValue(commandArgs, name: "--os")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedArch = optionValue(commandArgs, name: "--arch")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = resolvedVersionInfo()
        let manifest = remoteDaemonManifest()
        let platform = defaultRemoteDaemonPlatform(requestedOS: requestedOS, requestedArch: requestedArch)
        let cacheURL = remoteDaemonCacheURL(version: manifest?.appVersion ?? remoteDaemonVersionString(from: info), goOS: platform.goOS, goArch: platform.goArch)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        let cacheSHA = cacheExists ? try? sha256Hex(forFile: cacheURL) : nil
        let entry = manifest?.entry(goOS: platform.goOS, goArch: platform.goArch)
        let cacheVerified = (entry != nil && cacheSHA?.lowercased() == entry?.sha256.lowercased())
        let releaseTag = manifest?.releaseTag ?? "unknown"
        let assetName = entry?.assetName ?? "unknown"
        let downloadURL = entry?.downloadURL ?? "unknown"
        let checksumsAssetName = manifest?.checksumsAssetName ?? "unknown"
        let checksumsURL = manifest?.checksumsURL ?? "unknown"
        let downloadCommand = "gh release download \(releaseTag) --repo manaflow-ai/cmux --pattern \(assetName)"
        let downloadChecksumsCommand = "gh release download \(releaseTag) --repo manaflow-ai/cmux --pattern \(checksumsAssetName)"
        let checksumVerifyCommand = "shasum -a 256 -c \(checksumsAssetName) --ignore-missing"
        let signerWorkflow = releaseTag == "nightly"
            ? "manaflow-ai/cmux/.github/workflows/nightly.yml"
            : "manaflow-ai/cmux/.github/workflows/release.yml"
        let verifyCommand = "gh attestation verify ./\(assetName) --repo manaflow-ai/cmux --signer-workflow \(signerWorkflow)"

        let payload: [String: Any] = [
            "app_version": remoteDaemonVersionString(from: info),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "commit": info["CMUXCommit"] ?? NSNull(),
            "manifest_present": manifest != nil,
            "release_tag": releaseTag,
            "release_url": manifest?.releaseURL ?? NSNull(),
            "target_goos": platform.goOS,
            "target_goarch": platform.goArch,
            "asset_name": assetName,
            "download_url": downloadURL,
            "checksums_asset_name": checksumsAssetName,
            "checksums_url": checksumsURL,
            "expected_sha256": entry?.sha256 ?? NSNull(),
            "cache_path": cacheURL.path,
            "cache_exists": cacheExists,
            "cache_sha256": cacheSHA ?? NSNull(),
            "cache_verified": cacheVerified,
            "dev_local_build_fallback": ProcessInfo.processInfo.environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1",
            "download_command": downloadCommand,
            "download_checksums_command": downloadChecksumsCommand,
            "checksum_verify_command": checksumVerifyCommand,
            "attestation_verify_command": verifyCommand,
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("app version: \(payload["app_version"] as? String ?? "unknown")")
        if let build = payload["build"] as? String {
            print("build: \(build)")
        }
        if let commit = payload["commit"] as? String {
            print("commit: \(commit)")
        }
        print("manifest: \(manifest != nil ? "present" : "missing")")
        print("platform: \(platform.goOS)/\(platform.goArch)")
        print("release: \(releaseTag)")
        print("asset: \(assetName)")
        print("download url: \(downloadURL)")
        print("checksums asset: \(checksumsAssetName)")
        print("checksums: \(checksumsURL)")
        if let expectedSHA = entry?.sha256 {
            print("expected sha256: \(expectedSHA)")
        }
        print("cache: \(cacheURL.path)")
        print("cache exists: \(cacheExists ? "yes" : "no")")
        if let cacheSHA {
            print("cache sha256: \(cacheSHA)")
        }
        print("cache verified: \(cacheVerified ? "yes" : "no")")
        print("download command: \(downloadCommand)")
        print("download checksums: \(downloadChecksumsCommand)")
        print("verify checksum: \(checksumVerifyCommand)")
        print("attestation verify: \(verifyCommand)")
        if manifest == nil {
            print("note: this build has no embedded remote daemon manifest. Set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 only for dev builds.")
        }
    }

    private func defaultRemoteDaemonPlatform(requestedOS: String?, requestedArch: String?) -> (goOS: String, goArch: String) {
        let normalizedOS = requestedOS?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedArch = requestedArch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let goOS = (normalizedOS?.isEmpty == false ? normalizedOS! : hostGoOS())
        let goArch = (normalizedArch?.isEmpty == false ? normalizedArch! : hostGoArch())
        return (goOS, goArch)
    }

    private func hostGoOS() -> String {
#if os(macOS)
        return "darwin"
#elseif os(Linux)
        return "linux"
#else
        return "unknown"
#endif
    }

    private func hostGoArch() -> String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "amd64"
#else
        return "unknown"
#endif
    }

    private func remoteDaemonManifest() -> RemoteDaemonManifest? {
        for plistURL in candidateInfoPlistURLs() {
            guard let raw = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  let rawManifest = raw["CMUXRemoteDaemonManifestJSON"] as? String,
                  let data = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let manifest = try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data) else {
                continue
            }
            return manifest
        }
        return nil
    }

    private func remoteDaemonVersionString(from info: [String: String]) -> String {
        info["CFBundleShortVersionString"] ?? "dev"
    }

    private func remoteDaemonCacheURL(version: String, goOS: String, goArch: String) -> URL {
        let root: URL
        do {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("c11-remote-daemons", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
                .appendingPathComponent("c11d-remote", isDirectory: false)
        }
        return root
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("c11d-remote", isDirectory: false)
    }

    private func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let token = trimmed.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map(String.init)?.lowercased()
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func defaultSSHControlPathTemplate(remoteRelayPort: Int? = nil) -> String {
        if let remoteRelayPort, remoteRelayPort > 0 {
            return "/tmp/cmux-ssh-\(getuid())-\(remoteRelayPort)-%C"
        }
        return "/tmp/cmux-ssh-\(getuid())-%C"
    }

    private func normalizedSSHIdentityPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                return expanded
            }
        }
        return trimmed
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func cliDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let trimmedExplicit = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String? = {
            if let trimmedExplicit, !trimmedExplicit.isEmpty {
                return trimmedExplicit
            }
            guard let marker = try? String(contentsOfFile: "/tmp/cmux-last-debug-log-path", encoding: .utf8) else {
                return nil
            }
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMarker.isEmpty ? nil : trimmedMarker
        }()
        guard let path else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [cmux-cli] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
#endif
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            stdinText: stdinText,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }

    private func runBrowserCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard !commandArgs.isEmpty else {
            throw CLIError(message: "browser requires a subcommand")
        }

        var effectiveJSONOutput = jsonOutput
        var effectiveIDFormat = idFormat
        var browserArgs = commandArgs

        // Browser-skill examples often place output flags at the end of the command.
        // Strip trailing display flags so they don't become part of a URL or selector.
        while !browserArgs.isEmpty {
            if browserArgs.last == "--json" {
                effectiveJSONOutput = true
                browserArgs.removeLast()
                continue
            }

            if browserArgs.count >= 2,
               browserArgs[browserArgs.count - 2] == "--id-format" {
                let raw = browserArgs.last!
                guard let parsed = try CLIIDFormat.parse(raw) else {
                    throw CLIError(message: "--id-format must be one of: refs, uuids, both")
                }
                effectiveIDFormat = parsed
                browserArgs.removeLast(2)
                continue
            }

            break
        }

        let (surfaceOpt, argsWithoutSurfaceFlag) = parseOption(browserArgs, name: "--surface")
        var surfaceRaw = surfaceOpt
        var args = argsWithoutSurfaceFlag

        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify"]
        if surfaceRaw == nil, let first = args.first {
            if !first.hasPrefix("-") && !verbsWithoutSurface.contains(first.lowercased()) {
                surfaceRaw = first
                args = Array(args.dropFirst())
            }
        }

        guard let subcommandRaw = args.first else {
            throw CLIError(message: "browser requires a subcommand")
        }
        let subcommand = subcommandRaw.lowercased()
        let subArgs = Array(args.dropFirst())

        func requireSurface() throws -> String {
            guard let raw = surfaceRaw else {
                throw CLIError(message: "browser \(subcommand) requires a surface handle (use: browser <surface> \(subcommand) ... or --surface)")
            }
            guard let resolved = try normalizeSurfaceHandle(raw, client: client) else {
                throw CLIError(message: "Invalid surface handle")
            }
            return resolved
        }

        func output(_ payload: [String: Any], fallback: String) {
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                return
            }
            print(fallback)
            if let snapshot = payload["post_action_snapshot"] as? String,
               !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(snapshot)
            }
        }

        func displaySnapshotText(_ payload: [String: Any]) -> String {
            let snapshotText = (payload["snapshot"] as? String) ?? "Empty page"
            guard snapshotText.contains("\n- (empty)") else {
                return snapshotText
            }

            let url = ((payload["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let readyState = ((payload["ready_state"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = [snapshotText]

            if !url.isEmpty {
                lines.append("url: \(url)")
            }
            if !readyState.isEmpty {
                lines.append("ready_state: \(readyState)")
            }
            if url.isEmpty || url == "about:blank" {
                lines.append("hint: run 'c11 browser <surface> get url' to verify navigation")
            }

            return lines.joined(separator: "\n")
        }

        func displayBrowserValue(_ value: Any) -> String {
            if let dict = value as? [String: Any],
               let type = dict["__cmux_t"] as? String,
               type == "undefined" {
                return "undefined"
            }
            if value is NSNull {
                return "null"
            }
            if let string = value as? String {
                return string
            }
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }

        func displayBrowserLogItems(_ value: Any?) -> String? {
            guard let items = value as? [Any], !items.isEmpty else {
                return nil
            }

            let lines = items.map { item -> String in
                guard let dict = item as? [String: Any] else {
                    return displayBrowserValue(item)
                }

                let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let levelRaw = (dict["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let level = levelRaw.isEmpty ? "log" : levelRaw

                if text.isEmpty {
                    if let message = (dict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !message.isEmpty {
                        return "[error] \(message)"
                    }
                    return displayBrowserValue(dict)
                }
                return "[\(level)] \(text)"
            }

            return lines.joined(separator: "\n")
        }
        func nonFlagArgs(_ values: [String]) -> [String] {
            values.filter { !$0.hasPrefix("-") }
        }

        if subcommand == "identify" {
            let surface = try normalizeSurfaceHandle(surfaceRaw, client: client, allowFocused: true)
            var payload = try client.sendV2(method: "system.identify")
            if let surface {
                let urlPayload = try client.sendV2(method: "browser.url.get", params: ["surface_id": surface])
                let titlePayload = try client.sendV2(method: "browser.get.title", params: ["surface_id": surface])
                var browser: [String: Any] = [:]
                browser["surface"] = surface
                browser["url"] = urlPayload["url"] ?? ""
                browser["title"] = titlePayload["title"] ?? ""
                payload["browser"] = browser
            }
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "open" || subcommand == "open-split" || subcommand == "new" {
            // Parse routing flags before URL assembly so they never leak into the URL string.
            let (workspaceOpt, argsAfterWorkspace) = parseOption(subArgs, name: "--workspace")
            let (windowOpt, urlArgs) = parseOption(argsAfterWorkspace, name: "--window")
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let respectExternalOpenRules: Bool = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_RESPECT_EXTERNAL_OPEN_RULES"] else {
                    return false
                }
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on":
                    return true
                default:
                    return false
                }
            }()

            if surfaceRaw != nil, subcommand == "open" {
                // Treat `browser <surface> open <url>` as navigate for agent-browser ergonomics.
                let sid = try requireSurface()
                guard !url.isEmpty else {
                    throw CLIError(message: "browser <surface> open requires a URL")
                }
                let payload = try client.sendV2(method: "browser.navigate", params: ["surface_id": sid, "url": url])
                output(payload, fallback: "OK")
                return
            }

            var params: [String: Any] = [:]
            if !url.isEmpty {
                params["url"] = url
            }
            if let sourceSurface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = sourceSurface
            }
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            if let workspaceRaw {
                if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                    params["workspace_id"] = workspace
                }
            }
            if respectExternalOpenRules {
                params["respect_external_open_rules"] = true
            }
            if let windowRaw = windowOpt {
                if let window = try normalizeWindowHandle(windowRaw, client: client) {
                    params["window_id"] = window
                }
            }
            let payload = try client.sendV2(method: "browser.open_split", params: params)
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: effectiveIDFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: effectiveIDFormat) ?? "unknown"
            let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
            output(payload, fallback: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
            return
        }

        if subcommand == "goto" || subcommand == "navigate" {
            let sid = try requireSurface()
            var urlArgs = subArgs
            let snapshotAfter = urlArgs.last == "--snapshot-after"
            if snapshotAfter {
                urlArgs.removeLast()
            }
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires a URL")
            }
            var params: [String: Any] = ["surface_id": sid, "url": url]
            if snapshotAfter {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: "browser.navigate", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "back" || subcommand == "forward" || subcommand == "reload" {
            let sid = try requireSurface()
            let methodMap: [String: String] = [
                "back": "browser.back",
                "forward": "browser.forward",
                "reload": "browser.reload",
            ]
            var params: [String: Any] = ["surface_id": sid]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "url" || subcommand == "get-url" {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print((payload["url"] as? String) ?? "")
            }
            return
        }

        if ["focus-webview", "focus_webview"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.focus_webview", params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if ["is-webview-focused", "is_webview_focused"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.is_webview_focused", params: ["surface_id": sid])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print((payload["focused"] as? Bool) == true ? "true" : "false")
            }
            return
        }

        if subcommand == "snapshot" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (depthOpt, _) = parseOption(rem1, name: "--max-depth")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }
            if hasFlag(subArgs, name: "--interactive") || hasFlag(subArgs, name: "-i") {
                params["interactive"] = true
            }
            if hasFlag(subArgs, name: "--cursor") {
                params["cursor"] = true
            }
            if hasFlag(subArgs, name: "--compact") {
                params["compact"] = true
            }
            if let depthOpt {
                guard let depth = Int(depthOpt), depth >= 0 else {
                    throw CLIError(message: "--max-depth must be a non-negative integer")
                }
                params["max_depth"] = depth
            }

            let payload = try client.sendV2(method: "browser.snapshot", params: params)
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print(displaySnapshotText(payload))
            }
            return
        }

        if subcommand == "eval" {
            let sid = try requireSurface()
            let script = optionValue(subArgs, name: "--script") ?? subArgs.joined(separator: " ")
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIError(message: "browser eval requires a script")
            }
            let payload = try client.sendV2(method: "browser.eval", params: ["surface_id": sid, "script": trimmed])
            let fallback: String
            if let value = payload["value"] {
                fallback = displayBrowserValue(value)
            } else {
                fallback = "OK"
            }
            output(payload, fallback: fallback)
            return
        }

        if subcommand == "wait" {
            let sid = try requireSurface()
            var params: [String: Any] = ["surface_id": sid]

            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let (urlContainsOptA, rem3) = parseOption(rem2, name: "--url-contains")
            let (urlContainsOptB, rem4) = parseOption(rem3, name: "--url")
            let (loadStateOpt, rem5) = parseOption(rem4, name: "--load-state")
            let (functionOpt, rem6) = parseOption(rem5, name: "--function")
            let (timeoutOptMs, rem7) = parseOption(rem6, name: "--timeout-ms")
            let (timeoutOptSec, rem8) = parseOption(rem7, name: "--timeout")

            if let selector = selectorOpt ?? rem8.first {
                params["selector"] = selector
            }
            if let textOpt {
                params["text_contains"] = textOpt
            }
            if let urlContains = urlContainsOptA ?? urlContainsOptB {
                params["url_contains"] = urlContains
            }
            if let loadStateOpt {
                params["load_state"] = loadStateOpt
            }
            if let functionOpt {
                params["function"] = functionOpt
            }
            if let timeoutOptMs {
                guard let ms = Int(timeoutOptMs) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = ms
            } else if let timeoutOptSec {
                guard let seconds = Double(timeoutOptSec) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: "browser.wait", params: params, deadline: .none)
            output(payload, fallback: "OK")
            return
        }

        if ["click", "dblclick", "hover", "focus", "check", "uncheck", "scrollintoview", "scrollinto", "scroll-into-view"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }
            let methodMap: [String: String] = [
                "click": "browser.click",
                "dblclick": "browser.dblclick",
                "hover": "browser.hover",
                "focus": "browser.focus",
                "check": "browser.check",
                "uncheck": "browser.uncheck",
                "scrollintoview": "browser.scroll_into_view",
                "scrollinto": "browser.scroll_into_view",
                "scroll-into-view": "browser.scroll_into_view",
            ]
            var params: [String: Any] = ["surface_id": sid, "selector": selector]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["type", "fill"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }

            let positional = selectorOpt != nil ? rem2 : Array(rem2.dropFirst())
            let hasExplicitText = textOpt != nil || !positional.isEmpty
            let text: String
            if let textOpt {
                text = textOpt
            } else {
                text = positional.joined(separator: " ")
            }
            if subcommand == "type" {
                guard hasExplicitText, !text.isEmpty else {
                    throw CLIError(message: "browser type requires text")
                }
            }

            let method = (subcommand == "type") ? "browser.type" : "browser.fill"
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "text": text]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["press", "key", "keydown", "keyup"].contains(subcommand) {
            let sid = try requireSurface()
            let (keyOpt, rem1) = parseOption(subArgs, name: "--key")
            let key = keyOpt ?? rem1.first
            guard let key else {
                throw CLIError(message: "browser \(subcommand) requires a key")
            }
            let methodMap: [String: String] = [
                "press": "browser.press",
                "key": "browser.press",
                "keydown": "browser.keydown",
                "keyup": "browser.keyup",
            ]
            var params: [String: Any] = ["surface_id": sid, "key": key]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "select" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser select requires a selector")
            }
            let value = valueOpt ?? (selectorOpt != nil ? rem2.first : rem2.dropFirst().first)
            guard let value else {
                throw CLIError(message: "browser select requires a value")
            }
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "value": value]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: "browser.select", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "scroll" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (dxOpt, rem2) = parseOption(rem1, name: "--dx")
            let (dyOpt, rem3) = parseOption(rem2, name: "--dy")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }

            if let dxOpt {
                guard let dx = Int(dxOpt) else {
                    throw CLIError(message: "--dx must be an integer")
                }
                params["dx"] = dx
            }
            if let dyOpt {
                guard let dy = Int(dyOpt) else {
                    throw CLIError(message: "--dy must be an integer")
                }
                params["dy"] = dy
            } else if let first = rem3.first, let dy = Int(first) {
                params["dy"] = dy
            }
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }

            let payload = try client.sendV2(method: "browser.scroll", params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "screenshot" {
            let sid = try requireSurface()
            let (outPathOpt, _) = parseOption(subArgs, name: "--out")
            let localJSONOutput = hasFlag(subArgs, name: "--json")
            let outputAsJSON = effectiveJSONOutput || localJSONOutput
            var payload = try client.sendV2(method: "browser.screenshot", params: ["surface_id": sid])

            func fileURL(fromPath rawPath: String) -> URL {
                let resolvedPath = resolvePath(rawPath)
                return URL(fileURLWithPath: resolvedPath).standardizedFileURL
            }

            func writeScreenshot(_ data: Data, to destinationURL: URL) throws {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            }

            func hasText(_ value: String?) -> Bool {
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            var screenshotPath = payload["path"] as? String
            var screenshotURL = payload["url"] as? String

            func syncScreenshotLocationFields() {
                if !hasText(screenshotPath),
                   let rawURL = screenshotURL,
                   let fileURL = URL(string: rawURL),
                   fileURL.isFileURL,
                   !fileURL.path.isEmpty {
                    screenshotPath = fileURL.path
                }
                if !hasText(screenshotURL),
                   let screenshotPath,
                   hasText(screenshotPath) {
                    screenshotURL = URL(fileURLWithPath: screenshotPath).standardizedFileURL.absoluteString
                }
                if let screenshotPath, hasText(screenshotPath) {
                    payload["path"] = screenshotPath
                }
                if let screenshotURL, hasText(screenshotURL) {
                    payload["url"] = screenshotURL
                }
            }

            func persistPayloadScreenshot(to destinationURL: URL, allowFailure: Bool) throws -> Bool {
                if let sourcePath = screenshotPath, hasText(sourcePath) {
                    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
                    do {
                        if sourceURL.path != destinationURL.path {
                            try FileManager.default.createDirectory(
                                at: destinationURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try? FileManager.default.removeItem(at: destinationURL)
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        }
                        return true
                    } catch {
                        if payload["png_base64"] == nil {
                            if allowFailure {
                                return false
                            }
                            throw error
                        }
                    }
                }

                if let b64 = payload["png_base64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    do {
                        try writeScreenshot(data, to: destinationURL)
                        return true
                    } catch {
                        if allowFailure {
                            return false
                        }
                        throw error
                    }
                }

                return false
            }

            if let outPathOpt {
                let outputURL = fileURL(fromPath: outPathOpt)
                guard try persistPayloadScreenshot(to: outputURL, allowFailure: false) else {
                    throw CLIError(message: "browser screenshot missing image data")
                }
                screenshotPath = outputURL.path
                screenshotURL = outputURL.absoluteString
                payload["path"] = screenshotPath
                payload["url"] = screenshotURL
            } else {
                syncScreenshotLocationFields()
                if !hasText(screenshotPath) && !hasText(screenshotURL) {
                    let outputDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cmux-browser-screenshots-cli", isDirectory: true)
                    if (try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)) != nil {
                        bestEffortPruneTemporaryFiles(in: outputDir)
                        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                        let safeSid = sanitizedFilenameComponent(sid)
                        let filename = "surface-\(safeSid)-\(timestampMs)-\(String(UUID().uuidString.prefix(8))).png"
                        let outputURL = outputDir.appendingPathComponent(filename, isDirectory: false)
                        if (try? persistPayloadScreenshot(to: outputURL, allowFailure: true)) == true {
                            screenshotPath = outputURL.path
                            screenshotURL = outputURL.absoluteString
                            payload["path"] = screenshotPath
                            payload["url"] = screenshotURL
                        }
                    }
                }
            }

            if outputAsJSON {
                let formattedPayload = formatIDs(payload, mode: effectiveIDFormat)
                if var outputPayload = formattedPayload as? [String: Any] {
                    if hasText(screenshotPath) || hasText(screenshotURL) {
                        outputPayload.removeValue(forKey: "png_base64")
                    }
                    print(jsonString(outputPayload))
                } else {
                    print(jsonString(formattedPayload))
                }
            } else if let outPathOpt {
                print("OK \(outPathOpt)")
            } else if let screenshotURL,
                      hasText(screenshotURL) {
                print("OK \(screenshotURL)")
            } else if let screenshotPath,
                      hasText(screenshotPath) {
                print("OK \(screenshotPath)")
            } else {
                print("OK")
            }
            return
        }

        if subcommand == "get" {
            let sid = try requireSurface()
            guard let getVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser get requires a subcommand")
            }
            let getArgs = Array(subArgs.dropFirst())

            switch getVerb {
            case "url":
                let payload = try client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
                output(payload, fallback: (payload["url"] as? String) ?? "")
            case "title":
                let payload = try client.sendV2(method: "browser.get.title", params: ["surface_id": sid])
                output(payload, fallback: (payload["title"] as? String) ?? "")
            case "text", "html", "value", "count", "box", "styles", "attr":
                let (selectorOpt, rem1) = parseOption(getArgs, name: "--selector")
                let selector = selectorOpt ?? rem1.first
                if getVerb != "title" && getVerb != "url" {
                    guard selector != nil else {
                        throw CLIError(message: "browser get \(getVerb) requires a selector")
                    }
                }
                var params: [String: Any] = ["surface_id": sid]
                if let selector {
                    params["selector"] = selector
                }
                if getVerb == "attr" {
                    let (attrOpt, rem2) = parseOption(rem1, name: "--attr")
                    let attr = attrOpt ?? rem2.dropFirst().first
                    guard let attr else {
                        throw CLIError(message: "browser get attr requires --attr <name>")
                    }
                    params["attr"] = attr
                }
                if getVerb == "styles" {
                    let (propOpt, _) = parseOption(rem1, name: "--property")
                    if let propOpt {
                        params["property"] = propOpt
                    }
                }

                let methodMap: [String: String] = [
                    "text": "browser.get.text",
                    "html": "browser.get.html",
                    "value": "browser.get.value",
                    "attr": "browser.get.attr",
                    "count": "browser.get.count",
                    "box": "browser.get.box",
                    "styles": "browser.get.styles",
                ]
                let payload = try client.sendV2(method: methodMap[getVerb]!, params: params)
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else if let value = payload["value"] {
                    if let str = value as? String {
                        print(str)
                    } else {
                        print(jsonString(value))
                    }
                } else if let count = payload["count"] {
                    print("\(count)")
                } else {
                    print("OK")
                }
            default:
                throw CLIError(message: "Unsupported browser get subcommand: \(getVerb)")
            }
            return
        }

        if subcommand == "is" {
            let sid = try requireSurface()
            guard let isVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser is requires a subcommand")
            }
            let isArgs = Array(subArgs.dropFirst())
            let (selectorOpt, rem1) = parseOption(isArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser is \(isVerb) requires a selector")
            }

            let methodMap: [String: String] = [
                "visible": "browser.is.visible",
                "enabled": "browser.is.enabled",
                "checked": "browser.is.checked",
            ]
            guard let method = methodMap[isVerb] else {
                throw CLIError(message: "Unsupported browser is subcommand: \(isVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "selector": selector])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else if let value = payload["value"] {
                print("\(value)")
            } else {
                print("false")
            }
            return
        }


        if subcommand == "find" {
            let sid = try requireSurface()
            guard let locator = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser find requires a locator (role|text|label|placeholder|alt|title|testid|first|last|nth)")
            }
            let locatorArgs = Array(subArgs.dropFirst())

            var params: [String: Any] = ["surface_id": sid]
            let method: String

            switch locator {
            case "role":
                let (nameOpt, rem1) = parseOption(locatorArgs, name: "--name")
                let candidates = nonFlagArgs(rem1)
                guard let role = candidates.first else {
                    throw CLIError(message: "browser find role requires <role>")
                }
                params["role"] = role
                if let nameOpt {
                    params["name"] = nameOpt
                }
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = "browser.find.role"
            case "text", "label", "placeholder", "alt", "title", "testid":
                let keyMap: [String: String] = [
                    "text": "text",
                    "label": "label",
                    "placeholder": "placeholder",
                    "alt": "alt",
                    "title": "title",
                    "testid": "testid",
                ]
                let candidates = nonFlagArgs(locatorArgs)
                guard let value = candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a value")
                }
                params[keyMap[locator]!] = value
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = "browser.find.\(locator)"
            case "first", "last":
                let (selectorOpt, rem1) = parseOption(locatorArgs, name: "--selector")
                let candidates = nonFlagArgs(rem1)
                guard let selector = selectorOpt ?? candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a selector")
                }
                params["selector"] = selector
                method = "browser.find.\(locator)"
            case "nth":
                let (indexOpt, rem1) = parseOption(locatorArgs, name: "--index")
                let (selectorOpt, rem2) = parseOption(rem1, name: "--selector")
                let candidates = nonFlagArgs(rem2)
                let indexRaw = indexOpt ?? candidates.first
                guard let indexRaw,
                      let index = Int(indexRaw) else {
                    throw CLIError(message: "browser find nth requires an integer index")
                }
                let selector = selectorOpt ?? (candidates.count >= 2 ? candidates[1] : nil)
                guard let selector else {
                    throw CLIError(message: "browser find nth requires a selector")
                }
                params["index"] = index
                params["selector"] = selector
                method = "browser.find.nth"
            default:
                throw CLIError(message: "Unsupported browser find locator: \(locator)")
            }

            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "frame" {
            let sid = try requireSurface()
            guard let frameVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser frame requires <selector|main>")
            }
            if frameVerb == "main" {
                let payload = try client.sendV2(method: "browser.frame.main", params: ["surface_id": sid])
                output(payload, fallback: "OK")
                return
            }
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser frame requires a selector or 'main'")
            }
            let payload = try client.sendV2(method: "browser.frame.select", params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "dialog" {
            let sid = try requireSurface()
            guard let dialogVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser dialog requires <accept|dismiss> [text]")
            }
            let remainder = Array(subArgs.dropFirst())
            switch dialogVerb {
            case "accept":
                let text = remainder.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var params: [String: Any] = ["surface_id": sid]
                if !text.isEmpty {
                    params["text"] = text
                }
                let payload = try client.sendV2(method: "browser.dialog.accept", params: params)
                output(payload, fallback: "OK")
            case "dismiss":
                let payload = try client.sendV2(method: "browser.dialog.dismiss", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser dialog subcommand: \(dialogVerb)")
            }
            return
        }

        if subcommand == "download" {
            let sid = try requireSurface()
            let argsForDownload: [String]
            if subArgs.first?.lowercased() == "wait" {
                argsForDownload = Array(subArgs.dropFirst())
            } else {
                argsForDownload = subArgs
            }

            let (pathOpt, rem1) = parseOption(argsForDownload, name: "--path")
            let (timeoutMsOpt, rem2) = parseOption(rem1, name: "--timeout-ms")
            let (timeoutSecOpt, rem3) = parseOption(rem2, name: "--timeout")

            var params: [String: Any] = ["surface_id": sid]
            if let path = pathOpt ?? nonFlagArgs(rem3).first {
                params["path"] = path
            }
            if let timeoutMsOpt {
                guard let timeoutMs = Int(timeoutMsOpt) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = timeoutMs
            } else if let timeoutSecOpt {
                guard let seconds = Double(timeoutSecOpt) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: "browser.download.wait", params: params, deadline: .none)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "cookies" {
            let sid = try requireSurface()
            let cookieVerb = subArgs.first?.lowercased() ?? "get"
            let cookieArgs = subArgs.first != nil ? Array(subArgs.dropFirst()) : []

            let (nameOpt, rem1) = parseOption(cookieArgs, name: "--name")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let (urlOpt, rem3) = parseOption(rem2, name: "--url")
            let (domainOpt, rem4) = parseOption(rem3, name: "--domain")
            let (pathOpt, rem5) = parseOption(rem4, name: "--path")
            let (expiresOpt, _) = parseOption(rem5, name: "--expires")

            var params: [String: Any] = ["surface_id": sid]
            if let nameOpt { params["name"] = nameOpt }
            if let valueOpt { params["value"] = valueOpt }
            if let urlOpt { params["url"] = urlOpt }
            if let domainOpt { params["domain"] = domainOpt }
            if let pathOpt { params["path"] = pathOpt }
            if hasFlag(cookieArgs, name: "--secure") {
                params["secure"] = true
            }
            if hasFlag(cookieArgs, name: "--all") {
                params["all"] = true
            }
            if let expiresOpt {
                guard let expires = Int(expiresOpt) else {
                    throw CLIError(message: "--expires must be an integer Unix timestamp")
                }
                params["expires"] = expires
            }

            switch cookieVerb {
            case "get":
                let payload = try client.sendV2(method: "browser.cookies.get", params: params)
                output(payload, fallback: "OK")
            case "set":
                var setParams = params
                let positional = nonFlagArgs(cookieArgs)
                if setParams["name"] == nil, positional.count >= 1 {
                    setParams["name"] = positional[0]
                }
                if setParams["value"] == nil, positional.count >= 2 {
                    setParams["value"] = positional[1]
                }
                guard setParams["name"] != nil, setParams["value"] != nil else {
                    throw CLIError(message: "browser cookies set requires <name> <value> (or --name/--value)")
                }
                let payload = try client.sendV2(method: "browser.cookies.set", params: setParams)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: "browser.cookies.clear", params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser cookies subcommand: \(cookieVerb)")
            }
            return
        }

        if subcommand == "storage" {
            let sid = try requireSurface()
            let storageArgs = subArgs
            let storageType = storageArgs.first?.lowercased() ?? "local"
            guard storageType == "local" || storageType == "session" else {
                throw CLIError(message: "browser storage requires type: local|session")
            }
            let op = storageArgs.count >= 2 ? storageArgs[1].lowercased() : "get"
            let rest = storageArgs.count > 2 ? Array(storageArgs.dropFirst(2)) : []
            let positional = nonFlagArgs(rest)

            var params: [String: Any] = ["surface_id": sid, "type": storageType]
            switch op {
            case "get":
                if let key = positional.first {
                    params["key"] = key
                }
                let payload = try client.sendV2(method: "browser.storage.get", params: params)
                output(payload, fallback: "OK")
            case "set":
                guard positional.count >= 2 else {
                    throw CLIError(message: "browser storage \(storageType) set requires <key> <value>")
                }
                params["key"] = positional[0]
                params["value"] = positional[1]
                let payload = try client.sendV2(method: "browser.storage.set", params: params)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: "browser.storage.clear", params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser storage subcommand: \(op)")
            }
            return
        }

        if subcommand == "tab" {
            let sid = try requireSurface()
            let first = subArgs.first?.lowercased()
            let tabVerb: String
            let tabArgs: [String]
            if let first, ["new", "list", "close", "switch"].contains(first) {
                tabVerb = first
                tabArgs = Array(subArgs.dropFirst())
            } else if let first, Int(first) != nil {
                tabVerb = "switch"
                tabArgs = subArgs
            } else {
                tabVerb = "list"
                tabArgs = subArgs
            }

            switch tabVerb {
            case "list":
                let payload = try client.sendV2(method: "browser.tab.list", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            case "new":
                var params: [String: Any] = ["surface_id": sid]
                let url = tabArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    params["url"] = url
                }
                let payload = try client.sendV2(method: "browser.tab.new", params: params)
                output(payload, fallback: "OK")
            case "switch", "close":
                let method = (tabVerb == "switch") ? "browser.tab.switch" : "browser.tab.close"
                var params: [String: Any] = ["surface_id": sid]
                let target = tabArgs.first
                if let target {
                    if let index = Int(target) {
                        params["index"] = index
                    } else {
                        params["target_surface_id"] = target
                    }
                }
                let payload = try client.sendV2(method: method, params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser tab subcommand: \(tabVerb)")
            }
            return
        }

        if subcommand == "console" {
            let sid = try requireSurface()
            let consoleVerb = subArgs.first?.lowercased() ?? "list"
            let method = (consoleVerb == "clear") ? "browser.console.clear" : "browser.console.list"
            if consoleVerb != "list" && consoleVerb != "clear" {
                throw CLIError(message: "Unsupported browser console subcommand: \(consoleVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            if effectiveJSONOutput || consoleVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["entries"]) ?? "No console entries")
            }
            return
        }

        if subcommand == "errors" {
            let sid = try requireSurface()
            let errorsVerb = subArgs.first?.lowercased() ?? "list"
            var params: [String: Any] = ["surface_id": sid]
            if errorsVerb == "clear" {
                params["clear"] = true
            } else if errorsVerb != "list" {
                throw CLIError(message: "Unsupported browser errors subcommand: \(errorsVerb)")
            }
            let payload = try client.sendV2(method: "browser.errors.list", params: params)
            if effectiveJSONOutput || errorsVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["errors"]) ?? "No browser errors")
            }
            return
        }

        if subcommand == "highlight" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser highlight requires a selector")
            }
            let payload = try client.sendV2(method: "browser.highlight", params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "state" {
            let sid = try requireSurface()
            guard let stateVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser state requires save|load <path>")
            }
            guard subArgs.count >= 2 else {
                throw CLIError(message: "browser state \(stateVerb) requires a file path")
            }
            let path = subArgs[1]
            let method: String
            switch stateVerb {
            case "save":
                method = "browser.state.save"
            case "load":
                method = "browser.state.load"
            default:
                throw CLIError(message: "Unsupported browser state subcommand: \(stateVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "path": path])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "addinitscript" || subcommand == "addscript" || subcommand == "addstyle" {
            let sid = try requireSurface()
            let field = (subcommand == "addstyle") ? "css" : "script"
            let flag = (subcommand == "addstyle") ? "--css" : "--script"
            let (scriptOpt, rem1) = parseOption(subArgs, name: flag)
            let content = (scriptOpt ?? rem1.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires content")
            }
            let payload = try client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid, field: content])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "viewport" {
            let sid = try requireSurface()
            guard subArgs.count >= 2,
                  let width = Int(subArgs[0]),
                  let height = Int(subArgs[1]) else {
                throw CLIError(message: "browser viewport requires: <width> <height>")
            }
            let payload = try client.sendV2(method: "browser.viewport.set", params: ["surface_id": sid, "width": width, "height": height])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "geolocation" || subcommand == "geo" {
            let sid = try requireSurface()
            guard subArgs.count >= 2,
                  let latitude = Double(subArgs[0]),
                  let longitude = Double(subArgs[1]) else {
                throw CLIError(message: "browser geolocation requires: <latitude> <longitude>")
            }
            let payload = try client.sendV2(method: "browser.geolocation.set", params: ["surface_id": sid, "latitude": latitude, "longitude": longitude])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "offline" {
            let sid = try requireSurface()
            guard let raw = subArgs.first,
                  let enabled = parseBoolString(raw) else {
                throw CLIError(message: "browser offline requires true|false")
            }
            let payload = try client.sendV2(method: "browser.offline.set", params: ["surface_id": sid, "enabled": enabled])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "trace" {
            let sid = try requireSurface()
            guard let traceVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser trace requires start|stop")
            }
            let method: String
            switch traceVerb {
            case "start":
                method = "browser.trace.start"
            case "stop":
                method = "browser.trace.stop"
            default:
                throw CLIError(message: "Unsupported browser trace subcommand: \(traceVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if subArgs.count >= 2 {
                params["path"] = subArgs[1]
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "network" {
            let sid = try requireSurface()
            guard let networkVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser network requires route|unroute|requests")
            }
            let networkArgs = Array(subArgs.dropFirst())
            switch networkVerb {
            case "route":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network route requires a URL/pattern")
                }
                var params: [String: Any] = ["surface_id": sid, "url": pattern]
                if hasFlag(networkArgs, name: "--abort") {
                    params["abort"] = true
                }
                let (bodyOpt, _) = parseOption(networkArgs, name: "--body")
                if let bodyOpt {
                    params["body"] = bodyOpt
                }
                let payload = try client.sendV2(method: "browser.network.route", params: params)
                output(payload, fallback: "OK")
            case "unroute":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network unroute requires a URL/pattern")
                }
                let payload = try client.sendV2(method: "browser.network.unroute", params: ["surface_id": sid, "url": pattern])
                output(payload, fallback: "OK")
            case "requests":
                let payload = try client.sendV2(method: "browser.network.requests", params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser network subcommand: \(networkVerb)")
            }
            return
        }

        if subcommand == "screencast" {
            let sid = try requireSurface()
            guard let castVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser screencast requires start|stop")
            }
            let method: String
            switch castVerb {
            case "start":
                method = "browser.screencast.start"
            case "stop":
                method = "browser.screencast.stop"
            default:
                throw CLIError(message: "Unsupported browser screencast subcommand: \(castVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "input" {
            let sid = try requireSurface()
            guard let inputVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser input requires mouse|keyboard|touch")
            }
            let remainder = Array(subArgs.dropFirst())
            let method: String
            switch inputVerb {
            case "mouse":
                method = "browser.input_mouse"
            case "keyboard":
                method = "browser.input_keyboard"
            case "touch":
                method = "browser.input_touch"
            default:
                throw CLIError(message: "Unsupported browser input subcommand: \(inputVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if !remainder.isEmpty {
                params["args"] = remainder
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["input_mouse", "input_keyboard", "input_touch"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        throw CLIError(message: "Unsupported browser subcommand: \(subcommand)")
    }

    private func parseWindows(_ response: String) -> [WindowInfo] {
        guard response != "No windows" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let key = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = parts[1]

                var selectedWorkspaceId: String?
                var workspaceCount: Int = 0
                for token in parts.dropFirst(2) {
                    if token.hasPrefix("selected_workspace=") {
                        let v = token.replacingOccurrences(of: "selected_workspace=", with: "")
                        selectedWorkspaceId = (v == "none") ? nil : v
                    } else if token.hasPrefix("workspaces=") {
                        let v = token.replacingOccurrences(of: "workspaces=", with: "")
                        workspaceCount = Int(v) ?? 0
                    }
                }

                return WindowInfo(
                    index: index,
                    id: id,
                    key: key,
                    selectedWorkspaceId: selectedWorkspaceId,
                    workspaceCount: workspaceCount
                )
            }
    }

    private func parseNotifications(_ response: String) -> [NotificationInfo] {
        guard response != "No notifications" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let payload = parts[1].split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
                guard payload.count >= 7 else { return nil }
                let notifId = String(payload[0])
                let workspaceId = String(payload[1])
                let surfaceRaw = String(payload[2])
                let surfaceId = surfaceRaw == "none" ? nil : surfaceRaw
                let readText = String(payload[3])
                let title = String(payload[4])
                let subtitle = String(payload[5])
                let body = String(payload[6])
                return NotificationInfo(
                    id: notifId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    isRead: readText == "read",
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
    }

    private func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            // Resolve ref to UUID — search across all windows
            let windows = try client.sendV2(method: "window.list")
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "Workspace ref not found: \(raw)")
        }

        if let raw, let index = Int(raw) {
            let listed = try client.sendV2(method: "workspace.list")
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Workspace index not found")
        }

        let current = try client.sendV2(method: "workspace.current")
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    private func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface ref not found: \(raw)")
        }

        let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let items = listed["surfaces"] as? [[String: Any]] ?? []

        if let raw, let index = Int(raw) {
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface index not found")
        }

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve surface ID")
    }

    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    private func subcommandUsage(_ command: String) -> String? {
        switch command {
        case "ping":
            return """
            Usage: c11 ping

            Check connectivity to the c11 socket server.
            """
        case "capabilities":
            return """
            Usage: c11 capabilities

            Print server capabilities as JSON.
            """
        case "help":
            return """
            Usage: c11 help

            Show top-level CLI usage and command list.
            """
        case "welcome":
            return """
            Usage: c11 welcome

            Show a welcome screen with the c11 logo and useful shortcuts.
            Auto-runs once on first launch.
            """
        case "shortcuts":
            return """
            Usage: c11 shortcuts

            Open the Settings window to Keyboard Shortcuts.
            """
        case "feedback":
            return """
            Usage: c11 feedback
                   c11 feedback --email <email> --body <text> [--image <path> ...]

            Without args, open the Send Feedback modal in the running app.

            With args, submit feedback through the app using the same feedback pipeline as the modal.

            Flags:
              --email <email>   Contact email for follow-up
              --body <text>     Feedback body
              --image <path>    Attach an image file, repeat for multiple images

            Coding agents:
              Double check with the end user before sending anything. Review the message and attachments for secrets,
              private code, credentials, tokens, and other sensitive information first.
            """
        case "themes":
            return """
            Usage: c11 themes list
                   c11 themes get [--slot light|dark]
                   c11 themes set <name> [--slot light|dark|both]
                   c11 themes clear
                   c11 themes reload
                   c11 themes path
                   c11 themes dump [--json] [--color-scheme light|dark]
                   c11 themes validate <path>
                   c11 themes diff <a> <b>

            Manage c11 chrome themes: sidebar, title bars, tab bar, dividers,
            browser chrome, markdown chrome, and workspace frame.

            Commands:
              list                      List available c11 chrome themes
              get [--slot light|dark]   Read the active c11 chrome theme
              set <name> [--slot ...]   Set a c11 chrome theme for light, dark, or both slots
              clear                     Remove c11 chrome theme overrides
              reload                    Re-scan the user c11 themes directory
              path                      Print bundled and user c11 themes directories
              dump                      Print the resolved c11 chrome theme
              validate <path>           Validate a c11 chrome theme file
              diff <a> <b>              Compare two c11 chrome themes

            Examples:
              c11 themes list
              c11 themes set phosphor --slot both
              c11 themes dump --json --color-scheme dark
              c11 themes validate path/to/mytheme.toml
              c11 themes clear
            """
        case "terminal-theme":
            return """
            Usage: c11 terminal-theme
                   c11 terminal-theme list
                   c11 terminal-theme set <terminal-theme>
                   c11 terminal-theme set --light <terminal-theme> [--dark <terminal-theme>]
                   c11 terminal-theme set --dark <terminal-theme> [--light <terminal-theme>]
                   c11 terminal-theme clear

            Manage Ghostty terminal themes for terminal cells, ANSI colors, cursor,
            selection, and terminal background/foreground.

            When run in a TTY, `c11 terminal-theme` opens the interactive Ghostty
            terminal theme picker. Use `c11 terminal-theme list` for a plain listing.

            Commands:
              list                      List available Ghostty terminal themes and mark the current light/dark defaults
              set <terminal-theme>      Set the same Ghostty terminal theme for both light and dark appearance
              set --light <terminal-theme>
                                        Set the light appearance Ghostty terminal theme
              set --dark <terminal-theme>
                                        Set the dark appearance Ghostty terminal theme
              clear                     Remove the managed Ghostty terminal theme block

            Examples:
              c11 terminal-theme
              c11 terminal-theme list
              c11 terminal-theme set "Catppuccin Mocha"
              c11 terminal-theme set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              c11 terminal-theme clear
            """
        case "claude-teams":
            return String(localized: "cli.claude-teams.usage", defaultValue: """
            Usage: c11 claude-teams [claude-args...]

            Launch Claude Code with agent teams enabled.

            This command:
              - defaults Claude teammate mode to auto
              - sets a tmux-like environment so Claude auto mode uses c11 splits
              - sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to claude

            The tmux shim translates supported tmux window/pane commands into c11
            workspace and split operations in the current c11 session.

            Examples:
              c11 claude-teams
              c11 claude-teams --continue
              c11 claude-teams --model sonnet
            """)
        case "identify":
            return """
            Usage: c11 identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]

            Print server identity and caller context details.

            Flags:
              --workspace <id|ref|index>   Caller workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Caller surface context (default: $CMUX_SURFACE_ID)
              --no-caller                  Omit caller context from the request
            """
        case "list-windows":
            return """
            Usage: c11 list-windows

            List open windows.
            """
        case "current-window":
            return """
            Usage: c11 current-window

            Print the currently selected window ID.
            """
        case "new-window":
            return """
            Usage: c11 new-window

            Create a new window.

            Example:
              c11 new-window
            """
        case "focus-window":
            return """
            Usage: c11 focus-window --window <id|ref|index>

            Focus (bring to front) the specified window.

            Flags:
              --window <id|ref|index>   Window to focus (required)

            Example:
              c11 focus-window --window 0
              c11 focus-window --window window:1
            """
        case "close-window":
            return """
            Usage: c11 close-window --window <id|ref|index>

            Close the specified window.

            Flags:
              --window <id|ref|index>   Window to close (required)

            Example:
              c11 close-window --window 0
              c11 close-window --window window:1
            """
        case "move-workspace-to-window":
            return """
            Usage: c11 move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>

            Move a workspace to a different window.

            Flags:
              --workspace <id|ref|index>   Workspace to move (required)
              --window <id|ref|index>      Target window (required)

            Example:
              c11 move-workspace-to-window --workspace workspace:2 --window window:1
            """
        case "move-surface":
            return """
            Usage: c11 move-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Move a surface to a different pane, workspace, or window.

            Flags:
              --surface <id|ref|index>   Surface to move (required unless passed positionally)
              --pane <id|ref|index>      Target pane
              --workspace <id|ref|index> Target workspace
              --window <id|ref|index>    Target window
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after moving

            Example:
              c11 move-surface --surface surface:1 --workspace workspace:2
              c11 move-surface surface:1 --pane pane:2 --index 0
            """
        case "reorder-surface":
            return """
            Usage: c11 reorder-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Reorder a surface within its pane.

            Flags:
              --surface <id|ref|index>   Surface to reorder (required unless passed positionally)
              --workspace <id|ref|index> Workspace context
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index

            Example:
              c11 reorder-surface --surface surface:1 --index 0
              c11 reorder-surface --surface surface:3 --after surface:1
            """
        case "reorder-workspace":
            return """
            Usage: c11 reorder-workspace [--workspace <id|ref|index> | <id|ref|index>] [flags]

            Reorder a workspace within its window.

            Flags:
              --workspace <id|ref|index>   Workspace to reorder (required unless passed positionally)
              --index <n>                  Place at this index
              --before <id|ref|index>      Place before this workspace
              --before-workspace <id|ref|index>
                                         Alias for --before
              --after <id|ref|index>       Place after this workspace
              --after-workspace <id|ref|index>
                                         Alias for --after
              --window <id|ref|index>      Window context

            Example:
              c11 reorder-workspace --workspace workspace:2 --index 0
              c11 reorder-workspace --workspace workspace:3 --after workspace:1
            """
        case "workspace-action":
            return """
            Usage: c11 workspace-action --action <name> [flags]

            Perform workspace context-menu actions from CLI/socket.

            Actions:
              pin | unpin
              rename | clear-name
              move-up | move-down | move-top
              close-others | close-above | close-below
              mark-read | mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --workspace <id|ref|index>   Target workspace (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename (or pass trailing title text)

            Example:
              c11 workspace-action --workspace workspace:2 --action pin
              c11 workspace-action --action rename --title "infra"
              c11 workspace-action close-others
            """
        case "tab-action":
            return """
            Usage: c11 tab-action --action <name> [flags]

            Perform horizontal tab context-menu actions from CLI/socket.

            Actions:
              rename | clear-name
              close-left | close-right | close-others
              new-terminal-right | new-browser-right
              reload | duplicate
              pin | unpin
              mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
              --surface <id|ref|index>     Alias for --tab (backward compatibility)
              --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --title <text>               Title for rename (or pass trailing title text)
              --url <url>                  Optional URL for new-browser-right

            Example:
              c11 tab-action --tab tab:3 --action pin
              c11 tab-action --action close-right
              c11 tab-action --tab tab:2 --action rename --title "build logs"
            """
        case "rename-tab":
            return """
            Usage: c11 rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

            Compatibility alias for tab-action rename.

            Resolution order for target tab:
            1) --tab
            2) --surface
            3) $CMUX_TAB_ID / $CMUX_SURFACE_ID
            4) currently focused tab (optionally within --workspace)

            Flags:
              --workspace <id|ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
              --surface <id|ref>     Alias for --tab
              --title <text>         Explicit title (or use trailing positional title)

            Examples:
              c11 rename-tab "build logs"
              c11 rename-tab --tab tab:3 "staging server"
              c11 rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
            """
        case "set-title":
            return """
            Usage: c11 set-title [--surface <ref>] [--workspace <ref>] [--source <src>] <title-text>
                   c11 set-title [--surface <ref>] [--workspace <ref>] [--source <src>] --from-file <path>
                   c11 set-title [--surface <ref>] --json

            Set the surface's canonical `title` metadata key (M7 + M2).

            Flags:
              --surface <ref>     Target surface (default: $CMUX_SURFACE_ID, then focused)
              --workspace <ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --source <src>      Write source: explicit | declare | osc | heuristic (default: explicit)
              --from-file <path>  Read title text from file (use '-' for stdin)
              --json              Emit raw v2 socket result as JSON

            Exit non-zero when precedence gate blocks the write (applied=false).

            Examples:
              c11 set-title "Running smoke tests"
              c11 set-title --surface surface:3 "build logs"
              echo "Agent: gemini" | c11 set-title --source declare --from-file -
            """
        case "set-description":
            return """
            Usage: c11 set-description [--surface <ref>] [--workspace <ref>] [--source <src>] [--auto-expand=false] <description-text>
                   c11 set-description [--surface <ref>] [--workspace <ref>] [--source <src>] --from-file <path>

            Set the surface's canonical `description` metadata key (M7 + M2).

            Description supports inline Markdown: **bold**, *italic*, `inline code`.
            Block-level Markdown and links render as literal text.

            Flags:
              --surface <ref>       Target surface (default: $CMUX_SURFACE_ID, then focused)
              --workspace <ref>     Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --source <src>        Write source: explicit | declare | osc | heuristic (default: explicit)
              --from-file <path>    Read description text from file (use '-' for stdin)
              --auto-expand=false   Suppress first-set auto-expand behavior for this write
              --json                Emit raw v2 socket result as JSON

            Examples:
              c11 set-description "Running **10 shards** in parallel"
              c11 set-description --auto-expand=false --from-file ./notes.md
            """
        case "get-titlebar-state":
            return """
            Usage: c11 get-titlebar-state [--surface <ref>] [--workspace <ref>] [--json]

            Read the title bar's current state for a surface: title, description, sources,
            collapsed flag, visibility flag, and the truncated `sidebar_label` projection.

            Flags:
              --surface <ref>     Target surface (default: $CMUX_SURFACE_ID, then focused)
              --workspace <ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --json              Emit raw v2 socket result as JSON

            Example:
              c11 get-titlebar-state --json
            """
        case "new-workspace":
            return """
            Usage: c11 new-workspace [--cwd <path>] [--command <text>] [--layout <path|name>]

            Create a new workspace in the current window.

            Flags:
              --cwd <path>           Set the working directory for the new workspace
              --command <text>       Send text+Enter to the new workspace after creation
              --layout <path|name>   Apply a blueprint plan (file path or blueprint name)

            Example:
              c11 new-workspace
              c11 new-workspace --cwd ~/projects/myapp
              c11 new-workspace --cwd . --command "npm test"
              c11 new-workspace --layout my-review-room
              c11 new-workspace --layout /path/to/blueprint.json
            """
        case "list-workspaces":
            return """
            Usage: c11 list-workspaces

            List workspaces in the current window.

            Example:
              c11 list-workspaces
            """
        case "ssh":
            return """
            Usage: c11 ssh <destination> [flags] [-- <remote-command-args>]

            Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
            c11 will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

            Flags:
              --name <title>          Optional workspace title
              --port <n>              SSH port
              --identity <path>       SSH identity file path
              --ssh-option <opt>      Extra SSH -o option (repeatable)

            Example:
              c11 ssh dev@my-host
              c11 ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
              c11 ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
            """
        case "remote-daemon-status":
            return """
            Usage: c11 remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]

            Show the embedded c11d-remote release manifest, local cache status, checksum verification state,
            and the GitHub attestation verification command for a target platform.

            Example:
              c11 remote-daemon-status
              c11 remote-daemon-status --os linux --arch arm64
            """
        case "new-split":
            return """
            Usage: c11 new-split <left|right|up|down> [flags]

            Split the current pane in the given direction.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface to split from (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --title <text>         Seed the new pane's title metadata atomically with creation

            Example:
              c11 new-split right
              c11 new-split down --workspace workspace:1
              c11 new-split right --title "Parent :: Code Review"
            """
        case "list-panes":
            return """
            Usage: c11 list-panes [--workspace <id|ref>]

            List panes in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 list-panes
              c11 list-panes --workspace workspace:2
            """
        case "list-pane-surfaces":
            return """
            Usage: c11 list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

            List surfaces in a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Restrict to a specific pane (default: focused pane)

            Example:
              c11 list-pane-surfaces
              c11 list-pane-surfaces --workspace workspace:2 --pane pane:1
            """
        case "tree":
            return """
            Usage: c11 tree [flags]

            Print the hierarchy of windows, workspaces, panes, and surfaces, with
            spatial coordinates and an ASCII floor plan of the current workspace.

            Flags:
              --all                         Include all windows and all workspaces
              --window                      Include all workspaces in the current window
              --workspace <id|ref|index>    Show only one workspace
              --layout                      Render the floor plan even when scope > 1 workspace
              --no-layout                   Suppress the floor plan unconditionally
              --canvas-cols <N>             Override the floor-plan canvas width (default: auto, min 40)
              --json                        Structured JSON output (layout in `layout`/`content_area` keys)

            Default scope: the caller's current workspace. Use --window for the
            pre-M8 behavior (current window, all workspaces); --all for every window.

            Note: `layout.split_path` is recomputed on every call from the live
            split tree — it is NOT a stable identifier. A pane's split_path will
            change whenever the surrounding splits change. Use the pane ref/UUID
            to track a pane across layout mutations.

            Output:
              Text mode prints the floor plan (single-workspace scope) followed
              by a box-drawing tree with markers:
              - ◀ active (true focused window/workspace/pane/surface path)
              - ◀ here (caller surface where `c11 tree` was invoked)
              - workspace [selected]
              - pane [focused] size=W%×H% px=W×H split=H:left|...
              - surface [selected]
              Browser surfaces also include their current URL.

            Example:
              c11 tree
              c11 tree --window
              c11 tree --all
              c11 tree --workspace workspace:2
              c11 --json tree --all
            """
        case "focus-pane":
            return """
            Usage: c11 focus-pane [--pane <id|ref> | <id|ref>] [flags]

            Focus the specified pane.

            Flags:
              --pane <id|ref>          Pane to focus (required unless passed positionally)
              --workspace <id|ref>     Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 focus-pane --pane pane:2
              c11 focus-pane pane:1
              c11 focus-pane --pane pane:1 --workspace workspace:2
            """
        case "new-pane":
            return """
            Usage: c11 new-pane [flags]

            Create a new pane in the workspace.

            Flags:
              --type <terminal|browser|markdown>  Pane type (default: terminal)
              --direction <left|right|up|down>    Split direction (default: right)
              --workspace <id|ref>                Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                         URL for browser panes
              --file <path>                       File path for markdown panes
              --title <text>                      Seed the new pane's title metadata atomically with creation

            Example:
              c11 new-pane
              c11 new-pane --type browser --direction down --url https://example.com
              c11 new-pane --type markdown --file ~/docs/README.md
              c11 new-pane --title "Parent :: Code Review"
            """
        case "new-surface":
            return """
            Usage: c11 new-surface [flags]

            Create a new surface (tab) in a pane.

            Flags:
              --type <terminal|browser|markdown>  Surface type (default: terminal)
              --pane <id|ref>                     Target pane
              --workspace <id|ref>                Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                         URL for browser surfaces
              --file <path>                       File path for markdown surfaces
              --no-focus                          Create surface without stealing focus

            Example:
              c11 new-surface
              c11 new-surface --type browser --pane pane:1 --url https://example.com
              c11 new-surface --type markdown --file ~/docs/notes.md
              c11 new-surface --no-focus
            """
        case "close-surface":
            return """
            Usage: c11 close-surface [flags]

            Close a surface. Defaults to the focused surface if none specified.

            Flags:
              --surface <id|ref>     Surface to close (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 close-surface
              c11 close-surface --surface surface:3
            """
        case "drag-surface-to-split":
            return """
            Usage: c11 drag-surface-to-split --surface <id|ref> <left|right|up|down>

            Drag a surface into a new split in the given direction.

            Flags:
              --surface <id|ref>   Surface to drag (required)
              --panel <id|ref>     Alias for --surface

            Example:
              c11 drag-surface-to-split --surface surface:1 right
              c11 drag-surface-to-split --panel surface:2 down
            """
        case "refresh-surfaces":
            return """
            Usage: c11 refresh-surfaces

            Refresh surface snapshots for the focused workspace.
            """
        case "surface-health":
            return """
            Usage: c11 surface-health [--workspace <id|ref>]

            List health details for surfaces in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 surface-health
              c11 surface-health --workspace workspace:2
            """
        case "debug-terminals":
            return """
            Usage: c11 debug-terminals

            Print live Ghostty terminal runtime metadata across all windows and workspaces.
            Intended for debugging stray or detached terminal views.
            """
        case "trigger-flash":
            return """
            Usage: c11 trigger-flash [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]

            Trigger the unread flash indicator for a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface

            Example:
              c11 trigger-flash
              c11 trigger-flash --workspace workspace:2 --surface surface:3
            """
        case "list-panels":
            return """
            Usage: c11 list-panels [--workspace <id|ref>]

            List surfaces (panels) in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 list-panels
              c11 list-panels --workspace workspace:2
            """
        case "focus-panel":
            return """
            Usage: c11 focus-panel --panel <id|ref> [--workspace <id|ref>]

            Focus a specific panel (surface).

            Flags:
              --panel <id|ref>       Panel/surface to focus (required)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 focus-panel --panel surface:2
              c11 focus-panel --panel surface:5 --workspace workspace:2
            """
        case "close-workspace":
            return """
            Usage: c11 close-workspace --workspace <id|ref|index>

            Close the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to close (required)

            Example:
              c11 close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: c11 select-workspace --workspace <id|ref|index>

            Select (switch to) the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to select (required)

            Example:
              c11 select-workspace --workspace workspace:2
              c11 select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: c11 rename-workspace [--workspace <id|ref|index>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref|index>   Workspace to rename (default: current/$CMUX_WORKSPACE_ID)

            Example:
              c11 rename-workspace "backend logs"
              c11 rename-window --workspace workspace:2 "agent run"
            """
        case "current-workspace":
            return """
            Usage: c11 current-workspace

            Print the currently selected workspace ID.
            """
        case "capture-pane":
            return """
            Usage: c11 capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              c11 capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: c11 resize-pane [--pane <id|ref>] [--workspace <id|ref>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref>        Pane to resize (default: focused pane)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: c11 pipe-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <command>    Shell command to run (or pass as trailing text)
            """
        case "wait-for":
            return """
            Usage: c11 wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.

            Flags:
              -S, --signal           Signal the token instead of waiting
              --timeout <seconds>    Wait timeout (default: 30)
            """
        case "swap-pane":
            return """
            Usage: c11 swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]

            Swap two panes.

            Flags:
              --pane <id|ref>         Source pane (required)
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
            """
        case "break-pane":
            return """
            Usage: c11 break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Source pane
              --surface <id|ref>     Source surface
              --no-focus             Do not focus the result
            """
        case "join-pane":
            return """
            Usage: c11 join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>         Source pane
              --surface <id|ref>      Source surface
              --no-focus              Do not focus the result
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: c11\(command)

            Switch workspace selection (next/previous/last) in the current window.
            """
        case "last-pane":
            return """
            Usage: c11 last-pane [--workspace <id|ref>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
            """
        case "find-window":
            return """
            Usage: c11 find-window [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --content   Search terminal content in addition to workspace titles
              --select    Select the first match
            """
        case "clear-history":
            return """
            Usage: c11 clear-history [--workspace <id|ref>] [--surface <id|ref>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
            """
        case "set-hook":
            return """
            Usage: c11 set-hook [--list] [--unset <event>] | <event> <command>

            Manage tmux-compat hook definitions.

            Flags:
              --list            List configured hooks
              --unset <event>   Remove a hook by event name
            """
        case "popup":
            return """
            Usage: c11 popup

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "bind-key", "unbind-key", "copy-mode":
            return """
            Usage: c11\(command)

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "set-buffer":
            return """
            Usage: c11 set-buffer [--name <name>] [--] <text>

            Save text into a named tmux-compat buffer.

            Flags:
              --name <name>   Buffer name (default: default)
            """
        case "paste-buffer":
            return """
            Usage: c11 paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>    Surface context (default: focused surface)
            """
        case "list-buffers":
            return """
            Usage: c11 list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: c11 respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
              --command <cmd>        Command text (or pass trailing command text)
            """
        case "display-message":
            return """
            Usage: c11 display-message [-p|--print] <text>

            Print text (or show it via notification bridge in parity mode).

            Flags:
              -p, --print   Print to stdout only
            """
        case "read-screen":
            return """
            Usage: c11 read-screen [flags]

            Read terminal text from a surface as plain text.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback (not just visible viewport)
              --lines <n>            Limit to the last n lines (implies --scrollback)

            Example:
              c11 read-screen
              c11 read-screen --surface surface:2 --scrollback --lines 200
            """
        case "send":
            return """
            Usage: c11 send [flags] [--] <text>

            Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              c11 send "echo hello"
              c11 send --surface surface:2 "ls -la\\n"
            """
        case "send-key":
            return """
            Usage: c11 send-key [flags] [--] <key>

            Send a key event to a terminal surface.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              c11 send-key enter
              c11 send-key --surface surface:2 ctrl+c
            """
        case "send-panel":
            return """
            Usage: c11 send-panel --panel <id|ref> [flags] [--] <text>

            Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 send-panel --panel surface:2 "echo hello\\n"
            """
        case "send-key-panel":
            return """
            Usage: c11 send-key-panel --panel <id|ref> [flags] [--] <key>

            Send a key event to a specific panel (surface).

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 send-key-panel --panel surface:2 enter
              c11 send-key-panel --panel surface:2 ctrl+c
            """
        case "notify":
            return """
            Usage: c11 notify [flags]

            Send a notification to a workspace/surface.

            Flags:
              --title <text>         Notification title (default: "Notification")
              --subtitle <text>      Notification subtitle
              --body <text>          Notification body
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              c11 notify --title "Build done" --body "All tests passed"
              c11 notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
            """
        case "pane-confirm":
            return """
            Usage: c11 pane-confirm --panel <id|ref> --title <text> [flags]

            Present a modal confirmation dialog anchored on a specific panel and
            wait for the user's decision. Card is scrim-bounded to the panel,
            so other panes stay interactive.

            Flags:
              --panel <id|ref>        Target panel (required)
              --title <text>          Card title (required)
              --message <text>        Informative text below the title
              --destructive           Render the confirm button with destructive styling
              --timeout <seconds>     Cancel after N seconds (capped at 300; default: 300)
              --confirm-label <text>  Override the confirm-button label (default: "OK")
              --cancel-label <text>   Override the cancel-button label (default: "Cancel")
              --workspace <id|ref>    Workspace context (optional; resolved from --panel)

            Exit codes:
              0  user confirmed
              2  user cancelled
              3  dialog dismissed (panel closed, workspace closed, or timeout)
              1  error

            Example:
              c11 pane-confirm --panel surface:1 --title "Deploy to prod?" --destructive
              c11 pane-confirm --panel $CMUX_SURFACE_ID --title "Continue?" --timeout 60
            """
        case "list-notifications":
            return """
            Usage: c11 list-notifications

            List queued notifications.
            """
        case "clear-notifications":
            return """
            Usage: c11 clear-notifications

            Clear all queued notifications.
            """
        case "set-status":
            return """
            Usage: c11 set-status <key> <value> [flags]

            Set a sidebar status entry for a workspace. Status entries appear as
            pills in the sidebar tab row. Use a unique key so different tools
            (e.g. "claude_code", "build") can manage their own entries.

            Flags:
              --icon <name>          Icon name (e.g. "sparkle", "hammer")
              --color <#hex>         Pill color (e.g. "#ff9500")
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 set-status build "compiling" --icon hammer --color "#ff9500"
              c11 set-status deploy "v1.2.3" --workspace workspace:2
            """
        case "clear-status":
            return """
            Usage: c11 clear-status <key> [flags]

            Remove a sidebar status entry by key.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 clear-status build
            """
        case "list-status":
            return """
            Usage: c11 list-status [flags]

            List all sidebar status entries for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 list-status
              c11 list-status --workspace workspace:2
            """
        case "set-progress":
            return """
            Usage: c11 set-progress <0.0-1.0> [flags]

            Set a progress bar in the sidebar for a workspace.

            Flags:
              --label <text>         Label shown next to the progress bar
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 set-progress 0.5 --label "Building..."
              c11 set-progress 1.0 --label "Done"
            """
        case "clear-progress":
            return """
            Usage: c11 clear-progress [flags]

            Clear the sidebar progress bar for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 clear-progress
            """
        case "log":
            return """
            Usage: c11 log [flags] [--] <message>

            Append a log entry to the sidebar for a workspace.

            Flags:
              --level <level>        Log level: info, progress, success, warning, error (default: info)
              --source <name>        Source label (e.g. "build", "test")
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 log "Build started"
              c11 log --level error --source build "Compilation failed"
              c11 log --level success -- "All 42 tests passed"
            """
        case "clear-log":
            return """
            Usage: c11 clear-log [flags]

            Clear all sidebar log entries for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 clear-log
            """
        case "list-log":
            return """
            Usage: c11 list-log [flags]

            List sidebar log entries for a workspace.

            Flags:
              --limit <n>            Show only the last N entries
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 list-log
              c11 list-log --limit 5
            """
        case "sidebar-state":
            return """
            Usage: c11 sidebar-state [flags]

            Dump all sidebar metadata for a workspace (cwd, git branch, ports,
            status entries, progress, log entries).

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              c11 sidebar-state
              c11 sidebar-state --workspace workspace:2
            """
        case "set-agent":
            return """
            Usage: c11 set-agent --type <terminal_type>
                                  [--model <id>] [--task <id>] [--role <id>]
                                  [--surface <id|ref>] [--workspace <id|ref>]
                                  [--json]

            Declare agent identity for a surface. Writes through
            surface.set_metadata with source=declare, mode=merge.

            Only flags present are written (omitting --model does not clear an
            existing declared model). --type is kebab-case, ≤ 32 chars.

            Flags:
              --type <terminal_type>   Canonical or custom kebab-case type (required)
              --model <id>             Agent model (e.g. claude-opus-4-7)
              --task <id>              Opaque task identifier
              --role <id>              Opaque role identifier
              --surface <id|ref>       Target surface (default: $CMUX_SURFACE_ID / focused)
              --workspace <id|ref>     Target workspace (default: $CMUX_WORKSPACE_ID)
              --json                   Emit raw JSON-RPC result

            Examples:
              c11 set-agent --type claude-code --model claude-opus-4-7
              c11 set-agent --type opencode --task task-42 --surface surface:1
            """
        case "set-metadata":
            return """
            Usage: c11 set-metadata [--surface <id|ref> | --pane <id|ref>] [--workspace <id|ref>]
                                     (--json '{...}' | --key <K> --value <V> [--type string|number|bool|json])
                                     [--mode merge|replace] [--source explicit|declare|osc|heuristic]
                                     [--json]

            Set one or more metadata keys on a surface (surface.set_metadata) or
            pane (pane.set_metadata). Defaults: mode=merge, source=explicit.
            --surface and --pane are mutually exclusive.

            Flags:
              --json '{...}'           Full JSON object of keys/values
              --key <K> --value <V>    Single-key write; use --type to coerce
              --type <string|number|bool|json>   Value coercion (default: string)
              --mode <merge|replace>   Merge (default) or full replace (source=explicit only)
              --source <src>           Write source (default: explicit)
              --surface <id|ref>       Target surface (default: $CMUX_SURFACE_ID / focused)
              --pane <id|ref>          Target pane (routes to pane.set_metadata)
              --workspace <id|ref>     Target workspace (default: $CMUX_WORKSPACE_ID)

            Examples:
              c11 set-metadata --key title --value "My Surface"
              c11 set-metadata --json '{"title":"x","role":"review"}'
              c11 set-metadata --key progress --value 0.5 --type number
              c11 set-metadata --pane pane:2 --key title --value "Pane :: Child"
            """
        case "get-metadata":
            return """
            Usage: c11 get-metadata [--surface <id|ref> | --pane <id|ref>] [--workspace <id|ref>]
                                     [--key <K> ...] [--sources] [--json]

            Read metadata (and optional per-key sidecar) for a surface
            (surface.get_metadata) or pane (pane.get_metadata). Repeat --key to
            filter. --surface and --pane are mutually exclusive.

            Flags:
              --key <K>                Restrict to one key (repeatable)
              --sources                Include metadata_sources sidecar
              --surface <id|ref>       Target surface (default: $CMUX_SURFACE_ID / focused)
              --pane <id|ref>          Target pane (routes to pane.get_metadata)
              --workspace <id|ref>     Target workspace (default: $CMUX_WORKSPACE_ID)
              --json                   Emit raw JSON result

            Examples:
              c11 get-metadata
              c11 get-metadata --key terminal_type --sources
              c11 get-metadata --pane pane:2
            """
        case "clear-metadata":
            return """
            Usage: c11 clear-metadata [--surface <id|ref> | --pane <id|ref>] [--workspace <id|ref>]
                                       [--key <K> ...] [--source explicit|declare|osc|heuristic]
                                       [--json]

            Clear keys from a surface (surface.clear_metadata) or pane
            (pane.clear_metadata). With no --key flags, clears the entire blob
            (requires source=explicit). --surface and --pane are mutually exclusive.

            Flags:
              --key <K>                Key to clear (repeatable)
              --source <src>           Precedence source (default: explicit)
              --surface <id|ref>       Target surface (default: $CMUX_SURFACE_ID / focused)
              --pane <id|ref>          Target pane (routes to pane.clear_metadata)
              --workspace <id|ref>     Target workspace (default: $CMUX_WORKSPACE_ID)
              --json                   Emit raw JSON result

            Examples:
              c11 clear-metadata --key terminal_type
              c11 clear-metadata --surface surface:2
              c11 clear-metadata --pane pane:2 --key title
            """
        case "set-workspace-metadata":
            return """
            Usage: c11 set-workspace-metadata <key> <value> [flags]
                   c11 set-workspace-metadata --key <K> --value <V> [flags]
                   c11 set-workspace-metadata --json '{"description":"..."}' [flags]

            Write one or more operator-authored metadata keys on a workspace via
            workspace.set_metadata. Values are strings; canonical keys are
            "description" (≤2048 chars) and "icon" (≤32 chars). Custom keys
            must match [A-Za-z0-9_.-]+ and cap at 1024 chars each.

            Flags:
              --workspace <id|ref>     Target workspace (default: current)
              --json '{...}'           Full JSON object of keys/values
              --json                   Emit raw JSON result

            Examples:
              c11 set-workspace-metadata description "Backend API refactor"
              c11 set-workspace-metadata icon 🦊
            """
        case "get-workspace-metadata":
            return """
            Usage: c11 get-workspace-metadata [<key>] [--workspace <id|ref>] [--json]

            Read workspace metadata via workspace.get_metadata. With a key, prints
            just that value. Without a key, prints all keys/values.

            Examples:
              c11 get-workspace-metadata
              c11 get-workspace-metadata description
            """
        case "clear-workspace-metadata":
            return """
            Usage: c11 clear-workspace-metadata [<key>] [--key <K> ...] [--workspace <id|ref>] [--json]

            Clear workspace metadata keys via workspace.clear_metadata. With no
            key, clears the entire workspace metadata dictionary.

            Examples:
              c11 clear-workspace-metadata description
              c11 clear-workspace-metadata
            """
        case "set-workspace-description":
            return """
            Usage: c11 set-workspace-description <text> [--workspace <id|ref>]

            Sugar for `c11 set-workspace-metadata description <text>`.
            """
        case "set-workspace-icon":
            return """
            Usage: c11 set-workspace-icon <glyph> [--workspace <id|ref>]

            Sugar for `c11 set-workspace-metadata icon <glyph>`. Supports emoji
            or the prefix "sf:" + SF Symbol name (e.g. "sf:star.fill").
            """
        case "set-app-focus":
            return """
            Usage: c11 set-app-focus <active|inactive|clear>

            Override app focus state for notification routing tests.

            Example:
              c11 set-app-focus inactive
              c11 set-app-focus clear
            """
        case "simulate-app-active":
            return """
            Usage: c11 simulate-app-active

            Trigger the app-active handler used by notification focus tests.
            """
        case "conversation":
            return """
            Usage: c11 conversation <subcommand> [flags]

            Manage per-surface ConversationRefs (the C11-24 conversation
            store). Each surface hosts at most one active ConversationRef
            keyed by an opaque, per-kind id. The store survives c11
            restarts and is consulted at restore time to synthesise the
            resume command.

            Subcommands:
              claim --kind <k> [--cwd <path>] [--id <id>]
                Wrapper-claim: mint a placeholder ref. Idempotent and
                conservative — never displaces a real id captured by
                hook/scrape.
              push --kind <k> --id <id> --source <hook|scrape|manual>
                   [--state <alive|suspended|tombstoned|unknown|ended>]
                   [--cwd <path>] [--reason <text>]
                   [--payload <json> | --payload @<path>]
                Hook or operator push of the real id. Source priority:
                hook > scrape > manual > wrapperClaim.
                --payload accepts inline JSON or @<path> (mirrors HOOKS_FILE
                ergonomics in Resources/bin/claude).
              tombstone --kind <k> --id <id> [--reason <text>]
                Mark the surface's active ref as tombstoned. Operator-
                initiated; not auto-resumable.
              list [--surface <id>] [--json]
                List captured conversations. v1 stores process-wide;
                no workspace partitioning. Filter with --surface.
              get [--surface <id>] [--json]
                Read the active ref + can_resume + diagnostic_reason for
                the surface. Use this when debugging "why did this pane
                resume that session?" — diagnostic_reason explains the
                strategy's decision.
              clear [--surface <id>]
                Wipe the surface's conversations. Forces a fresh launch
                on next workspace open.

            Surface resolution: --surface flag, else $CMUX_SURFACE_ID env
            var. There is NO focused-surface fallback (the silent-misroute
            footgun the architecture exists to avoid).
            """
        case "claude-hook":
            return """
            Usage: c11 claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | c11 claude-hook session-start
              echo '{}' | c11 claude-hook stop
            """
        case "browser":
            return """
            Usage: c11 browser [--surface <id|ref|index> | <surface>] <subcommand> [args]

            Browser automation commands. Most subcommands require a surface handle.
            A surface can be passed as `--surface <handle>` or as the first positional token.
            `open`/`open-split`/`new`/`identify` can run without an explicit surface.

            Subcommands:
              open|open-split|new [url] [--workspace <id|ref|index>] [--window <id|ref|index>]
                open/open-split/new default to $CMUX_WORKSPACE_ID when --workspace is omitted and --window is not set
              goto|navigate <url> [--snapshot-after]
              back|forward|reload [--snapshot-after]
              url|get-url
              focus-webview | is-webview-focused
              snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval [--script <js> | <js>]
              wait [--selector <css>] [--text <text>] [--url-contains <text>|--url <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>|--timeout <seconds>]
              click|dblclick|hover|focus|check|uncheck|scroll-into-view [--selector <css> | <css>] [--snapshot-after]
              type|fill [--selector <css> | <css>] [--text <text> | <text>] [--snapshot-after]
              press|key|keydown|keyup [--key <key> | <key>] [--snapshot-after]
              select [--selector <css> | <css>] [--value <value> | <value>] [--snapshot-after]
              scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
              screenshot [--out <path>]
              get <url|title|text|html|value|attr|count|box|styles> [...]
                text|html|value|count|box|styles|attr: [--selector <css> | <css>]
                attr: [--attr <name> | <name>]
                styles: [--property <name>]
              is <visible|enabled|checked> [--selector <css> | <css>]
              find <role|text|label|placeholder|alt|title|testid|first|last|nth> [...]
                role: [--name <text>] [--exact] <role>
                text|label|placeholder|alt|title|testid: [--exact] <text>
                first|last: [--selector <css> | <css>]
                nth: [--index <n> | <n>] [--selector <css> | <css>]
              frame <main|selector> [--selector <css>]
              dialog <accept|dismiss> [text]
              download [wait] [--path <path>] [--timeout-ms <ms>|--timeout <seconds>]
              cookies <get|set|clear> [--name <name>] [--value <value>] [--url <url>] [--domain <domain>] [--path <path>] [--expires <unix>] [--secure] [--all]
              storage <local|session> <get|set|clear> [...]
              tab <new|list|switch|close|<index>> [...]
              console <list|clear>
              errors <list|clear>
              highlight [--selector <css> | <css>]
              state <save|load> <path>
              addinitscript|addscript [--script <js> | <js>]
              addstyle [--css <css> | <css>]
              viewport <width> <height>
              geolocation|geo <latitude> <longitude>
              offline <true|false>
              trace <start|stop> [path]
              network <route|unroute|requests> ...
                route <pattern> [--abort] [--body <text>]
                unroute <pattern>
              screencast <start|stop>
              input <mouse|keyboard|touch> [args...]
              input_mouse | input_keyboard | input_touch
              identify [--surface <id|ref|index>]

            Example:
              c11 browser open https://example.com
              c11 browser surface:1 navigate https://google.com
              c11 browser --surface surface:1 snapshot --interactive
            """
        // Legacy browser aliases — point users to `c11 browser --help`
        case "open-browser":
            return "Legacy alias for 'c11 browser open'. Run 'c11 browser --help' for details."
        case "navigate":
            return "Legacy alias for 'c11 browser navigate'. Run 'c11 browser --help' for details."
        case "browser-back":
            return "Legacy alias for 'c11 browser back'. Run 'c11 browser --help' for details."
        case "browser-forward":
            return "Legacy alias for 'c11 browser forward'. Run 'c11 browser --help' for details."
        case "browser-reload":
            return "Legacy alias for 'c11 browser reload'. Run 'c11 browser --help' for details."
        case "get-url":
            return "Legacy alias for 'c11 browser get-url'. Run 'c11 browser --help' for details."
        case "focus-webview":
            return "Legacy alias for 'c11 browser focus-webview'. Run 'c11 browser --help' for details."
        case "is-webview-focused":
            return "Legacy alias for 'c11 browser is-webview-focused'. Run 'c11 browser --help' for details."
        case "markdown":
            return """
            Usage: c11 markdown open <path> [options]
                   c11 markdown <path>       (shorthand for 'open')

            Open a markdown file in a formatted viewer panel with live file watching.
            The file is rendered with rich formatting (headings, code blocks, tables,
            lists, blockquotes) and automatically updates when the file changes on disk.

            Options:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Source surface to split from (default: focused surface)
              --window <id|ref|index>      Target window

            Examples:
              c11 markdown open plan.md
              c11 markdown ~/project/CHANGELOG.md
              c11 markdown open ./docs/design.md --workspace 0
            """
        case "snapshot":
            return """
            Usage: c11 snapshot [--workspace <ref>] [--out <path>] [--all] [--json]

            Capture the current workspace (or a named one) to
            `~/.c11-snapshots/<ulid>.json`. No args → current workspace
            (resolved from $CMUX_WORKSPACE_ID / $C11_WORKSPACE_ID).

            Flags:
              --workspace <ref>   Workspace to capture (ref or UUID)
              --out <path>        Override the default output path
              --all               Capture every open workspace in one pass
              --json              Emit raw snapshot.create result as JSON

            Note: --all and --workspace / --out are mutually exclusive.

            Examples:
              c11 snapshot
              c11 snapshot --workspace workspace:2 --out ~/snapshots/phase1.json
              c11 snapshot --all
            """
        case "restore":
            let inPlaceHelp = String(
                localized: "cli.restore.usage.inPlace",
                defaultValue:
                    "--in-place, --replace   Replace the current workspace's content instead of creating a new workspace"
            )
            let inPlaceNote = String(
                localized: "cli.restore.usage.inPlace.note",
                defaultValue:
                    "Running `c11 restore <id>` twice creates two workspaces unless --in-place is passed."
            )
            return """
            Usage: c11 restore <snapshot-id-or-path> [--in-place] [--json]

            Restore a workspace layout from a snapshot written by `c11 snapshot`.
            The argument is either a ULID (resolved under `~/.c11-snapshots/` or
            the legacy `~/.cmux-snapshots/`) or an absolute path to a `.json`
            snapshot file.

            \(inPlaceNote)

            When $C11_SESSION_RESUME (mirror: $CMUX_SESSION_RESUME) is set to a
            truthy value, Claude Code terminals resume their prior session via
            `cc --resume <session-id>`. Unset the env var to restore the layout
            with fresh shells instead.

            Per the socket focus policy (see CLAUDE.md), restore does not
            foreground the restored workspace; select it manually with
            `c11 workspace select <ref>` if needed.

            Flags:
              \(inPlaceHelp)
              --json                  Emit raw snapshot.restore result as JSON

            Examples:
              c11 restore 01KQ0XYZ…
              c11 restore --in-place 01KQ0XYZ…
              C11_SESSION_RESUME=1 c11 restore ~/snapshots/phase1.json
            """
        case "list-snapshots":
            return """
            Usage: c11 list-snapshots [--json]

            List snapshots under `~/.c11-snapshots/` merged with the legacy
            `~/.cmux-snapshots/` path. Newest first.

            Columns: SNAPSHOT_ID, CREATED_AT, WORKSPACE_TITLE, SURFACES, ORIGIN, SOURCE.
            SOURCE is `current` for `~/.c11-snapshots/`, `legacy` for the fallback.

            Examples:
              c11 list-snapshots
              c11 list-snapshots --json
            """
        default:
            return nil
        }
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    private func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("c11 \(command)")
        print("")
        print(text)
        return true
    }

    private static let cmuxThemeOverrideBundleIdentifier = "com.stage11.c11"
    private static let cmuxThemesBlockStart = "# cmux themes start"
    private static let cmuxThemesBlockEnd = "# cmux themes end"
    private static let cmuxThemesReloadNotificationName = "com.stage11.c11.themes.reload-config"

    private struct ThemeSelection {
        let rawValue: String?
        let light: String?
        let dark: String?
        let sourcePath: String?
    }

    private struct ThemeReloadStatus {
        let requested: Bool
        let targetBundleIdentifier: String
    }

    private enum ThemePickerTargetMode: String {
        case both
        case light
        case dark
    }

    private func shouldUseInteractiveThemePicker(jsonOutput: Bool) -> Bool {
        guard !jsonOutput else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    private func runInteractiveThemes() throws {
        guard let helperURL = bundledHelperURL(named: "ghostty") else {
            throw CLIError(message: "Bundled Ghostty terminal theme picker helper not found")
        }

        let selection = currentThemeSelection()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_THEME_PICKER_CONFIG"] = try cmuxThemeOverrideConfigURL().path
        environment["CMUX_THEME_PICKER_BUNDLE_ID"] = currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
        environment["CMUX_THEME_PICKER_TARGET"] = defaultThemePickerTargetMode(current: selection).rawValue
        environment["CMUX_THEME_PICKER_COLOR_SCHEME"] = defaultAppearancePrefersDarkThemes() ? "dark" : "light"
        if let light = selection.light {
            environment["CMUX_THEME_PICKER_INITIAL_LIGHT"] = light
        }
        if let dark = selection.dark {
            environment["CMUX_THEME_PICKER_INITIAL_DARK"] = dark
        }
        if let resourcesURL = bundledGhosttyResourcesURL() {
            environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        }

        try execInteractiveHelper(
            executablePath: helperURL.path,
            arguments: ["+list-themes"],
            environment: environment
        )
    }

    private func defaultThemePickerTargetMode(current: ThemeSelection) -> ThemePickerTargetMode {
        if let light = current.light,
           let dark = current.dark,
           light.caseInsensitiveCompare(dark) == .orderedSame {
            return .both
        }
        return defaultAppearancePrefersDarkThemes() ? .dark : .light
    }

    private func defaultAppearancePrefersDarkThemes() -> Bool {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let interfaceStyle = (globalDefaults?["AppleInterfaceStyle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private func bundledHelperURL(named helperName: String) -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var candidates: [URL] = [
            executableURL.deletingLastPathComponent().appendingPathComponent(helperName, isDirectory: false)
        ]

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                candidates.append(
                    current
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(helperName, isDirectory: false)
                )
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoHelper = current
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("zig-out", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.isExecutableFile(atPath: repoHelper.path) {
                candidates.append(repoHelper)
                break
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func execInteractiveHelper(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Never {
        var argv = ([executablePath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        var envp = environment
            .map { key, value in strdup("\(key)=\(value)") }
        defer {
            for item in envp {
                free(item)
            }
        }
        envp.append(nil)

        execve(executablePath, &argv, &envp)
        let code = errno
        throw CLIError(message: "Failed to launch interactive Ghostty terminal theme picker: \(String(cString: strerror(code)))")
    }

    private func bundledGhosttyResourcesURL() -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                let candidate = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoResources = current
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoResources.path) {
                return repoResources
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true)
    }

    private func runThemes(commandArgs: [String], jsonOutput: Bool) throws {
        if commandArgs.isEmpty {
            if shouldUseInteractiveThemePicker(jsonOutput: jsonOutput) {
                try runInteractiveThemes()
                return
            }
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        guard let subcommand = commandArgs.first else {
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        switch subcommand {
        case "list":
            if commandArgs.count > 1 {
                throw CLIError(message: "terminal-theme list does not take any positional arguments")
            }
            try printThemesList(jsonOutput: jsonOutput)
        case "set":
            try runThemesSet(
                args: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput
            )
        case "clear":
            if commandArgs.count > 1 {
                throw CLIError(message: "terminal-theme clear does not take any positional arguments")
            }
            try runThemesClear(jsonOutput: jsonOutput)
        default:
            if subcommand.hasPrefix("-") {
                throw CLIError(message: "Unknown terminal-theme subcommand '\(subcommand)'. Run 'c11 terminal-theme --help'.")
            }

            try runThemesSet(
                args: commandArgs,
                jsonOutput: jsonOutput
            )
        }
    }

    private func printThemesList(jsonOutput: Bool) throws {
        let themes = availableThemeNames()
        let current = currentThemeSelection()
        let configPath = try cmuxThemeOverrideConfigURL().path

        if jsonOutput {
            let currentPayload: [String: Any] = [
                "raw_value": current.rawValue ?? NSNull(),
                "light": current.light ?? NSNull(),
                "dark": current.dark ?? NSNull(),
                "source_path": current.sourcePath ?? NSNull()
            ]
            let payload: [String: Any] = [
                "themes": themes.map { theme in
                    [
                        "name": theme,
                        "current_light": current.light?.caseInsensitiveCompare(theme) == .orderedSame,
                        "current_dark": current.dark?.caseInsensitiveCompare(theme) == .orderedSame
                    ]
                },
                "current": currentPayload,
                "config_path": configPath
            ]
            print(jsonString(payload))
            return
        }

        print("Terminal light: \(current.light ?? "inherit")")
        print("Terminal dark: \(current.dark ?? "inherit")")
        print("Ghostty config: \(configPath)")
        if let sourcePath = current.sourcePath {
            print("Source: \(sourcePath)")
        }
        print("")

        guard !themes.isEmpty else {
            print("No Ghostty terminal themes found.")
            return
        }

        for theme in themes {
            var badges: [String] = []
            if current.light?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("light")
            }
            if current.dark?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("dark")
            }
            let badgeText = badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
            print("\(theme)\(badgeText)")
        }
    }

    private func runThemesSet(args: [String], jsonOutput: Bool) throws {
        let (lightOpt, rem0) = parseOption(args, name: "--light")
        let (darkOpt, rem1) = parseOption(rem0, name: "--dark")

        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "terminal-theme set: unknown flag '\(unknown)'. Known flags: --light <terminal-theme>, --dark <terminal-theme>")
        }

        let availableThemes = availableThemeNames()
        let current = currentThemeSelection()

        let lightTheme: String?
        let darkTheme: String?

        if lightOpt == nil && darkOpt == nil {
            let joinedTheme = rem1.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinedTheme.isEmpty else {
                throw CLIError(message: "terminal-theme set requires a terminal theme name or --light/--dark flags")
            }
            let resolved = try validatedThemeName(joinedTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
        } else {
            if !rem1.isEmpty {
                throw CLIError(message: "terminal-theme set: unexpected argument '\(rem1.joined(separator: " "))'")
            }
            lightTheme = try lightOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.light
            darkTheme = try darkOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.dark
        }

        guard let rawThemeValue = encodedThemeValue(light: lightTheme, dark: darkTheme) else {
            throw CLIError(message: "terminal-theme set requires at least one terminal theme")
        }

        let configURL = try writeManagedThemeOverride(rawThemeValue: rawThemeValue)
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "light": lightTheme ?? NSNull(),
                "dark": darkTheme ?? NSNull(),
                "raw_value": rawThemeValue,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print(
            "OK terminal_light=\(lightTheme ?? "-") terminal_dark=\(darkTheme ?? "-") ghostty_config=\(configURL.path) reload=requested"
        )
    }

    private func runThemesClear(jsonOutput: Bool) throws {
        let configURL = try clearManagedThemeOverride()
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "cleared": true,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print("OK cleared ghostty_config=\(configURL.path) reload=requested")
    }

    private func currentThemeSelection() -> ThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in themeConfigSearchURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return parseThemeSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    private func parseThemeSelection(rawValue: String?, sourcePath: String?) -> ThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return ThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        let resolvedLight = lightTheme ?? fallbackTheme ?? darkTheme
        let resolvedDark = darkTheme ?? fallbackTheme ?? lightTheme
        return ThemeSelection(rawValue: rawValue, light: resolvedLight, dark: resolvedDark, sourcePath: sourcePath)
    }

    private func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedLight?.isEmpty == false ? normalizedLight : nil, normalizedDark?.isEmpty == false ? normalizedDark : nil) {
        case let (lightTheme?, darkTheme?):
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme)"
        case let (nil, darkTheme?):
            return "dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }

    // MARK: - `c11 themes`, `c11 ui themes` + `c11 workspace-color` (CMUX-35)

    private func runUi(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let first = commandArgs.first else {
            throw CLIError(message: "ui requires a subcommand. Try: c11 themes list")
        }
        let sub = first.lowercased()
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "themes":
            try runUiThemes(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                allowAuthoringHelpers: true
            )
        default:
            throw CLIError(message: "Unknown ui subcommand: \(first)")
        }
    }

    private func runUiThemes(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        allowAuthoringHelpers: Bool
    ) throws {
        guard let first = commandArgs.first else {
            try runUiThemesList(client: client, jsonOutput: jsonOutput)
            return
        }
        let sub = first.lowercased()
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "list":
            try runUiThemesList(client: client, jsonOutput: jsonOutput)
        case "get":
            try runUiThemesGet(args: rest, client: client, jsonOutput: jsonOutput)
        case "set":
            try runUiThemesSet(args: rest, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runUiThemesClear(client: client, jsonOutput: jsonOutput)
        case "reload":
            try runUiThemesReload(client: client, jsonOutput: jsonOutput)
        case "path":
            try runUiThemesPath(client: client, jsonOutput: jsonOutput)
        case "dump":
            try runUiThemesDump(args: rest, client: client, jsonOutput: jsonOutput)
        case "validate":
            try runUiThemesValidate(args: rest, client: client, jsonOutput: jsonOutput)
        case "diff":
            try runUiThemesDiff(args: rest, client: client, jsonOutput: jsonOutput)
        case "inherit":
            if allowAuthoringHelpers {
                try runUiThemesInherit(args: rest, client: client, jsonOutput: jsonOutput)
            } else {
                throw CLIError(message: "Unknown themes subcommand: \(first)")
            }
        default:
            throw CLIError(message: "Unknown themes subcommand: \(first)")
        }
    }

    private func runUiThemesList(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.list")
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let activeLight = response["active_light"] as? String ?? "?"
        let activeDark = response["active_dark"] as? String ?? "?"
        print("Chrome light: \(activeLight)")
        print("Chrome dark:  \(activeDark)")
        print("")

        let items = response["themes"] as? [[String: Any]] ?? []
        for item in items {
            let name = item["name"] as? String ?? "?"
            let source = item["source"] as? String ?? "?"
            let display = item["display_name"] as? String ?? name
            let tags = [
                (item["is_active_light"] as? Bool == true) ? "light" : nil,
                (item["is_active_dark"] as? Bool == true) ? "dark" : nil,
                source
            ].compactMap { $0 }
            let tagText = tags.isEmpty ? "" : " [\(tags.joined(separator: ","))]"
            print("\(name)  \"\(display)\"\(tagText)")
            if let warning = item["warning"] as? String {
                print("  warning: \(warning)")
            }
        }
    }

    private func runUiThemesGet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (slotOpt, rest) = parseOption(args, name: "--slot")
        guard rest.isEmpty else {
            throw CLIError(message: "themes get: unexpected argument '\(rest[0])'")
        }
        var params: [String: Any] = [:]
        if let slot = slotOpt { params["slot"] = slot }
        let response = try client.sendV2(method: "theme.get", params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if let name = response["name"] as? String, let slot = response["slot"] as? String {
            print("Chrome \(slot): \(name)")
        } else {
            let l = response["active_light"] as? String ?? "?"
            let d = response["active_dark"] as? String ?? "?"
            print("Chrome light: \(l)")
            print("Chrome dark:  \(d)")
        }
    }

    private func runUiThemesSet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (slotOpt, rest) = parseOption(args, name: "--slot")
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard let name = positional.first else {
            throw CLIError(message: "themes set requires a c11 chrome theme name. Example: c11 themes set phosphor --slot both")
        }
        if positional.count > 1 {
            throw CLIError(message: "themes set: unexpected extra argument '\(positional[1])'")
        }
        var params: [String: Any] = ["name": name]
        if let slot = slotOpt { params["slot"] = slot }
        let response = try client.sendV2(method: "theme.set_active", params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true {
            let applied = response["slot"] as? String ?? "both"
            print("OK set \(applied)=\(name)")
        } else {
            let msg = response["error"] as? String ?? "failed"
            throw CLIError(message: "themes set failed: \(msg)")
        }
    }

    private func runUiThemesClear(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.clear_active")
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK cleared active c11 chrome theme overrides")
        }
    }

    private func runUiThemesReload(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.reload")
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK c11 chrome themes reloaded")
        }
    }

    private func runUiThemesPath(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.paths")
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if let user = response["user_themes_directory"] as? String {
            print("user:    \(user)")
        }
        if let bundled = response["bundled_themes_directory"] as? String {
            print("bundled: \(bundled)")
        }
    }

    private func runUiThemesDump(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (schemeOpt, rest) = parseOption(args, name: "--color-scheme")
        let wantJson = jsonOutput || rest.contains("--json")
        var params: [String: Any] = [:]
        if let scheme = schemeOpt { params["color_scheme"] = scheme }
        let response = try client.sendV2(method: "theme.dump", params: params)
        guard let json = response["dump_json"] as? String else {
            throw CLIError(message: "themes dump: missing dump_json")
        }
        if wantJson {
            print(json)
        } else {
            print(json)
        }
    }

    private func runUiThemesValidate(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let path = args.first else {
            throw CLIError(message: "themes validate requires a file path")
        }
        let absolutePath = resolvePath(path)
        let response = try client.sendV2(method: "theme.validate", params: ["path": absolutePath])
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true {
            let name = response["name"] as? String ?? "?"
            print("OK \(absolutePath): parses as '\(name)'")
        } else {
            let msg = response["error"] as? String ?? "invalid"
            print("FAIL \(absolutePath): \(msg)")
            throw CLIError(message: "validation failed")
        }
    }

    private func runUiThemesDiff(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard args.count >= 2 else {
            throw CLIError(message: "themes diff requires two c11 chrome theme names or paths")
        }
        let response = try client.sendV2(
            method: "theme.diff",
            params: ["a": args[0], "b": args[1]]
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true {
            let a = response["a"] as? String ?? args[0]
            let b = response["b"] as? String ?? args[1]
            let count = response["changed_role_count"] as? Int ?? 0
            print("\(a) vs \(b): \(count) role(s) differ")
            if let changed = response["changed_roles"] as? [String] {
                for role in changed { print("  \(role)") }
            }
        } else {
            let msg = response["error"] as? String ?? "diff failed"
            throw CLIError(message: msg)
        }
    }

    private func runUiThemesInherit(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (asOpt, rest) = parseOption(args, name: "--as")
        guard let parent = rest.first, let child = asOpt else {
            throw CLIError(message: "themes inherit requires a parent theme and --as <new-name>")
        }
        let response = try client.sendV2(
            method: "theme.inherit",
            params: ["parent": parent, "as": child]
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true, let path = response["path"] as? String {
            print("OK wrote \(path)")
        } else {
            let msg = response["error"] as? String ?? "inherit failed"
            throw CLIError(message: msg)
        }
    }

    private func runWorkspaceColor(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let first = commandArgs.first else {
            throw CLIError(message: "workspace-color requires a subcommand. Try: c11 workspace-color get")
        }
        let sub = first.lowercased()
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "set":
            try runWorkspaceColorSet(args: rest, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runWorkspaceColorClear(args: rest, client: client, jsonOutput: jsonOutput)
        case "get":
            try runWorkspaceColorGet(args: rest, client: client, jsonOutput: jsonOutput)
        case "list-palette":
            try runWorkspaceColorListPalette(client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Unknown workspace-color subcommand: \(first)")
        }
    }

    private func runWorkspaceColorSet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, rest) = parseOption(args, name: "--workspace")
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard let hex = positional.first else {
            throw CLIError(message: "workspace-color set <hex> [--workspace <ref>]")
        }
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        var params: [String: Any] = ["hex": hex]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let response = try client.sendV2(method: "workspace.set_custom_color", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            let applied = response["hex"] as? String ?? hex
            print("OK workspace_color=\(applied)")
        }
    }

    private func runWorkspaceColorClear(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, _) = parseOption(args, name: "--workspace")
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        var params: [String: Any] = ["clear": true]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let response = try client.sendV2(method: "workspace.set_custom_color", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK workspace color cleared")
        }
    }

    private func runWorkspaceColorGet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, _) = parseOption(args, name: "--workspace")
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        let response = try client.sendV2(method: "workspace.list")
        guard let workspaces = response["workspaces"] as? [[String: Any]] else {
            throw CLIError(message: "workspace-color get: unexpected workspace.list response")
        }
        let match = workspaces.first {
            ($0["id"] as? String) == workspaceHandle || ($0["ref"] as? String) == workspaceHandle
        } ?? workspaces.first { ($0["selected"] as? Bool) == true }
        if jsonOutput {
            print(jsonString(match ?? [:]))
            return
        }
        if let color = match?["color_hex"] as? String {
            print("color: \(color)")
        } else if let color = match?["custom_color"] as? String {
            print("color: \(color)")
        } else {
            print("color: (none)")
        }
    }

    private func runWorkspaceColorListPalette(client _: SocketClient, jsonOutput: Bool) throws {
        // Default palette names — keeps `workspace-color list-palette` purely informational.
        let palette = [
            "aurora", "carbon", "ember", "graphite", "lagoon", "lilac", "moss",
            "ochre", "pine", "plum", "rose", "sand", "sky", "slate", "void"
        ]
        if jsonOutput {
            print(jsonString(["palette": palette]))
            return
        }
        for name in palette {
            print(name)
        }
    }

    private func resolveWorkspaceColorTarget(_ raw: String?, client: SocketClient) throws -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == nil || value?.isEmpty == true || value == "@current" || value == "@focused" {
            return try normalizeWorkspaceHandle(nil, client: client, allowCurrent: true)
        }
        return try normalizeWorkspaceHandle(value, client: client)
    }

    private func availableThemeNames() -> [String] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var themes: [String] = []

        for directoryURL in themeDirectoryURLs() {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values?.isDirectory != true else { continue }
                guard values?.isRegularFile == true || values?.isRegularFile == nil else { continue }
                let name = entry.lastPathComponent
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(folded).inserted {
                    themes.append(name)
                }
            }
        }

        return themes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func themeDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        let processEnv = ProcessInfo.processInfo.environment
        var urls: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        if let resourcesDir = processEnv["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            appendIfExisting(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("themes", isDirectory: true)
        )

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Resources" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }
                if current.lastPathComponent == "Contents" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("ghostty", isDirectory: true)
                            .appendingPathComponent("themes", isDirectory: true)
                    )
                }

                let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
                let repoThemes = current.appendingPathComponent("Resources/ghostty/themes", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path),
                   fileManager.fileExists(atPath: repoThemes.path) {
                    appendIfExisting(repoThemes)
                    break
                }

                guard let parent = parentSearchURL(for: current) else { break }
                current = parent
            }
        }

        if let xdgDataDirs = processEnv["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
                appendIfExisting(
                    URL(fileURLWithPath: NSString(string: dataDir).expandingTildeInPath, isDirectory: true)
                        .appendingPathComponent("ghostty/themes", isDirectory: true)
                )
            }
        }

        appendIfExisting(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        appendIfExisting(URL(fileURLWithPath: NSString(string: "~/.config/ghostty/themes").expandingTildeInPath, isDirectory: true))
        appendIfExisting(
            URL(
                fileURLWithPath: NSString(
                    string: "~/Library/Application Support/com.mitchellh.ghostty/themes"
                ).expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }

    private func validatedThemeName(_ rawValue: String, availableThemes: [String]) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Theme name cannot be empty")
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        if availableThemes.isEmpty {
            return trimmed
        }
        throw CLIError(message: "Unknown terminal theme '\(trimmed)'. Run 'c11 terminal-theme' to list available Ghostty terminal themes.")
    }

    private func themeConfigSearchURLs() -> [URL] {
        let rawPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "~/Library/Application Support/\(Self.cmuxThemeOverrideBundleIdentifier)/config",
            "~/Library/Application Support/\(Self.cmuxThemeOverrideBundleIdentifier)/config.ghostty",
        ]

        return rawPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: false)
        }
    }

    private func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                lastValue = value
            }
        }

        return lastValue
    }

    private func cmuxThemeOverrideConfigURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CLIError(message: "Unable to resolve Application Support directory")
        }
        return appSupport
            .appendingPathComponent(Self.cmuxThemeOverrideBundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    private func writeManagedThemeOverride(rawThemeValue: String) throws -> URL {
        let fileManager = FileManager.default
        let configURL = try cmuxThemeOverrideConfigURL()
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let existingContents = try readOptionalThemeOverrideContents(at: configURL) ?? ""
        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        \(Self.cmuxThemesBlockStart)
        theme = \(rawThemeValue)
        \(Self.cmuxThemesBlockEnd)
        """

        let nextContents = strippedContents.isEmpty ? "\(block)\n" : "\(strippedContents)\n\n\(block)\n"
        try nextContents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func clearManagedThemeOverride() throws -> URL {
        let fileManager = FileManager.default
        let configURL = try cmuxThemeOverrideConfigURL()
        guard let existingContents = try readOptionalThemeOverrideContents(at: configURL) else {
            return configURL
        }

        let strippedContents = removingManagedThemeOverride(from: existingContents)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if strippedContents.isEmpty {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                guard !isThemeOverrideFileNotFoundError(error) else {
                    return configURL
                }
                throw error
            }
        } else {
            try strippedContents.appending("\n").write(to: configURL, atomically: true, encoding: .utf8)
        }

        return configURL
    }

    private func readOptionalThemeOverrideContents(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard isThemeOverrideFileNotFoundError(error) else {
                throw error
            }
            return nil
        }
    }

    private func isThemeOverrideFileNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    private func removingManagedThemeOverride(from contents: String) -> String {
        let pattern = #"(?ms)\n?# cmux themes start\n.*?\n# cmux themes end\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    private func reloadThemesIfPossible() -> ThemeReloadStatus {
        let bundleIdentifier = currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.cmuxThemesReloadNotificationName),
            object: nil,
            userInfo: ["bundleIdentifier": bundleIdentifier]
        )
        return ThemeReloadStatus(requested: true, targetBundleIdentifier: bundleIdentifier)
    }

    private func currentCmuxAppBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let bundleIdentifier = Bundle(url: current)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    /// Escape and quote a string for safe embedding in a v1 socket command.
    /// The socket tokenizer treats `\` and `"` as special inside quoted strings,
    /// so both must be escaped before wrapping in double quotes. Newlines and
    /// carriage returns must also be escaped since the socket protocol uses
    /// newline as the message terminator.
    private func socketQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
    /// Returns `(remaining, found)` — `found` is true when `name` is present.
    private func parseFlag(_ args: [String], name: String) -> ([String], Bool) {
        var remaining: [String] = []
        var found = false
        for arg in args {
            if arg == name {
                found = true
            } else {
                remaining.append(arg)
            }
        }
        return (remaining, found)
    }

    private func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                value = args[idx + 1]
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (value, remaining)
    }

    private func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    private func optionValue(_ args: [String], name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }

    private func replaceToken(_ args: [String], from: String, to: String) -> [String] {
        args.map { $0 == from ? to : $0 }
    }

    /// Unescape CLI escape sequences to match legacy v1 send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    private func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil { return nil }
        return ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
    }

    // MARK: - Module 1 / Module 2 metadata CLI

    /// Collect all `--<name> <value>` and `--<name>=<value>` occurrences.
    /// Used for repeated flags like `--key foo --key bar`.
    private func collectRepeatedOption(_ args: [String], name: String) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == name, i + 1 < args.count {
                out.append(args[i + 1])
                i += 2
                continue
            }
            if arg.hasPrefix("\(name)=") {
                out.append(String(arg.dropFirst(name.count + 1)))
                i += 1
                continue
            }
            i += 1
        }
        return out
    }

    /// Resolve `(workspace_id, surface_id)` for a metadata-style CLI call.
    /// Honors --surface, --workspace, `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, and falls back
    /// to the focused surface when no explicit target is supplied.
    private func resolveMetadataTarget(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> (workspaceId: String?, surfaceId: String?) {
        let workspaceRaw = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
        let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client)

        // Only fall back to CMUX_SURFACE_ID when the caller did not explicitly pass
        // --workspace. workspaceRaw includes the env-derived workspace, so gating
        // on workspaceRaw == nil defeats the env-surface fallback whenever the
        // agent is running inside c11 (CMUX_WORKSPACE_ID is always set).
        let explicitWorkspaceFlag = optionValue(commandArgs, name: "--workspace")
        let surfaceRaw = optionValue(commandArgs, name: "--surface")
            ?? optionValue(commandArgs, name: "--panel")
            ?? (explicitWorkspaceFlag == nil && windowOverride == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil)
        let surfaceId = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: surfaceRaw == nil
        )
        return (workspaceId, surfaceId)
    }

    /// Result of resolving a metadata command's target when either a pane or
    /// a surface may be specified. `--surface` and `--pane` are mutually
    /// exclusive; default (neither) routes to the caller's current surface
    /// per existing behavior.
    private enum MetadataCommandTarget {
        case surface(workspaceId: String?, surfaceId: String?)
        case pane(workspaceId: String?, paneId: String)
    }

    private func resolveMetadataCommandTarget(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> MetadataCommandTarget {
        let surfaceRaw = optionValue(commandArgs, name: "--surface")
            ?? optionValue(commandArgs, name: "--panel")
        let paneRaw = optionValue(commandArgs, name: "--pane")

        if surfaceRaw != nil, paneRaw != nil {
            throw CLIError(message: "usage: --surface and --pane are mutually exclusive")
        }

        if let paneRaw {
            let workspaceRaw = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            guard let paneId = try normalizePaneHandle(
                paneRaw,
                client: client,
                workspaceHandle: workspaceId
            ) else {
                throw CLIError(message: "Invalid pane handle: \(paneRaw)")
            }
            return .pane(workspaceId: workspaceId, paneId: paneId)
        }

        let (workspaceId, surfaceId) = try resolveMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        return .surface(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// `cmux set-agent` — M1 sugar over `surface.set_metadata { source: declare, mode: merge }`.
    private func runSetAgentCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let type = optionValue(commandArgs, name: "--type") else {
            throw CLIError(message: "set-agent requires --type <terminal_type>")
        }
        // Pre-validate per spec: kebab-case, ≤ 32 chars.
        let kebab = try NSRegularExpression(pattern: "^[a-z][a-z0-9-]*$")
        let range = NSRange(type.startIndex..<type.endIndex, in: type)
        guard type.count <= 32,
              kebab.firstMatch(in: type, options: [], range: range) != nil else {
            throw CLIError(message: "invalid_value: --type must be kebab-case and ≤ 32 chars (got: \(type))")
        }

        var metadata: [String: Any] = ["terminal_type": type]
        if let model = optionValue(commandArgs, name: "--model") { metadata["model"] = model }
        if let task = optionValue(commandArgs, name: "--task") { metadata["task"] = task }
        if let role = optionValue(commandArgs, name: "--role") { metadata["role"] = role }

        let (workspaceId, surfaceId) = try resolveMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [
            "metadata": metadata,
            "mode": "merge",
            "source": "declare"
        ]
        if let workspaceId { params["workspace_id"] = workspaceId }
        if let surfaceId { params["surface_id"] = surfaceId }

        let payload = try client.sendV2(method: "surface.set_metadata", params: params)
        printMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `cmux set-metadata` — M2 sugar over `surface.set_metadata { source: explicit }`.
    private func runSetMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        var metadata: [String: Any] = [:]
        if let jsonStr = optionValue(commandArgs, name: "--json-input")
            ?? optionValue(commandArgs, name: "--body") {
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "invalid_json: --json must be a JSON object string")
            }
            metadata = obj
        } else if let rawJSON = optionValue(commandArgs, name: "--json"),
                  let data = rawJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Accept --json '{...}' when it parses as an object. If it doesn't parse
            // (e.g. user meant the output toggle), fall through to key/value handling.
            metadata = obj
        }

        if metadata.isEmpty {
            guard let key = optionValue(commandArgs, name: "--key"),
                  let valueRaw = optionValue(commandArgs, name: "--value") else {
                throw CLIError(message: "set-metadata requires --key/--value or --json '{...}'")
            }
            let typeHint = (optionValue(commandArgs, name: "--type") ?? "string").lowercased()
            switch typeHint {
            case "string": metadata[key] = valueRaw
            case "number":
                if let n = Int(valueRaw) {
                    metadata[key] = n
                } else if let d = Double(valueRaw) {
                    metadata[key] = d
                } else {
                    throw CLIError(message: "invalid_value: --value is not a number (got: \(valueRaw))")
                }
            case "bool", "boolean":
                let v = valueRaw.lowercased()
                if v == "true" || v == "1" || v == "yes" { metadata[key] = true }
                else if v == "false" || v == "0" || v == "no" { metadata[key] = false }
                else { throw CLIError(message: "invalid_value: --value is not a bool (got: \(valueRaw))") }
            case "json":
                guard let data = valueRaw.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    throw CLIError(message: "invalid_json: --value is not JSON (got: \(valueRaw))")
                }
                metadata[key] = parsed
            default:
                throw CLIError(message: "invalid_value: --type must be string|number|bool|json")
            }
        }

        let mode = (optionValue(commandArgs, name: "--mode") ?? "merge").lowercased()
        let source = (optionValue(commandArgs, name: "--source") ?? "explicit").lowercased()
        let target = try resolveMetadataCommandTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [
            "metadata": metadata,
            "mode": mode,
            "source": source
        ]
        let method: String
        switch target {
        case .surface(let workspaceId, let surfaceId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let surfaceId { params["surface_id"] = surfaceId }
            method = "surface.set_metadata"
        case .pane(let workspaceId, let paneId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            params["pane_id"] = paneId
            method = "pane.set_metadata"
        }

        let payload = try client.sendV2(method: method, params: params)
        printMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `cmux get-metadata` — M2 sugar over `surface.get_metadata` (or
    /// `pane.get_metadata` when `--pane` is supplied).
    private func runGetMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let includeSources = hasFlag(commandArgs, name: "--sources")
            || hasFlag(commandArgs, name: "--include-sources")
        let keys = collectRepeatedOption(commandArgs, name: "--key")
        let target = try resolveMetadataCommandTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        if !keys.isEmpty { params["keys"] = keys }
        if includeSources { params["include_sources"] = true }
        let method: String
        switch target {
        case .surface(let workspaceId, let surfaceId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let surfaceId { params["surface_id"] = surfaceId }
            method = "surface.get_metadata"
        case .pane(let workspaceId, let paneId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            params["pane_id"] = paneId
            method = "pane.get_metadata"
        }

        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let metadata = payload["metadata"] as? [String: Any] ?? [:]
        let sources = payload["metadata_sources"] as? [String: [String: Any]] ?? [:]
        if metadata.isEmpty {
            print("(empty)")
            return
        }
        let keyOrder = metadata.keys.sorted()
        for k in keyOrder {
            guard let v = metadata[k] else { continue }
            let valueText = renderScalarOrJSON(v)
            if includeSources, let sidecar = sources[k] {
                let src = (sidecar["source"] as? String) ?? "?"
                let ts = (sidecar["ts"] as? Double).map { String(format: "%.3f", $0) } ?? "?"
                print("\(k) = \(valueText)  [\(src) @ \(ts)]")
            } else {
                print("\(k) = \(valueText)")
            }
        }
    }

    /// `cmux clear-metadata` — M2 sugar over `surface.clear_metadata` (or
    /// `pane.clear_metadata` when `--pane` is supplied).
    private func runClearMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let keys = collectRepeatedOption(commandArgs, name: "--key")
        let source = (optionValue(commandArgs, name: "--source") ?? "explicit").lowercased()
        let target = try resolveMetadataCommandTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = ["source": source]
        if !keys.isEmpty { params["keys"] = keys }
        let method: String
        switch target {
        case .surface(let workspaceId, let surfaceId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let surfaceId { params["surface_id"] = surfaceId }
            method = "surface.clear_metadata"
        case .pane(let workspaceId, let paneId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            params["pane_id"] = paneId
            method = "pane.clear_metadata"
        }

        let payload = try client.sendV2(method: method, params: params)
        printMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// Resolve the `workspace_id` param for a workspace metadata CLI call.
    /// Honors `--workspace`, `CMUX_WORKSPACE_ID`, then falls back to the
    /// currently selected workspace (server-side default).
    private func resolveWorkspaceMetadataTarget(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String? {
        let raw = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
        return try normalizeWorkspaceHandle(raw, client: client)
    }

    /// `c11 set-workspace-metadata <key> <value>` — wraps workspace.set_metadata.
    private func runSetWorkspaceMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        var metadata: [String: String] = [:]
        var singleKey: String?
        var singleValue: String?

        if let jsonStr = optionValue(commandArgs, name: "--json") {
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "invalid_json: --json must be a JSON object string")
            }
            for (k, v) in obj {
                guard let s = v as? String else {
                    throw CLIError(message: "invalid_value: workspace metadata values must be strings (key '\(k)')")
                }
                metadata[k] = s
            }
        } else if let keyOpt = optionValue(commandArgs, name: "--key"),
                  let valueOpt = optionValue(commandArgs, name: "--value") {
            singleKey = keyOpt
            singleValue = valueOpt
        } else if positional.count >= 2 {
            singleKey = positional[0]
            singleValue = positional.dropFirst().joined(separator: " ")
        } else {
            throw CLIError(message: "set-workspace-metadata requires <key> <value>, --key/--value, or --json '{...}'")
        }

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )

        var params: [String: Any] = [:]
        if let workspaceId { params["workspace_id"] = workspaceId }
        if !metadata.isEmpty {
            params["metadata"] = metadata
        } else if let singleKey, let singleValue {
            params["key"] = singleKey
            params["value"] = singleValue
        }

        let payload = try client.sendV2(method: "workspace.set_metadata", params: params)
        printWorkspaceMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `cmux get-workspace-metadata [<key>]` — wraps workspace.get_metadata.
    private func runGetWorkspaceMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        let keyFilter = optionValue(commandArgs, name: "--key") ?? positional.first

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        if let workspaceId { params["workspace_id"] = workspaceId }
        if let keyFilter { params["key"] = keyFilter }

        let payload = try client.sendV2(method: "workspace.get_metadata", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let metadata = payload["metadata"] as? [String: String] ?? [:]
        if let keyFilter {
            if let v = metadata[keyFilter] {
                print(v)
            } else {
                print("(unset)")
            }
            return
        }
        if metadata.isEmpty {
            print("(empty)")
            return
        }
        for key in metadata.keys.sorted() {
            print("\(key) = \(metadata[key] ?? "")")
        }
    }

    /// `cmux clear-workspace-metadata [<key>]` — wraps workspace.clear_metadata.
    private func runClearWorkspaceMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        var keys: [String] = collectRepeatedOption(commandArgs, name: "--key")
        if keys.isEmpty, let first = positional.first {
            keys = [first]
        }

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        if let workspaceId { params["workspace_id"] = workspaceId }
        if !keys.isEmpty { params["keys"] = keys }

        let payload = try client.sendV2(method: "workspace.clear_metadata", params: params)
        printWorkspaceMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `c11 set-workspace-description <text>` / `c11 set-workspace-icon <glyph>`
    /// — thin sugar over `set-workspace-metadata <canonical-key> <value>`.
    private func runSetWorkspaceCanonicalKeyCommand(
        key: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        guard let value = optionValue(commandArgs, name: "--value") ?? positional.first else {
            throw CLIError(message: "set-workspace-\(key) requires a value")
        }

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = ["key": key, "value": value]
        if let workspaceId { params["workspace_id"] = workspaceId }
        let payload = try client.sendV2(method: "workspace.set_metadata", params: params)
        printWorkspaceMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// Print a workspace.set_metadata / workspace.clear_metadata result.
    private func printWorkspaceMetadataResult(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        var parts = ["OK"]
        if let handle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            parts.append(handle)
        }
        print(parts.joined(separator: " "))
        let metadata = payload["metadata"] as? [String: String] ?? [:]
        if metadata.isEmpty {
            print("  (empty)")
            return
        }
        for key in metadata.keys.sorted() {
            print("  \(key) = \(metadata[key] ?? "")")
        }
    }

    /// Print a `surface.set_metadata` / `surface.clear_metadata` result.
    private func printMetadataResult(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let applied = payload["applied"] as? [String: Any] ?? [:]
        let reasons = payload["reasons"] as? [String: Any] ?? [:]
        var parts = ["OK"]
        if let handle = formatHandle(payload, kind: "surface", idFormat: idFormat) {
            parts.append(handle)
        }
        print(parts.joined(separator: " "))
        for key in applied.keys.sorted() {
            let ok = (applied[key] as? Bool) == true
            if ok {
                print("  \(key): applied")
            } else {
                let reason = (reasons[key] as? String) ?? "not_applied"
                print("  \(key): skipped (\(reason))")
            }
        }
    }

    /// `c11 conversation <claim|push|tombstone|list|get|clear>` — wraps the
    /// `conversation.*` v2 socket methods.
    ///
    /// Per the C11-24 plan: every verb resolves `--surface` from
    /// `CMUX_SURFACE_ID` if unset. **No focused-fallback** — that path is
    /// the silent-misroute footgun the architecture exists to fix. If the
    /// env var is missing and no flag was given, error out cleanly.
    private func runConversationCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let subArgs = Array(commandArgs.dropFirst())

        switch subcommand {
        case "claim":
            try runConversationClaim(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "push":
            try runConversationPush(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "tombstone":
            try runConversationTombstone(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "list":
            try runConversationList(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "get":
            try runConversationGet(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runConversationClear(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "help", "--help", "-h":
            print(conversationUsage())
        default:
            throw CLIError(message: "Unknown conversation subcommand: \(subcommand)")
        }
    }

    private func conversationUsage() -> String {
        return """
        Usage: c11 conversation <subcommand> [flags]

        Subcommands:
          claim --kind <k> [--cwd <path>] [--id <id>]
          push --kind <k> --id <id> --source <hook|scrape|manual>
               [--state <alive|suspended|tombstoned|unknown|ended>]
               [--cwd <path>] [--reason <text>]
               [--payload <json> | --payload @<path>]
          tombstone --kind <k> --id <id> [--reason <text>]
          list [--surface <id>] [--json]
          get [--surface <id>] [--json]
          clear [--surface <id>]

        --surface defaults to $CMUX_SURFACE_ID. There is NO focused-surface
        fallback; commands error out if the env var is missing and no flag
        was given.
        """
    }

    /// Resolve `--surface` strictly — env-var or flag, no focused fallback.
    /// Returns the raw surface handle; the server resolves it to a UUID.
    private func resolveConversationSurface(_ args: [String]) throws -> String {
        if let raw = optionValue(args, name: "--surface") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let envRaw = ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envRaw.isEmpty {
            return envRaw
        }
        throw CLIError(message: "missing_surface: --surface flag or CMUX_SURFACE_ID env var required (no focused-fallback)")
    }

    /// `--payload <json>` or `--payload @<path>` (mirrors HOOKS_FILE in
    /// Resources/bin/claude). Returns parsed JSON object or nil.
    private func readConversationPayload(_ args: [String]) throws -> [String: Any]? {
        guard let raw = optionValue(args, name: "--payload") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let jsonText: String
        if trimmed.hasPrefix("@") {
            let path = String(trimmed.dropFirst())
            do {
                jsonText = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw CLIError(message: "payload_file_unreadable: \(path): \(error.localizedDescription)")
            }
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw CLIError(message: "invalid_json: --payload is not valid UTF-8")
        }
        let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw CLIError(message: "invalid_json: --payload must be a JSON object")
        }
        return dict
    }

    private func runConversationClaim(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let kind = optionValue(subArgs, name: "--kind"),
              !kind.isEmpty else {
            throw CLIError(message: "claim requires --kind <kind>")
        }
        let surface = try resolveConversationSurface(subArgs)
        var params: [String: Any] = [
            "surface_id": surface,
            "kind": kind
        ]
        if let cwd = optionValue(subArgs, name: "--cwd") { params["cwd"] = cwd }
        if let id = optionValue(subArgs, name: "--id") { params["placeholder_id"] = id }
        let payload = try client.sendV2(method: "conversation.claim", params: params)
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print("OK conversation.claim kind=\(kind) surface=\(surface)")
        }
    }

    private func runConversationPush(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let kind = optionValue(subArgs, name: "--kind"),
              !kind.isEmpty else {
            throw CLIError(message: "push requires --kind <kind>")
        }
        guard let id = optionValue(subArgs, name: "--id"),
              !id.isEmpty else {
            throw CLIError(message: "push requires --id <id>")
        }
        guard let source = optionValue(subArgs, name: "--source"),
              !source.isEmpty else {
            throw CLIError(message: "push requires --source <hook|scrape|manual>")
        }
        let surface = try resolveConversationSurface(subArgs)
        var params: [String: Any] = [
            "surface_id": surface,
            "kind": kind,
            "id": id,
            "source": source
        ]
        if let state = optionValue(subArgs, name: "--state") {
            // C11-24 review (I2): mirror the server-side strict validation
            // so typos fail at the CLI boundary instead of round-tripping
            // to the socket only to come back with `invalid_state`.
            let allowed: Set<String> = ["alive", "suspended", "ended", "tombstoned", "unknown", "unsupported"]
            guard allowed.contains(state.lowercased()) else {
                throw CLIError(message: "--state must be one of: \(allowed.sorted().joined(separator: ", "))")
            }
            params["state"] = state.lowercased()
        }
        if let cwd = optionValue(subArgs, name: "--cwd") { params["cwd"] = cwd }
        if let reason = optionValue(subArgs, name: "--reason") { params["diagnostic_reason"] = reason }
        if let payloadObj = try readConversationPayload(subArgs) {
            params["payload"] = payloadObj
        }
        let response = try client.sendV2(method: "conversation.push", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.push kind=\(kind) surface=\(surface) source=\(source)")
        }
    }

    private func runConversationTombstone(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let kind = optionValue(subArgs, name: "--kind"),
              !kind.isEmpty else {
            throw CLIError(message: "tombstone requires --kind <kind>")
        }
        guard let id = optionValue(subArgs, name: "--id"),
              !id.isEmpty else {
            throw CLIError(message: "tombstone requires --id <id>")
        }
        let surface = try resolveConversationSurface(subArgs)
        var params: [String: Any] = [
            "surface_id": surface,
            "kind": kind,
            "id": id
        ]
        if let reason = optionValue(subArgs, name: "--reason") { params["reason"] = reason }
        let response = try client.sendV2(method: "conversation.tombstone", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.tombstone kind=\(kind) surface=\(surface)")
        }
    }

    private func runConversationList(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var params: [String: Any] = [:]
        if let s = optionValue(subArgs, name: "--surface") { params["surface_id"] = s }
        // C11-24 review (I3): --workspace is not implemented in v1. The
        // store doesn't track per-workspace partitioning today; the
        // server has been silently ignoring `workspace_id` and returning
        // every conversation across every workspace. Reject explicitly
        // rather than lying about the filter; revisit in v1.1 if the
        // store grows workspace partitioning.
        if optionValue(subArgs, name: "--workspace") != nil {
            throw CLIError(message: "--workspace is not supported in v1; conversations are stored process-wide. Filter with --surface instead.")
        }
        let response = try client.sendV2(method: "conversation.list", params: params)
        if jsonOutput || hasFlag(subArgs, name: "--json") {
            print(jsonString(response))
            return
        }
        let entries = response["conversations"] as? [[String: Any]] ?? []
        if entries.isEmpty {
            print("(no conversations)")
            return
        }
        for entry in entries {
            let kind = entry["kind"] as? String ?? "?"
            let id = entry["id"] as? String ?? "?"
            let state = entry["state"] as? String ?? "?"
            let surface = entry["surface_id"] as? String ?? "?"
            print("\(surface)  \(kind)  \(id)  [\(state)]")
        }
    }

    private func runConversationGet(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let surface = try resolveConversationSurface(subArgs)
        let params: [String: Any] = ["surface_id": surface]
        let response = try client.sendV2(method: "conversation.get", params: params)
        if jsonOutput || hasFlag(subArgs, name: "--json") {
            print(jsonString(response))
            return
        }
        guard let active = response["active"] as? [String: Any] else {
            print("(no conversation for surface)")
            return
        }
        let kind = active["kind"] as? String ?? "?"
        let id = active["id"] as? String ?? "?"
        let state = active["state"] as? String ?? "?"
        let source = active["captured_via"] as? String ?? "?"
        let reason = active["diagnostic_reason"] as? String ?? ""
        let resumable = (response["can_resume"] as? Bool) ?? false
        print("kind=\(kind) id=\(id) state=\(state) source=\(source) resumable=\(resumable)")
        if !reason.isEmpty {
            print("reason: \(reason)")
        }
    }

    private func runConversationClear(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let surface = try resolveConversationSurface(subArgs)
        let params: [String: Any] = ["surface_id": surface]
        let response = try client.sendV2(method: "conversation.clear", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.clear surface=\(surface)")
        }
    }

    /// Render an arbitrary JSON-ish metadata value for the human CLI output.
    private func renderScalarOrJSON(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // NSNumber can wrap Bool — distinguish.
            let cfType = CFNumberGetType(n)
            if CFGetTypeID(n) == CFBooleanGetTypeID() || cfType == .charType {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }

    private func forwardSidebarMetadataCommand(
        _ socketCommand: String,
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String {
        func insertArgumentBeforeSeparator(_ value: String, into args: inout [String]) {
            if let separatorIndex = args.firstIndex(of: "--") {
                args.insert(value, at: separatorIndex)
            } else {
                args.append(value)
            }
        }

        var forwardedArgs: [String] = []
        var resolvedExplicitWorkspace = false
        var index = 0

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--workspace", index + 1 < commandArgs.count {
                let workspaceId = try resolveWorkspaceId(commandArgs[index + 1], client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 2
                continue
            }
            if arg.hasPrefix("--workspace=") {
                let rawWorkspace = String(arg.dropFirst("--workspace=".count))
                let workspaceId = try resolveWorkspaceId(rawWorkspace, client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                index += 1
                continue
            }
            forwardedArgs.append(arg)
            index += 1
        }

        if !resolvedExplicitWorkspace,
           let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride) {
            let workspaceId = try resolveWorkspaceId(workspaceArg, client: client)
            insertArgumentBeforeSeparator("--tab=\(workspaceId)", into: &forwardedArgs)
        }

        let command = ([socketCommand] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        return try sendV1Command(command, client: client)
    }

    /// Pick the display handle for an item dict based on --id-format.
    private func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    private func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["surface", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        return parts.joined(separator: " ")
    }

    enum TreeScope: String {
        case workspace
        case window
        case all
    }

    private struct TreeCommandOptions {
        let scope: TreeScope
        let workspaceHandle: String?
        let jsonOutput: Bool
        /// Floor plan: nil = default per scope, true = force on, false = force off.
        let layoutOverride: Bool?
        let canvasColsOverride: Int?
    }

    private struct TreePath {
        let windowHandle: String?
        let workspaceHandle: String?
        let paneHandle: String?
        let surfaceHandle: String?
    }

    private func runTreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTreeCommandOptions(commandArgs)
        let payload = try buildTreePayload(options: options, client: client)
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(renderTreeText(payload: payload, options: options, idFormat: idFormat))
        }
    }

    private func parseTreeCommandOptions(_ args: [String]) throws -> TreeCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "tree requires --workspace <id|ref|index>")
        }

        let (canvasOpt, rem1) = parseOption(rem0, name: "--canvas-cols")
        if rem1.contains("--canvas-cols") {
            throw CLIError(message: "tree requires --canvas-cols <N>")
        }

        var includeAll = false
        var includeWindow = false
        var jsonOutput = false
        var layoutForceOn = false
        var layoutForceOff = false
        var remaining: [String] = []
        for arg in rem1 {
            switch arg {
            case "--all":
                includeAll = true
            case "--window":
                includeWindow = true
            case "--layout":
                layoutForceOn = true
            case "--no-layout":
                layoutForceOff = true
            case "--json":
                jsonOutput = true
            default:
                remaining.append(arg)
            }
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tree: unknown flag '\(unknown)'. Known flags: --all --window --workspace <id|ref|index> --layout --no-layout --canvas-cols <N> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "tree: unexpected argument '\(extra)'")
        }

        // Conflict detection per spec: at most one of --all, --window, --workspace.
        var scopeFlags: [String] = []
        if includeAll { scopeFlags.append("--all") }
        if includeWindow { scopeFlags.append("--window") }
        if workspaceOpt != nil { scopeFlags.append("--workspace") }
        if scopeFlags.count > 1 {
            let payload: [String: Any] = ["flags": scopeFlags]
            throw CLIError(message: makeStructuredErrorMessage(
                code: "conflicting_flags",
                message: "tree: conflicting scope flags \(scopeFlags.joined(separator: ", "))",
                data: payload
            ))
        }

        if layoutForceOn && layoutForceOff {
            throw CLIError(message: "tree: --layout and --no-layout are mutually exclusive")
        }

        let scope: TreeScope
        if includeAll {
            scope = .all
        } else if includeWindow {
            scope = .window
        } else {
            // Default and --workspace both produce a single workspace in the response.
            scope = .workspace
        }

        var canvasOverride: Int? = nil
        if let raw = canvasOpt {
            guard let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                let payload: [String: Any] = ["value": raw]
                throw CLIError(message: makeStructuredErrorMessage(
                    code: "invalid_canvas_cols",
                    message: "tree: --canvas-cols must be an integer",
                    data: payload
                ))
            }
            guard (40...200).contains(n) else {
                let payload: [String: Any] = ["value": n]
                throw CLIError(message: makeStructuredErrorMessage(
                    code: "invalid_canvas_cols",
                    message: "tree: --canvas-cols must be in [40, 200]",
                    data: payload
                ))
            }
            canvasOverride = n
        }

        let layoutOverride: Bool?
        if layoutForceOn { layoutOverride = true }
        else if layoutForceOff { layoutOverride = false }
        else { layoutOverride = nil }

        return TreeCommandOptions(
            scope: scope,
            workspaceHandle: workspaceOpt,
            jsonOutput: jsonOutput,
            layoutOverride: layoutOverride,
            canvasColsOverride: canvasOverride
        )
    }

    /// Encode an error code + structured data into the message string CLIError
    /// exposes today. Tests look for the `code: ` prefix.
    private func makeStructuredErrorMessage(code: String, message: String, data: [String: Any]) -> String {
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let str = String(data: bytes, encoding: .utf8) {
            return "\(code): \(message) (\(str))"
        }
        return "\(code): \(message)"
    }

    private func buildTreePayload(
        options: TreeCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "scope": options.scope.rawValue,
            // Keep `all_windows` for older servers that haven't seen `scope` yet.
            "all_windows": options.scope == .all
        ]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            let payload = try client.sendV2(method: "system.tree", params: params)
            return treePayloadWithMarkers(payload)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            // Back-compat fallback for older servers that don't support system.tree.
            return try buildLegacyTreePayload(options: options, params: params, client: client)
        }
    }

    private func buildLegacyTreePayload(
        options: TreeCommandOptions,
        params: [String: Any],
        client: SocketClient
    ) throws -> [String: Any] {
        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }

        let identifyPayload = try client.sendV2(method: "system.identify", params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: focused)
        let windows = try buildTreeWindowNodes(options: options, activePath: activePath, client: client)

        return treePayloadWithMarkers([
            "active": focused.isEmpty ? NSNull() : focused,
            "caller": caller.isEmpty ? NSNull() : caller,
            "windows": windows
        ])
    }

    private func buildTreeWindowNodes(
        options: TreeCommandOptions,
        activePath: TreePath,
        client: SocketClient
    ) throws -> [[String: Any]] {
        let windowsPayload = try client.sendV2(method: "window.list")
        let allWindows = windowsPayload["windows"] as? [[String: Any]] ?? []

        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }

            let workspaceListPayload = try client.sendV2(method: "workspace.list", params: ["workspace_id": workspaceHandle])
            let workspaceWindowHandle = (workspaceListPayload["window_ref"] as? String) ?? (workspaceListPayload["window_id"] as? String)
            let window = allWindows.first(where: { treeItemMatchesHandle($0, handle: workspaceWindowHandle) })
                ?? treeFallbackWindow(from: workspaceListPayload)

            let workspaces = workspaceListPayload["workspaces"] as? [[String: Any]] ?? []
            if workspaces.isEmpty {
                throw CLIError(message: "Workspace not found")
            }
            let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
            var node = window
            let isActiveWindow = treeItemMatchesHandle(node, handle: activePath.windowHandle)
            node["current"] = isActiveWindow
            node["active"] = isActiveWindow
            node["workspaces"] = workspaceNodes
            node["workspace_count"] = workspaceNodes.count
            return [node]
        }

        let targetWindows: [[String: Any]]
        if options.scope == .all {
            targetWindows = allWindows
        } else if let currentWindowHandle = activePath.windowHandle {
            let currentOnly = allWindows.filter { treeItemMatchesHandle($0, handle: currentWindowHandle) }
            targetWindows = currentOnly.isEmpty ? Array(allWindows.prefix(1)) : currentOnly
        } else {
            targetWindows = Array(allWindows.prefix(1))
        }

        return try targetWindows.map {
            try buildTreeWindowNode(
                window: $0,
                activePath: activePath,
                client: client
            )
        }
    }

    private func treeFallbackWindow(from payload: [String: Any]) -> [String: Any] {
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        let selectedWorkspace = workspaces.first(where: { ($0["selected"] as? Bool) == true })
        return [
            "id": payload["window_id"] ?? NSNull(),
            "ref": payload["window_ref"] ?? NSNull(),
            "index": 0,
            "key": false,
            "visible": true,
            "workspace_count": workspaces.count,
            "selected_workspace_id": selectedWorkspace?["id"] ?? NSNull(),
            "selected_workspace_ref": selectedWorkspace?["ref"] ?? NSNull(),
        ]
    }

    private func buildTreeWindowNode(
        window: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceParams: [String: Any] = [:]
        if let windowHandle = treeItemHandle(window) {
            workspaceParams["window_id"] = windowHandle
        }
        let workspacePayload = try client.sendV2(method: "workspace.list", params: workspaceParams)
        let workspaces = workspacePayload["workspaces"] as? [[String: Any]] ?? []
        let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
        var windowNode = window
        let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
        windowNode["current"] = isActiveWindow
        windowNode["active"] = isActiveWindow
        windowNode["workspaces"] = workspaceNodes
        windowNode["workspace_count"] = workspaceNodes.count
        return windowNode
    }

    private func buildTreeWorkspaceNode(
        workspace: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceNode = workspace
        guard let workspaceHandle = treeItemHandle(workspace) else {
            workspaceNode["panes"] = []
            return workspaceNode
        }

        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceHandle])
        let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceHandle])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
        let browserURLsByHandle = fetchTreeBrowserURLs(
            workspaceHandle: workspaceHandle,
            surfaces: surfaces,
            client: client
        )

        var surfacesByPane: [String: [[String: Any]]] = [:]
        for surface in surfaces {
            var surfaceNode = surface
            if surfaceNode["selected"] == nil {
                surfaceNode["selected"] = (surfaceNode["selected_in_pane"] as? Bool) == true
            }
            surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)

            let surfaceType = ((surfaceNode["type"] as? String) ?? "").lowercased()
            if surfaceType == "browser",
               let url = treeBrowserURL(surface: surfaceNode, urlsByHandle: browserURLsByHandle),
               !url.isEmpty {
                surfaceNode["url"] = url
            } else {
                surfaceNode["url"] = NSNull()
            }

            guard let paneHandle = treeRelatedHandle(surfaceNode, refKey: "pane_ref", idKey: "pane_id") else {
                continue
            }
            surfacesByPane[paneHandle, default: []].append(surfaceNode)
        }

        for paneHandle in surfacesByPane.keys {
            surfacesByPane[paneHandle]?.sort {
                let lhs = intFromAny($0["index_in_pane"]) ?? intFromAny($0["index"]) ?? Int.max
                let rhs = intFromAny($1["index_in_pane"]) ?? intFromAny($1["index"]) ?? Int.max
                return lhs < rhs
            }
        }

        let paneNodes: [[String: Any]] = panes.map { pane in
            var paneNode = pane
            paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)
            if let paneHandle = treeItemHandle(paneNode) {
                paneNode["surfaces"] = surfacesByPane[paneHandle] ?? []
            } else {
                paneNode["surfaces"] = []
            }
            return paneNode
        }

        workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)
        workspaceNode["panes"] = paneNodes
        return workspaceNode
    }

    private func treeItemHandle(_ item: [String: Any]) -> String? {
        if let ref = item["ref"] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func treeRelatedHandle(_ item: [String: Any], refKey: String, idKey: String) -> String? {
        if let ref = item[refKey] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item[idKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func parseTreePath(payload: [String: Any]) -> TreePath {
        return TreePath(
            windowHandle: treeRelatedHandle(payload, refKey: "window_ref", idKey: "window_id"),
            workspaceHandle: treeRelatedHandle(payload, refKey: "workspace_ref", idKey: "workspace_id"),
            paneHandle: treeRelatedHandle(payload, refKey: "pane_ref", idKey: "pane_id"),
            surfaceHandle: treeRelatedHandle(payload, refKey: "surface_ref", idKey: "surface_id")
        )
    }

    private func treeCallerContextFromEnvironment() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let workspaceRaw = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceRaw = env["CMUX_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var caller: [String: Any] = [:]
        if let workspaceRaw, !workspaceRaw.isEmpty {
            caller["workspace_id"] = workspaceRaw
        }
        if let surfaceRaw, !surfaceRaw.isEmpty {
            caller["surface_id"] = surfaceRaw
        }
        return caller.isEmpty ? nil : caller
    }

    private func treePayloadWithMarkers(_ payload: [String: Any]) -> [String: Any] {
        let active = payload["active"] as? [String: Any] ?? [:]
        let caller = payload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: active)
        let callerPath = parseTreePath(payload: caller)
        var result = payload
        let windows = payload["windows"] as? [[String: Any]] ?? []
        result["windows"] = treeApplyMarkers(windows: windows, activePath: activePath, callerPath: callerPath)
        if result["active"] == nil {
            result["active"] = active.isEmpty ? NSNull() : active
        }
        if result["caller"] == nil {
            result["caller"] = caller.isEmpty ? NSNull() : caller
        }
        return result
    }

    private func treeApplyMarkers(
        windows: [[String: Any]],
        activePath: TreePath,
        callerPath: TreePath
    ) -> [[String: Any]] {
        return windows.map { window in
            var windowNode = window
            let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
            windowNode["current"] = isActiveWindow
            windowNode["active"] = isActiveWindow

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let workspaceNodes = workspaces.map { workspace in
                var workspaceNode = workspace
                workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let paneNodes = panes.map { pane in
                    var paneNode = pane
                    paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    paneNode["surfaces"] = surfaces.map { surface in
                        var surfaceNode = surface
                        surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)
                        surfaceNode["here"] = treeItemMatchesHandle(surfaceNode, handle: callerPath.surfaceHandle)
                        return surfaceNode
                    }
                    return paneNode
                }

                workspaceNode["panes"] = paneNodes
                return workspaceNode
            }

            windowNode["workspaces"] = workspaceNodes
            return windowNode
        }
    }

    private func fetchTreeBrowserURLs(
        workspaceHandle: String,
        surfaces: [[String: Any]],
        client: SocketClient
    ) -> [String: String] {
        let hasBrowserSurfaces = surfaces.contains {
            (($0["type"] as? String) ?? "").lowercased() == "browser"
        }
        guard hasBrowserSurfaces else { return [:] }

        if let payload = try? client.sendV2(
            method: "browser.tab.list",
            params: ["workspace_id": workspaceHandle]
        ) {
            let tabs = payload["tabs"] as? [[String: Any]] ?? []
            var urlByHandle: [String: String] = [:]
            for tab in tabs {
                guard let url = tab["url"] as? String, !url.isEmpty else { continue }
                if let id = tab["id"] as? String, !id.isEmpty {
                    urlByHandle[id] = url
                }
                if let ref = tab["ref"] as? String, !ref.isEmpty {
                    urlByHandle[ref] = url
                }
            }
            return urlByHandle
        }

        // Fallback for older servers that may not support browser.tab.list.
        var fallbackURLs: [String: String] = [:]
        for surface in surfaces {
            guard ((surface["type"] as? String) ?? "").lowercased() == "browser" else { continue }
            guard let surfaceHandle = treeItemHandle(surface) else { continue }
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["workspace_id": workspaceHandle, "surface_id": surfaceHandle]
            ),
            let url = payload["url"] as? String,
            !url.isEmpty else {
                continue
            }
            fallbackURLs[surfaceHandle] = url
            if let id = surface["id"] as? String, !id.isEmpty {
                fallbackURLs[id] = url
            }
            if let ref = surface["ref"] as? String, !ref.isEmpty {
                fallbackURLs[ref] = url
            }
        }
        return fallbackURLs
    }

    private func treeBrowserURL(surface: [String: Any], urlsByHandle: [String: String]) -> String? {
        if let id = surface["id"] as? String, let url = urlsByHandle[id] {
            return url
        }
        if let ref = surface["ref"] as? String, let url = urlsByHandle[ref] {
            return url
        }
        if let handle = treeItemHandle(surface), let url = urlsByHandle[handle] {
            return url
        }
        return nil
    }

    private func treeItemMatchesHandle(_ item: [String: Any], handle: String?) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return false
        }
        return (item["id"] as? String) == handle || (item["ref"] as? String) == handle
    }

    /// Render `cmux tree` text output.
    ///
    /// Output ordering (per M8 spec):
    /// 1. Floor plan(s) — when enabled (default for single-workspace scope).
    /// 2. Hierarchical tree — pane lines now carry `size=`, `px=`, `split=` badges.
    private func renderTreeText(payload: [String: Any], options: TreeCommandOptions, idFormat: CLIIDFormat) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        guard !windows.isEmpty else { return "No windows" }

        // Decide whether to render floor plan(s).
        // Default: on for single-workspace scope, off for --window/--all.
        // Override: --layout forces on, --no-layout forces off. Both ignored under --json (handled by caller).
        let defaultPlanOn = (options.scope == .workspace)
        let planEnabled: Bool
        if let override = options.layoutOverride {
            planEnabled = override
        } else {
            planEnabled = defaultPlanOn
        }

        var sections: [String] = []

        if planEnabled {
            // Render one floor plan per workspace in the response.
            let canvasWidth = resolveFloorPlanCanvasWidth(override: options.canvasColsOverride)
            for window in windows {
                let workspaces = window["workspaces"] as? [[String: Any]] ?? []
                for workspace in workspaces {
                    if let plan = renderFloorPlan(workspace: workspace, canvasWidth: canvasWidth, idFormat: idFormat) {
                        sections.append(plan)
                    }
                }
            }
        }

        // Hierarchical tree.
        var treeLines: [String] = []
        for window in windows {
            treeLines.append(treeWindowLabel(window, idFormat: idFormat))

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for (workspaceIndex, workspace) in workspaces.enumerated() {
                let workspaceIsLast = workspaceIndex == workspaces.count - 1
                let workspaceBranch = workspaceIsLast ? "└── " : "├── "
                let workspaceIndent = workspaceIsLast ? "    " : "│   "
                treeLines.append("\(workspaceBranch)\(treeWorkspaceLabel(workspace, idFormat: idFormat))")

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for (paneIndex, pane) in panes.enumerated() {
                    let paneIsLast = paneIndex == panes.count - 1
                    let paneBranch = paneIsLast ? "└── " : "├── "
                    let paneIndent = paneIsLast ? "    " : "│   "
                    treeLines.append("\(workspaceIndent)\(paneBranch)\(treePaneLabel(pane, idFormat: idFormat))")

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for (surfaceIndex, surface) in surfaces.enumerated() {
                        let surfaceIsLast = surfaceIndex == surfaces.count - 1
                        let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                        treeLines.append("\(workspaceIndent)\(paneIndent)\(surfaceBranch)\(treeSurfaceLabel(surface, idFormat: idFormat))")
                    }
                }
            }
        }
        sections.append(treeLines.joined(separator: "\n"))

        return sections.joined(separator: "\n")
    }

    // MARK: - M8 Floor plan

    /// Resolve the canvas width based on `--canvas-cols` override and TTY size.
    /// - Returns: the chosen width in columns (clamped). Caller should suppress
    ///   the plan if the result is < 40.
    private func resolveFloorPlanCanvasWidth(override: Int?) -> Int {
        if let n = override {
            return n
        }
        if isatty(fileno(stdout)) != 0 {
            var ws = winsize()
            if ioctl(fileno(stdout), UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_col > 0 {
                let cols = Int(ws.ws_col)
                return max(40, min(cols, 160))
            }
        }
        return 80
    }

    /// Render the floor-plan section for one workspace, or nil when there is
    /// nothing to draw (no panes, no content area, or canvas too narrow).
    private func renderFloorPlan(workspace: [String: Any], canvasWidth: Int, idFormat: CLIIDFormat) -> String? {
        let title = (workspace["title"] as? String) ?? ""
        let workspaceHandle = textHandle(workspace, idFormat: idFormat)

        guard canvasWidth >= 40 else {
            return [
                "workspace \(workspaceHandle)\(title.isEmpty ? "" : " \"\(title)\"")",
                "[layout suppressed: canvas <40 cols]"
            ].joined(separator: "\n")
        }

        guard let contentArea = workspace["content_area"] as? [String: Any],
              let pixels = contentArea["pixels"] as? [String: Any],
              let widthRaw = pixels["width"],
              let heightRaw = pixels["height"],
              let contentWidth = doubleValue(widthRaw),
              let contentHeight = doubleValue(heightRaw),
              contentWidth > 0, contentHeight > 0 else {
            return [
                "workspace \(workspaceHandle)\(title.isEmpty ? "" : " \"\(title)\"")  content: not laid out yet",
                "[workspace not laid out — focus it once to populate]"
            ].joined(separator: "\n")
        }

        let panes = workspace["panes"] as? [[String: Any]] ?? []
        guard !panes.isEmpty else { return nil }

        // Canvas height: round(width * (h/w) * 0.5), floor 6, ceiling 60.
        let rawRows = Double(canvasWidth) * (contentHeight / contentWidth) * 0.5
        let canvasHeight = max(6, min(60, Int(rawRows.rounded())))

        let header = "workspace \(workspaceHandle)\(title.isEmpty ? "" : " \"\(title)\"")  content: \(Int(contentWidth.rounded()))×\(Int(contentHeight.rounded())) px"

        // Build per-pane box rectangles in canvas coordinates.
        struct PaneBox {
            let pane: [String: Any]
            // Inclusive col0..col1, row0..row1 ranges in the canvas grid.
            // Border characters live ON these rows/cols (the box body sits inside).
            var col0: Int
            var col1: Int
            var row0: Int
            var row1: Int
        }

        var boxes: [PaneBox] = []
        for pane in panes {
            guard let layout = pane["layout"] as? [String: Any],
                  let percent = layout["percent"] as? [String: Any],
                  let hArr = percent["H"] as? [Any],
                  let vArr = percent["V"] as? [Any],
                  hArr.count == 2, vArr.count == 2,
                  let h0 = doubleValue(hArr[0]),
                  let h1 = doubleValue(hArr[1]),
                  let v0 = doubleValue(vArr[0]),
                  let v1 = doubleValue(vArr[1]) else {
                continue
            }
            // Skip degenerate panes per spec Open Question 5.
            guard h1 > h0, v1 > v0 else { continue }

            // Map percent → canvas grid. Use canvas width-1/height-1 to leave room for closing borders.
            let col0 = Int((Double(canvasWidth - 1) * h0).rounded())
            let col1 = Int((Double(canvasWidth - 1) * h1).rounded())
            let row0 = Int((Double(canvasHeight - 1) * v0).rounded())
            let row1 = Int((Double(canvasHeight - 1) * v1).rounded())
            boxes.append(PaneBox(pane: pane, col0: col0, col1: max(col0 + 1, col1), row0: row0, row1: max(row0 + 1, row1)))
        }

        guard !boxes.isEmpty else { return header }

        // Snap the rightmost/bottommost edges to canvas extents so borders close.
        let maxCol = boxes.map { $0.col1 }.max() ?? (canvasWidth - 1)
        let maxRow = boxes.map { $0.row1 }.max() ?? (canvasHeight - 1)
        for i in boxes.indices {
            if boxes[i].col1 == maxCol { boxes[i].col1 = canvasWidth - 1 }
            if boxes[i].row1 == maxRow { boxes[i].row1 = canvasHeight - 1 }
        }

        // Initialize empty canvas.
        var grid: [[Character]] = Array(
            repeating: Array(repeating: " ", count: canvasWidth),
            count: canvasHeight
        )

        // Draw each box's borders (overwriting safely; junctions get cleaned up below).
        for box in boxes {
            // Horizontal edges.
            for c in box.col0...box.col1 {
                if grid[box.row0][c] == " " { grid[box.row0][c] = "─" }
                if grid[box.row1][c] == " " { grid[box.row1][c] = "─" }
            }
            // Vertical edges.
            for r in box.row0...box.row1 {
                if grid[r][box.col0] == " " { grid[r][box.col0] = "│" }
                if grid[r][box.col1] == " " { grid[r][box.col1] = "│" }
            }
            // Corners (unconditionally — corners are the strongest signal).
            grid[box.row0][box.col0] = "┌"
            grid[box.row0][box.col1] = "┐"
            grid[box.row1][box.col0] = "└"
            grid[box.row1][box.col1] = "┘"
        }

        // Emit T-junctions where vertical/horizontal lines meet a non-corner edge.
        // Junction promotion: pick the strongest character based on the directional
        // signature implied by adjacent panes. Computed by checking neighbor cells.
        for r in 0..<canvasHeight {
            for c in 0..<canvasWidth {
                let ch = grid[r][c]
                if ch != "┌" && ch != "┐" && ch != "└" && ch != "┘" && ch != "─" && ch != "│" {
                    continue
                }
                let up = r > 0 && isBoxChar(grid[r - 1][c])
                let down = r < canvasHeight - 1 && isBoxChar(grid[r + 1][c])
                let left = c > 0 && isBoxChar(grid[r][c - 1])
                let right = c < canvasWidth - 1 && isBoxChar(grid[r][c + 1])
                grid[r][c] = chooseBoxChar(up: up, down: down, left: left, right: right, fallback: ch)
            }
        }

        // Render box bodies (text inside each pane).
        for box in boxes {
            renderBoxBody(
                col0: box.col0, col1: box.col1,
                row0: box.row0, row1: box.row1,
                pane: box.pane,
                grid: &grid,
                idFormat: idFormat
            )
        }

        let planLines = grid.map { String($0).trimmingTrailingWhitespace() }
        return ([header] + planLines).joined(separator: "\n")
    }

    private func isBoxChar(_ ch: Character) -> Bool {
        switch ch {
        case "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼":
            return true
        default:
            return false
        }
    }

    private func chooseBoxChar(up: Bool, down: Bool, left: Bool, right: Bool, fallback: Character) -> Character {
        switch (up, down, left, right) {
        case (true,  true,  true,  true ): return "┼"
        case (true,  true,  true,  false): return "┤"
        case (true,  true,  false, true ): return "├"
        case (false, true,  true,  true ): return "┬"
        case (true,  false, true,  true ): return "┴"
        case (true,  true,  false, false): return "│"
        case (false, false, true,  true ): return "─"
        case (true,  false, false, true ): return "└"
        case (true,  false, true,  false): return "┘"
        case (false, true,  false, true ): return "┌"
        case (false, true,  true,  false): return "┐"
        default: return fallback
        }
    }

    private func renderBoxBody(
        col0: Int, col1: Int, row0: Int, row1: Int,
        pane: [String: Any],
        grid: inout [[Character]],
        idFormat: CLIIDFormat
    ) {
        let bodyCols = max(0, col1 - col0 - 1)
        let bodyRows = max(0, row1 - row0 - 1)
        if bodyCols < 1 || bodyRows < 1 { return }

        let paneRef = textHandle(pane, idFormat: idFormat)
        // Surface info for selected tab title (line 5) and tab count (line 4).
        let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
        let surfaceCount = (pane["surface_count"] as? Int) ?? surfaces.count
        let selectedTitle: String = {
            for s in surfaces {
                if (s["selected"] as? Bool) == true || (s["focused"] as? Bool) == true {
                    return (s["title"] as? String) ?? ""
                }
            }
            return (surfaces.first?["title"] as? String) ?? ""
        }()

        // Layout info for lines 2/3.
        let percentLine: String
        let pixelLine: String
        if let layout = pane["layout"] as? [String: Any],
           let pct = layout["percent"] as? [String: Any],
           let hArr = pct["H"] as? [Any],
           let vArr = pct["V"] as? [Any],
           hArr.count == 2, vArr.count == 2,
           let h0 = doubleValue(hArr[0]),
           let h1 = doubleValue(hArr[1]),
           let v0 = doubleValue(vArr[0]),
           let v1 = doubleValue(vArr[1]) {
            let widthPct = Int(((h1 - h0) * 100).rounded())
            let heightPct = Int(((v1 - v0) * 100).rounded())
            percentLine = "\(widthPct)%W × \(heightPct)%H"
            if let pix = layout["pixels"] as? [String: Any],
               let pixH = pix["H"] as? [Any], pixH.count == 2,
               let pixV = pix["V"] as? [Any], pixV.count == 2,
               let ph0 = doubleValue(pixH[0]), let ph1 = doubleValue(pixH[1]),
               let pv0 = doubleValue(pixV[0]), let pv1 = doubleValue(pixV[1]) {
                pixelLine = "\(Int(ph1 - ph0))×\(Int(pv1 - pv0)) px"
            } else {
                pixelLine = "? px"
            }
        } else {
            percentLine = "?% × ?%"
            pixelLine = "? px"
        }
        let tabLine = surfaceCount == 1 ? "1 tab" : "\(surfaceCount) tabs"
        let titleLine = "* \(selectedTitle)"

        // Narrow-pane single-line collapse (per spec): inside-body width < 13 (so box width < 15).
        if bodyCols < 13 {
            // Collapsed: single-line "p:N W%W×H%H px×px Ntabs", truncated with "…".
            // Use "p:N" prefix (drop "pane:" prefix).
            let shortRef: String = {
                if let r = pane["ref"] as? String, let colon = r.firstIndex(of: ":") {
                    return "p:\(r[r.index(after: colon)...])"
                }
                return paneRef
            }()
            let summary = "\(shortRef) \(percentLine.replacingOccurrences(of: " × ", with: "×")) \(pixelLine) \(tabLine)"
                .replacingOccurrences(of: "%W×", with: "%W×")
            let row = row0 + 1
            if row >= grid.count { return }
            writeStringIntoRow(&grid, row: row, col: col0 + 1, maxCols: bodyCols, text: summary)
            return
        }

        // Standard 5-line body. Drop lines from the bottom if not enough rows.
        var lines: [String] = [paneRef, percentLine, pixelLine, tabLine, titleLine]
        if bodyRows < 5 {
            // Drop line 5 first, then 4, then 3.
            let toKeep = max(2, bodyRows)
            lines = Array(lines.prefix(toKeep))
        }

        // Truncate line 5 if title too wide. If even "*…" doesn't fit, drop it.
        if lines.count >= 5 {
            let maxTitle = bodyCols - 2  // "* " prefix
            if maxTitle < 2 {
                lines.removeLast()
            } else if selectedTitle.count > maxTitle {
                let cut = max(0, maxTitle - 1)
                let prefix = String(selectedTitle.prefix(cut))
                lines[4] = "* \(prefix)…"
            }
        }

        for (i, line) in lines.enumerated() {
            let row = row0 + 1 + i
            if row >= row1 { break }
            writeStringIntoRow(&grid, row: row, col: col0 + 1, maxCols: bodyCols, text: line)
        }
    }

    private func writeStringIntoRow(_ grid: inout [[Character]], row: Int, col: Int, maxCols: Int, text: String) {
        if row < 0 || row >= grid.count { return }
        var write = text
        if write.count > maxCols {
            // Truncate with ellipsis if there's room, else hard-cut.
            if maxCols >= 1 {
                write = String(write.prefix(max(0, maxCols - 1))) + "…"
            } else {
                return
            }
        }
        var c = col
        for ch in write {
            if c >= grid[row].count { break }
            if c >= col + maxCols { break }
            grid[row][c] = ch
            c += 1
        }
    }

    private func doubleValue(_ raw: Any) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s) { return d }
        return nil
    }

    private func treeWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["current"] as? Bool) == true {
            parts.append("[current]")
        }
        if (window["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = (workspace["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treePaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]

        // M8 badges: size=W%×H% px=W×H split=...
        // Render between the pane ref and the bracketed markers.
        let layout = pane["layout"] as? [String: Any]
        let percent = layout?["percent"] as? [String: Any]
        let pixels = layout?["pixels"] as? [String: Any]

        let sizeBadge: String
        if let pct = percent,
           let hArr = pct["H"] as? [Any], hArr.count == 2,
           let vArr = pct["V"] as? [Any], vArr.count == 2,
           let h0 = doubleValue(hArr[0]), let h1 = doubleValue(hArr[1]),
           let v0 = doubleValue(vArr[0]), let v1 = doubleValue(vArr[1]) {
            let widthPct = Int(((h1 - h0) * 100).rounded())
            let heightPct = Int(((v1 - v0) * 100).rounded())
            sizeBadge = "size=\(widthPct)%×\(heightPct)%"
        } else {
            sizeBadge = "size=?"
        }
        parts.append(sizeBadge)

        let pxBadge: String
        if let pix = pixels,
           let hArr = pix["H"] as? [Any], hArr.count == 2,
           let vArr = pix["V"] as? [Any], vArr.count == 2,
           let h0 = doubleValue(hArr[0]), let h1 = doubleValue(hArr[1]),
           let v0 = doubleValue(vArr[0]), let v1 = doubleValue(vArr[1]) {
            pxBadge = "px=\(Int((h1 - h0).rounded()))×\(Int((v1 - v0).rounded()))"
        } else {
            pxBadge = "px=?"
        }
        parts.append(pxBadge)

        let splitBadge: String
        if let path = layout?["split_path"] as? [String] {
            splitBadge = path.isEmpty ? "split=none" : "split=\(path.joined(separator: ","))"
        } else {
            splitBadge = "split=?"
        }
        parts.append(splitBadge)

        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        if (pane["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = ((surface["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = (surface["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (surface["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        if (surface["here"] as? Bool) == true {
            parts.append("◀ here")
        }
        if surfaceType.lowercased() == "browser",
           let url = surface["url"] as? String,
           !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    private func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }

    private func printBrandHuman(_ response: Any) {
        guard let dict = response as? [String: Any] else {
            print(jsonString(response))
            return
        }
        let channel = dict["channel"] as? String ?? "unknown"
        let bundle = dict["bundle"] as? [String: Any] ?? [:]
        let palette = dict["palette"] as? [String: String] ?? [:]
        let accent = dict["accent_hex"] as? String ?? ""
        let font = dict["font_family"] as? String ?? ""
        let displayName = bundle["display_name"] as? String ?? ""
        let identifier = bundle["identifier"] as? String ?? ""
        let iconName = bundle["icon_name"] as? String ?? ""
        let shortVersion = bundle["short_version"] as? String ?? ""
        let build = bundle["build"] as? String ?? ""
        print("\(displayName) \(shortVersion) (build \(build))")
        print("channel:    \(channel)")
        print("identifier: \(identifier)")
        print("icon:       \(iconName)")
        print("accent:     \(accent)")
        print("font:       \(font)")
        print("palette:")
        let order = ["black", "surface", "rule", "dim", "white", "gold", "gold_faint"]
        for key in order {
            if let hex = palette[key] {
                print("  \(key.padding(toLength: 11, withPad: " ", startingAt: 0)) \(hex)")
            }
        }
    }

    private func jsonString(_ object: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.withoutEscapingSlashes)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private struct TmuxParsedArguments {
        var flags: Set<String> = []
        var options: [String: [String]] = [:]
        var positional: [String] = []

        func hasFlag(_ flag: String) -> Bool {
            flags.contains(flag)
        }

        func value(_ flag: String) -> String? {
            options[flag]?.last
        }
    }

    private func parseTmuxArguments(
        _ args: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) throws -> TmuxParsedArguments {
        var parsed = TmuxParsedArguments()
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let arg = args[index]
            if pastTerminator {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if !arg.hasPrefix("-") || arg == "-" {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                parsed.positional.append(arg)
                index += 1
                continue
            }

            let cluster = Array(arg.dropFirst())
            var cursor = 0
            var recognizedArgument = false
            while cursor < cluster.count {
                let flag = "-" + String(cluster[cursor])
                if boolFlags.contains(flag) {
                    parsed.flags.insert(flag)
                    cursor += 1
                    recognizedArgument = true
                    continue
                }
                if valueFlags.contains(flag) {
                    let remainder = String(cluster.dropFirst(cursor + 1))
                    let value: String
                    if !remainder.isEmpty {
                        value = remainder
                    } else {
                        guard index + 1 < args.count else {
                            throw CLIError(message: "\(flag) requires a value")
                        }
                        index += 1
                        value = args[index]
                    }
                    parsed.options[flag, default: []].append(value)
                    recognizedArgument = true
                    cursor = cluster.count
                    continue
                }

                recognizedArgument = false
                break
            }

            if !recognizedArgument {
                parsed.positional.append(arg)
            }
            index += 1
        }

        return parsed
    }

    private func splitTmuxCommand(_ args: [String]) throws -> (command: String, args: [String]) {
        var index = 0
        let globalValueFlags: Set<String> = ["-L", "-S", "-f"]

        while index < args.count {
            let arg = args[index]
            if !arg.hasPrefix("-") || arg == "-" {
                return (arg.lowercased(), Array(args.dropFirst(index + 1)))
            }
            if arg == "--" {
                break
            }
            if let flag = globalValueFlags.first(where: { arg == $0 || arg.hasPrefix($0) }) {
                if arg == flag {
                    index += 1
                }
            }
            index += 1
        }

        throw CLIError(message: "tmux shim requires a command")
    }

    private func normalizedTmuxTarget(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tmuxWindowSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") || trimmed.hasPrefix("pane:") {
            return nil
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[..<dot])
        }
        return trimmed
    }

    private func tmuxPaneSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("pane:") {
            return trimmed
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dot)...])
        }
        return nil
    }

    private func tmuxWorkspaceItems(client: SocketClient) throws -> [[String: Any]] {
        let payload = try client.sendV2(method: "workspace.list")
        return payload["workspaces"] as? [[String: Any]] ?? []
    }

    private func tmuxCallerWorkspaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"])
    }

    private func tmuxCallerPaneHandle() -> String? {
        guard let pane = normalizedTmuxTarget(ProcessInfo.processInfo.environment["TMUX_PANE"])
            ?? normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_PANE_ID"]) else {
            return nil
        }
        return pane.hasPrefix("%") ? String(pane.dropFirst()) : pane
    }

    private func tmuxCallerSurfaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
    }

    private func tmuxCanonicalPaneId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if isUUID(handle) {
            return handle
        }

        let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            if (pane["ref"] as? String) == handle || (pane["id"] as? String) == handle {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for pane in panes where intFromAny(pane["index"]) == index {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Pane target not found")
    }

    private func tmuxCanonicalSurfaceId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if isUUID(handle) {
            return handle
        }

        let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            if (surface["ref"] as? String) == handle || (surface["id"] as? String) == handle {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        if let index = Int(handle) {
            for surface in surfaces where intFromAny(surface["index"]) == index {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Surface target not found")
    }

    private func tmuxWorkspaceIdForPaneHandle(_ handle: String, client: SocketClient) throws -> String? {
        guard isUUID(handle) || isHandleRef(handle) else {
            return nil
        }

        let workspaces = try tmuxWorkspaceItems(client: client)
        for workspace in workspaces {
            guard let workspaceId = workspace["id"] as? String else { continue }
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            if panes.contains(where: { ($0["id"] as? String) == handle || ($0["ref"] as? String) == handle }) {
                return workspaceId
            }
        }

        return nil
    }

    private func tmuxFocusedPaneId(workspaceId: String, client: SocketClient) throws -> String {
        let payload = try client.sendV2(method: "surface.current", params: ["workspace_id": workspaceId])
        if let paneId = payload["pane_id"] as? String {
            return paneId
        }
        if let paneRef = payload["pane_ref"] as? String {
            return try tmuxCanonicalPaneId(paneRef, workspaceId: workspaceId, client: client)
        }
        throw CLIError(message: "Pane target not found")
    }

    private func tmuxResolveWorkspaceTarget(_ raw: String?, client: SocketClient) throws -> String {
        guard var token = normalizedTmuxTarget(raw) else {
            if let callerWorkspace = tmuxCallerWorkspaceHandle() {
                return try resolveWorkspaceId(callerWorkspace, client: client)
            }
            return try resolveWorkspaceId(nil, client: client)
        }

        if token == "!" || token == "^" || token == "-" {
            let payload = try client.sendV2(method: "workspace.last")
            if let workspaceId = payload["workspace_id"] as? String {
                return workspaceId
            }
            throw CLIError(message: "Previous workspace not found")
        }

        if let dot = token.lastIndex(of: ".") {
            token = String(token[..<dot])
        }
        if let colon = token.lastIndex(of: ":") {
            let suffix = token[token.index(after: colon)...]
            token = suffix.isEmpty ? String(token[..<colon]) : String(suffix)
        }
        if token.hasPrefix("@") {
            token = String(token.dropFirst())
        }

        if let resolvedHandle = try? normalizeWorkspaceHandle(token, client: client, allowCurrent: true) {
            return try resolveWorkspaceId(resolvedHandle, client: client)
        }

        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try tmuxWorkspaceItems(client: client)
        if let match = items.first(where: {
            (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }), let id = match["id"] as? String {
            return id
        }

        throw CLIError(message: "Workspace target not found: \(token)")
    }

    private func tmuxResolvePaneTarget(_ raw: String?, client: SocketClient) throws -> (workspaceId: String, paneId: String) {
        let paneSelector = tmuxPaneSelector(from: raw)
        let workspaceSelector = tmuxWindowSelector(from: raw)
        let workspaceId: String = {
            if let workspaceSelector {
                return (try? tmuxResolveWorkspaceTarget(workspaceSelector, client: client)) ?? ""
            }
            if let paneSelector,
               let workspaceId = try? tmuxWorkspaceIdForPaneHandle(paneSelector, client: client) {
                return workspaceId
            }
            return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
        }()
        guard !workspaceId.isEmpty else {
            throw CLIError(message: "Workspace target not found")
        }
        let paneId: String
        if let paneSelector {
            paneId = try tmuxCanonicalPaneId(paneSelector, workspaceId: workspaceId, client: client)
        } else if tmuxCallerWorkspaceHandle() == workspaceId,
                  let callerPane = tmuxCallerPaneHandle(),
                  let callerPaneId = try? tmuxCanonicalPaneId(callerPane, workspaceId: workspaceId, client: client) {
            paneId = callerPaneId
        } else {
            paneId = try tmuxFocusedPaneId(workspaceId: workspaceId, client: client)
        }
        return (workspaceId, paneId)
    }

    private func tmuxSelectedSurfaceId(
        workspaceId: String,
        paneId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(
            method: "pane.surfaces",
            params: ["workspace_id": workspaceId, "pane_id": paneId]
        )
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        if let selected = surfaces.first(where: { ($0["selected"] as? Bool) == true }),
           let id = selected["id"] as? String {
            return id
        }
        if let first = surfaces.first?["id"] as? String {
            return first
        }
        throw CLIError(message: "Pane has no surface to target")
    }

    private func tmuxResolveSurfaceTarget(
        _ raw: String?,
        client: SocketClient
    ) throws -> (workspaceId: String, paneId: String?, surfaceId: String) {
        if tmuxPaneSelector(from: raw) != nil {
            let resolved = try tmuxResolvePaneTarget(raw, client: client)
            let surfaceId = try tmuxSelectedSurfaceId(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                client: client
            )
            return (resolved.workspaceId, resolved.paneId, surfaceId)
        }

        let workspaceId = try tmuxResolveWorkspaceTarget(tmuxWindowSelector(from: raw), client: client)
        if tmuxWindowSelector(from: raw) == nil,
           tmuxCallerWorkspaceHandle() == workspaceId,
           let callerSurface = tmuxCallerSurfaceHandle(),
           let surfaceId = try? tmuxCanonicalSurfaceId(callerSurface, workspaceId: workspaceId, client: client) {
            return (workspaceId, nil, surfaceId)
        }
        let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
        return (workspaceId, nil, surfaceId)
    }

    private func tmuxRenderFormat(
        _ format: String?,
        context: [String: String],
        fallback: String
    ) -> String {
        guard let format, !format.isEmpty else { return fallback }
        var rendered = format
        for (key, value) in context {
            rendered = rendered.replacingOccurrences(of: "#{\(key)}", with: value)
        }
        rendered = rendered.replacingOccurrences(
            of: "#\\{[^}]+\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func tmuxFormatContext(
        workspaceId: String,
        paneId: String? = nil,
        surfaceId: String? = nil,
        client: SocketClient
    ) throws -> [String: String] {
        let canonicalWorkspaceId = try resolveWorkspaceId(workspaceId, client: client)
        var context: [String: String] = [
            "session_name": "cmux",
            "window_id": "@\(canonicalWorkspaceId)",
            "window_uuid": canonicalWorkspaceId
        ]

        let workspaceItems = try tmuxWorkspaceItems(client: client)
        if let workspace = workspaceItems.first(where: {
            ($0["id"] as? String) == canonicalWorkspaceId || ($0["ref"] as? String) == workspaceId
        }) {
            if let index = intFromAny(workspace["index"]) {
                context["window_index"] = String(index)
            }
            let title = ((workspace["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                context["window_name"] = title
            }
        }

        let currentPayload = try client.sendV2(method: "surface.current", params: ["workspace_id": canonicalWorkspaceId])
        let resolvedPaneId: String? = try {
            if let paneId {
                return try tmuxCanonicalPaneId(paneId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let currentPaneId = currentPayload["pane_id"] as? String {
                return currentPaneId
            }
            if let currentPaneRef = currentPayload["pane_ref"] as? String {
                return try tmuxCanonicalPaneId(currentPaneRef, workspaceId: canonicalWorkspaceId, client: client)
            }
            return nil
        }()
        let resolvedSurfaceId: String? = try {
            if let surfaceId {
                return try tmuxCanonicalSurfaceId(surfaceId, workspaceId: canonicalWorkspaceId, client: client)
            }
            if let resolvedPaneId {
                return try tmuxSelectedSurfaceId(
                    workspaceId: canonicalWorkspaceId,
                    paneId: resolvedPaneId,
                    client: client
                )
            }
            return currentPayload["surface_id"] as? String
        }()

        if let resolvedPaneId {
            context["pane_id"] = "%\(resolvedPaneId)"
            context["pane_uuid"] = resolvedPaneId
            let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": canonicalWorkspaceId])
            let panes = panePayload["panes"] as? [[String: Any]] ?? []
            if let pane = panes.first(where: { ($0["id"] as? String) == resolvedPaneId }),
               let index = intFromAny(pane["index"]) {
                context["pane_index"] = String(index)
            }
        }

        if let resolvedSurfaceId {
            context["surface_id"] = resolvedSurfaceId
            let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": canonicalWorkspaceId])
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            if let surface = surfaces.first(where: { ($0["id"] as? String) == resolvedSurfaceId }) {
                let title = ((surface["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    context["pane_title"] = title
                    context["window_name"] = context["window_name"] ?? title
                }
            }
        }

        return context
    }

    private func tmuxShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func tmuxShellCommandText(commandTokens: [String], cwd: String?) -> String? {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandText = commandTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedCwd?.isEmpty == false) || !commandText.isEmpty else {
            return nil
        }

        var pieces: [String] = []
        if let trimmedCwd, !trimmedCwd.isEmpty {
            pieces.append("cd -- \(tmuxShellQuote(resolvePath(trimmedCwd)))")
        }
        if !commandText.isEmpty {
            pieces.append(commandText)
        }
        return pieces.joined(separator: " && ") + "\r"
    }

    private func tmuxSpecialKeyText(_ token: String) -> String? {
        switch token.lowercased() {
        case "enter", "c-m", "kpenter":
            return "\r"
        case "tab", "c-i":
            return "\t"
        case "space":
            return " "
        case "bspace", "backspace":
            return "\u{7f}"
        case "escape", "esc", "c-[":
            return "\u{1b}"
        case "c-c":
            return "\u{03}"
        case "c-d":
            return "\u{04}"
        case "c-z":
            return "\u{1a}"
        case "c-l":
            return "\u{0c}"
        default:
            return nil
        }
    }

    private func tmuxSendKeysText(from tokens: [String], literal: Bool) -> String {
        if literal {
            return tokens.joined(separator: " ")
        }

        var result = ""
        var pendingSpace = false
        for token in tokens {
            if let special = tmuxSpecialKeyText(token) {
                result += special
                pendingSpace = false
                continue
            }
            if pendingSpace {
                result += " "
            }
            result += token
            pendingSpace = true
        }
        return result
    }

    private func prependPathEntries(_ newEntries: [String], to currentPath: String?) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in newEntries + (currentPath?.split(separator: ":").map(String.init) ?? []) where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    private struct ClaudeTeamsFocusedContext {
        let socketPath: String
        let workspaceId: String
        let windowId: String?
        let paneHandle: String
        let paneId: String?
        let surfaceId: String?
    }

    private func claudeTeamsResolvedSocketPath(processEnvironment: [String: String]) -> String {
        let envSocketPath: String? = {
            for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
                guard let raw = processEnvironment[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()

        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }

        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment
        )
    }

    private func claudeTeamsFocusedContext(
        processEnvironment: [String: String],
        explicitPassword: String?
    ) -> ClaudeTeamsFocusedContext? {
        let socketPath = claudeTeamsResolvedSocketPath(processEnvironment: processEnvironment)
        let client = SocketClient(path: socketPath)

        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            defer { client.close() }

            let payload = try client.sendV2(method: "system.identify")
            let focused = payload["focused"] as? [String: Any] ?? [:]

            let workspaceId = (focused["workspace_id"] as? String)
                ?? (focused["workspace_ref"] as? String)
            let paneId = (focused["pane_id"] as? String)
                ?? (focused["pane_ref"] as? String)

            guard let workspaceId, let paneId else {
                return nil
            }

            let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneHandle.isEmpty else {
                return nil
            }

            let windowId = (focused["window_id"] as? String)
                ?? (focused["window_ref"] as? String)
            let surfaceId = (focused["surface_id"] as? String)
                ?? (focused["surface_ref"] as? String)

            return ClaudeTeamsFocusedContext(
                socketPath: socketPath,
                workspaceId: workspaceId,
                windowId: windowId,
                paneHandle: paneHandle,
                paneId: focused["pane_id"] as? String,
                surfaceId: surfaceId
            )
        } catch {
            client.close()
            return nil
        }
    }

    private func isCmuxClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    private func resolveClaudeExecutable(searchPath: String?) -> String? {
        let entries = searchPath?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent("claude", isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            guard !isCmuxClaudeWrapper(at: candidate) else { continue }
            return candidate
        }
        return nil
    }

    private func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    private func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }

    private func configureClaudeTeamsEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: ClaudeTeamsFocusedContext?
    ) {
        let updatedPath = prependPathEntries(
            [shimDirectory.path],
            to: processEnvironment["PATH"]
        )
        let fakeTmuxValue: String = {
            if let focusedContext {
                let windowToken = focusedContext.windowId ?? focusedContext.workspaceId
                return "/tmp/cmux-claude-teams/\(focusedContext.workspaceId),\(windowToken),\(focusedContext.paneHandle)"
            }
            return processEnvironment["TMUX"] ?? "/tmp/cmux-claude-teams/default,0,0"
        }()
        let fakeTmuxPane = focusedContext.map { "%\($0.paneHandle)" }
            ?? processEnvironment["TMUX_PANE"]
            ?? "%1"
        let fakeTerm = processEnvironment["CMUX_CLAUDE_TEAMS_TERM"] ?? "screen-256color"

        setenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "1", 1)
        setenv("CMUX_CLAUDE_TEAMS_CMUX_BIN", executablePath, 1)
        setenv("PATH", updatedPath, 1)
        setenv("TMUX", fakeTmuxValue, 1)
        setenv("TMUX_PANE", fakeTmuxPane, 1)
        setenv("TERM", fakeTerm, 1)
        setenv("CMUX_SOCKET_PATH", socketPath, 1)
        setenv("CMUX_SOCKET", socketPath, 1)
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_SOCKET_PASSWORD", explicitPassword, 1)
        }
        unsetenv("TERM_PROGRAM")
        if let focusedContext {
            setenv("CMUX_WORKSPACE_ID", focusedContext.workspaceId, 1)
            if let surfaceId = focusedContext.surfaceId, !surfaceId.isEmpty {
                setenv("CMUX_SURFACE_ID", surfaceId, 1)
            }
        }
    }

    private func createClaudeTeamsShimDirectory() throws -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let rootPath = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("claude-teams-bin", isDirectory: true)
            .path
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let tmuxURL = root.appendingPathComponent("tmux", isDirectory: false)
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        let normalizedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingScript = try? String(contentsOf: tmuxURL, encoding: .utf8)
        if existingScript?.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedScript {
            try script.write(to: tmuxURL, atomically: false, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmuxURL.path)
        return root
    }

    private func runClaudeTeams(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment["CMUX_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }
        let shimDirectory = try createClaudeTeamsShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = claudeTeamsFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        let bundledClaudePath = resolvedExecutableURL()?
            .deletingLastPathComponent()
            .appendingPathComponent("claude", isDirectory: false)
            .path
        let claudeExecutablePath = resolveClaudeExecutable(searchPath: launcherEnvironment["PATH"])
            ?? {
                guard let bundledClaudePath,
                      FileManager.default.isExecutableFile(atPath: bundledClaudePath) else { return nil }
                return bundledClaudePath
            }()
        configureClaudeTeamsEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = claudeExecutablePath ?? "claude"
        let launchArguments = claudeTeamsLaunchArguments(commandArgs: commandArgs)
        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if claudeExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp("claude", &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch claude: \(String(cString: strerror(code)))")
    }

    private func runClaudeTeamsTmuxCompat(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (command, rawArgs) = try splitTmuxCommand(commandArgs)

        switch command {
        case "new-session", "new":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-s"],
                boolFlags: ["-A", "-d", "-P"]
            )
            if parsed.hasFlag("-A") {
                throw CLIError(message: "new-session -A is not supported in c11 claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n") ?? parsed.value("-s"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "new-window", "neww":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-t"],
                boolFlags: ["-d", "-P"]
            )
            if parsed.value("-t") != nil {
                throw CLIError(message: "new-window -t is not supported in c11 claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "split-window", "splitw":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-l", "-t"],
                boolFlags: ["-P", "-b", "-d", "-h", "-v"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let direction: String
            if parsed.hasFlag("-h") {
                direction = parsed.hasFlag("-b") ? "left" : "right"
            } else {
                direction = parsed.hasFlag("-b") ? "up" : "down"
            }
            let created = try client.sendV2(method: "surface.split", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "direction": direction
            ])
            guard let surfaceId = created["surface_id"] as? String else {
                throw CLIError(message: "surface.split did not return surface_id")
            }
            let paneId = created["pane_id"] as? String
            // Keep the leader pane focused while Claude starts teammates beside it.
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(
                    workspaceId: target.workspaceId,
                    paneId: paneId,
                    surfaceId: surfaceId,
                    client: client
                )
                let fallback = context["pane_id"] ?? surfaceId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "select-window", "selectw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": workspaceId])

        case "select-pane", "selectp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-P", "-T", "-t"], boolFlags: [])
            if parsed.value("-P") != nil || parsed.value("-T") != nil {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "pane.focus", params: [
                "workspace_id": target.workspaceId,
                "pane_id": target.paneId
            ])

        case "kill-window", "killw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])

        case "kill-pane", "killp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "surface.close", params: [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId
            ])

        case "send-keys", "send":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-l"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let text = tmuxSendKeysText(from: parsed.positional, literal: parsed.hasFlag("-l"))
            if !text.isEmpty {
                _ = try client.sendV2(method: "surface.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "surface_id": target.surfaceId,
                    "text": text
                ])
            }

        case "capture-pane", "capturep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-E", "-S", "-t"],
                boolFlags: ["-J", "-N", "-p"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "surface_id": target.surfaceId,
                "scrollback": true
            ]
            if let start = parsed.value("-S"), let lines = Int(start), lines < 0 {
                params["lines"] = abs(lines)
            }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            if parsed.hasFlag("-p") {
                print(text)
            } else {
                var store = loadTmuxCompatStore()
                store.buffers["default"] = text
                try saveTmuxCompatStore(store)
            }

        case "display-message", "display", "displayp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: ["-p"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let context = try tmuxFormatContext(
                workspaceId: target.workspaceId,
                paneId: target.paneId,
                surfaceId: target.surfaceId,
                client: client
            )
            let format = parsed.positional.isEmpty ? parsed.value("-F") : parsed.positional.joined(separator: " ")
            let rendered = tmuxRenderFormat(format, context: context, fallback: "")
            if parsed.hasFlag("-p") || !rendered.isEmpty {
                print(rendered)
            }

        case "list-windows", "lsw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let items = try tmuxWorkspaceItems(client: client)
            for item in items {
                guard let workspaceId = item["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                let fallback = [
                    context["window_index"] ?? "?",
                    context["window_name"] ?? workspaceId
                ].joined(separator: " ")
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "list-panes", "lsp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            for pane in panes {
                guard let paneId = pane["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, paneId: paneId, client: client)
                let fallback = context["pane_id"] ?? paneId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "rename-window", "renamew":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let title = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "rename-window requires a title")
            }
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": workspaceId,
                "title": title
            ])

        case "resize-pane", "resizep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-t", "-x", "-y"],
                boolFlags: ["-D", "-L", "-R", "-U"]
            )
            let hasDirectionalFlags = parsed.hasFlag("-L")
                || parsed.hasFlag("-R")
                || parsed.hasFlag("-U")
                || parsed.hasFlag("-D")
            if !hasDirectionalFlags {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            let direction: String
            if parsed.hasFlag("-L") {
                direction = "left"
            } else if parsed.hasFlag("-U") {
                direction = "up"
            } else if parsed.hasFlag("-D") {
                direction = "down"
            } else {
                direction = "right"
            }
            let rawAmount = (parsed.value("-x") ?? parsed.value("-y") ?? "5")
                .replacingOccurrences(of: "%", with: "")
            let amount = Int(rawAmount) ?? 5
            _ = try client.sendV2(method: "pane.resize", params: [
                "workspace_id": target.workspaceId,
                "pane_id": target.paneId,
                "direction": direction,
                "amount": max(1, amount)
            ])

        case "wait-for":
            try runTmuxCompatCommand(
                command: "wait-for",
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "last-pane":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "pane.last", params: ["workspace_id": workspaceId])

        case "show-buffer", "showb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            if let buffer = store.buffers[name] {
                print(buffer)
            }

        case "save-buffer", "saveb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            if let outputPath = parsed.positional.last, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try buffer.write(toFile: resolvePath(outputPath), atomically: true, encoding: .utf8)
            } else {
                print(buffer)
            }

        case "last-window", "next-window", "previous-window", "set-hook", "set-buffer", "list-buffers":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "has-session", "has":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            _ = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)

        case "select-layout", "set-option", "set", "set-window-option", "setw", "source-file", "refresh-client", "attach-session", "detach-client":
            return

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    private struct TmuxCompatStore: Codable {
        var buffers: [String: String] = [:]
        var hooks: [String: String] = [:]
    }

    private func tmuxCompatStoreURL() -> URL {
        let root = NSString(string: "~/.cmuxterm").expandingTildeInPath
        return URL(fileURLWithPath: root).appendingPathComponent("tmux-compat-store.json")
    }

    private func loadTmuxCompatStore() -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return TmuxCompatStore()
        }
        return decoded
    }

    private func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }

    private func runShellCommand(_ command: String, stdinText: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if let data = stdinText.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func tmuxWaitForSignalURL(name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return URL(fileURLWithPath: "/tmp/cmux-wait-for-\(String(sanitized)).sig")
    }

    private func runTmuxCompatCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        switch command {
        case "capture-pane":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--surface")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let workspaceArg = wsArg ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["surface_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "surface.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "resize-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let amountArg = optionValue(commandArgs, name: "--amount")
            let amount = Int(amountArg ?? "1") ?? 1
            if amount <= 0 {
                throw CLIError(message: "--amount must be greater than 0")
            }

            let direction: String = {
                if commandArgs.contains("-L") { return "left" }
                if commandArgs.contains("-R") { return "right" }
                if commandArgs.contains("-U") { return "up" }
                if commandArgs.contains("-D") { return "down" }
                return "right"
            }()

            var params: [String: Any] = ["direction": direction, "amount": amount]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let paneId { params["pane_id"] = paneId }
            let payload = try client.sendV2(method: "pane.resize", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "pipe-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (cmdOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText: String = {
                if let cmdOpt { return cmdOpt }
                let trimmed = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }()
            guard !commandText.isEmpty else {
                throw CLIError(message: "pipe-pane requires --command <shell-command>")
            }

            var params: [String: Any] = ["scrollback": true]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            let shell = try runShellCommand(commandText, stdinText: text)
            if shell.status != 0 {
                throw CLIError(message: "pipe-pane command failed (\(shell.status)): \(shell.stderr)")
            }
            if jsonOutput {
                print(jsonString([
                    "ok": true,
                    "status": shell.status,
                    "stdout": shell.stdout,
                    "stderr": shell.stderr
                ]))
            } else {
                if !shell.stdout.isEmpty {
                    print(shell.stdout, terminator: "")
                }
                print("OK")
            }

        case "wait-for":
            let signal = commandArgs.contains("-S") || commandArgs.contains("--signal")
            let timeoutRaw = optionValue(commandArgs, name: "--timeout")
            let timeout = timeoutRaw.flatMap { Double($0) } ?? 30.0
            let name = commandArgs.first(where: { !$0.hasPrefix("-") }) ?? ""
            guard !name.isEmpty else {
                throw CLIError(message: "wait-for requires a name")
            }
            let signalURL = tmuxWaitForSignalURL(name: name)
            if signal {
                FileManager.default.createFile(atPath: signalURL.path, contents: Data())
                print("OK")
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            do {
                try SocketClient.waitForFilesystemPath(signalURL.path, timeout: max(0, deadline.timeIntervalSinceNow))
                try? FileManager.default.removeItem(at: signalURL)
                print("OK")
                return
            } catch {
                if FileManager.default.fileExists(atPath: signalURL.path) {
                    try? FileManager.default.removeItem(at: signalURL)
                    print("OK")
                    return
                }
            }
            throw CLIError(message: "wait-for timed out waiting for '\(name)'")

        case "swap-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            guard let sourcePaneRaw = optionValue(commandArgs, name: "--pane") else {
                throw CLIError(message: "swap-pane requires --pane")
            }
            guard let targetPaneRaw = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "swap-pane requires --target-pane")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePane = try normalizePaneHandle(sourcePaneRaw, client: client, workspaceHandle: wsId)
            let targetPane = try normalizePaneHandle(targetPaneRaw, client: client, workspaceHandle: wsId)
            if let sourcePane { params["pane_id"] = sourcePane }
            if let targetPane { params["target_pane_id"] = targetPane }
            let payload = try client.sendV2(method: "pane.swap", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "break-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let paneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = ["focus": !commandArgs.contains("--no-focus")]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneArg, client: client, workspaceHandle: wsId)
            if let paneId { params["pane_id"] = paneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.break", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "join-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let sourcePaneArg = optionValue(commandArgs, name: "--pane")
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            guard let targetPaneArg = optionValue(commandArgs, name: "--target-pane") else {
                throw CLIError(message: "join-pane requires --target-pane")
            }
            var params: [String: Any] = ["focus": !commandArgs.contains("--no-focus")]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sourcePaneId = try normalizePaneHandle(sourcePaneArg, client: client, workspaceHandle: wsId)
            if let sourcePaneId { params["pane_id"] = sourcePaneId }
            let targetPaneId = try normalizePaneHandle(targetPaneArg, client: client, workspaceHandle: wsId)
            if let targetPaneId { params["target_pane_id"] = targetPaneId }
            let surfaceId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let surfaceId { params["surface_id"] = surfaceId }
            let payload = try client.sendV2(method: "pane.join", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "last-window":
            let payload = try client.sendV2(method: "workspace.last")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "next-window":
            let payload = try client.sendV2(method: "workspace.next")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "previous-window":
            let payload = try client.sendV2(method: "workspace.previous")
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "last-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "pane.last", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["pane"]))

        case "find-window":
            let includeContent = commandArgs.contains("--content")
            let shouldSelect = commandArgs.contains("--select")
            let query = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let listPayload = try client.sendV2(method: "workspace.list")
            let workspaces = listPayload["workspaces"] as? [[String: Any]] ?? []

            var matches: [[String: Any]] = []
            for ws in workspaces {
                let title = (ws["title"] as? String) ?? ""
                let titleMatch = query.isEmpty || title.localizedCaseInsensitiveContains(query)
                var contentMatch = false
                if includeContent && !query.isEmpty, let wsId = ws["id"] as? String {
                    let textPayload = try? client.sendV2(method: "surface.read_text", params: ["workspace_id": wsId])
                    let text = (textPayload?["text"] as? String) ?? ""
                    contentMatch = text.localizedCaseInsensitiveContains(query)
                }
                if titleMatch || contentMatch {
                    matches.append(ws)
                }
            }

            if shouldSelect, let first = matches.first, let wsId = first["id"] as? String {
                _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": wsId])
            }

            if jsonOutput {
                let formatted = formatIDs(["matches": matches], mode: idFormat) as? [String: Any]
                print(jsonString(["matches": formatted?["matches"] ?? []]))
            } else if matches.isEmpty {
                print("No matches")
            } else {
                for item in matches {
                    let handle = textHandle(item, idFormat: idFormat)
                    let title = (item["title"] as? String) ?? ""
                    print("\(handle)  \"\(title)\"")
                }
            }

        case "clear-history":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.clear_history", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "set-hook":
            var store = loadTmuxCompatStore()
            if commandArgs.contains("--list") {
                if jsonOutput {
                    print(jsonString(["hooks": store.hooks]))
                } else if store.hooks.isEmpty {
                    print("No hooks configured")
                } else {
                    for (event, hookCmd) in store.hooks.sorted(by: { $0.key < $1.key }) {
                        print("\(event) -> \(hookCmd)")
                    }
                }
                return
            }
            if commandArgs.contains("--unset") {
                guard let event = commandArgs.last else {
                    throw CLIError(message: "set-hook --unset requires an event name")
                }
                store.hooks.removeValue(forKey: event)
                try saveTmuxCompatStore(store)
                print("OK")
                return
            }
            guard let event = commandArgs.first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            let commandText = commandArgs.drop(while: { $0 != event }).dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandText.isEmpty else {
                throw CLIError(message: "set-hook requires <event> <command>")
            }
            store.hooks[event] = commandText
            try saveTmuxCompatStore(store)
            print("OK")

        case "popup":
            throw CLIError(message: "popup is not supported yet in c11 CLI parity mode")

        case "bind-key", "unbind-key", "copy-mode":
            throw CLIError(message: "\(command) is not supported yet in c11 CLI parity mode")

        case "set-buffer":
            let (nameArg, rem0) = parseOption(commandArgs, name: "--name")
            let name = (nameArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? nameArg! : "default"
            let content = rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "set-buffer requires text")
            }
            var store = loadTmuxCompatStore()
            store.buffers[name] = content
            try saveTmuxCompatStore(store)
            print("OK")

        case "list-buffers":
            let store = loadTmuxCompatStore()
            if jsonOutput {
                let payload = store.buffers.map { key, value in ["name": key, "size": value.count] }
                print(jsonString(["buffers": payload.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]))
            } else if store.buffers.isEmpty {
                print("No buffers")
            } else {
                for key in store.buffers.keys.sorted() {
                    let size = store.buffers[key]?.count ?? 0
                    print("\(key)\t\(size)")
                }
            }

        case "paste-buffer":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let name = optionValue(commandArgs, name: "--name") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            var params: [String: Any] = ["text": buffer]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "respawn-pane":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let surfaceArg = optionValue(commandArgs, name: "--surface")
            let (commandOpt, rem0) = parseOption(commandArgs, name: "--command")
            let commandText = (commandOpt ?? rem0.dropFirst(rem0.first == "--" ? 1 : 0).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCommand = commandText.isEmpty ? "exec ${SHELL:-/bin/zsh} -l" : commandText
            var params: [String: Any] = ["text": finalCommand + "\n"]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, allowFocused: true)
            if let sfId { params["surface_id"] = sfId }
            let payload = try client.sendV2(method: "surface.send_text", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")

        case "display-message":
            let printOnly = commandArgs.contains("-p") || commandArgs.contains("--print")
            let message = commandArgs
                .filter { !$0.hasPrefix("-") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw CLIError(message: "display-message requires text")
            }
            if printOnly {
                print(message)
                return
            }
            let payload = try client.sendV2(method: "notification.create", params: ["title": "c11", "body": message])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print(message)
            }

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }

    private func runClaudeHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // C11-24 diagnostic: when CMUX_HOOK_DEBUG_PATH is set, dump the
        // raw stdin JSON to that path before parsing. Used to verify the
        // exact shape of the SessionStart payload Claude Code emits when
        // session_id capture appears to be silently dropping. Best-effort —
        // any I/O error is swallowed so a misconfigured debug path can
        // never break the hook itself.
        if let debugPath = ProcessInfo.processInfo.environment["CMUX_HOOK_DEBUG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !debugPath.isEmpty {
            try? rawInput.write(toFile: debugPath, atomically: true, encoding: .utf8)
        }
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()
        telemetry.breadcrumb(
            "claude-hook.input",
            data: [
                "subcommand": subcommand,
                "has_session_id": parsedInput.sessionId != nil,
                "has_workspace_flag": hookWsFlag != nil,
                "has_surface_flag": optionValue(hookArgs, name: "--surface") != nil
            ]
        )
        let fallbackWorkspaceId = try resolveWorkspaceIdForClaudeHook(workspaceArg, client: client)
        let fallbackSurfaceId = try? resolveSurfaceId(surfaceArg, workspaceId: fallbackWorkspaceId, client: client)

        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("claude-hook.session-start")
            let workspaceId = fallbackWorkspaceId
            let surfaceId = try resolveSurfaceIdForClaudeHook(
                surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let claudePid: Int? = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_CLAUDE_PID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    let pid = Int(raw),
                    pid > 0 else {
                    return nil
                }
                return pid
            }()
            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    pid: claudePid
                )
                // C11-24 conversation store: route the SessionStart id
                // into ConversationStore via conversation.push. Replaces
                // the older claude.session_id reserved-metadata write
                // (which raced SessionEnd on Cmd+Q). The legacy
                // claude.session_id reserved key is no longer written
                // here; the read-side bridge in WorkspaceSnapshotStore
                // continues to recognise it for one-release backcompat
                // (snapshots from 0.43.0/0.44.0-pre).
                let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSessionId.isEmpty, !surfaceId.isEmpty {
                    var pushParams: [String: Any] = [
                        "surface_id": surfaceId,
                        "kind": "claude-code",
                        "id": trimmedSessionId,
                        "source": "hook",
                        "state": "alive"
                    ]
                    if let cwd = parsedInput.cwd, !cwd.isEmpty {
                        pushParams["cwd"] = cwd
                    }
                    do {
                        _ = try client.sendV2(method: "conversation.push", params: pushParams)
                        telemetry.breadcrumb("claude-hook.conversation.push.ok")
                    } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
                        telemetry.breadcrumb("claude-hook.conversation.push.skipped")
                    } catch {
                        telemetry.breadcrumb("claude-hook.conversation.push.failed")
                    }
                }
            }
            // Register PID for stale-session detection and OSC suppression,
            // but don't set a visible status. "Running" only appears when the
            // user submits a prompt (UserPromptSubmit) or Claude starts working
            // (PreToolUse).
            if let claudePid {
                _ = try? sendV1Command(
                    "set_agent_pid claude_code \(claudePid) --tab=\(workspaceId)",
                    client: client
                )
            }
            print("OK")

        case "stop", "idle":
            telemetry.breadcrumb("claude-hook.stop")
            // Turn ended. Don't consume session or clear PID — Claude is still alive.
            // Notification hook handles user-facing notifications; SessionEnd handles cleanup.
            var workspaceId = fallbackWorkspaceId
            var surfaceId = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                surfaceId = mapped.surfaceId
            }

            // Update session with transcript summary and send completion notification.
            let completion = summarizeClaudeHookStop(
                parsedInput: parsedInput,
                sessionRecord: (try? sessionStore.lookup(sessionId: parsedInput.sessionId ?? ""))
            )
            if let sessionId = parsedInput.sessionId, let completion {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId ?? "",
                    cwd: parsedInput.cwd,
                    lastSubtitle: completion.subtitle,
                    lastBody: completion.body
                )
            }

            if let completion {
                let resolvedSurface = try resolveSurfaceIdForClaudeHook(
                    surfaceId,
                    workspaceId: workspaceId,
                    client: client
                )
                let title = "Claude Code"
                let subtitle = sanitizeNotificationField(completion.subtitle)
                let body = sanitizeNotificationField(completion.body)
                let payload = "\(title)|\(subtitle)|\(body)"
                _ = try? sendV1Command("notify_target \(workspaceId) \(resolvedSurface) \(payload)", client: client)
            }

            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Idle",
                icon: "pause.circle.fill",
                color: "#8E8E93"
            )
            print("OK")

        case "prompt-submit":
            telemetry.breadcrumb("claude-hook.prompt-submit")
            var workspaceId = fallbackWorkspaceId
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
            }
            _ = try sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            print("OK")

        case "notification", "notify":
            telemetry.breadcrumb("claude-hook.notification")
            var summary = summarizeClaudeHookNotification(rawInput: rawInput)

            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                preferredSurface = mapped.surfaceId
                // If PreToolUse saved a richer message (e.g. from AskUserQuestion),
                // use it instead of the generic notification text.
                if let savedBody = mapped.lastBody, !savedBody.isEmpty,
                   summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                    summary = (subtitle: mapped.lastSubtitle ?? summary.subtitle, body: savedBody)
                }
            }

            let surfaceId = try resolveSurfaceIdForClaudeHook(
                preferredSurface,
                workspaceId: workspaceId,
                client: client
            )

            let title = "Claude Code"
            let subtitle = sanitizeNotificationField(summary.subtitle)
            let body = sanitizeNotificationField(summary.body)
            let payload = "\(title)|\(subtitle)|\(body)"

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }

            let response = try client.send(command: "notify_target \(workspaceId) \(surfaceId) \(payload)")
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            print(response)

        case "session-end":
            telemetry.breadcrumb("claude-hook.session-end")
            // Final cleanup when Claude process exits.
            // Only clear when we are the primary cleanup path (Stop didn't fire first).
            // If Stop already consumed the session, consumedSession is nil and we skip
            // to avoid wiping the completion notification that Stop just delivered.
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                _ = try? clearClaudeStatus(client: client, workspaceId: workspaceId)
                _ = try? sendV1Command("clear_agent_pid claude_code --tab=\(workspaceId)", client: client)
                _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
                // C11-24: SessionEnd race fix.
                //
                // The legacy code path here cleared `claude.session_id`
                // from surface metadata — but on Cmd+Q, c11 kills
                // terminals → claude exits → SessionEnd fires →
                // metadata cleared, racing the snapshot capture. By
                // next launch, per-surface session ids were gone (one
                // of the bugs this primitive was built to fix).
                //
                // New semantics: query is_terminating_app via
                // system.ping (250 ms bounded). If the app is
                // terminating, NO-OP (preserve the ref so resume on
                // next launch still works). If not, push state="ended"
                // → store maps to .unknown so next-launch scrape
                // reclassifies (the hook can't distinguish user
                // /exit from Claude crash, terminal kill, or wrapper
                // failure; tombstoning unconditionally would refuse
                // auto-resume of work the user expected to continue).
                //
                // CLI policy on socket failure: treat unreachable /
                // timeout as terminating, so we err on preservation,
                // never tombstone on socket-uncertainty.
                let surfaceId = consumedSession.surfaceId
                let isTerminating = isAppCurrentlyTerminating(client: client, telemetry: telemetry)
                if isTerminating {
                    telemetry.breadcrumb("claude-hook.session-end.skipped-during-shutdown")
                } else if let sessionId = parsedInput.sessionId, !surfaceId.isEmpty {
                    let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        var params: [String: Any] = [
                            "surface_id": surfaceId,
                            "kind": "claude-code",
                            "id": trimmed,
                            "source": "hook",
                            "state": "ended",
                            // C11-24 review (B3): server-side handler reads
                            // `diagnostic_reason`. Sending bare `reason` here
                            // dropped the SessionEnd context silently.
                            "diagnostic_reason": "SessionEnd (TUI exited; reclassify on next launch)"
                        ]
                        if !workspaceId.isEmpty {
                            params["workspace_id"] = workspaceId
                        }
                        do {
                            _ = try client.sendV2(method: "conversation.push", params: params)
                            telemetry.breadcrumb("claude-hook.session-end.ended.ok")
                        } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
                            telemetry.breadcrumb("claude-hook.session-end.ended.skipped")
                        } catch {
                            telemetry.breadcrumb("claude-hook.session-end.ended.failed")
                        }
                    }
                }
            }
            print("OK")

        case "pre-tool-use":
            telemetry.breadcrumb("claude-hook.pre-tool-use")
            // Clears "Needs input" status and notification when Claude resumes work
            // (e.g. after permission grant). Runs async so it doesn't block tool execution.
            var workspaceId = fallbackWorkspaceId
            var claudePid: Int? = nil
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForClaudeHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                claudePid = mapped.pid
            }

            // AskUserQuestion means Claude is about to ask the user something.
            // Save question text in session so the Notification handler can use it
            // instead of the generic "Claude Code needs your attention".
            if let toolName = parsedInput.object?["tool_name"] as? String,
               toolName == "AskUserQuestion",
               let question = describeAskUserQuestion(parsedInput.object),
               let sessionId = parsedInput.sessionId {
                // Preserve the existing surfaceId from SessionStart; passing ""
                // would overwrite it and cause notifications to target the wrong workspace.
                let existingSurfaceId = (try? sessionStore.lookup(sessionId: sessionId))?.surfaceId ?? ""
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: existingSurfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: "Waiting",
                    lastBody: question
                )
                // Don't clear notifications or set status here.
                // The Notification hook fires right after and will use the saved question.
                print("OK")
                return
            }

            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)

            let statusValue: String
            if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
               let toolStatus = describeToolUse(parsedInput.object) {
                statusValue = toolStatus
            } else {
                statusValue = "Running"
            }
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: statusValue,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
            print("OK")

        case "help", "--help", "-h":
            telemetry.breadcrumb("claude-hook.help")
            print(
                """
                c11 claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use> [--workspace <id|index>] [--surface <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown claude-hook subcommand: \(subcommand)")
        }
    }

    private func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var cmd = "set_status claude_code \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)"
        if let pid {
            cmd += " --pid=\(pid)"
        }
        _ = try client.send(command: cmd)
    }

    private func clearClaudeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.send(command: "clear_status claude_code --tab=\(workspaceId)")
    }

    private func describeAskUserQuestion(_ object: [String: Any]?) -> String? {
        guard let object,
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return nil }

        var parts: [String] = []

        if let question = first["question"] as? String, !question.isEmpty {
            parts.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            parts.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                parts.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        if parts.isEmpty { return "Asking a question" }
        return parts.joined(separator: "\n")
    }

    private func describeToolUse(_ object: [String: Any]?) -> String? {
        guard let object, let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any]

        switch toolName {
        case "Read":
            if let path = input?["file_path"] as? String {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"
        case "Edit":
            if let path = input?["file_path"] as? String {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"
        case "Write":
            if let path = input?["file_path"] as? String {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"
        case "Bash":
            if let cmd = input?["command"] as? String {
                let first = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
                let short = String(first.prefix(30))
                return "Running \(short)"
            }
            return "Running command"
        case "Glob":
            if let pattern = input?["pattern"] as? String {
                return "Searching \(String(pattern.prefix(30)))"
            }
            return "Searching files"
        case "Grep":
            if let pattern = input?["pattern"] as? String {
                return "Grep \(String(pattern.prefix(30)))"
            }
            return "Searching code"
        case "Agent":
            if let desc = input?["description"] as? String {
                return String(desc.prefix(40))
            }
            return "Subagent"
        case "WebFetch":
            return "Fetching URL"
        case "WebSearch":
            if let query = input?["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
            return "Web search"
        default:
            return toolName
        }
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? String(path.suffix(30)) : name
    }

    private func resolveWorkspaceIdForClaudeHook(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, !raw.isEmpty, let candidate = try? resolveWorkspaceId(raw, client: client) {
            let probe = try? client.sendV2(method: "surface.list", params: ["workspace_id": candidate])
            if probe != nil {
                return candidate
            }
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    private func resolveSurfaceIdForClaudeHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let raw, !raw.isEmpty, let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: client) {
            return candidate
        }
        return try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    }

    private func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            return ClaudeHookParsedInput(rawInput: rawInput, object: nil, sessionId: nil, cwd: nil, transcriptPath: nil)
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = firstString(in: object, keys: ["transcript_path", "transcriptPath"])
        return ClaudeHookParsedInput(rawInput: rawInput, object: object, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)
    }

    private func extractClaudeHookSessionId(from object: [String: Any]) -> String? {
        if let id = firstString(in: object, keys: ["session_id", "sessionId"]) {
            return id
        }

        if let nested = object["notification"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let nested = object["data"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let session = object["session"] as? [String: Any],
           let id = firstString(in: session, keys: ["id", "session_id", "sessionId"]) {
            return id
        }
        if let context = object["context"] as? [String: Any],
           let id = firstString(in: context, keys: ["session_id", "sessionId"]) {
            return id
        }
        return nil
    }

    private func extractClaudeHookCWD(from object: [String: Any]) -> String? {
        let cwdKeys = ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]
        if let cwd = firstString(in: object, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstString(in: context, keys: cwdKeys) {
            return cwd
        }
        return nil
    }

    /// C11-24: query `is_terminating_app` on `system.ping` with a 250 ms
    /// bounded timeout. CLI policy: treat unreachable/timeout as
    /// terminating so SessionEnd errs on preservation and never
    /// tombstones a ref the operator expected to resume.
    private func isAppCurrentlyTerminating(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        do {
            let response = try client.sendV2(method: "system.ping")
            if let flag = response["is_terminating_app"] as? Bool {
                if flag { telemetry.breadcrumb("claude-hook.is-terminating.true") }
                return flag
            }
            // Field absent on older builds — be conservative.
            telemetry.breadcrumb("claude-hook.is-terminating.field-absent")
            return false
        } catch let error as CLIError where isAdvisoryHookConnectivityError(error) {
            telemetry.breadcrumb("claude-hook.is-terminating.unreachable-treated-as-terminating")
            return true
        } catch {
            telemetry.breadcrumb("claude-hook.is-terminating.error-treated-as-terminating")
            return true
        }
    }

    private func summarizeClaudeHookStop(
        parsedInput: ClaudeHookParsedInput,
        sessionRecord: ClaudeHookSessionRecord?
    ) -> (subtitle: String, body: String)? {
        let cwd = parsedInput.cwd ?? sessionRecord?.cwd
        let transcriptPath = parsedInput.transcriptPath

        let projectName: String? = {
            guard let cwd = cwd, !cwd.isEmpty else { return nil }
            let path = NSString(string: cwd).expandingTildeInPath
            let tail = URL(fileURLWithPath: path).lastPathComponent
            return tail.isEmpty ? path : tail
        }()

        // Try reading the transcript JSONL for a richer summary.
        let transcript = transcriptPath.flatMap { readTranscriptSummary(path: $0) }

        if let lastMsg = transcript?.lastAssistantMessage {
            var subtitle = "Completed"
            if let projectName, !projectName.isEmpty {
                subtitle = "Completed in \(projectName)"
            }
            return (subtitle, truncate(lastMsg, maxLength: 200))
        }

        // Fallback: use session record data.
        let lastMessage = sessionRecord?.lastBody ?? sessionRecord?.lastSubtitle
        let hasContext = cwd != nil || lastMessage != nil
        guard hasContext else { return nil }

        var body = "Claude session completed"
        if let projectName, !projectName.isEmpty {
            body += " in \(projectName)"
        }
        if let lastMessage, !lastMessage.isEmpty {
            body += ". Last: \(lastMessage)"
        }
        return ("Completed", body)
    }

    private struct TranscriptSummary {
        let lastAssistantMessage: String?
    }

    private func readTranscriptSummary(path: String) -> TranscriptSummary? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        var lastAssistantMessage: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant" else {
                continue
            }

            let text = extractMessageText(from: message)
            guard let text, !text.isEmpty else { continue }
            lastAssistantMessage = truncate(normalizedSingleLine(text), maxLength: 120)
        }

        guard lastAssistantMessage != nil else { return nil }
        return TranscriptSummary(lastAssistantMessage: lastAssistantMessage)
    }

    private func extractMessageText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func summarizeClaudeHookNotification(rawInput: String) -> (subtitle: String, body: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Waiting", "Claude is waiting for your input")
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = truncate(normalizedSingleLine(trimmed), maxLength: 180)
            return classifyClaudeNotification(signal: fallback, message: fallback)
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let session = firstString(in: object, keys: ["session_id", "sessionId"])
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
            return ("Error", body)
        }
        if lower.contains("complet") || lower.contains("finish") || lower.contains("done") || lower.contains("success") {
            let body = message.isEmpty ? "Task completed" : message
            return ("Completed", body)
        }
        if lower.contains("idle") || lower.contains("wait") || lower.contains("input") || lower.contains("idle_prompt") {
            let body = message.isEmpty ? "Waiting for input" : message
            return ("Waiting", body)
        }
        // Use the message directly if it's meaningful (not a generic placeholder).
        if !message.isEmpty, message != "Claude needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Claude needs your attention")
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    private func sanitizeNotificationField(_ value: String) -> String {
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    private func versionSummary() -> String {
        let info = resolvedVersionInfo()
        let commit = info["CMUXCommit"].flatMap { normalizedCommitHash($0) }
        let baseSummary: String
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            baseSummary = "c11 \(version) (\(build))"
        } else if let version = info["CFBundleShortVersionString"] {
            baseSummary = "c11 \(version)"
        } else if let build = info["CFBundleVersion"] {
            baseSummary = "c11 build \(build)"
        } else {
            baseSummary = "c11 version unknown"
        }
        guard let commit else { return baseSummary }
        return "\(baseSummary) [\(commit)]"
    }

    private func printWelcome() {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        func trueColor(_ red: Int, _ green: Int, _ blue: Int) -> String {
            "\u{001B}[38;2;\(red);\(green);\(blue)m"
        }

        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        // Stage 11 gold ramp: single accent color, faded at the tips. Brand rule is
        // "gold is the only color" — the diamond glows gold, everything else stays
        // quiet. Values centered on --gold (#c9a84c = 201,168,76).
        let g1 = trueColor(104, 87, 39)
        let g2 = trueColor(149, 124, 56)
        let g3 = trueColor(183, 153, 69)
        let g4 = trueColor(201, 168, 76)
        let g5 = trueColor(183, 153, 69)
        let g6 = trueColor(149, 124, 56)
        let g7 = trueColor(104, 87, 39)
        let goldBold = bold + trueColor(201, 168, 76)

        let tagline: String
        let subdued: String

        if isDark {
            tagline = trueColor(130, 130, 140)
            subdued = "\u{001B}[2m"
        } else {
            tagline = trueColor(90, 90, 98)
            subdued = trueColor(100, 100, 108)
        }

        let logo = """
        \(g1)  ::\(reset)
        \(g2)    ::::\(reset)              \(goldBold)c11\(reset)
        \(g3)      ::::::\(reset)
        \(g4)        ::::::\(reset)        \(tagline)terminal multiplexing for the 10,000x hyperengineer\(reset)
        \(g5)      ::::::\(reset)
        \(g6)    ::::\(reset)
        \(g7)  ::\(reset)
        """

        let shortcuts = """
          \(bold)Shortcuts\(reset)

          \(bold)\u{2318}N\(reset)\(subdued)                  New workspace\(reset)
          \(bold)\u{2318}T\(reset)\(subdued)                  New tab\(reset)
          \(bold)\u{2318}P\(reset)\(subdued)                  Go to workspace\(reset)
          \(bold)\u{2318}D\(reset)\(subdued)                  Split right\(reset)
          \(bold)\u{2318}\u{21E7}D\(reset)\(subdued)                 Split down\(reset)
          \(bold)\u{2318}\u{21E7}P\(reset)\(subdued)                 Command palette\(reset)
          \(bold)\u{2318}\u{21E7}R\(reset)\(subdued)                 Rename workspace\(reset)
          \(bold)\u{2318}\u{21E7}L\(reset)\(subdued)                 New browser\(reset)
          \(bold)\u{2318}\u{21E7}U\(reset)\(subdued)                 Jump to latest unread\(reset)
        """

        print()
        print(logo)
        print()
        print(shortcuts)
        print()
        print("  \(bold)Stage 11\(reset)\(subdued)            https://stage11.ai\(reset)")
        print("  \(bold)The Spike\(reset)\(subdued)           https://stage11.ai/spike\(reset)")
        print("  \(bold)Upstream\(reset)\(subdued)            https://github.com/manaflow-ai/cmux (cmux — the project we forked)\(reset)")
        print()
        print("  \(subdued)Run \(reset)\(bold)c11 --help\(reset)\(subdued) for all commands.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)c11 shortcuts\(reset)\(subdued) to edit shortcuts.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)c11 feedback\(reset)\(subdued) to report a bug.\(reset)")
        print()
    }

    private func resolvedVersionInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            info.merge(main, uniquingKeysWith: { current, _ in current })
        }

        let needsPlistFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsPlistFallback {
            for plistURL in candidateInfoPlistURLs() {
                guard let data = try? Data(contentsOf: plistURL),
                      let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dictionary = raw as? [String: Any],
                      let parsed = versionInfo(from: dictionary)
                else {
                    continue
                }
                info.merge(parsed, uniquingKeysWith: { current, _ in current })
                if info["CFBundleShortVersionString"] != nil,
                   info["CFBundleVersion"] != nil,
                   info["CMUXCommit"] != nil {
                    break
                }
            }
        }

        let needsProjectFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsProjectFallback, let fromProject = versionInfoFromProjectFile() {
            info.merge(fromProject, uniquingKeysWith: { current, _ in current })
        }

        if info["CMUXCommit"] == nil,
           let commit = normalizedCommitHash(ProcessInfo.processInfo.environment["CMUX_COMMIT"]) {
            info["CMUXCommit"] = commit
        }

        return info
    }

    private func versionInfo(from dictionary: [String: Any]?) -> [String: String]? {
        guard let dictionary else { return nil }

        var info: [String: String] = [:]
        if let version = dictionary["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleShortVersionString"] = trimmed
            }
        }
        if let build = dictionary["CFBundleVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleVersion"] = trimmed
            }
        }
        if let commit = dictionary["CMUXCommit"] as? String,
           let normalizedCommit = normalizedCommitHash(commit) {
            info["CMUXCommit"] = normalizedCommit
        }
        return info.isEmpty ? nil : info
    }

    private func versionInfoFromProjectFile() -> [String: String]? {
        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        let fileManager = FileManager.default
        var current = executableURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let projectFile = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path),
               let contents = try? String(contentsOf: projectFile, encoding: .utf8) {
                var info: [String: String] = [:]
                if let version = firstProjectSetting("MARKETING_VERSION", in: contents) {
                    info["CFBundleShortVersionString"] = version
                }
                if let build = firstProjectSetting("CURRENT_PROJECT_VERSION", in: contents) {
                    info["CFBundleVersion"] = build
                }
                if let commit = gitCommitHash(at: current) {
                    info["CMUXCommit"] = commit
                }
                if !info.isEmpty {
                    return info
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    private func firstProjectSetting(_ key: String, in source: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        let value = source[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    private func gitCommitHash(at directory: URL) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(output)
    }

    private func normalizedCommitHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        let normalized = trimmed.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return String(normalized.prefix(12))
    }

    // Foundation can walk past "/" into "/.." when repeatedly deleting path
    // components, so stop once the canonical root is reached.
    private func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    private func candidateInfoPlistURLs() -> [URL] {
        guard let executableURL = resolvedExecutableURL() else {
            return []
        }

        let fileManager = FileManager.default

        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendIfExisting(_ url: URL) {
            let path = url.path
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            candidates.append(url)
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app" {
                appendIfExisting(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                appendIfExisting(current.appendingPathComponent("Info.plist"))
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                appendIfExisting(repoInfo)
                break
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        // If we already found an ancestor bundle or repo Info.plist, avoid scanning
        // sibling app bundles. Large Resources directories can otherwise balloon RSS.
        guard candidates.isEmpty else {
            return candidates
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent().standardizedFileURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        ]
        for root in searchRoots {
            guard let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let entry as URL in entries where entry.pathExtension == "app" {
                appendIfExisting(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        return candidates
    }

    private func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return Bundle.main.executableURL?.path ?? args.first
    }

    private func resolvedExecutableURL() -> URL? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let expanded = (executable as NSString).expandingTildeInPath
        if let resolvedPath = realpath(expanded, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func usage() -> String {
        return """
        c11 - control c11 via Unix socket

        Usage:
          c11 <path>                 Open a directory in a new workspace (launches c11 if needed)
          c11 [global-options] <command> [options]

        Handle Inputs:
          Use UUIDs, short refs (window:1/workspace:2/pane:3/surface:4), or indexes where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD env var, then password saved in Settings.

        Commands:
          welcome
          shortcuts
          feedback [--email <email> --body <text> [--image <path> ...]]
          themes [list|get|set|clear|reload|path|dump|validate|diff]  c11 chrome themes
          terminal-theme [list|set|clear]                             Ghostty terminal themes
          claude-teams [claude-args...]
          ping
          version
          capabilities
          brand [--json]
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          workspace-action --action <name> [--workspace <id|ref|index>] [--title <text>]
          list-workspaces
          new-workspace [--cwd <path>] [--command <text>]
          ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [--ssh-option <opt>] [-- <remote-command-args>]
          remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
          new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>] [--title <text>]
          list-panes [--workspace <id|ref>]
          list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]
          tree [--all] [--workspace <id|ref|index>]
          focus-pane --pane <id|ref> [--workspace <id|ref>]
          new-pane [--type <terminal|browser|markdown>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>] [--file <path>] [--title <text>]
          new-surface [--type <terminal|browser|markdown>] [--pane <id|ref>] [--workspace <id|ref>] [--url <url>] [--file <path>]
          close-surface [--surface <id|ref>] [--workspace <id|ref>]
          move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>)
          tab-action --action <name> [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--url <url>]
          rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>
          set-title [--workspace <id|ref>] [--surface <id|ref>] [--source <src>] <title>
          set-description [--workspace <id|ref>] [--surface <id|ref>] [--source <src>] [--auto-expand=false] <text>
          get-titlebar-state [--workspace <id|ref>] [--surface <id|ref>] [--json]
          drag-surface-to-split --surface <id|ref> <left|right|up|down>
          refresh-surfaces
          surface-health [--workspace <id|ref>]
          trigger-flash [--workspace <id|ref>] [--surface <id|ref>]
          list-panels [--workspace <id|ref>]
          focus-panel --panel <id|ref> [--workspace <id|ref>]
          close-workspace --workspace <id|ref>
          select-workspace --workspace <id|ref>
          rename-workspace [--workspace <id|ref>] <title>
          rename-window [--workspace <id|ref>] <title>
          current-workspace
          read-screen [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          send [--workspace <id|ref>] [--surface <id|ref>] <text>
          send-key [--workspace <id|ref>] [--surface <id|ref>] <key>
          send-panel --panel <id|ref> [--workspace <id|ref>] <text>
          send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>]
          pane-confirm --panel <id|ref> --title <text> [--message <text>] [--destructive] [--timeout <seconds>] [--confirm-label <text>] [--cancel-label <text>]
          list-notifications
          clear-notifications
          claude-hook <session-start|stop|notification> [--workspace <id|ref>] [--surface <id|ref>]
          set-agent --type <terminal_type> [--model <id>] [--task <id>] [--role <id>] [--surface <id|ref>] [--workspace <id|ref>]
          set-metadata (--json '{...}' | --key <K> --value <V> [--type string|number|bool|json]) [--surface <id|ref> | --pane <id|ref>] [--workspace <id|ref>] [--mode merge|replace] [--source <src>]
          get-metadata [--key <K> ...] [--sources] [--surface <id|ref> | --pane <id|ref>] [--workspace <id|ref>]
          clear-metadata [--key <K> ...] [--source <src>] [--surface <id|ref> | --pane <id|ref>] [--workspace <id|ref>]
          set-workspace-metadata <key> <value> | --key <K> --value <V> | --json '{...}'  [--workspace <id|ref>]
          get-workspace-metadata [<key>] [--workspace <id|ref>]
          clear-workspace-metadata [<key>] [--key <K> ...] [--workspace <id|ref>]
          set-workspace-description <text> [--workspace <id|ref>]
          set-workspace-icon <glyph> [--workspace <id|ref>]
          set-app-focus <active|inactive|clear>
          simulate-app-active

          # tmux compatibility commands
          capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]
          pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]
          wait-for [-S|--signal] <name> [--timeout <seconds>]
          swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>]
          break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]
          join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--no-focus]
          next-window | previous-window | last-window
          last-pane [--workspace <id|ref>]
          find-window [--content] [--select] <query>
          clear-history [--workspace <id|ref>] [--surface <id|ref>]
          set-hook [--list] [--unset <event>] | <event> <command>
          popup
          bind-key | unbind-key | copy-mode
          set-buffer [--name <name>] <text>
          list-buffers
          paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]
          respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd>]
          display-message [-p|--print] <text>

          markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)

          browser [--surface <id|ref|index> | <surface>] <subcommand> ...
          browser open [url]                   (create browser split in caller's workspace; if surface supplied, behaves like navigate)
          browser open-split [url]
          browser goto|navigate <url> [--snapshot-after]
          browser back|forward|reload [--snapshot-after]
          browser url|get-url
          browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
          browser eval <script>
          browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]
          browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]
          browser type <selector> <text> [--snapshot-after]
          browser fill <selector> [text] [--snapshot-after]   (empty text clears input)
          browser press|keydown|keyup <key> [--snapshot-after]
          browser select <selector> <value> [--snapshot-after]
          browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
          browser screenshot [--out <path>] [--json]
          browser get <url|title|text|html|value|attr|count|box|styles> [...]
          browser is <visible|enabled|checked> <selector>
          browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...
          browser frame <selector|main>
          browser dialog <accept|dismiss> [text]
          browser download [wait] [--path <path>] [--timeout-ms <ms>]
          browser cookies <get|set|clear> [...]
          browser storage <local|session> <get|set|clear> [...]
          browser tab <new|list|switch|close|<index>> [...]
          browser console <list|clear>
          browser errors <list|clear>
          browser highlight <selector>
          browser state <save|load> <path>
          browser addinitscript <script>
          browser addscript <script>
          browser addstyle <css>
          browser identify [--surface <id|ref|index>]
          help

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in c11 terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          CMUX_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          CMUX_SURFACE_ID     Auto-set in c11 terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/cmux/cmux.sock and auto-discovers tagged/debug sockets.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }
#endif
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last == " " {
            result.removeLast()
        }
        return result
    }

    func leftPadded(to length: Int, with pad: Character = " ") -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        NSSetUncaughtExceptionHandler { exception in
            // NSFileHandle.writeData: raises NSFileHandleOperationException when writing to a
            // closed pipe. SIGPIPE is already SIG_IGN; treat a broken-pipe write as a clean exit.
            if exception.name == .fileHandleOperationException {
                exit(0)
            }
            FileHandle.standardError.write(
                Data("c11: uncaught exception \(exception.name): \(exception.reason ?? "(none)")\n".utf8)
            )
            exit(1)
        }
        mirrorC11CmuxEnv()
        let cli = CMUXCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch let installerError as IntegrationInstallerError {
            // Installer errors carry their own exit code + structured payload.
            installerError.emit()
            exit(installerError.exitCode)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
}

// MARK: - Module 4: Integration installers
//
// c11 Module 4 — `cmux install <tui>` / `cmux uninstall <tui>`.
// One-command wiring of cmux's notification shims and agent-declaration
// calls into each first-class TUI's configuration.
//
// Spec: docs/c11mux-module-4-integration-installers-spec.md
//
// Everything here is filesystem-local; install does not touch the running
// cmux socket. Menubar integration lives in Sources/AppDelegate.swift and
// goes through the existing v2 surface.create + surface.send_text path.

public enum IntegrationInstallerTUI: String, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case opencode = "opencode"
    case kimi = "kimi"

    public static func parse(_ raw: String) -> IntegrationInstallerTUI? {
        let lowered = raw.lowercased()
        if let direct = IntegrationInstallerTUI(rawValue: lowered) { return direct }
        if lowered == "claude" { return .claudeCode }
        return nil
    }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi"
        }
    }

    public var usesNativeHooks: Bool { self == .claudeCode }

    public func defaultConfigPath(home: String) -> String {
        switch self {
        case .claudeCode: return "\(home)/.claude/settings.json"
        case .codex: return "\(home)/.codex/config.toml"
        case .opencode: return "\(home)/.config/opencode/opencode.json"
        case .kimi: return "\(home)/.kimi/config.toml"
        }
    }

    public func binaryName() -> String {
        // `claude-code` ships as `claude`, other three match rawValue.
        switch self {
        case .claudeCode: return "claude"
        default: return rawValue
        }
    }

    public func shimPath(home: String) -> String {
        return "\(home)/.local/bin/cmux-shims/\(rawValue)"
    }
}

public enum IntegrationInstallerState: String {
    case notInstalled = "not_installed"
    case installedCurrent = "installed_current"
    case installedOutdated = "installed_outdated"
    case schemaMismatch = "schema_mismatch"
    case configMalformed = "config_malformed"
    case markerHandEdit = "marker_hand_edit"
}

public struct IntegrationInstallerError: Error {
    public let code: String
    public let message: String
    public let exitCode: Int32
    public let path: String?
    public let parserError: String?
    public let jsonOutput: Bool

    public init(
        code: String,
        message: String,
        exitCode: Int32,
        path: String? = nil,
        parserError: String? = nil,
        jsonOutput: Bool = false
    ) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
        self.path = path
        self.parserError = parserError
        self.jsonOutput = jsonOutput
    }

    public func emit() {
        if jsonOutput {
            var errorPayload: [String: Any] = [
                "code": code,
                "message": message
            ]
            if let path { errorPayload["path"] = path }
            if let parserError { errorPayload["parser_error"] = parserError }
            let payload: [String: Any] = [
                "ok": false,
                "error": errorPayload
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            if let line = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        } else {
            FileHandle.standardError.write(Data(("Error: \(message)\n").utf8))
        }
    }
}

enum InstallExitCode {
    static let userAborted: Int32 = 1
    static let unknownTui: Int32 = 2
    static let configMissing: Int32 = 3
    static let configPermissionDenied: Int32 = 4
    static let configMalformed: Int32 = 5
    static let schemaVersionMismatch: Int32 = 6
    static let outdatedInstallRequiresForce: Int32 = 7
    static let tuiBinaryNotFound: Int32 = 8
    static let shimDirNotWritable: Int32 = 9
    static let markerHandEditDetected: Int32 = 10
}

struct IntegrationInstallerConstants {
    static let schemaVersion = 1
    static let markerId = "c11mux-v1"
    static let tomlFenceBegin = "# cmux-install-begin"
    static let tomlFenceEnd = "# cmux-install-end"
}

/// Canonical hook entries c11 writes into `~/.claude/settings.json`.
/// Identity is established by content-hash match against the `x-cmux.entries`
/// table. See `docs/c11mux-module-4-integration-installers-spec.md`.
private func claudeCanonicalEntries() -> [(event: String, entry: [String: Any])] {
    return [
        ("SessionStart", [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "c11 claude-hook session-start", "timeout": 10],
                ["type": "command", "command": "c11 set-agent --type claude-code --source declare", "timeout": 5]
            ]
        ]),
        ("Stop", [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "c11 claude-hook stop", "timeout": 10]
            ]
        ]),
        ("SessionEnd", [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "c11 claude-hook session-end", "timeout": 1]
            ]
        ]),
        ("Notification", [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "c11 claude-hook notification", "timeout": 10]
            ]
        ]),
        ("UserPromptSubmit", [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "c11 claude-hook prompt-submit", "timeout": 10]
            ]
        ]),
        ("PreToolUse", [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "c11 claude-hook pre-tool-use", "timeout": 5, "async": true]
            ]
        ])
    ]
}

func integrationInstallerCanonicalJSON(_ object: Any) -> Data {
    // Sorted keys, no whitespace. Safe for SHA256 content addressing.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

func integrationInstallerSHA256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func integrationInstallerSHA256(of string: String) -> String {
    return integrationInstallerSHA256(Data(string.utf8))
}

func integrationInstallerShimScript(for tui: IntegrationInstallerTUI) -> String {
    let type = tui.rawValue
    let binary = tui.binaryName()
    return """
    #!/usr/bin/env bash
    # c11 integration shim (do not edit — regenerate via `cmux install \(type)`)
    set -u
    CMUX_MARKER_ID=\"\(IntegrationInstallerConstants.markerId)\"
    if [[ -n \"${CMUX_SURFACE_ID:-}\" ]]; then
      cmux set-agent --type \(type) --source declare >/dev/null 2>&1 || true
      cmux claude-hook session-start </dev/null >/dev/null 2>&1 || true
    fi
    SELF_DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"
    REAL=\"\"
    OLD_IFS=$IFS
    IFS=:
    for d in $PATH; do
      [[ \"$d\" == \"$SELF_DIR\" ]] && continue
      if [[ -x \"$d/\(binary)\" ]]; then REAL=\"$d/\(binary)\"; break; fi
    done
    IFS=$OLD_IFS
    if [[ -z \"$REAL\" ]]; then
      echo \"cmux-shim: \(binary) not found in PATH\" >&2
      exit 127
    fi
    \"$REAL\" \"$@\"
    STATUS=$?
    if [[ -n \"${CMUX_SURFACE_ID:-}\" ]]; then
      cmux claude-hook session-end </dev/null >/dev/null 2>&1 || true
    fi
    exit $STATUS
    """
}

struct IntegrationInstallerPlan {
    let tui: IntegrationInstallerTUI
    let configPath: String
    let homePath: String
    let preConfigText: String?          // nil if the file did not exist
    let postConfigText: String?         // nil if no change to the config file
    let shimPath: String?               // nil for native-hook TUIs
    let preShimText: String?
    let postShimText: String?
    let priorState: IntegrationInstallerState
    let newInstalledAt: String
    let noop: Bool
    let summary: [String]
    let unifiedDiff: String
    let tuiBinaryFound: Bool
    let tuiBinaryPath: String?
    let createdConfig: Bool             // true when config file didn't exist pre-install
}

struct IntegrationInstallerStatus {
    let tui: IntegrationInstallerTUI
    let configPath: String
    let shimPath: String?
    let state: IntegrationInstallerState
    let schemaVersion: Int?
    let markerId: String?
    let installedAt: String?
    let tuiBinaryFound: Bool
    let tuiBinaryPath: String?
    let expectedHashes: [String: String]   // event -> sha for claude-code; "shim" -> sha for shim TUIs
    let actualHashes: [String: String]     // parallel
    let parserError: String?
    let note: String?
}

extension CMUXCLI {
    fileprivate func runIntegrationInstallerCommand(
        command: String,
        commandArgs: [String],
        jsonOutput: Bool
    ) throws {
        switch command {
        case "install":
            try runIntegrationInstallCommand(commandArgs: commandArgs, jsonOutput: jsonOutput)
        case "uninstall":
            try runIntegrationUninstallCommand(commandArgs: commandArgs, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Unknown integration command: \(command)")
        }
    }

    fileprivate func runIntegrationInstallCommand(commandArgs: [String], jsonOutput: Bool) throws {
        // --list and --status are sub-commands implemented as flags.
        if commandArgs.contains("--list") {
            try runIntegrationInstallerList(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }
        if commandArgs.contains("--status") {
            try runIntegrationInstallerStatus(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        // Parse flags and positional <tui>.
        var dryRun = false
        var noConfirm = false
        var force = false
        var configPathOverride: String? = nil
        var homeOverride: String? = nil
        var tuiArg: String? = nil

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--dry-run": dryRun = true
            case "--no-confirm": noConfirm = true
            case "--force": force = true
            case "--json": break  // handled by top-level --json flag
            case "--config-path":
                guard index + 1 < commandArgs.count else {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "--config-path requires a path",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
                configPathOverride = commandArgs[index + 1]
                index += 1
            case "--home":
                guard index + 1 < commandArgs.count else {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "--home requires a path",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
                homeOverride = commandArgs[index + 1]
                index += 1
            default:
                if arg.hasPrefix("-") {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "Unknown flag: \(arg)",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
                if tuiArg == nil {
                    tuiArg = arg
                } else {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "Unexpected argument: \(arg)",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
            }
            index += 1
        }

        guard let tuiRaw = tuiArg else {
            throw IntegrationInstallerError(
                code: "usage",
                message: "Missing <tui> argument. Run `cmux install --list` to see supported TUIs.",
                exitCode: 2,
                jsonOutput: jsonOutput
            )
        }
        guard let tui = IntegrationInstallerTUI.parse(tuiRaw) else {
            throw IntegrationInstallerError(
                code: "unknown_tui",
                message: "Unknown TUI '\(tuiRaw)'. Supported: \(IntegrationInstallerTUI.allCases.map { $0.rawValue }.joined(separator: ", "))",
                exitCode: InstallExitCode.unknownTui,
                jsonOutput: jsonOutput
            )
        }

        let home = resolveIntegrationInstallerHome(override: homeOverride)
        let configPath = configPathOverride.map { resolveIntegrationInstallerPath($0, home: home) }
            ?? tui.defaultConfigPath(home: home)

        let plan: IntegrationInstallerPlan
        do {
            plan = try integrationInstallerPlan(
                tui: tui,
                configPath: configPath,
                home: home,
                force: force,
                jsonOutput: jsonOutput
            )
        } catch let err as IntegrationInstallerError {
            throw err
        }

        // Apply gates unrelated to the diff (schema mismatch, malformed, etc.)
        if plan.priorState == .schemaMismatch && !force {
            throw IntegrationInstallerError(
                code: "schema_version_mismatch",
                message: "Existing cmux install uses a different schema; re-run with --force to overwrite.",
                exitCode: InstallExitCode.schemaVersionMismatch,
                path: configPath,
                jsonOutput: jsonOutput
            )
        }
        if plan.priorState == .installedOutdated && noConfirm && !force {
            throw IntegrationInstallerError(
                code: "outdated_install_requires_force",
                message: "Existing cmux install is outdated; pass --force to overwrite in non-interactive mode.",
                exitCode: InstallExitCode.outdatedInstallRequiresForce,
                path: configPath,
                jsonOutput: jsonOutput
            )
        }

        if dryRun {
            emitInstallerResultOutput(
                plan: plan,
                action: "install",
                applied: false,
                jsonOutput: jsonOutput,
                extraNote: plan.noop ? "would no-op" : "would apply"
            )
            return
        }

        if plan.noop {
            emitInstallerResultOutput(
                plan: plan,
                action: "install",
                applied: false,
                jsonOutput: jsonOutput,
                extraNote: "already installed, current"
            )
            return
        }

        if !noConfirm {
            // Require TTY for interactive prompt.
            let stdinTTY = isatty(STDIN_FILENO) == 1
            let stdoutTTY = isatty(STDOUT_FILENO) == 1
            if !stdinTTY || !stdoutTTY {
                throw IntegrationInstallerError(
                    code: "user_aborted",
                    message: "Interactive confirmation requires a TTY; pass --no-confirm to apply without prompting.",
                    exitCode: InstallExitCode.userAborted,
                    jsonOutput: jsonOutput
                )
            }

            if !jsonOutput {
                print(plan.unifiedDiff)
                print("")
                if plan.createdConfig {
                    print("Config not found at \(configPath). Install will create it.")
                }
                print("Apply these changes? [y/N] ", terminator: "")
            }
            let response = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if response != "y" && response != "yes" {
                throw IntegrationInstallerError(
                    code: "user_aborted",
                    message: "Install aborted by user.",
                    exitCode: InstallExitCode.userAborted,
                    jsonOutput: jsonOutput
                )
            }
        }

        try applyIntegrationInstallerPlan(plan: plan, jsonOutput: jsonOutput)

        emitInstallerResultOutput(
            plan: plan,
            action: "install",
            applied: true,
            jsonOutput: jsonOutput,
            extraNote: nil
        )
    }

    fileprivate func runIntegrationUninstallCommand(commandArgs: [String], jsonOutput: Bool) throws {
        var dryRun = false
        var noConfirm = false
        var force = false
        var configPathOverride: String? = nil
        var homeOverride: String? = nil
        var tuiArg: String? = nil

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--dry-run": dryRun = true
            case "--no-confirm": noConfirm = true
            case "--force": force = true
            case "--json": break
            case "--config-path":
                guard index + 1 < commandArgs.count else {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "--config-path requires a path",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
                configPathOverride = commandArgs[index + 1]
                index += 1
            case "--home":
                guard index + 1 < commandArgs.count else {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "--home requires a path",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
                homeOverride = commandArgs[index + 1]
                index += 1
            default:
                if arg.hasPrefix("-") {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "Unknown flag: \(arg)",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
                if tuiArg == nil {
                    tuiArg = arg
                } else {
                    throw IntegrationInstallerError(
                        code: "usage",
                        message: "Unexpected argument: \(arg)",
                        exitCode: 2,
                        jsonOutput: jsonOutput
                    )
                }
            }
            index += 1
        }

        guard let tuiRaw = tuiArg else {
            throw IntegrationInstallerError(
                code: "usage",
                message: "Missing <tui> argument.",
                exitCode: 2,
                jsonOutput: jsonOutput
            )
        }
        guard let tui = IntegrationInstallerTUI.parse(tuiRaw) else {
            throw IntegrationInstallerError(
                code: "unknown_tui",
                message: "Unknown TUI '\(tuiRaw)'.",
                exitCode: InstallExitCode.unknownTui,
                jsonOutput: jsonOutput
            )
        }

        let home = resolveIntegrationInstallerHome(override: homeOverride)
        let configPath = configPathOverride.map { resolveIntegrationInstallerPath($0, home: home) }
            ?? tui.defaultConfigPath(home: home)

        let plan = try integrationUninstallerPlan(
            tui: tui,
            configPath: configPath,
            home: home,
            force: force,
            jsonOutput: jsonOutput
        )

        if dryRun {
            emitInstallerResultOutput(
                plan: plan,
                action: "uninstall",
                applied: false,
                jsonOutput: jsonOutput,
                extraNote: plan.noop ? "nothing to uninstall" : "would remove cmux install"
            )
            return
        }

        if plan.noop {
            emitInstallerResultOutput(
                plan: plan,
                action: "uninstall",
                applied: false,
                jsonOutput: jsonOutput,
                extraNote: "nothing to uninstall"
            )
            return
        }

        if !noConfirm {
            let stdinTTY = isatty(STDIN_FILENO) == 1
            let stdoutTTY = isatty(STDOUT_FILENO) == 1
            if !stdinTTY || !stdoutTTY {
                throw IntegrationInstallerError(
                    code: "user_aborted",
                    message: "Interactive confirmation requires a TTY; pass --no-confirm to apply without prompting.",
                    exitCode: InstallExitCode.userAborted,
                    jsonOutput: jsonOutput
                )
            }
            if !jsonOutput {
                print(plan.unifiedDiff)
                print("")
                print("Remove cmux integration from \(tui.displayName)? [y/N] ", terminator: "")
            }
            let response = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if response != "y" && response != "yes" {
                throw IntegrationInstallerError(
                    code: "user_aborted",
                    message: "Uninstall aborted by user.",
                    exitCode: InstallExitCode.userAborted,
                    jsonOutput: jsonOutput
                )
            }
        }

        try applyIntegrationInstallerPlan(plan: plan, jsonOutput: jsonOutput)

        emitInstallerResultOutput(
            plan: plan,
            action: "uninstall",
            applied: true,
            jsonOutput: jsonOutput,
            extraNote: nil
        )
    }

    fileprivate func runIntegrationInstallerList(commandArgs: [String], jsonOutput: Bool) throws {
        let home = resolveIntegrationInstallerHome(override: optionValue(commandArgs, name: "--home"))
        var rows: [[String: Any]] = []
        for tui in IntegrationInstallerTUI.allCases {
            let configPath = tui.defaultConfigPath(home: home)
            let status = integrationInstallerStatusSnapshot(tui: tui, configPath: configPath, home: home)
            rows.append([
                "tui": tui.rawValue,
                "display_name": tui.displayName,
                "installed": status.state == .installedCurrent || status.state == .installedOutdated,
                "state": status.state.rawValue,
                "schema_version": status.schemaVersion ?? NSNull(),
                "config_path": configPath,
                "shim_path": status.shimPath ?? NSNull(),
                "tui_binary_found": status.tuiBinaryFound,
                "tui_binary_path": status.tuiBinaryPath ?? NSNull()
            ])
        }
        if jsonOutput {
            let payload: [String: Any] = ["ok": true, "integrations": rows]
            print(jsonString(payload))
            return
        }
        // Plain table.
        func pad(_ s: String, _ width: Int) -> String {
            if s.count >= width { return s }
            return s + String(repeating: " ", count: width - s.count)
        }
        print("TUI           INSTALLED     SCHEMA  TUI-BIN   CONFIG")
        for row in rows {
            let tuiName = (row["tui"] as? String) ?? ""
            let state = (row["state"] as? String) ?? ""
            let schema = row["schema_version"]
            let schemaText = (schema as? Int).map(String.init) ?? "-"
            let binFound = (row["tui_binary_found"] as? Bool) == true ? "yes" : "no"
            let configPath = (row["config_path"] as? String) ?? ""
            print("\(pad(tuiName, 13)) \(pad(state, 13)) \(pad(schemaText, 7)) \(pad(binFound, 9)) \(configPath)")
        }
    }

    fileprivate func runIntegrationInstallerStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let home = resolveIntegrationInstallerHome(override: optionValue(commandArgs, name: "--home"))
        guard let tuiRaw = optionValue(commandArgs, name: "--status") else {
            throw IntegrationInstallerError(
                code: "usage",
                message: "--status requires a <tui> value",
                exitCode: 2,
                jsonOutput: jsonOutput
            )
        }
        guard let tui = IntegrationInstallerTUI.parse(tuiRaw) else {
            throw IntegrationInstallerError(
                code: "unknown_tui",
                message: "Unknown TUI '\(tuiRaw)'.",
                exitCode: InstallExitCode.unknownTui,
                jsonOutput: jsonOutput
            )
        }
        let configPath = optionValue(commandArgs, name: "--config-path").map { resolveIntegrationInstallerPath($0, home: home) }
            ?? tui.defaultConfigPath(home: home)
        let status = integrationInstallerStatusSnapshot(tui: tui, configPath: configPath, home: home)

        if jsonOutput {
            var payload: [String: Any] = [
                "ok": true,
                "tui": tui.rawValue,
                "display_name": tui.displayName,
                "state": status.state.rawValue,
                "config_path": status.configPath,
                "shim_path": status.shimPath ?? NSNull(),
                "schema_version": status.schemaVersion ?? NSNull(),
                "marker_id": status.markerId ?? NSNull(),
                "installed_at": status.installedAt ?? NSNull(),
                "tui_binary_found": status.tuiBinaryFound,
                "tui_binary_path": status.tuiBinaryPath ?? NSNull(),
                "expected_hashes": status.expectedHashes,
                "actual_hashes": status.actualHashes
            ]
            if let note = status.note { payload["note"] = note }
            if let parserError = status.parserError { payload["parser_error"] = parserError }
            print(jsonString(payload))
            return
        }

        print("TUI:          \(tui.displayName) (\(tui.rawValue))")
        print("State:        \(status.state.rawValue)")
        print("Config path:  \(status.configPath)")
        if let shimPath = status.shimPath {
            print("Shim path:    \(shimPath)")
        }
        if let schema = status.schemaVersion {
            print("Schema:       \(schema)")
        }
        if let installed = status.installedAt {
            print("Installed at: \(installed)")
        }
        print("TUI binary:   \(status.tuiBinaryFound ? (status.tuiBinaryPath ?? "yes") : "not found")")
        if let note = status.note {
            print("Note:         \(note)")
        }
    }

    fileprivate func emitInstallerResultOutput(
        plan: IntegrationInstallerPlan,
        action: String,
        applied: Bool,
        jsonOutput: Bool,
        extraNote: String?
    ) {
        if jsonOutput {
            var payload: [String: Any] = [
                "ok": true,
                "action": action,
                "applied": applied,
                "noop": plan.noop,
                "tui": plan.tui.rawValue,
                "display_name": plan.tui.displayName,
                "config_path": plan.configPath,
                "prior_state": plan.priorState.rawValue,
                "created_config": plan.createdConfig,
                "tui_binary_found": plan.tuiBinaryFound,
                "tui_binary_path": plan.tuiBinaryPath ?? NSNull(),
                "summary": plan.summary
            ]
            if let shimPath = plan.shimPath {
                payload["shim_path"] = shimPath
            }
            if let note = extraNote {
                payload["note"] = note
            }
            print(jsonString(payload))
            return
        }

        if applied {
            print("\(plan.tui.displayName): \(action) OK")
        } else if let note = extraNote {
            print("\(plan.tui.displayName): \(note)")
        } else {
            print("\(plan.tui.displayName): (no changes)")
        }
        for line in plan.summary {
            print("  - \(line)")
        }
        if action == "install" && !plan.tuiBinaryFound {
            print("  warning: \(plan.tui.binaryName()) binary not found in PATH (\(plan.tui.rawValue))")
        }
        if plan.shimPath != nil && action == "install" && applied {
            let dir = IntegrationInstallerHelpers.parentDirectory(of: plan.shimPath!)
            print("  note: ensure \(dir) is on your PATH to route \(plan.tui.binaryName()) through the cmux shim.")
        }
    }
}

// MARK: - Installer helpers

enum IntegrationInstallerHelpers {
    static func parentDirectory(of path: String) -> String {
        return (path as NSString).deletingLastPathComponent
    }

    static func ensureDirectoryExists(_ path: String, mode: Int = 0o755) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw IntegrationInstallerError(
                code: "config_permission_denied",
                message: "Path exists and is not a directory: \(path)",
                exitCode: InstallExitCode.configPermissionDenied,
                path: path
            )
        }
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
        } catch {
            throw IntegrationInstallerError(
                code: "config_permission_denied",
                message: "Could not create directory \(path): \(error.localizedDescription)",
                exitCode: InstallExitCode.configPermissionDenied,
                path: path
            )
        }
    }

    /// Atomic write: writes to a sibling tempfile then renames into place.
    static func atomicWrite(_ text: String, to path: String, mode: Int = 0o644) throws {
        let dir = parentDirectory(of: path)
        try ensureDirectoryExists(dir)

        let tempPath = "\(path).cmux-install.\(getpid()).tmp"
        let data = Data(text.utf8)
        let fm = FileManager.default
        fm.createFile(atPath: tempPath, contents: data, attributes: [.posixPermissions: NSNumber(value: mode)])
        if rename(tempPath, path) != 0 {
            let savedErrno = errno
            _ = unlink(tempPath)
            if savedErrno == EACCES || savedErrno == EPERM {
                throw IntegrationInstallerError(
                    code: "config_permission_denied",
                    message: "Cannot write to \(path) (EACCES)",
                    exitCode: InstallExitCode.configPermissionDenied,
                    path: path
                )
            }
            throw IntegrationInstallerError(
                code: "config_permission_denied",
                message: "Atomic rename failed for \(path) (errno=\(savedErrno))",
                exitCode: InstallExitCode.configPermissionDenied,
                path: path
            )
        }
    }

    static func readUTF8IfExists(_ path: String) throws -> String? {
        if !FileManager.default.fileExists(atPath: path) { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let text = String(data: data, encoding: .utf8) else {
                throw IntegrationInstallerError(
                    code: "config_malformed",
                    message: "File is not valid UTF-8: \(path)",
                    exitCode: InstallExitCode.configMalformed,
                    path: path
                )
            }
            return text
        } catch let err as IntegrationInstallerError {
            throw err
        } catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError {
                throw IntegrationInstallerError(
                    code: "config_permission_denied",
                    message: "Cannot read \(path): permission denied",
                    exitCode: InstallExitCode.configPermissionDenied,
                    path: path
                )
            }
            throw IntegrationInstallerError(
                code: "config_permission_denied",
                message: "Cannot read \(path): \(error.localizedDescription)",
                exitCode: InstallExitCode.configPermissionDenied,
                path: path
            )
        }
    }

    static func removeFileIfExists(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw IntegrationInstallerError(
                code: "config_permission_denied",
                message: "Cannot remove \(path): \(error.localizedDescription)",
                exitCode: InstallExitCode.configPermissionDenied,
                path: path
            )
        }
    }

    static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// Finds `binary` in PATH, skipping the shim dir under `home`.
    static func findBinary(named binary: String, home: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let shimDir = "\(home)/.local/bin/cmux-shims"
        for component in pathEnv.split(separator: ":") {
            let dir = String(component)
            if dir == shimDir { continue }
            let candidate = "\(dir)/\(binary)"
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    static func prettyJSON(_ obj: Any) -> String {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        options.insert(.withoutEscapingSlashes)
        options.insert(.sortedKeys)
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Pretty-prints a JSON object with 2-space indent, sorted keys, and a
    /// trailing newline — matches the convention the claude-code installer
    /// writes. `sortedKeys` keeps roundtrip diffs clean across runs.
    static func claudeCodeJSONDump(_ obj: Any) -> String {
        return prettyJSON(obj) + "\n"
    }

    /// Unified diff between two strings. Simple implementation: per-line,
    /// prints the full before block as `-` and the full after block as `+`.
    /// This is sufficient for the confirmation prompt; it is not a real
    /// Myers diff.
    static func simpleUnifiedDiff(before: String?, after: String?, label: String) -> String {
        let beforeLines = (before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let afterLines = (after ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        lines.append("--- a/\(label)\(before == nil ? " (new file)" : "")")
        lines.append("+++ b/\(label)\(after == nil ? " (removed)" : "")")
        for line in beforeLines {
            lines.append("-\(line)")
        }
        for line in afterLines {
            lines.append("+\(line)")
        }
        return lines.joined(separator: "\n")
    }
}

fileprivate func resolveIntegrationInstallerHome(override: String?) -> String {
    if let override, !override.isEmpty {
        return resolveIntegrationInstallerPath(override, home: NSHomeDirectory())
    }
    return NSHomeDirectory()
}

fileprivate func resolveIntegrationInstallerPath(_ path: String, home: String) -> String {
    let expanded: String
    if path.hasPrefix("~/") {
        expanded = home + String(path.dropFirst(1))
    } else if path == "~" {
        expanded = home
    } else {
        expanded = path
    }
    if expanded.hasPrefix("/") { return expanded }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(expanded)
}

// MARK: - Planning (install)

fileprivate func integrationInstallerPlan(
    tui: IntegrationInstallerTUI,
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    switch tui {
    case .claudeCode:
        return try claudeCodeInstallerPlan(configPath: configPath, home: home, force: force, jsonOutput: jsonOutput)
    case .codex, .kimi:
        return try tomlShimInstallerPlan(tui: tui, configPath: configPath, home: home, force: force, jsonOutput: jsonOutput)
    case .opencode:
        return try opencodeShimInstallerPlan(configPath: configPath, home: home, force: force, jsonOutput: jsonOutput)
    }
}

fileprivate func integrationUninstallerPlan(
    tui: IntegrationInstallerTUI,
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    switch tui {
    case .claudeCode:
        return try claudeCodeUninstallerPlan(configPath: configPath, home: home, force: force, jsonOutput: jsonOutput)
    case .codex, .kimi:
        return try tomlShimUninstallerPlan(tui: tui, configPath: configPath, home: home, force: force, jsonOutput: jsonOutput)
    case .opencode:
        return try opencodeShimUninstallerPlan(configPath: configPath, home: home, force: force, jsonOutput: jsonOutput)
    }
}

fileprivate func applyIntegrationInstallerPlan(
    plan: IntegrationInstallerPlan,
    jsonOutput: Bool
) throws {
    // Config file write / delete.
    if let postText = plan.postConfigText {
        try IntegrationInstallerHelpers.atomicWrite(postText, to: plan.configPath)
    } else {
        // nil means delete (empty round-trip on a file we created).
        try IntegrationInstallerHelpers.removeFileIfExists(plan.configPath)
    }
    // Shim script write / delete.
    if let shimPath = plan.shimPath {
        if let postShim = plan.postShimText {
            do {
                try IntegrationInstallerHelpers.atomicWrite(postShim, to: shimPath, mode: 0o755)
            } catch let err as IntegrationInstallerError {
                if err.code == "config_permission_denied" {
                    throw IntegrationInstallerError(
                        code: "shim_dir_not_writable",
                        message: "Could not write shim at \(shimPath): \(err.message)",
                        exitCode: InstallExitCode.shimDirNotWritable,
                        path: shimPath,
                        jsonOutput: jsonOutput
                    )
                }
                throw err
            }
        } else {
            try IntegrationInstallerHelpers.removeFileIfExists(shimPath)
        }
    }
}

// MARK: - Status snapshots

fileprivate func integrationInstallerStatusSnapshot(
    tui: IntegrationInstallerTUI,
    configPath: String,
    home: String
) -> IntegrationInstallerStatus {
    let tuiBinaryPath = IntegrationInstallerHelpers.findBinary(named: tui.binaryName(), home: home)
    let tuiBinaryFound = tuiBinaryPath != nil
    switch tui {
    case .claudeCode:
        return claudeCodeStatusSnapshot(configPath: configPath, tuiBinaryFound: tuiBinaryFound, tuiBinaryPath: tuiBinaryPath)
    case .codex, .kimi:
        return tomlShimStatusSnapshot(tui: tui, configPath: configPath, home: home, tuiBinaryFound: tuiBinaryFound, tuiBinaryPath: tuiBinaryPath)
    case .opencode:
        return opencodeShimStatusSnapshot(configPath: configPath, home: home, tuiBinaryFound: tuiBinaryFound, tuiBinaryPath: tuiBinaryPath)
    }
}

// MARK: - Claude Code native-hook installer

fileprivate func claudeCodeBuildBlock(installedAt: String) -> (root: [String: Any], entryHashes: [String: String]) {
    let canonicals = claudeCanonicalEntries()
    var hashes: [String: String] = [:]
    var entriesBySha: [[String: Any]] = []
    for (event, entry) in canonicals {
        let hash = integrationInstallerSHA256(integrationInstallerCanonicalJSON(entry))
        hashes[event] = hash
        entriesBySha.append(["event": event, "sha256": hash])
    }
    let xCmux: [String: Any] = [
        "schema": IntegrationInstallerConstants.schemaVersion,
        "id": IntegrationInstallerConstants.markerId,
        "installed_at": installedAt,
        "entries": entriesBySha
    ]
    var hooks: [String: Any] = [:]
    for (event, entry) in canonicals {
        hooks[event] = [entry]
    }
    let root: [String: Any] = [
        "hooks": hooks,
        "x-cmux": xCmux
    ]
    return (root, hashes)
}

fileprivate func claudeCodeMergeInto(existing: [String: Any], with fresh: [String: Any], freshHashes: [String: String], installedAt: String) -> (root: [String: Any], priorHashes: [String: String]) {
    var result = existing

    // Track prior per-event hashes from existing x-cmux.entries, if any.
    var priorHashes: [String: String] = [:]
    if let xCmux = existing["x-cmux"] as? [String: Any],
       let entries = xCmux["entries"] as? [[String: Any]] {
        for e in entries {
            if let event = e["event"] as? String, let sha = e["sha256"] as? String {
                priorHashes[event] = sha
            }
        }
    }

    var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
    let canonicals = claudeCanonicalEntries()
    for (event, entry) in canonicals {
        let freshEntryHash = freshHashes[event] ?? ""
        var arr = (hooks[event] as? [Any]) ?? []
        // Try to find an entry with a hash matching any prior-stored hash for this event.
        var replacedIndex: Int? = nil
        if let prior = priorHashes[event] {
            for (idx, item) in arr.enumerated() {
                if let dict = item as? [String: Any] {
                    let itemHash = integrationInstallerSHA256(integrationInstallerCanonicalJSON(dict))
                    if itemHash == prior {
                        replacedIndex = idx
                        break
                    }
                }
            }
        }
        if let idx = replacedIndex {
            arr[idx] = entry
        } else {
            // If an entry with the exact fresh hash already exists, don't duplicate.
            var alreadyPresent = false
            for item in arr {
                if let dict = item as? [String: Any] {
                    let itemHash = integrationInstallerSHA256(integrationInstallerCanonicalJSON(dict))
                    if itemHash == freshEntryHash {
                        alreadyPresent = true
                        break
                    }
                }
            }
            if !alreadyPresent {
                arr.append(entry)
            }
        }
        hooks[event] = arr
    }

    result["hooks"] = hooks

    // Build x-cmux with current fresh hashes.
    var entriesOut: [[String: Any]] = []
    for (event, _) in canonicals {
        entriesOut.append(["event": event, "sha256": freshHashes[event] ?? ""])
    }
    result["x-cmux"] = [
        "schema": IntegrationInstallerConstants.schemaVersion,
        "id": IntegrationInstallerConstants.markerId,
        "installed_at": installedAt,
        "entries": entriesOut
    ] as [String: Any]

    return (result, priorHashes)
}

fileprivate func claudeCodeInstallerPlan(
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    let preText = try IntegrationInstallerHelpers.readUTF8IfExists(configPath)
    let createdConfig = preText == nil

    // Parse existing config if present. Empty file is treated as {} for merge purposes.
    var existing: [String: Any] = [:]
    if let text = preText, !text.isEmpty {
        guard let data = text.data(using: .utf8) else {
            throw IntegrationInstallerError(
                code: "config_malformed",
                message: "Config is not valid UTF-8",
                exitCode: InstallExitCode.configMalformed,
                path: configPath,
                jsonOutput: jsonOutput
            )
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else {
                throw IntegrationInstallerError(
                    code: "config_malformed",
                    message: "Config is not a JSON object",
                    exitCode: InstallExitCode.configMalformed,
                    path: configPath,
                    jsonOutput: jsonOutput
                )
            }
            existing = dict
        } catch let err as IntegrationInstallerError {
            throw err
        } catch {
            throw IntegrationInstallerError(
                code: "config_malformed",
                message: "Config is not valid JSON: \(error.localizedDescription)",
                exitCode: InstallExitCode.configMalformed,
                path: configPath,
                parserError: error.localizedDescription,
                jsonOutput: jsonOutput
            )
        }
    }

    // Determine prior state.
    let (priorState, _, priorSchema) = claudeCodeExistingState(existing: existing)
    if priorState == .schemaMismatch && !force {
        // Short-circuit: return a plan but signal no-op with the schema_mismatch state.
        let summary = ["cmux install uses schema \(priorSchema ?? 0); expected \(IntegrationInstallerConstants.schemaVersion). Re-run with --force to overwrite."]
        return IntegrationInstallerPlan(
            tui: .claudeCode,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: nil,
            shimPath: nil,
            preShimText: nil,
            postShimText: nil,
            priorState: .schemaMismatch,
            newInstalledAt: IntegrationInstallerHelpers.nowISO8601(),
            noop: true,
            summary: summary,
            unifiedDiff: "",
            tuiBinaryFound: IntegrationInstallerHelpers.findBinary(named: "claude", home: home) != nil,
            tuiBinaryPath: IntegrationInstallerHelpers.findBinary(named: "claude", home: home),
            createdConfig: false
        )
    }

    // Build fresh hashes.
    let installedAt = IntegrationInstallerHelpers.nowISO8601()
    let (_, freshHashes) = claudeCodeBuildBlock(installedAt: installedAt)
    let (merged, _) = claudeCodeMergeInto(existing: existing, with: [:], freshHashes: freshHashes, installedAt: installedAt)

    let newText = IntegrationInstallerHelpers.claudeCodeJSONDump(merged)

    // Detect noop: if priorState is installedCurrent (all hashes match), AND
    // the serialized post matches pre-byte-identical (modulo re-serialization),
    // we treat as noop. Because sortedKeys gives stable output, re-serializing
    // the same structure twice yields identical bytes.
    let noop: Bool
    if priorState == .installedCurrent {
        // Re-serialize existing with sorted keys for comparison.
        let canonicalPre = IntegrationInstallerHelpers.claudeCodeJSONDump(existing)
        noop = canonicalPre == newText
    } else {
        noop = false
    }

    let diff: String
    if noop {
        diff = "(no changes)"
    } else {
        diff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: preText, after: newText, label: configPath)
    }

    var summary: [String] = []
    switch priorState {
    case .notInstalled:
        summary.append(createdConfig ? "create \(configPath)" : "add cmux hooks to \(configPath)")
    case .installedCurrent:
        summary.append("cmux install is current (no changes)")
    case .installedOutdated:
        summary.append("update cmux hooks to schema \(IntegrationInstallerConstants.schemaVersion)")
    case .schemaMismatch:
        summary.append("schema mismatch: rewriting at schema \(IntegrationInstallerConstants.schemaVersion)")
    case .configMalformed, .markerHandEdit:
        summary.append("rewriting cmux hooks (prior state: \(priorState.rawValue))")
    }

    let binaryPath = IntegrationInstallerHelpers.findBinary(named: "claude", home: home)

    return IntegrationInstallerPlan(
        tui: .claudeCode,
        configPath: configPath,
        homePath: home,
        preConfigText: preText,
        postConfigText: noop ? preText : newText,
        shimPath: nil,
        preShimText: nil,
        postShimText: nil,
        priorState: priorState,
        newInstalledAt: installedAt,
        noop: noop,
        summary: summary,
        unifiedDiff: diff,
        tuiBinaryFound: binaryPath != nil,
        tuiBinaryPath: binaryPath,
        createdConfig: createdConfig
    )
}

fileprivate func claudeCodeExistingState(existing: [String: Any]) -> (state: IntegrationInstallerState, markerId: String?, schema: Int?) {
    guard let xCmux = existing["x-cmux"] as? [String: Any] else {
        return (.notInstalled, nil, nil)
    }
    let schema = xCmux["schema"] as? Int
    let markerId = xCmux["id"] as? String
    if let schema, schema != IntegrationInstallerConstants.schemaVersion {
        return (.schemaMismatch, markerId, schema)
    }
    // Verify each canonical event hash matches and that a live entry with that hash exists.
    var entriesByEvent: [String: String] = [:]
    if let entries = xCmux["entries"] as? [[String: Any]] {
        for e in entries {
            if let event = e["event"] as? String, let sha = e["sha256"] as? String {
                entriesByEvent[event] = sha
            }
        }
    }
    let hooks = (existing["hooks"] as? [String: Any]) ?? [:]
    var anyOutdated = false
    var anyMissing = false
    for (event, freshEntry) in claudeCanonicalEntries() {
        let freshHash = integrationInstallerSHA256(integrationInstallerCanonicalJSON(freshEntry))
        let storedHash = entriesByEvent[event]
        let entries = (hooks[event] as? [Any]) ?? []
        var liveHasStored = false
        for item in entries {
            if let dict = item as? [String: Any] {
                let h = integrationInstallerSHA256(integrationInstallerCanonicalJSON(dict))
                if storedHash != nil && h == storedHash {
                    liveHasStored = true
                    break
                }
            }
        }
        if storedHash == nil {
            anyMissing = true
        } else if storedHash != freshHash {
            anyOutdated = true
        } else if !liveHasStored {
            anyMissing = true
        }
    }
    if anyMissing { return (.installedOutdated, markerId, schema) }
    if anyOutdated { return (.installedOutdated, markerId, schema) }
    return (.installedCurrent, markerId, schema)
}

fileprivate func claudeCodeUninstallerPlan(
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    let preText = try IntegrationInstallerHelpers.readUTF8IfExists(configPath)
    guard let preText else {
        // Nothing to uninstall.
        return IntegrationInstallerPlan(
            tui: .claudeCode,
            configPath: configPath,
            homePath: home,
            preConfigText: nil,
            postConfigText: nil,
            shimPath: nil,
            preShimText: nil,
            postShimText: nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: true,
            summary: ["no config at \(configPath)"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    guard !preText.isEmpty else {
        return IntegrationInstallerPlan(
            tui: .claudeCode,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: preText,
            shimPath: nil,
            preShimText: nil,
            postShimText: nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: true,
            summary: ["config is empty"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    guard let data = preText.data(using: .utf8),
          let existing = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
        throw IntegrationInstallerError(
            code: "config_malformed",
            message: "Config at \(configPath) is not valid JSON",
            exitCode: InstallExitCode.configMalformed,
            path: configPath,
            jsonOutput: jsonOutput
        )
    }

    guard let xCmux = existing["x-cmux"] as? [String: Any] else {
        return IntegrationInstallerPlan(
            tui: .claudeCode,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: preText,
            shimPath: nil,
            preShimText: nil,
            postShimText: nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: true,
            summary: ["no cmux install detected"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    // Detect hand-edit: any stored entry whose hash no longer matches a live
    // entry. If so, error unless --force.
    var storedHashes: [String: String] = [:]
    if let entries = xCmux["entries"] as? [[String: Any]] {
        for e in entries {
            if let event = e["event"] as? String, let sha = e["sha256"] as? String {
                storedHashes[event] = sha
            }
        }
    }
    let storedSchema = xCmux["schema"] as? Int
    if let storedSchema, storedSchema != IntegrationInstallerConstants.schemaVersion, !force {
        throw IntegrationInstallerError(
            code: "marker_hand_edit_detected",
            message: "x-cmux.schema differs from current (\(storedSchema) vs \(IntegrationInstallerConstants.schemaVersion)); re-run uninstall with --force to proceed.",
            exitCode: InstallExitCode.markerHandEditDetected,
            path: configPath,
            jsonOutput: jsonOutput
        )
    }

    // Build post: remove matching cmux entries from hooks; remove x-cmux key.
    var hooks = (existing["hooks"] as? [String: Any]) ?? [:]
    var anyLiveMissing = false
    for (event, storedHash) in storedHashes {
        let arr = (hooks[event] as? [Any]) ?? []
        var filtered: [Any] = []
        var removed = false
        for item in arr {
            if let dict = item as? [String: Any] {
                let h = integrationInstallerSHA256(integrationInstallerCanonicalJSON(dict))
                if h == storedHash {
                    removed = true
                    continue
                }
            }
            filtered.append(item)
        }
        if !removed { anyLiveMissing = true }
        if filtered.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = filtered
        }
    }
    if anyLiveMissing && !force {
        throw IntegrationInstallerError(
            code: "marker_hand_edit_detected",
            message: "cmux-owned entries were hand-edited; re-run uninstall with --force to proceed. Unmatched entries left in place.",
            exitCode: InstallExitCode.markerHandEditDetected,
            path: configPath,
            jsonOutput: jsonOutput
        )
    }

    var result = existing
    if hooks.isEmpty {
        result.removeValue(forKey: "hooks")
    } else {
        result["hooks"] = hooks
    }
    result.removeValue(forKey: "x-cmux")

    let postText: String?
    if result.isEmpty {
        // Delete the file entirely.
        postText = nil
    } else {
        postText = IntegrationInstallerHelpers.claudeCodeJSONDump(result)
    }
    let diff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: preText, after: postText, label: configPath)

    return IntegrationInstallerPlan(
        tui: .claudeCode,
        configPath: configPath,
        homePath: home,
        preConfigText: preText,
        postConfigText: postText,
        shimPath: nil,
        preShimText: nil,
        postShimText: nil,
        priorState: .installedCurrent,
        newInstalledAt: "",
        noop: false,
        summary: postText == nil
            ? ["remove cmux install and delete empty config at \(configPath)"]
            : ["remove cmux install from \(configPath)"],
        unifiedDiff: diff,
        tuiBinaryFound: false,
        tuiBinaryPath: nil,
        createdConfig: false
    )
}

fileprivate func claudeCodeStatusSnapshot(
    configPath: String,
    tuiBinaryFound: Bool,
    tuiBinaryPath: String?
) -> IntegrationInstallerStatus {
    guard let text = (try? IntegrationInstallerHelpers.readUTF8IfExists(configPath)) ?? nil else {
        return IntegrationInstallerStatus(
            tui: .claudeCode,
            configPath: configPath,
            shimPath: nil,
            state: .notInstalled,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: nil,
            note: nil
        )
    }
    if text.isEmpty {
        return IntegrationInstallerStatus(
            tui: .claudeCode,
            configPath: configPath,
            shimPath: nil,
            state: .notInstalled,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: nil,
            note: "empty config"
        )
    }

    guard let data = text.data(using: .utf8),
          let existing = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
        return IntegrationInstallerStatus(
            tui: .claudeCode,
            configPath: configPath,
            shimPath: nil,
            state: .configMalformed,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: "invalid JSON",
            note: nil
        )
    }

    let (state, markerId, schema) = claudeCodeExistingState(existing: existing)
    var expected: [String: String] = [:]
    for (event, entry) in claudeCanonicalEntries() {
        expected[event] = integrationInstallerSHA256(integrationInstallerCanonicalJSON(entry))
    }
    var actual: [String: String] = [:]
    if let xCmux = existing["x-cmux"] as? [String: Any],
       let entries = xCmux["entries"] as? [[String: Any]] {
        for e in entries {
            if let event = e["event"] as? String, let sha = e["sha256"] as? String {
                actual[event] = sha
            }
        }
    }
    let installedAt = (existing["x-cmux"] as? [String: Any])?["installed_at"] as? String

    return IntegrationInstallerStatus(
        tui: .claudeCode,
        configPath: configPath,
        shimPath: nil,
        state: state,
        schemaVersion: schema,
        markerId: markerId,
        installedAt: installedAt,
        tuiBinaryFound: tuiBinaryFound,
        tuiBinaryPath: tuiBinaryPath,
        expectedHashes: expected,
        actualHashes: actual,
        parserError: nil,
        note: nil
    )
}

// MARK: - TOML shim installer (codex, kimi)

fileprivate func tomlShimBlock(tui: IntegrationInstallerTUI, installedAt: String, shimPath: String, shimSHA: String) -> String {
    return """
    \(IntegrationInstallerConstants.tomlFenceBegin)
    [x-cmux]
    schema = \(IntegrationInstallerConstants.schemaVersion)
    id = "\(IntegrationInstallerConstants.markerId)"
    installed_at = "\(installedAt)"
    shim_path = "\(shimPath)"
    shim_sha256 = "\(shimSHA)"
    # Managed by `cmux install \(tui.rawValue)`.
    \(IntegrationInstallerConstants.tomlFenceEnd)
    """
}

fileprivate func tomlStripExistingCmuxBlock(_ text: String) -> (stripped: String, removedRange: Range<String.Index>?) {
    guard let beginRange = text.range(of: IntegrationInstallerConstants.tomlFenceBegin) else {
        return (text, nil)
    }
    // Expand begin to include the leading newline if present.
    var start = beginRange.lowerBound
    if start > text.startIndex {
        let before = text.index(before: start)
        if text[before] == "\n" {
            start = before
        }
    }
    let endRange = text.range(
        of: IntegrationInstallerConstants.tomlFenceEnd,
        options: [],
        range: beginRange.upperBound..<text.endIndex
    )
    guard let endRange else {
        return (text, nil)
    }
    var end = endRange.upperBound
    // Include a trailing newline after the fence if present.
    if end < text.endIndex, text[end] == "\n" {
        end = text.index(after: end)
    }
    var stripped = text
    let cutRange = start..<end
    stripped.removeSubrange(cutRange)
    return (stripped, cutRange)
}

fileprivate func tomlShimInstallerPlan(
    tui: IntegrationInstallerTUI,
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    precondition(tui == .codex || tui == .kimi, "tomlShimInstallerPlan supports codex/kimi only")

    let preText = try IntegrationInstallerHelpers.readUTF8IfExists(configPath)
    let createdConfig = preText == nil

    let shimPath = tui.shimPath(home: home)
    let shimText = integrationInstallerShimScript(for: tui)
    let shimSHA = integrationInstallerSHA256(of: shimText)
    let installedAt = IntegrationInstallerHelpers.nowISO8601()
    let block = tomlShimBlock(tui: tui, installedAt: installedAt, shimPath: shimPath, shimSHA: shimSHA)

    // Strip any existing cmux block first.
    let (stripped, _) = tomlStripExistingCmuxBlock(preText ?? "")

    // Determine prior state.
    let priorState: IntegrationInstallerState
    var priorShimSHA: String? = nil
    var priorSchema: Int? = nil
    if let preText, let beginRange = preText.range(of: IntegrationInstallerConstants.tomlFenceBegin),
       let endRange = preText.range(of: IntegrationInstallerConstants.tomlFenceEnd, options: [], range: beginRange.upperBound..<preText.endIndex) {
        let blockText = String(preText[beginRange.lowerBound..<endRange.upperBound])
        priorShimSHA = tomlExtractValue(from: blockText, key: "shim_sha256")
        if let schemaStr = tomlExtractValue(from: blockText, key: "schema"), let parsed = Int(schemaStr) {
            priorSchema = parsed
        }
        if let priorSchema, priorSchema != IntegrationInstallerConstants.schemaVersion {
            priorState = .schemaMismatch
        } else {
            // Check shim on disk.
            let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
            let liveShimSHA = liveShim.map { integrationInstallerSHA256(of: $0) }
            if priorShimSHA == shimSHA && liveShimSHA == shimSHA {
                priorState = .installedCurrent
            } else {
                priorState = .installedOutdated
            }
        }
    } else {
        priorState = .notInstalled
    }

    if priorState == .schemaMismatch && !force {
        return IntegrationInstallerPlan(
            tui: tui,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: nil,
            shimPath: shimPath,
            preShimText: try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath),
            postShimText: nil,
            priorState: .schemaMismatch,
            newInstalledAt: installedAt,
            noop: true,
            summary: ["cmux install uses schema \(priorSchema ?? 0); expected \(IntegrationInstallerConstants.schemaVersion). Re-run with --force."],
            unifiedDiff: "",
            tuiBinaryFound: IntegrationInstallerHelpers.findBinary(named: tui.binaryName(), home: home) != nil,
            tuiBinaryPath: IntegrationInstallerHelpers.findBinary(named: tui.binaryName(), home: home),
            createdConfig: false
        )
    }

    // Build new text.
    let strippedEndsWithNewline = stripped.hasSuffix("\n") || stripped.isEmpty
    var newText: String = stripped
    if !stripped.isEmpty && !strippedEndsWithNewline {
        newText += "\n"
    }
    if !stripped.isEmpty {
        // separate existing content from our block with a blank line.
        newText += "\n"
    }
    newText += block + "\n"

    let noop: Bool
    if priorState == .installedCurrent {
        // Compare our new block to what's there; shims match; config content unchanged => noop.
        let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
        noop = (preText == newText) && (liveShim == shimText)
    } else {
        noop = false
    }

    let diff: String
    if noop {
        diff = "(no changes)"
    } else {
        let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
        let configDiff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: preText, after: newText, label: configPath)
        let shimDiff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: liveShim ?? nil, after: shimText, label: shimPath)
        diff = configDiff + "\n" + shimDiff
    }

    var summary: [String] = []
    switch priorState {
    case .notInstalled:
        summary.append(createdConfig ? "create \(configPath)" : "append [x-cmux] block to \(configPath)")
        summary.append("install shim at \(shimPath)")
    case .installedCurrent:
        summary.append("cmux install is current (no changes)")
    case .installedOutdated:
        summary.append("refresh [x-cmux] block in \(configPath)")
        summary.append("refresh shim at \(shimPath)")
    case .schemaMismatch:
        summary.append("schema mismatch: rewriting [x-cmux] at schema \(IntegrationInstallerConstants.schemaVersion)")
        summary.append("refresh shim at \(shimPath)")
    case .configMalformed, .markerHandEdit:
        summary.append("rewriting cmux block (prior state: \(priorState.rawValue))")
    }

    let tuiBinaryPath = IntegrationInstallerHelpers.findBinary(named: tui.binaryName(), home: home)
    return IntegrationInstallerPlan(
        tui: tui,
        configPath: configPath,
        homePath: home,
        preConfigText: preText,
        postConfigText: noop ? preText : newText,
        shimPath: shimPath,
        preShimText: try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath),
        postShimText: noop ? (try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)) ?? shimText : shimText,
        priorState: priorState,
        newInstalledAt: installedAt,
        noop: noop,
        summary: summary,
        unifiedDiff: diff,
        tuiBinaryFound: tuiBinaryPath != nil,
        tuiBinaryPath: tuiBinaryPath,
        createdConfig: createdConfig
    )
}

fileprivate func tomlExtractValue(from block: String, key: String) -> String? {
    for rawLine in block.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("\(key) =") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            var value = parts[1]
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
    }
    return nil
}

fileprivate func tomlShimUninstallerPlan(
    tui: IntegrationInstallerTUI,
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    let preText = try IntegrationInstallerHelpers.readUTF8IfExists(configPath)
    let shimPath = tui.shimPath(home: home)
    let preShim = try IntegrationInstallerHelpers.readUTF8IfExists(shimPath)

    guard let preText else {
        return IntegrationInstallerPlan(
            tui: tui,
            configPath: configPath,
            homePath: home,
            preConfigText: nil,
            postConfigText: nil,
            shimPath: shimPath,
            preShimText: preShim,
            postShimText: nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: preShim == nil,
            summary: preShim == nil ? ["nothing to uninstall"] : ["remove shim at \(shimPath)"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    guard preText.range(of: IntegrationInstallerConstants.tomlFenceBegin) != nil else {
        return IntegrationInstallerPlan(
            tui: tui,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: preText,
            shimPath: shimPath,
            preShimText: preShim,
            postShimText: preShim == nil ? nil : nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: preShim == nil,
            summary: preShim == nil ? ["nothing to uninstall"] : ["remove shim at \(shimPath)"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    // Hand-edit detection (force bypass).
    if let beginRange = preText.range(of: IntegrationInstallerConstants.tomlFenceBegin),
       let endRange = preText.range(of: IntegrationInstallerConstants.tomlFenceEnd, options: [], range: beginRange.upperBound..<preText.endIndex) {
        let blockText = String(preText[beginRange.lowerBound..<endRange.upperBound])
        let storedSchema = tomlExtractValue(from: blockText, key: "schema").flatMap(Int.init)
        if let storedSchema, storedSchema != IntegrationInstallerConstants.schemaVersion, !force {
            throw IntegrationInstallerError(
                code: "marker_hand_edit_detected",
                message: "x-cmux.schema differs from current; re-run uninstall with --force.",
                exitCode: InstallExitCode.markerHandEditDetected,
                path: configPath,
                jsonOutput: jsonOutput
            )
        }
    }

    let (stripped, _) = tomlStripExistingCmuxBlock(preText)

    // If resulting content is empty, delete the file entirely.
    let postText: String?
    if stripped.isEmpty {
        postText = nil
    } else {
        postText = stripped
    }

    let diff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: preText, after: postText, label: configPath)
    var summary: [String] = ["remove [x-cmux] block from \(configPath)"]
    if preShim != nil { summary.append("remove shim at \(shimPath)") }
    if postText == nil { summary.append("delete empty config file") }

    return IntegrationInstallerPlan(
        tui: tui,
        configPath: configPath,
        homePath: home,
        preConfigText: preText,
        postConfigText: postText,
        shimPath: shimPath,
        preShimText: preShim,
        postShimText: nil,
        priorState: .installedCurrent,
        newInstalledAt: "",
        noop: false,
        summary: summary,
        unifiedDiff: diff,
        tuiBinaryFound: false,
        tuiBinaryPath: nil,
        createdConfig: false
    )
}

fileprivate func tomlShimStatusSnapshot(
    tui: IntegrationInstallerTUI,
    configPath: String,
    home: String,
    tuiBinaryFound: Bool,
    tuiBinaryPath: String?
) -> IntegrationInstallerStatus {
    let shimPath = tui.shimPath(home: home)
    guard let text = (try? IntegrationInstallerHelpers.readUTF8IfExists(configPath)) ?? nil else {
        return IntegrationInstallerStatus(
            tui: tui,
            configPath: configPath,
            shimPath: shimPath,
            state: .notInstalled,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: nil,
            note: nil
        )
    }
    guard let beginRange = text.range(of: IntegrationInstallerConstants.tomlFenceBegin),
          let endRange = text.range(of: IntegrationInstallerConstants.tomlFenceEnd, options: [], range: beginRange.upperBound..<text.endIndex) else {
        return IntegrationInstallerStatus(
            tui: tui,
            configPath: configPath,
            shimPath: shimPath,
            state: .notInstalled,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: nil,
            note: nil
        )
    }
    let blockText = String(text[beginRange.lowerBound..<endRange.upperBound])
    let schema = tomlExtractValue(from: blockText, key: "schema").flatMap(Int.init)
    let markerId = tomlExtractValue(from: blockText, key: "id")
    let installedAt = tomlExtractValue(from: blockText, key: "installed_at")
    let storedShimSHA = tomlExtractValue(from: blockText, key: "shim_sha256")
    let expectedShimSHA = integrationInstallerSHA256(of: integrationInstallerShimScript(for: tui))
    let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
    let liveShimSHA = liveShim.map { integrationInstallerSHA256(of: $0) }

    let state: IntegrationInstallerState
    if let schema, schema != IntegrationInstallerConstants.schemaVersion {
        state = .schemaMismatch
    } else if storedShimSHA == expectedShimSHA && liveShimSHA == expectedShimSHA {
        state = .installedCurrent
    } else {
        state = .installedOutdated
    }

    return IntegrationInstallerStatus(
        tui: tui,
        configPath: configPath,
        shimPath: shimPath,
        state: state,
        schemaVersion: schema,
        markerId: markerId,
        installedAt: installedAt,
        tuiBinaryFound: tuiBinaryFound,
        tuiBinaryPath: tuiBinaryPath,
        expectedHashes: ["shim": expectedShimSHA],
        actualHashes: ["shim": storedShimSHA ?? "", "shim_live": liveShimSHA ?? ""],
        parserError: nil,
        note: nil
    )
}

// MARK: - OpenCode shim installer (JSON + shim)

fileprivate func opencodeShimInstallerPlan(
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    let preText = try IntegrationInstallerHelpers.readUTF8IfExists(configPath)
    let createdConfig = preText == nil

    let shimPath = IntegrationInstallerTUI.opencode.shimPath(home: home)
    let shimText = integrationInstallerShimScript(for: .opencode)
    let shimSHA = integrationInstallerSHA256(of: shimText)
    let installedAt = IntegrationInstallerHelpers.nowISO8601()

    var existing: [String: Any] = [:]
    if let text = preText, !text.isEmpty {
        guard let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            throw IntegrationInstallerError(
                code: "config_malformed",
                message: "Config at \(configPath) is not a valid JSON object",
                exitCode: InstallExitCode.configMalformed,
                path: configPath,
                jsonOutput: jsonOutput
            )
        }
        existing = dict
    }

    let priorState: IntegrationInstallerState
    var priorSchema: Int? = nil
    if let xCmux = existing["x-cmux"] as? [String: Any] {
        priorSchema = xCmux["schema"] as? Int
        if let priorSchema, priorSchema != IntegrationInstallerConstants.schemaVersion {
            priorState = .schemaMismatch
        } else {
            let storedShim = xCmux["shim_sha256"] as? String
            let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
            let liveSHA = liveShim.map { integrationInstallerSHA256(of: $0) }
            if storedShim == shimSHA && liveSHA == shimSHA {
                priorState = .installedCurrent
            } else {
                priorState = .installedOutdated
            }
        }
    } else {
        priorState = .notInstalled
    }

    if priorState == .schemaMismatch && !force {
        return IntegrationInstallerPlan(
            tui: .opencode,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: nil,
            shimPath: shimPath,
            preShimText: try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath),
            postShimText: nil,
            priorState: .schemaMismatch,
            newInstalledAt: installedAt,
            noop: true,
            summary: ["cmux install uses schema \(priorSchema ?? 0); expected \(IntegrationInstallerConstants.schemaVersion). Re-run with --force."],
            unifiedDiff: "",
            tuiBinaryFound: IntegrationInstallerHelpers.findBinary(named: "opencode", home: home) != nil,
            tuiBinaryPath: IntegrationInstallerHelpers.findBinary(named: "opencode", home: home),
            createdConfig: false
        )
    }

    var result = existing
    result["x-cmux"] = [
        "schema": IntegrationInstallerConstants.schemaVersion,
        "id": IntegrationInstallerConstants.markerId,
        "installed_at": installedAt,
        "shim_path": shimPath,
        "shim_sha256": shimSHA
    ] as [String: Any]
    let newText = IntegrationInstallerHelpers.claudeCodeJSONDump(result)

    let noop: Bool
    if priorState == .installedCurrent {
        let canonicalPre = IntegrationInstallerHelpers.claudeCodeJSONDump(existing)
        let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
        noop = canonicalPre == newText && liveShim == shimText
    } else {
        noop = false
    }

    let diff: String
    if noop {
        diff = "(no changes)"
    } else {
        let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
        let configDiff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: preText, after: newText, label: configPath)
        let shimDiff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: liveShim ?? nil, after: shimText, label: shimPath)
        diff = configDiff + "\n" + shimDiff
    }

    var summary: [String] = []
    switch priorState {
    case .notInstalled:
        summary.append(createdConfig ? "create \(configPath)" : "add x-cmux key to \(configPath)")
        summary.append("install shim at \(shimPath)")
    case .installedCurrent:
        summary.append("cmux install is current (no changes)")
    case .installedOutdated:
        summary.append("refresh x-cmux in \(configPath)")
        summary.append("refresh shim at \(shimPath)")
    case .schemaMismatch:
        summary.append("schema mismatch: rewriting x-cmux at schema \(IntegrationInstallerConstants.schemaVersion)")
        summary.append("refresh shim at \(shimPath)")
    case .configMalformed, .markerHandEdit:
        summary.append("rewriting x-cmux (prior state: \(priorState.rawValue))")
    }

    let tuiBinaryPath = IntegrationInstallerHelpers.findBinary(named: "opencode", home: home)
    return IntegrationInstallerPlan(
        tui: .opencode,
        configPath: configPath,
        homePath: home,
        preConfigText: preText,
        postConfigText: noop ? preText : newText,
        shimPath: shimPath,
        preShimText: try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath),
        postShimText: noop ? (try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)) ?? shimText : shimText,
        priorState: priorState,
        newInstalledAt: installedAt,
        noop: noop,
        summary: summary,
        unifiedDiff: diff,
        tuiBinaryFound: tuiBinaryPath != nil,
        tuiBinaryPath: tuiBinaryPath,
        createdConfig: createdConfig
    )
}

fileprivate func opencodeShimUninstallerPlan(
    configPath: String,
    home: String,
    force: Bool,
    jsonOutput: Bool
) throws -> IntegrationInstallerPlan {
    let preText = try IntegrationInstallerHelpers.readUTF8IfExists(configPath)
    let shimPath = IntegrationInstallerTUI.opencode.shimPath(home: home)
    let preShim = try IntegrationInstallerHelpers.readUTF8IfExists(shimPath)

    guard let preText else {
        return IntegrationInstallerPlan(
            tui: .opencode,
            configPath: configPath,
            homePath: home,
            preConfigText: nil,
            postConfigText: nil,
            shimPath: shimPath,
            preShimText: preShim,
            postShimText: nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: preShim == nil,
            summary: preShim == nil ? ["nothing to uninstall"] : ["remove shim at \(shimPath)"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    guard !preText.isEmpty,
          let data = preText.data(using: .utf8),
          let existing = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
        throw IntegrationInstallerError(
            code: "config_malformed",
            message: "Config at \(configPath) is not valid JSON",
            exitCode: InstallExitCode.configMalformed,
            path: configPath,
            jsonOutput: jsonOutput
        )
    }

    guard let xCmux = existing["x-cmux"] as? [String: Any] else {
        return IntegrationInstallerPlan(
            tui: .opencode,
            configPath: configPath,
            homePath: home,
            preConfigText: preText,
            postConfigText: preText,
            shimPath: shimPath,
            preShimText: preShim,
            postShimText: preShim == nil ? nil : nil,
            priorState: .notInstalled,
            newInstalledAt: "",
            noop: preShim == nil,
            summary: preShim == nil ? ["nothing to uninstall"] : ["remove shim at \(shimPath)"],
            unifiedDiff: "",
            tuiBinaryFound: false,
            tuiBinaryPath: nil,
            createdConfig: false
        )
    }

    let storedSchema = xCmux["schema"] as? Int
    if let storedSchema, storedSchema != IntegrationInstallerConstants.schemaVersion, !force {
        throw IntegrationInstallerError(
            code: "marker_hand_edit_detected",
            message: "x-cmux.schema differs from current; re-run uninstall with --force.",
            exitCode: InstallExitCode.markerHandEditDetected,
            path: configPath,
            jsonOutput: jsonOutput
        )
    }

    var result = existing
    result.removeValue(forKey: "x-cmux")

    let postText: String?
    if result.isEmpty {
        postText = nil
    } else {
        postText = IntegrationInstallerHelpers.claudeCodeJSONDump(result)
    }

    let diff = IntegrationInstallerHelpers.simpleUnifiedDiff(before: preText, after: postText, label: configPath)
    var summary: [String] = ["remove x-cmux from \(configPath)"]
    if preShim != nil { summary.append("remove shim at \(shimPath)") }
    if postText == nil { summary.append("delete empty config file") }

    return IntegrationInstallerPlan(
        tui: .opencode,
        configPath: configPath,
        homePath: home,
        preConfigText: preText,
        postConfigText: postText,
        shimPath: shimPath,
        preShimText: preShim,
        postShimText: nil,
        priorState: .installedCurrent,
        newInstalledAt: "",
        noop: false,
        summary: summary,
        unifiedDiff: diff,
        tuiBinaryFound: false,
        tuiBinaryPath: nil,
        createdConfig: false
    )
}

fileprivate func opencodeShimStatusSnapshot(
    configPath: String,
    home: String,
    tuiBinaryFound: Bool,
    tuiBinaryPath: String?
) -> IntegrationInstallerStatus {
    let shimPath = IntegrationInstallerTUI.opencode.shimPath(home: home)
    guard let text = (try? IntegrationInstallerHelpers.readUTF8IfExists(configPath)) ?? nil, !text.isEmpty else {
        return IntegrationInstallerStatus(
            tui: .opencode,
            configPath: configPath,
            shimPath: shimPath,
            state: .notInstalled,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: nil,
            note: nil
        )
    }
    guard let data = text.data(using: .utf8),
          let existing = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
        return IntegrationInstallerStatus(
            tui: .opencode,
            configPath: configPath,
            shimPath: shimPath,
            state: .configMalformed,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: "invalid JSON",
            note: nil
        )
    }
    guard let xCmux = existing["x-cmux"] as? [String: Any] else {
        return IntegrationInstallerStatus(
            tui: .opencode,
            configPath: configPath,
            shimPath: shimPath,
            state: .notInstalled,
            schemaVersion: nil,
            markerId: nil,
            installedAt: nil,
            tuiBinaryFound: tuiBinaryFound,
            tuiBinaryPath: tuiBinaryPath,
            expectedHashes: [:],
            actualHashes: [:],
            parserError: nil,
            note: nil
        )
    }
    let schema = xCmux["schema"] as? Int
    let markerId = xCmux["id"] as? String
    let installedAt = xCmux["installed_at"] as? String
    let storedShim = xCmux["shim_sha256"] as? String ?? ""
    let expectedShim = integrationInstallerSHA256(of: integrationInstallerShimScript(for: .opencode))
    let liveShim = try? IntegrationInstallerHelpers.readUTF8IfExists(shimPath)
    let liveShimSHA = liveShim.map { integrationInstallerSHA256(of: $0) } ?? ""

    let state: IntegrationInstallerState
    if let schema, schema != IntegrationInstallerConstants.schemaVersion {
        state = .schemaMismatch
    } else if storedShim == expectedShim && liveShimSHA == expectedShim {
        state = .installedCurrent
    } else {
        state = .installedOutdated
    }

    return IntegrationInstallerStatus(
        tui: .opencode,
        configPath: configPath,
        shimPath: shimPath,
        state: state,
        schemaVersion: schema,
        markerId: markerId,
        installedAt: installedAt,
        tuiBinaryFound: tuiBinaryFound,
        tuiBinaryPath: tuiBinaryPath,
        expectedHashes: ["shim": expectedShim],
        actualHashes: ["shim": storedShim, "shim_live": liveShimSHA],
        parserError: nil,
        note: nil
    )
}

// MARK: - `cmux skill` subcommand
//
// Active install is scoped to Claude Code — matching the grandfathered
// `Resources/bin/claude` precedent. For every other TUI the CLI reports
// detection and prints a copy-paste snippet; c11 does not write into
// `~/.codex/`, `~/.kimi/`, or `~/.opencode/` unless the operator explicitly
// passes `--tool <name>` (a deliberate operator-directed act).

extension CMUXCLI {
    fileprivate func runSkillCommand(commandArgs: [String], jsonOutput: Bool) throws {
        guard let sub = commandArgs.first else {
            print(skillCommandUsage())
            return
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "-h", "--help":
            print(skillCommandUsage())
        case "path":
            try runSkillPath(args: rest, jsonOutput: jsonOutput)
        case "status", "list":
            try runSkillStatus(args: rest, jsonOutput: jsonOutput)
        case "install":
            try runSkillInstall(args: rest, jsonOutput: jsonOutput)
        case "remove", "uninstall":
            try runSkillRemove(args: rest, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Unknown skill subcommand: \(sub). Try `c11 skill help`.")
        }
    }

    // MARK: Structured skill-subcommand parser.
    //
    // The global optionValue/hasFlag helpers are permissive: they don't
    // understand `--flag=value`, don't reject unknown flags, and happily
    // consume the next flag as a value. For `cmux skill`, a user mistyping
    // `--home --json` previously resolved the home override to the string
    // `--json`, which is worse than failing. Each skill subcommand declares
    // its allowed flags and this parser rejects anything outside the list.

    fileprivate struct SkillFlagSpec {
        enum Kind { case flag, value }
        let name: String
        let kind: Kind
    }

    fileprivate struct ParsedSkillArgs {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []

        func value(_ name: String) -> String? { values[name] }
        func has(_ name: String) -> Bool { flags.contains(name) }
    }

    fileprivate func parseSkillSubcommandArgs(
        _ args: [String],
        spec: [SkillFlagSpec]
    ) throws -> ParsedSkillArgs {
        let byName = Dictionary(uniqueKeysWithValues: spec.map { ($0.name, $0) })
        var out = ParsedSkillArgs()
        var i = 0
        while i < args.count {
            let raw = args[i]
            if raw.hasPrefix("--") {
                let name: String
                let inlineValue: String?
                if let eq = raw.firstIndex(of: "=") {
                    name = String(raw[..<eq])
                    inlineValue = String(raw[raw.index(after: eq)...])
                } else {
                    name = raw
                    inlineValue = nil
                }
                guard let flag = byName[name] else {
                    throw CLIError(message: "Unknown flag '\(name)' for this subcommand.")
                }
                switch flag.kind {
                case .flag:
                    if inlineValue != nil {
                        throw CLIError(message: "Flag '\(name)' does not take a value.")
                    }
                    out.flags.insert(name)
                case .value:
                    if let v = inlineValue {
                        out.values[name] = v
                    } else {
                        guard i + 1 < args.count else {
                            throw CLIError(message: "Flag '\(name)' requires a value.")
                        }
                        let next = args[i + 1]
                        if next.hasPrefix("--") {
                            throw CLIError(message: "Flag '\(name)' requires a value, got another flag '\(next)'.")
                        }
                        out.values[name] = next
                        i += 1
                    }
                }
            } else {
                out.positional.append(raw)
            }
            i += 1
        }
        return out
    }

    /// JSON encoder for `cmux skill *` output. Forces `.sortedKeys` so
    /// scripts parsing the output get deterministic key order across builds.
    fileprivate func skillJSONString(_ object: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    private func skillCommandUsage() -> String {
        return """
        c11 skill — manage the c11 skill file for detected agent tools.

        Subcommands:
          path                           Print the bundled skill source directory.
          status [--tool NAME] [--json]  Show detection + install status per tool.
          install [--tool NAME]          Install (default: claude only).
                  [--dry-run] [--force]  Dry-run, or force re-copy even if hash matches.
                  [--home PATH]          Override $HOME (useful for tests).
          remove  [--tool NAME]          Remove c11-installed skills from the tool.
                  [--home PATH]

        Tools: claude, codex, kimi, opencode.

        Principle:
          Claude Code is the default active install (grandfathered exception).
          For every other tool, c11 prints the manual command and only writes
          to disk when --tool is passed explicitly — the operator stays in charge.
        """
    }

    private func homeFromParsedSkillArgs(_ parsed: ParsedSkillArgs) -> URL {
        if let override = parsed.value("--home") {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        let envHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: envHome, isDirectory: true).standardizedFileURL
    }

    private func targetFromParsedSkillArgs(
        _ parsed: ParsedSkillArgs,
        defaultTarget: SkillInstallerTarget
    ) throws -> SkillInstallerTarget {
        guard let raw = parsed.value("--tool") else { return defaultTarget }
        guard let tool = SkillInstallerTarget(rawValue: raw.lowercased()) else {
            throw CLIError(message: "Unknown tool '\(raw)'. Supported: \(SkillInstallerTarget.allCases.map { $0.rawValue }.joined(separator: ", "))")
        }
        return tool
    }

    private func resolveSkillSource(jsonOutput: Bool) throws -> URL {
        let exec = resolvedExecutableURL()
        guard let source = SkillInstaller.defaultSourceURL(executableURL: exec) else {
            throw CLIError(message: "Could not locate the bundled skills directory. Set C11_SKILLS_SOURCE to override.")
        }
        return source
    }

    private func runSkillPath(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--json", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        if jsonOutput || parsed.has("--json") {
            print(skillJSONString(["path": source.path]))
        } else {
            print(source.path)
        }
    }

    private func runSkillStatus(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--tool", kind: .value),
            SkillFlagSpec(name: "--home", kind: .value),
            SkillFlagSpec(name: "--json", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        let home = homeFromParsedSkillArgs(parsed)
        let emitJSON = jsonOutput || parsed.has("--json")

        var targets = SkillInstallerTarget.allCases
        if let raw = parsed.value("--tool") {
            guard let target = SkillInstallerTarget(rawValue: raw.lowercased()) else {
                throw CLIError(message: "Unknown tool '\(raw)'.")
            }
            targets = [target]
        }

        var rows: [[String: Any]] = []
        for target in targets {
            let detected = target.isDetected(home: home)
            var packageRows: [[String: Any]] = []
            var errorPayload: [String: Any]? = nil
            if detected {
                do {
                    let statuses = try SkillInstaller.status(for: target, home: home, sourceDir: source)
                    packageRows = statuses.map { st in
                        var row: [String: Any] = [
                            "package": st.package.name,
                            "state": st.state.rawValue,
                            "dest": st.destinationDir.path,
                            "source_sha256": st.sourceContentHash,
                        ]
                        if let record = st.record {
                            row["installed_sha256"] = record.sourceContentHash
                            row["installed_at"] = record.installedAt
                            row["app_version"] = record.appVersion
                        }
                        return row
                    }
                } catch let err as SkillInstallerError {
                    var payload: [String: Any] = [
                        "code": err.code.rawValue,
                        "message": err.message,
                    ]
                    if let p = err.path { payload["path"] = p }
                    errorPayload = payload
                } catch {
                    errorPayload = [
                        "code": "unknown",
                        "message": "\(error)",
                    ]
                }
            }
            var row: [String: Any] = [
                "tool": target.rawValue,
                "display_name": target.displayName,
                "detected": detected,
                "skills_dir": target.skillsDir(home: home).path,
                "packages": packageRows,
            ]
            if let err = errorPayload { row["error"] = err }
            rows.append(row)
        }

        if emitJSON {
            print(skillJSONString(["targets": rows, "source": source.path]))
            return
        }
        print("Bundled skills: \(source.path)")
        print("")
        for row in rows {
            let tool = (row["tool"] as? String) ?? "?"
            let display = (row["display_name"] as? String) ?? tool
            let detected = (row["detected"] as? Bool) ?? false
            let dir = (row["skills_dir"] as? String) ?? ""
            let detectTag = detected ? "detected" : "not detected"
            print("\(display) [\(tool)] — \(detectTag)")
            print("  skills dir: \(dir)")
            if let err = row["error"] as? [String: Any] {
                let code = (err["code"] as? String) ?? "error"
                let msg = (err["message"] as? String) ?? ""
                print("  error [\(code)]: \(msg)")
                continue
            }
            let packageRows = (row["packages"] as? [[String: Any]]) ?? []
            if !detected {
                print("  (\(display) config dir not present; install skipped)")
                continue
            }
            if packageRows.isEmpty {
                print("  (no bundled packages found)")
                continue
            }
            for pkg in packageRows {
                let name = (pkg["package"] as? String) ?? "?"
                let state = (pkg["state"] as? String) ?? "?"
                let version = (pkg["app_version"] as? String).map { " v\($0)" } ?? ""
                let installed = (pkg["installed_at"] as? String).map { " @ \($0)" } ?? ""
                print("  - \(name): \(state)\(version)\(installed)")
            }
        }
    }

    private func runSkillInstall(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--tool", kind: .value),
            SkillFlagSpec(name: "--home", kind: .value),
            SkillFlagSpec(name: "--json", kind: .flag),
            SkillFlagSpec(name: "--force", kind: .flag),
            SkillFlagSpec(name: "--dry-run", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        let home = homeFromParsedSkillArgs(parsed)
        let target = try targetFromParsedSkillArgs(parsed, defaultTarget: .claude)
        let dryRun = parsed.has("--dry-run")
        let force = parsed.has("--force")
        let emitJSON = jsonOutput || parsed.has("--json")

        if !target.isDetected(home: home) {
            let msg = "Tool '\(target.rawValue)' config dir \(target.configRoot(home: home).path) not found. Install \(target.displayName) first, or pass --tool <other> if you meant a different target."
            if emitJSON {
                print(skillJSONString(["error": "target_not_detected", "tool": target.rawValue, "message": msg]))
                exit(2)
            }
            throw CLIError(message: msg)
        }

        if dryRun {
            let statuses = try SkillInstaller.status(for: target, home: home, sourceDir: source)
            let planned = statuses.filter { force || $0.state != .installedCurrent }.map { $0.package.name }
            let skipped = statuses.filter { !force && $0.state == .installedCurrent }.map { $0.package.name }
            if emitJSON {
                print(skillJSONString([
                    "dry_run": true,
                    "tool": target.rawValue,
                    "planned": planned,
                    "skipped": skipped,
                    "dest": target.skillsDir(home: home).path,
                ]))
            } else {
                print("Dry run — \(target.displayName) (\(target.skillsDir(home: home).path))")
                if planned.isEmpty {
                    print("  nothing to do; all packages current")
                } else {
                    print("  would write: \(planned.joined(separator: ", "))")
                }
                if !skipped.isEmpty {
                    print("  would skip (up-to-date): \(skipped.joined(separator: ", "))")
                }
            }
            return
        }

        let result = try SkillInstaller.install(
            target: target,
            home: home,
            sourceDir: source,
            force: force
        )

        if emitJSON {
            print(skillJSONString([
                "tool": target.rawValue,
                "dest": result.destDir.path,
                "installed": result.installed,
                "refreshed": result.refreshed,
                "skipped": result.skipped,
            ]))
            return
        }
        print("Installed skill for \(target.displayName) at \(result.destDir.path)")
        if !result.installed.isEmpty {
            print("  installed: \(result.installed.joined(separator: ", "))")
        }
        if !result.refreshed.isEmpty {
            print("  refreshed: \(result.refreshed.joined(separator: ", "))")
        }
        if !result.skipped.isEmpty {
            print("  skipped (up-to-date): \(result.skipped.joined(separator: ", "))")
        }
    }

    private func runSkillRemove(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--tool", kind: .value),
            SkillFlagSpec(name: "--home", kind: .value),
            SkillFlagSpec(name: "--json", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        let home = homeFromParsedSkillArgs(parsed)
        let target = try targetFromParsedSkillArgs(parsed, defaultTarget: .claude)
        let emitJSON = jsonOutput || parsed.has("--json")

        let result = try SkillInstaller.remove(target: target, home: home, sourceDir: source)
        if emitJSON {
            print(skillJSONString([
                "tool": target.rawValue,
                "dest": result.destDir.path,
                "removed": result.removed,
                "skipped": result.skipped,
            ]))
            return
        }
        print("Removed skill for \(target.displayName) from \(result.destDir.path)")
        if !result.removed.isEmpty {
            print("  removed: \(result.removed.joined(separator: ", "))")
        }
        if !result.skipped.isEmpty {
            print("  skipped: \(result.skipped.joined(separator: ", "))")
        }
    }
}

// MARK: - C11-13 Stage 2: `c11 mailbox` subcommand
//
// Pure file-I/O wrappers around MailboxEnvelope + MailboxIO + MailboxLayout.
// One socket call in practice: `surface.get_metadata` to resolve the caller's
// surface title. Raw-bash writers use the outbox-dir / inbox-dir / surface-name
// helpers to avoid any c11-provided env vars.

extension CMUXCLI {

    fileprivate func runMailboxCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let sub = commandArgs.first else {
            print(mailboxUsage())
            return
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "-h", "--help":
            print(mailboxUsage())
        case "send":
            try runMailboxSendCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "recv":
            try runMailboxRecvCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "trace":
            try runMailboxTraceCommand(subArgs: rest, client: client, jsonOutput: jsonOutput)
        case "tail":
            try runMailboxTailCommand(subArgs: rest, client: client)
        case "outbox-dir":
            try runMailboxOutboxDirCommand(subArgs: rest, client: client)
        case "inbox-dir":
            try runMailboxInboxDirCommand(subArgs: rest, client: client)
        case "surface-name":
            try runMailboxSurfaceNameCommand(subArgs: rest, client: client)
        case "new-id":
            print(MailboxULID.make())
        case "watch":
            throw CLIError(message: "watch not implemented in Stage 2; see c11 mailbox tail for the log-follow equivalent")
        default:
            throw CLIError(message: "unknown mailbox subcommand '\(sub)'. Use `c11 mailbox help` for usage.")
        }
    }

    private func mailboxUsage() -> String {
        """
        c11 mailbox — inter-agent messaging

          send       write an envelope to the per-workspace outbox
          recv       drain or peek the caller's inbox
          trace      pretty-print _dispatch.log lines for an envelope id
          tail       follow _dispatch.log
          outbox-dir print the caller's outbox directory (for raw-bash writers)
          inbox-dir  print the caller's inbox directory (for raw-bash readers)
          surface-name
                     print the caller's surface title (for `from` auto-fill)
          new-id     print a fresh Crockford base32 ULID (26 chars)

        Send flags:
          --to <surface>          recipient surface name
          --topic <topic>         dotted topic token
          --body <text>           inline body (≤ 4096 bytes UTF-8)
          --body-ref <path>       absolute path to external body (body must be empty)
          --reply-to <surface>    surface that should receive the reply
          --in-reply-to <ulid>    envelope id this is replying to
          --urgent                sender hint (handlers may ignore)
          --ttl-seconds <n>       advisory expiry
          --from <surface>        override caller's resolved title
          --id <ulid>             pin envelope id (testing / replay)
          --ts <rfc3339>          pin timestamp (testing / replay)
          --content-type <mime>   MIME hint for body or body_ref

        Recv flags:
          --drain                 default — list, print, unlink
          --peek                  list + print only
          --surface <name>        override caller's resolved surface
        """
    }

    // MARK: - Caller resolution

    /// Returns the caller's workspace UUID and surface name. Workspace UUID
    /// comes from the CMUX_WORKSPACE_ID (or C11_WORKSPACE_ID alias) env var
    /// that every surface shell inherits. Surface name is looked up via
    /// `surface.get_metadata`. Pass an override when scripting without a
    /// live c11 surface.
    private func resolveMailboxCaller(
        client: SocketClient,
        fromOverride: String?,
        surfaceOverride: String?
    ) throws -> (workspaceId: UUID, surfaceName: String) {
        let env = ProcessInfo.processInfo.environment
        let workspaceIdStr = env["CMUX_WORKSPACE_ID"] ?? env["C11_WORKSPACE_ID"]
        guard
            let workspaceIdStr,
            let workspaceId = UUID(uuidString: workspaceIdStr)
        else {
            throw CLIError(
                message: "CMUX_WORKSPACE_ID not set — run from inside a c11 surface or script with --from override and env"
            )
        }

        if let name = fromOverride ?? surfaceOverride, !name.isEmpty {
            return (workspaceId, name)
        }

        let surfaceIdStr = env["CMUX_SURFACE_ID"] ?? env["C11_SURFACE_ID"]
        guard let surfaceIdStr else {
            throw CLIError(message: "CMUX_SURFACE_ID not set — pass --from <surface> to override")
        }

        let payload = try client.sendV2(
            method: "surface.get_metadata",
            params: [
                "workspace_id": workspaceIdStr,
                "surface_id": surfaceIdStr
            ]
        )
        let metadata = (payload["metadata"] as? [String: Any]) ?? [:]
        guard let title = metadata["title"] as? String, !title.isEmpty else {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.surface-not-found",
                    defaultValue: "No surface named %@ in this workspace."
                ).replacingOccurrences(of: "%@", with: "(untitled)")
            )
        }
        return (workspaceId, title)
    }

    // MARK: - send

    private func runMailboxSendCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let to = optionValue(subArgs, name: "--to")
        let topic = optionValue(subArgs, name: "--topic")
        let body = optionValue(subArgs, name: "--body") ?? ""
        let bodyRef = optionValue(subArgs, name: "--body-ref")
        let replyTo = optionValue(subArgs, name: "--reply-to")
        let inReplyTo = optionValue(subArgs, name: "--in-reply-to")
        let urgent = hasFlag(subArgs, name: "--urgent")
        let ttlSeconds = optionValue(subArgs, name: "--ttl-seconds").flatMap(Int.init)
        let idOverride = optionValue(subArgs, name: "--id")
        let tsOverride = optionValue(subArgs, name: "--ts")
        let contentType = optionValue(subArgs, name: "--content-type")
        let fromOverride = optionValue(subArgs, name: "--from")

        if to == nil && topic == nil {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.no-recipient",
                    defaultValue: "A mailbox envelope needs --to or --topic."
                )
            )
        }

        // Stage 2 does not implement topic subscribe / fan-out. A topic-only
        // envelope would resolve to an empty recipient list and silently
        // vanish — reject at the CLI boundary so the operator sees the
        // failure instead of losing the message. Tracked for Stage 3;
        // pair with --to <surface> until then.
        if to == nil && topic != nil {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.topics-not-implemented",
                    defaultValue: "Topic-only envelopes are not delivered in Stage 2 (topic subscribe/fan-out ships in Stage 3). Pair --topic with --to <surface-name> to send now."
                )
            )
        }

        if Data(body.utf8).count > MailboxEnvelope.maxBodyBytes {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.error.body-too-large",
                    defaultValue: "Inline --body exceeds the 4 KB cap. Use --body-ref <path> for larger payloads."
                )
            )
        }

        let (workspaceId, surfaceName) = try resolveMailboxCaller(
            client: client,
            fromOverride: fromOverride,
            surfaceOverride: nil
        )

        let envelope = try MailboxEnvelope.build(
            from: fromOverride ?? surfaceName,
            to: to,
            topic: topic,
            body: body,
            id: idOverride,
            ts: tsOverride,
            replyTo: replyTo,
            inReplyTo: inReplyTo,
            urgent: urgent ? true : nil,
            ttlSeconds: ttlSeconds,
            bodyRef: bodyRef,
            contentType: contentType
        )

        let stateURL = try MailboxLayout.defaultStateURL()
        let outboxURL = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId)
        try FileManager.default.createDirectory(
            at: outboxURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let targetURL = outboxURL.appendingPathComponent(
            MailboxLayout.envelopeFilename(id: envelope.id)
        )
        let data = try envelope.encode()
        try MailboxIO.atomicWrite(data: data, to: targetURL)

        if jsonOutput {
            print(jsonString([
                "id": envelope.id,
                "outbox_path": targetURL.path,
                "workspace_id": workspaceId.uuidString,
                "from": envelope.from
            ]))
        } else {
            print(envelope.id)
        }
    }

    // MARK: - recv

    private func runMailboxRecvCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let peek = hasFlag(subArgs, name: "--peek")
        let drain = hasFlag(subArgs, name: "--drain") || !peek
        let surfaceOverride = optionValue(subArgs, name: "--surface")

        let (workspaceId, surfaceName) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: surfaceOverride
        )

        let stateURL = try MailboxLayout.defaultStateURL()
        let inboxURL = try MailboxLayout.inboxURL(
            state: stateURL,
            workspaceId: workspaceId,
            surfaceName: surfaceName
        )
        guard FileManager.default.fileExists(atPath: inboxURL.path) else {
            return
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == MailboxLayout.envelopeExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in entries {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            if drain {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - trace

    private func runMailboxTraceCommand(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let id = subArgs.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError(
                message: String(
                    localized: "mailbox.cli.trace.usage",
                    defaultValue: "c11 mailbox trace <envelope-id>"
                )
            )
        }
        let (workspaceId, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        let stateURL = try MailboxLayout.defaultStateURL()
        let logURL = MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: workspaceId)
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            return
        }
        let needle = "\"\(id)\""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains(needle) {
                print(String(line))
            }
        }
    }

    // MARK: - tail

    private func runMailboxTailCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let (workspaceId, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        let stateURL = try MailboxLayout.defaultStateURL()
        let logURL = MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: workspaceId)

        // Print existing contents, then poll for growth.
        var lastSize: UInt64 = 0
        func flushHandle(_ handle: FileHandle) {
            let data = (try? handle.readToEnd()) ?? nil ?? Data()
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                print(text, terminator: "")
                fflush(stdout)
            }
            lastSize = (try? handle.offset()) ?? lastSize
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forReadingFrom: logURL) {
            flushHandle(handle)
            try? handle.close()
        }
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            guard FileManager.default.fileExists(atPath: logURL.path) else { continue }
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { continue }
            try? handle.seek(toOffset: lastSize)
            flushHandle(handle)
            try? handle.close()
        }
    }

    // MARK: - Helpers for raw-bash senders/receivers

    private func runMailboxOutboxDirCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let (workspaceId, _) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        let stateURL = try MailboxLayout.defaultStateURL()
        let url = MailboxLayout.outboxURL(state: stateURL, workspaceId: workspaceId)
        print(url.path)
    }

    private func runMailboxInboxDirCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let surfaceOverride = optionValue(subArgs, name: "--surface")
        let (workspaceId, surfaceName) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: surfaceOverride
        )
        let stateURL = try MailboxLayout.defaultStateURL()
        let url = try MailboxLayout.inboxURL(
            state: stateURL,
            workspaceId: workspaceId,
            surfaceName: surfaceName
        )
        print(url.path)
    }

    private func runMailboxSurfaceNameCommand(
        subArgs: [String],
        client: SocketClient
    ) throws {
        let (_, surfaceName) = try resolveMailboxCaller(
            client: client,
            fromOverride: nil,
            surfaceOverride: nil
        )
        print(surfaceName)
    }
}
