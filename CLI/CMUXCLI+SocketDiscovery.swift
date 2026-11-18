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

    static func normalizedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
