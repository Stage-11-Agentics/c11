import Foundation

/// On-disk envelope for a named Blueprint. Wraps a `WorkspaceApplyPlan` — the
/// same shared primitive Snapshots use — alongside the human-authored name and
/// optional description. Unlike `WorkspaceSnapshotFile` there is no capture
/// timestamp or c11 version: Blueprints are hand-authored and version-agnostic.
struct WorkspaceBlueprintFile: Codable, Sendable, Equatable {
    var version: Int = 1
    var name: String
    var description: String?
    var plan: WorkspaceApplyPlan

    private enum CodingKeys: String, CodingKey {
        case version, name, description, plan
    }
}

/// Lightweight list entry returned by `WorkspaceBlueprintStore.list()` and
/// surfaced by `c11 list-blueprints`. Deliberately a subset of the full
/// envelope — callers that need the plan re-read the file by name.
struct WorkspaceBlueprintIndex: Codable, Sendable, Equatable {
    var name: String
    var description: String?
    /// Resolved absolute path on disk.
    var url: String
    /// Where the Blueprint was discovered.
    var source: Source
    /// Last-modified timestamp from the filesystem.
    var modifiedAt: Date

    enum Source: String, Codable, Sendable, Equatable {
        case repo = "repo"          // committed alongside the project
        case user = "user"          // ~/.config/cmux/blueprints/
        case builtIn = "built-in"   // shipped inside the app bundle
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, url, source
        case modifiedAt = "modified_at"
    }
}
