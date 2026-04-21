import Foundation

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
