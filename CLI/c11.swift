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

struct CLIError: Error, CustomStringConvertible {
    let message: String
    let structuredResponse: [String: Any]?

    init(message: String, structuredResponse: [String: Any]? = nil) {
        self.message = message
        self.structuredResponse = structuredResponse
    }

    var description: String { message }
}

/// Input-only aliases for the `C11_*` environment namespace, from the 11mux
/// rename: the app exports `C11_*` and `CMUX_*` only, and reads `MUX11_*`,
/// `ELEVENMUX_*` and `MUXELEVEN_*` as fallbacks. `11MUX_*` cannot exist: a shell
/// variable name cannot start with a digit. Order is precedence when two
/// aliases disagree.
let c11EnvAliasPrefixes = ["MUX11_", "ELEVENMUX_", "MUXELEVEN_"]

/// The `C11_*` and `CMUX_*` values that alias-prefixed variables in `environment`
/// fill in, and one notice per name whose aliases disagree.
///
/// Fill-only, like `CMUX_*` is for `C11_*`: an alias never replaces a set
/// `C11_*` or `CMUX_*` value. Launchers and every panel set those explicitly,
/// so a stray exported alias must not redirect them (the C11-155 inheritance
/// hazard). Empty alias values are ignored. Pure; the caller applies the result.
func c11EnvAliasOverrides(in environment: [String: String]) -> (values: [String: String], conflicts: [String]) {
    func isSet(_ key: String) -> Bool {
        !(environment[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var chosen: [String: (key: String, value: String)] = [:]
    var conflicts: [String] = []
    for prefix in c11EnvAliasPrefixes {
        for key in environment.keys.sorted() where key.hasPrefix(prefix) && key.count > prefix.count && isSet(key) {
            let value = environment[key] ?? ""
            let suffix = String(key.dropFirst(prefix.count))
            if let earlier = chosen[suffix] {
                if earlier.value != value {
                    conflicts.append("\(earlier.key) and \(key) disagree; using \(earlier.key)")
                }
            } else {
                chosen[suffix] = (key, value)
            }
        }
    }
    var values: [String: String] = [:]
    for (suffix, pick) in chosen where !isSet("C11_" + suffix) && !isSet("CMUX_" + suffix) {
        values["C11_" + suffix] = pick.value
        values["CMUX_" + suffix] = pick.value
    }
    return (values, conflicts)
}

/// Applies `c11EnvAliasOverrides` to this process's environment, then unsets
/// the aliases so child processes inherit only the canonical names. Running it
/// again is a no-op.
func applyC11EnvAliasOverrides() {
    let environment = ProcessInfo.processInfo.environment
    let overrides = c11EnvAliasOverrides(in: environment)
    for (key, value) in overrides.values {
        setenv(key, value, 1)
    }
    for key in environment.keys where c11EnvAliasPrefixes.contains(where: { key.hasPrefix($0) }) {
        unsetenv(key)
    }
    for notice in overrides.conflicts {
        // fputs, not FileHandle: a closed stderr must not raise an ObjC exception.
        fputs("c11: \(notice)\n", stderr)
    }
}

// Mirrors CMUX_* ↔ C11_* env vars so callers can use either prefix, after
// applying any MUX11_* / ELEVENMUX_* / MUXELEVEN_* input aliases.
// Why: binary rename from `cmux` to `c11` keeps both namespaces live during transition.
func mirrorC11CmuxEnv() {
    applyC11EnvAliasOverrides()
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
    // A terminal started by an app that predates the panel names exports only the
    // TAB / SURFACE twins: fill the panel names from them, per prefix.
    let mirrored = ProcessInfo.processInfo.environment
    for prefix in ["C11_", "CMUX_"] {
        for suffix in ["_ID", "_NUM"] {
            let panelKey = prefix + "PANEL" + suffix
            let current = mirrored[panelKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current.isEmpty else { continue }
            for twin in ["TAB", "SURFACE"] {
                if let value = mirrored[prefix + twin + suffix],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    setenv(panelKey, value, 1)
                    break
                }
            }
        }
    }
}

struct CMUXCLI {
    let args: [String]
}

@main
struct CMUXTermMain {
    static func main() {
        // CLI tools should ignore SIGPIPE so closed stdout pipes do not terminate the process.
        _ = signal(SIGPIPE, SIG_IGN)
        NSSetUncaughtExceptionHandler { exception in
            // Belt-and-braces only: an ObjC exception raised through Swift frames aborts
            // before reaching here (see `c11SafeWrite`), so the real guarantee is that
            // CLI writes go through `c11SafeWrite` and never raise in the first place.
            if exception.name == .fileHandleOperationException {
                exit(0)
            }
            FileHandle.standardError.c11SafeWrite(
                Data("c11: uncaught exception \(exception.name): \(exception.reason ?? "(none)")\n".utf8)
            )
            exit(1)
        }
        mirrorC11CmuxEnv()
        let cli = CMUXCLI(args: CommandLine.arguments)
        do {
            try cli.run()
        } catch {
            FileHandle.standardError.c11SafeWrite(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
}
