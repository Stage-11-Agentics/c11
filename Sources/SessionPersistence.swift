import CoreGraphics
import Foundation
import Bonsplit

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum WindowGeometryPersistenceStore {
    struct Geometry: Codable, Sendable {
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    static let defaultsKey = "cmux.session.lastWindowGeometry.v1"

    static func load(defaults: UserDefaults = .standard) -> Geometry? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Geometry.self, from: data)
    }

    static func encodedData(frame: SessionRectSnapshot?, display: SessionDisplaySnapshot?) -> Data? {
        guard let frame else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Geometry(frame: frame, display: display))
    }

    /// Compare with persisted bytes rather than a process-local cache so both
    /// window-close saves and background autosaves skip unchanged mutations.
    /// Older JSON key ordering can normalize once, without changing the schema.
    static func persist(_ data: Data?, defaults: UserDefaults = .standard) {
        if let data {
            guard defaults.data(forKey: defaultsKey) != data else { return }
            defaults.set(data, forKey: defaultsKey)
#if DEBUG
            dlog("session.geometry.write bytes=\(data.count)")
#endif
        } else {
            guard defaults.object(forKey: defaultsKey) != nil else { return }
            defaults.removeObject(forKey: defaultsKey)
#if DEBUG
            dlog("session.geometry.remove")
#endif
        }
    }
}

enum SessionPersistencePolicy {
    static let defaultSidebarWidth: Double = 200
    static let minimumSidebarWidth: Double = 180
    static let maximumSidebarWidth: Double = 600
    static let defaultWindowWidth: Double = 1120
    static let defaultWindowHeight: Double = 840
    static let minimumWindowWidth: Double = 900
    static let minimumWindowHeight: Double = 640
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000

    /// C11-24: startup-restore agent restart.
    ///
    /// When `true` (default), `Workspace.restoreSessionSnapshot` consults the
    /// Phase 1 `AgentRestartRegistry` for each restored terminal surface that
    /// carries a recognised `terminal_type` and a captured `claude.session_id`,
    /// and sends the synthesised resume command (e.g.
    /// `claude --dangerously-skip-permissions --resume <id>\n`) into the
    /// restored terminal panel after a short startup delay.
    ///
    /// Setting `CMUX_DISABLE_AGENT_RESTART=1` disables auto-resume — the
    /// workspace layout still restores, but no resume commands are sent.
    /// App-launch-scope only — set via `launchctl setenv` or the parent shell
    /// before launching c11; setting it on the `c11` CLI invocation has no
    /// effect. Kept as a one-release rollback safety net.
    static var agentRestartOnRestoreEnabled: Bool {
        !envFlagEnabled("CMUX_DISABLE_AGENT_RESTART")
    }

    /// Seconds to wait after `restoreSessionSnapshot` returns before
    /// dispatching agent-restart commands. Gives Ghostty PTYs and their
    /// shells time to come up so `TerminalPanel.sendText` has a live
    /// surface to write into. The TerminalPanel pre-ready queue would
    /// also catch early writes, but a small delay keeps the timing in a
    /// regime that has been hand-tested rather than relying purely on
    /// queue semantics.
    static let agentRestartDelay: TimeInterval = 2.5

    /// C11-156: per-agent spacing applied on top of `agentRestartDelay` when a
    /// restore resumes more than one agent. Without it, every restored agent's
    /// resume command is typed in the same main-queue turn, so N agents boot
    /// and fire their SessionStart hooks (each a `conversation.push` +
    /// `set_agent_pid` socket round-trip onto the main thread) simultaneously —
    /// a thundering herd that, on a multi-agent workspace, beachballs the app
    /// right after a crash-restore (observed: a fresh process stalled 44s on
    /// resume; see ~/Library/Logs/c11/hang.log). Spreading the resumes by this
    /// interval flattens that burst. The Nth agent resumes at
    /// `agentRestartDelay + N * agentRestartStagger`.
    static let agentRestartStagger: TimeInterval = 0.35

    private static func envFlagEnabled(_ name: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    static func sanitizedSidebarWidth(_ candidate: Double?) -> Double {
        let fallback = defaultSidebarWidth
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, minimumSidebarWidth), maximumSidebarWidth)
    }

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SessionRestorePolicy {
    static func isRunningUnderAutomatedTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func shouldAttemptRestore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // QA launch (`C11_QA_LAUNCH`) is the deterministic override: in QA
        // mode the resume decision comes straight from the flag — load the
        // snapshot iff resume was requested, regardless of args or test
        // markers. This wins over everything below so QA runs are reproducible.
        let qa = QALaunchPolicy.current(environment: environment)
        if qa.isActive {
            return qa.shouldResume
        }
        if environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests(environment: environment) {
            return false
        }

        let extraArgs = arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }

        // Any explicit launch argument is treated as an explicit open intent.
        return extraArgs.isEmpty
    }
}

struct SessionRectSnapshot: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SessionDisplaySnapshot: Codable, Sendable {
    var displayID: UInt32?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
        }
    }
}

struct SessionSidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SessionSidebarSelection
    var width: Double?
}

struct SessionStatusEntrySnapshot: Codable, Sendable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
    /// Tier 1 Phase 3: persisted fields previously dropped at serialization.
    /// All optional for backcompat with pre-Phase-3 snapshots.
    var url: String?
    var priority: Int?
    var format: String?
    /// Marker for entries restored from a prior session. The original agent's
    /// process is gone; the entry is still shown (with reduced emphasis) until
    /// the next real write clears the flag. Optional for backcompat.
    var staleFromRestart: Bool?
}

struct SessionLogEntrySnapshot: Codable, Sendable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct SessionProgressSnapshot: Codable, Sendable {
    var value: Double
    var label: String?
    /// C11-162 (TEL-2): wall-clock stamp (seconds since 1970) of when this
    /// progress value was written, so decay freshness survives relaunch instead
    /// of resetting to "now". Optional so pre-existing snapshots still decode.
    var timestamp: TimeInterval?
}

struct SessionGitBranchSnapshot: Codable, Sendable {
    var branch: String
    var isDirty: Bool
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
    /// Durable browser-to-agent association. Optional so pre-companion
    /// session-v1 snapshots continue to decode unchanged.
    var linkedAgent: AgentPanelLink? = nil
}

struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    /// Absolute path to the markdown file, or nil for an unbound panel
    /// (empty state — not yet bound to a file). Unbound panels are not
    /// recreated on restore; see Workspace.createPanel(from:inPane:).
    var filePath: String?
    /// Font scale multiplier (1.0 = default). Optional for backwards
    /// compatibility; old snapshots decode with nil.
    var fontScale: Double? = nil
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    /// Logical surface creation time. Optional so legacy snapshots remain
    /// honest: absence means "not recorded", never "created on restore".
    var createdAt: Date? = nil
    var type: PanelType
    var title: String?
    var customTitle: String?
    /// Per-surface tab color, normalized as `#RRGGBB`. Optional for
    /// backwards compatibility with pre-C11-10 snapshots; old snapshots
    /// decode with `customColor == nil` via `decodeIfPresent`.
    var customColor: String? = nil
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?

    /// Tier 1 Phase 2: persisted `SurfaceMetadataStore` values for this
    /// surface. Optional for backcompat with pre-Phase-2 snapshots; older
    /// builds ignore the field. Numbers round-trip as `Double`; see
    /// `PersistedJSONValue`.
    var metadata: [String: PersistedJSONValue]?
    /// Parallel sidecar: per-key `(source, ts)` record preserving the
    /// precedence chain across restarts. See `PersistedMetadataSource`.
    var metadataSources: [String: PersistedMetadataSource]?

    /// C11-24: per-surface ConversationRefs for the active conversation
    /// (and v1.x history). Embedded directly on the panel snapshot so the
    /// conversation follows the panel across a restart naturally. Optional
    /// for backcompat with pre-C11-24 snapshots; the
    /// read-side bridge in `WorkspaceSnapshotConversationBridge` lifts
    /// legacy `claude.session_id` reserved metadata into a ConversationRef
    /// for one release window (removed in 0.46.0 / v1.1).
    ///
    /// `history: []` is written explicitly as an empty array (not omitted)
    /// for stable JSON output across v1/v2.
    var surfaceConversations: PanelConversations? = nil

    /// C11-164 (RES-2): persisted `SurfaceActivityTracker.lastActivity` floor
    /// for this surface. The Codex/pi/omp scrape filters use "candidate mtime
    /// ≥ surface lastActivityTimestamp" to disambiguate which on-disk session
    /// belongs to which pane after a crash. The live tracker is in-memory only,
    /// so without persisting this the floor was lost on every restart and the
    /// restore-time scrape ran with `lastActivityTimestamp: nil` (widening the
    /// candidate set → spurious ambiguity). Optional for backcompat: pre-C11-164
    /// snapshots decode with `lastActivityAt == nil` (no floor, prior behaviour).
    /// Keyed implicitly by this panel's `id` — the same id the store and
    /// `ScrapeCaptureContext` key on across a restart.
    var lastActivityAt: Date? = nil

    /// C11-243: when the operator last looked at this tab (`SurfaceSeenTracker`).
    /// A tab being seen at capture time is stamped with the capture time. Optional
    /// for backcompat: older snapshots decode with `lastSeenAt == nil`.
    var lastSeenAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case id, type, title, customTitle, customColor, directory, isPinned,
             isManuallyUnread, gitBranch, listeningPorts, ttyName,
             terminal, browser, markdown, metadata, metadataSources
        case createdAt = "created_at"
        case surfaceConversations = "surface_conversations"
        case lastActivityAt = "last_activity_at"
        case lastSeenAt = "last_seen_at"
    }
}

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

struct SessionAreaLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]
    var selectedPanelId: UUID?

    /// CMUX-11 Phase 3: bonsplit pane UUID at save time. The production
    /// `Workspace.restoreSessionSnapshot` path pairs each leaf with its
    /// freshly minted `PaneID` by structural tree position (see
    /// `restoreSessionLayoutNode`); it does not read this field. The DEBUG
    /// `debugForceMetadataSaveAndLoad` rail does not rebuild the layout, so
    /// it relies on this field to look the live pane up by UUID. Optional
    /// for backcompat with pre-Phase-3 snapshots and for the synthetic
    /// empty-leaf fallback emitted when a split's rebuild fails; defaulted
    /// to nil so existing two-arg construction sites keep compiling.
    var id: UUID? = nil

    /// CMUX-11 Phase 3: persisted `PaneMetadataStore` values for this pane.
    /// Optional for backcompat. Numbers round-trip as `Double` per
    /// `PersistedJSONValue`; the 64 KiB per-pane cap is enforced at the
    /// persistence boundary on save.
    var metadata: [String: PersistedJSONValue]? = nil

    /// Parallel sidecar preserving the per-key `(source, ts)` record so the
    /// `explicit > declare > osc > heuristic` precedence chain survives a
    /// restart. See `PersistedMetadataSource`.
    var metadataSources: [String: PersistedMetadataSource]? = nil

    /// Round five: whether this area's tab rail was open (Rail layout).
    /// Optional for backcompat; absent means closed.
    var railOpen: Bool? = nil
}

struct SessionSplitLayoutSnapshot: Codable, Sendable {
    var orientation: SessionSplitOrientation
    var dividerPosition: Double
    var first: SessionWorkspaceLayoutSnapshot
    var second: SessionWorkspaceLayoutSnapshot
}

indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(SessionAreaLayoutSnapshot)
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionAreaLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
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
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    var id: UUID
    var processTitle: String
    var customTitle: String?
    var stableDefaultTitle: String? = nil
    var customColor: String?
    var isPinned: Bool
    var groupId: UUID? = nil
    var currentDirectory: String
    /// Stable workspace project root. Optional so pre-C11-194 snapshots decode.
    var rootDirectory: String? = nil
    /// C11-238: whether a rootless workspace still adopts its first reported
    /// cwd. False after an operator clear. Nil in older snapshots, which
    /// restore as armed when the root is nil.
    var rootAdoptionArmed: Bool? = nil
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
    /// Operator-authored workspace metadata (e.g. description, icon).
    /// Optional for backward compatibility with pre-metadata snapshots.
    var metadata: [String: String]?
    /// Session-only active companion context. Blueprints and snapshots do not
    /// carry this transient focus-derived value.
    var activeAgentSurfaceId: UUID? = nil

    // Pinned on-disk keys: session decode is all-or-nothing, so these raw
    // strings never change even when the Swift names do.
    private enum CodingKeys: String, CodingKey {
        case id = "id"
        case processTitle = "processTitle"
        case customTitle = "customTitle"
        case stableDefaultTitle = "stableDefaultTitle"
        case customColor = "customColor"
        case isPinned = "isPinned"
        case groupId = "groupId"
        case currentDirectory = "currentDirectory"
        case rootDirectory = "rootDirectory"
        case rootAdoptionArmed = "rootAdoptionArmed"
        case focusedPanelId = "focusedPanelId"
        case layout = "layout"
        case panels = "panels"
        case statusEntries = "statusEntries"
        case logEntries = "logEntries"
        case progress = "progress"
        case gitBranch = "gitBranch"
        case metadata = "metadata"
        case activeAgentSurfaceId = "activeAgentSurfaceId"
    }
}

/// Repair the duplicate identities seen in B024 before any restore consumer
/// creates tabs, rehydrates metadata, or schedules agent resumes.
enum SessionRestoreNormalization {
    /// Startup recovery reads activity, scrape contexts, and conversation seeds
    /// before it installs workspaces. All of those consumers must see the same
    /// first records as the later workspace restore.
    static func prepareStartupSnapshot(
        _ input: AppSessionSnapshot,
        reportDrop: (String) -> Void = { NSLog("%@", $0) }
    ) -> AppSessionSnapshot {
        var snapshot = input
        for windowIndex in snapshot.windows.indices {
            for workspaceIndex in snapshot.windows[windowIndex].workspaceManager.workspaces.indices {
                let workspace = snapshot.windows[windowIndex].workspaceManager.workspaces[workspaceIndex]
                let normalized = normalize(workspace)
                snapshot.windows[windowIndex].workspaceManager.workspaces[workspaceIndex] = normalized.snapshot
                for drop in normalized.drops {
                    reportDrop(drop.diagnostic(workspaceId: workspace.id))
                }
            }
        }
        return snapshot
    }

    struct Drop: Equatable {
        enum Reason: String {
            case duplicateRecord = "duplicate_record"
            case duplicateLayoutReference = "duplicate_layout_reference"
        }

        let tabId: UUID
        let reason: Reason

        func diagnostic(workspaceId: UUID) -> String {
            "session.restore.drop workspace=\(workspaceId) tab=\(tabId) reason=\(reason.rawValue)"
        }
    }

    static func normalize(_ input: SessionWorkspaceSnapshot) -> (snapshot: SessionWorkspaceSnapshot, drops: [Drop]) {
        var snapshot = input
        var drops: [Drop] = []
        var knownIds = Set<UUID>()
        snapshot.panels = input.panels.filter { panel in
            guard knownIds.insert(panel.id).inserted else {
                drops.append(Drop(tabId: panel.id, reason: .duplicateRecord))
                return false
            }
            return true
        }

        var placedIds = Set<UUID>()
        func normalizeLayout(_ node: SessionWorkspaceLayoutSnapshot) -> SessionWorkspaceLayoutSnapshot {
            switch node {
            case .pane(var pane):
                pane.panelIds = pane.panelIds.filter { id in
                    // restorePane already ignores unknown records. Leave those
                    // references alone rather than broadening this repair.
                    guard knownIds.contains(id) else { return true }
                    guard placedIds.insert(id).inserted else {
                        drops.append(Drop(tabId: id, reason: .duplicateLayoutReference))
                        return false
                    }
                    return true
                }
                if let selected = pane.selectedPanelId,
                   knownIds.contains(selected), !pane.panelIds.contains(selected) {
                    pane.selectedPanelId = pane.panelIds.first { knownIds.contains($0) }
                }
                return .pane(pane)
            case .split(var split):
                split.first = normalizeLayout(split.first)
                split.second = normalizeLayout(split.second)
                return .split(split)
            }
        }
        snapshot.layout = normalizeLayout(input.layout)
        return (snapshot, drops)
    }
}

struct SessionWorkspaceManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
    var workspaceGroups: [WorkspaceGroup]? = nil
}

struct SessionWindowSnapshot: Codable, Sendable {
    var frame: SessionRectSnapshot?
    var display: SessionDisplaySnapshot?
    var workspaceManager: SessionWorkspaceManagerSnapshot
    var sidebar: SessionSidebarSnapshot

    // Persisted session files key the workspace list as `tabManager`; keep that on-disk key.
    enum CodingKeys: String, CodingKey {
        case frame
        case display
        case workspaceManager = "tabManager"
        case sidebar
    }
}

struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
    var focusHistory: FocusHistorySnapshot? = nil
}

enum SessionPersistenceStore {
    enum SavePurpose: Equatable, Sendable {
        case autosave
        case operatorRequested
        case cleanShutdown
    }

    static let poorerSnapshotHoldbackInterval: TimeInterval = 5 * 60
    static let historyRestoreEnvironmentKey = "C11_SESSION_HISTORY_RESTORE_FILE"

    static func load(
        fileURL: URL? = nil,
        historyFileURL: URL? = nil
    ) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        if let historyFileURL,
           let snapshot = loadHistorySnapshot(from: historyFileURL, forSnapshot: fileURL) {
            return snapshot
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard var snapshot = decodeSnapshot(data) else { return nil }
        // A window without workspaces is not a restorable window. In particular,
        // do not turn stale empty-window records into extra fallback workspaces.
        snapshot.windows.removeAll { $0.workspaceManager.workspaces.isEmpty }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    /// Resolves the operator's one-shot startup recovery choice. The selected
    /// file is still validated against the canonical snapshot's own history
    /// directory by `loadHistorySnapshot` before it can be used.
    static func startupHistoryRestoreURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let rawPath = environment[historyRestoreEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else { return nil }
        return URL(
            fileURLWithPath: (rawPath as NSString).expandingTildeInPath,
            isDirectory: false
        ).standardizedFileURL
    }

    /// Loads one archived snapshot only when it is a named archive for this
    /// live snapshot and resolves to a regular file directly inside that
    /// snapshot's history directory. Symlinked escapes are rejected too.
    static func loadHistorySnapshot(
        from historyFileURL: URL,
        forSnapshot snapshotFileURL: URL
    ) -> AppSessionSnapshot? {
        let historyDirectory = historyDirectoryURL(for: snapshotFileURL).standardizedFileURL
        let candidate = historyFileURL.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == historyDirectory.path else { return nil }
        guard historyFileURLs(for: snapshotFileURL).contains(where: {
            $0.standardizedFileURL.path == candidate.path
        }) else { return nil }

        let resolvedSnapshotDirectory = snapshotFileURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let resolvedHistoryDirectory = historyDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedHistoryDirectory.deletingLastPathComponent().path == resolvedSnapshotDirectory.path else { return nil }
        guard resolvedCandidate.deletingLastPathComponent().path == resolvedHistoryDirectory.path else { return nil }
        guard let data = try? Data(contentsOf: resolvedCandidate),
              var snapshot = decodeSnapshot(data) else { return nil }
        snapshot.windows.removeAll { $0.workspaceManager.workspaces.isEmpty }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    @discardableResult
    static func save(
        _ snapshot: AppSessionSnapshot,
        fileURL: URL? = nil,
        purpose: SavePurpose = .autosave,
        now: Date = Date()
    ) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return true
            }
            if purpose == .autosave,
               shouldHoldBackPoorerSnapshot(snapshot, replacing: fileURL, now: now) {
                return true
            }
            guard archiveBeforeFirstOverwrite(fileURL: fileURL, now: now) else { return false }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func decodeSnapshot(_ data: Data) -> AppSessionSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(AppSessionSnapshot.self, from: data),
              snapshot.version == SessionSnapshotSchema.currentVersion else { return nil }
        return snapshot
    }

    private static func shouldHoldBackPoorerSnapshot(
        _ snapshot: AppSessionSnapshot,
        replacing fileURL: URL,
        now: Date
    ) -> Bool {
        guard let existingData = try? Data(contentsOf: fileURL),
              let existingSnapshot = decodeSnapshot(existingData),
              let modifiedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }

        let age = now.timeIntervalSince(modifiedAt)
        guard age < poorerSnapshotHoldbackInterval else { return false }
        let existingIdentities = normalizedIdentityCounts(in: existingSnapshot)
        let incomingIdentities = normalizedIdentityCounts(in: snapshot)
        return incomingIdentities.workspaces.count < existingIdentities.workspaces.count
            || incomingIdentities.panels.count < existingIdentities.panels.count
    }

    /// Holdback compares restorable identities, not raw record counts. Use the
    /// same per-workspace normalization as startup restore so repairing
    /// duplicate records cannot make an autosave appear poorer.
    private static func normalizedIdentityCounts(
        in snapshot: AppSessionSnapshot
    ) -> (workspaces: Set<UUID>, panels: Set<UUID>) {
        var workspaceIDs = Set<UUID>()
        var panelIDs = Set<UUID>()
        for window in snapshot.windows {
            for workspace in window.workspaceManager.workspaces {
                workspaceIDs.insert(workspace.id)
                let normalized = SessionRestoreNormalization.normalize(workspace).snapshot
                for panel in normalized.panels {
                    panelIDs.insert(panel.id)
                }
            }
        }
        return (workspaceIDs, panelIDs)
    }

    private static func encodedSnapshotData(_ snapshot: AppSessionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        guard archiveBeforeFirstOverwrite(fileURL: fileURL) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static let historyDirectoryName = "session-history"
    static let historyRetentionCount = 10
    private static let archiveLock = NSLock()
    private nonisolated(unsafe) static var archivedFilePaths = Set<String>()

    /// The session file is the only copy of the previous session. The first
    /// time this process is about to overwrite or remove it, copy it to
    /// `session-history/<name>-<UTC timestamp>.json` beside it, so a launch
    /// that skips, filters or never attempts the restore cannot destroy the
    /// prior session. Keeps the newest `historyRetentionCount` copies per file.
    /// Returns false when the copy failed; the caller must not overwrite, and
    /// the next attempt retries the copy.
    @discardableResult
    static func archiveBeforeFirstOverwrite(fileURL: URL, now: Date = Date()) -> Bool {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        let key = fileURL.standardizedFileURL.path
        guard !archivedFilePaths.contains(key) else { return true }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            archivedFilePaths.insert(key)
            return true
        }

        let historyDirectory = historyDirectoryURL(for: fileURL)
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let archiveURL = historyDirectory.appendingPathComponent(
            "\(stem)-\(formatter.string(from: now)).json",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true, attributes: nil)
            try fileManager.copyItem(at: fileURL, to: archiveURL)
        } catch {
            return false
        }
        archivedFilePaths.insert(key)

        let archives = historyFileURLs(for: fileURL)
        for stale in archives.dropFirst(historyRetentionCount) {
            try? fileManager.removeItem(at: stale)
        }
        return true
    }

    static func historyDirectoryURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    /// Archived copies of `fileURL`, newest first.
    static func historyFileURLs(for fileURL: URL) -> [URL] {
        // Exact match on the timestamp suffix: dev-build stems can prefix one
        // another (`…debug.foo` and `…debug.foo-bar`).
        let prefix = fileURL.deletingPathExtension().lastPathComponent + "-"
        let timestamp = try? NSRegularExpression(pattern: #"^\d{8}T\d{6}\.\d{3}Z\.json$"#)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: historyDirectoryURL(for: fileURL),
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix), let timestamp else { return false }
                let suffix = String(name.dropFirst(prefix.count))
                return timestamp.firstMatch(
                    in: suffix,
                    range: NSRange(suffix.startIndex..., in: suffix)
                ) != nil
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func defaultSnapshotFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.stage11.c11"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        StateDirectoryMigration.ensureMigrated()
        return resolvedAppSupport
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("session-\(safeBundleId).json", isDirectory: false)
    }
}

enum SessionScrollbackReplayStore {
    static let environmentKey = "CMUX_RESTORE_SCROLLBACK_FILE"
    private static let directoryName = "cmux-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedScrollback(scrollback) else { return [:] }
        guard let replayFileURL = writeReplayFile(
            contents: replayText,
            tempDirectory: tempDirectory
        ) else {
            return [:]
        }
        return [environmentKey: replayFileURL.path]
    }

    private static func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(scrollback) else { return nil }
        return ansiSafeReplayText(truncated)
    }

    /// Preserve ANSI color state safely across replay boundaries.
    private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
