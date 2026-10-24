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

extension CMUXCLI {

    static let debugLastSocketHintPath = "/tmp/cmux-last-socket-path"

    static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func pathIsSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    static func debugSocketPathFromHintFile() -> String? {
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

    static func defaultSocketPath(environment: [String: String]) -> String {
        for key in ["C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
            if let explicit = normalizedEnvValue(environment[key]) {
                return explicit
            }
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

    /// Print one stderr line attributing an auto-discovered socket so the
    /// operator can see they are not on the implicit default. Suppressed by
    /// `C11_QUIET_DISCOVERY=1` (any non-empty, non-"0" value). The value
    /// names both the picked socket and, when known, the source it came from
    /// (the `last-socket-path` pointer file or a `CMUX_TAG=` env var).
    func emitAutoDiscoveryNotice(
        resolvedPath: String,
        environment: [String: String]
    ) {
        if let suppress = environment["C11_QUIET_DISCOVERY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !suppress.isEmpty, suppress != "0" {
            return
        }
        let line: String
        if let source = CLISocketPathResolver.discoverySourceHint(
            resolvedPath: resolvedPath,
            environment: environment
        ) {
            line = String(
                localized: "cli.socket.autoDiscoveredWithSource",
                defaultValue: "c11: using socket \(resolvedPath) (auto-discovered from \(source))"
            )
        } else {
            line = String(
                localized: "cli.socket.autoDiscovered",
                defaultValue: "c11: using socket \(resolvedPath) (auto-discovered)"
            )
        }
        FileHandle.standardError.c11SafeWrite(Data((line + "\n").utf8))
    }
}
