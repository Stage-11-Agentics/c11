import AppKit
import Foundation
import UserNotifications
import Bonsplit

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.stage11.c11.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Serialize remove-before-add for one replacement identifier. The removal
    /// calls are synchronous XPC, so returning to main only after both calls
    /// guarantees the newly-added request cannot race ahead and be deleted.
    func replaceNotificationOffMain(
        withIdentifier identifier: String,
        add: @escaping @MainActor () -> Void
    ) {
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: [identifier])
            self.removePendingNotificationRequests(withIdentifiers: [identifier])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { add() }
            }
        }
    }
}

/// The turn-end sound (C11H-319: one of three channels, `NotificationSoundChannel`)
/// and the operator's notification command. Sound values and imported files
/// live in `NotificationSounds.swift`.
enum NotificationSoundSettings {
    static let key = NotificationSoundChannel.turnEnd.defaultsKey
    static let defaultValue = NotificationSoundChannel.turnEnd.shippedDefault.rawValue
    static let customCommandKey = "notificationCustomCommand"
    static let defaultCustomCommand = ""

    /// Plays a choice for the operator in Settings, right after a click.
    static func previewSound(_ choice: NotificationSoundChoice, store: CustomNotificationSoundStore = .shared) {
        switch choice {
        case .systemDefault:
            NSSound.beep()
        case .none:
            break
        case .named(let name):
            let base = (name as NSString).deletingPathExtension
            (NSSound(named: NSSound.Name(base)) ?? NSSound(named: NSSound.Name(name)))?.play()
        case .file(let id):
            NSSound(contentsOf: store.url(for: id), byReference: false)?.play()
        }
    }

    private static let customCommandQueue = DispatchQueue(
        label: "com.stage11.c11.notification-custom-command",
        qos: .utility
    )

    enum CommandKind: String {
        case routine
        case flag
    }

    static func runCustomCommand(
        title: String,
        subtitle: String,
        body: String,
        workspaceId: UUID? = nil,
        surfaceId: UUID? = nil,
        kind: CommandKind = .routine,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        customCommandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = environment ?? ProcessInfo.processInfo.environment
            env["CMUX_NOTIFICATION_TITLE"] = title
            env["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            env["CMUX_NOTIFICATION_BODY"] = body
            // Always overwrite attribution, including absent IDs: a command
            // must never inherit the tab that happened to launch the app.
            for prefix in ["C11", "CMUX"] {
                env["\(prefix)_NOTIFICATION_WORKSPACE_ID"] = workspaceId?.uuidString ?? ""
                env["\(prefix)_NOTIFICATION_PANEL_ID"] = surfaceId?.uuidString ?? ""
                env["\(prefix)_NOTIFICATION_TAB_ID"] = surfaceId?.uuidString ?? ""
                env["\(prefix)_NOTIFICATION_KIND"] = kind.rawValue
            }
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}

enum NotificationAreaRingSettings {
    static let enabledKey = "notificationPaneRingEnabled"
    static let defaultEnabled = true
}

enum NotificationAreaFlashSettings {
    static let enabledKey = "notificationPaneFlashEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}

/// CMUX-10: configurable Flash Duration. Scales both the pane and sidebar
/// envelopes — the sidebar inherits the same temporal pattern and just applies
/// its `peakScale` (commit 3), so a single duration tunes the whole signal.
/// Persisted in UserDefaults under `notificationFlashDurationMs`.
enum NotificationFlashDurationSettings {
    static let storageKey = "notificationFlashDurationMs"
    static let defaultMs: Int = 1500
    static let minMs: Int = 500
    static let maxMs: Int = 4000

    static func currentMs(defaults: UserDefaults = .standard) -> Int {
        if defaults.object(forKey: storageKey) == nil {
            return defaultMs
        }
        let raw = defaults.integer(forKey: storageKey)
        return clamp(raw)
    }

    static func setMs(_ ms: Int, defaults: UserDefaults = .standard) {
        defaults.set(clamp(ms), forKey: storageKey)
    }

    private static func clamp(_ ms: Int) -> Int {
        return min(maxMs, max(minMs, ms))
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

/// C11H-261: where a notification came from. Only an agent's own turn end
/// (Claude's Stop hook, Codex's turn-complete callback) is judged by the
/// waiting check; everything else (`c11 notify`, OSC 9/777, launch failures,
/// an older CLI) is `.other`. C11H-319: an agent stopped on the operator (a
/// permission prompt, a question or plan dialog, an ask) is `.needsYou` and
/// plays the needs-you sound; `.other` and `.turnEnd` play the turn-end sound.
enum TerminalNotificationOrigin: String, Hashable, Sendable {
    case other
    case turnEnd = "turn_end"
    case needsYou = "needs_you"
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    /// Stable external-delivery identity. Routine notification-store records
    /// use their UUID; direct flag alerts use workspace/surface/flag-epoch so
    /// an active reason revision replaces the existing delivered alert.
    let systemIdentifier: String?
    let workspaceId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    /// C11H-246: false when the routine dial is at Quiet (a banner, no sound).
    let deliversSound: Bool
    let origin: TerminalNotificationOrigin

    init(
        id: UUID,
        systemIdentifier: String? = nil,
        workspaceId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        deliversSound: Bool = true,
        origin: TerminalNotificationOrigin = .other
    ) {
        self.deliversSound = deliversSound
        self.origin = origin
        self.id = id
        self.systemIdentifier = systemIdentifier
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    /// The system notification `userInfo`. `tabId` holds the **workspace** id.
    /// The panel is written as `panelId` and, for notifications a pre-1.0 click
    /// handler may still read, as `surfaceId` (same value).
    nonisolated static func userInfo(for notification: TerminalNotification) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "tabId": notification.workspaceId.uuidString,
            "notificationId": notification.id.uuidString,
        ]
        if let surfaceId = notification.surfaceId {
            info["panelId"] = surfaceId.uuidString
            // C11-337: legacy spelling, still written and read forever.
            info["surfaceId"] = surfaceId.uuidString
        }
        return info
    }

    /// The panel id of a delivered notification: `panelId`, falling back to the
    /// legacy `surfaceId` so notifications delivered before the upgrade still open.
    nonisolated static func panelIdString(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["panelId"] as? String) ?? (userInfo["surfaceId"] as? String)
    }

    struct WorkspacePanelKey: Hashable {
        let workspaceId: UUID
        let surfaceId: UUID?
    }

    struct NotificationIndexes {
        var rawUnreadCount = 0
        var rawUnreadCountByWorkspaceId: [UUID: Int] = [:]
        var rawUnreadByWorkspaceSurface = Set<WorkspacePanelKey>()
        var unreadCount = 0
        var unreadCountByWorkspaceId: [UUID: Int] = [:]
        var unreadByWorkspaceSurface = Set<WorkspacePanelKey>()
        var latestUnreadByWorkspaceId: [UUID: TerminalNotification] = [:]
        var latestByWorkspaceId: [UUID: TerminalNotification] = [:]
        /// C11H-261: unread notifications the waiting check judged done. They
        /// would be signal-eligible otherwise; they are not in `unreadCount`.
        var doneUnreadCount = 0
        var doneUnreadCountByWorkspaceId: [UUID: Int] = [:]
        var doneUnreadByWorkspaceSurface = Set<WorkspacePanelKey>()
        /// In `notifications` order (newest first).
        var doneUnread: [TerminalNotification] = []
    }

    static let shared = TerminalNotificationStore(
        systemNotificationsEnabled: defaultSystemNotificationsEnabled()
    )

    private struct DirectFlagDeliveryToken: Equatable {
        let identifier: String
        let generation: UUID
    }

    private struct DirectFlagDelivery {
        let notification: TerminalNotification
        let spec: FlagNotificationSpec
        let sourceHost: String
        let isRevision: Bool
    }

    static let categoryIdentifier = C11Identity.userNotificationCategoryIdentifier
    static let actionShowIdentifier = C11Identity.userNotificationShowActionIdentifier
    private enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            // C11-163: capture the prior per-tab unread counts before the
            // rebuild so waiting-agent edges can be detected (amendment H).
            let previousUnreadByWorkspace = indexes.unreadCountByWorkspaceId
            indexes = Self.buildIndexes(
                for: notifications,
                signalEligible: Self.isAttentionSignalEligible,
                isDone: Self.isJudgedDone
            )
            emitWaitingEdges(previous: previousUnreadByWorkspace, current: indexes.unreadCountByWorkspaceId)
            rebuildAttentionUnreadTail()
        }
    }
    private static let attentionOrderQueue = DispatchQueue(label: "com.stage11.c11.unread-order", qos: .utility)
    private var attentionOrderRevision = 0
    private(set) var attentionUnreadTail: [AttentionOrder.Candidate] = []

    private func rebuildAttentionUnreadTail() {
        attentionOrderRevision += 1
        let revision = attentionOrderRevision
        let notifications = notifications
        Self.attentionOrderQueue.async { [weak self] in
            let facts = notifications.compactMap { notification -> AttentionOrder.UnreadFact? in
                guard !notification.isRead, let panelID = notification.surfaceId else { return nil }
                return .init(target: .init(workspaceID: notification.workspaceId, panelID: panelID),
                             notificationID: notification.id, createdAt: notification.createdAt)
            }
            let tail = AttentionOrder.unreadTail(facts)
            DispatchQueue.main.async {
                guard let self, self.attentionOrderRevision == revision else { return }
                self.attentionUnreadTail = tail
            }
        }
    }
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown
    /// C11H-261: bumped when `refreshSignalEligibility()` changes what counts
    /// as waiting or done without changing `notifications` (a verdict landed,
    /// a flag moved), so observers of `$notifications` alone can re-read.
    @Published private(set) var signalRevision = 0

    /// `UNUserNotificationCenter.current()` requires an application bundle.
    /// Bare c11LogicTests run in a non-app XCTest bundle, where calling it can
    /// trap inside UserNotifications. Keep the real center lazy and unavailable
    /// only for that process shape; hosted tests and the app retain the
    /// production transport.
    private let systemNotificationsEnabled: Bool
    private lazy var center: UNUserNotificationCenter? = {
        guard systemNotificationsEnabled else { return nil }
        return UNUserNotificationCenter.current()
    }()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private var notificationSettingsQAPolicyProvider: () -> QALaunchPolicy = { QALaunchPolicy.current() }
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.scheduleUserNotification(notification)
    }
    /// Current direct-delivery generation per active flag epoch. Reason
    /// revisions keep the deterministic identifier but replace its generation;
    /// lower/close/prune remove the generation before cancellation.
    private var directFlagDeliveryTokens: [String: DirectFlagDeliveryToken] = [:]
    /// Flag alerts this run posted (or found still owned at launch) and has
    /// not removed. Opening a panel checks it first, so focus changes on
    /// unflagged panels do no further work.
    private var postedFlagIdentifiers = Set<String>()
    /// C11H-319: the ask each panel's last needs-you was for. Reading the
    /// notice keeps it; the agent resuming or resolving (a clear) or closing
    /// the panel drops it.
    private var pendingAsks: [WorkspacePanelKey: NeedsYouAsk] = [:]
    /// Sound, source host and panel for each alert that is up, so its removal
    /// record names them (C11H-246 #10).
    private var flagAttributions: [String: FlagNotificationAttribution] = [:]
#if DEBUG
    private var deliveredFlagReaderForTesting:
        ((@escaping ([(String, [AnyHashable: Any])]) -> Void) -> Void)?
    private var operatorLookingProviderForTesting: ((UUID, UUID) -> Bool)?
    private var flagNotificationRecordHandlerForTesting: ((FlagNotificationRecord) -> Void)?
    private var flagNotificationRemovalHandlerForTesting: ((String) -> Void)?
    private var directFlagRequestHandlerForTesting:
        ((_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) -> Void)?
    private var notificationSettingsDefaultsForTesting: UserDefaults?
    private var waitingEdgeHandlerForTesting: ((Bool, UUID) -> Void)?
    private var flagNotificationReplacementHandlerForTesting:
        ((_ identifier: String, _ add: @escaping @MainActor () -> Void) -> Void)?
    private var directFlagAuthorizationHandlerForTesting:
        ((_ completion: @escaping (Bool) -> Void) -> Void)?
    private var directFlagAddHandlerForTesting:
        ((_ notification: TerminalNotification, _ completion: @escaping (Error?) -> Void) -> Void)?
    private var directFlagCustomCommandHandlerForTesting:
        ((_ notification: TerminalNotification) -> Void)?
    private var routineAuthorizationHandlerForTesting:
        ((_ completion: @escaping (Bool) -> Void) -> Void)?
    private var routineAddHandlerForTesting:
        ((_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) -> Void)?
    private var customCommandDefaultsForTesting: UserDefaults?
    private var notificationSoundStoreForTesting: CustomNotificationSoundStore?
    private var flagKindRegistryForTesting: PanelFlagKindRegistry?
    private var routineNotificationRecordHandlerForTesting: ((RoutineNotificationRecord) -> Void)?
#endif
    private var indexes = NotificationIndexes()

    /// C11-163: emit waiting.entered / waiting.left on the per-tab unread
    /// 0↔1 edge. "Agent is waiting" == the tab has an unread notification;
    /// this fires through the single `notifications` didSet, covering every
    /// caller (addNotification / markRead* / markUnread / markAllRead). The
    /// waiting signal is a TEL-6 seam — if the waiting-agent cluster plan
    /// redefines "attention demand", rewire the source here.
    private func emitWaitingEdges(previous: [UUID: Int], current: [UUID: Int]) {
        let workspaces = Set(previous.keys).union(current.keys)
        for workspace in workspaces {
            let before = previous[workspace] ?? 0
            let after = current[workspace] ?? 0
            if before == 0, after > 0 {
                EventEmitter.shared.emitWaiting(entered: true, workspace: workspace, surface: nil)
#if DEBUG
                waitingEdgeHandlerForTesting?(true, workspace)
#endif
            } else if before > 0, after == 0 {
                EventEmitter.shared.emitWaiting(entered: false, workspace: workspace, surface: nil)
#if DEBUG
                waitingEdgeHandlerForTesting?(false, workspace)
#endif
            }
        }
    }

    private init(systemNotificationsEnabled: Bool) {
        self.systemNotificationsEnabled = systemNotificationsEnabled
        indexes = Self.buildIndexes(
            for: notifications, signalEligible: Self.isAttentionSignalEligible, isDone: Self.isJudgedDone)
        if systemNotificationsEnabled {
            refreshAuthorizationStatus()
        }
    }

    static func defaultSystemNotificationsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        let isUnderXCTest = environment["XCTestConfigurationFilePath"] != nil
        let isApplicationBundle = bundleURL.pathExtension == "app"
        return !(isUnderXCTest && !isApplicationBundle)
    }

    var unreadCount: Int {
        indexes.unreadCount
    }

    var rawUnreadCount: Int {
        indexes.rawUnreadCount
    }

    /// C11H-261: unread notifications the waiting check judged done (the Done
    /// button's count). Never counted in `unreadCount`.
    var doneCount: Int {
        indexes.doneUnreadCount
    }

    func doneCount(forWorkspaceId workspaceId: UUID) -> Int {
        indexes.doneUnreadCountByWorkspaceId[workspaceId] ?? 0
    }

    func hasDoneNotification(forWorkspaceId workspaceId: UUID, surfaceId: UUID?) -> Bool {
        indexes.doneUnreadByWorkspaceSurface.contains(WorkspacePanelKey(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    /// Waiting or done: an unread notification the operator has not seen.
    /// Visiting or typing into the panel marks either read.
    func hasPendingNotification(forWorkspaceId workspaceId: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forWorkspaceId: workspaceId, surfaceId: surfaceId)
            || hasDoneNotification(forWorkspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// The oldest unread notification judged done, for the Done button's jump.
    func oldestDoneNotification() -> TerminalNotification? {
        indexes.doneUnread.min { $0.createdAt < $1.createdAt }
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        dlog("notification.auth \(message)")
#endif
        NSLog("notification.auth %@", message)
    }

    private static func authorizationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        guard let center else {
            authorizationState = .unknown
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel)"
                )
            }
        }
    }

    func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _ in }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
    }

    func sendSettingsTestNotification() {
        logAuthorization("settings test tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsTest) { [weak self] authorized in
            guard let self, authorized, let center = self.center else { return }

            let content = UNMutableNotificationContent()
            content.title = "cmux test notification"
            content.body = "Desktop notifications are enabled."
            content.sound = NotificationSoundResolver.routine(
                channel: .turnEnd, defaults: self.notificationSettingsDefaults, store: self.notificationSoundStore
            ).notificationSound
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "cmux.settings.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule test notification: \(error)")
                    self.logAuthorization("settings test schedule failed error=\(error.localizedDescription)")
                } else {
                    self.logAuthorization("settings test schedule succeeded")
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    func unreadCount(forWorkspaceId workspaceId: UUID) -> Int {
        indexes.unreadCountByWorkspaceId[workspaceId] ?? 0
    }

    /// All unread history for this workspace, including suppressed and workspace-scoped entries.
    /// Signal-eligible demand remains available through unreadCount(forWorkspaceId:).
    func rawUnreadCount(forWorkspaceId workspaceId: UUID) -> Int {
        indexes.rawUnreadCountByWorkspaceId[workspaceId] ?? 0
    }

    func hasUnreadNotification(forWorkspaceId workspaceId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByWorkspaceSurface.contains(WorkspacePanelKey(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    /// Exact creation boundary for the signal-eligible unread notification
    /// driving one surface into waiting. Callers use this as tooltip timing
    /// evidence; absence stays nil rather than manufacturing an age.
    func unreadNotificationCreatedAt(forWorkspaceId workspaceId: UUID, surfaceId: UUID) -> Date? {
        notifications.first {
            !$0.isRead
                && $0.workspaceId == workspaceId
                && $0.surfaceId == surfaceId
                && Self.isSignalEligible($0)
        }?.createdAt
    }

    func hasRawUnreadNotification(forWorkspaceId workspaceId: UUID, surfaceId: UUID?) -> Bool {
        indexes.rawUnreadByWorkspaceSurface.contains(WorkspacePanelKey(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func isSignalEligible(_ notification: TerminalNotification) -> Bool {
        Self.isSignalEligible(notification)
    }

    func refreshSignalEligibility() {
        let previous = indexes.unreadCountByWorkspaceId
        let next = Self.buildIndexes(
            for: notifications,
            signalEligible: Self.isAttentionSignalEligible,
            isDone: Self.isJudgedDone
        )
        guard previous != next.unreadCountByWorkspaceId
                || indexes.unreadByWorkspaceSurface != next.unreadByWorkspaceSurface
                || indexes.doneUnreadByWorkspaceSurface != next.doneUnreadByWorkspaceSurface
                || indexes.doneUnread.map(\.id) != next.doneUnread.map(\.id) else {
            indexes = next
            return
        }
        objectWillChange.send()
        indexes = next
        signalRevision &+= 1
        emitWaitingEdges(previous: previous, current: indexes.unreadCountByWorkspaceId)
        for workspaceId in Set(previous.keys).union(indexes.unreadCountByWorkspaceId.keys) {
            AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
                .workspaces.first(where: { $0.id == workspaceId })?
                .syncSurfacePanelActivityStates()
        }
    }

    func latestNotification(forWorkspaceId workspaceId: UUID) -> TerminalNotification? {
        indexes.latestUnreadByWorkspaceId[workspaceId] ?? indexes.latestByWorkspaceId[workspaceId]
    }

    func addNotification(workspaceId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String,
                         origin: TerminalNotificationOrigin = .other, ask: NeedsYouAsk? = nil) {
        // C11H-319: one sound per ask. A Claude ask can arrive twice (the
        // accepted question or plan ask, then Claude's own Notification for
        // it). A repeat (`NeedsYouAsk.repeats`), read or not, posts no banner
        // and no sound; its newer text replaces the record's. Anything else
        // (another request, another session, a second request-less ask, a
        // caller that names none) is a new ask and delivers.
        if origin == .needsYou, let surfaceId, let ask {
            let key = WorkspacePanelKey(workspaceId: workspaceId, surfaceId: surfaceId)
            if let pending = pendingAsks[key], ask.repeats(pending) {
                replaceNeedsYouText(key: key, title: title, subtitle: subtitle, body: body)
                return
            }
            pendingAsks[key] = ask
        }
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.workspaceId == workspaceId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        let isActiveTab = AppDelegate.shared?.workspaceManager?.selectedWorkspaceId == workspaceId
        let focusedSurfaceId = AppDelegate.shared?.workspaceManager?.focusedSurfaceId(for: workspaceId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let attentionSuppressed = surfaceId.map {
            PanelAttentionIndex.shared.snapshot(workspaceId: workspaceId, surfaceId: $0).suppressed
        } ?? false
        // C11H-246: the routine dial. Every stop keeps the record below
        // (Feed, sidebar, waiting edges); it decides only the system banner.
        let delivery = RoutineDeliveryPolicy.decide(
            level: NotificationLevel.current(defaults: notificationSettingsDefaults),
            focusSuppressed: isAppFocused && isFocusedPanel,
            attentionSuppressed: attentionSuppressed
        )

        // An agent notification is a lifecycle boundary: the turn either
        // completed or paused for operator input. Waiting still dominates the
        // card while unread; once the operator opens it, the underlying state
        // must settle to idle instead of snapping back to the outer shell's
        // misleading long-running-TUI "working" state.
        if let surfaceId {
            PanelLivenessDeriver.onAgentLifecycleChanged(
                surfaceId: surfaceId,
                workspaceId: workspaceId,
                activity: .idle
            )
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.workspaceManager?.moveWorkspaceToTopForNotification(workspaceId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(),
            isRead: false,
            deliversSound: delivery != .banner(sound: false),
            origin: origin
        )
        updated.insert(notification, at: 0)
        notifications = updated
        // C11H-261: the only trigger for the waiting check's judgment.
        WaitingCheckJudge.shared.turnEndNotificationAdded(notification)
        if !idsToClear.isEmpty {
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        if case .banner = delivery {
            notificationDeliveryHandler(self, notification)
        }
    }

    /// Direct flag delivery intentionally does not append to `notifications`.
    /// Operator decision: this path pierces suppression and the routine dial;
    /// routine delivery above remains barred for every suppressed surface.
    /// C11H-246: every source builds its request through `FlagNotificationSpec`.
    func deliverFlagNotification(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date,
        title: String?,
        reason: String,
        kind: PanelFlagKind? = nil,
        sourceHost: String? = nil
    ) {
        let spec = FlagNotificationSpec.make(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagRaisedAt: flagRaisedAt,
            title: title,
            reason: reason,
            kind: kind,
            sourceHost: sourceHost ?? Self.localSourceHost,
            defaults: notificationSettingsDefaults,
            kindSound: kind.flatMap { flagKindRegistry.sound(id: $0.id) },
            soundStore: notificationSoundStore
        )
        let identifier = spec.identifier
        let host = spec.sourceHost
        let isRevision = directFlagDeliveryTokens[identifier] != nil || postedFlagIdentifiers.contains(identifier)
        // The one exception: a new raise on the very panel the operator is
        // looking at: the app is active, it is the key window's focused
        // panel, and the operator's own last open named it (focus alone,
        // which an agent can set, never counts). Its banner is on screen; a
        // system alert would only repeat it. A revision never removes an
        // alert already up: only an operator open takes an alert down.
        if !isRevision, lastOperatorOpenPanel == surfaceId,
           operatorIsLookingAt(workspaceId: workspaceId, surfaceId: surfaceId) {
            recordFlagNotification(.init(
                action: .skippedOperatorLooking, cause: .raised, identifier: identifier, attribution: spec.attribution
            ))
            return
        }
        let token = DirectFlagDeliveryToken(identifier: identifier, generation: UUID())
        directFlagDeliveryTokens[identifier] = token
        let notification = TerminalNotification(
            id: UUID(),
            systemIdentifier: identifier,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: spec.title,
            subtitle: spec.subtitle,
            body: spec.body,
            createdAt: Date(),
            isRead: true
        )
        let delivery = DirectFlagDelivery(
            notification: notification, spec: spec, sourceHost: host, isRevision: isRevision
        )
        let add = { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.scheduleDirectFlagNotification(delivery, token: token)
        }
#if DEBUG
        if let replacement = flagNotificationReplacementHandlerForTesting {
            replacement(identifier, add)
            return
        }
#endif
        // `UNUserNotificationCenter.add` replaces pending requests sharing an
        // identifier, but an already-delivered alert is not a pending request.
        // Serialize removal before scheduling the revised active epoch.
        center?.replaceNotificationOffMain(
            withIdentifier: identifier,
            add: add
        )
    }

    static func flagNotificationIdentifier(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date
    ) -> String {
        FlagNotificationSpec.identifier(workspaceId: workspaceId, surfaceId: surfaceId, flagRaisedAt: flagRaisedAt)
    }

    /// The source host recorded for a raise made on this Mac.
    static let localSourceHost = FlagNotificationAttribution.localSourceHost

    func cancelFlagNotification(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date,
        cause: FlagNotificationRecord.Cause = .lowered
    ) {
        let identifier = Self.flagNotificationIdentifier(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagRaisedAt: flagRaisedAt
        )
        // Invalidate before cancellation so a delayed authorization or add
        // completion cannot resurrect delivery after lower/close/prune.
        launchReadCancellations?.insert(identifier)
        let hadDelivery = directFlagDeliveryTokens.removeValue(forKey: identifier) != nil
        let wasPosted = postedFlagIdentifiers.remove(identifier) != nil
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: [identifier])
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: [identifier])
#if DEBUG
        flagNotificationRemovalHandlerForTesting?(identifier)
#endif
        let attribution = flagAttributions.removeValue(forKey: identifier)
            ?? FlagNotificationAttribution.fromIdentifier(identifier)
        if hadDelivery || wasPosted {
            recordFlagNotification(.init(
                action: .removed, cause: cause, identifier: identifier, attribution: attribution
            ))
        }
    }

    /// C11H-246: an explicit operator input opened this panel: a notification
    /// click, a sidebar card or workspace shortcut, a tab click (the tab
    /// already shown included), keyboard panel selection, a click in the
    /// terminal, a panel link, or returning to c11 on its key terminal
    /// window. Its flag alert leaves Notification Center; the flag stays
    /// raised. This is the only way an alert goes besides lower and close: a
    /// focus change alone, whoever caused it, never removes one. Requests
    /// (an agent's socket call) are never an open.
    func dismissFlagNotificationForOperatorOpen(workspaceId: UUID, surfaceId: UUID?) {
        guard let surfaceId, SocketCommandContext.current == nil else { return }
        lastOperatorOpenPanel = surfaceId
        guard !directFlagDeliveryTokens.isEmpty || !postedFlagIdentifiers.isEmpty else { return }
        guard let epoch = PanelAttentionIndex.shared.snapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ).flagRaisedAt else { return }
        let identifier = Self.flagNotificationIdentifier(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagRaisedAt: epoch
        )
        guard directFlagDeliveryTokens[identifier] != nil || postedFlagIdentifiers.contains(identifier) else { return }
        cancelFlagNotification(workspaceId: workspaceId, surfaceId: surfaceId, flagRaisedAt: epoch, cause: .opened)
    }

    /// The panel the operator's last explicit open named; the looking rule
    /// skips a fresh post only for it.
    private(set) var lastOperatorOpenPanel: UUID?

    /// C11H-246 #3: after a launch's restore, keep each delivered flag alert
    /// whose flag is still raised (never re-posting it) and remove every other
    /// flag alert a previous run left behind. The Notification Center read
    /// runs off main and can be slow, so ownership is read on main when it
    /// answers, never from a snapshot taken before it: a flag raised while
    /// the read was in flight keeps its alert. Removals run off main.
    func reconcileDeliveredFlagNotifications(
        raisedIdentifiers: @escaping @MainActor () -> Set<String> = { TerminalNotificationStore.raisedFlagIdentifiers() }
    ) {
        let read: (@escaping ([(String, [AnyHashable: Any])]) -> Void) -> Void
#if DEBUG
        if let hook = deliveredFlagReaderForTesting {
            read = hook
        } else {
            guard let center else { return }
            read = { done in Self.readDelivered(center: center, done) }
        }
#else
        guard let center else { return }
        read = { done in Self.readDelivered(center: center, done) }
#endif
        launchReadCancellations = []
        read { delivered in
            let flags = delivered.filter { FlagNotificationSpec.isFlagIdentifier($0.0) }
            let attributions = Dictionary(flags.map { ($0.0, FlagNotificationAttribution.from(identifier: $0.0, userInfo: $0.1)) },
                                          uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // An alert taken down while the read was out (an operator
                    // open, a lower) is neither adopted nor removed again.
                    let cancelled = self.launchReadCancellations ?? []
                    self.launchReadCancellations = nil
                    // Owned now: raised flags, and anything this run posted
                    // or is still delivering.
                    let owned = raisedIdentifiers()
                        .union(self.postedFlagIdentifiers)
                        .union(self.directFlagDeliveryTokens.keys)
                    let plan = FlagNotificationReconcilePlan.make(
                        delivered: flags.map(\.0).filter { !cancelled.contains($0) },
                        raised: owned
                    )
                    for identifier in plan.keep where self.flagAttributions[identifier] == nil {
                        self.flagAttributions[identifier] = attributions[identifier]
                    }
                    self.postedFlagIdentifiers.formUnion(plan.keep)
                    guard !plan.remove.isEmpty else { return }
                    self.removeStaleFlagNotifications(plan.remove)
                    for identifier in plan.remove {
                        self.recordFlagNotification(.init(
                            action: .removed, cause: .staleAtLaunch, identifier: identifier,
                            attribution: attributions[identifier] ?? .fromIdentifier(identifier)
                        ))
                    }
                }
            }
        }
    }

    /// Identifiers cancelled while the launch read is out; nil otherwise.
    private var launchReadCancellations: Set<String>?

    /// Every raised flag's alert identifier, read now.
    static func raisedFlagIdentifiers() -> Set<String> {
        Set(PanelAttentionIndex.shared.oldestFlags.compactMap { snapshot in
            snapshot.flagRaisedAt.map {
                FlagNotificationSpec.identifier(workspaceId: snapshot.workspaceId, surfaceId: snapshot.surfaceId, flagRaisedAt: $0)
            }
        })
    }

    private nonisolated static func readDelivered(
        center: UNUserNotificationCenter,
        _ done: @escaping ([(String, [AnyHashable: Any])]) -> Void
    ) {
        flagReconcileQueue.async {
            center.getDeliveredNotifications { delivered in
                done(delivered.map { ($0.request.identifier, $0.request.content.userInfo) })
            }
        }
    }

    private func removeStaleFlagNotifications(_ identifiers: [String]) {
#if DEBUG
        if let hook = flagNotificationRemovalHandlerForTesting {
            identifiers.forEach(hook)
        }
#endif
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: identifiers)
    }

    private static let flagReconcileQueue = DispatchQueue(
        label: "com.stage11.c11.flag-notification-reconcile",
        qos: .utility
    )

    private func operatorIsLookingAt(workspaceId: UUID, surfaceId: UUID) -> Bool {
#if DEBUG
        if let provider = operatorLookingProviderForTesting {
            return provider(workspaceId, surfaceId)
        }
#endif
        guard let manager = AppDelegate.shared?.workspaceManager else { return false }
        return FlagPresentationPolicy.operatorIsLooking(
            isAppFocused: AppFocusState.isAppFocused(),
            selectedWorkspaceId: manager.selectedWorkspaceId,
            focusedSurfaceId: manager.focusedSurfaceId(for: workspaceId),
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    private func recordFlagNotification(_ record: FlagNotificationRecord) {
        NSLog("%@", record.logLine)
        EventEmitter.shared.emitNotificationFlag(
            workspace: record.workspaceId,
            surface: record.surfaceId,
            payload: record.payload
        )
#if DEBUG
        flagNotificationRecordHandlerForTesting?(record)
#endif
    }

    /// C11H-246: the dispatcher's one call for every envelope it delivers to
    /// an inbox, on its own queue. Reads the dial off main and hops to main
    /// only at Chatty.
    nonisolated static func noteMailDelivered(workspaceId: UUID, surfaceId: UUID?, recipient: String, sender: String) {
        guard RoutineDeliveryPolicy.deliversMail(level: NotificationLevel.current(defaults: mailLevelDefaults)) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TerminalNotificationStore.shared.deliverChattyMailBanner(
                    workspaceId: workspaceId, surfaceId: surfaceId, recipient: recipient, sender: sender
                )
            }
        }
    }

    /// Where the dispatcher's off-main pre-check reads the dial; tests point
    /// it at their own suite.
    nonisolated(unsafe) static var mailLevelDefaults: UserDefaults = .standard

    /// C11H-246: Chatty's mail banner. It keeps no store record, so it
    /// changes no waiting, unread or liveness state; the Feed and the mailbox
    /// cell already show the mail. Skipped while the operator is looking at
    /// the recipient panel, and when the dial left Chatty before this ran.
    func deliverChattyMailBanner(workspaceId: UUID, surfaceId: UUID?, recipient: String, sender: String) {
        guard RoutineDeliveryPolicy.deliversMail(
            level: NotificationLevel.current(defaults: notificationSettingsDefaults)
        ) else { return }
        if let surfaceId, operatorIsLookingAt(workspaceId: workspaceId, surfaceId: surfaceId) { return }
        let title = String(
            format: String(localized: "notification.chattyMail.title", defaultValue: "Mail for %@"),
            recipient
        )
        let body = sender.isEmpty ? "" : String(
            format: String(localized: "notification.chattyMail.body", defaultValue: "From %@"),
            sender
        )
        let notification = TerminalNotification(
            id: UUID(),
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: title,
            subtitle: "",
            body: body,
            createdAt: Date(),
            isRead: true
        )
        notificationDeliveryHandler(self, notification)
    }

    func cancelRoutineExternalNotifications(workspaceId: UUID, surfaceId: UUID) {
        let identifiers = notifications.compactMap { notification in
            notification.workspaceId == workspaceId && notification.surfaceId == surfaceId
                ? notification.id.uuidString
                : nil
        }
        guard !identifiers.isEmpty else { return }
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: identifiers)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: identifiers)
    }

    func markRead(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        updated[index].isRead = true
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func markRead(forWorkspaceId workspaceId: UUID) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].workspaceId == workspaceId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forWorkspaceId workspaceId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].workspaceId == workspaceId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forWorkspaceId workspaceId: UUID) {
        var updated = notifications
        var didChange = false
        var marked = Set<UUID>()
        for index in updated.indices where updated[index].workspaceId == workspaceId {
            marked.insert(updated[index].id)
            if updated[index].isRead {
                updated[index].isRead = false
                didChange = true
            }
        }
        // C11H-261: the operator asked for these back; no verdict hides them,
        // including a done one that was still unread.
        let droppedVerdict = WaitingCheckJudge.operatorMarkedUnread(
            marked, live: Set(updated.map(\.id)))
        if didChange {
            notifications = updated
        } else if droppedVerdict {
            refreshSignalEligibility()
        }
    }

    func markAllRead() {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    /// The held-back repeat of an ask: its text replaces the panel's needs-you
    /// record, which keeps its id, time and read state. No banner, no sound.
    private func replaceNeedsYouText(key: WorkspacePanelKey, title: String, subtitle: String, body: String) {
        guard let index = notifications.firstIndex(where: {
            $0.workspaceId == key.workspaceId && $0.surfaceId == key.surfaceId && $0.origin == .needsYou
        }) else { return }
        let old = notifications[index]
        guard old.title != title || old.subtitle != subtitle || old.body != body else { return }
        var updated = notifications
        updated[index] = TerminalNotification(
            id: old.id, systemIdentifier: old.systemIdentifier, workspaceId: old.workspaceId, surfaceId: old.surfaceId,
            title: title, subtitle: subtitle, body: body, createdAt: old.createdAt, isRead: old.isRead,
            deliversSound: old.deliversSound, origin: old.origin
        )
        notifications = updated
    }

    func clearAll() {
        pendingAsks.removeAll()
        guard !notifications.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(forWorkspaceId workspaceId: UUID, surfaceId: UUID?) {
        // The agent resumed or resolved its ask (Claude's hooks clear here).
        pendingAsks.removeValue(forKey: WorkspacePanelKey(workspaceId: workspaceId, surfaceId: surfaceId))
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.workspaceId == workspaceId, notification.surfaceId == surfaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    func clearNotifications(forWorkspaceId workspaceId: UUID) {
        pendingAsks = pendingAsks.filter { $0.key.workspaceId != workspaceId }
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.workspaceId == workspaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    /// Remove raw history for surfaces no longer present in a workspace.
    /// Surface-less workspace notifications remain valid and are retained.
    func clearNotifications(forWorkspaceId workspaceId: UUID, excludingSurfaceIds validSurfaceIds: Set<UUID>) {
        pendingAsks = pendingAsks.filter { key, _ in
            key.workspaceId != workspaceId || key.surfaceId.map(validSurfaceIds.contains) ?? true
        }
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.workspaceId == workspaceId,
               let surfaceId = notification.surfaceId,
               !validSurfaceIds.contains(surfaceId) {
                idsToClear.append(notification.systemIdentifier ?? notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        let commandDefaults = notificationCustomCommandDefaults
        // C11H-319: the notification's channel decides its sound; Quiet
        // (deliversSound false) posts the banner with none.
        let channel = NotificationSoundChannel.routine(for: notification.origin)
        let sound = notification.deliversSound
            ? NotificationSoundResolver.routine(
                channel: channel, defaults: notificationSettingsDefaults, store: notificationSoundStore
            )
            : NotificationSoundResolution.quiet
        requestRoutineAuthorization { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "cmux"
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = sound.notificationSound
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = Self.userInfo(for: notification)

            let request = UNNotificationRequest(
                identifier: notification.systemIdentifier ?? notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.addRoutineNotification(request) { error in
                // The completion arrives on Notification Center's queue.
                let record = RoutineNotificationRecord(
                    action: error == nil ? .posted : .failed,
                    channel: channel,
                    identifier: request.identifier,
                    workspaceId: notification.workspaceId,
                    surfaceId: notification.surfaceId,
                    sound: sound
                )
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.recordRoutineNotification(record) }
                }
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                } else {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body,
                        workspaceId: notification.workspaceId,
                        surfaceId: notification.surfaceId,
                        kind: .routine,
                        defaults: commandDefaults
                    )
                }
            }
        }
    }

    private var notificationCustomCommandDefaults: UserDefaults {
#if DEBUG
        if let defaults = customCommandDefaultsForTesting { return defaults }
#endif
        return .standard
    }

    /// The flag sound and the routine level are read at each delivery, so a
    /// change in Settings or `notify-level` takes effect on the next one.
    private var notificationSettingsDefaults: UserDefaults {
#if DEBUG
        if let defaults = notificationSettingsDefaultsForTesting { return defaults }
#endif
        return .standard
    }

    /// C11H-319: imported sound files.
    private var notificationSoundStore: CustomNotificationSoundStore {
#if DEBUG
        if let store = notificationSoundStoreForTesting { return store }
#endif
        return .shared
    }

    /// C11H-319: where a flag kind's sound is read, at each delivery.
    private var flagKindRegistry: PanelFlagKindRegistry {
#if DEBUG
        if let registry = flagKindRegistryForTesting { return registry }
#endif
        return .shared
    }

    private func recordRoutineNotification(_ record: RoutineNotificationRecord) {
        NSLog("%@", record.logLine)
        EventEmitter.shared.emitNotificationRoutine(
            workspace: record.workspaceId,
            surface: record.surfaceId,
            payload: record.payload
        )
#if DEBUG
        routineNotificationRecordHandlerForTesting?(record)
#endif
    }

    private func requestRoutineAuthorization(_ completion: @escaping (Bool) -> Void) {
#if DEBUG
        if let handler = routineAuthorizationHandlerForTesting {
            handler(completion)
            return
        }
#endif
        ensureAuthorization(origin: .notificationDelivery, completion)
    }

    private func addRoutineNotification(
        _ request: UNNotificationRequest,
        completion: @escaping (Error?) -> Void
    ) {
#if DEBUG
        if let handler = routineAddHandlerForTesting {
            handler(request, completion)
            return
        }
#endif
        guard let center else {
            completion(NSError(domain: "com.stage11.c11.notifications", code: 1))
            return
        }
        center.add(request, withCompletionHandler: completion)
    }

    /// Direct flag delivery has a separate generation guard from routine
    /// notifications. Authorization can resume long after the flag changed;
    /// both that boundary and the add completion must observe the same current
    /// generation before producing an external side effect.
    private func scheduleDirectFlagNotification(
        _ delivery: DirectFlagDelivery,
        token: DirectFlagDeliveryToken
    ) {
        guard isCurrent(token) else { return }
        requestDirectFlagAuthorization { [weak self] authorized in
            guard let self, authorized, self.isCurrent(token) else { return }
            self.addDirectFlagNotification(delivery) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let spec = delivery.spec
                    if let error {
                        NSLog("Failed to schedule direct flag notification: \(error)")
                        self.recordFlagNotification(.init(
                            action: .failed, cause: delivery.isRevision ? .revised : .raised,
                            identifier: spec.identifier, attribution: spec.attribution
                        ))
                        return
                    }
                    // Never remove a revision's alert here: an old same-identifier
                    // completion may arrive after a newer revision was added.
                    // But an add that lands after its flag was cancelled (no
                    // generation at all for this identifier) left an alert
                    // nothing owns; take it down now.
                    guard self.isCurrent(token) else {
                        if self.directFlagDeliveryTokens[spec.identifier] == nil,
                           !self.postedFlagIdentifiers.contains(spec.identifier) {
                            self.removeStaleFlagNotifications([spec.identifier])
                            self.center?.removePendingNotificationRequestsOffMain(withIdentifiers: [spec.identifier])
                        }
                        return
                    }
                    self.postedFlagIdentifiers.insert(spec.identifier)
                    self.flagAttributions[spec.identifier] = spec.attribution
                    self.recordFlagNotification(.init(
                        action: delivery.isRevision ? .replaced : .posted,
                        cause: delivery.isRevision ? .revised : .raised,
                        identifier: spec.identifier, attribution: spec.attribution
                    ))
                    self.runDirectFlagCustomCommand(delivery.notification)
                }
            }
        }
    }

    private func isCurrent(_ token: DirectFlagDeliveryToken) -> Bool {
        directFlagDeliveryTokens[token.identifier] == token
    }

    private func requestDirectFlagAuthorization(
        _ completion: @escaping (Bool) -> Void
    ) {
#if DEBUG
        if let handler = directFlagAuthorizationHandlerForTesting {
            handler(completion)
            return
        }
#endif
        ensureAuthorization(origin: .notificationDelivery, completion)
    }

    private func addDirectFlagNotification(
        _ delivery: DirectFlagDelivery,
        completion: @escaping (Error?) -> Void
    ) {
#if DEBUG
        if let handler = directFlagAddHandlerForTesting {
            handler(delivery.notification, completion)
            return
        }
#endif
        let request = delivery.spec.request(appName: Self.appName, categoryIdentifier: Self.categoryIdentifier)
#if DEBUG
        if let handler = directFlagRequestHandlerForTesting {
            handler(request, completion)
            return
        }
#endif
        guard let center else {
            completion(
                NSError(
                    domain: "com.stage11.c11.notifications",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "System notification center unavailable"]
                )
            )
            return
        }
        center.add(request, withCompletionHandler: completion)
    }

    nonisolated static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "c11"
    }

    private func runDirectFlagCustomCommand(_ notification: TerminalNotification) {
#if DEBUG
        if let handler = directFlagCustomCommandHandlerForTesting {
            handler(notification)
            return
        }
#endif
        NotificationSoundSettings.runCustomCommand(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            workspaceId: notification.workspaceId,
            surfaceId: notification.surfaceId,
            kind: .flag,
            defaults: notificationCustomCommandDefaults
        )
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        logAuthorization("ensure start origin=\(origin.rawValue)")
        guard let center else {
            completion(false)
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
                )
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .denied:
                    self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                    self.promptToEnableNotifications()
                    completion(false)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        guard let center else {
            completion(false)
            return
        }
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ) else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                self.logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=\(error?.localizedDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                )
                completion(granted)
            }
        }
    }

    private func promptToEnableNotifications() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Same QA gate as the Agent Skills sheet and the resume picker.
            // Reads C11_QA_LAUNCH for this launch only; writes nothing.
            guard Self.shouldPresentNotificationSettingsPrompt(
                qa: self.notificationSettingsQAPolicyProvider(),
                hasPromptedForSettings: self.hasPromptedForSettings
            ) else {
                return
            }
            self.logAuthorization("prompt settings shown")
            self.hasPromptedForSettings = true
            self.presentNotificationSettingsPrompt(attempt: 0)
        }
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for c11")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are off for c11. Enable them in System Settings so c11 can ring you when an area needs attention.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    /// Whether to present the "Turn on notifications for c11" sheet.
    ///
    /// An ordinary launch presents it once, after notifications are already
    /// off. `C11_QA_LAUNCH` / `CMUX_QA_LAUNCH` (`fresh`, `resume`, or any
    /// other non-empty value) suppresses it. Unset or blank leaves today's
    /// behaviour. This decision writes no UserDefaults and does not change
    /// notification settings.
    nonisolated static func shouldPresentNotificationSettingsPrompt(
        qa: QALaunchPolicy,
        hasPromptedForSettings: Bool
    ) -> Bool {
        guard !hasPromptedForSettings else { return false }
        guard !qa.isActive else { return false }
        return true
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

    /// Signal-eligible demand: the attention snapshot allows it and the
    /// waiting check has not judged it done (C11H-261).
    private static func isSignalEligible(_ notification: TerminalNotification) -> Bool {
        isAttentionSignalEligible(notification) && !isJudgedDone(notification)
    }

    private static func isAttentionSignalEligible(_ notification: TerminalNotification) -> Bool {
        guard let surfaceId = notification.surfaceId else { return true }
        return PanelAttentionIndex.shared.snapshot(
            workspaceId: notification.workspaceId,
            surfaceId: surfaceId
        ).isSignalEligible
    }

    private static func isJudgedDone(_ notification: TerminalNotification) -> Bool {
        WaitingCheckJudge.isDone(notification.id)
    }

    /// `signalEligible` is the attention rule; an eligible unread notification
    /// for which `isDone` holds is counted as done instead of unread.
    static func buildIndexes(
        for notifications: [TerminalNotification],
        signalEligible: (TerminalNotification) -> Bool,
        isDone: (TerminalNotification) -> Bool = { _ in false }
    ) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByWorkspaceId[notification.workspaceId] == nil {
                indexes.latestByWorkspaceId[notification.workspaceId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.rawUnreadCount += 1
            indexes.rawUnreadCountByWorkspaceId[notification.workspaceId, default: 0] += 1
            indexes.rawUnreadByWorkspaceSurface.insert(
                WorkspacePanelKey(workspaceId: notification.workspaceId, surfaceId: notification.surfaceId)
            )
            guard signalEligible(notification) else { continue }
            if isDone(notification) {
                indexes.doneUnreadCount += 1
                indexes.doneUnreadCountByWorkspaceId[notification.workspaceId, default: 0] += 1
                indexes.doneUnreadByWorkspaceSurface.insert(
                    WorkspacePanelKey(workspaceId: notification.workspaceId, surfaceId: notification.surfaceId)
                )
                indexes.doneUnread.append(notification)
                continue
            }
            indexes.unreadCount += 1
            indexes.unreadCountByWorkspaceId[notification.workspaceId, default: 0] += 1
            indexes.unreadByWorkspaceSurface.insert(
                WorkspacePanelKey(workspaceId: notification.workspaceId, surfaceId: notification.surfaceId)
            )
            if indexes.latestUnreadByWorkspaceId[notification.workspaceId] == nil {
                indexes.latestUnreadByWorkspaceId[notification.workspaceId] = notification
            }
        }
        return indexes
    }

#if DEBUG
    static func makeForNotificationCommandTesting() -> TerminalNotificationStore {
        TerminalNotificationStore(systemNotificationsEnabled: false)
    }

    func configureRoutineNotificationDeliveryHooksForTesting(
        authorization: @escaping (_ completion: @escaping (Bool) -> Void) -> Void,
        add: @escaping (_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) -> Void
    ) {
        routineAuthorizationHandlerForTesting = authorization
        routineAddHandlerForTesting = add
    }

    func configureNotificationCustomCommandDefaultsForTesting(_ defaults: UserDefaults) {
        customCommandDefaultsForTesting = defaults
    }

    func scheduleUserNotificationForTesting(_ notification: TerminalNotification) {
        scheduleUserNotification(notification)
    }

    /// C11H-319: imported sounds from a scratch store, kind sounds from a
    /// scratch registry, and every routine record.
    func configureNotificationSoundsForTesting(
        store: CustomNotificationSoundStore?,
        registry: PanelFlagKindRegistry?,
        routineRecord: ((RoutineNotificationRecord) -> Void)? = nil
    ) {
        notificationSoundStoreForTesting = store
        flagKindRegistryForTesting = registry
        routineNotificationRecordHandlerForTesting = routineRecord
    }

    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void,
        qaPolicyProvider: @escaping () -> QALaunchPolicy = { QALaunchPolicy.current() }
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        notificationSettingsQAPolicyProvider = qaPolicyProvider
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        notificationSettingsQAPolicyProvider = { QALaunchPolicy.current() }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification in
            store.scheduleUserNotification(notification)
        }
    }

    func configureWaitingEdgeHandlerForTesting(_ handler: @escaping (Bool, UUID) -> Void) {
        waitingEdgeHandlerForTesting = handler
    }

    func resetWaitingEdgeHandlerForTesting() {
        waitingEdgeHandlerForTesting = nil
    }

    func configureFlagNotificationReplacementHandlerForTesting(
        _ handler: @escaping (
            _ identifier: String,
            _ add: @escaping @MainActor () -> Void
        ) -> Void
    ) {
        flagNotificationReplacementHandlerForTesting = handler
    }

    func resetFlagNotificationReplacementHandlerForTesting() {
        flagNotificationReplacementHandlerForTesting = nil
    }

    func configureDirectFlagAuthorizationHandlerForTesting(
        _ handler: @escaping (_ completion: @escaping (Bool) -> Void) -> Void
    ) {
        directFlagAuthorizationHandlerForTesting = handler
    }

    func configureDirectFlagAddHandlerForTesting(
        _ handler: @escaping (
            _ notification: TerminalNotification,
            _ completion: @escaping (Error?) -> Void
        ) -> Void
    ) {
        directFlagAddHandlerForTesting = handler
    }

    func configureDirectFlagCustomCommandHandlerForTesting(
        _ handler: @escaping (_ notification: TerminalNotification) -> Void
    ) {
        directFlagCustomCommandHandlerForTesting = handler
    }

    func resetDirectFlagDeliveryHandlersForTesting() {
        directFlagAuthorizationHandlerForTesting = nil
        directFlagAddHandlerForTesting = nil
        directFlagCustomCommandHandlerForTesting = nil
        directFlagRequestHandlerForTesting = nil
        operatorLookingProviderForTesting = nil
        flagNotificationRecordHandlerForTesting = nil
        flagNotificationRemovalHandlerForTesting = nil
        notificationSettingsDefaultsForTesting = nil
        directFlagDeliveryTokens.removeAll()
        postedFlagIdentifiers.removeAll()
        lastOperatorOpenPanel = nil
        launchReadCancellations = nil
        flagAttributions.removeAll()
        deliveredFlagReaderForTesting = nil
    }

    /// C11H-246 #3: stand in for Notification Center's delivered read.
    func configureDeliveredFlagReaderForTesting(
        _ reader: @escaping (@escaping ([(String, [AnyHashable: Any])]) -> Void) -> Void
    ) {
        deliveredFlagReaderForTesting = reader
    }

    /// C11H-246: capture the built flag request, every removal, and every
    /// record; decide "the operator is looking"; read settings from a suite.
    func configureFlagNotificationObservationForTesting(
        request: @escaping (_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) -> Void,
        removal: @escaping (String) -> Void,
        record: @escaping (FlagNotificationRecord) -> Void,
        operatorLooking: @escaping (UUID, UUID) -> Bool = { _, _ in false },
        settings: UserDefaults? = nil
    ) {
        directFlagRequestHandlerForTesting = request
        flagNotificationRemovalHandlerForTesting = removal
        flagNotificationRecordHandlerForTesting = record
        operatorLookingProviderForTesting = operatorLooking
        notificationSettingsDefaultsForTesting = settings
    }

    func configureNotificationSettingsDefaultsForTesting(_ defaults: UserDefaults?) {
        notificationSettingsDefaultsForTesting = defaults
    }

    func postedFlagIdentifiersForTesting() -> Set<String> {
        postedFlagIdentifiers
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        self.notifications = notifications
    }
#endif

}
