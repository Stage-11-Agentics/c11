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

#if DEBUG
/// DEBUG-only check that the pre-connect flag declarations match the parsers.
/// With `C11_CLI_FLAG_READ_LOG=<path>` set, the shared option helpers record
/// every flag name a handler queries after preflight (present in argv or not),
/// and the CLI writes those names beside the names preflight accepted, as one
/// JSON object, when the process exits. `CLIFlagDeclarationTests` fails on any
/// name a parser reads that its declaration does not accept.
enum CLIFlagReadLog {
    private static let path = ProcessInfo.processInfo.environment["C11_CLI_FLAG_READ_LOG"]
    private static var armed = false
    private static var suspended = 0
    private static var accepted: [String: Set<String>] = [:]
    private static var arity: [String: String] = [:]
    private static var positionals: [String: Int] = [:]
    private static var queried: Set<String> = []
    private static var registered = false

    static func recordAccepted(command: String, flags: Set<String>, arity: String, positionals: Int) {
        guard path != nil else { return }
        accepted[command, default: []].formUnion(flags)
        self.arity[command] = arity
        self.positionals[command] = positionals
        registerFlush()
    }

    /// Start recording: called once preflight has accepted the argv, so the
    /// declarations' own parsing never counts as a parser read.
    static func arm() {
        guard path != nil else { return }
        armed = true
        registerFlush()
    }

    static func read(_ names: [String]) {
        guard armed, suspended == 0 else { return }
        queried.formUnion(names)
    }

    /// Validation that only rejects malformed values (an empty `--window`)
    /// is not a read of that option.
    static func withoutRecording<T>(_ body: () throws -> T) rethrows -> T {
        suspended += 1
        defer { suspended -= 1 }
        return try body()
    }

    private static func registerFlush() {
        guard !registered else { return }
        registered = true
        atexit { CLIFlagReadLog.flush() }
    }

    static func flush() {
        guard let path else { return }
        let object: [String: Any] = [
            "accepted": accepted.mapValues { $0.sorted() },
            "arity": arity,
            "positionals": positionals,
            "queried": queried.sorted(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
