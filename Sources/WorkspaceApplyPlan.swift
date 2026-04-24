import Foundation

/// Declarative description of a workspace and its initial layout, executed
/// app-side by `WorkspaceLayoutExecutor`. The value type is shared between
/// Blueprints (Phase 2), Snapshots (Phase 1), and the Phase 0 debug CLI.
///
/// Metadata values reuse `PersistedJSONValue` so the same Codable shape that
/// serializes through `SessionPanelSnapshot.metadata` and
/// `SessionPaneLayoutSnapshot.metadata` serializes through a plan without a
/// conversion layer. Per the C11-13 alignment doc, v1 only writes string
/// values on the reserved `mailbox.*` pane-metadata namespace; non-string
/// values surface as a warning in `ApplyResult` and are dropped on write.
struct WorkspaceApplyPlan: Codable, Sendable, Equatable {
    /// Schema version. Phase 0 ships `1`; bumped on breaking schema changes.
    var version: Int
    var workspace: WorkspaceSpec
    /// Nested split tree; mirrors `SessionWorkspaceLayoutSnapshot` so Phase 1
    /// Snapshot capture is a structural copy.
    var layout: LayoutTreeSpec
    /// Surfaces keyed by plan-local `SurfaceSpec.id`; referenced from
    /// `LayoutTreeSpec.pane.surfaceIds`.
    var surfaces: [SurfaceSpec]
}

struct WorkspaceSpec: Codable, Sendable, Equatable {
    /// Applied via `Workspace.setCustomTitle` after creation.
    var title: String?
    /// Hex string, e.g. `"#C0392B"`. Applied via `Workspace.setCustomColor`.
    var customColor: String?
    /// Passed to `TabManager.addWorkspace(workingDirectory:)`.
    var workingDirectory: String?
    /// Operator-authored workspace-level metadata. Shape matches
    /// `SessionWorkspaceSnapshot.metadata: [String: String]?` so Phase 1
    /// restore is a direct assignment. Strings-only per C11-13 alignment.
    var metadata: [String: String]?

    init(
        title: String? = nil,
        customColor: String? = nil,
        workingDirectory: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.title = title
        self.customColor = customColor
        self.workingDirectory = workingDirectory
        self.metadata = metadata
    }
}

enum SurfaceSpecKind: String, Codable, Sendable, Equatable {
    case terminal
    case browser
    case markdown
}

struct SurfaceSpec: Codable, Sendable, Equatable {
    /// Plan-local stable id, referenced from `LayoutTreeSpec.pane.surfaceIds`.
    /// Never persisted beyond `ApplyResult`; live refs replace it at apply time.
    var id: String
    var kind: SurfaceSpecKind
    /// Applied via `Workspace.setPanelCustomTitle`, which writes the canonical
    /// `title` key into `SurfaceMetadataStore` — no double-write.
    var title: String?
    /// Written via `SurfaceMetadataStore.setMetadata` under the reserved
    /// `description` key.
    var description: String?
    /// Terminal: passed to the creation primitive's `workingDirectory:`.
    var workingDirectory: String?
    /// Terminal: sent via `TerminalPanel.sendText` once the surface is created.
    /// Pre-surface-ready sends auto-queue and flush when the surface comes up.
    var command: String?
    /// Browser: passed to `newBrowserSplit(url:)` / `newBrowserSurface(url:)`.
    var url: String?
    /// Markdown: passed to `newMarkdownSplit(filePath:)` / `newMarkdownSurface(filePath:)`.
    var filePath: String?
    /// Surface metadata — routed through `SurfaceMetadataStore.setMetadata`
    /// with `.merge` mode and `.explicit` source.
    var metadata: [String: PersistedJSONValue]?
    /// Pane metadata — routed through `PaneMetadataStore.setMetadata` with
    /// `.merge` mode and `.explicit` source. The `mailbox.*` namespace is
    /// reserved per `docs/c11-13-cmux-37-alignment.md`; the executor writes
    /// values verbatim. v1 strings-only: non-string values on a `mailbox.*`
    /// key surface as a warning in `ApplyResult` and are dropped.
    var paneMetadata: [String: PersistedJSONValue]?

    init(
        id: String,
        kind: SurfaceSpecKind,
        title: String? = nil,
        description: String? = nil,
        workingDirectory: String? = nil,
        command: String? = nil,
        url: String? = nil,
        filePath: String? = nil,
        metadata: [String: PersistedJSONValue]? = nil,
        paneMetadata: [String: PersistedJSONValue]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.description = description
        self.workingDirectory = workingDirectory
        self.command = command
        self.url = url
        self.filePath = filePath
        self.metadata = metadata
        self.paneMetadata = paneMetadata
    }
}

/// Mirrors `SessionWorkspaceLayoutSnapshot` so Phase 1 Snapshot capture is
/// a structural copy. `SessionSplitOrientation` and Bonsplit's
/// `SplitOrientation` are the two sides of the translation, handled inside
/// the executor — callers stay in plan-space.
indirect enum LayoutTreeSpec: Codable, Sendable, Equatable {
    case pane(PaneSpec)
    case split(SplitSpec)

    private enum CodingKeys: String, CodingKey { case type, pane, split }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(PaneSpec.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SplitSpec.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "LayoutTreeSpec: unsupported node type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }

    struct PaneSpec: Codable, Sendable, Equatable {
        /// Plan-local surface ids referenced into `WorkspaceApplyPlan.surfaces`.
        /// Order matches tab order in the pane. At least one entry required.
        var surfaceIds: [String]
        /// Index into `surfaceIds` of the initially selected tab. Defaults to 0.
        var selectedIndex: Int?

        init(surfaceIds: [String], selectedIndex: Int? = nil) {
            self.surfaceIds = surfaceIds
            self.selectedIndex = selectedIndex
        }
    }

    struct SplitSpec: Codable, Sendable, Equatable {
        var orientation: Orientation
        /// 0...1. Mirrors `SessionSplitLayoutSnapshot.dividerPosition`.
        var dividerPosition: Double
        var first: LayoutTreeSpec
        var second: LayoutTreeSpec

        enum Orientation: String, Codable, Sendable, Equatable {
            case horizontal
            case vertical
        }

        init(
            orientation: Orientation,
            dividerPosition: Double,
            first: LayoutTreeSpec,
            second: LayoutTreeSpec
        ) {
            self.orientation = orientation
            self.dividerPosition = dividerPosition
            self.first = first
            self.second = second
        }
    }
}

/// Caller-supplied knobs for `WorkspaceLayoutExecutor.apply`. Defaults match
/// Phase 0's acceptance-fixture expectations.
struct ApplyOptions: Codable, Sendable, Equatable {
    /// Select + foreground the created workspace once ready. Defaults `true`
    /// so the debug CLI behaves like `workspace.create`. Passed through to
    /// `TabManager.addWorkspace(select:)`.
    var select: Bool
    /// Per-step deadline guard (ms). If any `StepTiming` exceeds it the
    /// executor appends a warning but continues — partial-failure semantics,
    /// not hard abort. A zero value disables the guard. Default: 2_000 ms,
    /// matching the acceptance target.
    var perStepTimeoutMs: Int
    /// Hint for callers that want to bypass the welcome/default-grid
    /// auto-spawn. The executor always passes `false` to
    /// `TabManager.addWorkspace(autoWelcomeIfNeeded:)` regardless — the field
    /// exists for future (Phase 1 restore) callers.
    var autoWelcomeIfNeeded: Bool

    init(
        select: Bool = true,
        perStepTimeoutMs: Int = 2_000,
        autoWelcomeIfNeeded: Bool = false
    ) {
        self.select = select
        self.perStepTimeoutMs = perStepTimeoutMs
        self.autoWelcomeIfNeeded = autoWelcomeIfNeeded
    }
}

/// Timing record emitted once per logical step inside `apply()`. Consumers
/// (the acceptance fixture, a future debug CLI, eventually the v2 socket
/// response) use these to attribute budget overruns to a named step.
struct StepTiming: Codable, Sendable, Equatable {
    /// Examples: `"validate"`, `"workspace.create"`, `"metadata.workspace.write"`,
    /// `"surface[<planId>].create"`, `"layout.split[<index>].create"`,
    /// `"metadata.surface[<planId>].write"`, `"metadata.pane[<planId>].write"`,
    /// `"surface[<planId>].command.enqueue"`, `"refs.assemble"`, `"total"`.
    var step: String
    var durationMs: Double

    init(step: String, durationMs: Double) {
        self.step = step
        self.durationMs = durationMs
    }
}

/// Machine-readable partial-failure record. Human-readable message is carried
/// in `message`; the code lets Phase 1 Snapshot restore branch without
/// parsing strings.
struct ApplyFailure: Codable, Sendable, Equatable {
    /// Stable code. Additions are backwards-compatible. Known values:
    /// `"validation_failed"`, `"surface_create_failed"`,
    /// `"metadata_write_failed"`, `"metadata_override"`, `"split_failed"`,
    /// `"unknown_surface_ref"`, `"duplicate_surface_id"`,
    /// `"duplicate_surface_reference"`, `"orphan_surface"`,
    /// `"mailbox_non_string_value"`, `"unsupported_version"`,
    /// `"working_directory_not_applied"`, `"divider_apply_failed"`,
    /// `"divider_clamped"`, `"per_step_timeout_exceeded"`,
    /// `"seed_panel_missing"`.
    var code: String
    /// Matches a `StepTiming.step` when possible.
    var step: String
    var message: String

    init(code: String, step: String, message: String) {
        self.code = code
        self.step = step
        self.message = message
    }
}

struct ApplyResult: Codable, Sendable, Equatable {
    /// Live workspace ref (`workspace:N`) assigned by the v2 ref helper after
    /// creation. Empty string if the plan failed validation before the
    /// workspace was created.
    var workspaceRef: String
    /// Plan-local surface id → live `surface:N` ref. Missing entries indicate
    /// a creation failure whose detail surfaces in `failures`.
    var surfaceRefs: [String: String]
    /// Plan-local surface id → `pane:N` of the pane hosting that surface.
    var paneRefs: [String: String]
    var timings: [StepTiming]
    /// Free-form human-readable warnings. Mirrored in `failures` when the
    /// warning has a stable code.
    var warnings: [String]
    var failures: [ApplyFailure]

    init(
        workspaceRef: String = "",
        surfaceRefs: [String: String] = [:],
        paneRefs: [String: String] = [:],
        timings: [StepTiming] = [],
        warnings: [String] = [],
        failures: [ApplyFailure] = []
    ) {
        self.workspaceRef = workspaceRef
        self.surfaceRefs = surfaceRefs
        self.paneRefs = paneRefs
        self.timings = timings
        self.warnings = warnings
        self.failures = failures
    }
}
