import Foundation

// C11H-261: Waiting means waiting.
//
// A plain turn end leaves an unread notification, and today every unread
// notification lights Waiting Agent. Many turn ends ask nothing ("Needs you:
// nothing", an agent parked on its own background job). The waiting check
// reads the settled screen once per turn-end notification and, when the
// agent's latest message needs nothing from the operator, records a `done`
// verdict for that notification: it leaves Waiting (count, jump order, tint)
// and is counted by the Done button instead.
//
// Two readers, in order:
// 1. The convention (free, no network, every user): the c11 guide teaches
//    every agent to open its report with `Needs you: nothing` or numbered
//    questions. A `Needs you:` line in the agent's latest message decides.
// 2. Jev (optional): TypeSafe System One, model `jev-latest`, when the
//    convention is silent and a key is set. Fails open: any error, timeout,
//    missing key or disabled setting leaves the notification waiting.
//
// Flags, feed asks (permission prompts, questions), errors and shows are
// deterministic waiting and are never judged.

/// Settings for the waiting check. UserDefaults keys; every default is on.
enum WaitingCheckSettings {
    /// Master switch: judge turn ends and sort finished agents out of Waiting.
    static let enabledKey = "waitingCheck.enabled"
    /// Show the Done button under Waiting in the sidebar.
    static let showDoneButtonKey = "waitingCheck.showDoneButton"
    /// Ask Jev when the convention is silent. Effective only with a key.
    static let jevEnabledKey = "waitingCheck.jevEnabled"
    /// Newline-separated terms. Any screen line containing one (case
    /// insensitive) is withheld whole from a Jev call.
    static let withheldTermsKey = "waitingCheck.withheldTerms"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func showsDoneButton(_ defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults) && (defaults.object(forKey: showDoneButtonKey) as? Bool ?? true)
    }

    static func isJevEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: jevEnabledKey) as? Bool ?? true
    }

    static func withheldTerms(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.string(forKey: withheldTermsKey) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The TypeSafe API key for Jev. Kept in a 0600 file in c11's own
/// Application Support folder, shared by release and tagged builds, not in the
/// Keychain: c11 builds are re-signed on every update and a Keychain item
/// would ask the operator to allow access after each one (nothing in c11 may
/// wait on a click). `TYPESAFE_API_KEY` in the app's environment is a
/// fallback. The key is never logged.
enum JevKeyStore {
    static let fileName = "jev-key"
    static let environmentVariable = "TYPESAFE_API_KEY"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: String??

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("c11", isDirectory: true).appendingPathComponent(fileName)
    }

    /// The key, from the file, else the environment. Cached; `save`/`clear`
    /// refresh it. Any thread.
    static func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let value = loadUncached()
        cached = .some(value)
        return value
    }

    static var hasKey: Bool { read() != nil }

    /// True when the key comes from the file (Settings can clear it).
    static var isStoredInFile: Bool {
        (try? PrivateFileWriter.readPrivateFile(at: fileURL, maxBytes: 4096)).flatMap(normalize) != nil
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        guard let key = normalize(key.data(using: .utf8) ?? Data()) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateFileWriter.write(Data(key.utf8), to: fileURL)
        } catch {
            return false
        }
        lock.lock(); cached = nil; lock.unlock()
        NotificationCenter.default.post(name: .jevKeyDidChange, object: nil)
        return true
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        lock.lock(); cached = nil; lock.unlock()
        NotificationCenter.default.post(name: .jevKeyDidChange, object: nil)
    }

    private static func loadUncached() -> String? {
        if let data = try? PrivateFileWriter.readPrivateFile(at: fileURL, maxBytes: 4096),
           let key = normalize(data) {
            return key
        }
        if let env = ProcessInfo.processInfo.environment[environmentVariable],
           let key = normalize(Data(env.utf8)) {
            return key
        }
        return nil
    }

    private static func normalize(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

extension Notification.Name {
    /// Settings or the key changed; the judge and the sidebar re-read.
    static let waitingCheckConfigurationDidChange = Notification.Name("c11.waitingCheck.configurationDidChange")
    /// The Jev key was saved or cleared (posted only by `JevKeyStore`). The
    /// only event that resets Jev's health and re-judges with the new key.
    static let jevKeyDidChange = Notification.Name("c11.waitingCheck.jevKeyDidChange")
}

/// One judgment of one turn-end notification.
struct WaitingCheckVerdict: Equatable, Sendable {
    enum Outcome: String, Sendable {
        /// The agent needs the operator: stays in Waiting.
        case waiting
        /// The agent's latest message needs nothing: counted by Done.
        case done
    }

    enum Source: String, Sendable {
        /// A `Needs you:` line in the latest message.
        case convention
        case jev
    }

    let notificationID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let outcome: Outcome
    let source: Source
    /// Jev's probability that the agent needs a human; nil for the convention.
    let needsHuman: Double?
    /// Jev's stop kind (`done`, `offering`, ...); nil for the convention.
    let stopKind: String?
    /// The line that decided it, for the hover card and `fleet --json`.
    let quote: String?
    let judgedAt: Date

    var jsonObject: [String: Any] {
        [
            "outcome": outcome.rawValue,
            "source": source.rawValue,
            "needs_human": needsHuman as Any? ?? NSNull(),
            "stop_kind": stopKind as Any? ?? NSNull(),
            "quote": quote as Any? ?? NSNull(),
            "judged_at": ISO8601DateFormatter().string(from: judgedAt),
            "notification_id": notificationID.uuidString,
        ]
    }
}

/// Jev's health, for Settings and `fleet --json`.
enum WaitingCheckJevHealth: Equatable, Sendable {
    /// The Jev setting is off.
    case off
    /// On, but no key is set: the convention alone runs.
    case noKey
    /// On with a key; no call has failed since the last success.
    case live
    /// The last call failed (auth, network, timeout, bad response).
    case failing(since: Date, reason: String)

    var label: String {
        switch self {
        case .off: return "off"
        case .noKey: return "no_key"
        case .live: return "live"
        case .failing: return "failing"
        }
    }
}
