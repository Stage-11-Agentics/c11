import Darwin
import Foundation
#if canImport(Security)
import Security
#endif

enum SocketControlMode: String, CaseIterable, Identifiable {
    case off
    case c11Only
    case automation
    case password
    /// Full open access (all local users/processes) with no ancestry or password gate.
    case allowAll

    var id: String { rawValue }

    static var uiCases: [SocketControlMode] { [.off, .c11Only, .automation, .password, .allowAll] }

    // Localization keys retain the legacy `socketControl.cmuxOnly.*` names so
    // translations across the six shipping locales survive the Swift rename;
    // chase the key rename in a separate hygiene pass.
    var displayName: String {
        switch self {
        case .off:
            return String(localized: "socketControl.off.name", defaultValue: "Off")
        case .c11Only:
            return String(localized: "socketControl.cmuxOnly.name", defaultValue: "c11 processes only")
        case .automation:
            return String(localized: "socketControl.automation.name", defaultValue: "Automation mode")
        case .password:
            return String(localized: "socketControl.password.name", defaultValue: "Password mode")
        case .allowAll:
            return String(localized: "socketControl.allowAll.name", defaultValue: "Full open access")
        }
    }

    var description: String {
        switch self {
        case .off:
            return String(localized: "socketControl.off.description", defaultValue: "Disable the local control socket.")
        case .c11Only:
            return String(localized: "socketControl.cmuxOnly.description", defaultValue: "Only processes started inside c11 terminals can send commands.")
        case .automation:
            return String(localized: "socketControl.automation.description", defaultValue: "Allow external local automation clients from this macOS user (no ancestry check).")
        case .password:
            return String(localized: "socketControl.password.description", defaultValue: "Require socket authentication with a password stored in a local file.")
        case .allowAll:
            return String(localized: "socketControl.allowAll.description", defaultValue: "Allow any local process and user to connect with no auth. Unsafe.")
        }
    }

    var socketFilePermissions: UInt16 {
        switch self {
        case .allowAll:
            return 0o666
        case .off, .c11Only, .automation, .password:
            return 0o600
        }
    }

    var requiresPasswordAuth: Bool {
        self == .password
    }
}

enum SocketControlPasswordStore {
    static let directoryName = C11Identity.passwordDirectoryName
    static let fileName = "socket-control-password"
    private static let keychainMigrationDefaultsKey = "socketControlPasswordMigrationVersion"
    private static let keychainMigrationVersion = 1
    private static let legacyKeychainService = "com.cmuxterm.app.socket-control"
    private static let legacyKeychainAccount = "local-socket-password"
    private struct LazyKeychainFallbackCache {
        var hasLoaded = false
        var password: String?
    }
    private static let lazyKeychainFallbackLock = NSLock()
    private static var lazyKeychainFallbackCache = LazyKeychainFallbackCache()

    static func configuredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        allowLazyKeychainFallback: Bool = false,
        loadKeychainPassword: () -> String? = { loadLegacyPasswordFromKeychain() }
    ) -> String? {
        if let envPassword = normalized(c11Env(SocketControlSettings.socketPasswordEnvKey, in: environment)) {
            return envPassword
        }
        let filePassword: String?
        do {
            filePassword = try loadPassword(fileURL: fileURL)
        } catch {
            filePassword = nil
        }
        if let filePassword {
            return filePassword
        }
        guard allowLazyKeychainFallback else {
            return nil
        }
        return cachedLazyKeychainFallbackPassword(loadKeychainPassword: loadKeychainPassword)
    }

    static func hasConfiguredPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        allowLazyKeychainFallback: Bool = false,
        loadKeychainPassword: () -> String? = { loadLegacyPasswordFromKeychain() }
    ) -> Bool {
        guard let configured = configuredPassword(
            environment: environment,
            fileURL: fileURL,
            allowLazyKeychainFallback: allowLazyKeychainFallback,
            loadKeychainPassword: loadKeychainPassword
        ) else { return false }
        return !configured.isEmpty
    }

    static func verify(
        password candidate: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        allowLazyKeychainFallback: Bool = false,
        loadKeychainPassword: () -> String? = { loadLegacyPasswordFromKeychain() }
    ) -> Bool {
        guard let expected = configuredPassword(
            environment: environment,
            fileURL: fileURL,
            allowLazyKeychainFallback: allowLazyKeychainFallback,
            loadKeychainPassword: loadKeychainPassword
        ), !expected.isEmpty else {
            return false
        }
        return expected == candidate
    }

    static func migrateLegacyKeychainPasswordIfNeeded(
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        loadLegacyPassword: () -> String? = { loadLegacyPasswordFromKeychain() },
        deleteLegacyPassword: () -> Bool = { deleteLegacyPasswordFromKeychain() }
    ) {
        // c11 does not read or delete the cmux/c11 socket-control keychain item.
        _ = defaults
        _ = fileURL
        _ = loadLegacyPassword
        _ = deleteLegacyPassword
    }

    static func loadPassword(fileURL: URL? = nil) throws -> String? {
        guard let fileURL = fileURL ?? defaultPasswordFileURL() else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        guard let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalized(password)
    }

    static func savePassword(_ password: String, fileURL: URL? = nil) throws {
        let normalized = password.trimmingCharacters(in: .newlines)
        if normalized.isEmpty {
            try clearPassword(fileURL: fileURL)
            return
        }

        guard let fileURL = fileURL ?? defaultPasswordFileURL() else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "socketControl.error.passwordFilePath", defaultValue: "Unable to resolve socket password file path.")]
            )
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = Data(normalized.utf8)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func clearPassword(fileURL: URL? = nil) throws {
        guard let fileURL = fileURL ?? defaultPasswordFileURL() else {
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func resetLazyKeychainFallbackCacheForTests() {
        lazyKeychainFallbackLock.lock()
        lazyKeychainFallbackCache = LazyKeychainFallbackCache()
        lazyKeychainFallbackLock.unlock()
    }

    static func defaultPasswordFileURL(
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        StateDirectoryMigration.ensureMigrated(fileManager: fileManager)
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        return resolvedAppSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func loadLegacyPasswordFromKeychain() -> String? {
        // c11 does not read the cmux/c11 socket-control keychain item.
        _ = legacyKeychainService
        _ = legacyKeychainAccount
        return nil
    }

    private static func deleteLegacyPasswordFromKeychain() -> Bool {
        // c11 does not delete another product's keychain item.
        _ = legacyKeychainService
        _ = legacyKeychainAccount
        return false
    }

    private static func cachedLazyKeychainFallbackPassword(
        loadKeychainPassword: () -> String?
    ) -> String? {
        lazyKeychainFallbackLock.lock()
        defer { lazyKeychainFallbackLock.unlock() }
        if lazyKeychainFallbackCache.hasLoaded {
            return lazyKeychainFallbackCache.password
        }
        lazyKeychainFallbackCache.hasLoaded = true
        lazyKeychainFallbackCache.password = normalized(loadKeychainPassword())
        return lazyKeychainFallbackCache.password
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension SocketControlPasswordStore {
    /// Where password mode looks for the expected password: the environment,
    /// then the password file, then the legacy Keychain item, read lazily once
    /// per process. `.shipped` reads this machine's real values. Tests pass a
    /// temporary file and a stub Keychain loader (C11-347).
    struct Source: Sendable {
        var environment: @Sendable () -> [String: String]
        /// nil reads the default file under Application Support.
        var fileURL: URL?
        /// Called at most once per process across every Source; tests reset it
        /// with `resetLazyKeychainFallbackCacheForTests()`.
        var loadKeychainPassword: @Sendable () -> String?

        static let shipped = Source(
            environment: { ProcessInfo.processInfo.environment },
            fileURL: nil,
            loadKeychainPassword: { SocketControlPasswordStore.loadLegacyPasswordFromKeychain() }
        )

        var hasConfiguredPassword: Bool {
            SocketControlPasswordStore.hasConfiguredPassword(
                environment: environment(),
                fileURL: fileURL,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loadKeychainPassword
            )
        }

        func verify(_ candidate: String) -> Bool {
            SocketControlPasswordStore.verify(
                password: candidate,
                environment: environment(),
                fileURL: fileURL,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loadKeychainPassword
            )
        }
    }
}

struct SocketControlSettings {
    static let appStorageKey = "socketControlMode"
    static let legacyEnabledKey = "socketControlEnabled"
    static let allowSocketPathOverrideKey = "C11_ALLOW_SOCKET_OVERRIDE"
    static let socketPasswordEnvKey = "C11_SOCKET_PASSWORD"
    static let launchTagEnvKey = "C11_TAG"
    static let baseDebugBundleIdentifier = C11Identity.untaggedDebugBundleIdentifier
    private static let socketDirectoryName = C11Identity.socketDirectoryName
    private static let stableSocketFileName = C11Identity.stableSocketFileName
    private static let lastSocketPathFileName = "last-socket-path"
    static let legacyStableDefaultSocketPath = C11Identity.tmpStableSocketPath
    static let legacyLastSocketPathFile = C11Identity.lastSocketPathFile

    static var stableDefaultSocketPath: String {
        stableSocketFileURL()?.path ?? legacyStableDefaultSocketPath
    }

    static var lastSocketPathFile: String {
        lastSocketPathFileURL()?.path ?? legacyLastSocketPathFile
    }

    enum StableDefaultSocketPathEntry: Equatable {
        case missing
        case socket(ownerUserID: uid_t)
        case other(ownerUserID: uid_t)
        case inaccessible(errnoCode: Int32)
    }

    private static func normalizeMode(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func parseMode(_ raw: String) -> SocketControlMode? {
        switch normalizeMode(raw) {
        case "off":
            return .off
        // "cmuxonly" remains here so persisted UserDefaults values from
        // pre-rename builds still migrate forward; "c11only" is the new
        // canonical form written by `migrateMode` (see c11App.swift).
        case "c11only", "cmuxonly":
            return .c11Only
        case "automation":
            return .automation
        case "password":
            return .password
        case "allowall", "openaccess", "fullopenaccess":
            return .allowAll
        // Legacy values from the old socket mode model.
        case "notifications":
            return .automation
        case "full":
            return .allowAll
        default:
            return nil
        }
    }

    /// Map persisted values to the current enum values.
    static func migrateMode(_ raw: String) -> SocketControlMode {
        parseMode(raw) ?? defaultMode
    }

    static var defaultMode: SocketControlMode {
        return .c11Only
    }

    private static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func launchTag(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = c11Env(launchTagEnvKey, in: environment) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The tag hc names its session by. Every build but release carries one in
    /// its bundle identifier (`C11Identity.sessionTag`), and is often launched
    /// without `C11_TAG`. A literal `C11_TAG` still wins.
    static func hcLaunchTag(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String? {
        if let tag = launchTag(environment: environment) { return tag }
        return C11Identity.sessionTag(bundleIdentifier: bundleIdentifier)
    }

    /// Whether the running app is a **local development build**: a Debug build,
    /// or a tagged `reload.sh --tag` / automation build (`C11_TAG` set). Never
    /// true in a shipped untagged Release. Single source of truth for
    /// suppressing launch-time auto-dialogs (the Agent Skills onboarding sheet
    /// and the resume picker) so the person rebuilding c11 isn't blocked by a
    /// modal on every relaunch. `isDebugBuild` is injectable so the env branch
    /// stays testable under the DEBUG-compiled logic-test target.
    static func isLocalDevBuild(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> Bool {
        if isDebugBuild { return true }
        return launchTag(environment: environment) != nil
    }

    static func shouldBlockUntaggedDebugLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> Bool {
        guard isDebugBuild else { return false }
        if isRunningUnderXCTest(environment: environment) {
            return false
        }
        // XCUITest launches the app as a separate process without XCTest env vars,
        // so isRunningUnderXCTest() misses it. Check for any CMUX_UI_TEST_ env var.
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return false
        }

        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return false
        }

        if bundleIdentifier.hasPrefix("\(baseDebugBundleIdentifier).") {
            return false
        }

        guard bundleIdentifier == baseDebugBundleIdentifier else {
            return false
        }

        return launchTag(environment: environment) == nil
    }

    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        let indicators = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "XCInjectBundle",
            "XCInjectBundleInto",
        ]
        if indicators.contains(where: { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild,
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry,
        processIdentifier: pid_t = getpid()
    ) -> String {
        var fallback = defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild,
            currentUserID: currentUserID,
            probeStableDefaultPathEntry: probeStableDefaultPathEntry
        )

        // C11-99 Area B: when launched by xcodebuild test, the XCTest host runs as the
        // untagged c11 DEV.app (bundle id com.stage11.c11.debug) and would otherwise
        // bind /tmp/c11-debug.sock — the same path the operator's running c11 DEV.app
        // uses. On teardown the test host unlinks the socket, killing the operator's
        // c11 socket. Detect XCTest via XCTestConfigurationFilePath and isolate per-PID.
        if environment["XCTestConfigurationFilePath"] != nil,
           fallback == C11Identity.debugSocketPath {
            fallback = C11Identity.xctestSocketPath(processIdentifier: processIdentifier)
        }

        if let taggedDebugPath = taggedDebugSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment
        ) {
            if isTruthy(c11Env(allowSocketPathOverrideKey, in: environment)),
               let override = c11Env("C11_SOCKET_PATH", in: environment),
               !override.isEmpty,
               C11Identity.isOwnSocketPath(override) {
                return override
            }
            return taggedDebugPath
        }

        guard let override = c11Env("C11_SOCKET_PATH", in: environment), !override.isEmpty else {
            return fallback
        }

        if shouldHonorSocketPathOverride(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild,
            overridePath: override,
            ownDefaultPath: fallback
        ) {
            return override
        }

        return fallback
    }

    static func defaultSocketPath(
        bundleIdentifier: String?,
        isDebugBuild: Bool,
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry
    ) -> String {
        if let taggedDebugPath = taggedDebugSocketPath(bundleIdentifier: bundleIdentifier, environment: [:]) {
            return taggedDebugPath
        }
        if bundleIdentifier == C11Identity.nightlyBundleIdentifier {
            return C11Identity.nightlySocketPath
        }
        if isDebugLikeBundleIdentifier(bundleIdentifier) || isDebugBuild {
            return C11Identity.debugSocketPath
        }
        if isStagingBundleIdentifier(bundleIdentifier) {
            return C11Identity.stagingSocketPath
        }
        // C11-155 defense-in-depth: only the canonical prod build owns the shared
        // `~/Library/Application Support/c11/c11.sock`. Any other bundle that still
        // falls through to the stable default (e.g. com.stage11.c11.release-probe)
        // gets a bundle-scoped socket so it can never collide with prod's path.
        if let bundleIdentifier,
           !bundleIdentifier.isEmpty,
           bundleIdentifier != prodBundleIdentifier {
            return bundleScopedStableSocketPath(
                bundleIdentifier: bundleIdentifier,
                currentUserID: currentUserID
            )
        }
        return resolvedStableDefaultSocketPath(
            currentUserID: currentUserID,
            probeStableDefaultPathEntry: probeStableDefaultPathEntry
        )
    }

    static let prodBundleIdentifier = C11Identity.releaseBundleIdentifier

    /// A stable socket path scoped to a specific bundle id, living alongside the
    /// prod socket in the shared `c11/` state dir but with a bundle-derived
    /// filename so distinct non-prod channels never share a path.
    static func bundleScopedStableSocketPath(
        bundleIdentifier: String,
        currentUserID: uid_t = getuid()
    ) -> String {
        let slug = bundleIdentifier
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = slug.isEmpty ? "c11-\(currentUserID).sock" : "\(slug).sock"
        return stableSocketDirectoryURL()?
            .appendingPathComponent(fileName, isDirectory: false)
            .path ?? "/tmp/\(fileName)"
    }

    static func userScopedStableSocketPath(currentUserID: uid_t = getuid()) -> String {
        stableSocketDirectoryURL()?
            .appendingPathComponent("c11-\(currentUserID).sock", isDirectory: false)
            .path ?? "/tmp/c11-\(currentUserID).sock"
    }

    static func resolvedStableDefaultSocketPath(
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry
    ) -> String {
        switch probeStableDefaultPathEntry(stableDefaultSocketPath) {
        case .missing:
            return stableDefaultSocketPath
        case .socket(let ownerUserID) where ownerUserID == currentUserID:
            return stableDefaultSocketPath
        case .socket, .other, .inaccessible:
            return userScopedStableSocketPath(currentUserID: currentUserID)
        }
    }

    /// Records the bound socket in the Application Support marker, the
    /// per-user one, and the shared `/tmp/c11-last-socket-path` older readers
    /// use. Each is written 0600 through `C11UserRuntime.writeBreadcrumb`: a
    /// `/tmp` entry another account created is left alone rather than
    /// written through (C11H-364, hardening note 10).
    static func recordLastSocketPath(_ path: String, filePath: String = lastSocketPathFile) {
        var targets = [filePath]
        if (try? C11UserRuntime.ensureDirectory()) != nil {
            targets.append(C11Identity.userLastSocketPathFile)
        }
        targets.append(C11Identity.lastSocketPathFile)
        var written: Set<String> = []
        for target in targets where written.insert(target).inserted {
            writeSocketPathMarker(path, to: target)
        }
    }

    /// The shared `/tmp` name a build before C11H-364 bound for the same
    /// channel, when `boundPath` is this build's own default socket (not an
    /// override or a pid sibling). c11 keeps a symlink there so shells stamped
    /// with that name before the update still reach it.
    static func legacyAliasPath(
        forBoundPath boundPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> String? {
        guard C11UserRuntime.isInsideDirectory(boundPath) else { return nil }
        let stem: String
        if let tagged = taggedDebugSocketPath(bundleIdentifier: bundleIdentifier, environment: environment),
           tagged == boundPath {
            stem = taggedDebugSocketStem(bundleIdentifier: bundleIdentifier, environment: environment) ?? ""
        } else if let slug = taggedStagingSocketSlug(bundleIdentifier: bundleIdentifier),
                  boundPath == C11Identity.userSocketPath(stem: "c11-" + slug) {
            // `reloads.sh --tag` stamps a tagged staging build with this name;
            // before C11H-364 it was `/tmp/c11-<slug>.sock`.
            stem = "c11-" + slug
        } else if boundPath == C11Identity.nightlySocketPath {
            stem = "c11-nightly"
        } else if boundPath == C11Identity.debugSocketPath {
            stem = "c11-debug"
        } else if boundPath == C11Identity.stagingSocketPath {
            stem = "c11-staging"
        } else {
            return nil
        }
        return stem.isEmpty ? nil : C11UserRuntime.legacySocketPath(stem: stem)
    }

    /// The slug `reloads.sh --tag` names a tagged staging build's socket
    /// from, read back from its bundle id (`com.stage11.c11.staging.<tag>`):
    /// the rest, dots to dashes, trimmed of dashes.
    static func taggedStagingSocketSlug(bundleIdentifier: String?) -> String? {
        let prefix = C11Identity.stagingBundleIdentifier + "."
        guard let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              bundleId.hasPrefix(prefix) else { return nil }
        let slug = String(bundleId.dropFirst(prefix.count))
            .replacingOccurrences(of: ".", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    static func shouldHonorSocketPathOverride(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool,
        overridePath: String? = nil,
        ownDefaultPath: String? = nil
    ) -> Bool {
        if let overridePath, !C11Identity.isOwnSocketPath(overridePath) {
            return false
        }
        if isTruthy(c11Env(allowSocketPathOverrideKey, in: environment)) {
            return overridePath.map(C11Identity.isOwnSocketPath) ?? true
        }
        let honorsByChannel = isDebugLikeBundleIdentifier(bundleIdentifier)
            || isStagingBundleIdentifier(bundleIdentifier)
            || isDebugBuild
        guard honorsByChannel else { return false }
        // C11-155: c11 injects `CMUX_SOCKET_PATH=<its own socket>` into every
        // terminal it spawns, so a debug/staging build launched from a *peer's*
        // pane inherits the peer's socket path. Binding it would unlink the peer's
        // live socket (the bind-time stomp). Refuse to adopt another channel's
        // shared default that we merely inherited; a tag-specific override path
        // (e.g. /tmp/c11-staging-my-tag.sock) is not a shared default, so the
        // tagged-build workflow is unaffected. Same-channel collisions (an
        // override equal to our own default) are still honored here and caught at
        // bind time by the liveness probe.
        if let overridePath,
           overridePath != ownDefaultPath,
           isForeignSharedDefaultSocketPath(overridePath) {
            return false
        }
        return true
    }

    /// Well-known *shared* default socket paths each owned by a long-lived
    /// channel. These are the paths most likely to be inherited via
    /// `CMUX_SOCKET_PATH` from a peer c11; a different build must never bind one
    /// (it would unlink the peer's live socket). Tag-specific paths are
    /// deliberately absent — those are launch-script intent, not inheritance.
    static func isForeignSharedDefaultSocketPath(_ path: String) -> Bool {
        !C11Identity.isOwnSocketPath(path)
    }

    static func isDebugLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == C11Identity.untaggedDebugBundleIdentifier
            || bundleIdentifier.hasPrefix(C11Identity.untaggedDebugBundleIdentifier + ".")
    }

    static func taggedDebugSocketPath(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> String? {
        taggedDebugSocketSlug(bundleIdentifier: bundleIdentifier, environment: environment)
            .map { C11Identity.taggedDebugSocketPath(slug: $0) }
    }

    /// `c11-debug-<slug>`, the stem a tagged Debug build's socket is named from.
    static func taggedDebugSocketStem(bundleIdentifier: String?, environment: [String: String]) -> String? {
        taggedDebugSocketSlug(bundleIdentifier: bundleIdentifier, environment: environment)
            .map { "c11-debug-\($0)" }
    }

    private static func taggedDebugSocketSlug(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> String? {
        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleId.hasPrefix("\(baseDebugBundleIdentifier).") {
            let suffix = String(bundleId.dropFirst(baseDebugBundleIdentifier.count + 1))
            let slug = suffix
                .replacingOccurrences(of: ".", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if !slug.isEmpty {
                return slug
            }
        }

        let tag = launchTag(environment: environment)?
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        guard bundleId == baseDebugBundleIdentifier,
              let tag,
              !tag.isEmpty else {
            return nil
        }
        return tag
    }

    static func isStagingBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == C11Identity.stagingBundleIdentifier
            || bundleIdentifier.hasPrefix(C11Identity.stagingBundleIdentifier + ".")
    }

    static func stableSocketDirectoryURL(fileManager: FileManager = .default) -> URL? {
        StateDirectoryMigration.ensureMigrated(fileManager: fileManager)
        guard let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory.appendingPathComponent(socketDirectoryName, isDirectory: true)
    }

    static func stableSocketFileURL(fileManager: FileManager = .default) -> URL? {
        stableSocketDirectoryURL(fileManager: fileManager)?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
    }

    static func lastSocketPathFileURL(fileManager: FileManager = .default) -> URL? {
        stableSocketDirectoryURL(fileManager: fileManager)?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
    }

    private static func writeSocketPathMarker(_ socketPath: String, to filePath: String) {
        let fileURL = URL(fileURLWithPath: filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        let parent = parentURL.path
        if parent != "/tmp" && parent != "/private/tmp" {
            try? FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        C11UserRuntime.writeBreadcrumb(socketPath, to: filePath)
    }

    private static func inspectStableDefaultSocketPathEntry(_ path: String) -> StableDefaultSocketPathEntry {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return .missing
            }
            return .inaccessible(errnoCode: errnoCode)
        }

        let fileType = st.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFSOCK) {
            return .socket(ownerUserID: st.st_uid)
        }
        return .other(ownerUserID: st.st_uid)
    }

    static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func envOverrideEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = c11Env("C11_SOCKET_ENABLE", in: environment), !raw.isEmpty else {
            return nil
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func envOverrideMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode? {
        guard let raw = c11Env("C11_SOCKET_MODE", in: environment), !raw.isEmpty else {
            return nil
        }
        return parseMode(raw)
    }

    static func effectiveMode(
        userMode: SocketControlMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode {
        if let overrideEnabled = envOverrideEnabled(environment: environment) {
            if !overrideEnabled {
                return .off
            }
            if let overrideMode = envOverrideMode(environment: environment) {
                return overrideMode
            }
            return userMode == .off ? .c11Only : userMode
        }

        if let overrideMode = envOverrideMode(environment: environment) {
            return overrideMode
        }

        return userMode
    }
}
