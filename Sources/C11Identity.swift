import Foundation

/// c11's on-disk identity. Compiled into the app and the `c11-cli` target.
/// Call sites take paths, bundle ids, sockets, and cross-process names from
/// here. c11 2.0 carries c11's identity (docs/c11-2.0-identity.md); the names
/// the retired line used live only in `Legacy`, read by first-launch migration.
enum C11Identity {
    static let releaseBundleIdentifier = "com.stage11.c11"
    static let untaggedDebugBundleIdentifier = "com.stage11.c11.debug"
    static let stagingBundleIdentifier = "com.stage11.c11.staging"
    static let nightlyBundleIdentifier = "com.stage11.c11.nightly"

    static let stateDirectoryName = "c11"
    static let logsDirectoryName = "c11"
    static let socketDirectoryName = "c11"
    static let stableSocketFileName = "c11.sock"
    static let passwordDirectoryName = "c11"

    static let lastSocketPathFile = "/tmp/c11-last-socket-path"
    static let keychainService = "com.stage11.c11.socket-control"

    static let themesReloadNotificationName = "com.stage11.c11.themes.reload-config"
    static let userNotificationCategoryIdentifier = "com.stage11.c11.userNotification"
    static let userNotificationShowActionIdentifier = "com.stage11.c11.userNotification.show"

    static let portBaseDefaultsKey = "cmuxPortBase"
    static let defaultPortBase = 29100

    static let productionEventLogPrefix = "events-com.stage11.c11-"
    static let ownedCLISymlinkSuffix = "/c11.app/Contents/Resources/bin/c11"

    /// The tag hc names c11's session by: a literal `C11_TAG` (or legacy
    /// `CMUX_TAG`) wins; otherwise the build's own (`sessionTag`). Only the
    /// release build has none (session `c11`). Shared by the app and
    /// `c11-core` (C11H-37) so both always name the same core.
    static func hcLaunchTag(environment: [String: String], bundleIdentifier: String?) -> String? {
        if let raw = environment["C11_TAG"] ?? environment["CMUX_TAG"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return sessionTag(bundleIdentifier: bundleIdentifier)
    }

    /// The session tag a bundle identifier gives (C11H-216). Every
    /// `com.stage11.c11.<rest>` build gets its own; only release itself, and a
    /// missing or foreign identifier, has none (session `c11`).
    /// - `debug`, `staging`, `nightly` for those builds;
    /// - `staging-<slug>` and `nightly-<slug>` for a tagged staging or nightly build;
    /// - a tagged Debug build's slug (`debug.<slug>`, dots to dashes), unless it
    ///   would name one of those, when it is `tag-<slug>`;
    /// - `app-<rest>` for any other identifier under c11's.
    /// Each build keeps its own cores and terminals, so none adopts, ends or
    /// serves another's.
    static func sessionTag(bundleIdentifier: String?) -> String? {
        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard bundleId.hasPrefix("\(releaseBundleIdentifier).") else { return nil }
        let rest = String(bundleId.dropFirst(releaseBundleIdentifier.count + 1))
            .replacingOccurrences(of: ".", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let channels = ["debug", "staging", "nightly"]
        if rest.isEmpty { return "app" }
        if channels.contains(rest) { return rest }
        if rest.hasPrefix("debug-") {
            let slug = String(rest.dropFirst("debug-".count))
            let reserved = channels.contains(slug) || slug.hasPrefix("staging-") || slug.hasPrefix("nightly-")
                || slug.hasPrefix("app-") || slug == "app" || slug.hasPrefix("tag-")
            return reserved ? "tag-\(slug)" : slug
        }
        if rest.hasPrefix("staging-") || rest.hasPrefix("nightly-") { return rest }
        return "app-\(rest)"
    }

    // Non-release sockets live in c11's per-user folder
    // (`$(getconf DARWIN_USER_TEMP_DIR)c11`, 0700), never in shared /tmp,
    // where another local account could take a fixed name first (C11H-364).
    // Release keeps `~/Library/Application Support/c11/c11.sock`.
    static var debugSocketPath: String { userSocketPath(stem: "c11-debug") }
    static var stagingSocketPath: String { userSocketPath(stem: "c11-staging") }
    static var nightlySocketPath: String { userSocketPath(stem: "c11-nightly") }
    static let tmpStableSocketPath = "/tmp/c11.sock"
    static var portalLogPath: String { C11UserRuntime.logPath("c11-portal.log") }
    static let snapshotDirectoryName = ".c11-snapshots"

    /// `<per-user folder>/<stem>.sock`, cut to fit `sun_path` (C11UserRuntime).
    static func userSocketPath(stem: String) -> String {
        C11UserRuntime.socketPath(stem: stem, directory: C11UserRuntime.directoryPath())
    }

    /// The per-user breadcrumb naming the socket c11 last bound.
    static var userLastSocketPathFile: String {
        C11UserRuntime.directoryPath() + "/" + C11UserRuntime.lastSocketPathFileName
    }

    /// Claude hook session file under the home directory. The
    /// `CMUX_CLAUDE_HOOK_STATE_PATH` override still wins when it is set.
    static func claudeHookStateFile(home: URL) -> URL {
        home.appendingPathComponent(".c11", isDirectory: true)
            .appendingPathComponent("claude-hook-sessions.json")
    }

    static func snapshotDirectory(home: URL) -> URL {
        home.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
    }

    static func userAgentsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(stateDirectoryName, isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    static func userBlueprintsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(stateDirectoryName, isDirectory: true)
            .appendingPathComponent("blueprints", isDirectory: true)
    }

    /// A QA launch standing in for the release app in a c11h migration guest
    /// proof: `C11_MIGRATION_QA=1` with a `C11_QA_LAUNCH` mode. The app migrates
    /// into the release app's folders (`C11MigrationPlanner.allowed`) and keeps
    /// its mail there; a CLI given the same two variables follows it
    /// (`MailboxStateRoot`, C11H-439).
    static func isMigrationQALaunch(environment: [String: String]) -> Bool {
        environment["C11_MIGRATION_QA"] == "1" && !(environment["C11_QA_LAUNCH"] ?? "").isEmpty
    }

    /// `com.stage11.c11` or `com.stage11.c11.*`. The retired line's ids
    /// (`Legacy.releaseBundleIdentifier`) are outside the family.
    static func isFamilyBundleIdentifier(_ identifier: String) -> Bool {
        identifier == releaseBundleIdentifier
            || identifier.hasPrefix(releaseBundleIdentifier + ".")
    }

    /// Browser history directory under Application Support. Tagged debug and
    /// staging builds share one c11 namespace. Any other id, including the retired
    /// line's and cmux's, lands on the c11 release id.
    static func browserHistoryNamespace(for bundleIdentifier: String) -> String {
        let id = isFamilyBundleIdentifier(bundleIdentifier) ? bundleIdentifier : releaseBundleIdentifier
        if id.hasPrefix(untaggedDebugBundleIdentifier + ".") {
            return untaggedDebugBundleIdentifier
        }
        if id.hasPrefix(stagingBundleIdentifier + ".") {
            return stagingBundleIdentifier
        }
        return id
    }

    static func isOwnSocketFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".sock") else { return false }
        if name == stableSocketFileName { return true }
        return name.hasPrefix("c11-") || name.hasPrefix("c11.")
    }

    /// A path c11 may bind or discover. Application Support must be followed
    /// immediately by `c11`. A socket in c11's per-user folder or in `/tmp`
    /// must be named `c11.sock` or `c11-…` / `c11.…`; `/tmp` names remain for
    /// explicit overrides (sandbox guests) and the legacy aliases. The retired
    /// line's names (`Legacy`) are not c11's.
    static func isOwnSocketPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        if let support = parts.firstIndex(of: "Application Support"),
           support + 1 < parts.count,
           parts[support + 1] == stateDirectoryName {
            return true
        }
        let parent = url.deletingLastPathComponent().path
        guard parent == "/tmp" || parent == "/private/tmp"
                || C11UserRuntime.isInsideDirectory(path) else { return false }
        return isOwnSocketFileName(url.lastPathComponent)
    }

    /// What a socket path in the environment names (C11H-282).
    enum SocketOverrideKind: Equatable {
        /// c11's own socket (`isOwnSocketPath`).
        case own
        /// Another product's socket: the retired c11h line's or cmux's. Its
        /// terminals export it, so it is inherited, not chosen; c11 never
        /// connects to it. Terminals c11 adopted from c11h carry this.
        case otherProduct
        /// Any other path. c11 does not bind it, so the CLI refuses it by name
        /// rather than reach a different instance without a word.
        case foreign
    }

    static func socketOverrideKind(_ path: String) -> SocketOverrideKind {
        if isOwnSocketPath(path) { return .own }
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        if let support = parts.firstIndex(of: "Application Support"),
           support + 1 < parts.count,
           otherProductNames.contains(parts[support + 1]) {
            return .otherProduct
        }
        let parent = url.deletingLastPathComponent().path
        if parent == "/tmp" || parent == "/private/tmp" {
            let name = url.lastPathComponent
            for product in otherProductNames where name.hasSuffix(".sock") {
                if name == product + ".sock" || name.hasPrefix(product + "-") || name.hasPrefix(product + ".") {
                    return .otherProduct
                }
            }
        }
        return .foreign
    }

    /// State directories and `/tmp` socket prefixes of the products whose
    /// terminals export the same socket variables: the c11h line and cmux.
    private static let otherProductNames = [Legacy.stateDirectoryName, "cmux"]

    static func xctestSocketPath(processIdentifier: Int32) -> String {
        userSocketPath(stem: "c11-test-\(processIdentifier)")
    }

    static func taggedDebugSocketPath(slug: String) -> String {
        userSocketPath(stem: "c11-debug-\(slug)")
    }

    /// The `/tmp` name a pre-C11H-364 tagged Debug build bound for `slug`.
    static func legacyTaggedDebugSocketPath(slug: String) -> String {
        C11UserRuntime.legacySocketPath(stem: "c11-debug-\(slug)")
    }

    /// Reads `cmuxPortBase` from the defaults object the caller supplies.
    /// Missing or non-positive values use 29100. This does not open another
    /// suite.
    static func portBase(defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: portBaseDefaultsKey) != nil else {
            return defaultPortBase
        }
        let value = defaults.integer(forKey: portBaseDefaultsKey)
        return value > 0 ? value : defaultPortBase
    }

    /// Sparkle starts whenever the bundle carries a feed URL, as c11 1.x did.
    static func shouldStartSparkleUpdater(bundleIdentifier: String, feedURL: String?) -> Bool {
        let feed = feedURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !feed.isEmpty
    }

    /// Claim only a dangling symlink whose target is this app's bundled CLI.
    /// A link into the retired line's app (`Legacy.ownedCLISymlinkSuffix`) is not claimable.
    static func claimsCLISymlink(rawTargetPath: String) -> Bool {
        return rawTargetPath.hasSuffix(ownedCLISymlinkSuffix)
    }

    /// Yes only for a c11-family bundle id whose executable sits inside
    /// `c11.app`, `c11 DEV*.app`, or `c11 STAGING*.app`.
    static func ownsProcess(bundleIdentifier: String, executablePath: String) -> Bool {
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFamilyBundleIdentifier(bundle) else { return false }
        if executablePath.contains("/cmux.app/") { return false }
        if executablePath.hasSuffix("/usr/local/bin/c11") { return false }
        return executableIsInsideC11App(executablePath)
    }

    static func executableIsInsideC11App(_ path: String) -> Bool {
        guard path.contains("/Contents/MacOS/") else { return false }
        if path.contains("/c11.app/Contents/MacOS/") { return true }
        if appContainer(path, product: "c11 DEV") { return true }
        if appContainer(path, product: "c11 STAGING") { return true }
        return false
    }

    private static func appContainer(_ path: String, product: String) -> Bool {
        let marker = "/" + product
        guard let range = path.range(of: marker) else { return false }
        let rest = path[range.upperBound...]
        guard let app = rest.range(of: ".app/Contents/MacOS/") else { return false }
        return !rest[..<app.lowerBound].contains("/")
    }

    struct ImplicitSocketDiscovery: Equatable {
        var environment: [String: String] = [:]
        var defaultPath: String
        /// Directory path to the entry names listed there. Only `/tmp` and a
        /// `c11` Application Support directory contribute candidates, and
        /// only names that are c11 socket files.
        var socketListings: [String: [String]] = [:]
        var breadcrumbFiles: [String: String] = [:]
        var connectable: Set<String> = []
        var existingSocketFiles: Set<String> = []
    }

    /// Implicit CLI discovery. Foreign env values, c11 breadcrumbs, and
    /// socket names that merely start with `c11` or `cmux` are not candidates.
    /// With nothing of c11's connectable, the result is `defaultPath`.
    static func resolveImplicitSocket(_ input: ImplicitSocketDiscovery) -> String {
        let candidates = implicitSocketCandidates(input)
        for path in candidates where input.connectable.contains(path) {
            return path
        }
        for path in candidates where input.existingSocketFiles.contains(path) {
            return path
        }
        return input.defaultPath
    }

    static func implicitSocketCandidates(_ input: ImplicitSocketDiscovery) -> [String] {
        var candidates: [String] = []
        for key in ["C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
            guard let raw = input.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  isOwnSocketPath(raw) else { continue }
            candidates.append(raw)
        }
        if let tag = firstTag(in: input.environment) {
            let slug = sanitizeTagSlug(tag)
            candidates.append(taggedDebugSocketPath(slug: slug))
            candidates.append(userSocketPath(stem: "c11-\(slug)"))
            candidates.append(legacyTaggedDebugSocketPath(slug: slug))
            candidates.append("/tmp/c11-\(slug).sock")
        }
        if isOwnSocketPath(input.defaultPath) {
            candidates.append(input.defaultPath)
        }
        for (directory, names) in input.socketListings.sorted(by: { $0.key < $1.key }) {
            guard listingDirectoryIsOwn(directory) else { continue }
            let base = URL(fileURLWithPath: directory)
            for name in names where isOwnSocketFileName(name) {
                candidates.append(base.appendingPathComponent(name).path)
            }
        }
        for (file, contents) in input.breadcrumbFiles.sorted(by: { $0.key < $1.key }) {
            guard isC11BreadcrumbFile(file) else { continue }
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, isOwnSocketPath(value) else { continue }
            candidates.append(value)
        }
        return dedupe(candidates)
    }

    static func listingDirectoryIsOwn(_ directory: String) -> Bool {
        let url = URL(fileURLWithPath: directory)
        let path = url.path
        if path == "/tmp" || path == "/private/tmp" { return true }
        if path == C11UserRuntime.directoryPath() || path == "/private" + C11UserRuntime.directoryPath() {
            return true
        }
        let parts = url.pathComponents
        guard let support = parts.firstIndex(of: "Application Support"),
              support + 1 < parts.count else { return false }
        return parts[support + 1] == stateDirectoryName
    }

    static func isC11BreadcrumbFile(_ path: String) -> Bool {
        if path == lastSocketPathFile || path == userLastSocketPathFile { return true }
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        guard let support = parts.firstIndex(of: "Application Support"),
              support + 1 < parts.count,
              parts[support + 1] == stateDirectoryName else { return false }
        return url.lastPathComponent == "last-socket-path"
    }

    static func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : slug
    }

    private static func firstTag(in environment: [String: String]) -> String? {
        for key in ["C11_TAG", "CMUX_TAG"] {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            return raw
        }
        return nil
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }

    // c11-2.0:begin-keep
    /// The c11h line's names (c11h 1.x). Read only by first-launch migration
    /// (C11H-266) and by the hidden aliases the identity map lists; no c11 2.0
    /// build writes them. Every line carries `c11-2.0:legacy` so the rename
    /// codemod leaves it alone.
    enum Legacy {
        /// The earlier app's name, as copy shows it (C11H-335).
        static let appName = "c11h" // c11-2.0:legacy
        static let releaseBundleIdentifier = "com.stage11.c11h" // c11-2.0:legacy
        static let untaggedDebugBundleIdentifier = "com.stage11.c11h.debug" // c11-2.0:legacy
        static let stagingBundleIdentifier = "com.stage11.c11h.staging" // c11-2.0:legacy
        static let nightlyBundleIdentifier = "com.stage11.c11h.nightly" // c11-2.0:legacy
        static let defaultsDomain = "com.stage11.c11h" // c11-2.0:legacy
        static let stateDirectoryName = "c11h" // c11-2.0:legacy
        static let logsDirectoryName = "c11h" // c11-2.0:legacy
        static let stableSocketFileName = "c11h.sock" // c11-2.0:legacy
        static let lastSocketPathFile = "/tmp/c11h-last-socket-path" // c11-2.0:legacy
        static let keychainService = "com.stage11.c11h.socket-control" // c11-2.0:legacy
        static let snapshotDirectoryName = ".c11h-snapshots" // c11-2.0:legacy
        static let runtimeDirectoryName = ".c11h" // c11-2.0:legacy
        static let configDirectoryName = "c11h" // c11-2.0:legacy (~/.config/c11h)
        static let hcRootRelativePath = ".local/share/c11h" // c11-2.0:legacy
        static let hcSessionBase = "c11h" // c11-2.0:legacy (shards c11h-s1..s8)
        static let hcHelperIdentifier = "com.stage11.c11h.herdr-core" // c11-2.0:legacy
        static let appBundleName = "c11h.app" // c11-2.0:legacy
        static let ownedCLISymlinkSuffix = "/c11h.app/Contents/Resources/bin/c11" // c11-2.0:legacy
        static let defaultsKeyPrefix = "c11h." // c11-2.0:legacy (c11h.<key> became c11.<key>)
        static let invokedAsNames: Set<String> = ["c11h", "c11h-core"] // c11-2.0:legacy (hidden CLI aliases)
        static let panelLinkScheme = "c11h" // c11-2.0:legacy
        static let showScheme = "c11h-show" // c11-2.0:legacy
        static let guidePage = "c11h" // c11-2.0:legacy (`c11 guide c11h` prints `persistence`)
        static let environmentPrefix = "C11H_" // c11-2.0:legacy

        /// The product variables (identity map, appendix A) whose old name still
        /// works: `C11H_<suffix>` fills `C11_<suffix>` when only the old one is
        /// set. Tooling knobs are not here: `C11H_SOCKET` and `C11H_TAG` were the
        /// proof harness's, and must never become the CLI's socket or tag.
        static let environmentAliasSuffixes: [String] = [
            "RELAY_BIN", "RELAY_AUTH", "RELAY_HC_SOCKET", "RELAY_SESSION", "RELAY_PROTOCOL",
            "RELAY_PICKUP", "RELAY_CODEX_WRAPPER_REENTRY", "RELAY_CLAIM_MS", "START_DIR",
            "AGENT_NOTE_SENT", "AGENT_NOTE_DISABLED", "HOST_TRANSPORT_BUS", "HC_FAULTS",
            "LATENCY_LOG", "HOST_END_RESUME_INTERVAL_MS", "HOST_END_RESUME_SETTLE_MS",
            "HOST_END_RESUME_MAX_IN_FLIGHT", "MASS_SIGNAL_END_WINDOW_MS", "MASS_SIGNAL_END_SETTLE_MS",
            "FORCE_MAIN_STALL", "GRAPH_CHURN", "GRAPH_CHURN_PRINT", "GRAPH_CHURN_LOG",
            "DEBUG_KEEP_SESSION_TWINS", "TIP_PREVIEW", "WHATS_DIFFERENT_SAMPLE",
        ]

        /// `~/.local/share/c11h` under `home`.
        static func hcRoot(home: URL) -> URL {
            home.appendingPathComponent(hcRootRelativePath, isDirectory: true)
        }

        /// The hc session names c11h's release build used: `c11h`, `c11h-s1`…`c11h-s8`.
        static func releaseSessionNames(poolSize: Int = 8) -> [String] {
            [hcSessionBase] + (1...poolSize).map { "\(hcSessionBase)-s\($0)" }
        }
    }
    // c11-2.0:end-keep
}


/// The retired line's product variable names still work as hidden fallbacks
/// (`C11Identity.Legacy.environmentAliasSuffixes`): fill `C11_X` from the old
/// name when only that is set. Live terminals keep the environment they
/// started with, so a shell an older build opened still carries the old names.
func fillC11EnvFromLegacyNames(environment: [String: String] = ProcessInfo.processInfo.environment,
                               set: (String, String) -> Void = { setenv($0, $1, 1) }) {
    for suffix in C11Identity.Legacy.environmentAliasSuffixes {
        guard let value = environment[C11Identity.Legacy.environmentPrefix + suffix],
              environment["C11_" + suffix] == nil else { continue }
        set("C11_" + suffix, value)
    }
}
