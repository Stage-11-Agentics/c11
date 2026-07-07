import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

extension Notification.Name {
    static let socketListenerDidStart = Notification.Name("cmux.socketListenerDidStart")
    static let terminalSurfaceDidBecomeReady = Notification.Name("cmux.terminalSurfaceDidBecomeReady")
    static let terminalSurfaceHostedViewDidMoveToWindow = Notification.Name("cmux.terminalSurfaceHostedViewDidMoveToWindow")
    static let mainWindowContextsDidChange = Notification.Name("cmux.mainWindowContextsDidChange")
    static let browserDownloadEventDidArrive = Notification.Name("cmux.browserDownloadEventDidArrive")
}

/// Pure validation for the `--cwd` flag on `new-split` / `new-pane`
/// (socket methods `surface.split` / `pane.create`).
///
/// Kept free of any TerminalController/AppKit state so it is exercisable from
/// `c11LogicTests` without launching the app. The socket handler adapts the
/// `Outcome` onto its result envelope.
enum CwdParamResolution {
    /// The result of validating a raw `cwd` param value.
    enum Outcome: Equatable {
        /// No cwd supplied (or the `inherit` keyword): use the default
        /// inheritance chain (parent panel cwd → workspace cwd → $HOME).
        case inherit
        /// A validated, absolute, existing directory path to spawn the shell in.
        case path(String)
        /// The supplied value is unusable; `code`/`message` map to the socket
        /// error envelope, `path` is the offending standardized path when known.
        case invalid(code: String, message: String, path: String?)
    }

    /// Validate a raw `cwd` param value (as received off the socket / CLI).
    ///
    /// - A missing value, a non-string, an empty string, or the literal
    ///   `"inherit"` (case-insensitive) → `.inherit`.
    /// - A non-empty string → tilde-expanded + standardized, then required to be
    ///   absolute, to exist, and to be a directory. Any failure → `.invalid`
    ///   so the spawn never silently lands in $HOME.
    static func resolve(_ raw: Any?) -> Outcome {
        guard let raw else { return .inherit }
        guard let rawStr = raw as? String else {
            return .invalid(code: "invalid_params", message: "cwd must be a string", path: nil)
        }
        let trimmed = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "inherit" {
            return .inherit
        }
        let expandedPath = NSString(string: trimmed).expandingTildeInPath
        let resolvedPath = NSString(string: expandedPath).standardizingPath
        guard resolvedPath.hasPrefix("/") else {
            return .invalid(code: "invalid_params", message: "cwd must be an absolute path: \(resolvedPath)", path: resolvedPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return .invalid(code: "not_found", message: "cwd directory not found: \(resolvedPath)", path: resolvedPath)
        }
        guard isDir.boolValue else {
            return .invalid(code: "invalid_params", message: "cwd is not a directory: \(resolvedPath)", path: resolvedPath)
        }
        return .path(resolvedPath)
    }
}

/// Pure composition for `default-agent launch --in-surface`'s shell line and
/// prompt-delivery decision.
///
/// `launchInExistingSurface` types a single composed line into an existing
/// terminal's PTY: an optional `cd <cwd> &&` prefix, the agent's bare launcher,
/// and — for claude-code only — the prompt as a single-quoted positional. For
/// every other TUI the prompt cannot ride the launch line (those agents don't
/// accept a positional prompt) so it is delivered after the agent has booted via
/// a second, delayed `sendText`. This enum captures that decision free of any
/// TerminalController/AppKit state so it is exercisable from `c11LogicTests`.
enum DefaultAgentLaunchComposition: Equatable {
    /// The shell line to type+submit into the surface immediately, plus the
    /// prompt (if any) that must be delivered after the agent boots.
    struct Plan: Equatable {
        /// The composed `[cd <cwd> && ]<launcher>[ '<prompt>']` line.
        let launchLine: String
        /// When non-nil, the prompt to deliver via a delayed post-launch
        /// sendText (non-claude agents). nil means the prompt (if any) already
        /// rode the launch line, or there was no prompt.
        let delayedPrompt: String?
    }

    /// Compose the launch plan.
    ///
    /// - `agent`: the resolved agent type — only claude-code accepts a positional prompt.
    /// - `bareCommand`: the agent's launcher command (already resolved from config).
    /// - `cwd`: optional working directory; when non-empty a `cd <quoted> &&` prefix is prepended.
    /// - `prompt`: optional initial prompt.
    static func plan(
        agent: AgentType,
        bareCommand: String,
        cwd: String?,
        prompt: String?
    ) -> Plan {
        var line = ""
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            line += "cd \(DefaultAgentResolver.shellQuote(cwd)) && "
        }
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPrompt = (trimmedPrompt?.isEmpty == false)
        if agent == .claudeCode, let trimmedPrompt, hasPrompt {
            line += "\(bareCommand) \(DefaultAgentResolver.shellQuote(trimmedPrompt))"
            return Plan(launchLine: line, delayedPrompt: nil)
        }
        line += bareCommand
        // Non-claude agents: prompt rides a separate post-ready sendText.
        let delayed = (hasPrompt ? trimmedPrompt : nil)
        return Plan(launchLine: line, delayedPrompt: delayed)
    }
}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    struct SocketListenerHealth: Sendable {
        let isRunning: Bool
        let acceptLoopAlive: Bool
        let socketPathMatches: Bool
        let socketPathExists: Bool

        var failureSignals: [String] {
            var signals: [String] = []
            if !isRunning { signals.append("not_running") }
            if !acceptLoopAlive { signals.append("accept_loop_dead") }
            if !socketPathMatches { signals.append("socket_path_mismatch") }
            if !socketPathExists { signals.append("socket_missing") }
            return signals
        }

        var isHealthy: Bool {
            failureSignals.isEmpty
        }
    }

    static let shared = TerminalController()

    /// Set by `AppDelegate.applicationShouldTerminate` /
    /// `applicationWillTerminate` / `persistSessionForUpdateRelaunch` and
    /// read by `system.ping`. The `c11 claude-hook session-end` CLI queries
    /// this to decide whether to skip the surface-metadata clear during a
    /// c11 shutdown — see `SessionEndShutdownPolicy` for the rationale.
    /// Plain `var`: read and write are both on the main actor.
    private var isTerminatingApp: Bool = false

    func setIsTerminatingApp(_ value: Bool) {
        isTerminatingApp = value
    }

    // Empty until `start(...)` binds. Initializing to the stable default would
    // make `stop()` unlink that shared path even in a never-started controller
    // — the C11-105 production unlink mechanism. See `stop()` for the matching
    // empty-path guard.
    private nonisolated(unsafe) var socketPath = ""
    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var acceptLoopAlive = false
    private nonisolated(unsafe) var activeAcceptLoopGeneration: UInt64 = 0
    private nonisolated(unsafe) var nextAcceptLoopGeneration: UInt64 = 0
    private nonisolated(unsafe) var pendingAcceptLoopRearmGeneration: UInt64?
    private nonisolated(unsafe) var pendingAcceptLoopResumeGeneration: UInt64?
    private nonisolated(unsafe) var listenerStartInProgress = false
    private nonisolated let listenerStateLock = NSLock()
    private var clientHandlers: [Int32: Thread] = [:]
    var tabManager: TabManager?
    var accessMode: SocketControlMode = .c11Only
    private let myPid = getpid()
    private nonisolated(unsafe) static var socketCommandPolicyDepth: Int = 0
    private nonisolated(unsafe) static var socketCommandFocusAllowanceStack: [Bool] = []
    private nonisolated static let socketCommandPolicyLock = NSLock()
    private nonisolated static let socketListenBacklog: Int32 = 128
    private nonisolated static let acceptFailureBaseBackoffMs = 10
    private nonisolated static let acceptFailureMaxBackoffMs = 5_000
    private nonisolated static let acceptFailureMinimumRearmDelayMs = 100
    private nonisolated static let acceptFailureRearmThreshold = 50
    private nonisolated static let socketProbePollTimeoutMs: Int32 = 100
    private nonisolated static let socketProbePollAttempts = 3
    private nonisolated static let socketProbePollRetryBackoffUs: useconds_t = 50_000
    private nonisolated static let socketListenerFailureCaptureCooldown: TimeInterval = 60
    private nonisolated static let socketListenerFailureCaptureLock = NSLock()
    private nonisolated(unsafe) static var socketListenerFailureLastCapturedAt: [String: Date] = [:]
    private nonisolated static let unixSocketPathMaxLength: Int = {
        var addr = sockaddr_un()
        // Reserve one byte for the null terminator.
        return MemoryLayout.size(ofValue: addr.sun_path) - 1
    }()

    private struct ListenerStateSnapshot {
        let socketPath: String
        let serverSocket: Int32
        let isRunning: Bool
        let acceptLoopAlive: Bool
        let activeGeneration: UInt64
        let pendingRearmGeneration: UInt64?
        let pendingResumeGeneration: UInt64?
        let listenerStartInProgress: Bool
    }

    enum AcceptFailureRecoveryAction: Equatable {
        case retryImmediately
        case resumeAfterDelay(delayMs: Int)
        case rearmAfterDelay(delayMs: Int)

        var delayMs: Int {
            switch self {
            case .retryImmediately:
                return 0
            case .resumeAfterDelay(let delayMs), .rearmAfterDelay(let delayMs):
                return delayMs
            }
        }

        var debugLabel: String {
            switch self {
            case .retryImmediately:
                return "retry_immediately"
            case .resumeAfterDelay:
                return "resume_after_delay"
            case .rearmAfterDelay:
                return "rearm_after_delay"
            }
        }
    }

    private enum SocketBindAttemptResult {
        case success(path: String)
        case pathTooLong(path: String)
        case failure(path: String, stage: String, errnoCode: Int32)
        /// A live peer is already accepting connections on this path; refusing to
        /// unlink it (C11-155). The caller must rebind elsewhere, never stomp.
        case peerAlive(path: String)
    }

    private static let focusIntentV1Commands: Set<String> = [
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app"
    ]

    private static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate"
    ]

    // C11-159: widened private->internal so per-domain socket handler
    // extensions in Sources/SocketHandlers/ can name this type. Module-internal
    // only (app target, no library API surface). See DX-5 widening inventory.
    enum V2HandleKind: String, CaseIterable {
        case window
        case workspace
        case pane
        case surface
    }

    var v2NextHandleOrdinal: [V2HandleKind: Int] = [
        .window: 1,
        .workspace: 1,
        .pane: 1,
        .surface: 1,
    ]
    var v2RefByUUID: [V2HandleKind: [UUID: String]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]
    var v2UUIDByRef: [V2HandleKind: [String: UUID]] = [
        .window: [:],
        .workspace: [:],
        .pane: [:],
        .surface: [:],
    ]

    private struct V2BrowserElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    private struct V2BrowserPendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    private final class V2BrowserUndefinedSentinel {}

    static let v2BrowserEvalEnvelopeTypeKey = "__cmux_t"
    static let v2BrowserEvalEnvelopeValueKey = "__cmux_v"
    static let v2BrowserEvalEnvelopeTypeUndefined = "undefined"
    static let v2BrowserEvalEnvelopeTypeValue = "value"

    var v2BrowserNextElementOrdinal: Int = 1
    var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]
    let v2BrowserUndefinedSentinel = V2BrowserUndefinedSentinel()
    var browserDownloadObserver: NSObjectProtocol?

    private init() {
        browserDownloadObserver = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var queue = self.v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                queue.append(event)
                self.v2BrowserDownloadEventsBySurface[surfaceId] = queue
            }
        }
    }

    private nonisolated func withListenerState<T>(_ body: () -> T) -> T {
        listenerStateLock.lock()
        defer { listenerStateLock.unlock() }
        return body()
    }

    private nonisolated func listenerStateSnapshot() -> ListenerStateSnapshot {
        withListenerState {
            ListenerStateSnapshot(
                socketPath: socketPath,
                serverSocket: serverSocket,
                isRunning: isRunning,
                acceptLoopAlive: acceptLoopAlive,
                activeGeneration: activeAcceptLoopGeneration,
                pendingRearmGeneration: pendingAcceptLoopRearmGeneration,
                pendingResumeGeneration: pendingAcceptLoopResumeGeneration,
                listenerStartInProgress: listenerStartInProgress
            )
        }
    }

    nonisolated func activeSocketPath(preferredPath: String) -> String {
        let snapshot = listenerStateSnapshot()
        if snapshot.isRunning || snapshot.acceptLoopAlive || snapshot.listenerStartInProgress || snapshot.serverSocket >= 0 {
            return snapshot.socketPath
        }
        return preferredPath
    }

    /// Test seam: the raw `socketPath` field without any
    /// running/preferred-path fallback. Used by C11-105 regression tests to
    /// assert a never-started controller does not carry a shared default
    /// that `stop()` would unlink.
    var socketPathSnapshot: String {
        withListenerState { socketPath }
    }

    /// Test seam: construct a fresh, never-started `TerminalController` whose
    /// fields are at their default-init values. The production code path
    /// always uses `TerminalController.shared`; this exists only so C11-105
    /// regression tests can observe the default state without rebinding the
    /// shared singleton mid-process.
    static func makeForTesting() -> TerminalController {
        TerminalController()
    }

    private nonisolated func shouldContinueAcceptLoop(generation: UInt64) -> Bool {
        withListenerState {
            isRunning && generation == activeAcceptLoopGeneration
        }
    }

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandPolicyDepth > 0
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        socketCommandPolicyLock.lock()
        defer { socketCommandPolicyLock.unlock() }
        return socketCommandFocusAllowanceStack.last ?? false
    }

    private func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    private nonisolated static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    nonisolated func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2)
        Self.socketCommandPolicyLock.lock()
        Self.socketCommandPolicyDepth += 1
        Self.socketCommandFocusAllowanceStack.append(allowsFocusMutation)
        Self.socketCommandPolicyLock.unlock()
        defer {
            Self.socketCommandPolicyLock.lock()
            if !Self.socketCommandFocusAllowanceStack.isEmpty {
                _ = Self.socketCommandFocusAllowanceStack.popLast()
            }
            Self.socketCommandPolicyDepth = max(0, Self.socketCommandPolicyDepth - 1)
            Self.socketCommandPolicyLock.unlock()
        }
        return body()
    }

#if DEBUG
    static func debugSocketCommandPolicySnapshot(
        commandKey: String,
        isV2: Bool
    ) -> (insideSuppressed: Bool, insideAllowsFocus: Bool, outsideSuppressed: Bool, outsideAllowsFocus: Bool) {
        var insideSuppressed = false
        var insideAllowsFocus = false
        _ = Self.shared.withSocketCommandPolicy(commandKey: commandKey, isV2: isV2) {
            insideSuppressed = Self.shouldSuppressSocketCommandActivation()
            insideAllowsFocus = Self.socketCommandAllowsInAppFocusMutations()
            return 0
        }
        return (
            insideSuppressed: insideSuppressed,
            insideAllowsFocus: insideAllowsFocus,
            outsideSuppressed: Self.shouldSuppressSocketCommandActivation(),
            outsideAllowsFocus: Self.socketCommandAllowsInAppFocusMutations()
        )
    }
#endif

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        // Tier 1 Phase 3: a stale-from-restart entry must always yield to the
        // first real write, even if the payload is identical. Without this,
        // an agent that re-announces the same status (common idempotent
        // pattern) would never clear the stale marker.
        if current.staleFromRestart { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?,
        checks: SidebarPullRequestChecksStatus?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        let effectiveChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.checks
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.checks != effectiveChecks
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    private struct SocketSurfaceKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private final class SocketFastPathState: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.stage11.c11.socket-fast-path")
        private var lastReportedDirectories: [SocketSurfaceKey: String] = [:]
        private var lastReportedShellStates: [SocketSurfaceKey: Workspace.PanelShellActivityState] = [:]
        private let maxTrackedDirectories = 4096
        private let maxTrackedShellStates = 4096

        func shouldPublishDirectory(workspaceId: UUID, panelId: UUID, directory: String) -> Bool {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            return queue.sync {
                if lastReportedDirectories[key] == directory {
                    return false
                }
                if lastReportedDirectories.count >= maxTrackedDirectories {
                    lastReportedDirectories.removeAll(keepingCapacity: true)
                }
                lastReportedDirectories[key] = directory
                return true
            }
        }

        func shouldPublishShellActivity(
            workspaceId: UUID,
            panelId: UUID,
            state: Workspace.PanelShellActivityState
        ) -> Bool {
            let key = SocketSurfaceKey(workspaceId: workspaceId, panelId: panelId)
            return queue.sync {
                if lastReportedShellStates[key] == state {
                    return false
                }
                if lastReportedShellStates.count >= maxTrackedShellStates {
                    lastReportedShellStates.removeAll(keepingCapacity: true)
                }
                lastReportedShellStates[key] = state
                return true
            }
        }
    }

    private static let socketFastPathState = SocketFastPathState()
    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func parseReportedShellActivityState(
        _ rawState: String
    ) -> Workspace.PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        self.tabManager = tabManager
    }

    // MARK: - Process Ancestry Check

    /// Get the peer PID of a connected Unix domain socket using LOCAL_PEERPID.
    private nonisolated func getPeerPid(_ socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        if result != 0 || pid <= 0 {
            return nil
        }
        return pid
    }

    /// Check if the peer has the same UID as this process using LOCAL_PEERCRED.
    /// This works even after the peer has disconnected (unlike LOCAL_PEERPID).
    private func peerHasSameUID(_ socket: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    /// Check if `pid` is a descendant of this process by walking the process tree.
    func isDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        // Walk up to 128 levels to avoid infinite loops from kernel bugs
        for _ in 0..<128 {
            if current == myPid {
                return true
            }
            if current <= 1 {
                return false
            }
            let parent = parentPid(of: current)
            if parent == current || parent < 0 {
                return false
            }
            current = parent
        }
        return false
    }

    /// Get the parent PID of a process using sysctl.
    private func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    private nonisolated func socketListenerEventData(
        stage: String,
        errnoCode: Int32? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let snapshot = listenerStateSnapshot()
        var data: [String: Any] = [
            "stage": stage,
            "path": snapshot.socketPath,
            "isRunning": snapshot.isRunning ? 1 : 0,
            "acceptLoopAlive": snapshot.acceptLoopAlive ? 1 : 0,
            "serverSocket": Int(snapshot.serverSocket),
            "activeGeneration": snapshot.activeGeneration
        ]
        if let errnoCode {
            data["errno"] = Int(errnoCode)
            data["errnoDescription"] = String(cString: strerror(errnoCode))
        }
        for (key, value) in extra {
            data[key] = value
        }
        return data
    }

    private nonisolated func reportSocketListenerFailure(
        message: String,
        stage: String,
        errnoCode: Int32? = nil,
        extra: [String: Any] = [:]
    ) {
        let data = socketListenerEventData(stage: stage, errnoCode: errnoCode, extra: extra)
        sentryBreadcrumb(message, category: "socket", data: data)
        guard Self.shouldCaptureSocketListenerFailure(
            message: message,
            stage: stage,
            path: data["path"] as? String ?? "",
            errnoCode: errnoCode
        ) else {
            return
        }
        sentryCaptureError(message, category: "socket", data: data, contextKey: "socket_listener")
    }

    private nonisolated static func shouldCaptureSocketListenerFailure(
        message: String,
        stage: String,
        path: String,
        errnoCode: Int32?
    ) -> Bool {
        let key = "\(message)|\(stage)|\(path)|\(errnoCode.map(String.init) ?? "none")"
        let now = Date()
        socketListenerFailureCaptureLock.lock()
        defer { socketListenerFailureCaptureLock.unlock() }
        if let lastCapturedAt = socketListenerFailureLastCapturedAt[key],
           now.timeIntervalSince(lastCapturedAt) < socketListenerFailureCaptureCooldown {
            return false
        }
        socketListenerFailureLastCapturedAt[key] = now
        return true
    }

    nonisolated static func acceptErrorClassification(errnoCode: Int32) -> String {
        switch errnoCode {
        case EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK:
            return "immediate_retry"
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return "resource_pressure"
        case EBADF, EINVAL, ENOTSOCK:
            return "fatal"
        default:
            return "retry_with_backoff"
        }
    }

    nonisolated static func shouldRearmListenerForAcceptError(errnoCode: Int32) -> Bool {
        acceptErrorClassification(errnoCode: errnoCode) == "fatal"
    }

    nonisolated static func shouldRetryAcceptImmediately(errnoCode: Int32) -> Bool {
        acceptErrorClassification(errnoCode: errnoCode) == "immediate_retry"
    }

    nonisolated static func shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= acceptFailureRearmThreshold
    }

    nonisolated static func acceptFailureBackoffMilliseconds(consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 0 else { return 0 }
        var delay = acceptFailureBaseBackoffMs
        var remaining = consecutiveFailures - 1
        while remaining > 0 {
            if delay >= acceptFailureMaxBackoffMs {
                return acceptFailureMaxBackoffMs
            }
            delay = min(delay * 2, acceptFailureMaxBackoffMs)
            remaining -= 1
        }
        return delay
    }

    nonisolated static func acceptFailureRearmDelayMilliseconds(consecutiveFailures: Int) -> Int {
        max(
            acceptFailureBackoffMilliseconds(consecutiveFailures: consecutiveFailures),
            acceptFailureMinimumRearmDelayMs
        )
    }

    nonisolated static func acceptFailureRecoveryAction(
        errnoCode: Int32,
        consecutiveFailures: Int
    ) -> AcceptFailureRecoveryAction {
        let classification = acceptErrorClassification(errnoCode: errnoCode)
        if classification == "immediate_retry" {
            return .retryImmediately
        }

        if classification == "fatal"
            || shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: consecutiveFailures) {
            return .rearmAfterDelay(
                delayMs: acceptFailureRearmDelayMilliseconds(
                    consecutiveFailures: consecutiveFailures
                )
            )
        }

        return .resumeAfterDelay(
            delayMs: acceptFailureBackoffMilliseconds(
                consecutiveFailures: consecutiveFailures
            )
        )
    }

    nonisolated static func shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: Int) -> Bool {
        guard consecutiveFailures > 0 else { return false }
        if consecutiveFailures <= 3 {
            return true
        }
        return (consecutiveFailures & (consecutiveFailures - 1)) == 0
    }

    nonisolated static func shouldUnlinkSocketPathAfterAcceptLoopCleanup(
        pathMatches: Bool,
        isRunning: Bool,
        activeGeneration: UInt64,
        listenerStartInProgress: Bool
    ) -> Bool {
        guard pathMatches else { return false }
        guard !listenerStartInProgress else { return false }
        return !isRunning && activeGeneration == 0
    }

    private nonisolated static func unixSocketAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = unixSocketPathMaxLength + 1
        var didFit = false
        path.withCString { source in
            let sourceLength = strlen(source)
            guard sourceLength < maxLength else { return }

            _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let destination = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maxLength - 1)
            }
            didFit = true
        }
        return didFit ? addr : nil
    }

    private nonisolated static func bindUnixSocket(_ socket: Int32, path: String) -> Int32? {
        guard var addr = unixSocketAddress(path: path) else { return nil }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private nonisolated static func makeSocketTimeout(_ timeout: TimeInterval) -> timeval {
        let normalizedTimeout = max(timeout, 0)
        let seconds = floor(normalizedTimeout)
        let microseconds = (normalizedTimeout - seconds) * 1_000_000
        return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
    }

    private nonisolated static func configureSocketTimeouts(_ fd: Int32, timeout: TimeInterval) {
        var socketTimeout = makeSocketTimeout(timeout)
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    /// True when `path` is a unix socket with a process *currently accepting*
    /// connections on it. A successful connect proves a live acceptor;
    /// ECONNREFUSED / ENOENT prove a stale or absent socket we may safely replace.
    /// This is the C11-155 guard that prevents a build from unlinking a live
    /// peer's socket at bind time.
    nonisolated static func socketHasLiveListener(path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        configureSocketTimeouts(fd, timeout: 0.25)
        guard var addr = unixSocketAddress(path: path) else { return false }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// A unique, build-local socket path to bind when the requested path is held
    /// by a live peer (C11-155). The shared prod default falls back to the
    /// user-scoped stable path; any other path gets a pid-stamped sibling so it
    /// is guaranteed not to collide.
    nonisolated static func safeAlternateSocketPath(
        afterPeerAliveAt requestedPath: String,
        currentUserID: uid_t = getuid(),
        processIdentifier: pid_t = getpid()
    ) -> String {
        if requestedPath == SocketControlSettings.stableDefaultSocketPath {
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        }
        let url = URL(fileURLWithPath: requestedPath)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        let fileName = ext.isEmpty
            ? "\(base)-\(processIdentifier)"
            : "\(base)-\(processIdentifier).\(ext)"
        return directory.appendingPathComponent(fileName, isDirectory: false).path
    }

    private nonisolated static func bindListenerSocket(_ socket: Int32, path: String) -> SocketBindAttemptResult {
        if let errnoCode = ensureSocketParentDirectoryExists(path: path) {
            return .failure(path: path, stage: "create_directory", errnoCode: errnoCode)
        }
        // C11-155: never unlink a socket a live peer is still serving — that is
        // the bind-time stomp that wedges the peer. Probe liveness before unlink.
        if socketHasLiveListener(path: path) {
            return .peerAlive(path: path)
        }
        if unlink(path) != 0, errno != ENOENT {
            return .failure(path: path, stage: "unlink", errnoCode: errno)
        }

        guard let bindResult = bindUnixSocket(socket, path: path) else {
            return .pathTooLong(path: path)
        }
        guard bindResult >= 0 else {
            return .failure(path: path, stage: "bind", errnoCode: errno)
        }
        return .success(path: path)
    }

    private nonisolated static func ensureSocketParentDirectoryExists(path: String) -> Int32? {
        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return nil
        } catch let error as NSError {
            if error.domain == NSPOSIXErrorDomain {
                return Int32(error.code)
            }
            return EIO
        }
    }

    nonisolated static func fallbackSocketPathAfterBindFailure(
        requestedPath: String,
        stage: String,
        errnoCode: Int32,
        currentUserID: uid_t = getuid()
    ) -> String? {
        guard requestedPath == SocketControlSettings.stableDefaultSocketPath else {
            return nil
        }

        switch stage {
        case "unlink" where errnoCode == EACCES || errnoCode == EPERM:
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        case "bind" where errnoCode == EACCES || errnoCode == EPERM || errnoCode == EADDRINUSE:
            return SocketControlSettings.userScopedStableSocketPath(currentUserID: currentUserID)
        default:
            return nil
        }
    }

    func start(tabManager: TabManager, socketPath: String, accessMode: SocketControlMode) {
        self.tabManager = tabManager
        self.accessMode = accessMode

        let existing = withListenerState {
            (isRunning: isRunning, socketPath: self.socketPath, acceptLoopAlive: acceptLoopAlive)
        }

        if existing.isRunning && existing.socketPath == socketPath && existing.acceptLoopAlive {
            self.accessMode = accessMode
            applySocketPermissions()
            return
        }

        if existing.isRunning {
            stop()
        }

        var activeSocketPath = socketPath
        withListenerState {
            self.socketPath = activeSocketPath
            listenerStartInProgress = true
        }
        var listenerActivated = false
        defer {
            if !listenerActivated {
                withListenerState {
                    listenerStartInProgress = false
                }
            }
        }

        // Create socket
        let newServerSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newServerSocket >= 0 else {
            let errnoCode = errno
            print("TerminalController: Failed to create socket")
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "create_socket",
                errnoCode: errnoCode
            )
            return
        }

        var bindAttempt = Self.bindListenerSocket(newServerSocket, path: activeSocketPath)
        // C11-155: the requested path is held by a live peer. Rebind on a safe,
        // build-local alternate rather than wedge the incumbent.
        if case .peerAlive(let occupiedPath) = bindAttempt {
            let fallbackPath = Self.safeAlternateSocketPath(afterPeerAliveAt: occupiedPath)
            sentryBreadcrumb(
                "socket.listener.peerAlive.fallback",
                category: "socket",
                data: [
                    "occupiedPath": occupiedPath,
                    "fallbackPath": fallbackPath
                ]
            )
            if fallbackPath != occupiedPath {
                activeSocketPath = fallbackPath
                withListenerState {
                    self.socketPath = activeSocketPath
                }
                bindAttempt = Self.bindListenerSocket(newServerSocket, path: activeSocketPath)
            }
        }
        if case .failure(let failedPath, let failedStage, let failedErrnoCode) = bindAttempt,
           let fallbackPath = Self.fallbackSocketPathAfterBindFailure(
               requestedPath: failedPath,
               stage: failedStage,
               errnoCode: failedErrnoCode
           ),
           fallbackPath != failedPath {
            sentryBreadcrumb(
                "socket.listener.path.fallback",
                category: "socket",
                data: [
                    "requestedPath": failedPath,
                    "fallbackPath": fallbackPath,
                    "stage": failedStage,
                    "errno": Int(failedErrnoCode)
                ]
            )
            activeSocketPath = fallbackPath
            withListenerState {
                self.socketPath = activeSocketPath
            }
            bindAttempt = Self.bindListenerSocket(newServerSocket, path: activeSocketPath)
        }

        switch bindAttempt {
        case .success(let boundPath):
            activeSocketPath = boundPath
            withListenerState {
                self.socketPath = activeSocketPath
            }
        case .pathTooLong(let failedPath):
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "bind_path_too_long",
                errnoCode: ENAMETOOLONG,
                extra: [
                    "path": failedPath,
                    "pathLength": failedPath.utf8.count,
                    "maxPathLength": Self.unixSocketPathMaxLength
                ]
            )
            return
        case .failure(let failedPath, let failedStage, let failedErrnoCode):
            print("TerminalController: Failed to bind socket")
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: failedStage,
                errnoCode: failedErrnoCode,
                extra: ["path": failedPath]
            )
            return
        case .peerAlive(let occupiedPath):
            // Even the safe alternate is held by a live peer (extremely unlikely).
            // Refuse to stomp; report and bail rather than wedge anyone.
            print("TerminalController: Refusing to bind — live peer owns socket")
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "peer_alive",
                errnoCode: EADDRINUSE,
                extra: ["path": occupiedPath]
            )
            return
        }

        applySocketPermissions()

        // Listen
        guard listen(newServerSocket, Self.socketListenBacklog) >= 0 else {
            let errnoCode = errno
            print("TerminalController: Failed to listen on socket")
            close(newServerSocket)
            reportSocketListenerFailure(
                message: "socket.listener.start.failed",
                stage: "listen",
                errnoCode: errnoCode
            )
            return
        }

        SocketControlSettings.recordLastSocketPath(activeSocketPath)

        let generation = withListenerState {
            isRunning = true
            pendingAcceptLoopRearmGeneration = nil
            pendingAcceptLoopResumeGeneration = nil
            nextAcceptLoopGeneration &+= 1
            let generation = nextAcceptLoopGeneration
            activeAcceptLoopGeneration = generation
            serverSocket = newServerSocket
            listenerStartInProgress = false
            return generation
        }
        listenerActivated = true
        let listenerSocket = newServerSocket
        print("TerminalController: Listening on \(activeSocketPath)")
        sentryBreadcrumb(
            "socket.listener.listening",
            category: "socket",
            data: [
                "path": activeSocketPath,
                "mode": accessMode.rawValue,
                "generation": generation,
                "backlog": Self.socketListenBacklog
            ]
        )
        NotificationCenter.default.post(
            name: .socketListenerDidStart,
            object: self,
            userInfo: ["path": activeSocketPath]
        )

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            MainActor.assumeIsolated {
                guard let self, let tabManager = self.tabManager else { return }
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                let validSurfaceIds = Set(workspace.panels.keys)
                guard validSurfaceIds.contains(panelId) else { return }
                workspace.surfaceListeningPorts[panelId] = ports.isEmpty ? nil : ports
                workspace.recomputeListeningPorts()
            }
        }

        // Accept connections in background thread
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(listenerSocket: listenerSocket, generation: generation)
        }
    }

    nonisolated func socketListenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        let snapshot = listenerStateSnapshot()
        let pathMatches = snapshot.socketPath == expectedSocketPath

        var st = stat()
        let exists = lstat(expectedSocketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK

        return SocketListenerHealth(
            isRunning: snapshot.isRunning,
            acceptLoopAlive: snapshot.acceptLoopAlive,
            socketPathMatches: pathMatches,
            socketPathExists: exists
        )
    }

    nonisolated static func probeSocketCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval
    ) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Self.configureSocketTimeouts(fd, timeout: timeout)

#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
#endif

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
#if os(macOS)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }

        let payload = command + "\n"
        let wroteAll = payload.withCString { cString in
            var remaining = strlen(cString)
            var pointer = UnsafeRawPointer(cString)
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
        guard wroteAll else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var response = ""

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                let readErrno = errno
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    break
                }
                return nil
            }
            if count == 0 {
                break
            }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                response.append(chunk)
                if let newlineIndex = response.firstIndex(of: "\n") {
                    return String(response[..<newlineIndex])
                }
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func stop() {
        let (socketToClose, socketPathToUnlink) = withListenerState {
            isRunning = false
            acceptLoopAlive = false
            pendingAcceptLoopRearmGeneration = nil
            pendingAcceptLoopResumeGeneration = nil
            listenerStartInProgress = false
            nextAcceptLoopGeneration &+= 1
            activeAcceptLoopGeneration = 0
            let socketToClose = serverSocket
            serverSocket = -1
            return (socketToClose, socketPath)
        }
        if socketToClose >= 0 {
            close(socketToClose)
        }
        // Skip the unlink when we never bound a path. Calling unlink on the
        // stable default while a sibling c11 process owns that bind point is
        // the C11-105 production bug — the dentry is removed under the live
        // owner, leaving every `c11 <cmd>` reporting "Socket not found".
        if !socketPathToUnlink.isEmpty {
            unlink(socketPathToUnlink)
        }
    }

    private nonisolated func unlinkSocketPathIfListenerStillInactive(_ path: String) {
        guard !path.isEmpty else { return }
        let shouldUnlink = withListenerState {
            Self.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: socketPath == path,
                isRunning: isRunning,
                activeGeneration: activeAcceptLoopGeneration,
                listenerStartInProgress: listenerStartInProgress
            )
        }
        if shouldUnlink {
            unlink(path)
        }
    }

    private func applySocketPermissions() {
        let permissions = mode_t(accessMode.socketFilePermissions)
        let currentSocketPath = withListenerState { socketPath }
        if chmod(currentSocketPath, permissions) != 0 {
            let errnoCode = errno
            print(
                "TerminalController: Failed to set socket permissions to \(String(permissions, radix: 8)) for \(currentSocketPath)"
            )
            sentryBreadcrumb(
                "socket.listener.permissions.failed",
                category: "socket",
                data: socketListenerEventData(
                    stage: "chmod",
                    errnoCode: errnoCode,
                    extra: ["permissions": String(permissions, radix: 8)]
                )
            )
        }
    }

    private func writeSocketResponse(_ response: String, to socket: Int32) {
        let payload = response + "\n"
        payload.withCString { ptr in
            _ = write(socket, ptr, strlen(ptr))
        }
    }

    private func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard SocketControlPasswordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard SocketControlPasswordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard SocketControlPasswordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard SocketControlPasswordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    private func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v1Response
        }
        if !authenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    private nonisolated func acceptLoop(listenerSocket: Int32, generation: UInt64) {
        let armedAcceptLoop = withListenerState {
            guard generation == activeAcceptLoopGeneration else { return false }
            acceptLoopAlive = true
            return true
        }
        guard armedAcceptLoop else {
            return
        }

        sentryBreadcrumb(
            "socket.listener.accept_loop.started",
            category: "socket",
            data: socketListenerEventData(
                stage: "accept_loop_start",
                extra: [
                    "generation": generation,
                    "listenerSocket": Int(listenerSocket)
                ]
            )
        )

        var exitReason = "stopped"
        var lastAcceptErrno: Int32?
        var lastAcceptErrnoClass = "none"
        var rearmRequested = false
        var resumeRequested = false

        defer {
            let cleanup = withListenerState {
                guard generation == activeAcceptLoopGeneration else {
                    return (
                        shouldCaptureExit: false,
                        socketToClose: Int32(-1),
                        pathToUnlink: nil as String?
                    )
                }

                if resumeRequested && exitReason == "accept_backoff_resume" {
                    acceptLoopAlive = false
                    return (
                        shouldCaptureExit: false,
                        socketToClose: Int32(-1),
                        pathToUnlink: nil as String?
                    )
                }

                if isRunning && exitReason == "stopped" {
                    exitReason = "unexpected_loop_exit"
                }
                let shouldCaptureExit = exitReason != "stopped"

                acceptLoopAlive = false
                isRunning = false
                activeAcceptLoopGeneration = 0
                pendingAcceptLoopResumeGeneration = nil

                var socketToClose: Int32 = -1
                var pathToUnlink: String?
                if serverSocket == listenerSocket {
                    socketToClose = serverSocket
                    serverSocket = -1
                    if shouldCaptureExit {
                        pathToUnlink = socketPath
                    }
                }
                return (shouldCaptureExit, socketToClose, pathToUnlink)
            }

            if cleanup.socketToClose >= 0 {
                close(cleanup.socketToClose)
            }
            if let pathToUnlink = cleanup.pathToUnlink {
                unlinkSocketPathIfListenerStillInactive(pathToUnlink)
            }

            if cleanup.shouldCaptureExit {
                let data = socketListenerEventData(
                    stage: "accept_loop_exit",
                    errnoCode: lastAcceptErrno,
                    extra: [
                        "reason": exitReason,
                        "generation": generation,
                        "errnoClass": lastAcceptErrnoClass,
                        "rearmRequested": rearmRequested ? 1 : 0,
                        "resumeRequested": resumeRequested ? 1 : 0
                    ]
                )
                sentryBreadcrumb("socket.listener.accept_loop.exited", category: "socket", data: data)
                sentryCaptureError(
                    "socket.listener.accept_loop.exited",
                    category: "socket",
                    data: data,
                    contextKey: "socket_listener"
                )
            }
        }

        var consecutiveFailures = 0

        while shouldContinueAcceptLoop(generation: generation) {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenerSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if !shouldContinueAcceptLoop(generation: generation) {
                    exitReason = "stopped"
                    break
                }

                let errnoCode = errno
                lastAcceptErrno = errnoCode
                let errnoClass = Self.acceptErrorClassification(errnoCode: errnoCode)
                lastAcceptErrnoClass = errnoClass

                if Self.shouldRetryAcceptImmediately(errnoCode: errnoCode) {
                    continue
                }

                consecutiveFailures += 1
                let recoveryAction = Self.acceptFailureRecoveryAction(
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures
                )

                if Self.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: consecutiveFailures) {
                    sentryBreadcrumb(
                        "socket.listener.accept.failed",
                        category: "socket",
                        data: socketListenerEventData(
                            stage: "accept",
                            errnoCode: errnoCode,
                            extra: [
                                "consecutiveFailures": consecutiveFailures,
                                "generation": generation,
                                "errnoClass": errnoClass,
                                "delayMs": recoveryAction.delayMs,
                                "recoveryAction": recoveryAction.debugLabel
                            ]
                        )
                    )
                }

                let shouldRearmForFatalErrno = Self.shouldRearmListenerForAcceptError(errnoCode: errnoCode)

                if case .rearmAfterDelay(let delayMs) = recoveryAction {
                    exitReason = shouldRearmForFatalErrno
                        ? "fatal_accept_error"
                        : "persistent_accept_failures"
                    rearmRequested = true
                    withListenerState {
                        pendingAcceptLoopRearmGeneration = generation
                    }
                    scheduleListenerRearm(
                        generation: generation,
                        errnoCode: errnoCode,
                        consecutiveFailures: consecutiveFailures,
                        delayMs: delayMs
                    )
                    break
                }

                if case .resumeAfterDelay(let delayMs) = recoveryAction {
                    exitReason = "accept_backoff_resume"
                    resumeRequested = true
                    withListenerState {
                        pendingAcceptLoopResumeGeneration = generation
                    }
                    scheduleAcceptLoopResume(
                        listenerSocket: listenerSocket,
                        generation: generation,
                        errnoCode: errnoCode,
                        consecutiveFailures: consecutiveFailures,
                        delayMs: delayMs
                    )
                    break
                }

                continue
            }

            consecutiveFailures = 0

            // Capture peer PID immediately — before the client can disconnect.
            // ncat --send-only closes the connection right after writing, so by
            // the time a new thread starts the peer may already be gone.
            let peerPid = getPeerPid(clientSocket)

            // Handle client in new thread
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientSocket, peerPid: peerPid)
            }
        }
    }

    private nonisolated func scheduleAcceptLoopResume(
        listenerSocket: Int32,
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        let deadline = DispatchTime.now() + .milliseconds(delayMs)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            let shouldResume = self.withListenerState {
                guard self.pendingAcceptLoopResumeGeneration == generation else { return false }
                guard self.activeAcceptLoopGeneration == generation else {
                    self.pendingAcceptLoopResumeGeneration = nil
                    return false
                }
                guard self.isRunning, self.serverSocket == listenerSocket else {
                    self.pendingAcceptLoopResumeGeneration = nil
                    return false
                }
                self.pendingAcceptLoopResumeGeneration = nil
                return true
            }
            guard shouldResume else { return }

            sentryBreadcrumb(
                "socket.listener.resume.requested",
                category: "socket",
                data: self.socketListenerEventData(
                    stage: "accept_resume",
                    errnoCode: errnoCode,
                    extra: [
                        "generation": generation,
                        "consecutiveFailures": consecutiveFailures,
                        "resumeDelayMs": delayMs
                    ]
                )
            )

            Thread.detachNewThread { [weak self] in
                self?.acceptLoop(listenerSocket: listenerSocket, generation: generation)
            }
        }
    }

    private nonisolated func scheduleListenerRearm(
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        let deadline = DispatchTime.now() + .milliseconds(delayMs)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            guard let tabManager = self.tabManager else { return }
            guard let restartPath = self.withListenerState({ () -> String? in
                guard self.pendingAcceptLoopRearmGeneration == generation else { return nil }
                self.pendingAcceptLoopRearmGeneration = nil
                return self.socketPath
            }) else { return }

            let restartMode = self.accessMode

            sentryBreadcrumb(
                "socket.listener.rearm.requested",
                category: "socket",
                data: self.socketListenerEventData(
                    stage: "accept_rearm",
                    errnoCode: errnoCode,
                    extra: [
                        "generation": generation,
                        "consecutiveFailures": consecutiveFailures,
                        "rearmDelayMs": delayMs
                    ]
                )
            )

            self.stop()
            self.start(tabManager: tabManager, socketPath: restartPath, accessMode: restartMode)
        }
    }

    private func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In c11Only mode, verify the connecting process is a descendant of c11.
        // In allowAll mode (env-var only), skip the ancestry check.
        if accessMode == .c11Only {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? getPeerPid(socket)
            if let pid {
                guard isDescendant(pid) else {
                    let msg = "ERROR: Access denied — only processes started inside c11 can connect\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
            // If pid is nil, LOCAL_PEERPID failed (peer disconnected before we
            // could read it — common with ncat --send-only). We still verify the
            // peer runs as the same user via LOCAL_PEERCRED. This is the same
            // security boundary as the socket file permissions (0600), so it does
            // not widen the attack surface. We also require that the peer actually
            // sent data (checked in the read loop below) — a connect-only probe
            // with no data is harmless.
            if pid == nil {
                guard peerHasSameUID(socket) else {
                    let msg = "ERROR: Unable to verify client process\n"
                    msg.withCString { ptr in _ = write(socket, ptr, strlen(ptr)) }
                    return
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        var authenticated = false

        while withListenerState({ isRunning }) {
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { break }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newlineIndex])
                pending = String(pending[pending.index(after: newlineIndex)...])
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let authResponse = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                    writeSocketResponse(authResponse, to: socket)
                    continue
                }

                let response = processCommandUsingSocketExecutionPolicy(trimmed)
                writeSocketResponse(response, to: socket)
            }
        }
    }

    // MARK: - Socket command execution policy
    //
    // C11-26: Some v2 methods must run on the socket worker thread, not the main actor,
    // so callers that internally wait on `@MainActor` notifications (e.g. via
    // `v2AwaitCallback` / `waitForTerminalSurface`) cannot deadlock on a nested
    // `CFRunLoopRun` reached from inside an outer `DispatchQueue.main.sync` block.
    // Entries in `socketWorkerV2Methods` are dispatched directly on the worker via
    // `socketWorkerV2Response` and short-hop to `@MainActor` only for bounded slices
    // of work that genuinely need it.
    //
    // Methods absent from `socketWorkerV2Methods` flow through the default-policy
    // path below, which hops to the main thread *before* invoking `processCommand`.
    // That hop is a behavior change vs. pre-C11-26 (where `handleClient` called
    // `processCommand(trimmed)` directly from the worker), and any handler that
    // internally calls `DispatchQueue.main.sync` would self-deadlock on the main
    // queue — libdispatch's `__DISPATCH_WAIT_FOR_QUEUE__` traps with EXC_BREAKPOINT.
    // Handlers reached through this path must use `v2MainSync` (which short-circuits
    // when already on main) instead of bare `DispatchQueue.main.sync`.

    private enum SocketCommandExecutionPolicy: Equatable {
        case mainActor
        case socketWorker
    }

    // C11-159: widened private->internal (see DX-5 widening inventory).
    struct V2SocketRequest {
        let id: Any?
        let method: String
        let params: [String: Any]
    }

    private nonisolated static let socketWorkerV2Methods: Set<String> = [
        "surface.send_text",
        "surface.send_key",
        "surface.read_text",
        "surface.clear_history",
    ]

    // C11-4: v1 telemetry commands the worker is allowed to handle off-main.
    // Each entry has a fast-path branch in its handler that runs only when
    // `Self.explicitSocketScope(options:)` returns non-nil — i.e. when the
    // caller passed `--tab=<uuid>` and `--panel=<uuid>` (or `--surface=<uuid>`).
    // For requests without explicit IDs (the slow path that reads "current
    // focused tab"), the worker entry returns nil so the dispatcher falls
    // through to its existing main-sync path. The shell integrations (zsh +
    // bash) always include explicit IDs so the prompt-frequency telemetry
    // hits the fast path; only ad-hoc CLI invocations land on the slow path.
    private nonisolated static let socketWorkerV1Commands: Set<String> = [
        "report_pwd",
        "report_shell_state",
        "report_git_branch",
        "clear_git_branch",
        "ports_kick",
        "agent_kick",
    ]

    // C11-156: fire-and-forget sidebar/notification telemetry the Claude Code
    // hook integration issues at tool-call frequency. Each `c11 claude-hook`
    // process (one per tool call, per agent) ends up calling these; their
    // handlers return a bare "OK" the caller discards (`_ = try? sendV1Command`)
    // and mutate only sidebar/notification model state. The default policy
    // runs them under `DispatchQueue.main.sync`, so every hook blocks a
    // socket-worker thread on the main queue. Under a multi-agent fleet — or a
    // crash-restore mass-resume — that serialized main-sync backlog starves
    // the run loop and beachballs the app (the 44s stall captured in
    // ~/Library/Logs/c11/hang.log). Unlike `socketWorkerV1Commands` these
    // don't need an off-main parse + explicit selector: we ack "OK" off-main
    // immediately and re-enter the EXISTING handler via `main.async`, so there
    // is zero logic duplication and the CLI never piles up blocked processes
    // while the run loop drains status writes cooperatively.
    private nonisolated static let asyncAckV1Commands: Set<String> = [
        "set_status",
        "clear_notifications",
        "set_agent_pid",
        "notify_target",
    ]

    nonisolated static func executionPolicy(forV2Method method: String) -> SocketCommandExecutionPolicy {
        if socketWorkerV2Methods.contains(method) {
            return .socketWorker
        }
        return .mainActor
    }

    private nonisolated func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !method.isEmpty else {
            return nil
        }

        return V2SocketRequest(
            id: dict["id"],
            method: method,
            params: dict["params"] as? [String: Any] ?? [:]
        )
    }

    private nonisolated func socketWorkerV2ResponseIfNeeded(for command: String) -> String? {
        guard let request = parseV2SocketRequest(command),
              Self.executionPolicy(forV2Method: request.method) == .socketWorker else {
            return nil
        }

        return withSocketCommandPolicy(commandKey: request.method, isV2: true) {
            socketWorkerV2Response(request)
        }
    }

    private nonisolated func socketWorkerV2Response(_ request: V2SocketRequest) -> String {
        // C11-26 review M1: emit the off-main diagnostic at the dispatcher seam
        // so future migrated methods get it for free instead of "we forgot."
        #if DEBUG
        dlog("v2.\(request.method) isMain=\(Thread.isMainThread) tid=\(pthread_mach_thread_np(pthread_self()))")
        #endif

        switch request.method {
        case "surface.send_text":
            return v2Result(id: request.id, v2SurfaceSendText(params: request.params))
        case "surface.send_key":
            return v2Result(id: request.id, v2SurfaceSendKey(params: request.params))
        case "surface.read_text":
            return v2Result(id: request.id, v2SurfaceReadText(params: request.params))
        case "surface.clear_history":
            return v2Result(id: request.id, v2SurfaceClearHistory(params: request.params))
        default:
            return v2Error(id: request.id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated func processCommandUsingSocketExecutionPolicy(_ command: String) -> String {
        if let response = socketWorkerV2ResponseIfNeeded(for: command) {
            return response
        }

        if let response = socketWorkerV1ResponseIfNeeded(for: command) {
            return response
        }

        if let response = asyncAckResponseIfNeeded(for: command) {
            return response
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated { self.processCommand(command) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.processCommand(command) }
        }
    }

    /// C11-156: ack a fire-and-forget telemetry command off-main and apply its
    /// mutation via `main.async`, instead of blocking a socket-worker thread on
    /// `DispatchQueue.main.sync`. Returns nil for anything not in
    /// `asyncAckV1Commands` (and for v2/JSON requests) so the dispatcher falls
    /// through to its normal path. The existing `@MainActor` handler is reused
    /// verbatim — only the scheduling changes — so behaviour is identical
    /// except that the caller is acked before the mutation lands, which is safe
    /// precisely because these handlers return a bare "OK" the hook discards.
    private nonisolated func asyncAckResponseIfNeeded(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        guard Self.asyncAckV1Commands.contains(head) else { return nil }

        DispatchQueue.main.async {
            MainActor.assumeIsolated { _ = self.processCommand(command) }
        }
        return "OK"
    }

    /// v1 telemetry worker entry. Parses head and args off-main, checks the
    /// allowlist, and routes to a per-command worker variant when the args
    /// carry an explicit `--tab=`/`--panel=` selector. Returns nil to make
    /// the dispatcher fall through to the existing main-sync path when:
    ///   - The command is not a v1 telemetry command we know how to migrate.
    ///   - The args do not contain an explicit selector (handler would need
    ///     a focused-tab read, which requires a main hop anyway — the
    ///     current main-sync path already handles that correctly).
    private nonisolated func socketWorkerV1ResponseIfNeeded(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return nil }
        let head = parts[0].lowercased()
        guard Self.socketWorkerV1Commands.contains(head) else { return nil }
        let args = parts.count > 1 ? parts[1] : ""

        return withSocketCommandPolicy(commandKey: head, isV2: false) {
            socketWorkerV1Response(head: head, args: args)
        }
    }

    /// Dispatch a v1 telemetry command to its nonisolated worker variant.
    /// Each variant returns nil if the command must fall through to the
    /// main-actor path (slow-path callers without an explicit selector).
    private nonisolated func socketWorkerV1Response(head: String, args: String) -> String? {
        switch head {
        case "report_pwd":
            return reportPwdWorker(args)
        case "report_shell_state":
            return reportShellStateWorker(args)
        case "report_git_branch":
            return reportGitBranchWorker(args)
        case "clear_git_branch":
            return clearGitBranchWorker(args)
        case "ports_kick":
            return portsKickWorker(args)
        case "agent_kick":
            return agentKickWorker(args)
        default:
            return nil
        }
    }

    // MARK: - Pure parser helpers (off-main safe)
    //
    // These mirror the @MainActor instance methods `tokenizeArgs`,
    // `parseOptions`, and `parseOptionsNoStop` exactly. They are pure string
    // operations; making them static + nonisolated lets the v1 telemetry
    // worker run them off the main thread without touching the existing
    // call sites (which still want the shorter instance-method names).

    nonisolated static func tokenizeArgsStatic(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    nonisolated static func parseOptionsStatic(
        _ args: String
    ) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgsStatic(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    // MARK: - V1 telemetry worker variants (nonisolated, fast-path only)
    //
    // Each worker variant handles the explicit-scope fast path of a
    // high-frequency telemetry command. They mirror the corresponding @MainActor
    // handler bit-for-bit *only* on the fast path — when the args do not
    // contain explicit `--tab=<uuid>` and `--panel=<uuid>`, they return nil
    // so the dispatcher falls through to the main-sync path and the @MainActor
    // handler runs unchanged. The behavioral contract for callers (shell
    // integrations etc.) is identical: parse-time errors still come back as
    // "ERROR: ..." synchronously, and the actual UI mutation is enqueued via
    // `DispatchQueue.main.async` exactly as the @MainActor variant does.

    private nonisolated func reportPwdWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        // Note: the @MainActor `reportPwd` early-returns "ERROR: TabManager
        // not available" when `self.tabManager` is nil. The worker variant
        // skips that guard intentionally — when `--tab=<uuid>` is provided,
        // we resolve the manager via `AppDelegate.shared?.tabManagerFor(...)`
        // below, which finds the correct manager regardless of the
        // controller's bound `tabManager`. The visible behavioral diff is
        // "ERROR: TabManager not available" → silent async no-op when
        // neither path can resolve a manager. In practice this fires only
        // before the app finishes wiring its TabManager, well before any
        // socket accepts commands.
        let directory = parsed.positional.joined(separator: " ")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceDirectory(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    directory: directory
                )
            }
        }
        return "OK"
    }

    private nonisolated func reportShellStateWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let rawState = parsed.positional.first, !rawState.isEmpty else {
            return "ERROR: Missing shell state — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        }
        guard let state = Self.parseReportedShellActivityState(rawState) else {
            return "ERROR: Invalid shell state '\(rawState)' — expected prompt or running"
        }

        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        guard Self.socketFastPathState.shouldPublishShellActivity(
            workspaceId: scope.workspaceId,
            panelId: scope.panelId,
            state: state
        ) else {
            return "OK"
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId) else { return }
                tabManager.updateSurfaceShellActivity(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    state: state
                )
            }
        }
        return "OK"
    }

    private nonisolated func reportGitBranchWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let branch = parsed.positional.first else {
            return "ERROR: Missing branch name — usage: report_git_branch <branch> [--status=dirty] [--tab=X]"
        }
        let isDirty = parsed.options["status"]?.lowercased() == "dirty"

        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceGitBranch(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    branch: branch,
                    isDirty: isDirty
                )
            }
        }
        return "OK"
    }

    private nonisolated func clearGitBranchWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.clearSurfaceGitBranch(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId
                )
            }
        }
        return "OK"
    }

    private nonisolated func portsKickWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                PortScanner.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            }
        }
        return "OK"
    }

    private nonisolated func agentKickWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                AgentDetector.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            }
        }
        return "OK"
    }

    private func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        return withSocketCommandPolicy(commandKey: cmd, isV2: false) {
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        case "list_windows":
            return listWindows()

        case "current_window":
            return currentWindow()

        case "focus_window":
            return focusWindow(args)

        case "new_window":
            return newWindow()

        case "close_window":
            return closeWindow(args)

        case "move_workspace_to_window":
            return moveWorkspaceToWindow(args)

        case "list_workspaces":
            return listWorkspaces()

	        case "new_workspace":
	            return newWorkspace()

	        case "new_split":
	            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_workspace":
            return closeWorkspace(args)

        case "select_workspace":
            return selectWorkspace(args)

        case "current_workspace":
            return currentWorkspace()

        case "send":
            return sendInput(args)

        case "send_key":
            return sendKey(args)

        case "send_surface":
            return sendInputToSurface(args)

        case "send_key_surface":
            return sendKeyToSurface(args)

        case "notify":
            return notifyCurrent(args)

        case "notify_surface":
            return notifySurface(args)

        case "notify_target":
            return notifyTarget(args)

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications(args)

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        case "set_status":
            return setStatus(args)

        case "report_meta":
            return reportMeta(args)

        case "report_meta_block":
            return reportMetaBlock(args)

        case "clear_status":
            return clearStatus(args)

        case "set_agent_pid":
            return setAgentPID(args)

        case "clear_agent_pid":
            return clearAgentPID(args)

        case "clear_meta":
            return clearMeta(args)

        case "clear_meta_block":
            return clearMetaBlock(args)

        case "list_status":
            return listStatus(args)

        case "list_meta":
            return listMeta(args)

        case "list_meta_blocks":
            return listMetaBlocks(args)

        case "log":
            return appendLog(args)

        case "clear_log":
            return clearLog(args)

        case "list_log":
            return listLog(args)

        case "set_progress":
            return setProgress(args)

        case "clear_progress":
            return clearProgress(args)

        case "report_git_branch":
            return reportGitBranch(args)

        case "clear_git_branch":
            return clearGitBranch(args)

        case "report_pr":
            return reportPullRequest(args)

        case "report_review":
            return reportPullRequest(args)

        case "clear_pr":
            return clearPullRequest(args)

        case "report_ports":
            return reportPorts(args)

        case "clear_ports":
            return clearPorts(args)

        case "report_tty":
            return reportTTY(args)

        case "ports_kick":
            return portsKick(args)

        case "agent_kick":
            return agentKick(args)

        case "report_shell_state":
            return reportShellState(args)

        case "report_pwd":
            return reportPwd(args)

        case "sidebar_state":
            return sidebarState(args)

        case "reset_sidebar":
            return resetSidebar(args)

        case "read_screen":
            return readScreenText(args)


#if DEBUG
        case "send_workspace":
            return sendInputToWorkspace(args)

        case "set_shortcut":
            return setShortcut(args)

        case "simulate_shortcut":
            return simulateShortcut(args)

        case "simulate_type":
            return simulateType(args)

        case "simulate_file_drop":
            return simulateFileDrop(args)

        case "seed_drag_pasteboard_fileurl":
            return seedDragPasteboardFileURL()

        case "seed_drag_pasteboard_tabtransfer":
            return seedDragPasteboardTabTransfer()

        case "seed_drag_pasteboard_sidebar_reorder":
            return seedDragPasteboardSidebarReorder()

        case "seed_drag_pasteboard_types":
            return seedDragPasteboardTypes(args)

        case "clear_drag_pasteboard":
            return clearDragPasteboard()

        case "drop_hit_test":
            return dropHitTest(args)

        case "drag_hit_chain":
            return dragHitChain(args)

        case "overlay_hit_gate":
            return overlayHitGate(args)

        case "overlay_drop_gate":
            return overlayDropGate(args)

        case "portal_hit_gate":
            return portalHitGate(args)

        case "sidebar_overlay_gate":
            return sidebarOverlayGate(args)

        case "terminal_drop_overlay_probe":
            return terminalDropOverlayProbe(args)

        case "activate_app":
            return activateApp()

        case "is_terminal_focused":
            return isTerminalFocused(args)

        case "read_terminal_text":
            return readTerminalText(args)

        case "render_stats":
            return renderStats(args)

        case "layout_debug":
            return layoutDebug()

        case "bonsplit_underflow_count":
            return bonsplitUnderflowCount()

        case "reset_bonsplit_underflow_count":
            return resetBonsplitUnderflowCount()

        case "empty_panel_count":
            return emptyPanelCount()

        case "reset_empty_panel_count":
            return resetEmptyPanelCount()

        case "focus_notification":
            return focusFromNotification(args)

        case "flash_count":
            return flashCount(args)

        case "reset_flash_counts":
            return resetFlashCounts()

        case "panel_snapshot":
            return panelSnapshot(args)

        case "panel_snapshot_reset":
            return panelSnapshotReset(args)

        case "screenshot":
            return captureScreenshot(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands
        case "open_browser":
            return openBrowser(args)

        case "navigate":
            return navigateBrowser(args)

        case "browser_back":
            return browserBack(args)

        case "browser_forward":
            return browserForward(args)

        case "browser_reload":
            return browserReload(args)

        case "get_url":
            return getUrl(args)

        case "focus_webview":
            return focusWebView(args)

        case "is_webview_focused":
            return isWebViewFocused(args)

        case "list_panes":
            return listPanes()

        case "list_pane_surfaces":
            return listPaneSurfaces(args)

	        case "focus_pane":
	            return focusPane(args)

	        case "focus_surface_by_panel":
	            return focusSurfaceByPanel(args)

	        case "drag_surface_to_split":
	            return dragSurfaceToSplit(args)

	        case "new_pane":
	            return newPane(args)

        case "new_surface":
            return newSurface(args)

        // C11-14: read/write the default agent + per-agent configuration. Same
        // store the Settings UI binds to; live updates fan out via UserDefaults.
        case "default_agent":
            return defaultAgentCommand(args)

        case "agent_config":
            return agentConfigCommand(args)

        case "close_surface":
            return closeSurface(args)

        case "reload_config":
            return reloadConfig(args)

        case "refresh_surfaces":
            return refreshSurfaces()

            case "surface_health":
                return surfaceHealth(args)

            default:
                return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
            }
        }
    }

    // MARK: - V2 JSON Socket Protocol

    private func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        guard let data = jsonLine.data(using: .utf8) else {
            return v2Encode(["ok": false, "error": ["code": "invalid_utf8", "message": "Invalid UTF-8"]])
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]])
        }

        guard let dict = object as? [String: Any] else {
            return v2Encode(["ok": false, "error": ["code": "invalid_request", "message": "Expected JSON object"]])
        }

        let id: Any? = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        guard !method.isEmpty else {
            return v2Error(id: id, code: "invalid_request", message: "Missing method")
        }

        // C11-26: Methods on the socket-worker policy must be dispatched via
        // socketWorkerV2Response (off main); reaching processV2Command for one of
        // them means the routing layer mis-targeted the request, and falling
        // through to the main-actor handler would re-introduce the deadlock the
        // worker policy exists to avoid.
        guard Self.executionPolicy(forV2Method: method) == .mainActor else {
            // C11-26 review M2: in DEBUG, this routing bug should fail loudly so
            // CI catches it before it ships. Release-mode behavior (return an
            // invalid_dispatch error) is unchanged.
            #if DEBUG
            dlog("v2.invalid_dispatch method=\(method) — worker-policy method reached processV2Command")
            assertionFailure("\(method) is on the socket-worker policy and must not reach processV2Command")
            #endif
            return v2Error(
                id: id,
                code: "invalid_dispatch",
                message: "\(method) must run on the socket worker"
            )
        }

        v2MainSync { self.v2RefreshKnownRefs() }


        return withSocketCommandPolicy(commandKey: method, isV2: true) {
            switch method {


        // Windows — see Sources/SocketHandlers/WindowHandlers.swift (C11-159)

        // Workspaces

        // Blueprints (CMUX-37 Phase 2)

        // Snapshots (CMUX-37 Phase 1)

        // Themes (CMUX-35)

        // Settings

        // Feedback


        // Surfaces / input
        // C11-131: explicit operator-grade state verbs.
        // surface.send_text is on the socketWorker execution policy and is dispatched
        // by socketWorkerV2Response. Reaching this switch for it would mean the
        // routing layer mis-targeted the request; the invalid_dispatch guard above
        // catches that and returns an error.
        // surface.send_key, surface.clear_history, and surface.read_text are on
        // the socketWorker execution policy and are dispatched by
        // socketWorkerV2Response. The invalid_dispatch guard above catches any
        // mis-routed request before it reaches this switch.
        // C11-24 conversation store

        // Mailbox

        // Panes

        // Notifications

        // App focus

        // Browser
        case "browser.open_split":
            return v2Result(id: id, self.v2BrowserOpenSplit(params: params))
        case "browser.navigate":
            return v2Result(id: id, self.v2BrowserNavigate(params: params))
        case "browser.back":
            return v2Result(id: id, self.v2BrowserBack(params: params))
        case "browser.forward":
            return v2Result(id: id, self.v2BrowserForward(params: params))
        case "browser.reload":
            return v2Result(id: id, self.v2BrowserReload(params: params))
        case "browser.url.get":
            return v2Result(id: id, self.v2BrowserGetURL(params: params))
        case "browser.focus_webview":
            return v2Result(id: id, self.v2BrowserFocusWebView(params: params))
        case "browser.is_webview_focused":
            return v2Result(id: id, self.v2BrowserIsWebViewFocused(params: params))
        case "browser.snapshot":
            return v2Result(id: id, self.v2BrowserSnapshot(params: params))
        case "browser.eval":
            return v2Result(id: id, self.v2BrowserEval(params: params))
        case "browser.wait":
            return v2Result(id: id, self.v2BrowserWait(params: params))
        case "browser.click":
            return v2Result(id: id, self.v2BrowserClick(params: params))
        case "browser.dblclick":
            return v2Result(id: id, self.v2BrowserDblClick(params: params))
        case "browser.hover":
            return v2Result(id: id, self.v2BrowserHover(params: params))
        case "browser.focus":
            return v2Result(id: id, self.v2BrowserFocusElement(params: params))
        case "browser.type":
            return v2Result(id: id, self.v2BrowserType(params: params))
        case "browser.fill":
            return v2Result(id: id, self.v2BrowserFill(params: params))
        case "browser.press":
            return v2Result(id: id, self.v2BrowserPress(params: params))
        case "browser.keydown":
            return v2Result(id: id, self.v2BrowserKeyDown(params: params))
        case "browser.keyup":
            return v2Result(id: id, self.v2BrowserKeyUp(params: params))
        case "browser.check":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: true))
        case "browser.uncheck":
            return v2Result(id: id, self.v2BrowserCheck(params: params, checked: false))
        case "browser.select":
            return v2Result(id: id, self.v2BrowserSelect(params: params))
        case "browser.scroll":
            return v2Result(id: id, self.v2BrowserScroll(params: params))
        case "browser.scroll_into_view":
            return v2Result(id: id, self.v2BrowserScrollIntoView(params: params))
        case "browser.screenshot":
            return v2Result(id: id, self.v2BrowserScreenshot(params: params))
        case "browser.get.text":
            return v2Result(id: id, self.v2BrowserGetText(params: params))
        case "browser.get.html":
            return v2Result(id: id, self.v2BrowserGetHTML(params: params))
        case "browser.get.value":
            return v2Result(id: id, self.v2BrowserGetValue(params: params))
        case "browser.get.attr":
            return v2Result(id: id, self.v2BrowserGetAttr(params: params))
        case "browser.get.title":
            return v2Result(id: id, self.v2BrowserGetTitle(params: params))
        case "browser.get.count":
            return v2Result(id: id, self.v2BrowserGetCount(params: params))
        case "browser.get.box":
            return v2Result(id: id, self.v2BrowserGetBox(params: params))
        case "browser.get.styles":
            return v2Result(id: id, self.v2BrowserGetStyles(params: params))
        case "browser.is.visible":
            return v2Result(id: id, self.v2BrowserIsVisible(params: params))
        case "browser.is.enabled":
            return v2Result(id: id, self.v2BrowserIsEnabled(params: params))
        case "browser.is.checked":
            return v2Result(id: id, self.v2BrowserIsChecked(params: params))
        case "browser.find.role":
            return v2Result(id: id, self.v2BrowserFindRole(params: params))
        case "browser.find.text":
            return v2Result(id: id, self.v2BrowserFindText(params: params))
        case "browser.find.label":
            return v2Result(id: id, self.v2BrowserFindLabel(params: params))
        case "browser.find.placeholder":
            return v2Result(id: id, self.v2BrowserFindPlaceholder(params: params))
        case "browser.find.alt":
            return v2Result(id: id, self.v2BrowserFindAlt(params: params))
        case "browser.find.title":
            return v2Result(id: id, self.v2BrowserFindTitle(params: params))
        case "browser.find.testid":
            return v2Result(id: id, self.v2BrowserFindTestId(params: params))
        case "browser.find.first":
            return v2Result(id: id, self.v2BrowserFindFirst(params: params))
        case "browser.find.last":
            return v2Result(id: id, self.v2BrowserFindLast(params: params))
        case "browser.find.nth":
            return v2Result(id: id, self.v2BrowserFindNth(params: params))
        case "browser.frame.select":
            return v2Result(id: id, self.v2BrowserFrameSelect(params: params))
        case "browser.frame.main":
            return v2Result(id: id, self.v2BrowserFrameMain(params: params))
        case "browser.dialog.accept":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: true))
        case "browser.dialog.dismiss":
            return v2Result(id: id, self.v2BrowserDialogRespond(params: params, accept: false))
        case "browser.download.wait":
            return v2Result(id: id, self.v2BrowserDownloadWait(params: params))
        case "browser.cookies.get":
            return v2Result(id: id, self.v2BrowserCookiesGet(params: params))
        case "browser.cookies.set":
            return v2Result(id: id, self.v2BrowserCookiesSet(params: params))
        case "browser.cookies.clear":
            return v2Result(id: id, self.v2BrowserCookiesClear(params: params))
        case "browser.storage.get":
            return v2Result(id: id, self.v2BrowserStorageGet(params: params))
        case "browser.storage.set":
            return v2Result(id: id, self.v2BrowserStorageSet(params: params))
        case "browser.storage.clear":
            return v2Result(id: id, self.v2BrowserStorageClear(params: params))
        case "browser.tab.new":
            return v2Result(id: id, self.v2BrowserTabNew(params: params))
        case "browser.tab.list":
            return v2Result(id: id, self.v2BrowserTabList(params: params))
        case "browser.tab.switch":
            return v2Result(id: id, self.v2BrowserTabSwitch(params: params))
        case "browser.tab.close":
            return v2Result(id: id, self.v2BrowserTabClose(params: params))
        case "browser.console.list":
            return v2Result(id: id, self.v2BrowserConsoleList(params: params))
        case "browser.console.clear":
            return v2Result(id: id, self.v2BrowserConsoleClear(params: params))
        case "browser.errors.list":
            return v2Result(id: id, self.v2BrowserErrorsList(params: params))
        case "browser.highlight":
            return v2Result(id: id, self.v2BrowserHighlight(params: params))
        case "browser.state.save":
            return v2Result(id: id, self.v2BrowserStateSave(params: params))
        case "browser.state.load":
            return v2Result(id: id, self.v2BrowserStateLoad(params: params))
        case "browser.addinitscript":
            return v2Result(id: id, self.v2BrowserAddInitScript(params: params))
        case "browser.addscript":
            return v2Result(id: id, self.v2BrowserAddScript(params: params))
        case "browser.addstyle":
            return v2Result(id: id, self.v2BrowserAddStyle(params: params))
        case "browser.viewport.set":
            return v2Result(id: id, self.v2BrowserViewportSet(params: params))
        case "browser.geolocation.set":
            return v2Result(id: id, self.v2BrowserGeolocationSet(params: params))
        case "browser.offline.set":
            return v2Result(id: id, self.v2BrowserOfflineSet(params: params))
        case "browser.trace.start":
            return v2Result(id: id, self.v2BrowserTraceStart(params: params))
        case "browser.trace.stop":
            return v2Result(id: id, self.v2BrowserTraceStop(params: params))
        case "browser.network.route":
            return v2Result(id: id, self.v2BrowserNetworkRoute(params: params))
        case "browser.network.unroute":
            return v2Result(id: id, self.v2BrowserNetworkUnroute(params: params))
        case "browser.network.requests":
            return v2Result(id: id, self.v2BrowserNetworkRequests(params: params))
        case "browser.screencast.start":
            return v2Result(id: id, self.v2BrowserScreencastStart(params: params))
        case "browser.screencast.stop":
            return v2Result(id: id, self.v2BrowserScreencastStop(params: params))
        case "browser.input_mouse":
            return v2Result(id: id, self.v2BrowserInputMouse(params: params))
        case "browser.input_keyboard":
            return v2Result(id: id, self.v2BrowserInputKeyboard(params: params))
        case "browser.input_touch":
            return v2Result(id: id, self.v2BrowserInputTouch(params: params))

        // Markdown

        // M3 — structured sidebar state (extends v1 `sidebar_state` with agent_chip)

        // surface.read_text is on the socketWorker execution policy and is
        // dispatched by socketWorkerV2Response.

        // M7 — title bar projection (read-only sugar)



            default:
                // C11-159: methods whose per-domain handlers have been relocated to
                // Sources/SocketHandlers/ are routed here. Any method still not handled
                // returns the identical method_not_found error as before.
                if let extracted = v2DispatchExtracted(method, id: id, params: params) {
                    return extracted
                }
                return v2Error(id: id, code: "method_not_found", message: "Unknown method")
            }
        }
    }

    /// C11-159 dispatcher seam (v2). Routes a method whose per-domain handler
    /// unit lives under `Sources/SocketHandlers/` by its domain prefix. Returns
    /// nil only when no relocated domain owns the prefix, so the caller falls
    /// back to the identical `method_not_found` response. This is the handler
    /// seam DX-1 asks for; the router (parse/auth-gate/policy/main-sync) is
    /// unchanged. Runs on the main actor exactly like the switch it replaces.
    func v2DispatchExtracted(_ method: String, id: Any?, params: [String: Any]) -> String? {
        if method.hasPrefix("window.") { return v2DispatchWindow(method, id: id, params: params) }
        if method.hasPrefix("workspace.") { return v2DispatchWorkspace(method, id: id, params: params) }
        if method.hasPrefix("pane.") { return v2DispatchPane(method, id: id, params: params) }
        if method.hasPrefix("surface.") { return v2DispatchSurface(method, id: id, params: params) }
        if method.hasPrefix("debug.") { return v2DispatchDebug(method, id: id, params: params) }
        if method.hasPrefix("theme.") { return v2DispatchTheme(method, id: id, params: params) }
        if method.hasPrefix("system.") || method.hasPrefix("auth.") || method.hasPrefix("app.") { return v2DispatchSystem(method, id: id, params: params) }
        if method.hasPrefix("snapshot.") { return v2DispatchSnapshot(method, id: id, params: params) }
        if method.hasPrefix("conversation.") { return v2DispatchConversation(method, id: id, params: params) }
        if method.hasPrefix("notification.") { return v2DispatchNotification(method, id: id, params: params) }
        if method.hasPrefix("markdown.") || method.hasPrefix("feedback.") { return v2DispatchMarkdownFeedback(method, id: id, params: params) }
        if method.hasPrefix("settings.") || method.hasPrefix("sidebar.") || method.hasPrefix("session.") || method.hasPrefix("tab.") || method.hasPrefix("mailbox.") { return v2DispatchMisc(method, id: id, params: params) }
        return nil
    }





    private func v2TreeWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    private func v2TreeWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [[String: Any]]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            var item: [String: Any] = [
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": surfaceIndex,
                "type": panel.panelType.rawValue,
                "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                "focused": panel.id == focusedSurfaceId,
                "selected": selectedInPane,
                "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                "tty": v2OrNull(workspace.surfaceTTYNames[panel.id])
            ]

            if panel.panelType == .browser, let browserPanel = panel as? BrowserPanel {
                item["url"] = browserPanel.currentURL?.absoluteString ?? ""
            } else {
                item["url"] = NSNull()
            }
            if let markdownPanel = panel as? MarkdownPanel {
                item["file_path"] = markdownPanel.filePath
            }
            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(item)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                let lhs = ($0["index_in_pane"] as? Int) ?? ($0["index"] as? Int) ?? Int.max
                let rhs = ($1["index_in_pane"] as? Int) ?? ($1["index"] as? Int) ?? Int.max
                return lhs < rhs
            }
        }

        // M8: derive content area + per-pane layout from bonsplit's snapshot.
        // Percent values are workspace-relative regardless of split nesting depth.
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        let contentSize = snapshot.containerFrame
        let contentWidth = contentSize.width
        let contentHeight = contentSize.height
        let hasLayout = contentWidth > 0 && contentHeight > 0

        var pixelByPaneId: [UUID: (h0: Int, h1: Int, v0: Int, v1: Int)] = [:]
        var percentByPaneId: [UUID: (h0: Double, h1: Double, v0: Double, v1: Double)] = [:]
        if hasLayout {
            for geom in snapshot.panes {
                guard let paneUUID = UUID(uuidString: geom.paneId) else { continue }
                // Subtract the content origin so coordinates are relative to the workspace
                // content area rather than the host window.
                let relX = geom.frame.x - contentSize.x
                let relY = geom.frame.y - contentSize.y
                let h0 = Int((relX).rounded())
                let h1 = Int((relX + geom.frame.width).rounded())
                let v0 = Int((relY).rounded())
                let v1 = Int((relY + geom.frame.height).rounded())
                pixelByPaneId[paneUUID] = (h0, h1, v0, v1)
                percentByPaneId[paneUUID] = (
                    relX / contentWidth,
                    (relX + geom.frame.width) / contentWidth,
                    relY / contentHeight,
                    (relY + geom.frame.height) / contentHeight
                )
            }
        }

        let splitPathByPaneId = m8SplitPathByPaneId(workspace: workspace)

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [[String: Any]] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            // M8 layout sub-object.
            let path = splitPathByPaneId[paneId.id] ?? []
            let layoutObj: [String: Any]
            if hasLayout, let pix = pixelByPaneId[paneId.id], let pct = percentByPaneId[paneId.id] {
                layoutObj = [
                    "percent": [
                        "H": [pct.h0, pct.h1],
                        "V": [pct.v0, pct.v1]
                    ],
                    "pixels": [
                        "H": [pix.h0, pix.h1],
                        "V": [pix.v0, pix.v1]
                    ],
                    "split_path": path
                ]
            } else {
                layoutObj = [
                    "percent": NSNull(),
                    "pixels": NSNull(),
                    "split_path": path
                ]
            }

            return [
                "id": paneId.id.uuidString,
                "ref": v2Ref(kind: .pane, uuid: paneId.id),
                "index": paneIndex,
                "focused": paneId == focusedPaneId,
                "surface_ids": surfaceUUIDs.map { $0.uuidString },
                "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                "surface_count": surfaceUUIDs.count,
                "surfaces": surfacesByPane[paneId.id] ?? [],
                "layout": layoutObj
            ]
        }

        let contentArea: Any
        if hasLayout {
            contentArea = [
                "pixels": [
                    "width": Int(contentWidth.rounded()),
                    "height": Int(contentHeight.rounded())
                ]
            ]
        } else {
            contentArea = NSNull()
        }

        return [
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "selected": selected,
            "pinned": workspace.isPinned,
            "content_area": contentArea,
            "panes": panes
        ]
    }

    /// Walk the workspace's split tree and produce a root-to-leaf path of
    /// `H:left | H:right | V:top | V:bottom` tokens for every pane. The path is
    /// recomputed on every call — it is **not** a stable identifier and changes
    /// whenever the surrounding splits change.
    private func m8SplitPathByPaneId(workspace: Workspace) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        let tree = workspace.bonsplitController.treeSnapshot()
        m8WalkSplitTree(node: tree, path: [], into: &result)
        return result
    }

    private func m8WalkSplitTree(node: ExternalTreeNode, path: [String], into result: inout [UUID: [String]]) {
        switch node {
        case .pane(let paneNode):
            if let uuid = UUID(uuidString: paneNode.id) {
                result[uuid] = path
            }
        case .split(let splitNode):
            let isHorizontal = splitNode.orientation.lowercased() == "horizontal"
            let firstToken = isHorizontal ? "H:left" : "V:top"
            let secondToken = isHorizontal ? "H:right" : "V:bottom"
            m8WalkSplitTree(node: splitNode.first, path: path + [firstToken], into: &result)
            m8WalkSplitTree(node: splitNode.second, path: path + [secondToken], into: &result)
        }
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

    nonisolated func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    func v2MainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    // 8 s is slightly under the CLI 10 s deadline so the server-side error
    // propagates before SO_RCVTIMEO fires on the caller side.
    // Must stay strictly less than SocketClient.configuredDefaultDeadlineSeconds (10 s).
    private static let kTier1MainThreadDeadlineSeconds: TimeInterval = 8.0

    func v2MainSyncWithDeadline<T>(seconds: TimeInterval = kTier1MainThreadDeadlineSeconds, _ body: @escaping () -> T) -> T? {
        if Thread.isMainThread { return body() }
        var result: T?
        // Cancellation flag: written by the calling (socket) thread after a timeout, read by the
        // main-thread closure. Prevents ghost mutations when the main queue drains after the
        // caller has already received a timeout error and the operation has been declared failed.
        // On Darwin, GCD memory ordering makes this safe in practice. C11-4 can harden further
        // if needed (e.g., os_unfair_lock) for strict memory-model correctness.
        var cancelled = false
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            if !cancelled { result = body() }
            sema.signal()
        }
        if sema.wait(timeout: .now() + seconds) == .success { return result }
        cancelled = true
        return nil
    }

    nonisolated func v2Ok(id: Any?, result: Any) -> String {
        return v2Encode([
            "id": v2OrNull(id),
            "ok": true,
            "result": result
        ])
    }

    nonisolated func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        var err: [String: Any] = ["code": code, "message": message]
        if let data {
            err["data"] = data
        }
        return v2Encode([
            "id": v2OrNull(id),
            "ok": false,
            "error": err
        ])
    }

    // C11-159: widened private->internal so per-domain handler extensions can
    // return this type (used as the return of ~all v2* handlers). See DX-5 inventory.
    enum V2CallResult: Error {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    nonisolated func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    nonisolated func v2Encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }

        // Ensure single-line responses for the line-oriented socket protocol.
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        return s
    }

    func v2EnsureHandleRef(kind: V2HandleKind, uuid: UUID) -> String {
        if let existing = v2RefByUUID[kind]?[uuid] {
            return existing
        }
        let next = v2NextHandleOrdinal[kind] ?? 1
        let ref = "\(kind.rawValue):\(next)"
        var byUUID = v2RefByUUID[kind] ?? [:]
        var byRef = v2UUIDByRef[kind] ?? [:]
        byUUID[uuid] = ref
        byRef[ref] = uuid
        v2RefByUUID[kind] = byUUID
        v2UUIDByRef[kind] = byRef
        v2NextHandleOrdinal[kind] = next + 1
        return ref
    }

    func v2ResolveHandleRef(_ handle: String) -> UUID? {
        for kind in V2HandleKind.allCases {
            if let id = v2UUIDByRef[kind]?[handle] {
                return id
            }
        }
        // Tab refs are aliases for surface refs in tab-facing APIs.
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tab:"),
           let ordinal = Int(trimmed.replacingOccurrences(of: "tab:", with: "")),
           let id = v2UUIDByRef[.surface]?["surface:\(ordinal)"] {
            return id
        }
        return nil
    }

    func v2Ref(kind: V2HandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2EnsureHandleRef(kind: kind, uuid: uuid)
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    /// Cheap surface-ref-only lookup. Mints (or returns) just the `surface:N`
    /// handle for a panel — a dictionary lookup, no pane/window/locate work.
    /// Used by the bonsplit tab context menu's "Copy surface:N" item, which is
    /// built per tab and must stay cheap. `@MainActor` like the ref maps.
    func surfaceRefOnly(forSurfaceUUID surfaceId: UUID) -> String {
        v2EnsureHandleRef(kind: .surface, uuid: surfaceId)
    }

    /// UI-facing handle lookup for the Surface Details panel.
    ///
    /// Mints (or returns) the friendly `surface:N` / `tab:N` / `pane:M` /
    /// `workspace:X` / `window:Y` handles for a surface — the same numbers the
    /// CLI (`c11 identify`, `c11 tree`) exposes — plus a few human-relevant
    /// fields (tty, cwd, url, file). The operator opens this to answer "what
    /// number is this surface?" without dropping to the CLI. Minting on demand
    /// is intentional: a surface the CLI has never touched still gets a stable
    /// handle the operator can paste into a command.
    ///
    /// `@MainActor`-confined like the rest of the v2 ref maps; safe to call
    /// from UI (the panel is presented on the main actor).
    func surfaceHandleInfo(workspaceId: UUID, surfaceId: UUID) -> SurfaceHandleInfo {
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: surfaceId)
        let tabRef = surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
        let workspaceRef = v2EnsureHandleRef(kind: .workspace, uuid: workspaceId)

        var paneRef: String?
        var windowRef: String?
        var tty: String?
        var workingDirectory: String?
        var url: String?
        var filePath: String?

        if let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId) {
            windowRef = v2EnsureHandleRef(kind: .window, uuid: located.windowId)
            if let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) {
                for paneId in ws.bonsplitController.allPaneIds
                where ws.bonsplitController.tabs(inPane: paneId)
                    .contains(where: { ws.panelIdFromSurfaceId($0.id) == surfaceId }) {
                    paneRef = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    break
                }
                tty = ws.surfaceTTYNames[surfaceId]
                workingDirectory = ws.surfaceDirectories[surfaceId]
                if let panel = ws.panels[surfaceId] {
                    if let browser = panel as? BrowserPanel {
                        url = browser.currentURL?.absoluteString
                    }
                    if let markdown = panel as? MarkdownPanel {
                        filePath = markdown.filePath
                    }
                }
            }
        }

        let (metadata, _) = SurfaceMetadataStore.shared.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let terminalType = metadata[MetadataKey.terminalType] as? String

        return SurfaceHandleInfo(
            surfaceRef: surfaceRef,
            tabRef: tabRef,
            paneRef: paneRef,
            workspaceRef: workspaceRef,
            windowRef: windowRef,
            terminalType: terminalType,
            tty: tty,
            workingDirectory: workingDirectory,
            url: url,
            filePath: filePath
        )
    }

    func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = v2EnsureHandleRef(kind: .surface, uuid: panelId)
                    }
                }
            }
        }
    }

    // MARK: - V2 Param Parsing

    nonisolated func v2String(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func v2StringArray(_ params: [String: Any], _ key: String) -> [String]? {
        if let raw = params[key] as? [String] {
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let raw = params[key] as? [Any] {
            let normalized = raw
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let single = v2String(params, key) {
            return [single]
        }
        return nil
    }

    func v2StringMap(_ params: [String: Any], _ key: String) -> [String: String]? {
        guard let raw = params[key] else { return nil }
        if let dict = raw as? [String: String] {
            return dict
        }
        if let anyDict = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (k, value) in anyDict {
                guard let stringValue = value as? String else { continue }
                out[k] = stringValue
            }
            return out
        }
        return nil
    }

    func v2ActionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        guard let action = v2String(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    func v2RawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    func v2UUID(_ params: [String: Any], _ key: String) -> UUID? {
        guard let s = v2String(params, key) else { return nil }
        if let uuid = UUID(uuidString: s) {
            return uuid
        }
        return v2ResolveHandleRef(s)
    }

    func v2UUIDAny(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        return v2ResolveHandleRef(trimmed)
    }
    nonisolated func v2Bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let b = params[key] as? Bool { return b }
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func v2LocatePane(_ paneUUID: UUID) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace, paneId: PaneID)? {
        guard let app = AppDelegate.shared else { return nil }
        let windows = app.listMainWindowSummaries()
        for item in windows {
            guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
            for ws in tm.tabs {
                if let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) {
                    return (item.windowId, tm, ws, paneId)
                }
            }
        }
        return nil
    }
    nonisolated func v2Int(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    func v2HasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        guard let raw = params[key] else { return false }
        return !(raw is NSNull)
    }

    func v2StrictInt(_ params: [String: Any], _ key: String) -> Int? {
        v2StrictIntAny(params[key])
    }

    func v2StrictIntAny(_ raw: Any?) -> Int? {
        guard let raw else { return nil }

        if let numberValue = raw as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = numberValue.doubleValue
            guard doubleValue.isFinite, floor(doubleValue) == doubleValue else {
                return nil
            }
            return Int(exactly: doubleValue)
        }

        if let intValue = raw as? Int {
            return intValue
        }

        if let stringValue = raw as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    func v2PanelType(_ params: [String: Any], _ key: String) -> PanelType? {
        guard let s = v2String(params, key) else { return nil }
        return PanelType(rawValue: s.lowercased())
    }

    /// Reject creating a surface of a type the operator has disabled. Returns a
    /// `surface_type_disabled` error envelope when blocked, or `nil` to proceed.
    /// Terminal is never gated. Restore/snapshot bypasses this by calling the
    /// low-level `Workspace.newBrowser*`/`newMarkdown*` methods directly.
    func v2SurfaceTypeDenial(_ type: PanelType) -> V2CallResult? {
        guard !SurfaceTypeAvailability.isEnabled(type) else { return nil }
        return .err(
            code: "surface_type_disabled",
            message: SurfaceTypeAvailability.disabledMessage(for: type),
            data: ["type": type.rawValue]
        )
    }

    /// Validate and resolve a markdown file path from raw input.
    /// Returns nil on success (resolved path stored in `resolved`), or a V2CallResult error.
    func v2ValidateMarkdownPath(_ rawPath: String?, context: String, resolved: inout String?) -> V2CallResult? {
        guard let rawPath else {
            return .err(code: "invalid_params", message: "Missing --file for markdown \(context)", data: nil)
        }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let resolvedPath = NSString(string: expandedPath).standardizingPath
        guard resolvedPath.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "Path must be absolute: \(resolvedPath)", data: ["path": resolvedPath])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return .err(code: "not_found", message: "File not found: \(resolvedPath)", data: ["path": resolvedPath])
        }
        guard !isDir.boolValue else {
            return .err(code: "invalid_params", message: "Path is a directory, not a file: \(resolvedPath)", data: ["path": resolvedPath])
        }
        guard FileManager.default.isReadableFile(atPath: resolvedPath) else {
            return .err(code: "permission_denied", message: "File not readable: \(resolvedPath)", data: ["path": resolvedPath])
        }
        resolved = resolvedPath
        return nil
    }

    /// Validate and resolve a `cwd` param for surface.split / pane.create.
    ///
    /// Outcomes encoded into `resolved`:
    /// - No `cwd` param, or the literal `"inherit"` → `resolved = nil`, return
    ///   `nil` (no error). A nil working directory falls through to the existing
    ///   inheritance chain (parent panel cwd → workspace cwd → $HOME).
    /// - A non-empty path → expanded, standardized, and checked: it must be
    ///   absolute, must exist, and must be a directory. On success `resolved`
    ///   holds the absolute directory path. On failure returns a `V2CallResult`
    ///   error so the spawn never silently falls back to $HOME.
    ///
    /// The validation logic itself lives in the pure, testable
    /// `CwdParamResolution.resolve(_:)` enum so it can be exercised from
    /// `c11LogicTests` without standing up a TerminalController; this method is
    /// the thin adapter that maps the outcome onto the socket result envelope.
    func v2ResolveCwdParam(_ params: [String: Any], resolved: inout String?) -> V2CallResult? {
        resolved = nil
        switch CwdParamResolution.resolve(params["cwd"]) {
        case .inherit:
            return nil
        case .path(let dir):
            resolved = dir
            return nil
        case .invalid(let code, let message, let path):
            let data: [String: Any]? = path.map { ["path": $0] }
            return .err(code: code, message: message, data: data)
        }
    }

    // MARK: - V2 Context Resolution

    func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Fall back to global lookup by workspace_id/surface_id/tab_id,
        // then panel_id (pane.confirm and other panel-scoped methods), and
        // finally to the active window's TabManager.
        if let windowId = v2UUID(params, "window_id") {
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager }) {
                return tm
            }
        }
        // panel_id: for panel-scoped methods (pane.confirm) callers may pass
        // only the panel identity. Panel IDs are surface IDs today, so the
        // surface locator finds the owning TabManager even across windows.
        if let panelId = v2UUID(params, "panel_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: panelId)?.tabManager }) {
                return tm
            }
        }
        return tabManager
    }

    func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    // MARK: - V2 Window Methods






    // MARK: - V2 Workspace Methods










    /// Resolve the Workspace referenced by `workspace_id`. Falls back to the
    /// currently selected workspace on the caller's TabManager if no explicit
    /// id is supplied. Returns nil when the workspace cannot be located.
    ///
    /// Performs a main-actor read to locate the Workspace instance; callers
    /// should mutate `workspace.metadata` via `v2MainSync` since `Workspace`
    /// is `@MainActor` (see `Workspace.swift` class declaration).
    func v2ResolveWorkspaceForMetadata(
        params: [String: Any]
    ) -> (tabManager: TabManager, workspaceId: UUID)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        if let explicit = v2UUID(params, "workspace_id") {
            return v2MainSync {
                guard tabManager.tabs.contains(where: { $0.id == explicit }) else { return nil }
                return (tabManager, explicit)
            }
        }
        return v2MainSync {
            guard let selected = tabManager.selectedTabId,
                  tabManager.tabs.contains(where: { $0.id == selected }) else {
                return nil
            }
            return (tabManager, selected)
        }
    }


    // MARK: - V2 Blueprint Methods (CMUX-37 Phase 2)




    // MARK: - V2 Snapshot Methods (CMUX-37 Phase 1)











    // MARK: - V2 Surface Methods

    func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }





    // MARK: - Size-aware split policy helpers

    private func splitDirectionString(_ d: SplitDirection) -> String {
        switch d {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }

    /// Flip a split axis while keeping the insert side: left↔up, right↔down.
    private func flippedSplitDirection(_ d: SplitDirection) -> SplitDirection {
        switch d {
        case .left: return .up
        case .up: return .left
        case .right: return .down
        case .down: return .right
        }
    }

    /// Per-call escape hatch: `--allow-undersized` (alias `--force`).
    private func splitForceFlag(_ params: [String: Any]) -> Bool {
        (v2Bool(params, "allow_undersized") ?? false) || (v2Bool(params, "force") ?? false)
    }

    private enum SizeAwareSplitPlan {
        /// Create the split on `direction` (may differ from `requested` if flipped).
        case split(direction: SplitDirection, requested: SplitDirection, warning: String?)
        /// Add a tab to `paneId` instead of splitting.
        case tab(paneId: PaneID, warning: String?)
        /// Refuse with an actionable message.
        case refuse(message: String, data: [String: Any])
    }

    /// Apply the active pane-size policy to a split request. Main-actor only
    /// (callers are already inside `v2MainSync`).
    private func planSizeAwareSplit(
        ws: Workspace,
        sourcePanelId: UUID,
        requested: SplitDirection,
        newIsTerminal: Bool,
        force: Bool
    ) -> SizeAwareSplitPlan {
        let requestedAxis: SplitAxis = requested.isHorizontal ? .horizontal : .vertical
        guard let eval = ws.evaluateSplitSize(
            sourcePanelId: sourcePanelId,
            requested: requestedAxis,
            newIsTerminal: newIsTerminal,
            force: force
        ) else {
            // Geometry not known yet — proceed as requested rather than block.
            return .split(direction: requested, requested: requested, warning: nil)
        }
        let decision = eval.decision
        let warning = PaneSizePolicy.warningText(for: decision, kindLabel: eval.kindLabel)
        switch decision.outcome {
        case .proceed(let axis):
            let applied = (axis == requestedAxis) ? requested : flippedSplitDirection(requested)
            return .split(direction: applied, requested: requested, warning: warning)
        case .addTab:
            return .tab(paneId: eval.targetPaneId, warning: warning)
        case .refuse:
            let paneRef = v2EnsureHandleRef(kind: .pane, uuid: eval.targetPaneId.id)
            let msg = PaneSizePolicy.refusalMessage(for: decision, kindLabel: eval.kindLabel, paneRefLabel: paneRef)
            let data: [String: Any] = [
                "pane_ref": paneRef,
                "requested_direction": splitDirectionString(requested),
                "resulting": [
                    "width": Int(decision.resultingChild.width.rounded()),
                    "height": Int(decision.resultingChild.height.rounded())
                ],
                "minimum": [
                    "width": Int(decision.minPoints.width.rounded()),
                    "height": Int(decision.minPoints.height.rounded())
                ]
            ]
            return .refuse(message: msg, data: data)
        }
    }

    /// Attach size-policy fields to a successful split / pane-create response.
    private func annotateSizeOutcome(
        _ result: inout [String: Any],
        requested: SplitDirection,
        applied: SplitDirection,
        becameTab: Bool,
        warning: String?
    ) {
        result["requested_direction"] = splitDirectionString(requested)
        result["applied_direction"] = splitDirectionString(applied)
        result["size_outcome"] = becameTab ? "tab" : (requested == applied ? "split" : "flipped")
        result["size_warning"] = v2OrNull(warning)
    }











    // C11-26: shared scaffolding for the socket-worker-policy surface.* handlers.
    // The handlers run nonisolated; they capture the references they need on
    // @MainActor (Phase A) so the worker-side flow can read them without further
    // hops, and so result envelope strings produced by v2Ref are computed while
    // we are still safely on the main actor.

    private struct SurfaceSendPhaseAResolved {
        let terminalPanel: TerminalPanel
        let initialSurface: ghostty_surface_t?
        let workspaceIdString: String
        let surfaceIdString: String
        let responseEnvelope: [String: Any]
    }

    private enum SurfaceSendPhaseAOutcome {
        case ok(SurfaceSendPhaseAResolved)
        case err(V2CallResult)
    }

    @MainActor
    private func resolveSurfaceSendTargets(params: [String: Any]) -> SurfaceSendPhaseAOutcome {
        // C11-26: Worker-policy methods skip processV2Command's
        // `v2MainSync { v2RefreshKnownRefs() }` (Sources/TerminalController.swift:2132).
        // Without this refresh, a fresh `surface:N` / `workspace:N` ref handle is
        // unresolved on the first worker call and `v2UUID(...)` silently falls
        // back to the focused panel — meaning text/keys can be injected into the
        // wrong terminal. Refresh here so the handle map is current before any
        // resolution call below.
        v2RefreshKnownRefs()

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(.err(code: "unavailable", message: "TabManager not available", data: nil))
        }
        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(.err(code: "not_found", message: "Workspace not found", data: nil))
        }
        let resolvedSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
        guard let surfaceId = resolvedSurfaceId else {
            return .err(.err(code: "not_found", message: "No focused surface", data: nil))
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .err(.err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString]))
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        let envelope: [String: Any] = [
            "workspace_id": ws.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ]
        return .ok(SurfaceSendPhaseAResolved(
            terminalPanel: terminalPanel,
            initialSurface: terminalPanel.surface.surface,
            workspaceIdString: ws.id.uuidString,
            surfaceIdString: surfaceId.uuidString,
            responseEnvelope: envelope
        ))
    }

    // Off-main variant of waitForTerminalSurface: the worker thread blocks on a
    // semaphore while NotificationCenter observers (registered with queue: .main)
    // fire on the still-free main queue. The legacy waitForTerminalSurface goes
    // through v2AwaitCallback whose main-thread branch nests CFRunLoopRun inside
    // an outer DispatchQueue.main.sync block — that is the C11-26 deadlock; this
    // off-main variant avoids the nested run loop entirely.
    private nonisolated func waitForTerminalSurfaceOffMain(_ terminalPanel: TerminalPanel, waitUpTo timeout: TimeInterval) -> ghostty_surface_t? {
        // Off-main reads of `TerminalSurface.surface` are intentional here: the
        // property is a pointer-sized value (Darwin guarantees naturally aligned
        // word loads/stores are atomic), so a torn read is not possible. The
        // post-observer recheck below closes the observer-registration race
        // window — without it, an attach that fires between the first read and
        // observer install would never wake the semaphore. If
        // `TerminalSurface.surface` is ever migrated to `@MainActor` isolation,
        // this helper must be revisited (the off-main reads would then violate
        // actor isolation and need to round-trip via Task { @MainActor in ... }).
        if let surface = terminalPanel.surface.surface { return surface }
        let terminalSurface = terminalPanel.surface
        terminalSurface.requestBackgroundSurfaceStartIfNeeded()
        #if DEBUG
        dlog("v2.send_text waiting for surface attach (slow path) — backgroundSurfaceStartIfNeeded re-dispatched async")
        #endif

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var done = false
        let signalOnce: () -> Void = {
            lock.lock()
            let alreadyDone = done
            done = true
            lock.unlock()
            if !alreadyDone { semaphore.signal() }
        }

        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: terminalSurface,
            queue: .main
        ) { _ in
            signalOnce()
        }
        let hostedViewObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: terminalSurface,
            queue: .main
        ) { _ in
            if terminalSurface.surface != nil {
                signalOnce()
            }
        }

        if terminalSurface.surface != nil {
            signalOnce()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        NotificationCenter.default.removeObserver(readyObserver)
        NotificationCenter.default.removeObserver(hostedViewObserver)
        return terminalPanel.surface.surface
    }





    // MARK: - M7 title bar





    private func readTerminalTextBase64(terminalPanel: TerminalPanel, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let surface = terminalPanel.surface.surface else { return "ERROR: Terminal surface not found" }

        func readSelectionText(pointTag: ghostty_point_tag_e) -> String? {
            let topLeft = ghostty_point_s(
                tag: pointTag,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            )
            let bottomRight = ghostty_point_s(
                tag: pointTag,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            )
            let selection = ghostty_selection_s(
                top_left: topLeft,
                bottom_right: bottomRight,
                rectangle: false
            )

            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else {
                return nil
            }
            defer {
                ghostty_surface_free_text(surface, &text)
            }

            guard let ptr = text.text, text.text_len > 0 else {
                return ""
            }
            let rawData = Data(bytes: ptr, count: Int(text.text_len))
            return String(decoding: rawData, as: UTF8.self)
        }

        var output: String
        if includeScrollback {
            func candidateScore(_ text: String) -> (lines: Int, bytes: Int) {
                let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
                return (lines, text.utf8.count)
            }

            // Read all available regions and pick the most complete candidate.
            // Different point tags can lose different rows around resize/reflow boundaries.
            let screen = readSelectionText(pointTag: GHOSTTY_POINT_SCREEN)
            let history = readSelectionText(pointTag: GHOSTTY_POINT_SURFACE)
            let active = readSelectionText(pointTag: GHOSTTY_POINT_ACTIVE)

            var candidates: [String] = []
            if let screen {
                candidates.append(screen)
            }
            if history != nil || active != nil {
                var merged = history ?? ""
                if let active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                        merged.append("\n")
                    }
                    merged.append(active)
                }
                candidates.append(merged)
            }

            if let best = candidates.max(by: { lhs, rhs in
                let left = candidateScore(lhs)
                let right = candidateScore(rhs)
                if left.lines != right.lines {
                    return left.lines < right.lines
                }
                return left.bytes < right.bytes
            }) {
                output = best
            } else {
                return "ERROR: Failed to read terminal text"
            }
        } else {
            guard let viewport = readSelectionText(pointTag: GHOSTTY_POINT_VIEWPORT) else {
                return "ERROR: Failed to read terminal text"
            }
            output = viewport
        }

        if let lineLimit {
            output = tailTerminalLines(output, maxLines: lineLimit)
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return "OK \(base64)"
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let representations = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        _ = pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }

        let restoredItems = snapshots.compactMap { snapshot -> NSPasteboardItem? in
            guard !snapshot.representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        guard !restoredItems.isEmpty else { return }
        _ = pasteboard.writeObjects(restoredItems)
    }

    private func readGeneralPasteboardString(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let firstURL = urls.first,
           firstURL.isFileURL {
            return firstURL.path
        }
        if let value = pasteboard.string(forType: .string) {
            return value
        }
        return pasteboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel,
        lineLimit: Int?
    ) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboardItems(pasteboard)
        defer {
            restorePasteboardItems(snapshot, to: pasteboard)
        }

        let initialChangeCount = pasteboard.changeCount
        guard terminalPanel.performBindingAction("write_screen_file:copy,vt") else {
            return nil
        }
        guard pasteboard.changeCount != initialChangeCount else {
            return nil
        }
        guard let exportedPath = Self.normalizedExportedScreenPath(readGeneralPasteboardString(pasteboard)) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              var output = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let lineLimit {
            output = tailTerminalLines(output, maxLines: lineLimit)
        }
        return output
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        if includeScrollback,
           let vtOutput = readTerminalTextFromVTExportForSnapshot(
               terminalPanel: terminalPanel,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

        let response = readTerminalTextBase64(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty {
            return ""
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    func readTerminalTextForSessionSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }





    // MARK: - V2 Surface Metadata (Module 2)



    /// M7 side effect: sync render cache + auto-expand title bar when
    /// `title` / `description` is written through M2's metadata API.
    private func applyTitleDescriptionSideEffects(
        workspaceId: UUID,
        surfaceId: UUID,
        tabManager: TabManager,
        applied: [String: Bool],
        autoExpand: Bool
    ) {
        let titleApplied = applied[MetadataKey.title] == true
        let descriptionApplied = applied[MetadataKey.description] == true
        guard titleApplied || descriptionApplied else { return }
        v2MainSync {
            guard let ws = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            if titleApplied {
                ws.syncPanelTitleFromMetadata(panelId: surfaceId)
            }
            if descriptionApplied && autoExpand {
                ws.maybeAutoExpandTitleBar(panelId: surfaceId)
            }
        }
    }



    // MARK: - Mailbox cross-workspace resolution


    private func mailboxCandidatePayload(
        _ surfaces: [MailboxGlobalResolver.Surface]
    ) -> [[String: Any]] {
        surfaces.map { surface in
            [
                "workspace_id": surface.workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: surface.workspaceId),
                "surface_id": surface.surfaceId.uuidString,
                "name": surface.name
            ]
        }
    }

    private func buildMetadataOkPayload(
        workspaceId: UUID,
        surfaceId: UUID,
        tabManager: TabManager,
        result: SurfaceMetadataStore.WriteResult
    ) -> [String: Any] {
        var appliedAny: [String: Any] = [:]
        for (k, v) in result.applied { appliedAny[k] = v }
        var reasonsAny: [String: Any] = [:]
        for (k, v) in result.reasons { reasonsAny[k] = v }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "applied": appliedAny,
            "reasons": reasonsAny,
            "metadata": result.metadata,
            "metadata_sources": result.sources
        ]
    }

    // MARK: - V2 Pane Methods



    private enum V2PaneResizeDirection: String {
        case left
        case right
        case up
        case down

        var splitOrientation: String {
            switch self {
            case .left, .right:
                return "horizontal"
            case .up, .down:
                return "vertical"
            }
        }

        /// A split controls the target pane's right/bottom edge when target is first child,
        /// and left/top edge when target is second child.
        var requiresPaneInFirstChild: Bool {
            switch self {
            case .right, .down:
                return true
            case .left, .up:
                return false
            }
        }

        /// Positive value moves divider toward second child (right/down).
        var dividerDeltaSign: CGFloat {
            requiresPaneInFirstChild ? 1 : -1
        }
    }

    private struct V2PaneResizeCandidate {
        let splitId: UUID
        let orientation: String
        let paneInFirstChild: Bool
        let dividerPosition: CGFloat
        let axisPixels: CGFloat
    }

    private struct V2PaneResizeTrace {
        let containsTarget: Bool
        let bounds: CGRect
    }







    // MARK: - V2 Pane Metadata (CMUX-11 Phase 2)

    /// Resolve the (workspaceId, paneId) pair for a pane-metadata call.
    /// Runs its bonsplit read on main (minimum needed) and returns the tab
    /// manager for downstream use. The actual `PaneMetadataStore` mutation
    /// happens off-main on the store's own serial queue.
    private func v2ResolvePaneForMetadata(
        params: [String: Any]
    ) -> (workspaceId: UUID, paneId: UUID, tabManager: TabManager)? {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return nil
        }
        return v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return nil
            }
            if let paneUUID = v2UUID(params, "pane_id") {
                guard ws.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
                    return nil
                }
                return (ws.id, paneUUID, tabManager)
            }
            // Fallback: default to the workspace's focused pane.
            if let focused = ws.bonsplitController.focusedPaneId {
                return (ws.id, focused.id, tabManager)
            }
            return nil
        }
    }




    private func buildPaneMetadataOkPayload(
        workspaceId: UUID,
        paneId: UUID,
        tabManager: TabManager,
        result: SurfaceMetadataStore.WriteResult,
        includePriorValues: Bool
    ) -> [String: Any] {
        var appliedAny: [String: Any] = [:]
        for (k, v) in result.applied { appliedAny[k] = v }
        var reasonsAny: [String: Any] = [:]
        for (k, v) in result.reasons { reasonsAny[k] = v }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "pane_id": paneId.uuidString,
            "pane_ref": v2Ref(kind: .pane, uuid: paneId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "applied": appliedAny,
            "reasons": reasonsAny,
            "metadata": result.metadata,
            "metadata_sources": result.sources
        ]
        if includePriorValues {
            payload["prior_values"] = result.priorValues
        }
        return payload
    }




    // MARK: - V2 Conversation Methods (C11-24)

    /// Strict surface UUID resolution for conversation commands.
    /// **No focused-fallback** — see plan §"CLI surface" and the env-loss
    /// footgun the architecture exists to fix.
    private func v2ResolveSurfaceForConversation(
        params: [String: Any]
    ) -> Result<UUID, V2CallResult> {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .failure(.err(
                code: "missing_surface",
                message: "surface_id required (no focused-fallback for conversation commands)",
                data: nil
            ))
        }
        return .success(surfaceId)
    }

    /// 64 KiB cap on the serialised payload accepted by v2 conversation
    /// push. Matches the metadata path. Defends the snapshot file against
    /// oversized hook input.
    private static let conversationPayloadMaxBytes: Int = 64 * 1024

    /// Bool detection for payload coercion. Swift `Bool` bridges to
    /// `NSNumber` on Apple platforms, so a naive `as? NSNumber` cast
    /// succeeds for booleans and silently coerces them to `.number(1.0)`.
    /// Use `CFBooleanGetTypeID` to disambiguate.
    private func conversationBoolValue(_ v: Any) -> Bool? {
        let cf = v as CFTypeRef
        if CFGetTypeID(cf) == CFBooleanGetTypeID() {
            return (v as? Bool)
        }
        return nil
    }

    /// Synchronous bridge into the `ConversationStore` actor. Each call
    /// hops onto a Task and waits via a semaphore so the v2 dispatch
    /// thread (off-main) gets a result before returning. The store is
    /// a Swift actor so internal state-transitions are isolated; we only
    /// need this bridge because v2 handlers are sync.
    ///
    /// Bounded timeout (2 s); the actor never blocks on I/O so a hang
    /// here would mean a deadlock somewhere unrelated.
    private func conversationStoreSync<T: Sendable>(
        _ body: @escaping @Sendable (ConversationStore) async -> T
    ) -> T? {
        // C11-24: `Task.detached` so the spawned task does not inherit
        // `@MainActor` isolation from `TerminalController` (declared
        // `@MainActor` at line 18). Without this, the task body cannot
        // run while main is blocked on `sema.wait`, the actor call
        // never completes, and every `v2ConversationList`,
        // `v2ConversationGet`, etc. silently returns the `?? [:]`
        // fallback even when the actor has data. Verified by
        // reproducer at `notes/c11-24-snapshot-capture-bug.md`.
        let store = ConversationStore.shared
        nonisolated(unsafe) var result: T?
        let sema = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            result = await body(store)
            sema.signal()
        }
        if sema.wait(timeout: .now() + 2.0) == .success {
            return result
        }
        return nil
    }







    private func conversationRefAsDict(_ ref: ConversationRef) -> [String: Any] {
        return [
            "kind": ref.kind,
            "id": ref.id,
            "placeholder": ref.placeholder,
            "cwd": v2OrNull(ref.cwd),
            "captured_at": ref.capturedAt.timeIntervalSince1970,
            "captured_via": ref.capturedVia.rawValue,
            "state": ref.state.rawValue,
            "diagnostic_reason": v2OrNull(ref.diagnosticReason)
        ]
    }

    // MARK: - V2 Notification Methods









    // MARK: - V2 App Focus Methods



    // MARK: - V2 Browser Methods

    private func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    private func v2JSONLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    private func v2NormalizeJSValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is V2BrowserUndefinedSentinel {
            return [
                Self.v2BrowserEvalEnvelopeTypeKey: Self.v2BrowserEvalEnvelopeTypeUndefined,
                Self.v2BrowserEvalEnvelopeValueKey: NSNull()
            ]
        }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = v2NormalizeJSValue(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { v2NormalizeJSValue($0) }
        }
        return String(describing: value)
    }

    private enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    private func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        contentWorld: WKContentWorld
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            if preferAsync, #available(macOS 11.0, *) {
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                    switch result {
                    case .success(let value):
                        finish(value, nil)
                    case .failure(let error):
                        finish(nil, error.localizedDescription)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        finish(nil, error.localizedDescription)
                    } else {
                        finish(value, nil)
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    private func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        if Thread.isMainThread {
            let runLoop = CFRunLoopGetCurrent()
            var resolved = false
            var timedOut = false
            var result: T?

            let finish: (T) -> Void = { value in
                guard !resolved else { return }
                resolved = true
                result = value
                CFRunLoopStop(runLoop)
            }

            start(finish)
            guard !resolved else { return result }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !resolved else { return }
                resolved = true
                timedOut = true
                CFRunLoopStop(runLoop)
            }

            CFRunLoopRun()
            return timedOut ? nil : result
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T?
        start { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> Bool {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true
        case .failure:
            return false
        }
    }

    private func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    private func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    private func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(v2BrowserNextElementOrdinal)"
        v2BrowserNextElementOrdinal += 1
        v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(surfaceId: surfaceId, selector: selector)
        return ref
    }

    private func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = v2BrowserElementRefs[refKey], entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }

    private func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2BrowserFrameSelectorBySurface[surfaceId]
    }

    private func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> V2JavaScriptResult {
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """

        var rawResult: V2JavaScriptResult
        if #available(macOS 11.0, *) {
            rawResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .page
            )
        } else {
            let evaluateFallback = """
            (async () => {
              \(asyncFunctionBody)
            })()
            """
            rawResult = v2RunJavaScript(webView, script: evaluateFallback, timeout: timeout, contentWorld: .page)
        }

        if !useEval, case .failure(let pageMessage) = rawResult, #available(macOS 11.0, *) {
            let isolatedResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .defaultClient
            )
            switch isolatedResult {
            case .success:
                rawResult = isolatedResult
            case .failure(let isolatedMessage):
                if isolatedMessage != pageMessage {
                    rawResult = .failure("\(pageMessage) (isolated-world retry: \(isolatedMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .success(value)
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .success(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .success(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .success(value)
            }
        }
    }

    private func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    private func v2BrowserPendingDialogs(surfaceId: UUID) -> [[String: Any]] {
        let queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        return queue.enumerated().map { index, d in
            [
                "index": index,
                "type": d.type,
                "message": d.message,
                "default_text": v2OrNull(d.defaultText)
            ]
        }
    }

    func enqueueBrowserDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        queue.append(V2BrowserPendingDialog(type: type, message: message, defaultText: defaultText, responder: responder))
        if queue.count > 16 {
            // Keep bounded memory while preserving FIFO semantics for newest entries.
            queue.removeFirst(queue.count - 16)
        }
        v2BrowserDialogQueueBySurface[surfaceId] = queue
    }

    private func v2BrowserPopDialog(surfaceId: UUID) -> V2BrowserPendingDialog? {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        guard !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        v2BrowserDialogQueueBySurface[surfaceId] = queue
        return first
    }

    private func v2BrowserEnsureInitScriptsApplied(surfaceId: UUID, browserPanel: BrowserPanel) {
        let scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
        let styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
        guard !scripts.isEmpty || !styles.isEmpty else { return }

        let injector = """
        (() => {
          window.__cmuxInitScriptsApplied = window.__cmuxInitScriptsApplied || { scripts: [], styles: [] };
          return true;
        })()
        """
        _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: injector)

        for script in scripts {
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script)
        }
        for css in styles {
            let cssLiteral = v2JSONLiteral(css)
            let styleScript = """
            (() => {
              const id = 'cmux-init-style-' + btoa(unescape(encodeURIComponent(\(cssLiteral)))).replace(/=+$/g, '');
              if (document.getElementById(id)) return true;
              const el = document.createElement('style');
              el.id = id;
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: styleScript)
        }
    }

    private func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown


    // MARK: - M3 — structured sidebar.state


    /// Build the agent_chip payload for inclusion in `sidebar.state` (v2) and `sidebar_state` (v1 text).
    private func resolveAgentChipDict(workspace ws: Workspace) -> [String: Any] {
        guard let focusedId = ws.focusedPanelId else {
            return ["present": false]
        }
        let (values, sources) = Self.canonicalMetadataSnapshot(workspaceId: ws.id, surfaceId: focusedId)
        guard let chip = AgentChipResolver.resolve(
            focusedSurfaceId: focusedId,
            metadata: values,
            sources: sources
        ) else {
            return ["present": false]
        }

        var out: [String: Any] = [
            "present": true,
            "terminal_type": chip.terminalType,
            "icon_asset": chip.iconAsset,
            "source_surface_id": chip.sourceSurfaceId.uuidString,
            "source_surface_ref": v2Ref(kind: .surface, uuid: chip.sourceSurfaceId)
        ]
        if let model = chip.model { out["model"] = model }
        if let modelLabel = chip.modelLabel { out["model_label"] = modelLabel }
        if let displayLabel = chip.displayLabel { out["display_label"] = displayLabel }
        if let source = chip.source { out["source"] = source }
        var perKey: [String: Any] = [:]
        if let tts = chip.terminalTypeSource { perKey["terminal_type"] = tts }
        if let ms = chip.modelSource { perKey["model"] = ms }
        out["per_key_sources"] = perKey
        return out
    }

    // MARK: - M3/M6 helpers

    /// Pair (metadata, per-key source enum) for consumers that only read the
    /// canonical subset. Parses the JSON-shaped sidecar returned by
    /// SurfaceMetadataStore into typed `MetadataSource` values.
    static func canonicalMetadataSnapshot(
        workspaceId: UUID,
        surfaceId: UUID
    ) -> (values: [String: Any], sources: [String: MetadataSource]) {
        let (values, rawSources) = SurfaceMetadataStore.shared.getMetadata(
            workspaceId: workspaceId, surfaceId: surfaceId
        )
        var sources: [String: MetadataSource] = [:]
        for (key, entry) in rawSources {
            if let name = entry["source"] as? String,
               let src = MetadataSource(rawValue: name) {
                sources[key] = src
            }
        }
        return (values, sources)
    }

    /// Resolve `(Workspace, surfaceId)` for markdown/sidebar code paths.
    private func v2ResolveWorkspaceSurface(params: [String: Any]) -> (Workspace, UUID)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        var out: (Workspace, UUID)?
        v2MainSync {
            if let surfaceId = v2UUID(params, "surface_id") {
                for ws in tabManager.tabs where ws.panels[surfaceId] != nil {
                    out = (ws, surfaceId)
                    return
                }
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let surfaceId = ws.focusedPanelId else { return }
            out = (ws, surfaceId)
        }
        return out
    }

    // MARK: - M6 — markdown.get_content


    // MARK: - Browser

    private func v2BrowserOpenSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let respectExternalOpenRules = v2Bool(params, "respect_external_open_rules") ?? false

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let url,
               respectExternalOpenRules,
               BrowserLinkOpenSettings.shouldOpenExternally(url) {
                guard NSWorkspace.shared.open(url) else {
                    result = .err(
                        code: "external_open_failed",
                        message: "Failed to open URL externally",
                        data: ["url": url.absoluteString]
                    )
                    return
                }
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(nil),
                    "pane_ref": v2Ref(kind: .pane, uuid: nil),
                    "surface_id": v2OrNull(nil),
                    "surface_ref": v2Ref(kind: .surface, uuid: nil),
                    "created_split": false,
                    "placement_strategy": "external",
                    "opened_externally": true,
                    "url": url.absoluteString
                ])
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            var createdSplit = true
            var placementStrategy = "split_right"
            let createdPanel: BrowserPanel?
            if let targetPane = ws.preferredBrowserTargetPane(fromPanelId: sourceSurfaceId) {
                createdPanel = ws.newBrowserSurface(inPane: targetPane, url: url, focus: true)
                createdSplit = false
                placementStrategy = "reuse_right_sibling"
            } else {
                createdPanel = ws.newBrowserSplit(from: sourceSurfaceId, orientation: .horizontal, url: url)
            }

            guard let browserPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create browser", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: browserPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": browserPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: browserPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "created_split": createdSplit,
                "placement_strategy": placementStrategy
            ])
        }
        return result
    }

    private func v2BrowserNavigate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let url = v2String(params, "url") else {
            return .err(code: "invalid_params", message: "Missing url", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            browserPanel.navigateSmart(url)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    private func v2BrowserBack(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "back")
    }

    private func v2BrowserForward(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "forward")
    }

    private func v2BrowserReload(params: [String: Any]) -> V2CallResult {
        return v2BrowserNavSimple(params: params, action: "reload")
    }

    private func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let selectorLiteral = v2JSONLiteral(selector)
        let script = """
        (() => {
          const __selector = \(selectorLiteral);
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = v2NormalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    private func v2BrowserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        browserPanel: BrowserPanel
    ) -> V2CallResult {
        var data = v2BrowserNotFoundDiagnostics(surfaceId: surfaceId, browserPanel: browserPanel, selector: selector)
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message: String
        if count > 0 && visibleCount == 0 {
            message = "Element \"\(selector)\" is present but not visible."
        } else if count > 1 {
            message = "Selector \"\(selector)\" matched multiple elements."
        } else {
            message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }

        return .err(code: "not_found", message: message, data: data)
    }

    private func v2BrowserAppendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any]
    ) {
        guard v2Bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": v2Bool(params, "snapshot_interactive") ?? true,
            "cursor": v2Bool(params, "snapshot_cursor") ?? false,
            "compact": v2Bool(params, "snapshot_compact") ?? true,
            "max_depth": max(0, v2Int(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = v2String(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = v2OrNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    private func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(v2JSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, useEval: false) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ws.id.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard v2WaitForBrowserCondition(
                            browserPanel.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return v2BrowserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                browserPanel: browserPanel
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return v2BrowserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return v2BrowserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                browserPanel: browserPanel
            )
        }
    }

    private func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    private func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12)
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let interactiveLiteral = interactiveOnly ? "true" : "false"
            let cursorLiteral = includeCursor ? "true" : "false"
            let compactLiteral = compact ? "true" : "false"
            let scopeLiteral = scopeSelector.map(v2JSONLiteral) ?? "null"

            let script = """
            (() => {
              const __interactiveOnly = \(interactiveLiteral);
              const __includeCursor = \(cursorLiteral);
              const __compact = \(compactLiteral);
              const __maxDepth = \(maxDepth);
              const __scopeSelector = \(scopeLiteral);

              const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
              const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
              const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
              const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

              const __isVisible = (el) => {
                try {
                  if (!el) return false;
                  const style = getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  if (!style || !rect) return false;
                  if (rect.width <= 0 || rect.height <= 0) return false;
                  if (style.display === 'none' || style.visibility === 'hidden') return false;
                  if (parseFloat(style.opacity || '1') <= 0.01) return false;
                  return true;
                } catch (_) {
                  return false;
                }
              };

              const __implicitRole = (el) => {
                const tag = String(el.tagName || '').toLowerCase();
                if (tag === 'button') return 'button';
                if (tag === 'a' && el.hasAttribute('href')) return 'link';
                if (tag === 'input') {
                  const type = String(el.getAttribute('type') || 'text').toLowerCase();
                  if (type === 'checkbox') return 'checkbox';
                  if (type === 'radio') return 'radio';
                  if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
                  return 'textbox';
                }
                if (tag === 'textarea') return 'textbox';
                if (tag === 'select') return 'combobox';
                if (tag === 'summary') return 'button';
                if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
                if (tag === 'li') return 'listitem';
                return null;
              };

              const __nameFor = (el) => {
                const aria = __normalize(el.getAttribute('aria-label') || '');
                if (aria) return aria;
                const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
                if (labelledBy) {
                  const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
                  if (text) return text;
                }
                if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
                  const placeholder = __normalize(el.getAttribute('placeholder') || '');
                  if (placeholder) return placeholder;
                  const value = __normalize(el.value || '');
                  if (value) return value;
                }
                const title = __normalize(el.getAttribute('title') || '');
                if (title) return title;
                const text = __normalize(el.innerText || el.textContent || '');
                if (text) return text.slice(0, 120);
                return '';
              };

              const __cssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  const parent = cur.parentElement;
                  if (parent) {
                    const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                    if (siblings.length > 1) {
                      const index = siblings.indexOf(cur) + 1;
                      part += `:nth-of-type(${index})`;
                    }
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                  if (parts.length >= 6) break;
                }
                return parts.join(' > ');
              };

              const __root = (() => {
                if (__scopeSelector) {
                  return document.querySelector(__scopeSelector) || document.body || document.documentElement;
                }
                return document.body || document.documentElement;
              })();

              const __entries = [];
              const __seen = new Set();
              const __appendEntry = (el, depth, forcedRole) => {
                if (!__isVisible(el)) return;
                const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
                const role = forcedRole || explicitRole || __implicitRole(el) || '';
                if (!role) return;

                if (__interactiveOnly && !__interactiveRoles.has(role)) return;
                if (!__interactiveOnly) {
                  const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
                  if (!includeRole) return;
                  if (__compact && __structuralRoles.has(role)) {
                    const name = __nameFor(el);
                    if (!name) return;
                  }
                }

                const selector = __cssPath(el);
                if (!selector || __seen.has(selector)) return;
                __seen.add(selector);
                __entries.push({
                  selector,
                  role,
                  name: __nameFor(el),
                  depth
                });
              };

              const __walk = (node, depth) => {
                if (!node || depth > __maxDepth || node.nodeType !== 1) return;
                const el = node;
                __appendEntry(el, depth, null);
                for (const child of Array.from(el.children || [])) {
                  __walk(child, depth + 1);
                }
              };

              if (__root) {
                __walk(__root, 0);
              }

              if (__includeCursor && __root) {
                const all = Array.from(__root.querySelectorAll('*'));
                for (const el of all) {
                  if (!__isVisible(el)) continue;
                  const style = getComputedStyle(el);
                  const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
                  const hasCursorPointer = style.cursor === 'pointer';
                  const tabIndex = el.getAttribute('tabindex');
                  const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
                  if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
                  __appendEntry(el, 0, 'generic');
                  if (__entries.length >= 256) break;
                }
              }

              const body = document.body;
              const root = document.documentElement;
              return {
                title: __normalize(document.title || ''),
                url: String(location.href || ''),
                ready_state: String(document.readyState || ''),
                text: body ? String(body.innerText || '') : '',
                html: root ? String(root.outerHTML || '') : '',
                entries: __entries
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0, useEval: false) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let refToken = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                return .ok(payload)
            }
        }
    }

    private func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = v2BrowserSelector(params)

        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                let literal = v2JSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = v2String(params, "text_contains") {
                let literal = v2JSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = v2JSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = v2String(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        var setupResult: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var webView: WKWebView?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupResult = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupResult = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                setupResult = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                setupResult = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            workspaceId = ws.id
            surfaceIdOut = surfaceId
            webView = browserPanel.webView
        }

        if let setupResult {
            return setupResult
        }
        guard let workspaceId, let surfaceIdOut, let webView else {
            return .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let literal = v2JSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        if v2WaitForBrowserCondition(
            webView,
            surfaceId: surfaceIdOut,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "waited": true
            ])
        }
        return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
    }

    private func v2BrowserClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "click") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              if (typeof el.click === 'function') {
                el.click();
              } else {
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
              }
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserDblClick(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "dblclick") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window, detail: 2 }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserHover(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "hover") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
              el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
              el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserFocusElement(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "focus") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserType(params: [String: Any]) -> V2CallResult {
        guard let text = v2String(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "type") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const chunk = String(\(textLiteral));
              if ('value' in el) {
                el.value = (el.value || '') + chunk;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = (el.textContent || '') + chunk;
              }
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserFill(params: [String: Any]) -> V2CallResult {
        // `fill` must allow empty strings so callers can clear existing input values.
        guard let text = v2RawString(params, "text") ?? v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing text/value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "fill") { selectorLiteral in
            let textLiteral = v2JSONLiteral(text)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (typeof el.focus === 'function') el.focus();
              const value = String(\(textLiteral));
              if ('value' in el) {
                el.value = value;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              } else {
                el.textContent = value;
              }
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserPress(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keypress', { key: k, bubbles: true, cancelable: true }));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserKeyDown(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserKeyUp(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let keyLiteral = v2JSONLiteral(key)
            let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserCheck(params: [String: Any], checked: Bool) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: checked ? "check" : "uncheck") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
              el.checked = \(checked ? "true" : "false");
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserSelect(params: [String: Any]) -> V2CallResult {
        let selectedValue = v2String(params, "value") ?? v2String(params, "text")
        guard let selectedValue else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "select") { selectorLiteral in
            let valueLiteral = v2JSONLiteral(selectedValue)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              if (!('value' in el)) return { ok: false, error: 'not_select' };
              el.value = String(\(valueLiteral));
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserScroll(params: [String: Any]) -> V2CallResult {
        let dx = v2Int(params, "dx") ?? 0
        let dy = v2Int(params, "dy") ?? 0
        let selectorRaw = v2BrowserSelector(params)

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let selector = selectorRaw.flatMap { v2BrowserResolveSelector($0, surfaceId: surfaceId) }
            if selectorRaw != nil && selector == nil {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw ?? ""])
            }

            let script: String
            if let selector {
                let selectorLiteral = v2JSONLiteral(selector)
                script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.scrollBy === 'function') {
                    el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
                  } else {
                    el.scrollLeft += \(dx);
                    el.scrollTop += \(dy);
                  }
                  return { ok: true };
                })()
                """
            } else {
                script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
            }

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return v2BrowserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                return .ok(payload)
            }
        }
    }

    private func v2BrowserScrollIntoView(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "scroll_into_view") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserScreenshot(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let snapshotResult: Data?? = v2AwaitCallback(timeout: 5.0) { finish in
                browserPanel.takeSnapshot { image in
                    finish(image.flatMap { self.v2PNGData(from: $0) })
                }
            }

            guard let snapshotResult else {
                return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
            }
            guard let imageData = snapshotResult else {
                return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
            }

            var result: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "png_base64": imageData.base64EncodedString()
            ]

            // Best effort: keep screenshot data available even when temp-file writes fail.
            let screenshotsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
                bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
                let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
                let shortRandomId = String(UUID().uuidString.prefix(8))
                let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
                let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
                if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                    result["path"] = imageURL.path
                    result["url"] = imageURL.absoluteString
                }
            }

            return .ok(result)
        }
    }

    private func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    private func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    private func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    private func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = v2JSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    private func v2BrowserGetTitle(params: [String: Any]) -> V2CallResult {
        v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "title": browserPanel.pageTitle
            ])
        }
    }

    private func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    private func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    private func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = v2JSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

    private func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    private func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    private func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }


    private func v2BrowserNavSimple(params: [String: Any], action: String) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            switch action {
            case "back":
                browserPanel.goBack()
            case "forward":
                browserPanel.goForward()
            case "reload":
                browserPanel.reload()
            default:
                break
            }
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))
            ]
            v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
            result = .ok(payload)
        }
        return result
    }

    private func v2BrowserGetURL(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "url": browserPanel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    private func v2BrowserFocusWebView(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found or not a browser", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.0)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = .err(code: "invalid_state", message: "WebView is not in a window", data: nil)
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = .err(code: "invalid_state", message: "WebView is hidden", data: nil)
                return
            }

            window.makeFirstResponder(webView)
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                result = .ok(["focused": true])
            } else {
                result = .err(code: "internal_error", message: "Focus did not move into web view", data: nil)
            }
        }
        return result
    }

    private func v2BrowserIsWebViewFocused(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var focused = false
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            let webView = browserPanel.webView
            guard let window = webView.window,
                  let fr = window.firstResponder as? NSView else {
                focused = false
                return
            }
            focused = fr.isDescendant(of: webView)
        }
        return .ok(["focused": focused])
    }

    private func v2BrowserFindWithScript(
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadata: [String: Any] = [:]
    ) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let script = """
            (() => {
              const __cmuxCssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  let siblings = cur.parentElement ? Array.from(cur.parentElement.children).filter((n) => String(n.tagName || '').toLowerCase() === tag) : [];
                  if (siblings.length > 1) {
                    const pos = siblings.indexOf(cur) + 1;
                    part += `:nth-of-type(${pos})`;
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                }
                return parts.join(' > ');
              };

              const __cmuxFound = (() => {
            \(finderBody)
              })();
              if (!__cmuxFound) return { ok: false, error: 'not_found' };
              const selector = __cmuxCssPath(__cmuxFound);
              if (!selector) return { ok: false, error: 'not_found' };
              return {
                ok: true,
                selector,
                tag: String(__cmuxFound.tagName || '').toLowerCase(),
                text: String(__cmuxFound.textContent || '').trim()
              };
            })()
            """

            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: ["action": actionName])
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: metadata)
                }

                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                var payload: [String: Any] = [
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "action": actionName,
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref
                ]
                for (k, v) in metadata {
                    payload[k] = v
                }
                if let tag = dict["tag"] as? String {
                    payload["tag"] = tag
                }
                if let text = dict["text"] as? String {
                    payload["text"] = text
                }
                return .ok(payload)
            }
        }
    }

    private func v2BrowserFindRole(params: [String: Any]) -> V2CallResult {
        guard let role = (v2String(params, "role") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing role", data: nil)
        }
        let name = v2String(params, "name")?.lowercased()
        let exact = v2Bool(params, "exact") ?? false
        let roleLiteral = v2JSONLiteral(role)
        let nameLiteral = name.map(v2JSONLiteral) ?? "null"
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __targetRole = String(\(roleLiteral)).toLowerCase();
                const __targetName = \(nameLiteral);
                const __exact = \(exactLiteral);
                const __implicitRole = (el) => {
                  const tag = String(el.tagName || '').toLowerCase();
                  if (tag === 'button') return 'button';
                  if (tag === 'a' && el.hasAttribute('href')) return 'link';
                  if (tag === 'input') {
                    const type = String(el.getAttribute('type') || 'text').toLowerCase();
                    if (type === 'checkbox') return 'checkbox';
                    if (type === 'radio') return 'radio';
                    if (type === 'submit' || type === 'button') return 'button';
                    return 'textbox';
                  }
                  if (tag === 'textarea') return 'textbox';
                  if (tag === 'select') return 'combobox';
                  return null;
                };
                const __nameFor = (el) => {
                  const aria = String(el.getAttribute('aria-label') || '').trim();
                  if (aria) return aria.toLowerCase();
                  const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                  if (labelledBy) {
                    const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                    if (text) return text.toLowerCase();
                  }
                  const txt = String(el.innerText || el.textContent || '').trim();
                  if (txt) return txt.toLowerCase();
                  if ('value' in el) {
                    const v = String(el.value || '').trim();
                    if (v) return v.toLowerCase();
                  }
                  return '';
                };
                const __nodes = Array.from(document.querySelectorAll('*'));
                return __nodes.find((el) => {
                  const explicit = String(el.getAttribute('role') || '').toLowerCase();
                  const resolved = explicit || __implicitRole(el) || '';
                  if (resolved !== __targetRole) return false;
                  if (__targetName == null) return true;
                  const currentName = __nameFor(el);
                  return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.role",
            finderBody: finder,
            metadata: [
                "role": role,
                "name": v2OrNull(name),
                "exact": exact
            ]
        )
    }

    private func v2BrowserFindText(params: [String: Any]) -> V2CallResult {
        guard let text = (v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let textLiteral = v2JSONLiteral(text)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(textLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __nodes = Array.from(document.querySelectorAll('body *'));
                return __nodes.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  if (!v) return false;
                  return __exact ? (v === __target) : v.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.text",
            finderBody: finder,
            metadata: ["text": text, "exact": exact]
        )
    }

    private func v2BrowserFindLabel(params: [String: Any]) -> V2CallResult {
        guard let label = (v2String(params, "label") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing label", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let labelLiteral = v2JSONLiteral(label)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(labelLiteral));
                const __exact = \(exactLiteral);
                const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                const __labels = Array.from(document.querySelectorAll('label'));
                const __label = __labels.find((el) => {
                  const v = __norm(el.innerText || el.textContent || '');
                  return __exact ? (v === __target) : v.includes(__target);
                });
                if (!__label) return null;
                const htmlFor = String(__label.getAttribute('for') || '').trim();
                if (htmlFor) {
                  return document.getElementById(htmlFor);
                }
                return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.label",
            finderBody: finder,
            metadata: ["label": label, "exact": exact]
        )
    }

    private func v2BrowserFindPlaceholder(params: [String: Any]) -> V2CallResult {
        guard let placeholder = (v2String(params, "placeholder") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing placeholder", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let placeholderLiteral = v2JSONLiteral(placeholder)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(placeholderLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[placeholder]'));
                return __nodes.find((el) => {
                  const p = String(el.getAttribute('placeholder') || '').trim().toLowerCase();
                  if (!p) return false;
                  return __exact ? (p === __target) : p.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.placeholder",
            finderBody: finder,
            metadata: ["placeholder": placeholder, "exact": exact]
        )
    }

    private func v2BrowserFindAlt(params: [String: Any]) -> V2CallResult {
        guard let alt = (v2String(params, "alt") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing alt text", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let altLiteral = v2JSONLiteral(alt)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(altLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[alt]'));
                return __nodes.find((el) => {
                  const a = String(el.getAttribute('alt') || '').trim().toLowerCase();
                  if (!a) return false;
                  return __exact ? (a === __target) : a.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.alt",
            finderBody: finder,
            metadata: ["alt": alt, "exact": exact]
        )
    }

    private func v2BrowserFindTitle(params: [String: Any]) -> V2CallResult {
        guard let title = (v2String(params, "title") ?? v2String(params, "text") ?? v2String(params, "value"))?.lowercased() else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        let exact = v2Bool(params, "exact") ?? false
        let titleLiteral = v2JSONLiteral(title)
        let exactLiteral = exact ? "true" : "false"

        let finder = """
                const __target = String(\(titleLiteral));
                const __exact = \(exactLiteral);
                const __nodes = Array.from(document.querySelectorAll('[title]'));
                return __nodes.find((el) => {
                  const t = String(el.getAttribute('title') || '').trim().toLowerCase();
                  if (!t) return false;
                  return __exact ? (t === __target) : t.includes(__target);
                }) || null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.title",
            finderBody: finder,
            metadata: ["title": title, "exact": exact]
        )
    }

    private func v2BrowserFindTestId(params: [String: Any]) -> V2CallResult {
        guard let testId = v2String(params, "testid") ?? v2String(params, "test_id") ?? v2String(params, "value") else {
            return .err(code: "invalid_params", message: "Missing testid", data: nil)
        }
        let testIdLiteral = v2JSONLiteral(testId)

        let finder = """
                const __target = String(\(testIdLiteral));
                const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                for (const sel of __selectors) {
                  const nodes = Array.from(document.querySelectorAll(sel));
                  const found = nodes.find((el) => {
                    return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                  });
                  if (found) return found;
                }
                return null;
        """

        return v2BrowserFindWithScript(
            params: params,
            actionName: "find.testid",
            finderBody: finder,
            metadata: ["testid": testId]
        )
    }

    private func v2BrowserFindFirst(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": selector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    private func v2BrowserFindLast(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = document.querySelectorAll(\(selectorLiteral));
              if (!list || list.length === 0) return { ok: false, error: 'not_found' };
              const idx = list.length - 1;
              const el = list[idx];
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
              return { ok: true, selector: finalSelector, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    private func v2BrowserFindNth(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        guard let index = v2Int(params, "index") ?? v2Int(params, "nth") else {
            return .err(code: "invalid_params", message: "Missing index", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              const nth = idx + 1;
              const finalSelector = `${\(selectorLiteral)}:nth-of-type(${nth})`;
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector, "index": index])
                }
                let ref = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: finalSelector)
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "selector": finalSelector,
                    "element_ref": ref,
                    "ref": ref,
                    "index": v2OrNull(dict["index"]),
                    "text": v2OrNull(dict["text"])
                ])
            }
        }
    }

    private func v2BrowserFrameSelect(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2BrowserFrameSelectorBySurface[surfaceId] = selector
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "frame_selector": selector
                    ])
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .err(code: "not_supported", message: "Cross-origin iframe control is not supported", data: ["selector": selector])
                }
                return .err(code: "not_found", message: "Frame not found", data: ["selector": selector])
            }
        }
    }

    private func v2BrowserFrameMain(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "frame_selector": NSNull()
            ])
        }
    }

    private func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    private func v2BrowserEnsureDialogHooks(browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.dialogTelemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    private func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            v2BrowserEnsureDialogHooks(browserPanel: browserPanel)
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__cmuxDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__cmuxDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__cmuxDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: surfaceId)
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": pending])
                }

                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ])
            }
        }
    }

    private func v2BrowserDownloadWait(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 10_000)
            let timeout = Double(timeoutMs) / 1000.0
            let path = v2String(params, "path")

            if let path {
                let fm = FileManager.default
                let pathIsReady = {
                    guard fm.fileExists(atPath: path),
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let size = attrs[.size] as? NSNumber else {
                        return false
                    }
                    return size.intValue > 0
                }
                if pathIsReady() {
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "path": path,
                        "downloaded": true
                    ])
                }

                let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
                let fd = open(watchedPath, O_EVTONLY)
                guard fd >= 0 else {
                    return .err(code: "internal_error", message: "Failed to watch download path", data: ["path": path])
                }
                defer { close(fd) }

                let ready = v2AwaitCallback(timeout: timeout) { finish in
                    var source: DispatchSourceFileSystemObject?
                    var timeoutWorkItem: DispatchWorkItem?
                    var finished = false
                    let finishOnce: (Bool) -> Void = { value in
                        guard !finished else { return }
                        finished = true
                        timeoutWorkItem?.cancel()
                        source?.cancel()
                        finish(value)
                    }
                    source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: [.write, .extend, .attrib, .link, .rename],
                        queue: .main
                    )
                    source?.setEventHandler {
                        if pathIsReady() {
                            finishOnce(true)
                        }
                    }
                    source?.setCancelHandler {
                        source = nil
                    }
                    source?.resume()
                    timeoutWorkItem = DispatchWorkItem {
                        finishOnce(pathIsReady())
                    }
                    if let timeoutWorkItem {
                        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
                    }
                    if pathIsReady() {
                        finishOnce(true)
                    }
                } ?? false
                guard ready else {
                    return .err(code: "timeout", message: "Timed out waiting for download file", data: ["path": path, "timeout_ms": timeoutMs])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "path": path,
                    "downloaded": true
                ])
            }

            if let first = v2BrowserDownloadEventsBySurface[surfaceId]?.first {
                var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                remaining.removeFirst()
                v2BrowserDownloadEventsBySurface[surfaceId] = remaining
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "download": first
                ])
            }

            let downloadEvent = v2AwaitCallback(timeout: timeout) { finish in
                var observer: NSObjectProtocol?
                observer = NotificationCenter.default.addObserver(
                    forName: .browserDownloadEventDidArrive,
                    object: nil,
                    queue: .main
                ) { note in
                    guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                          candidateSurfaceId == surfaceId,
                          let event = note.userInfo?["event"] as? [String: Any] else {
                        return
                    }
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    finish(event)
                }
            }
            guard let downloadEvent else {
                return .err(code: "timeout", message: "No download event observed", data: ["timeout_ms": timeoutMs])
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "download": downloadEvent
            ])
        }
    }

    private func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    private func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            store.getAllCookies { items in
                finish(items)
            }
        }
    }

    private func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.setCookie(cookie) {
                finish(true)
            }
        } ?? false
    }

    private func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.delete(cookie) {
                finish(true)
            }
        } ?? false
    }

    private func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    private func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cookies": cookies.map(v2BrowserCookieDict)
            ])
        }
    }

    private func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = browserPanel.currentURL

            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty {
                    cookieObjects = [single]
                }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "set": setCount
            ])
        }
    }

    private func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let clearAll = params["all"] == nil && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cleared": removed
            ])
        }
    }

    private func v2BrowserStorageType(_ params: [String: Any]) -> String {
        let type = (v2String(params, "storage") ?? v2String(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    private func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = key.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ])
            }
        }
    }

    private func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = v2JSONLiteral(key)
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value))
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": key
                ])
            }
        }
    }

    private func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "cleared": true
                ])
            }
        }
    }

    private func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
                [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "title": panel.displayTitle,
                    "url": panel.currentURL?.absoluteString ?? "",
                    "focused": panel.id == ws.focusedPanelId,
                    "pane_id": v2OrNull(ws.paneId(forPanelId: panel.id)?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: ws.paneId(forPanelId: panel.id)?.id)
                ]
            }
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": v2OrNull(ws.focusedPanelId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "tabs": tabs
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let url = v2String(params, "url").flatMap(URL.init(string:))
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let paneUUID = v2UUID(params, "pane_id")
                ?? v2UUID(params, "target_pane_id")
                ?? (v2UUID(params, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found", data: nil)
                return
            }

            guard let panel = ws.newBrowserSurface(inPane: pane, url: url, focus: true) else {
                result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                return
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": pane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: pane.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "url": panel.currentURL?.absoluteString ?? ""
            ])
        }
        return result
    }

    private func v2BrowserTabSwitch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return v2UUID(params, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            ws.focusPanel(targetId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": targetId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: targetId)
            ])
        }
        return result
    }

    private func v2BrowserTabClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                result = .err(code: "not_found", message: "No browser tabs", data: nil)
                return
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(params, "target_surface_id") ?? v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = v2UUID(params, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            let ok = ws.closePanel(targetId, force: true)
            result = ok
                ? .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": targetId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: targetId)
                ])
                : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
        }
        return result
    }

    private func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : [];
              if (\(clearLiteral)) {
                window.__cmuxConsoleLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    private func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    private func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [];
              if (\(clearLiteral)) {
                window.__cmuxErrorLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, contentWorld: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    private func v2BrowserHighlight(params: [String: Any]) -> V2CallResult {
        return v2BrowserSelectorAction(params: params, actionName: "highlight") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const prev = el.style.outline;
              const prevOffset = el.style.outlineOffset;
              el.style.outline = '3px solid #ff9f0a';
              el.style.outlineOffset = '2px';
              setTimeout(() => {
                el.style.outline = prev;
                el.style.outlineOffset = prevOffset;
              }, 1200);
              return { ok: true };
            })()
            """
        }
    }

    private func v2BrowserStateSave(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let storageScript = """
            (() => {
              const readStorage = (st) => {
                const out = {};
                if (!st) return out;
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return out;
              };
              return {
                local: readStorage(window.localStorage),
                session: readStorage(window.sessionStorage)
              };
            })()
            """

            let storageValue: Any
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (v2BrowserCookieStoreAll(store) ?? []).map(v2BrowserCookieDict)

            let state: [String: Any] = [
                "url": browserPanel.currentURL?.absoluteString ?? "",
                "cookies": cookies,
                "storage": storageValue,
                "frame_selector": v2OrNull(v2BrowserFrameSelectorBySurface[surfaceId])
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .err(code: "internal_error", message: "Failed to write state file", data: ["path": path, "error": error.localizedDescription])
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "cookies": cookies.count
            ])
        }
    }

    private func v2BrowserStateLoad(params: [String: Any]) -> V2CallResult {
        guard let path = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }

        let url = URL(fileURLWithPath: path)
        let raw: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .err(code: "invalid_params", message: "State file must contain a JSON object", data: ["path": path])
            }
            raw = obj
        } catch {
            return .err(code: "not_found", message: "Failed to read state file", data: ["path": path, "error": error.localizedDescription])
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            if let frameSelector = raw["frame_selector"] as? String, !frameSelector.isEmpty {
                v2BrowserFrameSelectorBySurface[surfaceId] = frameSelector
            } else {
                v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            }

            if let urlStr = raw["url"] as? String,
               !urlStr.isEmpty,
               let parsed = URL(string: urlStr) {
                browserPanel.navigate(to: parsed)
            }

            if let cookieRows = raw["cookies"] as? [[String: Any]] {
                let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
                for row in cookieRows {
                    if let cookie = v2BrowserCookieFromObject(row, fallbackURL: browserPanel.currentURL) {
                        _ = v2BrowserCookieStoreSet(store, cookie: cookie)
                    }
                }
            }

            if let storage = raw["storage"] as? [String: Any] {
                let storageLiteral = v2JSONLiteral(storage)
                let script = """
                (() => {
                  const payload = \(storageLiteral);
                  const apply = (st, data) => {
                    if (!st || !data || typeof data !== 'object') return;
                    st.clear();
                    for (const [k, v] of Object.entries(data)) {
                      st.setItem(String(k), v == null ? '' : String(v));
                    }
                  };
                  apply(window.localStorage, payload.local);
                  apply(window.sessionStorage, payload.session);
                  return true;
                })()
                """
                _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "path": path,
                "loaded": true
            ])
        }
    }

    private func v2BrowserAddInitScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
            scripts.append(script)
            v2BrowserInitScriptsBySurface[surfaceId] = scripts

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "scripts": scripts.count
            ])
        }
    }

    private func v2BrowserAddScript(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "value": v2NormalizeJSValue(value)
                ])
            }
        }
    }

    private func v2BrowserAddStyle(params: [String: Any]) -> V2CallResult {
        guard let css = v2String(params, "css") ?? v2String(params, "style") ?? v2String(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            var styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
            styles.append(css)
            v2BrowserInitStylesBySurface[surfaceId] = styles

            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: source, timeout: 10.0)

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "styles": styles.count
            ])
        }
    }

    private func v2BrowserViewportSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.viewport.set", details: "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP")
    }

    private func v2BrowserGeolocationSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.geolocation.set", details: "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP")
    }

    private func v2BrowserOfflineSet(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.offline.set", details: "WKWebView does not expose reliable per-tab offline emulation")
    }

    private func v2BrowserTraceStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.start", details: "Playwright trace artifacts are not available on WKWebView")
    }

    private func v2BrowserTraceStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.stop", details: "Playwright trace artifacts are not available on WKWebView")
    }

    private func v2BrowserNetworkRoute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "route", "params": params])
        }
        return v2BrowserNotSupported("browser.network.route", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    private func v2BrowserNetworkUnroute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "unroute", "params": params])
        }
        return v2BrowserNotSupported("browser.network.unroute", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    private func v2BrowserNetworkRequests(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            let items = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            return .err(code: "not_supported", message: "browser.network.requests is not supported on WKWebView", data: [
                "details": "Request interception logs are unavailable without CDP network hooks",
                "recorded_requests": items
            ])
        }
        return v2BrowserNotSupported("browser.network.requests", details: "Request interception logs are unavailable without CDP network hooks")
    }

    private func v2BrowserScreencastStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.start", details: "WKWebView does not expose CDP screencast streaming")
    }

    private func v2BrowserScreencastStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.stop", details: "WKWebView does not expose CDP screencast streaming")
    }

    private func v2BrowserInputMouse(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_mouse", details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll")
    }

    private func v2BrowserInputKeyboard(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_keyboard", details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup")
    }

    private func v2BrowserInputTouch(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_touch", details: "Raw CDP touch injection is unavailable on WKWebView")
    }


    private struct ReadScreenOptions {
        let surfaceArg: String
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    private struct ReadScreenParseError: Error {
        let message: String
    }

    private func parseReadScreenArgs(_ args: String) -> Result<ReadScreenOptions, ReadScreenParseError> {
        let tokens = args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var surfaceArg: String?
        var includeScrollback = false
        var lineLimit: Int?
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]
            switch token {
            case "--scrollback":
                includeScrollback = true
                idx += 1
            case "--lines":
                guard idx + 1 < tokens.count, let parsed = Int(tokens[idx + 1]), parsed > 0 else {
                    return .failure(ReadScreenParseError(message: "ERROR: --lines must be greater than 0"))
                }
                lineLimit = parsed
                includeScrollback = true
                idx += 2
            default:
                guard surfaceArg == nil else {
                    return .failure(ReadScreenParseError(message: "ERROR: Usage: read_screen [id|idx] [--scrollback] [--lines <n>]"))
                }
                surfaceArg = token
                idx += 1
            }
        }

        return .success(
            ReadScreenOptions(
                surfaceArg: surfaceArg ?? "",
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        )
    }

    private func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func readTerminalTextBase64(surfaceArg: String, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmedSurfaceArg = surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if trimmedSurfaceArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: trimmedSurfaceArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            result = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }
        return result
    }

    private func readScreenText(_ args: String) -> String {
        let options: ReadScreenOptions
        switch parseReadScreenArgs(args) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            return error.message
        }

        let response = readTerminalTextBase64(
            surfaceArg: options.surfaceArg,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        )
        guard response.hasPrefix("OK ") else { return response }

        let payload = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty {
            return ""
        }

        guard let data = Data(base64Encoded: payload) else {
            return "ERROR: Failed to decode terminal text"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func helpText() -> String {
        var text = """
        Hierarchy: Workspace (sidebar tab) > Pane (split region) > Surface (nested tab) > Panel (terminal/browser)

        Available commands:
          ping                        - Check if server is running
          list_workspaces             - List all workspaces with IDs
          new_workspace               - Create a new workspace
          select_workspace <id|index> - Select workspace by ID or index (0-based)
          current_workspace           - Get current workspace ID
          close_workspace <id>        - Close workspace by ID

        Split & surface commands:
          new_split <direction> [panel]   - Split panel (left/right/up/down)
          drag_surface_to_split <id|idx> <direction> - Move surface into a new split (drag-to-edge)
          new_pane [--type=terminal|browser] [--direction=left|right|up|down] [--url=...]
          new_surface [--type=terminal|browser] [--pane=<pane-id|index>] [--url=...]
          list_surfaces [workspace]       - List surfaces for workspace (current if omitted)
          list_panes                      - List all panes with IDs
          list_pane_surfaces [--pane=<pane-id|index>] - List surfaces in pane
          focus_surface <id|idx>          - Focus surface by ID or index
          focus_pane <pane-id|index>      - Focus a pane
          focus_surface_by_panel <panel_id> - Focus surface by panel ID
          close_surface [id|idx]          - Close surface (collapse split)
          reload_config [soft]            - Reload Ghostty config and refresh terminals
          refresh_surfaces                - Force refresh all terminals
          surface_health [workspace]      - Check view health of all surfaces

        Input commands:
          send <text>                     - Send text to current terminal
          send_key <key>                  - Send special key. Vocabulary:
                                            enter/return, tab, escape, space, backspace, delete,
                                            up, down, left, right, home, end, pageup, pagedown,
                                            f1-f12, ctrl-c, ctrl-d, ctrl-z, ctrl-<letter>
          send_surface <id|idx> <text>    - Send text to a specific terminal
          send_key_surface <id|idx> <key> - Send special key to a specific terminal
          read_screen [id|idx] [--scrollback] [--lines N] - Read terminal text (plain text)

        Notification commands:
          notify <title>|<subtitle>|<body>   - Notify focused panel
          notify_surface <id|idx> <payload>  - Notify a specific surface
          notify_target <workspace_id> <surface_id> <payload> - Notify by workspace+surface
          list_notifications              - List all notifications
          clear_notifications [--tab=X]    - Clear notifications (all or per-tab)
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active             - Trigger app active handler
          set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set a status entry
          report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set sidebar metadata entry
          report_meta_block <key> [--priority=N] [--tab=X] -- <markdown> - Set freeform sidebar markdown block
          clear_status <key> [--tab=X] - Remove a status entry
          clear_meta <key> [--tab=X] - Remove sidebar metadata entry
          clear_meta_block <key> [--tab=X] - Remove sidebar markdown block
          list_status [--tab=X]   - List all status entries
          list_meta [--tab=X]     - List sidebar metadata entries
          list_meta_blocks [--tab=X] - List sidebar markdown blocks
          log [--level=X] [--source=X] [--tab=X] -- <message> - Append a log entry
          clear_log [--tab=X]     - Clear log entries
          list_log [--limit=N] [--tab=X] - List log entries
          set_progress <0.0-1.0> [--label=X] [--tab=X] - Set progress bar
          clear_progress [--tab=X] - Clear progress bar
          report_git_branch <branch> [--status=dirty] [--tab=X] [--panel=Y] - Report git branch
          clear_git_branch [--tab=X] [--panel=Y] - Clear git branch
          report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--checks=pass|fail|pending] [--tab=X] [--panel=Y] - Report pull request / review item
          report_review <number> <url> [--label=MR] [--state=open|merged|closed] [--checks=pass|fail|pending] [--tab=X] [--panel=Y] - Alias for provider-specific review item
          clear_pr [--tab=X] [--panel=Y] - Clear pull request
          report_ports <port1> [port2...] [--tab=X] [--panel=Y] - Report listening ports
          report_tty <tty_name> [--tab=X] [--panel=Y] - Register TTY for batched port scanning
          ports_kick [--tab=X] [--panel=Y] - Request batched port scan for panel
          report_shell_state <prompt|running> [--tab=X] [--panel=Y] - Report whether the shell is idle at a prompt or running a command
          report_pwd <path> [--tab=X] [--panel=Y] - Report current working directory
          clear_ports [--tab=X] [--panel=Y] - Clear listening ports
          sidebar_state [--tab=X] - Dump sidebar metadata
          reset_sidebar [--tab=X] - Clear sidebar metadata

        Browser commands:
          open_browser [url]              - Create browser panel with optional URL
          navigate <panel_id> <url>       - Navigate browser to URL
          browser_back <panel_id>         - Go back in browser history
          browser_forward <panel_id>      - Go forward in browser history
          browser_reload <panel_id>       - Reload browser page
          get_url <panel_id>              - Get current URL of browser panel
          focus_webview <panel_id>        - Move keyboard focus into the WKWebView (for tests)
          is_webview_focused <panel_id>   - Return true/false if WKWebView is first responder

          help                            - Show this help
        """
#if DEBUG
        text += """

          focus_notification <workspace|idx> [surface|idx] - Focus via notification flow
          flash_count <id|idx>            - Read flash count for a panel
          reset_flash_counts              - Reset flash counters
          screenshot [label]              - Capture window screenshot
          set_shortcut <name> <combo|clear> - Set a keyboard shortcut (test-only)
          simulate_shortcut <combo>       - Simulate a keyDown shortcut (test-only)
          simulate_type <text>            - Insert text into the current first responder (test-only)
          simulate_file_drop <id|idx> <path[|path...]> - Simulate dropping file path(s) on terminal (test-only)
          seed_drag_pasteboard_fileurl    - Seed NSDrag pasteboard with public.file-url (test-only)
          seed_drag_pasteboard_tabtransfer - Seed NSDrag pasteboard with tab transfer type (test-only)
          seed_drag_pasteboard_sidebar_reorder - Seed NSDrag pasteboard with sidebar reorder type (test-only)
          seed_drag_pasteboard_types <types> - Seed NSDrag pasteboard with comma/space-separated types (fileurl, tabtransfer, sidebarreorder, or raw UTI)
          clear_drag_pasteboard           - Clear NSDrag pasteboard (test-only)
          drop_hit_test <x 0-1> <y 0-1> - Hit-test file-drop overlay at normalised coords (test-only)
          drag_hit_chain <x 0-1> <y 0-1> - Return hit-view chain at normalised coords (test-only)
          overlay_hit_gate <event|none> - Return true/false if file-drop overlay would capture hit-testing for event type (test-only)
          overlay_drop_gate [external|local] - Return true/false if file-drop overlay would capture drag destination routing (test-only)
          portal_hit_gate <event|none> - Return true/false if terminal portal should pass hit-testing to SwiftUI drag targets (test-only)
          sidebar_overlay_gate [active|inactive] - Return true/false if sidebar outside-drop overlay would capture (test-only)
          terminal_drop_overlay_probe [deferred|direct] - Trigger focused terminal drop-overlay show path and report animation counts (test-only)
          activate_app                    - Bring app + main window to front (test-only)
          send_workspace <workspace_id> <text> - Send text to a workspace's selected terminal (test-only)
          is_terminal_focused <id|idx>    - Return true/false if terminal surface is first responder (test-only)
          read_terminal_text [id|idx]     - Read visible terminal text (base64, test-only)
          render_stats [id|idx]           - Read terminal render stats (draw counters, test-only)
          layout_debug                    - Dump bonsplit layout + selected panel bounds (test-only)
          bonsplit_underflow_count        - Count bonsplit arranged-subview underflow events (test-only)
          reset_bonsplit_underflow_count  - Reset bonsplit underflow counter (test-only)
          empty_panel_count               - Count EmptyPanelView appearances (test-only)
          reset_empty_panel_count         - Reset EmptyPanelView appearance count (test-only)
        """
#endif
        return text
    }

#if DEBUG
    private func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0].lowercased()
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let defaultsKey: String?
        switch name {
        case "focus_left", "focusleft":
            defaultsKey = KeyboardShortcutSettings.focusLeftKey
        case "focus_right", "focusright":
            defaultsKey = KeyboardShortcutSettings.focusRightKey
        case "focus_up", "focusup":
            defaultsKey = KeyboardShortcutSettings.focusUpKey
        case "focus_down", "focusdown":
            defaultsKey = KeyboardShortcutSettings.focusDownKey
        default:
            defaultsKey = nil
        }

        guard let defaultsKey else {
            return "ERROR: Unknown shortcut name. Supported: focus_left, focus_right, focus_up, focus_down"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "default" || combo.lowercased() == "reset" {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return "OK"
        }

        guard let parsed = parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        let shortcut = StoredShortcut(
            key: parsed.storedKey,
            command: parsed.modifierFlags.contains(.command),
            shift: parsed.modifierFlags.contains(.shift),
            option: parsed.modifierFlags.contains(.option),
            control: parsed.modifierFlags.contains(.control)
        )
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return "ERROR: Failed to encode shortcut"
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        return "OK"
    }

    private func prepareWindowForSyntheticInput(_ window: NSWindow?) {
        guard let window else { return }
        // Keep socket-driven input simulation focused on the intended window without
        // paying repeated activation/order-front costs for every synthetic key event.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow || !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func simulateShortcut(_ args: String) -> String {
        let combo = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combo.isEmpty else {
            return "ERROR: Usage: simulate_shortcut <combo>"
        }
        guard let parsed = parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        // Stamp at socket-handler arrival so event.timestamp includes any wait
        // before the main-thread event dispatch.
        let requestTimestamp = ProcessInfo.processInfo.systemUptime

        var result = "ERROR: Failed to create event"
        v2MainSync {
            // Prefer the current active-tab-manager window so shortcut simulation stays
            // scoped to the intended window even when NSApp.keyWindow is stale.
            let targetWindow: NSWindow? = {
                if let activeTabManager = self.tabManager,
                   let windowId = AppDelegate.shared?.windowId(for: activeTabManager),
                   let window = AppDelegate.shared?.mainWindow(for: windowId) {
                    return window
                }
                return NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? NSApp.windows.first(where: { $0.isVisible })
                    ?? NSApp.windows.first
            }()
            prepareWindowForSyntheticInput(targetWindow)
            let windowNumber = targetWindow?.windowNumber ?? 0
            guard let keyDownEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: parsed.modifierFlags,
                timestamp: requestTimestamp,
                windowNumber: windowNumber,
                context: nil,
                characters: parsed.characters,
                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: parsed.keyCode
            ) else {
                result = "ERROR: NSEvent.keyEvent returned nil"
                return
            }
            let keyUpEvent = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: parsed.modifierFlags,
                timestamp: requestTimestamp + 0.0001,
                windowNumber: windowNumber,
                context: nil,
                characters: parsed.characters,
                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: parsed.keyCode
            )
            // Socket-driven shortcut simulation should reuse the exact same matching logic as the
            // app-level shortcut monitor (so tests are hermetic), while still falling back to the
            // normal responder chain for plain typing.
            if let delegate = AppDelegate.shared, delegate.debugHandleCustomShortcut(event: keyDownEvent) {
                result = "OK"
                return
            }
            NSApp.sendEvent(keyDownEvent)
            if let keyUpEvent {
                NSApp.sendEvent(keyUpEvent)
            }
            result = "OK"
        }
        return result
    }

    private func activateApp() -> String {
        v2MainSync {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            let hasMainTerminalWindow = NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }

            if !hasMainTerminalWindow {
                AppDelegate.shared?.openNewMainWindow(nil)
            }

            if let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                })
                ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return "OK"
    }

    private func simulateType(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: simulate_type <text>"
        }

        // Socket commands are line-based; allow callers to express control chars with backslash escapes.
        let text = unescapeSocketText(raw)

        var result = "ERROR: No window"
        v2MainSync {
            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
            // fail during key window transitions.
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else { return }
            prepareWindowForSyntheticInput(window)
            guard let fr = window.firstResponder else {
                result = "ERROR: No first responder"
                return
            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = "OK"
                return
            }

            // Fall back to the responder chain insertText action.
            (fr as? NSResponder)?.insertText(text)
            result = "OK"
        }
        return result
    }

    private func simulateFileDrop(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPaths = parts[1]
        let paths = rawPaths
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let panel = resolveTerminalPanel(from: target, tabManager: tabManager) else { return }
            result = panel.hostedView.debugSimulateFileDrop(paths: paths)
                ? "OK"
                : "ERROR: Failed to simulate drop"
        }
        return result
    }

    private func seedDragPasteboardFileURL() -> String {
        return seedDragPasteboardTypes("fileurl")
    }

    private func seedDragPasteboardTabTransfer() -> String {
        return seedDragPasteboardTypes("tabtransfer")
    }

    private func seedDragPasteboardSidebarReorder() -> String {
        return seedDragPasteboardTypes("sidebarreorder")
    }

    private func seedDragPasteboardTypes(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        var types: [NSPasteboard.PasteboardType] = []
        for token in tokens {
            guard let mapped = dragPasteboardType(from: token) else {
                return "ERROR: Unknown drag type '\(token)'"
            }
            if !types.contains(mapped) {
                types.append(mapped)
            }
        }

        v2MainSync {
            _ = NSPasteboard(name: .drag).declareTypes(types, owner: nil)
        }
        return "OK"
    }

    private func clearDragPasteboard() -> String {
        v2MainSync {
            _ = NSPasteboard(name: .drag).clearContents()
        }
        return "OK"
    }

    private func overlayHitGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: overlay_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }

        let parsedEvent = parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(args.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }

        return shouldCapture ? "true" : "false"
    }

    private func overlayDropGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasLocalDraggingSource: Bool
        switch token {
        case "", "external":
            hasLocalDraggingSource = false
        case "local":
            hasLocalDraggingSource = true
        default:
            return "ERROR: Usage: overlay_drop_gate [external|local]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: pb.types,
                hasLocalDraggingSource: hasLocalDraggingSource
            )
        }
        return shouldCapture ? "true" : "false"
    }

    private func portalHitGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: portal_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }
        let parsedEvent = parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(args.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldPassThrough = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }
        return shouldPassThrough ? "true" : "false"
    }

    private func sidebarOverlayGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSidebarDragState: Bool
        switch token {
        case "", "active":
            hasSidebarDragState = true
        case "inactive":
            hasSidebarDragState = false
        default:
            return "ERROR: Usage: sidebar_overlay_gate [active|inactive]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
                hasSidebarDragState: hasSidebarDragState,
                pasteboardTypes: pb.types
            )
        }
        return shouldCapture ? "true" : "false"
    }

    private func terminalDropOverlayProbe(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let useDeferredPath: Bool
        switch token {
        case "", "deferred":
            useDeferredPath = true
        case "direct":
            useDeferredPath = false
        default:
            return "ERROR: Usage: terminal_drop_overlay_probe [deferred|direct]"
        }

        var result = "ERROR: No selected workspace"
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
                return
            }

            let terminalPanel = workspace.focusedTerminalPanel
                ?? orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }.first
            guard let terminalPanel else {
                result = "ERROR: No terminal panel available"
                return
            }

            let probe = terminalPanel.hostedView.debugProbeDropOverlayAnimation(
                useDeferredPath: useDeferredPath
            )
            let animated = probe.after > probe.before
            let mode = useDeferredPath ? "deferred" : "direct"
            result = String(
                format: "OK mode=%@ animated=%d before=%d after=%d bounds=%.1fx%.1f",
                mode,
                animated ? 1 : 0,
                probe.before,
                probe.after,
                probe.bounds.width,
                probe.bounds.height
            )
        }
        return result
    }

    private func parseOverlayEventType(_ token: String) -> (isKnown: Bool, eventType: NSEvent.EventType?) {
        switch token {
        case "leftmousedragged":
            return (true, .leftMouseDragged)
        case "rightmousedragged":
            return (true, .rightMouseDragged)
        case "othermousedragged":
            return (true, .otherMouseDragged)
        case "mousemove", "mousemoved":
            return (true, .mouseMoved)
        case "mouseentered":
            return (true, .mouseEntered)
        case "mouseexited":
            return (true, .mouseExited)
        case "flagschanged":
            return (true, .flagsChanged)
        case "cursorupdate":
            return (true, .cursorUpdate)
        case "appkitdefined":
            return (true, .appKitDefined)
        case "systemdefined":
            return (true, .systemDefined)
        case "applicationdefined":
            return (true, .applicationDefined)
        case "periodic":
            return (true, .periodic)
        case "leftmousedown":
            return (true, .leftMouseDown)
        case "leftmouseup":
            return (true, .leftMouseUp)
        case "rightmousedown":
            return (true, .rightMouseDown)
        case "rightmouseup":
            return (true, .rightMouseUp)
        case "othermousedown":
            return (true, .otherMouseDown)
        case "othermouseup":
            return (true, .otherMouseUp)
        case "scrollwheel":
            return (true, .scrollWheel)
        case "none":
            return (true, nil)
        default:
            return (false, nil)
        }
    }

    private func dragPasteboardType(from token: String) -> NSPasteboard.PasteboardType? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "fileurl", "file-url", "public.file-url":
            return .fileURL
        case "tabtransfer", "tab-transfer", "com.stage11.c11.tabtransfer":
            return DragOverlayRoutingPolicy.bonsplitTabTransferType
        case "sidebarreorder", "sidebar-reorder", "sidebar_tab_reorder",
            "com.stage11.c11.sidebar-tab-reorder":
            return DragOverlayRoutingPolicy.sidebarTabReorderType
        default:
            // Allow explicit UTI strings for ad-hoc debug probes.
            guard token.contains(".") else { return nil }
            return NSPasteboard.PasteboardType(token)
        }
    }

    /// Hit-tests the file-drop overlay's coordinate-to-terminal mapping.
    /// Takes normalised (0-1) x,y within the content area where (0,0) is the
    /// top-left corner and (1,1) is the bottom-right corner.  Returns the
    /// surface UUID of the terminal under that point, or "none".
    private func dropHitTest(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>"
        }

        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            // Convert normalized top-left coordinates into a window point.
            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )
            let windowPoint = themeFrame.convert(pointInTheme, to: nil)

            if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView,
               let terminal = overlay.terminalUnderPoint(windowPoint),
               let surfaceId = terminal.terminalSurface?.id {
                result = surfaceId.uuidString.uppercased()
                return
            }

            result = "none"
        }
        return result
    }

    /// Return the hit-test chain at normalized (0-1) coordinates in the main window's
    /// content area. Used by regression tests to detect root-level drag destinations
    /// shadowing pane-local Bonsplit drop targets.
    private func dragHitChain(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1>"
        }

        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )

            let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView
            if let overlay { overlay.isHidden = true }
            defer { overlay?.isHidden = false }

            guard let hit = themeFrame.hitTest(pointInTheme) else {
                result = "none"
                return
            }

            var chain: [String] = []
            var current: NSView? = hit
            var depth = 0
            while let view = current, depth < 8 {
                chain.append(debugDragHitViewDescriptor(view))
                current = view.superview
                depth += 1
            }
            result = chain.joined(separator: "->")
        }
        return result
    }

    private func debugDragHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let pointer = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let types = view.registeredDraggedTypes
        let renderedTypes: String
        if types.isEmpty {
            renderedTypes = "-"
        } else {
            let raw = types.map(\.rawValue)
            renderedTypes = raw.count <= 4
                ? raw.joined(separator: ",")
                : raw.prefix(4).joined(separator: ",") + ",+\(raw.count - 4)"
        }
        return "\(className)@\(pointer){dragTypes=\(renderedTypes)}"
    }

    private func unescapeSocketText(_ input: String) -> String {
        var out = ""
        var escaping = false
        for ch in input {
            if escaping {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\":
                    out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping {
            out.append("\\")
        }
        return out
    }

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    private func isTerminalFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_terminal_focused <panel_id|idx>" }

        var result = "false"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "false"
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "false"
                return
            }
            result = terminalPanel.hostedView.isSurfaceViewFirstResponder() ? "true" : "false"
        }
        return result
    }

    private func readTerminalText(_ args: String) -> String {
        readTerminalTextBase64(surfaceArg: args)
    }

    private struct RenderStatsResponse: Codable {
        let panelId: String
        let drawCount: Int
        let lastDrawTime: Double
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    private func renderStats(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if panelArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: panelArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            let stats = terminalPanel.hostedView.debugRenderStats()
            let payload = RenderStatsResponse(
                panelId: panelId.uuidString,
                drawCount: stats.drawCount,
                lastDrawTime: stats.lastDrawTime,
                metalDrawableCount: stats.metalDrawableCount,
                metalLastDrawableTime: stats.metalLastDrawableTime,
                presentCount: stats.presentCount,
                lastPresentTime: stats.lastPresentTime,
                layerClass: stats.layerClass,
                layerContentsKey: stats.layerContentsKey,
                inWindow: stats.inWindow,
                windowIsKey: stats.windowIsKey,
                windowOcclusionVisible: stats.windowOcclusionVisible,
                appIsActive: stats.appIsActive,
                isActive: stats.isActive,
                desiredFocus: stats.desiredFocus,
                isFirstResponder: stats.isFirstResponder
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode render_stats"
                return
            }

            result = "OK \(json)"
        }

        return result
    }

    private struct ParsedShortcutCombo {
        let storedKey: String
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags
        let characters: String
        let charactersIgnoringModifiers: String
    }

    private func parseShortcutCombo(_ combo: String) -> ParsedShortcutCombo? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parts = raw
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyToken: String?

        for part in parts {
            let lower = part.lowercased()
            switch lower {
            case "cmd", "command", "super":
                flags.insert(.command)
            case "ctrl", "control":
                flags.insert(.control)
            case "opt", "option", "alt":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            default:
                // Treat as the key component.
                if keyToken == nil {
                    keyToken = part
                } else {
                    // Multiple non-modifier tokens is ambiguous.
                    return nil
                }
            }
        }

        guard var keyToken else { return nil }
        keyToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToken.isEmpty else { return nil }

        // Normalize a few named keys.
        let storedKey: String
        let keyCode: UInt16
        let charactersIgnoringModifiers: String

        switch keyToken.lowercased() {
        case "left":
            storedKey = "←"
            keyCode = 123
            charactersIgnoringModifiers = storedKey
        case "right":
            storedKey = "→"
            keyCode = 124
            charactersIgnoringModifiers = storedKey
        case "down":
            storedKey = "↓"
            keyCode = 125
            charactersIgnoringModifiers = storedKey
        case "up":
            storedKey = "↑"
            keyCode = 126
            charactersIgnoringModifiers = storedKey
        case "enter", "return":
            storedKey = "\r"
            keyCode = UInt16(kVK_Return)
            charactersIgnoringModifiers = storedKey
        default:
            let key = keyToken.lowercased()
            guard let code = keyCodeForShortcutKey(key) else { return nil }
            storedKey = key
            keyCode = code

            // Replicate a common system behavior: Ctrl+letter yields a control character in
            // charactersIgnoringModifiers (e.g. Ctrl+H => backspace). This is important for
            // testing keyCode fallback matching.
            if flags.contains(.control),
               key.count == 1,
               let scalar = key.unicodeScalars.first,
               scalar.isASCII,
               scalar.value >= 97, scalar.value <= 122 { // a-z
                let upper = scalar.value - 32
                let controlValue = upper - 64 // 'A' => 1
                charactersIgnoringModifiers = String(UnicodeScalar(controlValue)!)
            } else {
                charactersIgnoringModifiers = storedKey
            }
        }

        // For our shortcut matcher, characters aren't important beyond exercising edge cases.
        let chars = charactersIgnoringModifiers

        return ParsedShortcutCombo(
            storedKey: storedKey,
            keyCode: keyCode,
            modifierFlags: flags,
            characters: chars,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    private func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes for common printable keys and a few named specials.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "]": return 30  // kVK_ANSI_RightBracket
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "[": return 33  // kVK_ANSI_LeftBracket
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        default:
            return nil
        }
    }
#endif

    #if !DEBUG
    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
    #endif

    private func listWindows() -> String {
        let summaries = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        guard !summaries.isEmpty else { return "No windows" }

        let lines = summaries.enumerated().map { idx, item in
            let selected = item.isKeyWindow ? "*" : " "
            let selectedWs = item.selectedWorkspaceId?.uuidString ?? "none"
            return "\(selected) \(idx): \(item.windowId.uuidString) selected_workspace=\(selectedWs) workspaces=\(item.workspaceCount)"
        }
        return lines.joined(separator: "\n")
    }

    private func currentWindow() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else { return "ERROR: No active window" }
        return windowId.uuidString
    }

    private func focusWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }

        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    private func newWindow() -> String {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return "ERROR: Failed to create window"
        }
        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK \(windowId.uuidString)"
    }

    private func closeWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok ? "OK" : "ERROR: Window not found"
    }

    private func moveWorkspaceToWindow(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage move_workspace_to_window <workspace_id> <window_id>" }
        guard let wsId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid workspace id" }
        guard let windowId = UUID(uuidString: parts[1]) else { return "ERROR: Invalid window id" }

        var ok = false
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId),
                  let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }

    private func listWorkspaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        v2MainSync {
            let tabs = tabManager.tabs.enumerated().map { (index, tab) in
                let selected = tab.id == tabManager.selectedTabId ? "*" : " "
                return "\(selected) \(index): \(tab.id.uuidString) \(tab.title)"
            }
            result = tabs.joined(separator: "\n")
        }
        return result.isEmpty ? "No workspaces" : result
    }

    private func newWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var newTabId: UUID?
        let focus = socketCommandAllowsInAppFocusMutations()
        guard v2MainSyncWithDeadline({
            let workspace = tabManager.addTab(select: focus, eagerLoadTerminal: !focus)
            newTabId = workspace.id
            return
        }) != nil else {
            return "ERROR: main thread did not respond within deadline"
        }
        return "OK \(newTabId?.uuidString ?? "unknown")"
    }

    private func newSplit(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let directionArg = parts[0]
        let panelArg = parts.count > 1 ? parts[1] : ""

        guard let direction = parseSplitDirection(directionArg) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        var result = "ERROR: Failed to create split"
        guard v2MainSyncWithDeadline({
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // If panel arg provided, resolve it; otherwise use focused panel
            let surfaceId: UUID?
            if !panelArg.isEmpty {
                surfaceId = self.resolveSurfaceId(from: panelArg, tab: tab)
                if surfaceId == nil {
                    result = "ERROR: Panel not found"
                    return
                }
            } else {
                surfaceId = tab.focusedPanelId
            }

            guard let targetSurface = surfaceId else {
                result = "ERROR: No surface to split"
                return
            }

            if let newPanelId = tabManager.newSplit(tabId: tabId, surfaceId: targetSurface, direction: direction) {
                result = "OK \(newPanelId.uuidString)"
            }
        }) != nil else {
            return "ERROR: main thread did not respond within deadline"
        }
        return result
    }

    private func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let focusedId = tab.focusedPanelId
            let lines = panels.enumerated().map { index, panel in
                let selected = panel.id == focusedId ? "*" : " "
                return "\(selected) \(index): \(panel.id.uuidString)"
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    private func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing panel id or index" }

        var success = false
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            if let uuid = UUID(uuidString: trimmed),
               tab.panels[uuid] != nil {
                guard tab.surfaceIdFromPanelId(uuid) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
                return
            }

            if let index = Int(trimmed), index >= 0 {
                let panels = orderedPanels(in: tab)
                guard index < panels.count else { return }
                guard tab.surfaceIdFromPanelId(panels[index].id) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: panels[index].id)
                success = true
            }
        }

        return success ? "OK" : "ERROR: Panel not found"
    }

    private func notifyCurrent(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId else {
                result = "ERROR: No tab selected"
                return
            }
            let surfaceId = tabManager.focusedSurfaceId(for: tabId)
            let (title, subtitle, body) = parseNotificationPayload(args)
            TerminalNotificationStore.shared.addNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func notifySurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let surfaceArg = parts[0]
        let payload = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: surfaceArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            TerminalNotificationStore.shared.addNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func notifyTarget(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let tabArg = parts[0]
        let panelArg = parts[1]
        let payload = parts.count > 2 ? parts[2] : ""

        var result = "OK"
        v2MainSync {
            let tab: Tab?
            if let tabId = UUID(uuidString: tabArg) {
                tab = tabForSidebarMutation(id: tabId)
            } else {
                tab = resolveTab(from: tabArg, tabManager: tabManager)
            }
            guard let tab else {
                result = "ERROR: Tab not found"
                return
            }
            guard let panelId = UUID(uuidString: panelArg),
                  tab.panels[panelId] != nil else {
                result = "ERROR: Panel not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            TerminalNotificationStore.shared.addNotification(
                tabId: tab.id,
                surfaceId: panelId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    private func listNotifications() -> String {
        var result = ""
        v2MainSync {
            let lines = TerminalNotificationStore.shared.notifications.enumerated().map { index, notification in
                let surfaceText = notification.surfaceId?.uuidString ?? "none"
                let readText = notification.isRead ? "read" : "unread"
                return "\(index):\(notification.id.uuidString)|\(notification.tabId.uuidString)|\(surfaceText)|\(readText)|\(notification.title)|\(notification.subtitle)|\(notification.body)"
            }
            result = lines.joined(separator: "\n")
        }
        return result.isEmpty ? "No notifications" : result
    }

    private func clearNotifications(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            v2MainSync {
                TerminalNotificationStore.shared.clearAll()
            }
            return "OK"
        }
        let parsed = parseOptions(trimmed)
        guard let tabOption = parsed.options["tab"],
              !tabOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ERROR: Usage: clear_notifications [--tab=X]"
        }
        var tabId: UUID?
        v2MainSync {
            if let tab = resolveTabForReport(trimmed) {
                tabId = tab.id
            }
        }
        guard let tabId else {
            return "ERROR: Tab not found"
        }
        v2MainSync {
            TerminalNotificationStore.shared.clearNotifications(forTabId: tabId)
        }
        return "OK"
    }

    private func setAppFocusOverride(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "active", "1", "true":
            AppFocusState.overrideIsFocused = true
            return "OK"
        case "inactive", "0", "false":
            AppFocusState.overrideIsFocused = false
            return "OK"
        case "clear", "none", "":
            AppFocusState.overrideIsFocused = nil
            return "OK"
        default:
            return "ERROR: Expected active, inactive, or clear"
        }
    }

    private func simulateAppDidBecomeActive() -> String {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return "OK"
    }

#if DEBUG
    private func focusFromNotification(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let tabArg = parts.first ?? ""
        let surfaceArg = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaceId = surfaceArg.isEmpty ? nil : resolveSurfaceId(from: surfaceArg, tab: tab)
            if !surfaceArg.isEmpty && surfaceId == nil {
                result = "ERROR: Surface not found"
                return
            }
            if !tabManager.focusTabFromNotification(tab.id, surfaceId: surfaceId) {
                result = "ERROR: Focus failed"
            }
        }
        return result
    }

    private func flashCount(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: trimmed, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let count = GhosttySurfaceScrollView.flashCount(for: surfaceId)
            result = "OK \(count)"
        }
        return result
    }

    private func resetFlashCounts() -> String {
        v2MainSync {
            GhosttySurfaceScrollView.resetFlashCounts()
        }
        return "OK"
    }

#if DEBUG
    private struct PanelSnapshotState: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let rgba: Data
    }

    /// Most tests run single-threaded but socket handlers can be invoked concurrently.
    /// Keep snapshot bookkeeping simple and thread-safe.
    private static let panelSnapshotLock = NSLock()
    private static var panelSnapshots: [UUID: PanelSnapshotState] = [:]

    private func panelSnapshotReset(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: panel_snapshot_reset <panel_id|idx>" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }
            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            Self.panelSnapshotLock.lock()
            Self.panelSnapshots.removeValue(forKey: panelId)
            Self.panelSnapshotLock.unlock()
            result = "OK"
        }

        return result
    }

    private static func makePanelSnapshot(from cgImage: CGImage) -> PanelSnapshotState? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        return PanelSnapshotState(width: width, height: height, bytesPerRow: bytesPerRow, rgba: data)
    }

    private static func countChangedPixels(previous: PanelSnapshotState, current: PanelSnapshotState) -> Int {
        // Any mismatch means we can't sensibly diff; treat as a fresh snapshot.
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow else {
            return -1
        }

        let threshold = 8 // ignore tiny per-channel jitter
        var changed = 0

        previous.rgba.withUnsafeBytes { prevRaw in
            current.rgba.withUnsafeBytes { curRaw in
                guard let prev = prevRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cur = curRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                let count = min(prevRaw.count, curRaw.count)
                var i = 0
                while i + 3 < count {
                    let dr = abs(Int(prev[i]) - Int(cur[i]))
                    let dg = abs(Int(prev[i + 1]) - Int(cur[i + 1]))
                    let db = abs(Int(prev[i + 2]) - Int(cur[i + 2]))
                    // Skip alpha channel at i+3.
                    if dr + dg + db > threshold {
                        changed += 1
                    }
                    i += 4
                }
            }
        }

        return changed
    }

    private func panelSnapshot(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: panel_snapshot <panel_id|idx> [label]" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let panelArg = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : ""

        // Generate unique ID for this snapshot/screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let snapshotId = "\(timestamp)_\(shortId)"

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let filename = label.isEmpty ? "\(snapshotId).png" : "\(label)_\(snapshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            // Capture the terminal's IOSurface directly, avoiding Screen Recording permissions.
            let view = terminalPanel.hostedView
            var cgImage = view.debugCopyIOSurfaceCGImage()
            if cgImage == nil {
                // If the surface is mid-attach we may not have contents yet. Nudge a draw and retry once.
                terminalPanel.surface.forceRefresh(reason: "terminalController.debugCopyIOSurfaceRetry")
                cgImage = view.debugCopyIOSurfaceCGImage()
            }
            guard let cgImage else {
                result = "ERROR: Failed to capture panel image"
                return
            }

            guard let current = Self.makePanelSnapshot(from: cgImage) else {
                result = "ERROR: Failed to read panel pixels"
                return
            }

            var changedPixels = -1
            Self.panelSnapshotLock.lock()
            if let previous = Self.panelSnapshots[panelId] {
                changedPixels = Self.countChangedPixels(previous: previous, current: current)
            }
            Self.panelSnapshots[panelId] = current
            Self.panelSnapshotLock.unlock()

            // Save PNG for postmortem debugging.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                result = "ERROR: Failed to encode PNG"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                result = "ERROR: Failed to write file: \(error.localizedDescription)"
                return
            }

            result = "OK \(panelId.uuidString) \(changedPixels) \(current.width) \(current.height) \(outputPath.path)"
        }

        return result
    }
#endif

    private struct LayoutDebugSelectedPanel: Codable, Sendable {
        let paneId: String
        let paneFrame: PixelRect?
        let selectedTabId: String?
        let panelId: String?
        let panelType: String?
        let inWindow: Bool?
        let hidden: Bool?
        let viewFrame: PixelRect?
        let splitViews: [LayoutDebugSplitView]?
    }

    private struct LayoutDebugSplitView: Codable, Sendable {
        let isVertical: Bool
        let dividerThickness: Double
        let bounds: PixelRect
        let frame: PixelRect?
        let arrangedSubviewFrames: [PixelRect]
        let normalizedDividerPosition: Double?
    }

    private struct LayoutDebugResponse: Codable, Sendable {
        let layout: LayoutSnapshot
        let selectedPanels: [LayoutDebugSelectedPanel]
        let mainWindowNumber: Int?
        let keyWindowNumber: Int?
    }

    private func layoutDebug() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let layout = tab.bonsplitController.layoutSnapshot()
            var paneFrames: [String: PixelRect] = [:]
            for pane in layout.panes {
                paneFrames[pane.paneId] = pane.frame
            }

            func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
                if view.isHidden { return true }
                var current = view.superview
                while let v = current {
                    if v.isHidden { return true }
                    current = v.superview
                }
                return false
            }

            func windowFrame(for view: NSView) -> CGRect? {
                guard view.window != nil else { return nil }
                // Prefer the view's frame as laid out by its superview. Some AppKit views
                // (notably scroll views) can temporarily report stale bounds during reparenting.
                if let superview = view.superview {
                    return superview.convert(view.frame, to: nil)
                }
                return view.convert(view.bounds, to: nil)
            }

            func splitViewInfos(for view: NSView) -> [LayoutDebugSplitView] {
                var infos: [LayoutDebugSplitView] = []
                var current: NSView? = view
                var depth = 0
                while let v = current, depth < 12 {
                    if let sv = v as? NSSplitView {
                        // The split view can be mid-update during bonsplit structural changes; force a layout
                        // pass so our debug snapshot reflects the real state.
                        sv.layoutSubtreeIfNeeded()
                        let isVertical = sv.isVertical
                        let dividerThickness = Double(sv.dividerThickness)
                        let bounds = PixelRect(from: sv.bounds)
                        let frame = windowFrame(for: sv).map { PixelRect(from: $0) }
                        let arranged = sv.arrangedSubviews
                        let arrangedFrames = arranged.compactMap { windowFrame(for: $0).map { PixelRect(from: $0) } }

                        // Approximate divider position from the first arranged subview's size.
                        let totalSize: CGFloat = isVertical ? sv.bounds.width : sv.bounds.height
                        let availableSize = max(totalSize - sv.dividerThickness, 0)
                        var normalized: Double? = nil
                        if availableSize > 0, let first = arranged.first {
                            let dividerPos = isVertical ? first.frame.width : first.frame.height
                            normalized = Double(dividerPos / availableSize)
                        }

                        infos.append(LayoutDebugSplitView(
                            isVertical: isVertical,
                            dividerThickness: dividerThickness,
                            bounds: bounds,
                            frame: frame,
                            arrangedSubviewFrames: arrangedFrames,
                            normalizedDividerPosition: normalized
                        ))
                    }
                    current = v.superview
                    depth += 1
                }
                return infos
            }

            let selectedPanels: [LayoutDebugSelectedPanel] = tab.bonsplitController.allPaneIds.map { paneId in
                let paneIdStr = paneId.id.uuidString
                let paneFrame = paneFrames[paneIdStr]
                let selectedTabId = layout.panes.first(where: { $0.paneId == paneIdStr })?.selectedTabId

	                guard let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId) else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

	                guard let panelId = tab.panelIdFromSurfaceId(selectedTab.id),
	                      let panel = tab.panels[panelId] else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

                if let tp = panel as? TerminalPanel {
                    let viewRect = windowFrame(for: tp.hostedView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: tp.hostedView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: tp.panelType.rawValue,
	                        inWindow: tp.surface.isViewInWindow,
	                        hidden: isHiddenOrAncestorHidden(tp.hostedView),
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

                if let bp = panel as? BrowserPanel {
                    let viewRect = windowFrame(for: bp.webView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: bp.webView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: bp.panelType.rawValue,
	                        inWindow: bp.webView.window != nil,
	                        hidden: isHiddenOrAncestorHidden(bp.webView),
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }

	                return LayoutDebugSelectedPanel(
	                    paneId: paneIdStr,
	                    paneFrame: paneFrame,
	                    selectedTabId: selectedTabId,
	                    panelId: panelId.uuidString,
	                    panelType: panel.panelType.rawValue,
	                    inWindow: nil,
	                    hidden: nil,
	                    viewFrame: nil,
	                    splitViews: nil
	                )
	            }

            let payload = LayoutDebugResponse(
                layout: layout,
                selectedPanels: selectedPanels,
                mainWindowNumber: NSApp.mainWindow?.windowNumber,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode layout_debug"
                return
            }

            result = "OK \(json)"
        }
        return result
    }

    private func emptyPanelCount() -> String {
        var result = "OK 0"
        v2MainSync {
            result = "OK \(DebugUIEventCounters.emptyPanelAppearCount)"
        }
        return result
    }

    private func resetEmptyPanelCount() -> String {
        v2MainSync {
            DebugUIEventCounters.resetEmptyPanelAppearCount()
        }
        return "OK"
    }

    private func bonsplitUnderflowCount() -> String {
        var result = "OK 0"
        v2MainSync {
#if DEBUG
            result = "OK \(BonsplitDebugCounters.arrangedSubviewUnderflowCount)"
#else
            result = "OK 0"
#endif
        }
        return result
    }

    private func resetBonsplitUnderflowCount() -> String {
        v2MainSync {
#if DEBUG
            BonsplitDebugCounters.reset()
#endif
        }
        return "OK"
    }

    private func captureScreenshot(_ args: String) -> String {
        // Parse optional label from args
        let label = args.trimmingCharacters(in: .whitespacesAndNewlines)

        // Generate unique ID for this screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let screenshotId = "\(timestamp)_\(shortId)"

        // Determine output path
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let filename = label.isEmpty ? "\(screenshotId).png" : "\(label)_\(screenshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        // Capture the main window on main thread
        var captureError: String?
        v2MainSync {
            guard let window = NSApp.mainWindow ?? NSApp.windows.first else {
                captureError = "No window available"
                return
            }

            // Get window's CGWindowID
            let windowNumber = CGWindowID(window.windowNumber)

            // Capture the window using CGWindowListCreateImage
            guard let cgImage = CGWindowListCreateImage(
                .null,  // Capture just the window bounds
                .optionIncludingWindow,
                windowNumber,
                [.boundsIgnoreFraming, .nominalResolution]
            ) else {
                captureError = "Failed to capture window image"
                return
            }

            // Convert to NSBitmapImageRep and save as PNG
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                captureError = "Failed to create PNG data"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                captureError = "Failed to write file: \(error.localizedDescription)"
            }
        }

        if let error = captureError {
            return "ERROR: \(error)"
        }

        // Return OK with screenshot ID and path for easy reference
        return "OK \(screenshotId) \(outputPath.path)"
    }
#endif

    private func parseSplitDirection(_ value: String) -> SplitDirection? {
        switch value.lowercased() {
        case "left", "l":
            return .left
        case "right", "r":
            return .right
        case "up", "u":
            return .up
        case "down", "d":
            return .down
        default:
            return nil
        }
    }

    private func resolveTab(from arg: String, tabManager: TabManager) -> Tab? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let index = Int(trimmed), index >= 0, index < tabManager.tabs.count {
            return tabManager.tabs[index]
        }

        return nil
    }

    private func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Use bonsplit's tab ordering as the source of truth. This avoids relying on
        // Dictionary iteration order, and prevents indexing into panels that aren't
        // actually present in bonsplit anymore.
        let orderedTabIds = tab.bonsplitController.allTabIds
        var result: [any Panel] = []
        var seen = Set<UUID>()

        for tabId in orderedTabIds {
            guard let panelId = tab.panelIdFromSurfaceId(tabId),
                  let panel = tab.panels[panelId] else { continue }
            result.append(panel)
            seen.insert(panelId)
        }

        // Defensive: include any orphaned panels in a stable order at the end.
        let orphans = tab.panels.values
            .filter { !seen.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.append(contentsOf: orphans)

        return result
    }

    private func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg) {
            return tab.terminalPanel(for: uuid)
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index] as? TerminalPanel
        }

        return nil
    }

    private func resolveTerminalSurface(from arg: String, tabManager: TabManager, waitUpTo timeout: TimeInterval = 0.6) -> ghostty_surface_t? {
        guard let terminalPanel = resolveTerminalPanel(from: arg, tabManager: tabManager) else { return nil }
        return waitForTerminalSurface(terminalPanel, waitUpTo: timeout)
    }

    private func waitForTerminalSurface(_ terminalPanel: TerminalPanel, waitUpTo timeout: TimeInterval = 0.6) -> ghostty_surface_t? {
        if let surface = terminalPanel.surface.surface { return surface }

        let terminalSurface = terminalPanel.surface
        terminalSurface.requestBackgroundSurfaceStartIfNeeded()
        _ = v2AwaitCallback(timeout: timeout) { finish in
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?
            let finishOnce: () -> Void = {
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                finish(())
            }

            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: terminalSurface,
                queue: .main
            ) { _ in
                finishOnce()
            }
            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: terminalSurface,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    if terminalSurface.surface != nil {
                        finishOnce()
                    }
                }
            }

            if terminalSurface.surface != nil {
                finishOnce()
            }
        }

        return terminalPanel.surface.surface
    }

    private func resolveSurface(from arg: String, tabManager: TabManager) -> ghostty_surface_t? {
        // Backwards compatibility: resolve a terminal surface by panel UUID or a stable index.
        // Use a slightly longer wait to reduce flakiness during bonsplit/layout restructures.
        return resolveTerminalSurface(from: arg, tabManager: tabManager, waitUpTo: 2.0)
    }

    private func resolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.panels[uuid] != nil {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index].id
        }

        return nil
    }

    private func parseNotificationPayload(_ args: String) -> (String, String, String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "") }
        let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    private func closeWorkspace(_ tabId: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        guard let uuid = UUID(uuidString: tabId) else { return "ERROR: Invalid tab ID" }

        var success = false
        v2MainSync {
            if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                tabManager.closeTab(tab)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    private func selectWorkspace(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        v2MainSync {
            // Try as UUID first
            if let uuid = UUID(uuidString: arg) {
                if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                    tabManager.selectTab(tab)
                    success = true
                }
            }
            // Try as index
            else if let index = Int(arg), index >= 0, index < tabManager.tabs.count {
                tabManager.selectTab(at: index)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    private func currentWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        v2MainSync {
            if let id = tabManager.selectedTabId {
                result = id.uuidString
            }
        }
        return result.isEmpty ? "ERROR: No tab selected" : result
    }

    private func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        if let text {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func sendTextEvent(surface: ghostty_surface_t, text: String) {
        sendKeyEvent(surface: surface, keycode: 0, text: text)
    }

    enum SocketTextChunk: Equatable {
        case text(String)
        case control(UnicodeScalar)
    }

    nonisolated static func socketTextChunks(_ text: String) -> [SocketTextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [SocketTextChunk] = []
        chunks.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            chunks.append(.text(bufferedText))
            bufferedText.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isSocketControlScalar(scalar) {
                flushBufferedText()
                chunks.append(.control(scalar))
            } else {
                bufferedText.unicodeScalars.append(scalar)
            }
        }
        flushBufferedText()
        return chunks
    }

    private nonisolated static func isSocketControlScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x09, 0x1B, 0x7F:
            return true
        default:
            return false
        }
    }

    private func handleControlScalar(_ scalar: UnicodeScalar, surface: ghostty_surface_t) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Return))
            return true
        case 0x09:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Tab))
            return true
        case 0x1B:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Escape))
            return true
        case 0x7F:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Delete))
            return true
        default:
            return false
        }
    }

    private static func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    /// A resolved keystroke: the macOS virtual keycode plus modifier flags to
    /// hand to `ghostty_surface_key`. Ghostty owns the keycode → PTY-bytes
    /// translation, so arrows and friends are emitted as the correct CSI
    /// (normal) or SS3 (application-cursor-keys) sequence for the surface's
    /// current DECCKM mode — which is what drives arrow-select menus in TUIs.
    struct NamedKeyEvent: Equatable {
        let keycode: UInt32
        let mods: ghostty_input_mods_e

        static func == (lhs: NamedKeyEvent, rhs: NamedKeyEvent) -> Bool {
            lhs.keycode == rhs.keycode && lhs.mods.rawValue == rhs.mods.rawValue
        }
    }

    /// Pure name → keystroke mapping for `send-key`. Kept separate from the
    /// surface-injecting `sendNamedKey` so the vocabulary is unit-testable
    /// without a live surface. Returns nil for an unrecognised name.
    static func namedKeyEvent(for keyName: String) -> NamedKeyEvent? {
        func ev(_ keycode: Int, _ mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) -> NamedKeyEvent {
            NamedKeyEvent(keycode: UInt32(keycode), mods: mods)
        }
        let name = keyName.lowercased()
        switch name {
        // Control combinations / signals
        case "ctrl-c", "ctrl+c", "sigint": return ev(kVK_ANSI_C, GHOSTTY_MODS_CTRL)
        case "ctrl-d", "ctrl+d", "eof": return ev(kVK_ANSI_D, GHOSTTY_MODS_CTRL)
        case "ctrl-z", "ctrl+z", "sigtstp": return ev(kVK_ANSI_Z, GHOSTTY_MODS_CTRL)
        case "ctrl-\\", "ctrl+\\", "sigquit": return ev(kVK_ANSI_Backslash, GHOSTTY_MODS_CTRL)
        // Editing / submission keys
        case "enter", "return": return ev(kVK_Return)
        case "tab": return ev(kVK_Tab)
        case "escape", "esc": return ev(kVK_Escape)
        case "backspace", "bs": return ev(kVK_Delete)
        case "delete", "del", "forward-delete": return ev(kVK_ForwardDelete)
        case "space": return ev(kVK_Space)
        // Arrow keys
        case "up", "arrow-up", "arrowup": return ev(kVK_UpArrow)
        case "down", "arrow-down", "arrowdown": return ev(kVK_DownArrow)
        case "left", "arrow-left", "arrowleft": return ev(kVK_LeftArrow)
        case "right", "arrow-right", "arrowright": return ev(kVK_RightArrow)
        // Navigation keys
        case "home": return ev(kVK_Home)
        case "end": return ev(kVK_End)
        case "pageup", "page-up", "pgup": return ev(kVK_PageUp)
        case "pagedown", "page-down", "pgdn": return ev(kVK_PageDown)
        // Function keys
        case "f1": return ev(kVK_F1)
        case "f2": return ev(kVK_F2)
        case "f3": return ev(kVK_F3)
        case "f4": return ev(kVK_F4)
        case "f5": return ev(kVK_F5)
        case "f6": return ev(kVK_F6)
        case "f7": return ev(kVK_F7)
        case "f8": return ev(kVK_F8)
        case "f9": return ev(kVK_F9)
        case "f10": return ev(kVK_F10)
        case "f11": return ev(kVK_F11)
        case "f12": return ev(kVK_F12)
        default:
            if name.hasPrefix("ctrl-") || name.hasPrefix("ctrl+") {
                let letter = name.dropFirst(5)
                if letter.count == 1, let char = letter.first, let keycode = keycodeForLetter(char) {
                    return NamedKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_CTRL)
                }
            }
            return nil
        }
    }

    private func sendNamedKey(_ surface: ghostty_surface_t, keyName: String) -> Bool {
        guard let event = Self.namedKeyEvent(for: keyName) else { return false }
        sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
        return true
    }

    private func sendInput(_ text: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            guard let surface = resolveTerminalSurface(
                from: terminalPanel.id.uuidString,
                tabManager: tabManager,
                waitUpTo: 2.0
            ) else {
                error = "ERROR: Surface not ready"
                return
            }

            // Unescape common escape sequences
            // Note: \n is converted to \r for terminal (Enter key sends \r)
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            for char in unescaped {
                if char.unicodeScalars.count == 1,
                   let scalar = char.unicodeScalars.first,
                   handleControlScalar(scalar, surface: surface) {
                    continue
                }
                sendTextEvent(surface: surface, text: String(char))
            }
            success = true
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendSocketText(_ text: String, surface: ghostty_surface_t) {
        let chunks = Self.socketTextChunks(text)
#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
#endif
        for chunk in chunks {
            switch chunk {
            case .text(let value):
                sendTextEvent(surface: surface, text: value)
            case .control(let scalar):
                _ = handleControlScalar(scalar, surface: surface)
            }
        }
#if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        if elapsedMs >= 8 || chunks.count > 1 {
            dlog(
                "socket.send_text.inject chars=\(text.count) chunks=\(chunks.count) ms=\(String(format: "%.2f", elapsedMs))"
            )
        }
#endif
    }

    private func sendInputToWorkspace(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_workspace <workspace_id> <text>" }

        let workspaceArg = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let text = parts[1]
        guard let workspaceId = UUID(uuidString: workspaceArg) else {
            return "ERROR: Invalid workspace ID"
        }

        var success = false
        var error: String?
        v2MainSync {
            guard let targetManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
                ?? (tabManager.tabs.contains(where: { $0.id == workspaceId }) ? tabManager : nil) else {
                error = "ERROR: Workspace not found"
                return
            }
            guard let tab = targetManager.tabs.first(where: { $0.id == workspaceId }) else {
                error = "ERROR: Workspace not found"
                return
            }

            guard let terminalPanel = sendableWorkspaceTerminalPanel(in: tab) else {
                error = "ERROR: No selected terminal in workspace"
                return
            }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            // This DEBUG-only command is used by UI tests to enqueue shell work in an
            // existing workspace. Return once the input is queued on main so a long
            // payload does not hold the control-socket response open in CI.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let surface = terminalPanel.surface.surface {
                    self.sendSocketText(unescaped, surface: surface)
                } else {
                    terminalPanel.sendText(unescaped)
                    terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
            success = true
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendableWorkspaceTerminalPanel(in workspace: Workspace) -> TerminalPanel? {
        func selectedTerminalPanel(in paneId: PaneID) -> TerminalPanel? {
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = workspace.panelIdFromSurfaceId(selectedTab.id),
                  let terminalPanel = workspace.panels[panelId] as? TerminalPanel else {
                return nil
            }
            return terminalPanel
        }

        func isSelectedTerminalPanel(_ terminalPanel: TerminalPanel) -> Bool {
            guard let surfaceId = workspace.surfaceIdFromPanelId(terminalPanel.id) else {
                return false
            }
            return workspace.bonsplitController.allPaneIds.contains { paneId in
                workspace.bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
            }
        }

        if let focusedPane = workspace.bonsplitController.focusedPaneId,
           let terminalPanel = selectedTerminalPanel(in: focusedPane) {
            return terminalPanel
        }

        if let rememberedTerminal = workspace.lastRememberedTerminalPanelForConfigInheritance(),
           isSelectedTerminalPanel(rememberedTerminal) {
            return rememberedTerminal
        }

        for paneId in workspace.bonsplitController.allPaneIds {
            if let terminalPanel = selectedTerminalPanel(in: paneId) {
                return terminalPanel
            }
        }

        return nil
    }

    private func sendInputToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_surface <id|idx> <text>" }

        let target = parts[0]
        let text = parts[1]

        var success = false
        v2MainSync {
            guard let surface = resolveSurface(from: target, tabManager: tabManager) else { return }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            for char in unescaped {
                if char.unicodeScalars.count == 1,
                   let scalar = char.unicodeScalars.first,
                   handleControlScalar(scalar, surface: surface) {
                    continue
                }
                sendTextEvent(surface: surface, text: String(char))
            }
            success = true
        }

        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendKey(_ keyName: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            guard let surface = resolveTerminalSurface(
                from: terminalPanel.id.uuidString,
                tabManager: tabManager,
                waitUpTo: 2.0
            ) else {
                error = "ERROR: Surface not ready"
                return
            }

            success = sendNamedKey(surface, keyName: keyName)
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    private func sendKeyToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_key_surface <id|idx> <key>" }

        let target = parts[0]
        let keyName = parts[1]

        var success = false
        var error: String?
        v2MainSync {
            guard resolveTerminalPanel(from: target, tabManager: tabManager) != nil else {
                error = "ERROR: Surface not found"
                return
            }
            guard let surface = resolveTerminalSurface(from: target, tabManager: tabManager, waitUpTo: 2.0) else {
                error = "ERROR: Surface not ready"
                return
            }
            success = sendNamedKey(surface, keyName: keyName)
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    // MARK: - Browser Panel Commands

    private func openBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = trimmed.isEmpty ? nil : URL(string: trimmed)

        var result = "ERROR: Failed to create browser panel"
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            if let browserPanelId = tab.newBrowserSplit(
                from: focusedPanelId,
                orientation: .horizontal,
                url: url,
                focus: focus
            )?.id {
                result = "OK \(browserPanelId.uuidString)"
            }
        }
        return result
    }

    private func navigateBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: navigate <panel_id> <url>" }

        let panelArg = parts[0]
        let urlStr = parts[1]

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.navigateSmart(urlStr)
            result = "OK"
        }
        return result
    }

    private func browserBack(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_back <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goBack()
            result = "OK"
        }
        return result
    }

    private func browserForward(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_forward <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goForward()
            result = "OK"
        }
        return result
    }

    private func browserReload(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_reload <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.reload()
            result = "OK"
        }
        return result
    }

    private func getUrl(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: get_url <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            result = browserPanel.currentURL?.absoluteString ?? ""
        }
        return result
    }

    private func focusWebView(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: focus_webview <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            // Programmatic WebView focus should win over stale omnibar focus state, especially
            // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
            browserPanel.endSuppressWebViewFocusForAddressBar()
            browserPanel.clearWebViewFocusSuppression()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.5)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "ERROR: WebView is not in a window"
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = "ERROR: WebView is hidden"
                return
            }

            window.makeFirstResponder(webView)
            if Self.responderChainContains(window.firstResponder, target: webView) {
                // Some focus churn paths (workspace handoff / omnibar blur) can race this call.
                // Reassert on the next runloop if another responder steals focus immediately.
                DispatchQueue.main.async { [weak window, weak webView] in
                    guard let window, let webView else { return }
                    guard webView.window === window else { return }
                    if !Self.responderChainContains(window.firstResponder, target: webView) {
                        window.makeFirstResponder(webView)
                    }
                }
                result = "OK"
            } else {
                result = "ERROR: Focus did not move into web view"
            }
        }
        return result
    }

    private func isWebViewFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_webview_focused <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "false"
                return
            }
            result = Self.responderChainContains(window.firstResponder, target: webView) ? "true" : "false"
        }
        return result
    }

    // MARK: - Bonsplit Pane Commands

    private func listPanes() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds
            let focusedPaneId = tab.bonsplitController.focusedPaneId

            let lines = paneIds.enumerated().map { index, paneId in
                let selected = paneId == focusedPaneId ? "*" : " "
                let tabCount = tab.bonsplitController.tabs(inPane: paneId).count
                return "\(selected) \(index): \(paneId) [\(tabCount) tabs]"
            }
            result = lines.isEmpty ? "No panes" : lines.joined(separator: "\n")
        }
        return result
    }

    private func listPaneSurfaces(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            // Parse --pane=<pane-id|index> argument (UUID preferred).
            var paneArg: String?
            for part in args.split(separator: " ") {
                if part.hasPrefix("--pane=") {
                    paneArg = String(part.dropFirst(7))
                    break
                }
            }

            let paneIds = tab.bonsplitController.allPaneIds
            var targetPaneId: PaneID? = tab.bonsplitController.focusedPaneId
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg),
                   let paneId = paneIds.first(where: { $0.id == uuid }) {
                    targetPaneId = paneId
                } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                    targetPaneId = paneIds[index]
                } else {
                    result = "ERROR: Pane not found"
                    return
                }
            }

            guard let paneId = targetPaneId else {
                result = "ERROR: No pane to list tabs from"
                return
            }

            let tabs = tab.bonsplitController.tabs(inPane: paneId)
            let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId)

            let lines = tabs.enumerated().map { index, bonsplitTab in
                let selected = bonsplitTab.id == selectedTab?.id ? "*" : " "
                let panelId = tab.panelIdFromSurfaceId(bonsplitTab.id)
                let panelIdStr = panelId?.uuidString ?? "unknown"
                return "\(selected) \(index): \(bonsplitTab.title) [panel:\(panelIdStr)]"
            }
            result = lines.isEmpty ? "No tabs in pane" : lines.joined(separator: "\n")
        }
        return result
    }

    private func focusPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let paneArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneArg.isEmpty else { return "ERROR: Usage: focus_pane <pane_id>" }

        var result = "ERROR: Pane not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds

            // Try UUID first, then fall back to index
            if let uuid = UUID(uuidString: paneArg),
               let paneId = paneIds.first(where: { $0.id == uuid }) {
                tab.bonsplitController.focusPane(paneId)
                result = "OK"
            } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                tab.bonsplitController.focusPane(paneIds[index])
                result = "OK"
            }
        }
        return result
    }

	    private func focusSurfaceByPanel(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let tabArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tabArg.isEmpty else { return "ERROR: Usage: focus_surface_by_panel <panel_id>" }

        var result = "ERROR: Panel not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Focus by panel UUID (our stable surface handle). This must also move AppKit
            // first responder into the terminal view to ensure typing routes correctly.
            if let panelUUID = UUID(uuidString: tabArg),
               tab.panels[panelUUID] != nil,
               tab.surfaceIdFromPanelId(panelUUID) != nil {
                tabManager.focusSurface(tabId: tab.id, surfaceId: panelUUID)
                result = "OK"
            }
        }
	        return result
	    }
	
	    private func dragSurfaceToSplit(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
	
	        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
	        let parts = trimmed.split(separator: " ").map(String.init)
	        guard parts.count >= 2 else { return "ERROR: Usage: drag_surface_to_split <id|idx> <left|right|up|down>" }
	
	        let surfaceArg = parts[0]
	        let directionArg = parts[1]
	        guard let direction = parseSplitDirection(directionArg) else {
	            return "ERROR: Invalid direction. Use left, right, up, or down."
	        }
	
	        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
	        let insertFirst = (direction == .left || direction == .up)
	
	        var result = "ERROR: Failed to move surface"
	        guard v2MainSyncWithDeadline({
	            guard let tabId = tabManager.selectedTabId,
	                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
	                result = "ERROR: No tab selected"
	                return
	            }
	
	            guard let panelId = self.resolveSurfaceId(from: surfaceArg, tab: tab),
	                  let bonsplitTabId = tab.surfaceIdFromPanelId(panelId) else {
	                result = "ERROR: Surface not found"
	                return
	            }
	
	            guard let newPaneId = tab.bonsplitController.splitPane(
	                orientation: orientation,
	                movingTab: bonsplitTabId,
	                insertFirst: insertFirst
	            ) else {
	                result = "ERROR: Failed to split pane"
	                return
	            }
	
	            result = "OK \(newPaneId.id.uuidString)"
	        }) != nil else {
	            return "ERROR: main thread did not respond within deadline"
	        }
	        return result
	    }
	
    private func newPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --direction=left|right|up|down --url=...
        var panelType: PanelType = .terminal
        var direction: SplitDirection = .right
        var url: URL? = nil
        var invalidDirection = false

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--direction=") {
                let dirStr = String(partStr.dropFirst(12))
                if let parsed = parseSplitDirection(dirStr) {
                    direction = parsed
                } else {
                    invalidDirection = true
                }
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6))
                url = URL(string: urlStr)
            }
        }

        if invalidDirection {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        if !SurfaceTypeAvailability.isEnabled(panelType) {
            return "ERROR: \(SurfaceTypeAvailability.disabledMessage(for: panelType))"
        }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst

        var result = "ERROR: Failed to create pane"
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: focus
                )?.id
            } else {
                newPanelId = tab.newTerminalSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    focus: focus
                )?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    // MARK: - Option Parsing (sidebar metadata commands)

    private func tokenizeArgs(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private func resolveTabForReport(_ args: String) -> Tab? {
        guard let tabManager else { return nil }
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            if let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    private func resolveTabIdForSidebarMutation(
        reportArgs: String,
        options: [String: String]
    ) -> (tabId: UUID?, error: String?) {
        var tabId: UUID?
        v2MainSync {
            if let tab = resolveTabForReport(reportArgs) {
                tabId = tab.id
            }
        }
        if let tabId {
            return (tabId, nil)
        }
        let error = options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        return (nil, error)
    }

    private func tabForSidebarMutation(id: UUID) -> Tab? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    private func parseSidebarMetadataFormat(_ raw: String) -> SidebarMetadataFormat? {
        switch raw.lowercased() {
        case "plain":
            return .plain
        case "markdown", "md":
            return .markdown
        default:
            return nil
        }
    }

    private func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func schedulePanelMetadataMutation(
        args: String,
        options: [String: String],
        missingPanelUsage: String,
        mutation: @escaping (Tab, UUID) -> Void
    ) -> String {
        let rawPanelArg = options["panel"] ?? options["surface"]
        let surfaceIdFromOptions: UUID?
        if let rawPanelArg {
            if rawPanelArg.isEmpty {
                return "ERROR: Missing panel id — usage: \(missingPanelUsage)"
            }
            guard let surfaceId = UUID(uuidString: rawPanelArg) else {
                return "ERROR: Invalid panel id '\(rawPanelArg)'"
            }
            surfaceIdFromOptions = surfaceId
        } else {
            surfaceIdFromOptions = nil
        }

        if let tabArg = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabArg.isEmpty,
           UUID(uuidString: tabArg) == nil,
           Int(tabArg) == nil {
            return "ERROR: Tab not found"
        }

        if let scope = Self.explicitSocketScope(options: options) {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let tab = self.tabForSidebarMutation(id: scope.workspaceId) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                mutation(tab, scope.panelId)
            }
            return "OK"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let tab = self.resolveTabForReport(args) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard let surfaceId = surfaceIdFromOptions ?? tab.focusedPanelId else { return }
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tab, surfaceId)
        }
        return "OK"
    }

    private func upsertSidebarMetadata(_ args: String, missingError: String) -> String {
        guard tabManager != nil else { return "ERROR: TabManager not available" }
        let parsed = parseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else { return missingError }

        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = normalizedOptionValue(parsed.options["icon"])
        let color = normalizedOptionValue(parsed.options["color"])

        let formatRaw = normalizedOptionValue(parsed.options["format"]) ?? SidebarMetadataFormat.plain.rawValue
        guard let format = parseSidebarMetadataFormat(formatRaw) else {
            return "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown"
        }

        let priority: Int
        if let rawPriority = normalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let parsedURL: URL?
        if let rawURL = normalizedOptionValue(parsed.options["url"] ?? parsed.options["link"]) {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "ERROR: Invalid metadata URL '\(rawURL)' — expected http(s) URL"
            }
            parsedURL = candidate
        } else {
            parsedURL = nil
        }

        let tabResolution = resolveTabIdForSidebarMutation(reportArgs: args, options: parsed.options)
        guard let targetTabId = tabResolution.tabId else {
            return tabResolution.error ?? "ERROR: No tab selected"
        }

        let pidValue: pid_t? = {
            if let rawPid = normalizedOptionValue(parsed.options["pid"]),
               let p = Int32(rawPid), p > 0 {
                return p
            }
            return nil
        }()

        DispatchQueue.main.async { [weak self] in
            guard let self, let tab = self.tabForSidebarMutation(id: targetTabId) else { return }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format
            ) else {
                // Still update PID tracking even if the status display hasn't changed.
                if let pidValue {
                    tab.agentPIDs[key] = pidValue
                }
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format,
                timestamp: Date()
            )
            if let pidValue {
                tab.agentPIDs[key] = pidValue
            }
        }
        return "OK"
    }

    private func clearSidebarMetadata(_ args: String, usage: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata key — usage: \(usage)"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.statusEntries.removeValue(forKey: key) == nil {
                result = "OK (key not found)"
            }
            tab.agentPIDs.removeValue(forKey: key)
        }
        return result
    }

    /// Register an agent PID for stale-session detection without setting a visible status entry.
    /// Usage: set_agent_pid <key> <pid> [--tab=<id>]
    private func setAgentPID(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard parsed.positional.count >= 2,
              let pid = Int32(parsed.positional[1]), pid > 0 else {
            return "ERROR: Usage: set_agent_pid <key> <pid> [--tab=<id>]"
        }
        let key = parsed.positional[0]
        let tabResolution = resolveTabIdForSidebarMutation(reportArgs: args, options: parsed.options)
        guard let targetTabId = tabResolution.tabId else {
            return tabResolution.error ?? "ERROR: No tab selected"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let tab = self.tabForSidebarMutation(id: targetTabId) else { return }
            tab.agentPIDs[key] = pid
        }
        return "OK"
    }

    /// Unregister an agent PID. Usage: clear_agent_pid <key> [--tab=<id>]
    private func clearAgentPID(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first else {
            return "ERROR: Usage: clear_agent_pid <key> [--tab=<id>]"
        }
        // Resolve tab ID synchronously before dispatching to avoid
        // racing against selection changes on the main queue.
        let tabResolution = resolveTabIdForSidebarMutation(reportArgs: args, options: parsed.options)
        guard let targetTabId = tabResolution.tabId else {
            return tabResolution.error ?? "ERROR: No tab selected"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let tab = self.tabForSidebarMutation(id: targetTabId) else { return }
            tab.agentPIDs.removeValue(forKey: key)
        }
        return "OK"
    }

    private func sidebarMetadataLine(_ entry: SidebarStatusEntry) -> String {
        var line = "\(entry.key)=\(entry.value)"
        if let icon = entry.icon { line += " icon=\(icon)" }
        if let color = entry.color { line += " color=\(color)" }
        if let url = entry.url { line += " url=\(url.absoluteString)" }
        if entry.priority != 0 { line += " priority=\(entry.priority)" }
        if entry.format != .plain { line += " format=\(entry.format.rawValue)" }
        return line
    }

    private func listSidebarMetadata(_ args: String, emptyMessage: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            let entries = tab.sidebarStatusEntriesInDisplayOrder()
            if entries.isEmpty {
                result = emptyMessage
                return
            }
            result = entries.map(sidebarMetadataLine).joined(separator: "\n")
        }
        return result
    }

    private func setStatus(_ args: String) -> String {
        upsertSidebarMetadata(
            args,
            missingError: "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]"
        )
    }

    private func reportMeta(_ args: String) -> String {
        upsertSidebarMetadata(
            args,
            missingError: "ERROR: Missing metadata key or value — usage: report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X]"
        )
    }

    private func clearStatus(_ args: String) -> String {
        clearSidebarMetadata(args, usage: "clear_status <key> [--tab=X]")
    }

    private func clearMeta(_ args: String) -> String {
        clearSidebarMetadata(args, usage: "clear_meta <key> [--tab=X]")
    }

    private func listStatus(_ args: String) -> String {
        listSidebarMetadata(args, emptyMessage: "No status entries")
    }

    private func listMeta(_ args: String) -> String {
        listSidebarMetadata(args, emptyMessage: "No metadata entries")
    }

    private func splitMetadataBlockArgs(_ args: String) -> (optionsPart: String, markdownPart: String?) {
        guard let separatorRange = args.range(of: " -- ") else {
            return (args, nil)
        }
        let optionsPart = String(args[..<separatorRange.lowerBound])
        let markdownPart = String(args[separatorRange.upperBound...])
        return (optionsPart, markdownPart)
    }

    private func sidebarMetadataBlockLine(_ block: SidebarMetadataBlock) -> String {
        var line = "\(block.key)=\(block.markdown.replacingOccurrences(of: "\n", with: "\\n"))"
        if block.priority != 0 { line += " priority=\(block.priority)" }
        return line
    }

    private func reportMetaBlock(_ args: String) -> String {
        guard tabManager != nil else { return "ERROR: TabManager not available" }

        let parts = splitMetadataBlockArgs(args)
        let parsed = parseOptionsNoStop(parts.optionsPart)
        guard let key = parsed.positional.first, !key.isEmpty else {
            return "ERROR: Missing metadata block key — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>"
        }

        let markdown: String
        if let raw = parts.markdownPart {
            markdown = raw
        } else if parsed.positional.count >= 2 {
            markdown = parsed.positional.dropFirst().joined(separator: " ")
        } else {
            return "ERROR: Missing metadata markdown — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>"
        }

        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let trimmedMarkdown = normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarkdown.isEmpty else {
            return "ERROR: Missing metadata markdown — usage: report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>"
        }

        let priority: Int
        if let rawPriority = normalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata block priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let tabResolution = resolveTabIdForSidebarMutation(reportArgs: parts.optionsPart, options: parsed.options)
        guard let targetTabId = tabResolution.tabId else {
            return tabResolution.error ?? "ERROR: No tab selected"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let tab = self.tabForSidebarMutation(id: targetTabId) else { return }
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: normalizedMarkdown,
                priority: priority
            ) else {
                return
            }
            tab.metadataBlocks[key] = SidebarMetadataBlock(
                key: key,
                markdown: normalizedMarkdown,
                priority: priority,
                timestamp: Date()
            )
        }
        return "OK"
    }

    private func clearMetaBlock(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata block key — usage: clear_meta_block <key> [--tab=X]"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.metadataBlocks.removeValue(forKey: key) == nil {
                result = "OK (key not found)"
            }
        }
        return result
    }

    private func listMetaBlocks(_ args: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            let blocks = tab.sidebarMetadataBlocksInDisplayOrder()
            if blocks.isEmpty {
                result = "No metadata blocks"
                return
            }
            result = blocks.map(sidebarMetadataBlockLine).joined(separator: "\n")
        }
        return result
    }

    private func appendLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard let level = SidebarLogLevel(rawValue: levelStr) else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
            let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
            let limit = max(1, min(500, configuredLimit))
            if tab.logEntries.count > limit {
                tab.logEntries.removeFirst(tab.logEntries.count - limit)
            }
        }
        return result
    }

    private func clearLog(_ args: String) -> String {
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.logEntries.removeAll()
        }
        return result
    }

    private func listLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        var limit: Int?
        if let limitStr = parsed.options["limit"] {
            if limitStr.isEmpty {
                return "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]"
            }
            guard let parsedLimit = Int(limitStr), parsedLimit >= 0 else {
                return "ERROR: Invalid limit '\(limitStr)' — must be >= 0"
            }
            limit = parsedLimit
        }

        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.logEntries.isEmpty {
                result = "No log entries"
                return
            }
            let entries: [SidebarLogEntry]
            if let limit {
                entries = Array(tab.logEntries.suffix(limit))
            } else {
                entries = tab.logEntries
            }
            result = entries.map { entry in
                var line = "[\(entry.level.rawValue)] \(entry.message)"
                if let source = entry.source, !source.isEmpty {
                    line = "[\(source)] \(line)"
                }
                return line
            }.joined(separator: "\n")
        }
        return result
    }

    private func setProgress(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            tab.progress = SidebarProgressState(value: clamped, label: label)
        }
        return result
    }

    private func clearProgress(_ args: String) -> String {
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.progress = nil
        }
        return result
    }

    private func reportGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let branch = parsed.positional.first else {
            return "ERROR: Missing branch name — usage: report_git_branch <branch> [--status=dirty] [--tab=X]"
        }
        let isDirty = parsed.options["status"]?.lowercased() == "dirty"

        // Shell integration always includes explicit workspace/panel IDs.
        // Keep this telemetry path off-main so wake/main-thread stalls don't
        // block socket handlers and starve subsequent branch updates.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceGitBranch(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    branch: branch,
                    isDirty: isDirty
                )
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            tab.gitBranch = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        }
        return result
    }

    private func clearGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)

        // Shell integration always includes explicit workspace/panel IDs.
        // Keep this telemetry path off-main so wake/main-thread stalls don't
        // block socket handlers and starve subsequent branch updates.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.clearSurfaceGitBranch(tabId: scope.workspaceId, surfaceId: scope.panelId)
            }
            return "OK"
        }
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.gitBranch = nil
        }
        return result
    }

    private func reportPullRequest(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard parsed.positional.count >= 2 else {
            return "ERROR: Missing pull request number or URL — usage: report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--checks=pass|fail|pending] [--tab=X] [--panel=Y]"
        }

        let rawNumber = parsed.positional[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let numberToken = rawNumber.hasPrefix("#") ? String(rawNumber.dropFirst()) : rawNumber
        guard let number = Int(numberToken), number > 0 else {
            return "ERROR: Invalid pull request number '\(rawNumber)'"
        }

        let rawURL = parsed.positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "ERROR: Invalid pull request URL '\(rawURL)'"
        }

        let statusRaw = (parsed.options["state"] ?? "open").lowercased()
        guard let status = SidebarPullRequestStatus(rawValue: statusRaw) else {
            return "ERROR: Invalid pull request state '\(statusRaw)' — use: open, merged, closed"
        }
        let branch = normalizedOptionValue(parsed.options["branch"])

        let checks: SidebarPullRequestChecksStatus?
        if let rawChecks = normalizedOptionValue(parsed.options["checks"]) {
            guard let parsedChecks = SidebarPullRequestChecksStatus(rawValue: rawChecks.lowercased()) else {
                return "ERROR: Invalid pull request checks '\(rawChecks)' — use: pass, fail, pending"
            }
            checks = parsedChecks
        } else {
            checks = nil
        }

        let labelRaw = normalizedOptionValue(parsed.options["label"]) ?? "PR"
        guard !labelRaw.isEmpty else {
            return "ERROR: Invalid review label — usage: report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--checks=pass|fail|pending] [--tab=X] [--panel=Y]"
        }
        let label = String(labelRaw.prefix(16))

        // Shell integration provides explicit workspace/panel UUIDs for browser metadata.
        // Keep this telemetry path off-main so SwiftUI render passes can't deadlock the socket handler.
        return schedulePanelMetadataMutation(
            args: args,
            options: parsed.options,
            missingPanelUsage: "report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--checks=pass|fail|pending] [--tab=X] [--panel=Y]"
        ) { tab, surfaceId in
            guard Self.shouldReplacePullRequest(
                current: tab.panelPullRequests[surfaceId],
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch,
                checks: checks
            ) else {
                return
            }

            tab.updatePanelPullRequest(
                panelId: surfaceId,
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch,
                checks: checks
            )
        }
    }

    private func clearPullRequest(_ args: String) -> String {
        let parsed = parseOptions(args)
        return schedulePanelMetadataMutation(
            args: args,
            options: parsed.options,
            missingPanelUsage: "clear_pr [--tab=X] [--panel=Y]"
        ) { tab, surfaceId in
            tab.clearPanelPullRequest(panelId: surfaceId)
        }
    }

    private func reportPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing ports — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
        }
        var ports: [Int] = []
        for portStr in parsed.positional {
            guard let port = Int(portStr), port > 0, port <= 65535 else {
                return "ERROR: Invalid port '\(portStr)' — must be 1-65535"
            }
            ports.append(port)
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tab.surfaceListeningPorts[surfaceId] = ports
            tab.recomputeListeningPorts()
        }
        return result
    }

    private func reportPwd(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        let directory = parsed.positional.joined(separator: " ")
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceDirectory(tabId: scope.workspaceId, surfaceId: scope.panelId, directory: directory)
            }
            return "OK"
        }
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_pwd <path> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tabManager.updateSurfaceDirectory(tabId: tab.id, surfaceId: surfaceId, directory: directory)
        }
        return result
    }

    private func reportShellState(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let rawState = parsed.positional.first, !rawState.isEmpty else {
            return "ERROR: Missing shell state — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        }
        guard let state = Self.parseReportedShellActivityState(rawState) else {
            return "ERROR: Invalid shell state '\(rawState)' — expected prompt or running"
        }

        if let scope = Self.explicitSocketScope(options: parsed.options) {
            guard Self.socketFastPathState.shouldPublishShellActivity(
                workspaceId: scope.workspaceId,
                panelId: scope.panelId,
                state: state
            ) else {
                return "OK"
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId) else { return }
                tabManager.updateSurfaceShellActivity(tabId: scope.workspaceId, surfaceId: scope.panelId, state: state)
            }
            return "OK"
        }

        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }
        return result
    }

    private func clearPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: clear_ports [--tab=X] [--panel=Y]"
                    return
                }
                guard let surfaceId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                guard validSurfaceIds.contains(surfaceId) else {
                    result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                    return
                }
                tab.surfaceListeningPorts.removeValue(forKey: surfaceId)
            } else {
                tab.surfaceListeningPorts.removeAll()
            }
            tab.recomputeListeningPorts()
        }
        return result
    }

    private func reportTTY(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let ttyName = parsed.positional.first, !ttyName.isEmpty else {
            return "ERROR: Missing tty name — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
        }

        if let scope = Self.explicitSocketScope(options: parsed.options) {
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tab.surfaceTTYNames[scope.panelId] = ttyName
                PortScanner.shared.registerTTY(workspaceId: scope.workspaceId, panelId: scope.panelId, ttyName: ttyName)
                AgentDetector.shared.registerTTY(workspaceId: scope.workspaceId, panelId: scope.panelId, ttyName: ttyName)
                // C11-25 fix DoD #5: install a Sendable PID provider so
                // the per-surface CPU/MEM sampler can attribute usage to
                // the foreground process running on this tty (typically
                // the shell or its most-recently spawned child).
                let capturedTTY = ttyName
                SurfaceMetricsSampler.shared.setPidProvider(surfaceId: scope.panelId) {
                    TerminalPIDResolver.foregroundPID(forTTYName: capturedTTY)
                }
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            let validSurfaceIds = Set(tab.panels.keys)
            guard validSurfaceIds.contains(surfaceId) else {
                result = "ERROR: Panel not found '\(surfaceId.uuidString)'"
                return
            }

            tab.surfaceTTYNames[surfaceId] = ttyName
            PortScanner.shared.registerTTY(workspaceId: tab.id, panelId: surfaceId, ttyName: ttyName)
            AgentDetector.shared.registerTTY(workspaceId: tab.id, panelId: surfaceId, ttyName: ttyName)
            // C11-25 fix DoD #5: install a Sendable PID provider so the
            // per-surface CPU/MEM sampler can attribute usage to the
            // foreground process running on this tty.
            let capturedTTY = ttyName
            SurfaceMetricsSampler.shared.setPidProvider(surfaceId: surfaceId) {
                TerminalPIDResolver.foregroundPID(forTTYName: capturedTTY)
            }
        }
        return result
    }

    private func agentKick(_ args: String) -> String {
        let parsed = parseOptions(args)
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                AgentDetector.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: agent_kick [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            AgentDetector.shared.kick(workspaceId: tab.id, panelId: surfaceId)
        }
        return result
    }

    private func portsKick(_ args: String) -> String {
        let parsed = parseOptions(args)
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                PortScanner.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            }
            return "OK"
        }

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }

            let panelArg = parsed.options["panel"] ?? parsed.options["surface"]
            let surfaceId: UUID
            if let panelArg {
                if panelArg.isEmpty {
                    result = "ERROR: Missing panel id — usage: ports_kick [--tab=X] [--panel=Y]"
                    return
                }
                guard let parsedId = UUID(uuidString: panelArg) else {
                    result = "ERROR: Invalid panel id '\(panelArg)'"
                    return
                }
                surfaceId = parsedId
            } else {
                guard let focused = tab.focusedPanelId else {
                    result = "ERROR: Missing panel id (no focused surface)"
                    return
                }
                surfaceId = focused
            }

            PortScanner.shared.kick(workspaceId: tab.id, panelId: surfaceId)
        }
        return result
    }

    private func sidebarState(_ args: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }

            var lines: [String] = []
            lines.append("tab=\(tab.id.uuidString)")
            lines.append("color=\(tab.customColor ?? "none")")
            lines.append("cwd=\(tab.currentDirectory)")

            if let focused = tab.focusedPanelId,
               let focusedDir = tab.panelDirectories[focused] {
                lines.append("focused_cwd=\(focusedDir)")
                lines.append("focused_panel=\(focused.uuidString)")
            } else {
                lines.append("focused_cwd=unknown")
                lines.append("focused_panel=unknown")
            }

            if let git = tab.gitBranch {
                lines.append("git_branch=\(git.branch)\(git.isDirty ? " dirty" : " clean")")
            } else {
                lines.append("git_branch=none")
            }

            if let pr = tab.sidebarPullRequestsInDisplayOrder().first {
                lines.append("pr=#\(pr.number) \(pr.status.rawValue) \(pr.url.absoluteString)")
                lines.append("pr_label=\(pr.label)")
                lines.append("pr_checks=\(pr.checks?.rawValue ?? "none")")
            } else {
                lines.append("pr=none")
                lines.append("pr_label=none")
                lines.append("pr_checks=none")
            }

            if tab.listeningPorts.isEmpty {
                lines.append("ports=none")
            } else {
                lines.append("ports=\(tab.listeningPorts.map(String.init).joined(separator: ","))")
            }

            if let progress = tab.progress {
                let label = progress.label ?? ""
                lines.append("progress=\(String(format: "%.2f", progress.value)) \(label)".trimmingCharacters(in: .whitespaces))
            } else {
                lines.append("progress=none")
            }

            let statusEntries = tab.sidebarStatusEntriesInDisplayOrder()
            lines.append("status_count=\(statusEntries.count)")
            for entry in statusEntries {
                lines.append("  \(sidebarMetadataLine(entry))")
            }

            let metadataBlocks = tab.sidebarMetadataBlocksInDisplayOrder()
            lines.append("meta_block_count=\(metadataBlocks.count)")
            for block in metadataBlocks {
                lines.append("  \(sidebarMetadataBlockLine(block))")
            }

            // M3 — agent_chip block (derived from focused surface's canonical metadata).
            if let focusedId = tab.focusedPanelId,
               case let (values, sources) = Self.canonicalMetadataSnapshot(
                   workspaceId: tab.id, surfaceId: focusedId),
               let chip = AgentChipResolver.resolve(
                   focusedSurfaceId: focusedId,
                   metadata: values,
                   sources: sources
               ) {
                lines.append("agent_chip=present")
                lines.append("  terminal_type=\(chip.terminalType)")
                lines.append("  model=\(chip.model ?? "none")")
                lines.append("  model_label=\(chip.modelLabel ?? "none")")
                lines.append("  display_label=\(chip.displayLabel ?? "none")")
                lines.append("  icon_asset=\(chip.iconAsset)")
                lines.append("  source_surface_id=\(chip.sourceSurfaceId.uuidString)")
                lines.append("  source_surface_ref=\(v2Ref(kind: .surface, uuid: chip.sourceSurfaceId))")
                lines.append("  source=\(chip.source ?? "none")")
                lines.append("  terminal_type_source=\(chip.terminalTypeSource ?? "none")")
                lines.append("  model_source=\(chip.modelSource ?? "none")")
            } else {
                lines.append("agent_chip=none")
            }

            lines.append("log_count=\(tab.logEntries.count)")
            for entry in tab.logEntries.suffix(5) {
                lines.append("  [\(entry.level.rawValue)] \(entry.message)")
            }

            result = lines.joined(separator: "\n")
        }
        return result
    }

    private func resetSidebar(_ args: String) -> String {
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.resetSidebarContext(reason: "reset_sidebar")
        }
        return result
    }

    private func reloadConfig(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let soft: Bool
        switch trimmed {
        case "", "full":
            soft = false
        case "soft":
            soft = true
        default:
            return "ERROR: Usage: reload_config [soft]"
        }

        v2MainSync {
            GhosttyApp.shared.reloadConfiguration(soft: soft, source: "socket.reload_config")
        }
        return soft ? "OK Reloaded config (soft)" : "OK Reloaded config"
    }

    private func refreshSurfaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var refreshedCount = 0
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Force-refresh all terminal panels in current tab
            // (resets cached metrics so the Metal layer drawable resizes correctly)
            for panel in tab.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.refreshAllTerminalPanels")
                    refreshedCount += 1
                }
            }
        }
        return "OK Refreshed \(refreshedCount) surfaces"
    }

    private func viewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    private func isPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }

    private func surfaceHealth(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let lines = panels.enumerated().map { index, panel -> String in
                let panelId = panel.id.uuidString
                let type = panel.panelType.rawValue
                if let tp = panel as? TerminalPanel {
                    let inWindow = tp.surface.isViewInWindow
                    let portalHosted = isPortalHosted(tp.hostedView)
                    let depth = viewDepth(of: tp.hostedView)
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow) portal=\(portalHosted) view_depth=\(depth)"
                } else if let bp = panel as? BrowserPanel {
                    let inWindow = bp.webView.window != nil
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow)"
                } else {
                    return "\(index): \(panelId) type=\(type) in_window=unknown"
                }
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    private func closeSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: Failed to close surface"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Resolve surface ID from argument or use focused
            let surfaceId: UUID?
            if trimmed.isEmpty {
                surfaceId = tab.focusedPanelId
            } else {
                surfaceId = resolveSurfaceId(from: trimmed, tab: tab)
            }

            guard let targetSurfaceId = surfaceId else {
                result = "ERROR: Surface not found"
                return
            }

            // Don't close if it's the only surface
            if tab.panels.count <= 1 {
                result = "ERROR: Cannot close the last surface"
                return
            }

            // Socket commands must be non-interactive: bypass close-confirmation gating.
            tab.closePanel(targetSurfaceId, force: true)
            result = "OK"
        }
        return result
    }

    private func newSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --pane=<pane_id> --url=...
        var panelType: PanelType = .terminal
        var paneArg: String? = nil
        var url: URL? = nil

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--pane=") {
                paneArg = String(partStr.dropFirst(7))
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6))
                url = URL(string: urlStr)
            }
        }

        if !SurfaceTypeAvailability.isEnabled(panelType) {
            return "ERROR: \(SurfaceTypeAvailability.disabledMessage(for: panelType))"
        }

        var result = "ERROR: Failed to create tab"
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Get target pane
            let paneId: PaneID?
            let paneIds = tab.bonsplitController.allPaneIds
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg) {
                    paneId = paneIds.first(where: { $0.id == uuid })
                } else if let idx = Int(paneArg), idx >= 0, idx < paneIds.count {
                    paneId = paneIds[idx]
                } else {
                    paneId = nil
                }
            } else {
                paneId = tab.bonsplitController.focusedPaneId
            }

            guard let targetPaneId = paneId else {
                result = "ERROR: Pane not found"
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSurface(inPane: targetPaneId, url: url, focus: focus)?.id
            } else {
                newPanelId = tab.newTerminalSurface(inPane: targetPaneId, focus: focus)?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    // MARK: - C11-14 default-agent socket commands

    /// `default_agent get`                              → prints current default agent type
    /// `default_agent set <type>`                       → sets default
    /// `default_agent launch [--agent <type>] [--pane <id>]` → A-button mimic: create
    ///     a new agent surface in the focused (or named) pane
    /// `default_agent launch --in-surface <uuid> [--agent <type>] [--cwd <path>]
    ///     [--prompt "text" | --prompt-file <path>]` → launch into an existing
    ///     surface's PTY; c11 composes the launch line and (for non-claude agents)
    ///     delivers the prompt after a fixed post-launch delay.
    private func defaultAgentCommand(_ args: String) -> String {
        let allTokens = tokenizeArgs(args)
        guard let sub = allTokens.first else {
            return "ERROR: usage: default_agent {get|set <type>|launch [flags]}"
        }

        switch sub {
        case "get":
            return "OK \(DefaultAgentConfigStore.shared.current.defaultAgent.rawValue)"

        case "set":
            guard allTokens.count == 2, let agent = AgentType(rawValue: allTokens[1]) else {
                let valid = AgentType.allCases.map(\.rawValue).joined(separator: ", ")
                return "ERROR: usage: default_agent set <type> — valid types: \(valid)"
            }
            DefaultAgentConfigStore.shared.setDefaultAgent(agent)
            return "OK \(agent.rawValue)"

        case "launch":
            return defaultAgentLaunch(tokens: Array(allTokens.dropFirst()))

        default:
            return "ERROR: unknown subcommand '\(sub)'. usage: default_agent {get|set|launch}"
        }
    }

    /// Parses launch flags and dispatches to the A-button or in-surface path.
    private func defaultAgentLaunch(tokens: [String]) -> String {
        var explicitAgent: AgentType? = nil
        var paneArg: String? = nil
        var inSurfaceArg: String? = nil
        var cwdArg: String? = nil
        var promptArg: String? = nil
        var promptFileArg: String? = nil
        var idx = 0
        while idx < tokens.count {
            let t = tokens[idx]
            if t == "--agent", idx + 1 < tokens.count {
                guard let parsed = AgentType(rawValue: tokens[idx + 1]) else {
                    return "ERROR: unknown agent type: \(tokens[idx + 1])"
                }
                explicitAgent = parsed; idx += 2
            } else if t == "--pane", idx + 1 < tokens.count {
                paneArg = tokens[idx + 1]; idx += 2
            } else if t == "--in-surface", idx + 1 < tokens.count {
                inSurfaceArg = tokens[idx + 1]; idx += 2
            } else if t == "--cwd", idx + 1 < tokens.count {
                cwdArg = tokens[idx + 1]; idx += 2
            } else if t == "--prompt", idx + 1 < tokens.count {
                promptArg = tokens[idx + 1]; idx += 2
            } else if t == "--prompt-file", idx + 1 < tokens.count {
                promptFileArg = tokens[idx + 1]; idx += 2
            } else {
                return "ERROR: unknown flag '\(t)'"
            }
        }

        if paneArg != nil && inSurfaceArg != nil {
            return "ERROR: --pane and --in-surface are mutually exclusive"
        }
        if promptArg != nil && promptFileArg != nil {
            return "ERROR: --prompt and --prompt-file are mutually exclusive"
        }

        // Resolve the prompt content (file wins on --prompt-file path).
        let promptText: String? = {
            if let raw = promptArg, !raw.isEmpty { return raw }
            if let path = promptFileArg {
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return nil
                }
                return contents.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()
        if promptFileArg != nil && promptText == nil {
            return "ERROR: failed to read --prompt-file: \(promptFileArg ?? "")"
        }

        // Resolve the agent config. Use --cwd for project-config lookup when
        // provided; otherwise fall back to the process cwd.
        let lookupCwd = cwdArg ?? FileManager.default.currentDirectoryPath
        let userDefault = DefaultAgentConfigStore.shared.current
        let projectConfig = DefaultAgentProjectConfig.find(from: lookupCwd)
        let resolved = DefaultAgentResolver.resolve(
            explicitAgent: explicitAgent,
            userDefault: userDefault,
            projectConfig: projectConfig
        )
        guard !resolved.launch.bareCommand.isEmpty else {
            return "ERROR: resolved agent has empty command (configure it in Settings → Default Agent)"
        }

        if let inSurfaceArg {
            return launchInExistingSurface(
                surfaceArg: inSurfaceArg,
                agent: resolved.agent,
                bareCommand: resolved.launch.bareCommand,
                cwd: cwdArg,
                prompt: promptText
            )
        } else {
            // A-button mimic: create a new surface in a pane. Prompt args are
            // ignored on this path (the operator's configured initial prompt
            // still flows via launchAgentSurface's existing pre-baking).
            guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
            var result = "ERROR: Failed to launch agent"
            v2MainSync {
                guard let tabId = tabManager.selectedTabId,
                      let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                    return
                }
                let paneIds = tab.bonsplitController.allPaneIds
                let resolvedPane: PaneID?
                if let paneArg {
                    if let uuid = UUID(uuidString: paneArg) {
                        resolvedPane = paneIds.first(where: { $0.id == uuid })
                    } else if let idx = Int(paneArg), idx >= 0, idx < paneIds.count {
                        resolvedPane = paneIds[idx]
                    } else {
                        resolvedPane = nil
                    }
                } else {
                    resolvedPane = tab.bonsplitController.focusedPaneId
                }
                guard let pane = resolvedPane else {
                    result = "ERROR: Pane not found"
                    return
                }
                tab.launchAgentSurface(inPane: pane, explicitAgent: explicitAgent)
                result = "OK"
            }
            return result
        }
    }

    /// Launch into an existing surface's PTY. Composes `[cd <cwd> && ]<launcher>[ <quoted-prompt>]`,
    /// sends it to the surface, and (for non-claude agents with a prompt) schedules
    /// a delayed sendText to deliver the prompt after the agent has booted.
    ///
    /// Resolution parity with `send` (C11-121): the surface ref is resolved the
    /// same way `v2SurfaceSendText` resolves it — `v2RefreshKnownRefs()` is run
    /// first so a `surface:N` handle minted moments earlier by `new-split` is
    /// already in the map, and a freshly-split surface whose PTY has not attached
    /// yet is started in the background and waited on (bounded) before the line is
    /// sent. This closes the two C11-121 races: (1) a `new-split` ref that send
    /// resolves but launch did not, and (2) launch erroring/returning a non-truthful
    /// `OK` while the surface's ghostty PTY was still `nil` (`tty: null`). The
    /// success envelope is only returned once the line has actually been delivered
    /// (or durably queued for flush-on-attach via `sendSubmitFormText`).
    private func launchInExistingSurface(
        surfaceArg: String,
        agent: AgentType,
        bareCommand: String,
        cwd: String?,
        prompt: String?
    ) -> String {
        guard let surfaceId = UUID(uuidString: surfaceArg) else {
            return "ERROR: --in-surface requires a UUID (CLI resolves short refs client-side)"
        }
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let composed = DefaultAgentLaunchComposition.plan(
            agent: agent,
            bareCommand: bareCommand,
            cwd: cwd,
            prompt: prompt
        )

        var result = "ERROR: surface not found: \(surfaceId.uuidString)"
        v2MainSync {
            // Resolve the ref → panel exactly like send does. v2RefreshKnownRefs()
            // guarantees a just-minted `surface:N` handle (e.g. from `new-split`
            // moments earlier) is already in the resolution map, so launch no
            // longer races behind send for a brand-new surface.
            v2RefreshKnownRefs()

            var targetPanel: TerminalPanel?
            for tab in tabManager.tabs {
                if let panel = tab.terminalPanel(for: surfaceId) {
                    targetPanel = panel
                    break
                }
            }
            guard let panel = targetPanel else { return }

            // A freshly-split or background surface may not have attached its
            // ghostty PTY yet (the `tty: null` symptom). Kick the background
            // surface start so the shell actually boots; sendSubmitFormText
            // queues the line and flushes it on attach, so the OK we return is
            // truthful — the line is durably bound to the surface, not dropped.
            if panel.surface.surface == nil {
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
            }

            // sendSubmitFormText types via ghostty_surface_text (bracketed
            // paste) then dispatches a real synthetic Return outside the paste
            // sequence — required for shell line discipline and TUI raw-mode
            // handlers to execute. Falls back to a flush-time submit if the
            // surface is not yet attached to a window.
            panel.surface.sendSubmitFormText(composed.launchLine)
            if let delayedPrompt = composed.delayedPrompt {
                // Post-ready delivery. Fixed 2500ms delay: long enough for
                // codex/opencode/kimi to boot to a prompt on a typical machine,
                // short enough not to feel sluggish. Readiness detection (poll
                // for prompt-string-visible) is a v2 follow-up.
                let delay: DispatchTimeInterval = .milliseconds(2500)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak panel] in
                    panel?.surface.sendSubmitFormText(delayedPrompt)
                }
            }
            result = "OK"
        }
        return result
    }

    /// `agent_config get <type>`                        → prints JSON: { command, initial_prompt, env_overrides }
    /// `agent_config set <type> [--command "..."] [--initial-prompt "..."] [--env-overrides "KEY=val\nKEY=val"] [--reset]`
    private func agentConfigCommand(_ args: String) -> String {
        // Tokenize quoted-args style so multi-word values work.
        let tokens = tokenizeArgs(args)
        guard let sub = tokens.first else {
            return "ERROR: usage: agent_config {get <type>|set <type> [--command \"…\"] [--initial-prompt \"…\"] [--env-overrides \"…\"] [--reset]}"
        }

        switch sub {
        case "get":
            guard tokens.count == 2, let agent = AgentType(rawValue: tokens[1]) else {
                return "ERROR: usage: agent_config get <type>"
            }
            let entry = DefaultAgentConfigStore.shared.current.config(for: agent)
            struct Out: Encodable {
                let command: String
                let initialPrompt: String
                let envOverrides: String
                enum CodingKeys: String, CodingKey {
                    case command, initialPrompt = "initial_prompt", envOverrides = "env_overrides"
                }
            }
            let out = Out(
                command: entry.command,
                initialPrompt: entry.initialPrompt,
                envOverrides: entry.envOverridesText
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(out),
                  let json = String(data: data, encoding: .utf8) else {
                return "ERROR: failed to encode config"
            }
            return "OK \(json)"

        case "set":
            guard tokens.count >= 2, let agent = AgentType(rawValue: tokens[1]) else {
                return "ERROR: usage: agent_config set <type> [flags]"
            }
            var newCommand: String? = nil
            var newPrompt: String? = nil
            var newEnv: String? = nil
            var reset = false
            var i = 2
            while i < tokens.count {
                let t = tokens[i]
                if t == "--command", i + 1 < tokens.count {
                    newCommand = tokens[i + 1]; i += 2
                } else if t == "--initial-prompt", i + 1 < tokens.count {
                    newPrompt = tokens[i + 1]; i += 2
                } else if t == "--env-overrides", i + 1 < tokens.count {
                    newEnv = tokens[i + 1]; i += 2
                } else if t == "--reset" {
                    reset = true; i += 1
                } else {
                    return "ERROR: unknown flag '\(t)'"
                }
            }
            if reset {
                DefaultAgentConfigStore.shared.update(agent) { $0 = .factory(for: agent) }
                return "OK reset"
            }
            DefaultAgentConfigStore.shared.update(agent) { entry in
                if let v = newCommand { entry.command = v }
                if let v = newPrompt { entry.initialPrompt = v }
                if let v = newEnv { entry.envOverridesText = v }
            }
            return "OK"

        default:
            return "ERROR: unknown subcommand '\(sub)'. usage: agent_config {get|set}"
        }
    }

    deinit {
        if let browserDownloadObserver {
            NotificationCenter.default.removeObserver(browserDownloadObserver)
        }
        stop()
    }
}
