import CryptoKit
import Foundation
import os

/// c11 2.0's first-launch migration (C11H-266). Plan: `notes/c11-2.0/C11H-266-plan.md`.
///
/// - c11h → 2.0 with c11h's terminals alive: 2.0 adopts c11h's folders in place  c11-2.0:legacy
///   through links (2.0 code keeps c11 names) and its hc sessions by name.  c11-2.0:legacy
/// - Later, with nothing adopted alive, or at once when c11h's terminals are gone:  c11-2.0:legacy
///   the staged copy into 2.0's own names (convergence). c11h's files are only read.  c11-2.0:legacy
/// - c11 1.x → 2.0: 1.x already keeps its state under 2.0's names.
/// - Both: c11 1.x's state is moved aside, whole, before anything else.
///
/// One record (`C11MigrationState`) journals every step's intent and completion;
/// every step is idempotent, so any interrupted launch resumes to the same end.
enum C11Migration {
    static let stagingSuffix = ".migrating"
    static let asideSuffix = ".adopted-link"
    static let keptPrefix = "-1.x-kept-"
    static let logFileName = "migration.log"
}

// MARK: - Names

/// Every path the migration reads or writes, from one home directory.
struct C11MigrationLayout: Equatable {
    var home: URL
    var sourceSupportName = "c11h"  // c11-2.0:legacy
    var sourceBundleIdentifier = "com.stage11.c11h"  // c11-2.0:legacy
    var destSupportName = "c11"
    var destBundleIdentifier = "com.stage11.c11"
    /// c11 1.x's release domain and bundle, kept aside on a machine that also had c11h.  c11-2.0:legacy
    var oneXBundleIdentifier = "com.stage11.c11"
    var sourceHCRoot = ".local/share/c11h"  // c11-2.0:legacy
    var sourceHCBase = "c11h"  // c11-2.0:legacy
    var destHCBase = "c11"
    /// c11h's control socket file, which surviving agents' `C11_SOCKET` names.  c11-2.0:legacy
    var sourceSocketName = "c11h.sock"  // c11-2.0:legacy
    /// The c11h app whose helper serves the adopted cores (found at launch).  c11-2.0:legacy
    var sourceApp: String?
    var sourceHomeDirectory = ".c11h"  // c11-2.0:legacy
    var destHomeDirectory = ".c11"

    var appSupport: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    var sourceSupport: URL { appSupport.appendingPathComponent(sourceSupportName, isDirectory: true) }
    var destSupport: URL { appSupport.appendingPathComponent(destSupportName, isDirectory: true) }
    var logsDirectory: URL { home.appendingPathComponent("Library/Logs/\(destSupportName)", isDirectory: true) }

    var sourceSnapshotName: String { "session-\(sourceBundleIdentifier).json" }
    var sourceSnapshot: URL { sourceSupport.appendingPathComponent(sourceSnapshotName) }
    var destSnapshotName: String { "session-\(destBundleIdentifier).json" }
    var sourcePanelAllocations: String { "panel-allocations-\(sourceBundleIdentifier).json" }
    var destPanelAllocations: String { "panel-allocations-\(destBundleIdentifier).json" }

    /// Entries under c11h's Application Support folder that carry over. Sockets,  c11-2.0:legacy
    /// caches and other bundles' files (debug, staging) stay behind.
    static let supportEntries = [
        "session-history", "workspaces", "messages", "journal", "events",
        "agent-configs.json", "agent-launch-stats.json", "agent-launches.jsonl",
        "themes", "relay", "show", "HC", "diagnostics", "model-catalog.tsv", "model-costs.json",
        "jev-key", "socket-control-password",
    ]

    /// Folders 2.0 runs on: while adopted, each is a link into c11h's; converged, a  c11-2.0:legacy
    /// real folder. (home-relative path, link target relative to its parent,
    /// the c11h folder it is staged from)  c11-2.0:legacy
    var switchedFolders: [(path: String, target: String, source: String)] {
        [
            ("Library/Application Support/\(destSupportName)", sourceSupportName, "Library/Application Support/\(sourceSupportName)"),
            (destHomeDirectory, sourceHomeDirectory, sourceHomeDirectory),
            (".c11-snapshots", ".c11h-snapshots", ".c11h-snapshots"),  // c11-2.0:legacy
            (".config/c11", "c11h", ".config/c11h"),  // c11-2.0:legacy
        ]
    }

    /// Per-bundle data (browser profiles, cookies, history), copied to 2.0's bundle
    /// name when 2.0 first takes over. Not linked: each bundle owns its own.
    var bundleDataItems: [(source: String, dest: String)] {
        [
            ("Library/WebKit/\(sourceBundleIdentifier)", "Library/WebKit/\(destBundleIdentifier)"),
            ("Library/HTTPStorages/\(sourceBundleIdentifier)", "Library/HTTPStorages/\(destBundleIdentifier)"),
            ("Library/HTTPStorages/\(sourceBundleIdentifier).binarycookies", "Library/HTTPStorages/\(destBundleIdentifier).binarycookies"),
            ("Library/Application Support/\(sourceBundleIdentifier)", "Library/Application Support/\(destBundleIdentifier)"),
        ]
    }

    /// c11 1.x's home-relative state, moved aside on a machine that has both.
    var oneXItems: [String] {
        switchedFolders.map(\.path) + [
            "Library/WebKit/\(oneXBundleIdentifier)",
            "Library/HTTPStorages/\(oneXBundleIdentifier)",
            "Library/HTTPStorages/\(oneXBundleIdentifier).binarycookies",
            "Library/Application Support/\(oneXBundleIdentifier)",
        ]
    }

    func url(_ rel: String) -> URL { home.appendingPathComponent(rel) }

    /// A directory that is not a symbolic link.
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}

// MARK: - What is on disk

struct C11MigrationInventory: Equatable {
    /// c11h has state to carry (its snapshot or workspace tree).  c11-2.0:legacy
    var legacyState: Bool
    /// c11 1.x has state here (only meaningful before any record exists).
    var oneXState: Bool
    /// c11h's world must stay adopted: a core or holder answers, or a session has a linked machine.  c11-2.0:legacy
    var adoptedWorldAlive: Bool

    static func read(_ layout: C11MigrationLayout, oneXDefaults: [String: Any]?, worldAlive: Bool,
                     fileManager fm: FileManager = .default) -> C11MigrationInventory {
        let legacy = fm.fileExists(atPath: layout.sourceSnapshot.path)
            || fm.fileExists(atPath: layout.sourceSupport.appendingPathComponent("workspaces").path)
        let folders = layout.oneXItems.contains { C11MigrationLayout.isRealDirectory(layout.url($0)) }
        // Settings this migration wrote are never 1.x's.
        let defaults = !(oneXDefaults ?? [:]).isEmpty && oneXDefaults?[C11MigrationDefaults.writtenByKey] == nil
        return C11MigrationInventory(legacyState: legacy, oneXState: folders || defaults, adoptedWorldAlive: worldAlive)
    }
}

// MARK: - Plan

enum C11MigrationDecision: Equatable {
    /// A tagged Debug, staging or nightly build. Never touches the operator's state.
    case skipNonRelease
    /// A running c11h: quit it first (its Quit keeps every terminal), then plan again.  c11-2.0:legacy
    case waitForLegacyApp
    /// A record this launch cannot act on (another bundle's, or unreadable): stop.
    case stop(String)
    /// Finished earlier.
    case alreadyDone
    case fresh
    case inPlace1x
    /// Adopt c11h in place (or finish an adoption under way).  c11-2.0:legacy
    case adopt(keepOneXAside: Bool)
    /// Adopted, and adopted terminals still live.
    case stayAdopted
    /// The staged copy into 2.0's names (or finish one under way).
    case converge(keepOneXAside: Bool, fromAdoption: Bool)
    /// A convergence under way finds the adopted world alive again: undo it.
    case rollBackConvergence
}

enum C11MigrationPlanner {
    /// Release bundle, or a QA launch that opted in for a guest proof.
    static func allowed(bundleIdentifier: String, destBundleIdentifier: String,
                        environment: [String: String]) -> Bool {
        if bundleIdentifier == destBundleIdentifier { return true }
        return C11Identity.isMigrationQALaunch(environment: environment)
    }

    /// `record` is the one durable record (nil when none). A running c11h always  c11-2.0:legacy
    /// waits, whatever the record says.
    /// Reconciliation is the ordinary launch path. A diagnostic hold leaves
    /// adoption in place and refuses to publish an unfinished convergence.
    static func convergeEnabled(environment: [String: String]) -> Bool {
        environment["C11_MIGRATION_CONVERGE"] != "0"
    }

    static func decide(record: C11MigrationState?, inventory i: C11MigrationInventory, legacyRunning: Bool,
                       allowed: Bool, owner: String, convergeEnabled: Bool = true) -> C11MigrationDecision {
        guard allowed else { return .skipNonRelease }
        if legacyRunning { return .waitForLegacyApp }
        guard let record else {
            if i.legacyState {
                return i.adoptedWorldAlive || !convergeEnabled ? .adopt(keepOneXAside: i.oneXState)
                                                               : .converge(keepOneXAside: i.oneXState, fromAdoption: false)
            }
            return i.oneXState ? .inPlace1x : .fresh
        }
        guard record.owner == owner else {
            return .stop("The migration record belongs to \(record.owner), not this app (\(owner)).")
        }
        switch record.phase {
        case .adopting: return .adopt(keepOneXAside: record.keepOneX)
        case .adopted:
            return i.adoptedWorldAlive || !convergeEnabled ? .stayAdopted : .converge(keepOneXAside: false, fromAdoption: true)
        case .converging:
            // A diagnostic hold never leaves a mixed layout open to consumers.
            guard convergeEnabled else {
                return .stop("A convergence is unfinished, and C11_MIGRATION_CONVERGE=0 is holding this launch. Remove that setting to finish it.")
            }
            return i.adoptedWorldAlive || record.target == .adopted ? .rollBackConvergence
                                       : .converge(keepOneXAside: record.keepOneX, fromAdoption: record.fromAdoption)
        case .converged, .fresh, .inPlace1x: return .alreadyDone
        }
    }
}

// MARK: - Log

/// One JSON line per step: local time, run id, step, outcome, and counts or
/// paths. Never file contents, settings values or secrets.
struct C11MigrationLog {
    let url: URL
    let run: String
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "migration")

    static func localTimestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func line(_ step: String, _ outcome: String, _ fields: [String: Any] = [:]) {
        var object: [String: Any] = ["ts": Self.localTimestamp(), "run": run, "step": step, "outcome": outcome]
        for (k, v) in fields { object[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return }
        Self.logger.notice("\(text, privacy: .public)")
        text += "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

// MARK: - Execute

struct C11MigrationExecutor {
    var layout: C11MigrationLayout
    var log: C11MigrationLog
    var fileManager: FileManager = .default
    /// Read and write settings domains. Injected for tests.
    var defaults: C11MigrationDefaults
    /// Fault injection (QA and tests): called after each step completes, and at
    /// the named points inside a step. Production leaves it nil.
    var fault: ((String) throws -> Void)?
    var now: () -> Date = Date.init

    enum Failure: Error, Equatable { case sourceChanged(String), occupied(String), injected(String), io(String) }

    static let originKey = "c11.migration.origin"
    /// The origins an adoption records; `C11UpgradeOrigin` reads them (C11H-335).
    static let adoptedOrigin = "c11h"  // c11-2.0:legacy
    static let adoptedBesideOneXOrigin = "both"

    func run(_ decision: C11MigrationDecision) throws {
        switch decision {
        case .skipNonRelease, .waitForLegacyApp, .stop:
            return
        case .alreadyDone:
            if try C11MigrationState.load(home: layout.home)?.phase == .converged {
                try verifyCommittedLayout()
            }
        case .stayAdopted:
            do { try verifyCommittedLayout() } catch { try rollBackConvergence() }
        case .fresh:
            try finishInPlace(.fresh, origin: "fresh")
        case .inPlace1x:
            try mirrorOneXForQABuild()
            try finishInPlace(.inPlace1x, origin: "c11-1x")
        case .adopt(let keep):
            try adopt(keepOneXAside: keep)
        case .converge(let keep, let fromAdoption):
            try converge(keepOneXAside: keep, fromAdoption: fromAdoption)
        case .rollBackConvergence:
            try rollBackConvergence()
        }
    }

    // MARK: Journal

    private func newState(_ phase: C11MigrationState.Phase, origin: String, keep: Bool, fromAdoption: Bool = false) -> C11MigrationState {
        let stamp = C11MigrationLog.localTimestamp(now())
        return C11MigrationState(owner: layout.destBundleIdentifier, phase: phase, origin: origin, keepOneX: keep,
                                 fromAdoption: fromAdoption, hcRoot: layout.sourceHCRoot, hcBase: layout.sourceHCBase,
                                 servingApp: layout.sourceApp, startedAt: stamp, updatedAt: stamp)
    }

    private func save(_ state: inout C11MigrationState) throws {
        state.updatedAt = C11MigrationLog.localTimestamp(now())
        try state.write(home: layout.home)
    }

    /// Intent first, then the work, then completion; a done step is skipped.
    private func step(_ name: String, _ state: inout C11MigrationState, _ body: (inout C11MigrationState) throws -> Void) throws {
        if state.isDone(name) { return }
        state.steps[name] = .running
        try save(&state)
        try body(&state)
        state.steps[name] = .done
        try save(&state)
        try fault?(name)
    }

    private func finishInPlace(_ phase: C11MigrationState.Phase, origin: String) throws {
        var state = newState(phase, origin: origin, keep: false)
        try save(&state)
        writeOrigin(origin)
        log.line("commit", "ok", ["outcome": phase.rawValue])
    }

    // MARK: Adopt

    func adopt(keepOneXAside: Bool) throws {
        var state = (try C11MigrationState.load(home: layout.home))
            ?? newState(.adopting, origin: keepOneXAside ? Self.adoptedBesideOneXOrigin : Self.adoptedOrigin, keep: keepOneXAside)
        log.line("plan", "ok", ["decision": "adopt", "keep_1x": state.keepOneX, "resumed": !state.steps.isEmpty])
        try save(&state)
        try keepOneXStep(&state)
        try step("defaults", &state) { _ in
            let source = defaults.read(layout.sourceBundleIdentifier) ?? [:]
            let mapped = C11MigrationDefaults.map(source)
            defaults.replace(layout.destBundleIdentifier, mapped)
            log.line("defaults", "ok", ["source_keys": source.count, "written_keys": mapped.count])
        }
        try step("adopt_files", &state) { _ in
            var added: [String] = []
            for (from, to) in [(layout.sourceSnapshotName, layout.destSnapshotName),
                               (layout.sourcePanelAllocations, layout.destPanelAllocations)] {
                let src = layout.sourceSupport.appendingPathComponent(from)
                guard fileManager.fileExists(atPath: src.path) else { continue }
                try copyVerified(src, to: layout.sourceSupport.appendingPathComponent(to))
                added.append("\(layout.sourceSupportName)/\(to)")
            }
            added += try copyRuntimeMarkers(from: layout.sourceBundleIdentifier, into: layout.sourceHomeDirectory)
            added += try copyItems(layout.bundleDataItems)
            log.line("adopt_files", "ok", ["added": added])
        }
        state.target = .adopted
        try save(&state)
        try reconcileAdopted(&state)
        try fault?("adopt_links")
        state.phase = .adopted
        try save(&state)
        writeOrigin(state.origin)
        log.line("adopt", "ok", ["hc_root": state.hcRoot, "hc_base": state.hcBase,
                                 "serving_app": state.servingApp ?? "", "kept": state.keptDirectory ?? ""])
    }

    /// Creates `path` as a link to `target` atomically: a temporary link renamed
    /// into place. A link already there with that target is kept.
    private func installLink(_ path: String, target: String) throws {
        let link = layout.url(path)
        if C11MigrationLayout.linkTarget(link) == target { return }
        var info = stat()
        if lstat(link.path, &info) == 0 {
            log.line("adopt_links", "occupied", ["path": path])
            throw Failure.occupied(path)
        }
        let parent = link.deletingLastPathComponent()
        // Link publication alone does not establish a usable adopted path.
        // The reconciler creates missing targets and verifies resolution.
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".\(link.lastPathComponent).c11-link-\(log.run)")
        try? fileManager.removeItem(at: temp)
        try fileManager.createSymbolicLink(atPath: temp.path, withDestinationPath: target)
        guard rename(temp.path, link.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temp)
            throw Failure.io("link \(path): errno \(code)")
        }
    }

    // MARK: Converge

    /// A directory carries its provenance with it through rename. A nil stamp
    /// identifies an owned, incomplete stage, never a publishable replacement.
    struct StageIdentity: Codable, Equatable {
        var owner: String
        var path: String
        var sourceStamp: String?
    }
    static let stageIdentityName = ".c11-migration-stage.json"

    private enum ObjectKind: Equatable { case missing, link(String), directory, other }

    private func observe(_ url: URL) throws -> ObjectKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw Failure.io("observe \(url.path): errno \(errno)")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .link(try fileManager.destinationOfSymbolicLink(atPath: url.path))
        default: return .other
        }
    }

    private func stageIdentity(_ url: URL, path: String) throws -> StageIdentity? {
        guard try observe(url) == .directory else { return nil }
        let marker = url.appendingPathComponent(Self.stageIdentityName)
        if try observe(marker) == .missing { return nil }
        guard try observe(marker) == .other else { throw Failure.occupied(marker.path) }
        let identity = try JSONDecoder().decode(StageIdentity.self, from: Data(contentsOf: marker))
        guard identity.owner == layout.destBundleIdentifier, identity.path == path else {
            throw Failure.occupied(url.path)
        }
        return identity
    }

    private func markStage(_ url: URL, path: String, stamp: String?) throws {
        let identity = StageIdentity(owner: layout.destBundleIdentifier, path: path, sourceStamp: stamp)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(identity).write(to: url.appendingPathComponent(Self.stageIdentityName), options: .atomic)
    }

    /// Compatibility is bounded to an unfinished old executor transaction.
    /// Old completion flags never skip an operation; all its candidates are
    /// marked incomplete and reconciled back to links before being rebuilt.
    private func adoptLegacyCandidates(_ state: C11MigrationState) throws {
        guard state.phase == .converging, state.target == nil,
              state.steps["c_stage"] != nil else { return }
        for folder in layout.switchedFolders {
            for url in [layout.url(folder.path), staged(folder.path)] {
                if try observe(url) == .directory, try stageIdentity(url, path: folder.path) == nil {
                    try markStage(url, path: folder.path, stamp: nil)
                }
            }
        }
    }

    func converge(keepOneXAside: Bool, fromAdoption: Bool) throws {
        let previous = try C11MigrationState.load(home: layout.home)
        var state = previous
            ?? newState(.converging, origin: keepOneXAside ? Self.adoptedBesideOneXOrigin : Self.adoptedOrigin, keep: keepOneXAside, fromAdoption: fromAdoption)
        if state.phase == .converging, state.target == .adopted {
            try rollBackConvergence()
            return
        }
        if let previous { try adoptLegacyCandidates(previous) }
        if state.phase == .adopted { state.fromAdoption = true }
        state.phase = .converging
        state.target = .converged
        // The old journal is accepted on read only. It never authorizes reuse.
        for name in state.steps.keys where name.hasPrefix("c_") { state.steps[name] = nil }
        try save(&state)
        if !state.fromAdoption { try keepOneXStep(&state) }

        var stamp = try sourceStamp()
        let complete = try hasCompleteGeneration(stamp)
        if state.sourceStamp != stamp || !complete {
            // This intent precedes both stale-generation rollback and a build
            // from empty paths. If interrupted, the next launch finishes the
            // adoption target first, whatever the new liveness inventory says.
            state.target = .adopted
            try save(&state)
            try fault?("rollback.intent")
            try reconcileAdopted(&state)
            try removeOwnedStages(&state)
            // Adoption materializes optional legacy folders so every link is
            // writable. Those empty inputs belong in this generation's stamp.
            stamp = try sourceStamp()
            state.target = .converged
            state.sourceStamp = stamp
            try save(&state)
            try fault?("stage.intent")
            try buildStage(fromAdoption: state.fromAdoption)
            guard try sourceStamp() == stamp else { throw Failure.sourceChanged("stage") }
            for folder in layout.switchedFolders {
                try markStage(staged(folder.path), path: folder.path, stamp: stamp)
            }
            try fault?("c_stage")
        }
        if !state.fromAdoption {
            defaults.replace(layout.destBundleIdentifier, C11MigrationDefaults.map(defaults.read(layout.sourceBundleIdentifier) ?? [:]))
        }
        try fault?("c_defaults")

        for (index, folder) in layout.switchedFolders.enumerated() {
            let final = layout.url(folder.path), stage = staged(folder.path)
            let aside = URL(fileURLWithPath: final.path + C11Migration.asideSuffix)
            let observed = try observe(final)
            if observed == .link(folder.target) {
                let old = try observe(aside)
                guard old == .missing || old == .link(folder.target) else { throw Failure.occupied(aside.path) }
                try move(final, to: aside, point: "forward.\(index).park")
            } else if observed != .missing && observed != .directory {
                throw Failure.occupied(final.path)
            }
            try fault?("c_switch_mid")
            if try observe(final) == .missing {
                guard try stageIdentity(stage, path: folder.path)?.sourceStamp == stamp else {
                    throw Failure.io("missing replacement: \(folder.path)")
                }
                try move(stage, to: final, point: "forward.\(index).install")
            }
            guard try stageIdentity(final, path: folder.path)?.sourceStamp == stamp else {
                throw Failure.occupied(final.path)
            }
        }
        try fault?("c_switch")
        try verifyRealDirectories(stamp: stamp)
        guard try sourceStamp() == stamp else { throw Failure.sourceChanged("commit") }
        try cleanAsideLinks()
        if !state.fromAdoption { writeOrigin(state.origin) }
        try fault?("converged.commit.before")
        state.phase = .converged
        state.target = .converged
        try save(&state)
        try fault?("converged.commit.after")
        log.line("commit", "ok", ["outcome": "converged"])
    }

    /// A rollback intent is durable before any move. It is completed on its
    /// own terms even when the next launch observes an ended legacy world.
    func rollBackConvergence() throws {
        guard var state = try C11MigrationState.load(home: layout.home) else { return }
        try adoptLegacyCandidates(state)
        state.target = .adopted
        state.phase = .converging
        try save(&state)
        try fault?("rollback.intent")
        // The direct path may have stopped while preserving 1.x, before any
        // migration-owned directory existed. Finish that same keep-aside first.
        if !state.fromAdoption { try keepOneXStep(&state) }
        try reconcileAdopted(&state)
        try removeOwnedStages(&state)
        // A direct migration may have failed before defaults/alias creation.
        // Let the existing adoption path establish those once; its folder
        // reconciliation observes the already restored links.
        if !state.fromAdoption {
            state.sourceStamp = nil
            state.phase = .adopting
            try save(&state)
            try adopt(keepOneXAside: state.keepOneX)
            return
        }
        try fault?("adopted.commit.before")
        state.phase = .adopted
        state.sourceStamp = nil
        try save(&state)
        try fault?("adopted.commit.after")
        log.line("rollback", "ok", ["to": "adopted"])
    }

    private func reconcileAdopted(_ state: inout C11MigrationState) throws {
        for (index, folder) in layout.switchedFolders.enumerated() {
            let final = layout.url(folder.path), stage = staged(folder.path)
            let aside = URL(fileURLWithPath: final.path + C11Migration.asideSuffix)
            let observed = try observe(final)
            let source = layout.url(folder.source)
            if try observe(source) == .missing {
                try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
            }
            if observed == .link(folder.target) { continue }
            guard observed == .missing || observed == .directory else { throw Failure.occupied(final.path) }
            // Prepare the link BEFORE moving a real directory out of the way.
            let previous = try observe(aside)
            if previous == .missing {
                try fileManager.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: aside.path, withDestinationPath: folder.target)
            } else if previous != .link(folder.target) { throw Failure.occupied(aside.path) }
            if observed == .directory {
                guard try stageIdentity(final, path: folder.path) != nil else { throw Failure.occupied(final.path) }
                guard try observe(stage) == .missing else { throw Failure.occupied(stage.path) }
                try move(final, to: stage, point: "rollback.\(index).park")
            }
            try move(aside, to: final, point: "rollback.\(index).install")
        }
        try verifyLinks()
        try cleanAsideLinks()
    }

    private func move(_ from: URL, to: URL, point: String) throws {
        try fault?(point + ".before")
        try renameItem(from, to)
        try fault?(point + ".after")
    }

    private func verifyLinks() throws {
        for folder in layout.switchedFolders {
            var isDirectory: ObjCBool = false
            guard try observe(layout.url(folder.path)) == .link(folder.target),
                  fileManager.fileExists(atPath: layout.url(folder.path).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw Failure.io("adoption postcondition: \(folder.path)")
            }
        }
    }

    private func verifyRealDirectories(stamp: String? = nil) throws {
        for folder in layout.switchedFolders {
            guard let identity = try stageIdentity(layout.url(folder.path), path: folder.path),
                  let actual = identity.sourceStamp, stamp == nil || actual == stamp else {
                throw Failure.io("convergence postcondition: \(folder.path)")
            }
        }
    }

    func verifyCommittedLayout() throws {
        guard let state = try C11MigrationState.load(home: layout.home), state.owner == layout.destBundleIdentifier else {
            throw Failure.io("missing or foreign migration record")
        }
        switch state.phase {
        case .adopted: try verifyLinks()
        case .converged: try verifyRealDirectories(stamp: state.sourceStamp)
        case .fresh, .inPlace1x: break
        default: throw Failure.io("unfinished migration")
        }
    }

    private func hasCompleteGeneration(_ stamp: String) throws -> Bool {
        for folder in layout.switchedFolders {
            let final = layout.url(folder.path), stage = staged(folder.path)
            let atFinal = try stageIdentity(final, path: folder.path)
            let atStage = try stageIdentity(stage, path: folder.path)
            if atFinal != nil && atStage != nil { throw Failure.occupied(stage.path) }
            guard (atFinal ?? atStage)?.sourceStamp == stamp else { return false }
        }
        return true
    }

    private func cleanAsideLinks() throws {
        for (index, folder) in layout.switchedFolders.enumerated() {
            let aside = URL(fileURLWithPath: layout.url(folder.path).path + C11Migration.asideSuffix)
            let kind = try observe(aside)
            if kind == .missing { continue }
            guard kind == .link(folder.target) else { throw Failure.occupied(aside.path) }
            try fault?("cleanup.\(index).before")
            try fileManager.removeItem(at: aside)
            try fault?("cleanup.\(index).after")
        }
    }

    private func removeOwnedStages(_ state: inout C11MigrationState) throws {
        for (index, folder) in layout.switchedFolders.enumerated() {
            let stage = staged(folder.path)
            if try observe(stage) == .missing { continue }
            if try stageIdentity(stage, path: folder.path) == nil {
                // mkdir and writing its marker cannot be one filesystem operation.
                // The durable generation intent owns only an empty directory in
                // that gap; never infer ownership of an unmarked nonempty tree.
                guard state.sourceStamp != nil || state.discardingStage == folder.path,
                      try observe(stage) == .directory,
                      try fileManager.contentsOfDirectory(atPath: stage.path).isEmpty else {
                    throw Failure.occupied(stage.path)
                }
            }
            // Keep ownership until all payload entries are gone. An interrupted
            // recursive removal must not leave an unowned nonempty remainder.
            for name in try fileManager.contentsOfDirectory(atPath: stage.path).sorted()
                where name != Self.stageIdentityName {
                try fault?("discard.\(index).entry.before")
                try fileManager.removeItem(at: stage.appendingPathComponent(name))
                try fault?("discard.\(index).entry.after")
            }
            state.discardingStage = folder.path
            try save(&state)
            let marker = stage.appendingPathComponent(Self.stageIdentityName)
            if try observe(marker) != .missing { try fileManager.removeItem(at: marker) }
            try fault?("discard.\(index).marker.after")
            try fileManager.removeItem(at: stage)
        }
        state.discardingStage = nil
        try save(&state)
    }

    private func buildStage(fromAdoption own: Bool) throws {
        for (index, folder) in layout.switchedFolders.enumerated() {
            let stage = staged(folder.path)
            guard try observe(stage) == .missing else { throw Failure.occupied(stage.path) }
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
            try fault?("stage.\(index).created")
            try markStage(stage, path: folder.path, stamp: nil)
        }
        let support = staged(layout.switchedFolders[0].path)
        for entry in C11MigrationLayout.supportEntries {
            let src = layout.sourceSupport.appendingPathComponent(entry)
            if try observe(src) != .missing { try copyVerified(src, to: support.appendingPathComponent(entry)) }
        }
        let snapshotBundle = try currentSnapshotBundle(adopted: own)
        for (legacy, to) in [(layout.sourceSnapshotName, layout.destSnapshotName),
                             (layout.sourcePanelAllocations, layout.destPanelAllocations)] {
            let from = try (legacy == layout.sourceSnapshotName
                ? "session-\(snapshotBundle).json"
                : currentSourceName(legacy: legacy, own: to, adopted: own))
            let src = layout.sourceSupport.appendingPathComponent(from)
            if try observe(src) != .missing { try copyVerified(src, to: support.appendingPathComponent(to)) }
        }
        let snapshot = support.appendingPathComponent(layout.destSnapshotName)
        if try observe(snapshot) != .missing {
            let (settled, count) = try Self.settleDeadTerminals(Data(contentsOf: snapshot), legacyBase: layout.sourceHCBase)
            if count > 0 { try settled.write(to: snapshot, options: .atomic) }
        }
        _ = try dropDeadIntents(support.appendingPathComponent("HC", isDirectory: true), snapshot: snapshot)
        let homeStage = staged(layout.destHomeDirectory)
        let hooks = layout.url("\(layout.sourceHomeDirectory)/claude-hook-sessions.json")
        if try observe(hooks) != .missing { try copyVerified(hooks, to: homeStage.appendingPathComponent("claude-hook-sessions.json")) }
        _ = try copyRuntimeMarkers(from: snapshotBundle,
                                   intoFolder: homeStage.appendingPathComponent("runtime", isDirectory: true))
        for folder in layout.switchedFolders.dropFirst(2) {
            let src = layout.url(folder.source)
            if try observe(src) == .missing { continue }
            guard try observe(src) == .directory else { throw Failure.occupied(src.path) }
            for name in try fileManager.contentsOfDirectory(atPath: src.path) {
                try copyVerified(src.appendingPathComponent(name), to: staged(folder.path).appendingPathComponent(name))
            }
        }
        if !own { _ = try copyItems(layout.bundleDataItems) }
    }

    /// Both apps keep their own snapshot name while adopted. Going back to
    /// c11h can make its file newer than the c11 alias; use the last writer.
    private func currentSourceName(legacy: String, own: String, adopted: Bool) throws -> String {
        guard adopted else { return legacy }
        let ownURL = layout.sourceSupport.appendingPathComponent(own)
        let legacyURL = layout.sourceSupport.appendingPathComponent(legacy)
        guard try observe(ownURL) != .missing else { return legacy }
        guard try observe(legacyURL) != .missing else { return own }
        guard let ownStamp = C11FileStamp(ownURL), let legacyStamp = C11FileStamp(legacyURL) else {
            throw Failure.io("snapshot source changed while selecting")
        }
        return legacyStamp.mtime > ownStamp.mtime ? legacy : own
    }

    /// The last app to run owns both the snapshot and the whole sentinel set.
    /// Selecting clean/dirty separately can turn that app's crash into a clean
    /// quit using the other app's old clean file and bypass recovery verification.
    private func currentSnapshotBundle(adopted: Bool) throws -> String {
        guard adopted else { return layout.sourceBundleIdentifier }
        let runtime = layout.url("\(layout.sourceHomeDirectory)/runtime")
        func newestShutdown(_ bundle: String) throws -> TimeInterval? {
            var newest: TimeInterval?
            for suffix in [".clean", ".dirty"] {
                let marker = runtime.appendingPathComponent("shutdown." + bundle + suffix)
                if try observe(marker) == .missing { continue }
                guard let stamp = C11FileStamp(marker) else { throw Failure.io("unreadable shutdown marker") }
                newest = max(newest ?? -.infinity, stamp.mtime)
            }
            return newest
        }
        let legacy = try newestShutdown(layout.sourceBundleIdentifier)
        let own = try newestShutdown(layout.destBundleIdentifier)
        let bundle: String
        if legacy != nil || own != nil {
            bundle = (own ?? -.infinity) >= (legacy ?? -.infinity) ? layout.destBundleIdentifier : layout.sourceBundleIdentifier
        } else {
            let name = try currentSourceName(legacy: layout.sourceSnapshotName, own: layout.destSnapshotName, adopted: true)
            bundle = name == layout.destSnapshotName ? layout.destBundleIdentifier : layout.sourceBundleIdentifier
        }
        let selected = layout.sourceSupport.appendingPathComponent("session-\(bundle).json")
        let other = layout.sourceSupport.appendingPathComponent(bundle == layout.destBundleIdentifier
            ? layout.sourceSnapshotName : layout.destSnapshotName)
        if try observe(selected) == .missing, try observe(other) != .missing {
            throw Failure.io("missing snapshot for the most recent shutdown")
        }
        return bundle
    }

    private func staged(_ rel: String) -> URL { URL(fileURLWithPath: layout.url(rel).path + C11Migration.stagingSuffix) }

    private func freshDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func renameItem(_ from: URL, _ to: URL) throws {
        guard rename(from.path, to.path) == 0 else { throw Failure.io("rename \(from.lastPathComponent): errno \(errno)") }
    }

    /// Local intents belong to proven-dead cores. Remote records can share the
    /// same legacy session directory and retain their replay ledger unchanged.
    private func dropDeadIntents(_ hc: URL, snapshot: URL) throws -> Int {
        guard try observe(hc) != .missing else { return 0 }
        var remotePanels = Set<String>()
        func collectRemotePanels(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let terminal = dict["terminal"] as? [String: Any], terminal["hcRemoteTarget"] != nil,
                   let id = dict["id"] as? String { remotePanels.insert(id.uppercased()) }
                for value in dict.values { collectRemotePanels(value) }
            } else if let array = value as? [Any] { array.forEach(collectRemotePanels) }
        }
        if try observe(snapshot) != .missing {
            collectRemotePanels(try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot)))
        }
        let names = try fileManager.contentsOfDirectory(atPath: hc.path)
        var count = 0
        for name in names where Self.rehomeSessionName(name, from: layout.sourceHCBase, to: layout.sourceHCBase) != nil {
            let directory = hc.appendingPathComponent(name)
            let file = directory.appendingPathComponent("creation-intents.json")
            if try observe(file) != .missing {
                guard var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                      document["version"] as? Int == 1,
                      let active = document["active"] as? [String: Any],
                      document["usedCreationIDs"] is [String] else {
                    throw Failure.io("invalid creation intents: \(name)")
                }
                var remote: [String: Any] = [:]
                for (id, value) in active {
                    let record = try JSONDecoder().decode(HCStoredCreation.self,
                        from: JSONSerialization.data(withJSONObject: value))
                    if record.machine != nil || remotePanels.contains(record.panelID.uuidString.uppercased()) {
                        remote[id] = value
                    }
                }
                if !remote.isEmpty {
                    document["active"] = remote
                    try HCCreationIntentStore.persistDurably(
                        JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), file)
                    continue
                }
            }
            try fileManager.removeItem(at: directory)
            count += 1
        }
        return count
    }

    /// Every local terminal panel homed on the legacy pool (`<base>`, `<base>-sN`)
    /// loses its active hc identity/session and carries the proven end into
    /// ordinary recovery. Existing settled decisions remain intact. Remote terminals (`hcRemoteTarget`) and other sessions are
    /// left as they are. Returns the new snapshot and how many panels changed.
    static func settleDeadTerminals(_ data: Data, legacyBase: String) throws -> (Data, Int) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (data, 0) }
        var count = 0
        func settle(_ value: Any) throws -> Any {
            if var dict = value as? [String: Any] {
                if var terminal = dict["terminal"] as? [String: Any], terminal["hcRemoteTarget"] == nil,
                   terminal["hcIdentity"] != nil || terminal["hcSession"] != nil {
                    let session = terminal["hcSession"] as? String ?? legacyBase
                    let persistence = (terminal["hcIdentity"] as? [String: Any])?["persistence"]
                    // Exec fallbacks keep their nonpersistent identity and
                    // scrollback. The dead HC world proves no end for them.
                    if (persistence == nil || persistence as? String == HCPersistence.persistent.rawValue),
                       rehomeSessionName(session, from: legacyBase, to: legacyBase) != nil {
                        guard let id = dict["id"] as? String, let panelID = UUID(uuidString: id) else {
                            throw Failure.io("legacy terminal has no valid panel identity")
                        }
                        var endedKey: HCTerminalKey?
                        if let identity = terminal["hcIdentity"] as? [String: Any], let key = identity["key"] {
                            endedKey = try JSONDecoder().decode(HCTerminalKey.self,
                                from: JSONSerialization.data(withJSONObject: key))
                        }
                        let proof = SessionTerminalPanelSnapshot.migrationEnd(panelID: panelID, endedKey: endedKey)
                        terminal["hcMigrationEnd"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))
                        terminal["hcIdentity"] = nil
                        terminal["hcSession"] = nil
                        // Existing decided/found keys remain authoritative. The
                        // separate end proof supplies lifecycle provenance only.
                        dict["terminal"] = terminal
                        count += 1
                    }
                }
                for (k, v) in dict where k != "terminal" { dict[k] = try settle(v) }
                return dict
            }
            if let array = value as? [Any] { return try array.map(settle) }
            return value
        }
        root = try settle(root) as? [String: Any] ?? root
        let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return (out, count)
    }

    /// A stamp of c11h's state the stage is built from (paths, sizes, mtimes of
    /// the carried entries and home folders). A resumed convergence rebuilds the
    /// stage when it no longer matches.  c11-2.0:legacy
    func sourceStamp() throws -> String {
        var parts: [String] = []
        var roots = C11MigrationLayout.supportEntries.map { layout.sourceSupport.appendingPathComponent($0) }
        roots += [layout.sourceSupport.appendingPathComponent(layout.sourceSnapshotName),
                  layout.sourceSupport.appendingPathComponent(layout.destSnapshotName),
                  layout.sourceSupport.appendingPathComponent(layout.sourcePanelAllocations),
                  layout.sourceSupport.appendingPathComponent(layout.destPanelAllocations),
                  layout.url(layout.sourceHomeDirectory), layout.url(".c11h-snapshots"), layout.url(".config/c11h")] // c11-2.0:legacy
        roots += layout.bundleDataItems.map { layout.url($0.source) }
        func visit(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { parts.append("\(url.path)|absent"); return }
                throw Failure.io("stamp \(url.path): errno \(errno)")
            }
            let type = info.st_mode & S_IFMT
            parts.append("\(url.path)|\(info.st_mode)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
            if type == S_IFDIR {
                for name in try fileManager.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(name))
                }
            } else if type == S_IFLNK {
                parts.append(try fileManager.destinationOfSymbolicLink(atPath: url.path))
            }
        }
        for root in roots { try visit(root) }
        // The direct path also imports settings; a retry must see their new
        // values. XML property lists serialize dictionary keys deterministically.
        let settings = C11MigrationDefaults.map(defaults.read(layout.sourceBundleIdentifier) ?? [:])
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        var input = Data(parts.sorted().joined(separator: "\n").utf8)
        input.append(data)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// `<from>` → `<to>`, `<from>-sN` (N in 1...8) → `<to>-sN`; nil for anything else.
    static func rehomeSessionName(_ name: String, from: String, to: String) -> String? {
        if name == from { return to }
        guard name.hasPrefix(from + "-s"), let n = Int(name.dropFirst(from.count + 2)), (1...8).contains(n) else { return nil }
        return "\(to)-s\(n)"
    }

    /// `"hcSession": "<from>"` and `"<from>-sN"` become `<to>` and `<to>-sN`.
    /// Anything else (a tagged build's session) is left as it is.
    static func rehomeSessions(_ text: String, from: String, to: String) -> (String, Int) {
        let pattern = #"("hcSession"\s*:\s*")"# + NSRegularExpression.escapedPattern(for: from) + #"((?:-s[1-8])?)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, 0) }
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        let replaced = regex.stringByReplacingMatches(in: text, range: range,
                                                      withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: to) + "$2\"")
        return (replaced, count)
    }

    // MARK: c11 1.x aside

    /// Moves c11 1.x's folders and settings into one kept folder whose name is
    /// journaled before anything moves; resumes a half-moved one.
    private func keepOneXStep(_ state: inout C11MigrationState) throws {
        guard state.keepOneX else { return }
        if state.keptDirectory == nil {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            stamp.timeZone = .current
            state.keptDirectory = "\(layout.destSupportName)\(C11Migration.keptPrefix)\(stamp.string(from: now()))"
            try save(&state)
        }
        let name = state.keptDirectory!
        try step("keep_1x", &state) { _ in
            let kept = layout.appSupport.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: kept, withIntermediateDirectories: true)
            let plist = kept.appendingPathComponent("defaults-\(layout.oneXBundleIdentifier).plist")
            if !fileManager.fileExists(atPath: plist.path) {
                let domain = defaults.read(layout.oneXBundleIdentifier) ?? [:]
                let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
                try data.write(to: plist, options: .atomic)
                log.line("keep_1x", "defaults_exported", ["keys": domain.count])
            }
            var moved: [String] = []
            for rel in layout.oneXItems {
                let src = layout.url(rel)
                let dst = kept.appendingPathComponent("home").appendingPathComponent(rel)
                var info = stat()
                guard lstat(src.path, &info) == 0, !fileManager.fileExists(atPath: dst.path) else { continue }
                try fileManager.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try renameItem(src, dst)
                moved.append(rel)
                try fault?("keep_1x_mid")
            }
            let readme = """
            # c11 1.x state, kept by c11 2.0

            c11 2.0 took this Mac's c11h workspaces and moved c11 1.x's own state here,
            unchanged, at \(C11MigrationLog.localTimestamp(now())). Nothing in this folder was edited.

            - `home/<path>` was `~/<path>`.
            - `defaults-\(layout.oneXBundleIdentifier).plist` is the `\(layout.oneXBundleIdentifier)` settings domain.

            To put c11 1.x back: quit c11, move each item back to its original path, then
            `defaults import \(layout.oneXBundleIdentifier) defaults-\(layout.oneXBundleIdentifier).plist`.

            """
            try readme.write(to: kept.appendingPathComponent("KEPT.md"), atomically: true, encoding: .utf8)
            log.line("keep_1x", "ok", ["kept": name, "moved": moved])
        }
    }

    // MARK: Copies

    private func copyItems(_ items: [(source: String, dest: String)]) throws -> [String] {
        var copied: [String] = []
        for item in items {
            let src = layout.url(item.source)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try copyVerified(src, to: layout.url(item.dest))
            copied.append(item.dest)
        }
        return copied
    }

    /// APFS clone (copy-on-write, milliseconds even for GB-scale stores; a real
    /// copy off APFS) into `dst.migrating-tmp`, then renamed into place. Each
    /// source file's size, mtime and inode are checked before and after.
    @discardableResult
    func copyVerified(_ src: URL, to dst: URL) throws -> (files: Int, bytes: Int64) {
        let fm = fileManager
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(dst.lastPathComponent + ".migrating-tmp")
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var before: [String: C11FileStamp] = [:]
        var files = 0
        var bytes: Int64 = 0
        try forEachFile(src) { url in
            if let stamp = C11FileStamp(url) { before[url.path] = stamp; files += 1; bytes += stamp.size }
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(src.path, tmp.path, nil, flags) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw Failure.io("copy \(src.lastPathComponent): errno \(code)")
        }
        for (path, stamp) in before where C11FileStamp(URL(fileURLWithPath: path)) != stamp {
            try? fm.removeItem(at: tmp)
            log.line("copy", "source_changed", ["path": path])
            throw Failure.sourceChanged(path)
        }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try renameItem(tmp, dst)
        return (files, bytes)
    }

    private func forEachFile(_ root: URL, _ body: (URL) throws -> Void) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue else { try body(root); return }
        let e = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        while let url = e?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try body(url) }
        }
    }

    /// `shutdown.<bundle>.<clean|dirty>` and `relaunch.<bundle>.json` from
    /// `.c11h/runtime`, under 2.0's bundle name, so 2.0 reads the last quit as its own.  c11-2.0:legacy
    private func copyRuntimeMarkers(from bundle: String, into homeDirectory: String) throws -> [String] {
        try copyRuntimeMarkers(from: bundle, intoFolder: layout.url("\(homeDirectory)/runtime"))
    }

    private func copyRuntimeMarkers(from bundle: String, intoFolder targetDir: URL) throws -> [String] {
        var out: [String] = []
        let dir = layout.url("\(layout.sourceHomeDirectory)/runtime")
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        for name in names {
            for kind in ["shutdown.", "relaunch."] {
                let prefix = kind + bundle
                guard name.hasPrefix(prefix) else { continue }
                let rest = String(name.dropFirst(prefix.count))
                guard [".clean", ".dirty", ".json"].contains(rest) else { continue }
                let targetName = kind + layout.destBundleIdentifier + rest
                if dir.standardizedFileURL == targetDir.standardizedFileURL && targetName == name { continue }
                try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
                try copyVerified(dir.appendingPathComponent(name), to: targetDir.appendingPathComponent(targetName))
                out.append("runtime/\(targetName)")
            }
        }
        return out
    }

    // MARK: Settings and origin

    /// Where this Mac came from, for C11H-267's first-run sheet. Written once.
    func writeOrigin(_ origin: String) {
        var domain = defaults.read(layout.destBundleIdentifier) ?? [:]
        guard domain[Self.originKey] == nil else { return }
        domain[Self.originKey] = origin
        defaults.replace(layout.destBundleIdentifier, domain)
        log.line("origin", "ok", ["origin": origin])
    }

    /// The release reads 1.x's files as its own. A QA build (guest proofs only)
    /// keys its snapshot and settings by its own bundle id, so it gets a copy.
    func mirrorOneXForQABuild() throws {
        guard layout.destBundleIdentifier != layout.oneXBundleIdentifier else { return }
        for (from, to) in [("session-\(layout.oneXBundleIdentifier).json", layout.destSnapshotName),
                           ("panel-allocations-\(layout.oneXBundleIdentifier).json", layout.destPanelAllocations)] {
            let src = layout.destSupport.appendingPathComponent(from)
            let dst = layout.destSupport.appendingPathComponent(to)
            guard fileManager.fileExists(atPath: src.path), !fileManager.fileExists(atPath: dst.path) else { continue }
            try copyVerified(src, to: dst)
        }
        if let domain = defaults.read(layout.oneXBundleIdentifier), (defaults.read(layout.destBundleIdentifier) ?? [:]).isEmpty {
            defaults.replace(layout.destBundleIdentifier, domain)
        }
        log.line("qa_mirror_1x", "ok", ["bundle": layout.destBundleIdentifier])
    }
}

struct C11FileStamp: Equatable {
    let size: Int64
    let mtime: TimeInterval
    let inode: UInt64

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        mtime = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        inode = UInt64(info.st_ino)
    }
}

// MARK: - Settings

struct C11MigrationDefaults {
    var read: (String) -> [String: Any]?
    var replace: (String, [String: Any]) -> Void

    /// Main thread only (AGENTS.md: UserDefaults writes on main).
    static let system = C11MigrationDefaults(
        read: { UserDefaults.standard.persistentDomain(forName: $0) },
        replace: { name, value in
            UserDefaults.standard.setPersistentDomain(value, forName: name)
            UserDefaults.standard.synchronize()
        })

    /// Marks a domain this migration wrote, so it is never read as c11 1.x's.
    static let writtenByKey = "c11.migration.settingsFrom"

    /// c11h's own keys (`c11h.<key>`) are 2.0's `c11.<key>` (C11H-265's table).  c11-2.0:legacy
    static func renamedKey(_ key: String) -> String {
        let legacy = C11Identity.Legacy.defaultsKeyPrefix
        guard key.hasPrefix(legacy) else { return key }
        return "c11." + key.dropFirst(legacy.count)
    }

    /// c11h's settings as 2.0's. Updater and telemetry state stays behind: c11h  c11-2.0:legacy
    /// never ran Sparkle or telemetry, so 2.0 starts from its own defaults there.
    static func map(_ source: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [writtenByKey: "c11h"]  // c11-2.0:legacy
        for (key, value) in source {
            let lowered = key.lowercased()
            if key.hasPrefix("SU") || lowered.contains("sparkle") { continue }
            if lowered.contains("telemetry") || key.hasPrefix("posthog.") { continue }
            out[renamedKey(key)] = value
        }
        return out
    }
}
