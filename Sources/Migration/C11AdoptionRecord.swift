import Foundation

/// The one durable record of c11 2.0's first-launch migration (C11H-266):
/// `~/Library/Application Support/c11-migration.json`, beside the support
/// folders so it never sits inside one that moves. Replaced whole on every
/// write (temp file, then rename). Convergence records target/generation intent
/// and reconciles the actual directories; legacy adoption steps remain readable.
struct C11MigrationState: Codable, Equatable {
    static let fileName = "c11-migration.json"
    static let schemaVersion = 2

    enum Phase: String, Codable {
        /// Adoption under way: steps may be half done.
        case adopting
        /// 2.0 runs on c11h's folders through links, and on c11h's hc sessions.  c11-2.0:legacy
        case adopted
        /// The staged copy into 2.0's own names is under way.
        case converging
        /// Finished states: nothing left to do.
        case converged, fresh, inPlace1x
    }

    enum StepState: String, Codable { case running, done }

    var schema = Self.schemaVersion
    /// The bundle the record belongs to; no other bundle reads or resumes it.
    var owner: String
    var phase: Phase
    /// `fresh`, `c11-1x`, `c11h` or `both` (C11H-267's first-run sheet reads it).  c11-2.0:legacy
    var origin: String
    /// c11 1.x's state is moved aside before anything else; decided once, at the start.
    var keepOneX = false
    var keptDirectory: String?
    /// An adopted convergence keeps 2.0 settings, takes the last shutdown
    /// owner's snapshot/markers together and the newest allocation file.
    var fromAdoption = false
    /// The source state the convergence stage was built from (Rule B).
    var sourceStamp: String?
    /// Ownership of the last empty-stage deletion, retained across the gap
    /// between removing its marker and removing its directory (also for v2 stages).
    var discardingStage: String?
    /// C11H-283: the desired layout, written before any switch. An adopted
    /// target on a converging record is a rollback that must finish first.
    /// Older records have no target; their step flags never prove disk state.
    enum Target: String, Codable { case adopted, converged }
    var target: Target?
    var steps: [String: StepState] = [:]
    /// Adopted hc namespace (home-relative root, session base) and the c11h app  c11-2.0:legacy
    /// whose helper serves its cores.
    var hcRoot = ".local/share/c11h"  // c11-2.0:legacy
    var hcBase = "c11h"  // c11-2.0:legacy
    var servingApp: String?
    var startedAt: String
    var updatedAt: String

    static func url(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent(fileName)
    }

    /// nil when absent. An unreadable or unknown file throws: the caller stops.
    static func load(home: URL) throws -> C11MigrationState? {
        let file = url(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        let state = try JSONDecoder().decode(C11MigrationState.self, from: data)
        guard state.schema == schemaVersion, C11AdoptionRecord.isSafeRelativePath(state.hcRoot),
              C11AdoptionRecord.isSafeName(state.hcBase) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return state
    }

    /// Atomic: written to a temporary file in the same folder, then renamed over.
    func write(home: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = Self.url(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    func isDone(_ step: String) -> Bool { steps[step] == .done }
}

/// What hc needs from an adoption: the c11h namespace this app's cores use.  c11-2.0:legacy
/// Present only for the record's owner, and only while adopted, so a tagged
/// build sharing the folders never attaches the release's sessions.
struct C11AdoptionRecord: Equatable {
    var owner: String
    /// Home-relative hc root: `run/<session>.sock`, `config/`.
    var root = ".local/share/c11h"  // c11-2.0:legacy
    /// Session base: shards are `<base>-s<N>`.
    var base = "c11h"  // c11-2.0:legacy
    /// The c11h app whose helper (or retained helpers) serve the adopted cores.  c11-2.0:legacy
    var servingApp: String? = nil

    static func resolve(home: URL, bundleIdentifier: String?) -> C11AdoptionRecord? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let state = try? C11MigrationState.load(home: home),
              state.owner == bundleIdentifier, state.phase == .adopted else { return nil }
        return C11AdoptionRecord(owner: state.owner, root: state.hcRoot, base: state.hcBase, servingApp: state.servingApp)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.utf8.contains(0)
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte)
        }
    }
}
