import Foundation

/// On-disk envelope for a `c11 snapshot --all` run. A "set" is a *pointer*
/// file: it lists the per-workspace snapshot ids that were captured in
/// the same pass with set-level metadata (set id, capture time, c11
/// version, the workspace that was selected at capture time). Each
/// referenced inner snapshot stays independently restorable through the
/// existing `c11 restore <inner-id>` path; the set merely lets
/// `c11 restore <set-id>` rehydrate the lot in one go.
///
/// Ships at `~/.c11-snapshots/sets/<set_id>.json`. The `sets/`
/// subdirectory is never walked by `WorkspaceSnapshotStore.list()` (which
/// uses non-recursive `contentsOfDirectory`), so set manifests do not
/// pollute the per-workspace listing.
///
/// Wire shape:
///
/// ```json
/// {
///   "version": 1,
///   "set_id": "01KQ...",
///   "created_at": "2026-05-03T16:15:38.000Z",
///   "c11_version": "0.44.1+95",
///   "selected_workspace_index": 1,
///   "snapshots": [
///     {"workspace_ref": "workspace:1", "snapshot_id": "01KQ...", "order": 0},
///     {"workspace_ref": "workspace:2", "snapshot_id": "01KQ...", "order": 1, "selected": true}
///   ]
/// }
/// ```
///
/// Purely a value type. No AppKit; tests round-trip through Codable in a
/// Foundation-only world.
struct WorkspaceSnapshotSetFile: Codable, Sendable, Equatable {
    /// Envelope schema version. Phase 1 ships `1`; a breaking envelope
    /// change bumps this without touching the embedded snapshot ids.
    var version: Int
    /// ULID; matches the on-disk filename stem
    /// (`<set_id>.json` under `~/.c11-snapshots/sets/`).
    var setId: String
    /// UTC capture time, ISO-8601 with fractional seconds.
    var createdAt: Date
    /// `CFBundleShortVersionString+CFBundleVersion` at capture time. Lets
    /// operators correlate a set with the binary that produced it.
    var c11Version: String
    /// Index into `snapshots` of the workspace that was selected at
    /// capture time, or `nil` if no selection could be resolved. Set
    /// restore re-establishes this selection on a best-effort basis.
    var selectedWorkspaceIndex: Int?
    /// References to the per-workspace snapshot files captured in this
    /// pass. Order is the original tab order at capture time.
    var snapshots: [Entry]

    init(
        version: Int = 1,
        setId: String,
        createdAt: Date,
        c11Version: String,
        selectedWorkspaceIndex: Int? = nil,
        snapshots: [Entry]
    ) {
        self.version = version
        self.setId = setId
        self.createdAt = createdAt
        self.c11Version = c11Version
        self.selectedWorkspaceIndex = selectedWorkspaceIndex
        self.snapshots = snapshots
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case setId = "set_id"
        case createdAt = "created_at"
        case c11Version = "c11_version"
        case selectedWorkspaceIndex = "selected_workspace_index"
        case snapshots
    }

    /// One per-workspace pointer.
    struct Entry: Codable, Sendable, Equatable {
        /// Live workspace ref at capture time (`workspace:N` index form
        /// or `workspace:<uuid>` handle form). Restored as a hint only —
        /// the inner snapshot's plan carries the structural shape.
        var workspaceRef: String
        /// Per-workspace snapshot file id under
        /// `~/.c11-snapshots/<snapshot_id>.json`.
        var snapshotId: String
        /// Position in the capture-time tab order. 0-based.
        var order: Int
        /// Mirrors the parent set's `selected_workspace_index` for
        /// machine consumers that walk this list directly. Wire-omitted
        /// when false to keep the JSON minimal on the common case.
        var selected: Bool

        init(workspaceRef: String, snapshotId: String, order: Int, selected: Bool = false) {
            self.workspaceRef = workspaceRef
            self.snapshotId = snapshotId
            self.order = order
            self.selected = selected
        }

        private enum CodingKeys: String, CodingKey {
            case workspaceRef = "workspace_ref"
            case snapshotId = "snapshot_id"
            case order
            case selected
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(workspaceRef, forKey: .workspaceRef)
            try c.encode(snapshotId, forKey: .snapshotId)
            try c.encode(order, forKey: .order)
            if selected {
                try c.encode(true, forKey: .selected)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspaceRef = try c.decode(String.self, forKey: .workspaceRef)
            snapshotId = try c.decode(String.self, forKey: .snapshotId)
            order = try c.decode(Int.self, forKey: .order)
            selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        }
    }
}

/// Lightweight list entry returned by `WorkspaceSnapshotStore.listSets()`
/// and surfaced by `c11 list-snapshots --sets`. Deliberately a subset of
/// the full envelope — callers that need the inner ids re-read by id.
struct WorkspaceSnapshotSetIndex: Codable, Sendable, Equatable {
    var setId: String
    /// Resolved absolute path on disk.
    var path: String
    var createdAt: Date
    /// Number of inner snapshot references in the manifest.
    var snapshotCount: Int
    /// `c11_version` from the envelope.
    var c11Version: String?

    init(
        setId: String,
        path: String,
        createdAt: Date,
        snapshotCount: Int,
        c11Version: String?
    ) {
        self.setId = setId
        self.path = path
        self.createdAt = createdAt
        self.snapshotCount = snapshotCount
        self.c11Version = c11Version
    }

    private enum CodingKeys: String, CodingKey {
        case setId = "set_id"
        case path
        case createdAt = "created_at"
        case snapshotCount = "snapshot_count"
        case c11Version = "c11_version"
    }
}
