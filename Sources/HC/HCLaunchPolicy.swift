import CryptoKit
import Foundation
import os
#if canImport(Security)
import Security
#endif

/// Pure launch/environment policy. Neither reading config nor building a tuple
/// starts hc; only HCLauncher may perform the process launch after verification.
enum HCLaunchPolicy {
    /// Contract Amendment 1 (C11H-66): with `SSH_CONNECTION` set, hc starts every
    /// core directly, including one its holder restarts after a crash, and strips
    /// `SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY` from every program. A fixed
    /// placeholder; hc only asks whether it is set.
    static let restartPlaceholder = "c11 0 c11 0"

    /// Variables the core carries for itself that a terminal must not inherit
    /// from it (A1, S3). hc's run environment cannot unset a variable, so a
    /// terminal with no value of its own gets `/usr/bin/env -u NAME` on its argv.
    static let coreOnlyVariables = ["XDG_CONFIG_HOME", "HC_SPAWN_MS", "HC_LAUNCHD_DIRECT"]

    /// The external pin's tuple, as in M1. Kept for tests and the transition.
    static func configuration(home: URL, tag: String?, shard: Int = 0, inherited: [String: String], pin: HCPin,
                              launcherPID: Int32 = getpid()) throws -> HCLaunchConfiguration {
        try configuration(home: home, tag: tag, shard: shard, inherited: inherited,
                          binary: HCCoreBinary.external(home: home, pin: pin), launcherPID: launcherPID)
    }

    /// `shard` 0 is the single session every build had before shards (C11H-67);
    /// shard N in 1...HCShardID.poolSize is `<base>-sN`, its own core and socket.
    /// Amendment 1 A1.L1: the 103-byte check runs against shard K's holder for
    /// every shard, so a tuple that cannot hold the whole pool is refused for all.
    ///
    /// `binary` nil resolves this app's core: the bundled helper, else the
    /// external pin (C11H-66 transition). `launcherPID` is the process that will
    /// spawn `serve` (HCLauncher, in this process): A1 requires `HC_LAUNCHD_DIRECT`
    /// to name the core's direct parent.
    static func configuration(home: URL, tag: String?, shard: Int = 0, inherited: [String: String], binary: HCCoreBinary? = nil,
                              launcherPID: Int32 = getpid(),
                              retainedTrust: HCRetainedTrust = .current,
                              namespace: C11AdoptionRecord? = HCLaunchPolicy.processNamespace) throws -> HCLaunchConfiguration {
        let binary = try binary ?? HCCoreBinary.resolved(home: home)
        let pin = binary.pin
        if let tag {
            guard !tag.isEmpty, tag.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte)
            }) else { throw HCUnavailableReason.invalidLaunchTuple }
            // `<tag>` ending in `-sN` (or being `sN`) would name another build's shard.
            guard !HCShardID.isShardSuffix(tag.split(separator: "-", omittingEmptySubsequences: false).last.map(String.init) ?? "")
            else { throw HCUnavailableReason.invalidLaunchTuple }
        }
        guard (0...HCShardID.poolSize).contains(shard) else { throw HCUnavailableReason.invalidLaunchTuple }
        // C11H-266: a migrated app keeps the sessions it adopted, by name and root.
        let base = namespace?.base ?? HCShardID.base(tag: tag)
        let session = HCShardID.session(base: base, shard: HCShardID(index: shard))
        let root = home.appendingPathComponent(namespace?.root ?? ".local/share/c11", isDirectory: true)
        let socket = root.appendingPathComponent("run/\(session).sock")
        let longestHolder = root.appendingPathComponent("run/\(HCShardID.session(base: base, shard: HCShardID(index: HCShardID.poolSize))).sock")
            .deletingPathExtension().path + ".holder.00000000.sock"
        guard socket.path.utf8.count <= 103, longestHolder.utf8.count <= 103,
              !home.path.utf8.contains(0), home.path.hasPrefix("/"),
              !pin.version.isEmpty, pin.version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            throw HCUnavailableReason.invalidLaunchTuple
        }
        var environment = inherited.filter { key, _ in
            !key.hasPrefix("HC_") && !key.hasPrefix("XDG_") &&
            !key.hasPrefix("C11_") && !key.hasPrefix("CMUX_") &&
            !HCLaunchEnvironmentScrub.isAgentOrHostTerminalVariable(key) &&
            // Ghostty removes these inherited values before terminal overrides.
            // hc's string-only run environment cannot unset a core variable.
            !Set(["CODEX_THREAD_ID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "VTE_VERSION", "GHOSTTY_LOG"]).contains(key)
        }
        environment["HOME"] = home.path
        environment["HC_SESSION"] = session
        environment["HC_SOCKET"] = socket.path
        environment["HC_SPAWN_MS"] = String(HCLimits.spawnMilliseconds)
        // Amendment 1, bundled core: exactly these three values are added. c11's
        // own config home (hc's shared ~/.config/herdr-core is never read), the
        // direct parent for the first start, and the restart rule.
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        environment["XDG_CONFIG_HOME"] = configDirectory.path
        environment["HC_LAUNCHD_DIRECT"] = String(launcherPID)
        environment["SSH_CONNECTION"] = restartPlaceholder
        var serving = [HCServingBinary(executableURL: binary.executableURL, pin: pin)]
        if binary.origin == .bundled {
            // Transition (one update): a core already serving from M1's external
            // pin is adopted, never started.
            let external = HCCoreBinary.external(home: home, pin: HCCoreBinary.externalPin)
            serving.append(HCServingBinary(executableURL: external.executableURL, pin: external.pin))
        }
        if let retained = binary.retainedRoot {
            // A core of the app this one replaced keeps running from the helper
            // the installer retained; it is adopted, never started.
            serving.append(contentsOf: HCCoreBinary.retainedServing(in: retained, helperName: binary.executableURL.lastPathComponent,
                                                                    trust: retainedTrust))
        }
        if let app = namespace?.servingApp {
            // C11H-266: adopted cores run c11h's own helper, or a helper the c11h  c11-2.0:legacy
            // installer retained beside it after an update (`.<app>-helpers/<entry>`);
            // each by its exact path, its sealed hash and the same trust.
            let appURL = URL(fileURLWithPath: app, isDirectory: true)
            let helperName = binary.executableURL.lastPathComponent
            if let adopted = HCCoreBinary.servingEntry(bundle: appURL, helperName: helperName, trust: retainedTrust) {
                serving.append(adopted)
            }
            serving.append(contentsOf: HCCoreBinary.retainedServing(in: HCCoreBinary.retainedRootURL(bundle: appURL),
                                                                    helperName: helperName, trust: retainedTrust))
        }
        return HCLaunchConfiguration(
            executableURL: binary.executableURL,
            session: session, socketURL: socket,
            stateDirectory: home.appendingPathComponent(".local/state/herdr-core/\(session)", isDirectory: true),
            intentDirectory: home.appendingPathComponent("Library/Application Support/c11/HC/\(session)", isDirectory: true),
            environment: environment, pin: pin,
            acceptedServing: serving, configDirectory: configDirectory
        )
    }

    /// C11H-391: the links session `L` of an app that adopted c11h's sessions
    /// (`namespace` set): c11's own shard 0 with no namespace, so session
    /// `c11[-<tag>]`, root `~/.local/share/c11`, this build's hc and its own
    /// retained helpers, never the adopted `c11h`. Add Machine, Update and
    /// `c11 machine link` link there, and the pool composes it beside the
    /// adopted members. Nil when not adopted: shard 0 is c11's own already.
    static func linksConfiguration(home: URL, tag: String?, inherited: [String: String], binary: HCCoreBinary? = nil,
                                   namespace: C11AdoptionRecord? = HCLaunchPolicy.processNamespace) throws -> HCLaunchConfiguration? {
        guard namespace != nil else { return nil }
        return try configuration(home: home, tag: tag, inherited: inherited, binary: binary, namespace: nil)
    }

    /// This process's hc namespace record, read once: the app's own bundle, or the
    /// `.app` around the CLI (`HCCoreBinary.appBundle`).
    static let processNamespace: C11AdoptionRecord? = {
        let main = Bundle.main.bundleURL
        let app = HCCoreBinary.appBundle(main: main, executable: Bundle.main.executableURL)
        let bundleIdentifier = app.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? Bundle.main.bundleIdentifier
        return C11AdoptionRecord.resolve(home: FileManager.default.homeDirectoryForCurrentUser,
                                      bundleIdentifier: bundleIdentifier)
    }()

    /// The common wire builder for panel creation (including replacements,
    /// retries and remote/headless starts) and managed `hc run`. Apply this
    /// after placement and relay preparation, never in a surface's start path:
    /// replacements can supply a new argv without going through that path.
    ///
    /// `environment` contains terminal overrides, NOT the core environment.
    /// Presence is provenance: an app-launch/config/panel XDG value is user
    /// input even when empty or equal to the core's private config directory.
    /// Without an override, env -u removes the value inherited from the core.
    /// HC_* overrides are forbidden; the core's launch knobs are always unset,
    /// while its terminal identity/socket/scope variables remain intact.
    static func terminalRunParameters(argv: [String], environment: [String: String]) -> [String: HCJSONValue] {
        let overlay = environment.filter { !$0.key.hasPrefix("HC_") }
        let unset = coreOnlyVariables.filter { overlay[$0] == nil }
        // An omitted command must not bypass sanitization. Resolve the default
        // login shell on the owning machine, as remote placement does.
        let command = argv.isEmpty ? ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l"] : argv
        // env execs its target: the terminal root keeps the same pid.
        let sanitized = ["/usr/bin/env"] + unset.flatMap { ["-u", $0] } + command
        return ["argv": .array(sanitized.map(HCJSONValue.string)),
                "env": .object(overlay.mapValues(HCJSONValue.string))]
    }

    /// What a native terminal inherits from c11's own process environment that
    /// an hc terminal does not: hc spawns the terminal from the core, whose
    /// environment is scrubbed of `C11_*`/`CMUX_*`/`XDG_*` (see `configuration`),
    /// so `C11_DEBUG_LOG`, `C11_QA_LAUNCH` and the rest of c11's launch settings
    /// never arrived. This is that inherited base: `XDG_*` and the c11 namespace,
    /// minus what is not c11's launch setting to hand on:
    /// - the panel-scoped identity and port variables (ids, numbers, area,
    ///   ports): c11 sets these itself per panel, and an inherited value (c11
    ///   started from another c11 terminal) names a different panel;
    /// - hc's own identity (`HC_*`, `C11_HC_SESSION`, `C11_HC_SOCKET`), which hc
    ///   owns.
    /// Everything c11 sets for the surface (the `managed` environment: ids,
    /// socket path, PATH wrappers, shell integration, ZDOTDIR) is laid over
    /// this by `HCShellIntegration.launchTuple`, so it wins.
    static func inheritedAppEnvironment(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { key, _ in
            if key.hasPrefix("XDG_") { return true }
            guard key.hasPrefix("C11_") || key.hasPrefix("CMUX_") else { return false }
            if key == "C11_HC_SESSION" || key == "C11_HC_SOCKET" { return false }
            let name = String(key.hasPrefix("C11_") ? key.dropFirst(4) : key.dropFirst(5))
            // C11H-34: the agent seat's wrapper stamps (reentry markers, interactive
            // pid, hook CLI, opencode claims) are as host-specific as the ids.
            return !panelScopedNames.contains(name) && !HCLaunchEnvironmentScrub.isHostIdentityName(name)
        }
    }

    static let panelScopedNames: Set<String> = [
        "PANEL_ID", "TAB_ID", "SURFACE_ID", "WORKSPACE_ID",
        "PANEL_NUM", "TAB_NUM", "SURFACE_NUM", "AREA_ID",
        "PORT", "PORT_END", "PORT_RANGE",
    ]

    /// Overlay values are explicitly selected by the existing terminal builder,
    /// not a copy of the agent's environment. hc owns all its identity variables.
    static func terminalEnvironment(managed: [String: String], configured: [String: String], intendedXDG: [String: String], configuration: HCLaunchConfiguration? = nil) -> [String: String] {
        var result = managed.merging(configured) { _, configured in configured }
        for (key, value) in intendedXDG where key.hasPrefix("XDG_") { result[key] = value }
        if let configuration {
            result["C11_HC_SESSION"] = configuration.session
            result["C11_HC_SOCKET"] = configuration.socketURL.path
        }
        return result.filter { !$0.key.hasPrefix("HC_") }
    }

    static func shimTargetsOwnedCore(caller: [String: String], configuration: HCLaunchConfiguration) -> Bool {
        caller["HC_SESSION"] == configuration.session && caller["HC_SOCKET"] == configuration.socketURL.path
    }
}

struct HCFileLimitPlan: Equatable, Sendable {
    let soft: UInt64
    let hard: UInt64
    let kernelCap: UInt64
    let targetSoft: UInt64

    init(soft: UInt64, hard: UInt64, kernelCap: UInt64, infinity: UInt64) throws {
        let effectiveHard = hard == infinity ? kernelCap : min(hard, kernelCap)
        guard effectiveHard >= HCLimits.minimumFileDescriptors else { throw HCUnavailableReason.fileDescriptorLimit }
        self.soft = soft
        self.hard = hard
        self.kernelCap = kernelCap
        // Keep an already-sufficient higher value; never lower the app's limit.
        self.targetSoft = max(soft, effectiveHard)
    }

    func verified(soft: UInt64, hard: UInt64) -> Bool {
        hard == self.hard && min(soft, kernelCap) >= HCLimits.minimumFileDescriptors
    }
}


/// c11's own process environment at launch (C11H-34). `open` from a c11
/// terminal hands the app that terminal's whole environment: the panel's ids,
/// its socket, the launching agent's session markers (`CLAUDE_CODE_CHILD_SESSION`
/// makes Claude inside c11 report "Transcript saving is off"), the host
/// terminal's `TERM_PROGRAM*`. The hc core and every terminal c11 starts
/// descend from this process, so what is not scrubbed here is inherited by all.
///
/// What goes, by name only (values are never read or logged):
/// - agent markers: `CLAUDE_*`, `CLAUDECODE`, `CODEX_*`, and `TERM_PROGRAM*`
///   (the host terminal's identity; `configureGhosttyEnvironment` then sets
///   `TERM_PROGRAM=ghostty` for c11's own terminals);
/// - the host terminal's identity under both prefixes (`hostIdentityNames`: the
///   panel-scoped ids, numbers and ports, shell-integration stamps, the bundled
///   CLI path, c11's agent stamps and hc's session/socket);
/// - the socket path (`*_SOCKET_PATH`, `*_SOCKET`) when the environment also
///   carries a terminal marker, unless `ALLOW_SOCKET_OVERRIDE` says the override
///   is intended. A launch script or a UI test sets a socket path with no panel
///   id beside it; an inherited one always arrives with them.
/// - the legacy `CMUX_*` namespace, except `cmuxLaunchSettings`.
///
/// What stays is the allowlist: the `C11_*` namespace is c11's own launch
/// settings (`C11_QA_LAUNCH`, `C11_DEBUG_LOG`, `C11_TAG`, `C11_SOCKET_MODE`,
/// the daemon and hang knobs, ...), so it is scrubbed only by the identity
/// names above rather than by an allowlist that would silently drop a knob it
/// forgot. Their `CMUX_*` aliases stay when named in `cmuxLaunchSettings` or
/// under `CMUX_UI_TEST_`/`CMUX_DISABLE_`.
///
/// Interplay with `HCLaunchPolicy.inheritedAppEnvironment` (#63): that hands
/// the app's remaining `C11_*`/`CMUX_*` to hc terminals, so the scrub is what
/// keeps the host terminal's identity out of the app's environment in the first
/// place; #63 keeps its own panel-scoped filter as a second line.
enum HCLaunchEnvironmentScrub {
    static let hostIdentityNames: Set<String> = HCLaunchPolicy.panelScopedNames.union([
        "SHELL_INTEGRATION", "SHELL_INTEGRATION_DIR",
        "LOAD_GHOSTTY_ZSH_INTEGRATION", "LOAD_GHOSTTY_BASH_INTEGRATION",
        "ZSH_ZDOTDIR", "RESTORE_SCROLLBACK_FILE",
        "BUNDLE_ID", "BUNDLED_CLI_PATH", "CLAUDE_HOOKS_DISABLED",
        "AGENT_TYPE", "AGENT_MODEL", "AGENT_TASK", "AGENT_ROLE",
        "CLAUDE_WRAPPER_REENTRY", "CODEX_WRAPPER_REENTRY", "AGENT_INTERACTIVE_PID", "AGENT_HOOK_CLI", "CLAUDE_PID",
        "OPENCODE_EXPECTED_RESUME_ID", "OPENCODE_TUI_CLAIMED", "OPENCODE_RESUME_RESERVED",
        "OPENCODE_TUI_CLAIM_FAILED", "OPENCODE_RESUME_RESERVATION_FAILED",
        "HC_SESSION", "HC_SOCKET",
        "DEFAULT_AGENT_LAUNCH", "DEFAULT_AGENT_SEED_PROMPT",
    ])

    /// A terminal's own stamp. Present beside a socket path, it means the path
    /// was inherited from that terminal.
    static let terminalMarkerNames: Set<String> = [
        "PANEL_ID", "SURFACE_ID", "TAB_ID", "WORKSPACE_ID", "SHELL_INTEGRATION",
    ]

    /// A name that identifies the host terminal or the launching agent seat,
    /// whichever namespace it arrives in. The `_WRAPPER_REENTRY` suffix covers
    /// the next agent wrapper's marker before anyone lists it: a wrapper that
    /// finds its own marker execs the real binary without its integration, so
    /// an inherited one switches the integration off for a fresh agent.
    static func isHostIdentityName(_ name: String) -> Bool {
        hostIdentityNames.contains(name) || name.hasSuffix("_WRAPPER_REENTRY")
    }

    static let socketPathNames: Set<String> = ["SOCKET_PATH", "SOCKET"]

    /// Legacy `CMUX_*` aliases of launch settings still honoured at launch.
    static let cmuxLaunchSettings: Set<String> = [
        "TAG", "DEBUG_LOG", "QA_LAUNCH", "SOCKET_ENABLE", "SOCKET_MODE",
        "SOCKET_PASSWORD", "ALLOW_SOCKET_OVERRIDE", "REPO_ROOT",
    ]

    private static let allowSocketOverrideName = "ALLOW_SOCKET_OVERRIDE"
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.launch")

    /// Agent and host-terminal markers that no c11 process or terminal should
    /// inherit, whatever the namespace around them.
    static func isAgentOrHostTerminalVariable(_ key: String) -> Bool {
        key.hasPrefix("CLAUDE_") || key == "CLAUDECODE" ||
            key.hasPrefix("CODEX_") || key.hasPrefix("TERM_PROGRAM")
    }

    private static func familyName(_ key: String) -> (prefix: String, name: String)? {
        if key.hasPrefix("C11_") { return ("C11_", String(key.dropFirst(4))) }
        if key.hasPrefix("CMUX_") { return ("CMUX_", String(key.dropFirst(5))) }
        return nil
    }

    /// The names to remove from `environment`, sorted.
    static func namesToRemove(from environment: [String: String]) -> [String] {
        let carriesTerminalMarker = environment.keys.contains { key in
            familyName(key).map { terminalMarkerNames.contains($0.name) } ?? false
        }
        let socketOverrideIntended = environment.contains { key, value in
            guard let family = familyName(key), family.name == allowSocketOverrideName else { return false }
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        return environment.keys.filter { key in
            if key == "ZDOTDIR" { return zdotdirIsShellIntegration(environment) }
            if isAgentOrHostTerminalVariable(key) { return true }
            guard let family = familyName(key) else { return false }
            if isHostIdentityName(family.name) { return true }
            if socketPathNames.contains(family.name) {
                return carriesTerminalMarker && !socketOverrideIntended
            }
            guard family.prefix == "CMUX_" else { return false }
            return !(cmuxLaunchSettings.contains(family.name) ||
                family.name.hasPrefix("UI_TEST_") || family.name.hasPrefix("DISABLE_"))
        }.sorted()
    }

    /// `ZDOTDIR` is a host-terminal stamp only when it points into a c11 or c11
    /// shell-integration directory (the terminal's own `ZDOTDIR` wrapper, or the
    /// value of its `*_SHELL_INTEGRATION_DIR`). An operator's own `ZDOTDIR` stays.
    static func zdotdirIsShellIntegration(_ environment: [String: String]) -> Bool {
        guard let raw = environment["ZDOTDIR"], !raw.isEmpty else { return false }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        for (key, value) in environment {
            guard let family = familyName(key), family.name == "SHELL_INTEGRATION_DIR", !value.isEmpty else { continue }
            if URL(fileURLWithPath: value).standardizedFileURL.path == path { return true }
        }
        return path.hasSuffix(".app/Contents/Resources/shell-integration")
    }

    /// The operator's own `ZDOTDIR` that the host terminal saved in
    /// `*_ZSH_ZDOTDIR` when it put its wrapper in place; restoring it keeps the
    /// operator's zsh startup files, where merely unsetting would lose them.
    /// `nil` when `ZDOTDIR` is not a stamp or nothing was saved.
    static func zdotdirRestoration(from environment: [String: String]) -> String? {
        guard zdotdirIsShellIntegration(environment) else { return nil }
        for key in ["C11_ZSH_ZDOTDIR", "CMUX_ZSH_ZDOTDIR"] {
            if let saved = environment[key], !saved.isEmpty { return saved }
        }
        return nil
    }

    /// Removes `namesToRemove` from the live process environment and returns
    /// the names (never values). Call it before anything reads or mirrors the
    /// environment.
    @discardableResult
    static func scrubProcessEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { _ = unsetenv($0) },
        set: (String, String) -> Void = { _ = setenv($0, $1, 1) }
    ) -> [String] {
        let names = namesToRemove(from: environment)
        let zdotdir = zdotdirRestoration(from: environment)
        for name in names { unset(name) }
        if let zdotdir { set("ZDOTDIR", zdotdir) }
        if !names.isEmpty {
            logger.notice("launch.env.scrubbed count=\(names.count, privacy: .public) names=\(names.joined(separator: ","), privacy: .public)")
        }
        return names
    }
}


/// Every environment variable the terminal builder (`TerminalSurface.createSurface`)
/// stamps on a c11 terminal. The builder takes this type, not a string, so a
/// variable cannot be stamped without being listed here; `HCLaunchEnvironmentScrub`'s
/// tests walk `allCases` and fail for any c11 name the launch scrub does not
/// cover (C11H-34). Add the case, then either put its name in
/// `HCLaunchEnvironmentScrub.hostIdentityNames` or, for an ordinary variable,
/// in `notC11Namespace` with the reason.
enum ManagedTerminalEnvironmentKey: String, CaseIterable {
    case surfaceId = "CMUX_SURFACE_ID"
    case workspaceId = "CMUX_WORKSPACE_ID"
    case panelId = "CMUX_PANEL_ID"
    case tabId = "CMUX_TAB_ID"
    case panelNum = "C11_PANEL_NUM"
    case tabNum = "C11_TAB_NUM"
    case surfaceNum = "C11_SURFACE_NUM"
    case socketPath = "CMUX_SOCKET_PATH"
    case c11SocketPath = "C11_SOCKET_PATH"
    case bundledCLIPath = "CMUX_BUNDLED_CLI_PATH"
    case bundleId = "CMUX_BUNDLE_ID"
    case defaultAgentLaunch = "C11_DEFAULT_AGENT_LAUNCH"
    case defaultAgentSeedPrompt = "C11_DEFAULT_AGENT_SEED_PROMPT"
    case port = "CMUX_PORT"
    case portEnd = "CMUX_PORT_END"
    case portRange = "CMUX_PORT_RANGE"
    case claudeHooksDisabled = "CMUX_CLAUDE_HOOKS_DISABLED"
    case path = "PATH"
    case shellIntegration = "CMUX_SHELL_INTEGRATION"
    case shellIntegrationDir = "CMUX_SHELL_INTEGRATION_DIR"
    case loadGhosttyZsh = "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"
    case zshZdotdir = "CMUX_ZSH_ZDOTDIR"
    case zdotdir = "ZDOTDIR"
    case loadGhosttyBash = "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION"
    case promptCommand = "PROMPT_COMMAND"

    /// Stamped on terminals but not c11 names: the builder rewrites them per
    /// terminal from the shell, so an inherited value is ordinary shell
    /// startup state, not the host terminal's identity.
    static let notC11Namespace: Set<ManagedTerminalEnvironmentKey> = [.path, .zdotdir, .promptCommand]
}


/// Every `C11_*`/`CMUX_*` variable the agent wrappers in `Resources/bin/` export
/// to the agent they launch (`export NAME=` and `NAME=1 exec`), declared by hand
/// from those scripts. A c11 Codex seat that launches c11 hands these on; the
/// Codex marker made a fresh Codex in c11 skip its wrapper integration
/// (sol, #71). `testEveryVariableAnAgentWrapperExportsIsScrubbedAndNotHandedToHcTerminals`
/// walks `allCases`; a new export needs a case here and a name in
/// `HCLaunchEnvironmentScrub.hostIdentityNames` (the `_WRAPPER_REENTRY` suffix
/// is covered without listing).
enum AgentWrapperEnvironmentKey: String, CaseIterable {
    case codexReentry = "C11_CODEX_WRAPPER_REENTRY"
    case claudeReentry = "C11_CLAUDE_WRAPPER_REENTRY"
    case interactivePid = "C11_AGENT_INTERACTIVE_PID"
    case hookCLI = "C11_AGENT_HOOK_CLI"
    case claudePid = "CMUX_CLAUDE_PID"
    case opencodeExpectedResumeId = "C11_OPENCODE_EXPECTED_RESUME_ID"
    case opencodeTuiClaimed = "C11_OPENCODE_TUI_CLAIMED"
    case opencodeResumeReserved = "C11_OPENCODE_RESUME_RESERVED"
    case opencodeTuiClaimFailed = "C11_OPENCODE_TUI_CLAIM_FAILED"
    case opencodeResumeReservationFailed = "C11_OPENCODE_RESUME_RESERVATION_FAILED"
}


/// A core binary c11 accepts as already serving: its path, and the pin its
/// file must hash to (L2).
struct HCServingBinary: Equatable, Sendable {
    let executableURL: URL
    let pin: HCPin
}

/// The core binary c11 starts (C11H-66, contract Amendment 1). The stock build
/// sits at `Contents/Helpers/herdr-core` and is checked against the hash of its
/// signed file. The build records that hash in `Contents/Resources/hc-pin.json`,
/// which the app's own signature seals. With no bundled helper (a Debug build
/// made without the hc cache), M1's external pin is used, for one transition update.
struct HCCoreBinary: Equatable, Sendable {
    enum Origin: String, Sendable { case bundled, external }

    let executableURL: URL
    let pin: HCPin
    let origin: Origin
    /// Where the installer keeps replaced apps whose helper a live core still
    /// runs (`.<app name>-helpers` beside the app). Bundled only.
    var retainedRoot: URL? = nil

    static let helperName = "herdr-core"
    static let retainedLimit = 32
    static let manifestName = "hc-pin.json"
    static let manifestMaxBytes = 64 * 1024

    /// M1's external pin: upstream's 0.1.16 release at
    /// `~/.local/share/c11/hc/0.1.16/herdr-core`.
    static let externalPin = HCPin(
        version: "0.1.16",
        archiveSHA256: "698d8f0c44f4e4b15fec174d52a39d57a014cfd71added44b53a0753b469d0fd",
        executableSHA256: "c617feeb4d1b5f59b30e4ab6b4e9e7f7ac114d0681d207d9f41efa12c813b922",
        protocolGeneration: 1
    )

    /// What the build writes after signing the helper. `sourceSHA256` is the
    /// unsigned reproducible build it came from (`Resources/hc/hc-source.json`);
    /// `executableSHA256` is the signed file, the one L2 checks.
    struct Manifest: Codable, Equatable, Sendable {
        let version: String
        let protocolGeneration: Int
        let sourceSHA256: String
        let executableSHA256: String
    }

    static func external(home: URL, pin: HCPin) -> HCCoreBinary {
        HCCoreBinary(executableURL: home.appendingPathComponent(".local/share/c11/hc/\(pin.version)/herdr-core"),
                     pin: pin, origin: .external)
    }

    static func helperURL(bundle: URL, name: String = helperName) -> URL {
        bundle.appendingPathComponent("Contents/Helpers", isDirectory: true).appendingPathComponent(name)
    }

    static func manifestURL(bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(manifestName)
    }

    /// nil when the bundle carries neither the helper nor its manifest. Half a
    /// bundle (one without the other) or an invalid manifest throws `pinMismatch`:
    /// a broken bundle never falls back to the external pin.
    static func bundled(in bundle: URL) throws -> HCCoreBinary? {
        let helper = helperURL(bundle: bundle), manifestURL = manifestURL(bundle: bundle)
        var info = stat()
        let helperPresent = lstat(helper.path, &info) == 0
        let manifestPresent = lstat(manifestURL.path, &info) == 0
        guard helperPresent || manifestPresent else { return nil }
        guard helperPresent, manifestPresent else { throw HCUnavailableReason.pinMismatch }
        let manifest = try decodeManifest(at: manifestURL)
        let pin = HCPin(version: manifest.version, archiveSHA256: manifest.sourceSHA256,
                        executableSHA256: manifest.executableSHA256, protocolGeneration: manifest.protocolGeneration)
        return HCCoreBinary(executableURL: helper, pin: pin, origin: .bundled, retainedRoot: retainedRootURL(bundle: bundle))
    }

    static func retainedRootURL(bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent)-helpers", isDirectory: true)
    }

    /// The replaced apps `c11-install.sh` kept, renamed whole into the retained
    /// root, because a process still ran their helper. Each entry's helper is
    /// accepted only at its own path and only if its file hashes to that entry's
    /// own sealed manifest (the verifier hashes it); an entry with a bad manifest
    /// or no helper is skipped. The entry's word is not enough (C11H-108): `trust`
    /// must also admit it, by a shipped pin hash or c11's own signature.
    /// `helperName` is the bundled helper's file name (`herdr-core` in every
    /// shipped app), so a retained app is read the way the running app is laid out.
    static func retainedServing(in root: URL, helperName: String = helperName, trust: HCRetainedTrust) -> [HCServingBinary] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.sorted().prefix(retainedLimit).compactMap { name -> HCServingBinary? in
            servingEntry(bundle: root.appendingPathComponent(name, isDirectory: true), helperName: helperName, trust: trust)
        }
    }

    /// One app's helper, accepted only at its own path, only if it hashes to its
    /// own sealed manifest, and only if `trust` admits it.
    static func servingEntry(bundle entry: URL, helperName: String = helperName, trust: HCRetainedTrust) -> HCServingBinary? {
        let helper = helperURL(bundle: entry, name: helperName)
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let manifest = try? decodeManifest(at: manifestURL(bundle: entry)) else { return nil }
        let pin = HCPin(version: manifest.version, archiveSHA256: manifest.sourceSHA256,
                        executableSHA256: manifest.executableSHA256, protocolGeneration: manifest.protocolGeneration)
        guard trust.admits(helper: helper, pin: pin) else {
            logger.error("hc_retained_refused path=\(helper.path, privacy: .public) sha256=\(pin.executableSHA256, privacy: .public)")
            return nil
        }
        return HCServingBinary(executableURL: helper, pin: pin)
    }

    /// Signed hashes of bundled helpers that shipped in a c11 release. A release
    /// that ships a bundled helper adds its signed hash here for the releases
    /// after it, so a core of that release stays adoptable from its retained app
    /// whatever signed it.
    static let shippedHelperSHA256: Set<String> = [
        // c11 1.7.9-h5 (build 148.5, b864b611a), the first bundled release.
        "dd9b39ae3bc0da8950f1f0dfbe5a34614b7cbe82214c3700ad86315b6454161d",
        // c11 1.7.9-h6 (build 148.6, f5d2bb8b8).
        "60de0f5cc1cff3e77d110870b5b0d6d3b15da406618989303849cb43e092bfba",
        // c11 1.8.0-h7 (build 149.7, 351db3ead).
        "9c0676bbcce35c58d82b5f16b59f3e55b2d6673a0e716254c5e58c18b96bb61d",
        // c11 1.8.0-h8 (build 149.8, a78193048).
        "8e045f31ffad4004b99793461c8cad128508daccb9d32ddfaf14b5f3f0ae8757",
        // c11h 1.8.1-h10 (build 150.10, 8068cdd21). h9 was built but never installed.  // c11-2.0:legacy
        "0ebe98033baf5bf2f76dcd541eb461b15d4cbd5aefdd32e92d264d072a9cfd0b",
        // c11h 1.8.1-h11 to h15 (builds 150.11 to 150.15). c11 2.0 adopts their  // c11-2.0:legacy
        // cores from the c11h app a migration found (C11H-266).  // c11-2.0:legacy
        "af919b8d605ebd580f340bbfcd1e4a1c7c3b24fc7a981eac9916e0573b016a8f",
        "187aa94dbbc419367aadb1d50ec28945e3d3f9c28cb9697ca67d1e953bb8ba79",
        "8f68032d030e4fef4bc7dbc4b8102907fd994dcb6cd771447419b7ce9011f52f",
        "14b315d8af18d5f073388c2d513929b3645bd65c461803abe2d498740a8f59b2",
        "3f1b58dca952f6a35272111854f8d455324255fe5d56dccc5420a4b8f040d5bc",
        // c11h 1.8.1-h16 to h20 (C11H-394), each from its signed app's hc manifest,  // c11-2.0:legacy
        // the helper hashed to match. Respins superseded before install are left out.
        // c11h 1.8.1-h16 (build 150.16, 3158f9e3e).  // c11-2.0:legacy
        "03339dce9273efa37f9cbb0402e3220e2cf7b3a0890c408149f46e8693f65030",
        // c11h 1.8.1-h17 (build 150.17, 1eb93e3f4).  // c11-2.0:legacy
        "6d852295b9ddd43ed713c5be48248c6707564538778c20de206efbcba52db4cd",
        // c11h 1.8.1-h18 (build 150.18, f3e965513).  // c11-2.0:legacy
        "d073bd1a241c7b126c2c3ef0184509c844084a48cf573efe44fe9c13c6b99e0d",
        // c11h 1.8.1-h19 (build 150.19, 061dcf8b1). Built signed, never installed.  // c11-2.0:legacy
        "9351840eacff0fdabdff75e8d9be4c7e26b215293c06b98be02968db30e66896",
        // c11h 1.8.1-h20 (build 150.20, e63cd891b).  // c11-2.0:legacy
        "0df3a843035dd82772880f963d92020c09084e812f58f5a01b918ce58f14f193",
    ]

    static func decodeManifest(at url: URL) throws -> Manifest {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw HCUnavailableReason.pinMismatch }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: manifestMaxBytes + 1), data.count <= manifestMaxBytes,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.version.isEmpty, manifest.version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              manifest.protocolGeneration > 0,
              isSHA256(manifest.sourceSHA256), isSHA256(manifest.executableSHA256) else {
            throw HCUnavailableReason.pinMismatch
        }
        return manifest
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.launch")

    /// The `.app` this process runs from. For the app it is its own bundle. For
    /// the bundled CLI (`Contents/Resources/bin/c11`, which `c11-core` execs,
    /// possibly reached through a symlink) it is the nearest `.app` above the
    /// resolved executable, so the CLI pins the same helper the app starts.
    static func appBundle(main: URL, executable: URL?) -> URL? {
        if main.pathExtension == "app" { return main }
        guard var url = executable?.resolvingSymlinksInPath() else { return nil }
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    /// Read once per process: the bundle cannot change under a running app
    /// (a changed file fails the hash check at launch and on every connection).
    private static let bundledAtLaunch: Result<HCCoreBinary?, HCUnavailableReason> = {
        guard let app = appBundle(main: Bundle.main.bundleURL, executable: Bundle.main.executableURL) else {
            return .success(nil)
        }
        do {
            let binary = try bundled(in: app)
            if let binary {
                let folder = binary.executableURL.deletingLastPathComponent().path
                // The installer makes the folder 0555 (S1: hc then refuses `update`).
                // A dev build's folder stays writable; the hash is the guard.
                if access(folder, W_OK) == 0 {
                    logger.notice("hc_bundle_folder_writable path=\(folder, privacy: .public)")
                }
            }
            return .success(binary)
        } catch {
            logger.error("hc_bundle_invalid bundle=\(app.path, privacy: .public)")
            return .failure((error as? HCUnavailableReason) ?? .pinMismatch)
        }
    }()

    /// The bundled helper if this app has one, else the external pin under `home`.
    static func resolved(home: URL) throws -> HCCoreBinary {
        switch bundledAtLaunch {
        case .success(let binary?): return binary
        case .success(nil): return external(home: home, pin: externalPin)
        case .failure(let reason): throw reason
        }
    }

    /// For readers that only need the pin (diagnostics, rendering, the remote
    /// machine link). A broken bundle reports the external pin here and refuses to launch.
    static var current: HCCoreBinary {
        (try? resolved(home: FileManager.default.homeDirectoryForCurrentUser))
            ?? external(home: FileManager.default.homeDirectoryForCurrentUser, pin: externalPin)
    }
}

/// Who may vouch for a retained helper (C11H-108). A retained entry sits in a
/// user-writable folder, so its own manifest proves nothing: the entry is
/// admitted only when its pin hash is one a c11 release shipped, or its helper
/// carries c11's own Developer ID signature (this app's team, anchored at
/// Apple, one of the helper's identifiers). An app without a team (ad hoc,
/// Debug) has only the shipped list.
struct HCRetainedTrust: Sendable {
    static let helperIdentifier = "com.stage11.c11.herdr-core"
    /// The c11h line signed its helper under its own name; 2.0 adopts those
    /// cores at the switch (C11H-266, C11H-394).
    static let helperIdentifiers = [helperIdentifier, C11Identity.Legacy.hcHelperIdentifier]

    let shipped: Set<String>
    let team: String?
    let satisfies: @Sendable (URL, String) -> Bool

    static let current = HCRetainedTrust(shipped: HCCoreBinary.shippedHelperSHA256,
                                         team: HCCodeSignature.ownTeam,
                                         satisfies: { HCCodeSignature.satisfies($0, $1) })

    /// One requirement: either identifier, and always our team at an Apple
    /// anchor. `anchor apple generic` is what makes the team mean anything: a
    /// self-signed certificate can carry any team field.
    static func requirement(team: String) -> String {
        let identifiers = helperIdentifiers.map { #"identifier "\#($0)""# }.joined(separator: " or ")
        return #"(\#(identifiers)) and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }

    static func isTeamIdentifier(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }

    /// A shipped pin binds the bytes by itself: adoption hashes the served file
    /// against it. A signature binds only the file it was checked on, so the
    /// helper is hashed through one open descriptor, that digest must be the pin
    /// adoption will check, and the path must still name that same unchanged file
    /// (device, inode, size, mtime, ctime) after the signature check. A file
    /// swapped in before or after is then refused, here or by adoption's hash.
    func admits(helper: URL, pin: HCPin) -> Bool {
        if shipped.contains(pin.executableSHA256) { return true }
        guard let team, Self.isTeamIdentifier(team) else { return false }
        guard let snapshot = HCFileSnapshot(helper) else { return false }
        defer { snapshot.close() }
        guard snapshot.sha256 == pin.executableSHA256 else { return false }
        guard satisfies(helper, Self.requirement(team: team)) else { return false }
        return snapshot.isUnchanged(at: helper)
    }
}

/// One regular file, opened once: its digest and the identity it had when read.
final class HCFileSnapshot {
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modified: timespec, changed: timespec
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modified = info.st_mtimespec; changed = info.st_ctimespec
        }
        static func == (a: Identity, b: Identity) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    private var fd: Int32
    private let identity: Identity
    let sha256: String

    init?(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); return nil }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { Darwin.close(fd); return nil }
            if count == 0 { break }
            digest.update(data: buffer[0..<count])
        }
        self.fd = fd
        identity = Identity(info)
        sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The descriptor's file is unchanged and the path still names it.
    func isUnchanged(at url: URL) -> Bool {
        var now = stat(), there = stat()
        guard fd >= 0, fstat(fd, &now) == 0, lstat(url.path, &there) == 0 else { return false }
        return Identity(now) == identity && Identity(there) == identity
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}

enum HCCodeSignature {
#if canImport(Security)
    /// Strict static validation of `url` (all architectures) against `requirement`.
    static func satisfies(_ url: URL, _ requirement: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures))
        return SecStaticCodeCheckValidity(code, flags, parsed) == errSecSuccess
    }

    /// This process's own signing team, nil when ad hoc or unsigned.
    static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }()
#else
    /// No code signing to check on Linux (the relay CLI's platform): nothing satisfies a requirement, so every
    /// caller fails closed, and there is no signing team.
    static func satisfies(_ url: URL, _ requirement: String) -> Bool { false }
    static let ownTeam: String? = nil
#endif
}
