import Foundation

// Core for `c11 doctor`. Pure, testable: no socket, no UI, no Bundle.main reads.
// The CLI shim at CLI/c11.swift wires this into the `c11 doctor` dispatch.
//
// The doctor surfaces "which CLI binary will my shell invoke" — the live
// counterpart to `c11 health` (which inspects post-mortem rails like IPS and
// Sentry). It is intentionally narrow: CLI resolution only. Future live
// environment subchecks can accrete here.

/// Stable JSON keys for `c11 doctor --json`. Lowercase-snake to match
/// `c11 health --json`. Field names are part of the public CLI contract;
/// adding new keys is fine, removing or renaming requires care.
public enum CLIResolutionField: String {
    case bundledCliPath = "bundled_cli_path"
    case c11OnPath = "c11_on_path"
    case cmuxOnPath = "cmux_on_path"
    case bundledCliVersion = "bundled_cli_version"
    case c11OnPathVersion = "c11_on_path_version"
    case pathFixApplied = "path_fix_applied"
    case path = "path"
    case status = "status"
    case notes = "notes"
}

/// Classification of the operator's current CLI resolution state.
public enum CLIResolutionStatus: String {
    /// `c11` resolves to the active bundle's CLI; bundled and PATH-resolved
    /// paths agree.
    case ok = "ok"
    /// `c11` resolves to a binary that is not the active bundle's CLI.
    /// Most common cause: an upstream homebrew install ahead of
    /// `Resources/bin` in PATH (or a stale cached bundled CLI).
    case mismatch = "mismatch"
    /// `c11` is not on PATH at all. Typical when the shell-integration
    /// hasn't been sourced yet (eager invocation from a non-c11 terminal,
    /// or a shell that hasn't executed `_cmux_fix_path`).
    case missing = "missing"
    /// `CMUX_BUNDLED_CLI_PATH` is unset, so we can't tell what the active
    /// bundle's CLI is supposed to be. Doctor is being run outside a c11
    /// terminal; report what's on PATH and stop.
    case noBundle = "no_bundle"
}

/// Snapshot of the operator's CLI resolution state: which `c11`/`cmux`
/// binaries are on PATH, what the active bundle's CLI is, and whether they
/// agree. Pure data — no I/O is performed by the struct itself.
public struct CLIResolutionSnapshot {
    public let bundledCliPath: String?
    public let c11OnPath: String?
    public let cmuxOnPath: String?
    public let bundledCliVersion: String?
    public let c11OnPathVersion: String?
    public let pathEntries: [String]
    public let pathFixApplied: Bool
    public let status: CLIResolutionStatus
    public let notes: [String]

    public init(
        bundledCliPath: String?,
        c11OnPath: String?,
        cmuxOnPath: String?,
        bundledCliVersion: String?,
        c11OnPathVersion: String?,
        pathEntries: [String],
        pathFixApplied: Bool,
        status: CLIResolutionStatus,
        notes: [String]
    ) {
        self.bundledCliPath = bundledCliPath
        self.c11OnPath = c11OnPath
        self.cmuxOnPath = cmuxOnPath
        self.bundledCliVersion = bundledCliVersion
        self.c11OnPathVersion = c11OnPathVersion
        self.pathEntries = pathEntries
        self.pathFixApplied = pathFixApplied
        self.status = status
        self.notes = notes
    }
}

/// Inputs for `CLIResolutionSnapshot.collect` — environment plus three
/// closures that simulate `command -v <name>`, file existence, and
/// `<path> --version`. Tests inject synthetic implementations; the CLI
/// uses real `/usr/bin/which`-style lookups via the helpers below.
public struct CLIResolutionInputs {
    public var environment: [String: String]
    /// Looks up a command on PATH (like `command -v foo`). Returns the
    /// resolved absolute path or nil if not found.
    public var commandLookup: (String) -> String?
    /// Returns true if the path resolves to an existing executable file.
    public var executableExists: (String) -> Bool
    /// Invokes `<path> --version` and returns the first line of stdout.
    /// Closure form keeps tests deterministic and avoids spawning a child
    /// process during unit tests.
    public var versionLookup: (String) -> String?

    public init(
        environment: [String: String],
        commandLookup: @escaping (String) -> String?,
        executableExists: @escaping (String) -> Bool,
        versionLookup: @escaping (String) -> String?
    ) {
        self.environment = environment
        self.commandLookup = commandLookup
        self.executableExists = executableExists
        self.versionLookup = versionLookup
    }
}

extension CLIResolutionSnapshot {
    /// Collect a CLI-resolution snapshot from the given inputs. Pure
    /// classification — no I/O beyond what the input closures perform.
    public static func collect(inputs: CLIResolutionInputs) -> CLIResolutionSnapshot {
        let env = inputs.environment
        let bundledRaw = env["CMUX_BUNDLED_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundled = (bundledRaw?.isEmpty == false) ? bundledRaw : nil

        let pathRaw = env["PATH"] ?? ""
        let pathEntries = pathRaw
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)

        let c11Resolved = inputs.commandLookup("c11").flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let cmuxResolved = inputs.commandLookup("cmux").flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // Structural proxy for "did the shell integration's `_cmux_fix_path`
        // (or its bash equivalent) run?" — we report `path_fix_applied` as
        // true whenever the bundled CLI's directory is the first entry on
        // PATH. Any mechanism that prepends the same directory will flip the
        // bool, not just the c11 shell integration; treat it as a load-bearing
        // *resolution* signal, not a literal "did our function execute" gate.
        // (If a stricter signal is ever needed, have the integration export a
        // sentinel env var — e.g. `__CMUX_FIX_PATH_RAN=1` — and read it here.)
        var pathFixApplied = false
        if let bundled {
            let bundledDir = (bundled as NSString).deletingLastPathComponent
            if let firstPathEntry = pathEntries.first(where: { !$0.isEmpty }),
               firstPathEntry == bundledDir {
                pathFixApplied = true
            }
        }

        let bundledVersion = bundled.flatMap { inputs.versionLookup($0) }
        let c11Version = c11Resolved.flatMap { inputs.versionLookup($0) }

        let status: CLIResolutionStatus
        var notes: [String] = []

        if bundled == nil {
            status = .noBundle
            notes.append(
                "CMUX_BUNDLED_CLI_PATH is unset; c11 doctor is best run inside a c11 terminal."
            )
        } else if let bundled, !inputs.executableExists(bundled) {
            // Bundle env var is set but the file is gone — usually means the
            // operator launched c11 from a different bundle than is currently
            // on disk. Flag as mismatch with an explicit note.
            status = .mismatch
            notes.append(
                "CMUX_BUNDLED_CLI_PATH points at \(bundled), which is not an executable file."
            )
        } else if c11Resolved == nil {
            status = .missing
            notes.append(
                "`c11` is not on PATH. The shell integration's _cmux_fix_path may not have run yet."
            )
        } else if let bundled, let c11Resolved {
            if pathsAgree(bundled, c11Resolved) {
                status = .ok
            } else {
                status = .mismatch
                notes.append(
                    "`c11` on PATH (\(c11Resolved)) is not the active bundle's CLI (\(bundled))."
                )
            }
        } else {
            // Defensive: every branch above should have been taken.
            status = .missing
        }

        if let cmuxResolved, let bundled, !pathsAgree(cmuxResolved, bundled) {
            // The contract from Resources/welcome.md is intentional: c11 does
            // not claim the `cmux` name on PATH. Surface where `cmux`
            // currently resolves so the operator can see that — confusion
            // about "which cmux am I running" is the audit's motivating case.
            notes.append(
                "`cmux` on PATH (\(cmuxResolved)) is upstream/unrelated to the active c11 bundle. This is intentional; see Resources/welcome.md."
            )
        }

        return CLIResolutionSnapshot(
            bundledCliPath: bundled,
            c11OnPath: c11Resolved,
            cmuxOnPath: cmuxResolved,
            bundledCliVersion: bundledVersion,
            c11OnPathVersion: c11Version,
            pathEntries: pathEntries,
            pathFixApplied: pathFixApplied,
            status: status,
            notes: notes
        )
    }

    /// Two paths agree if their canonical forms (path normalization only —
    /// `..` and trailing-slash resolution) are equal. We deliberately do
    /// NOT resolve symlinks: `URL.standardizedFileURL` does not call
    /// `realpath`. For `Resources/bin/c11` in a real bundle this is fine
    /// (no symlinks), but if a future deployment introduces one, this
    /// helper will report `mismatch` until updated.
    private static func pathsAgree(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let l = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let r = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return l == r
    }
}

// MARK: - Rendering

extension CLIResolutionSnapshot {
    /// Human-readable table form. Keep field labels stable: copy-paste from
    /// this output ends up in incident reports and chat threads.
    public func renderText() -> String {
        var lines: [String] = []
        lines.append("c11 doctor — CLI resolution")
        lines.append("")
        lines.append("status:               \(status.rawValue)")
        lines.append("bundled_cli_path:     \(bundledCliPath ?? "<unset>")")
        lines.append("c11_on_path:          \(c11OnPath ?? "<not found>")")
        lines.append("cmux_on_path:         \(cmuxOnPath ?? "<not found>")")
        lines.append("bundled_cli_version:  \(bundledCliVersion ?? "<unknown>")")
        lines.append("c11_on_path_version:  \(c11OnPathVersion ?? "<unknown>")")
        lines.append("path_fix_applied:     \(pathFixApplied ? "yes" : "no")")
        if !notes.isEmpty {
            lines.append("")
            lines.append("notes:")
            for note in notes {
                lines.append("  - \(note)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Stable, lowercase-snake JSON shape for `--json`. Field names match
    /// `CLIResolutionField` and `c11 health --json` conventions.
    public func toJSONDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            CLIResolutionField.status.rawValue: status.rawValue,
            CLIResolutionField.pathFixApplied.rawValue: pathFixApplied,
            CLIResolutionField.path.rawValue: pathEntries,
            CLIResolutionField.notes.rawValue: notes,
        ]
        if let bundledCliPath {
            dict[CLIResolutionField.bundledCliPath.rawValue] = bundledCliPath
        }
        if let c11OnPath {
            dict[CLIResolutionField.c11OnPath.rawValue] = c11OnPath
        }
        if let cmuxOnPath {
            dict[CLIResolutionField.cmuxOnPath.rawValue] = cmuxOnPath
        }
        if let bundledCliVersion {
            dict[CLIResolutionField.bundledCliVersion.rawValue] = bundledCliVersion
        }
        if let c11OnPathVersion {
            dict[CLIResolutionField.c11OnPathVersion.rawValue] = c11OnPathVersion
        }
        return dict
    }
}

// MARK: - Argument parsing

public enum DoctorCLIError: Error, CustomStringConvertible {
    case unknownFlag(String)

    public var description: String {
        switch self {
        case .unknownFlag(let f):
            return "unknown flag '\(f)'"
        }
    }
}

public struct DoctorCLIOptions {
    public let json: Bool

    public init(json: Bool) {
        self.json = json
    }
}

public func parseDoctorCLIArgs(_ args: [String]) throws -> DoctorCLIOptions {
    var json = false
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--json":
            json = true
            i += 1
        case "-h", "--help":
            // Help is dispatched upstream via dispatchSubcommandHelp; tolerate here.
            i += 1
        default:
            throw DoctorCLIError.unknownFlag(arg)
        }
    }
    return DoctorCLIOptions(json: json)
}

// MARK: - Real-world helpers (CLI side)

/// Look up an executable on PATH the way `command -v` does. Returns the
/// absolute path or nil. Walks the supplied PATH entries in order; the
/// caller controls PATH through the inputs struct so tests stay pure.
public func defaultCommandLookup(_ name: String, environment: [String: String]) -> String? {
    let pathRaw = environment["PATH"] ?? ""
    for entry in pathRaw.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = (String(entry) as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Spawn `<path> --version` and return the first line of stdout. Bounded
/// to a 1-second deadline so a hung binary cannot stall `c11 doctor`.
public func defaultVersionLookup(_ path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }

    let deadline = Date(timeIntervalSinceNow: 1.0)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        try? process.waitUntilExit()
        return nil
    }

    guard let data = try? pipe.fileHandleForReading.readToEnd() else {
        return nil
    }
    let raw = String(data: data, encoding: .utf8) ?? ""
    return raw.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
}
