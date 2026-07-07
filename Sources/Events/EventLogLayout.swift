import Foundation

/// Pure path builders for the c11 events stream (C11-163). No I/O happens here
/// beyond the read-only directory listing used to resolve the newest instance
/// log — path math and filename derivation only. Compiled into **both** the app
/// target (the `EventLog` writer) and the `c11-cli` target (the `c11 events
/// tail` reader), so it must stay free of any app-only imports.
///
/// Layout on disk:
///
///     <state>/events/
///         events-<instance>.ndjson       (current per-instance log)
///         events-<instance>.ndjson.1      (one rolled generation, EVT-4)
///
/// The log is **per-instance** (EVT-1): each running c11 process writes its own
/// file, keyed by `<launch-tag-or-bundle>-<pid>`. This is deliberate — the state
/// dir is shared, and dogfooders run a tagged debug build alongside the prod
/// build (see `StateDirectoryMigration`), so a single shared file would suffer
/// non-atomic multi-writer append corruption. Per-instance files sidestep that
/// and let `seq` reset cleanly per boot.
///
/// See `spec/event-envelope.v1.schema.json` for the line format and
/// `skills/c11/references/events.md` for the consumer contract.
enum EventLogLayout {

    // MARK: - Names

    /// Directory name under `~/Library/Application Support/`. Mirrors
    /// `MailboxLayout.stateDirectoryName` / `SocketControlSettings
    /// .socketDirectoryName`; duplicated here so the CLI target resolves the
    /// state root without a cross-target import.
    static let stateDirectoryName = "c11"

    /// Subdirectory of the state root that holds the event logs.
    static let eventsDirectoryName = "events"

    /// Prefix + extension for a per-instance current log: `events-<id>.ndjson`.
    static let logFilePrefix = "events-"
    static let logFileExtension = "ndjson"

    /// Suffix appended to the rolled generation: `events-<id>.ndjson.1`.
    static let rolledGenerationSuffix = "1"

    // MARK: - Errors

    enum Error: Swift.Error, Equatable {
        case stateDirectoryUnavailable
        case noInstanceLogFound
    }

    // MARK: - State root

    /// Resolves the c11 state root (default:
    /// `~/Library/Application Support/c11`). Mirrors
    /// `MailboxLayout.defaultStateURL` exactly, including the legacy→current
    /// migration latch, so the events tree lands beside the mailbox tree.
    static func defaultStateURL(fileManager: FileManager = .default) throws -> URL {
        StateDirectoryMigration.ensureMigrated(fileManager: fileManager)
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw Error.stateDirectoryUnavailable
        }
        return appSupport.appendingPathComponent(stateDirectoryName, isDirectory: true)
    }

    // MARK: - Path builders

    /// `<state>/events/`.
    static func eventsDirectoryURL(state: URL) -> URL {
        state.appendingPathComponent(eventsDirectoryName, isDirectory: true)
    }

    /// Filename for a given instance id: `events-<instance>.ndjson`.
    static func logFileName(instance: String) -> String {
        "\(logFilePrefix)\(sanitizeInstance(instance)).\(logFileExtension)"
    }

    /// Current log for an instance: `<state>/events/events-<instance>.ndjson`.
    static func logURL(state: URL, instance: String) -> URL {
        eventsDirectoryURL(state: state)
            .appendingPathComponent(logFileName(instance: instance), isDirectory: false)
    }

    /// Rolled generation for a current log: append `.1` to the current path.
    static func rolledURL(for currentLog: URL) -> URL {
        URL(fileURLWithPath: currentLog.path + "." + rolledGenerationSuffix)
    }

    // MARK: - Instance id

    /// Builds the per-instance discriminator `<tag-or-bundle>-<pid>`. `pid` is
    /// the only guaranteed-unique component; the tag/bundle prefix keeps the
    /// filename legible when a dogfooder eyeballs the events dir.
    static func makeInstanceId(
        tag: String? = ProcessInfo.processInfo.environment["C11_TAG"],
        bundleId: String? = Bundle.main.bundleIdentifier,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> String {
        let label: String
        if let tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            label = tag
        } else if let bundleId, !bundleId.isEmpty {
            label = bundleId
        } else {
            label = "c11"
        }
        return sanitizeInstance("\(label)-\(pid)")
    }

    /// Restricts an instance component to filename-safe characters.
    static func sanitizeInstance(_ raw: String) -> String {
        let mapped = raw.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" {
                return ch
            }
            return "_"
        }
        let cleaned = String(mapped)
        return cleaned.isEmpty ? "c11" : cleaned
    }

    // MARK: - Reader resolution (CLI)

    /// Resolves the log a consumer should tail when no explicit instance is
    /// given: the newest current log in `<state>/events/` by modification time.
    /// A `c11 events tail` with no running app still works — the file is the
    /// contract. Rolled `.1` files are ignored here (the follow loop drains
    /// them on rotation detection).
    static func newestLogURL(state: URL, fileManager: FileManager = .default) throws -> URL {
        let dir = eventsDirectoryURL(state: state)
        let entries = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidates = entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(logFilePrefix)
                && name.hasSuffix("." + logFileExtension)
        }
        guard !candidates.isEmpty else { throw Error.noInstanceLogFound }

        let sorted = candidates.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return l > r
        }
        return sorted[0]
    }
}
