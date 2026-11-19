import Foundation
import Darwin

/// `c11 show` on the CLI side (C11H-228): what the agent asked to show,
/// resolved on the machine the CLI runs on, and the relay's durable record
/// (`ShowRecord`) kept in that machine's hc document store. Shared with the
/// app target only so tests can reach it; the app never calls it.
enum ShowCLIRecord {
    /// A refusal the CLI prints as `<code>: <message>` and exits 1.
    struct Failure: Error, Equatable, CustomStringConvertible {
        let code: String
        let message: String
        var description: String { "\(code): \(message)" }
    }

    // MARK: - Target

    /// A URL is `<scheme>://…`; anything else is a path. A URL is never
    /// resolved here: c11 applies URL policy.
    static func isURL(_ raw: String) -> Bool {
        raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
    }

    /// `~` and `~/x` against `home`, then absolute against `cwd`.
    static func absolute(_ raw: String, cwd: String, home: String?) -> String {
        var path = raw
        if let home, !home.isEmpty {
            if path == "~" { path = home }
            else if path.hasPrefix("~/") { path = (home.hasSuffix("/") ? String(home.dropLast()) : home) + String(path.dropFirst()) }
        }
        if !path.hasPrefix("/") { path = (cwd.hasSuffix("/") ? cwd : cwd + "/") + path }
        return path
    }

    /// The path with every symlink resolved, or nil when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private enum Kind { case file(Int64), directory, other }

    private static func kind(_ path: String) -> Kind? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeDirectory { return .directory }
        guard type == .typeRegular else { return .other }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64((attributes[.size] as? UInt64) ?? 0)
        return .file(size)
    }

    /// What `c11 show <target> [--dir <dir>]` names. A path must be an
    /// existing regular file of at most `ShowSpec.maxBytes`; `--dir` an
    /// existing folder; both are absolute with symlinks resolved.
    static func resolve(target: String, dir: String?, cwd: String, home: String?) throws -> ShowSourceSpec {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure(code: ShowSpec.Code.badSource, message: String(localized: "show.cli.error.noTarget",
                defaultValue: "c11 show needs a file path or a URL"))
        }
        if isURL(trimmed) {
            if dir != nil {
                throw Failure(code: ShowSpec.Code.badDir, message: String(localized: "show.cli.error.dirWithURL",
                    defaultValue: "--dir applies to a file path, not a URL"))
            }
            return .url(trimmed)
        }
        let path = absolute(trimmed, cwd: cwd, home: home)
        guard let real = realPath(path), let found = kind(real) else {
            throw Failure(code: ShowSpec.Code.notFound, message: String(format: String(localized: "show.cli.error.notFound",
                defaultValue: "no such file: %@"), path))
        }
        guard case .file(let size) = found else {
            throw Failure(code: ShowSpec.Code.notFile, message: String(format: String(localized: "show.cli.error.notFile",
                defaultValue: "not a regular file: %@"), real))
        }
        guard size <= Int64(ShowSpec.maxBytes) else {
            let megabytes = String(format: "%.1f", Double(size) / 1_048_576)
            throw Failure(code: ShowSpec.Code.tooLarge, message: String(format: String(localized: "show.cli.error.tooLarge",
                defaultValue: "%@ is %@ MB, %@"), real, megabytes, ShowSpec.tooLargeMessage()))
        }
        var realDir: String?
        if let dir {
            let absoluteDir = absolute(dir, cwd: cwd, home: home)
            guard let resolved = realPath(absoluteDir), case .directory? = kind(resolved) else {
                throw Failure(code: ShowSpec.Code.badDir, message: String(format: String(localized: "show.cli.error.badDir",
                    defaultValue: "not an existing folder: %@"), absoluteDir))
            }
            realDir = resolved
        }
        return .path(real, dir: realDir, home: home)
    }

    /// What `c11 show close <target>` names. The file may be gone, so a path
    /// that no longer exists is closed by its absolute form.
    static func resolveForClose(target: String, dir: String?, cwd: String, home: String?) -> ShowSourceSpec {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if isURL(trimmed) { return .url(trimmed) }
        let path = absolute(trimmed, cwd: cwd, home: home)
        let realDir = dir.map { absolute($0, cwd: cwd, home: home) }.map { realPath($0) ?? $0 }
        return .path(realPath(path) ?? (path as NSString).standardizingPath, dir: realDir, home: home)
    }

    /// The `--wait` seconds, clamped; nil input is the default.
    static func waitSeconds(_ raw: String?) throws -> Double {
        guard let raw else { return ShowSpec.defaultWaitSeconds }
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            throw Failure(code: "invalid_params", message: String(localized: "show.cli.error.wait",
                defaultValue: "--wait needs a number of seconds"))
        }
        return min(max(value, ShowSpec.waitSecondsRange.lowerBound), ShowSpec.waitSecondsRange.upperBound)
    }

    // MARK: - Relay

    /// c11 wrote its heartbeat on this machine recently, so a call now is
    /// likely to be claimed.
    static func isFresh(_ seen: Any?, now: Int64) -> Bool {
        guard let link = C11Relay.linkView(seen, now: now) else { return false }
        return link.answered < C11Relay.seenFreshSeconds
    }

    /// The call failed because c11 could not be reached over the machine
    /// link (nobody claimed it; nothing ran). The relayed CLI reports that as
    /// a `relay_unreachable:` message (`C11RelayCallError.unreachable`).
    /// A refusal, a show_* error, a busy relay or an unknown outcome is not.
    static func isUnreachable(_ error: Error) -> Bool {
        if case C11RelayCallError.unreachable = error { return true }
        return String(describing: error).hasPrefix("relay_unreachable:")
    }

    /// The outcome may be that c11 ran the call: leave the record as it is.
    static func outcomeMayHaveRun(_ error: Error) -> Bool {
        if let relay = error as? C11RelayCallError {
            return relay == .outcomeUnknown || relay == .replyUnverified
        }
        let text = String(describing: error)
        return text.hasPrefix("relay_outcome_unknown:") || text.hasPrefix("relay_reply_unverified:")
    }

    static let conflictRetries = 3

    /// Reads, changes and compare-and-sets the panel's record, retrying a
    /// lost race. `change` returns false when there is nothing to write.
    static func mutate(_ store: C11RelayDocStore, panel: UUID, _ change: (inout ShowRecord) -> Bool) throws {
        let name = ShowRecord.name(panel: panel)
        for attempt in 0..<conflictRetries {
            let (value, version) = try store.get(name)
            var record = ShowRecord(panel: panel, value: value) ?? ShowRecord(panel: panel)
            guard change(&record) else { return }
            do {
                _ = try store.set(name, value: record.dictionary, version: version)
                return
            } catch C11RelayStoreError.conflict where attempt + 1 < conflictRetries {
                continue
            }
        }
    }

    /// The away line, the same for show and close.
    static func awayLine() -> String {
        String(localized: "show.cli.away", defaultValue: "OK recorded; c11 is away; it will load when the Mac wakes")
    }

    static func awayCloseLine() -> String {
        String(localized: "show.cli.awayClose", defaultValue: "OK closed in record; c11 is away")
    }

    static func unrecorded(_ error: Error) -> Failure {
        let reason: String
        switch error {
        case C11RelayStoreError.unavailable(let detail): reason = detail
        case C11RelayStoreError.conflict:
            reason = String(localized: "show.cli.error.recordConflict", defaultValue: "the record kept changing")
        default: reason = String(describing: error)
        }
        return Failure(code: "show_unrecorded", message: String(format: String(localized: "show.cli.error.unrecorded",
            defaultValue: "c11 is away and this machine could not keep the record (%@)"), reason))
    }

    enum Outcome {
        /// c11 answered; the `show.open` / `show.close` result.
        case answered([String: Any])
        /// c11 is away; the record holds it.
        case recorded
    }

    /// `c11 show` through the relay: resolve the target here (nothing is
    /// written for a target that fails), then record the show in this
    /// machine's hc store and ask c11 when its heartbeat is fresh. `call`
    /// sends `show.open` for the resolved source with the record id (nil
    /// when the record could not be written).
    static func openRelayed(target: String, dir: String?, cwd: String, home: String?,
                            store: C11RelayDocStore, panel: UUID,
                            credential: C11RelayAuth.Credential? = nil,
                            now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                            makeID: () -> String = { UUID().uuidString.lowercased() },
                            call: (_ source: ShowSourceSpec, _ recordID: String?) throws -> [String: Any]) throws -> Outcome {
        let source = try resolve(target: target, dir: dir, cwd: cwd, home: home)
        let fresh = isFresh((try? store.get(C11Relay.seenName))?.value, now: now)
        let id = makeID()
        var writeError: Error?
        do {
            // Signed with the terminal's relay credential: c11 surfaces only
            // entries this terminal signed (any process can write a document).
            try mutate(store, panel: panel) {
                $0.upsert(id: id, source: source, at: now, state: fresh ? .live : .waiting, credential: credential)
                return true
            }
        } catch {
            writeError = error
        }
        guard fresh else {
            if let writeError { throw unrecorded(writeError) }
            return .recorded
        }
        let recorded = writeError == nil
        do {
            return .answered(try call(source, recorded ? id : nil))
        } catch {
            if isUnreachable(error) {
                guard recorded else { throw unrecorded(error) }
                do {
                    try mutate(store, panel: panel) { $0.setState(.waiting, id: id, signer: credential.map(ShowEntrySigner.init)) }
                } catch {
                    throw unrecorded(error)
                }
                return .recorded
            }
            if recorded, !outcomeMayHaveRun(error) {
                // Refused: the show never happened, so it leaves no entry.
                try? mutate(store, panel: panel) { record in
                    let before = record.entries.count
                    record.entries.removeAll { $0.id == id }
                    return record.entries.count != before
                }
            }
            throw error
        }
    }

    /// Whether `entry` is one `show close <source>` names: the same kind and
    /// target, and the same `--dir` when one was given.
    static func closes(_ entry: ShowRecord.Entry, source: ShowSourceSpec?) -> Bool {
        ShowSourceSpec.closes(source, entry.source)
    }

    /// `c11 show close` through the relay: mark the record's entries closed
    /// (best effort while c11 answers), then ask c11 when it is fresh.
    static func closeRelayed(source: ShowSourceSpec?, store: C11RelayDocStore, panel: UUID,
                             now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                             call: () throws -> [String: Any]) throws -> Outcome {
        let fresh = isFresh((try? store.get(C11Relay.seenName))?.value, now: now)
        var writeError: Error?
        do {
            try mutate(store, panel: panel) { record in
                var changed = false
                for index in record.entries.indices where closes(record.entries[index], source: source)
                    && record.entries[index].state != .closed {
                    record.entries[index].state = .closed
                    changed = true
                }
                return changed
            }
        } catch {
            writeError = error
        }
        guard fresh else {
            if let writeError { throw unrecorded(writeError) }
            return .recorded
        }
        do {
            return .answered(try call())
        } catch where isUnreachable(error) {
            if let writeError { throw unrecorded(writeError) }
            return .recorded
        }
    }
}
