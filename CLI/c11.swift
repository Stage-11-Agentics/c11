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

/// Input-only aliases for the `C11_*` environment namespace (the 11mux rename,
/// `docs/11mux-rename-plan.md`, D3). The app exports `C11_*` and `CMUX_*` only;
/// `MUX11_*`, `ELEVENMUX_*` and `MUXELEVEN_*` are read as overrides. `11MUX_*`
/// cannot exist: a shell variable name cannot start with a digit.
/// Order is precedence: an earlier prefix wins when two aliases disagree.
let c11EnvAliasPrefixes = ["MUX11_", "ELEVENMUX_", "MUXELEVEN_"]

/// The `C11_*` and `CMUX_*` values that alias-prefixed variables in `environment`
/// ask for, and one notice per name whose aliases disagree.
///
/// A set alias always wins over an existing `C11_*`/`CMUX_*` value: the app never
/// exports an alias, so one can only come from a person or script asking for an
/// override. Pure; the caller applies the result.
func c11EnvAliasOverrides(in environment: [String: String]) -> (values: [String: String], conflicts: [String]) {
    var chosen: [String: (key: String, value: String)] = [:]
    var conflicts: [String] = []
    for prefix in c11EnvAliasPrefixes {
        for key in environment.keys.sorted() where key.hasPrefix(prefix) && key.count > prefix.count {
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
    for (suffix, pick) in chosen {
        values["C11_" + suffix] = pick.value
        values["CMUX_" + suffix] = pick.value
    }
    return (values, conflicts)
}

/// Applies `c11EnvAliasOverrides` to this process's environment.
func applyC11EnvAliasOverrides() {
    let overrides = c11EnvAliasOverrides(in: ProcessInfo.processInfo.environment)
    for (key, value) in overrides.values {
        setenv(key, value, 1)
    }
    for notice in overrides.conflicts {
        FileHandle.standardError.write(Data("c11: \(notice)\n".utf8))
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
