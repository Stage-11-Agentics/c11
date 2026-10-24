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
