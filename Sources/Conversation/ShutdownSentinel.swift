import Foundation

/// Inverted dirty/clean shutdown sentinel for crash-recovery detection.
///
/// **Semantics** (from C11-24 architecture doc §"Crash recovery"):
/// - At launch, write `~/.c11/runtime/shutdown.<bundle_id>.dirty` containing
///   the launch timestamp.
/// - During termination: forced final scrape across all surfaces, write the
///   snapshot synchronously, **only after both succeed** replace the dirty
///   file with `~/.c11/runtime/shutdown.<bundle_id>.clean` containing the
///   clean-shutdown timestamp.
/// - On next launch, read prior-shutdown sentinel:
///   - `.clean` present → clean shutdown.
///   - `.dirty` present (or both missing) → crashed/sleep-killed/power-died/
///     kernel-panicked between launch and final-snapshot completion.
///
/// Bundle-scoping prevents debug/release/concurrent c11 instances from
/// cross-contaminating each other's crash markers (debug builds use a
/// distinct bundle id).
enum ShutdownSentinel {
    enum PriorShutdown: Equatable {
        case clean(at: Date)
        case dirty(launchedAt: Date?)
        case missing
        case unreadable
        case invalid
    }

    private enum MarkerState {
        case missing
        case valid(Date)
        case unreadable
        case invalid
    }

    /// Default sentinel directory: `~/.c11/runtime/`. Created on first
    /// write; missing dir on recovery read = treat as crash.
    static func defaultDirectory() -> URL? {
        guard let home = FileManager.default
            .homeDirectoryForCurrentUser as URL? else {
            return nil
        }
        return home
            .appendingPathComponent(".c11", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
    }

    /// Resolve the dirty sentinel URL for a given bundle id.
    static func dirtyURL(
        bundleId: String,
        directory: URL? = nil
    ) -> URL? {
        guard let dir = directory ?? defaultDirectory() else { return nil }
        let safe = sanitiseBundleId(bundleId)
        return dir.appendingPathComponent("shutdown.\(safe).dirty", isDirectory: false)
    }

    /// Resolve the clean sentinel URL for a given bundle id.
    static func cleanURL(
        bundleId: String,
        directory: URL? = nil
    ) -> URL? {
        guard let dir = directory ?? defaultDirectory() else { return nil }
        let safe = sanitiseBundleId(bundleId)
        return dir.appendingPathComponent("shutdown.\(safe).clean", isDirectory: false)
    }

    /// Inspect prior-shutdown state without mutating it. Caller is
    /// responsible for using the result before overwriting at this
    /// launch.
    static func readPriorShutdown(
        bundleId: String,
        directory: URL? = nil,
        fileManager: FileManager = .default,
        readData: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> PriorShutdown {
        guard let cleanURL = cleanURL(bundleId: bundleId, directory: directory),
              let dirtyURL = dirtyURL(bundleId: bundleId, directory: directory) else {
            return .missing
        }
        let clean = readMarker(cleanURL, fileManager: fileManager, readData: readData)
        let dirty = readMarker(dirtyURL, fileManager: fileManager, readData: readData)

        // A valid clean marker wins the intentional two-marker promotion
        // window. Invalid or unreadable clean data cannot mask dirty.
        if case .valid(let at) = clean { return .clean(at: at) }
        if case .valid(let at) = dirty { return .dirty(launchedAt: at) }
        if case .unreadable = clean { return .unreadable }
        if case .unreadable = dirty { return .unreadable }
        if case .invalid = clean { return .invalid }
        if case .invalid = dirty { return .invalid }
        return .missing
    }

    /// Only a valid readable clean marker authorizes clean restore. Explicit
    /// no-resume policy wins, and every uncertain state fails closed dirty.
    static func resolveRecoveryMode(
        explicitNoResume: Bool,
        priorShutdown: PriorShutdown
    ) -> ResumeRecoveryMode {
        if explicitNoResume { return .noResume }
        if case .clean = priorShutdown { return .clean }
        return .dirty
    }

    /// Write the dirty sentinel at app launch. Best-effort: a missing
    /// `~/.c11/runtime/` is created here. Errors are swallowed (returned
    /// boolean indicates success) — sentinel writes must NEVER block
    /// launch.
    @discardableResult
    static func writeDirty(
        bundleId: String,
        at: Date = Date(),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let dir = directory ?? defaultDirectory(),
              let url = dirtyURL(bundleId: bundleId, directory: dir) else {
            return false
        }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            // Remove any stale clean sentinel from a prior session so the
            // next-launch read distinguishes "this run is in flight" from
            // "this run terminated cleanly."
            if let cleanURL = cleanURL(bundleId: bundleId, directory: dir),
               fileManager.fileExists(atPath: cleanURL.path) {
                try? fileManager.removeItem(at: cleanURL)
            }
            let payload = "\(at.timeIntervalSince1970)\n"
            try payload.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Promote dirty → clean. ONLY called after the forced final scrape
    /// AND the snapshot write have both succeeded. The two operations
    /// must complete before this is reached or the false-clean window
    /// the original design suffered from reappears.
    @discardableResult
    static func promoteToClean(
        bundleId: String,
        at: Date = Date(),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let dir = directory ?? defaultDirectory(),
              let cleanURL = cleanURL(bundleId: bundleId, directory: dir) else {
            return false
        }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload = "\(at.timeIntervalSince1970)\n"
            try payload.write(to: cleanURL, atomically: true, encoding: .utf8)
            // Remove the dirty marker last so a partially-completed
            // promote (interrupted between writeClean and removeDirty)
            // still classifies as a clean shutdown on next launch (the
            // read prefers `.clean` when present).
            if let dirtyURL = dirtyURL(bundleId: bundleId, directory: dir),
               fileManager.fileExists(atPath: dirtyURL.path) {
                try? fileManager.removeItem(at: dirtyURL)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private static func sanitiseBundleId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown" }
        let component = trimmed.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        // Preserve normal reverse-DNS dots while removing every path-
        // traversal-shaped run. The value is used as one filename component,
        // so no `..` sequence may survive sanitisation.
        return component.replacingOccurrences(
            of: "\\.{2,}",
            with: "_",
            options: .regularExpression
        )
    }

    private static func readMarker(
        _ url: URL,
        fileManager: FileManager,
        readData: (URL) throws -> Data
    ) -> MarkerState {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try readData(url)
        } catch {
            return .unreadable
        }
        guard let text = String(data: data, encoding: .utf8) else { return .invalid }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let interval = TimeInterval(trimmed), interval.isFinite else { return .invalid }
        return .valid(Date(timeIntervalSince1970: interval))
    }
}
