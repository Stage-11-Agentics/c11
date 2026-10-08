import Foundation
import Darwin


/// Cached local-only recording policy. UserDefaults is consulted at launch and
/// on changes, never by the hot emission path. The full switch is defaults-only.
struct ActivityHistoryPolicy: Equatable {
    static let enabledKey = "c11.activityHistory.enabled"
    static let analyticsEnabledKey = "c11.activityHistory.analyticsEnabled"
    static let keepTextKey = "c11.activityHistory.keepText"
    static let retentionDaysKey = "c11.activityHistory.retentionDays"
    var enabled = true
    var analyticsEnabled = true
    var keepText = true
    var retentionDays = 14

    init(enabled: Bool = true, analyticsEnabled: Bool = true, keepText: Bool = true, retentionDays: Int = 14) {
        self.enabled = enabled
        self.analyticsEnabled = analyticsEnabled
        self.keepText = keepText
        self.retentionDays = [7, 14, 30].contains(retentionDays) ? retentionDays : 14
    }

    init(defaults: UserDefaults) {
        self.init(enabled: defaults.object(forKey: Self.enabledKey) as? Bool ?? true,
                  analyticsEnabled: defaults.object(forKey: Self.analyticsEnabledKey) as? Bool ?? true,
                  keepText: defaults.object(forKey: Self.keepTextKey) as? Bool ?? true,
                  retentionDays: defaults.object(forKey: Self.retentionDaysKey) as? Int ?? 14)
    }
}

/// One kernel query, off-main, for all three health fields. No panel census or
/// transcript work is performed by the app. CPU is cumulative process seconds.
enum ActivityHistoryMetrics {
    static func sample() -> [String: Any] {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let read = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard read == Int32(size) else { return [:] }
        return ["rss_mb": Double(info.pti_resident_size) / 1_048_576,
                "cpu_s_total": Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000,
                "threads": Int(info.pti_threadnum)]
    }
}

/// Process-wide facade for the c11 events stream (C11-163). `EventEmitter.shared`
/// is callable from **any** thread — main-actor emit sites (surface create/close,
/// workspace select, waiting edges) and off-main queues (metadata stores, the
/// mailbox dispatcher) alike. The underlying `EventLog` owns all threading, so
/// emitting is a cheap envelope build + a fire-and-forget `append`; no emit site
/// ever blocks and none needs to hop threads.
///
/// Initialize eagerly and early via `start()` (from `applicationDidFinishLaunching`,
/// on main) so the first-use state-dir resolution + `log.opened` marker land
/// before any surface-creation or metadata path can emit (amendment K). Calls
/// before `start()`, or when disabled, are silent no-ops.
final class EventEmitter {

    static let shared = EventEmitter()

    /// Canonical metadata keys that produce a `metadata.changed` event in v1.
    /// `progress` is deliberately excluded — it is the highest-frequency
    /// canonical key and would flood the stream (amendment G); it can be added
    /// later behind explicit coalescing. Matches the SPEC EVT-2 named set
    /// (status/title/description) minus progress.
    static let canonicalMetadataEventKeys: Set<String> = ["status", "title", "description"]

    /// C11-257: event payloads retain the first 256 KiB of text. The byte cap
    /// is applied before JSON serialization and never splits a UTF-8 scalar.
    static let maxRecordedTextBytes = 256 * 1024

    private let lock = NSLock()
    private var log: EventLog?
    private var instanceId: String = ""
    private var enabled = false
    private var policy = ActivityHistoryPolicy()
    private var defaultsObserver: NSObjectProtocol?
    private var appActive: Bool?
    private var screenLocked: Bool?
    private var sleeping: Bool?

    private init() {}

    // MARK: - Lifecycle

    /// Resolves the per-instance log path, mints the instance id, opens the log,
    /// and writes the `log.opened` marker. Idempotent; safe to call once on main
    /// at launch. Disabled under XCTest (host suites must not write real logs)
    /// unless a test injected a log via `startForTesting`.
    func start() {
        lock.lock()
        if enabled || log != nil {
            lock.unlock()
            return
        }
        if Self.isRunningUnderXCTest() {
            lock.unlock()
            return
        }
        lock.unlock()

        // Resolve outside the lock — StateDirectoryMigration does disk I/O.
        guard let state = try? EventLogLayout.defaultStateURL() else { return }
        let instance = EventLogLayout.makeInstanceId()
        let url = EventLogLayout.logURL(state: state, instance: instance)
        let newLog = EventLog(url: url, instance: instance)

        lock.lock()
        guard log == nil else { lock.unlock(); return }
        log = newLog
        instanceId = instance
        policy = ActivityHistoryPolicy(defaults: .standard)
        enabled = policy.enabled
        let initialPolicy = policy
        lock.unlock()

        newLog.updatePolicy(initialPolicy)
        if initialPolicy.enabled {
            newLog.open()
            emit(.logPolicy, payload: Self.policyPayload(initialPolicy))
        }
        newLog.startSampling { [weak self] in self?.sampleEnvelope() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.reloadPolicy() }
    }

    /// Test seam: install a caller-provided log + instance and enable emission.
    func startForTesting(log: EventLog, instance: String) {
        lock.lock()
        self.log = log
        self.instanceId = instance
        self.enabled = true
        self.policy = ActivityHistoryPolicy()
        self.appActive = nil
        self.screenLocked = nil
        self.sleeping = nil
        lock.unlock()
    }

    /// Test seam: tear down so the next `startForTesting` starts clean.
    func resetForTesting() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        currentLog()?.stopSampling()
        lock.lock()
        appActive = nil
        screenLocked = nil
        sleeping = nil
        policy = ActivityHistoryPolicy()
        log = nil
        instanceId = ""
        enabled = false
        lock.unlock()
    }

    /// Instance id of the log this process is writing, or nil before `start()`
    /// and whenever recording is off. Feed watch binds to this id, not newest-mtime.
    func currentInstance() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !instanceId.isEmpty else { return nil }
        return instanceId
    }

    /// Whether emits currently reach a log (false before `start()`, when
    /// disabled, and under XCTest without an injected log).
    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && log != nil
    }

    var keepText: Bool {
        lock.lock()
        defer { lock.unlock() }
        return policy.keepText
    }

    /// Flush the underlying log (tests / shutdown).
    func flush() {
        currentLog()?.flush()
    }

    func reloadPolicy(defaults: UserDefaults = .standard) {
        updatePolicy(ActivityHistoryPolicy(defaults: defaults))
    }

    private static func policyPayload(_ policy: ActivityHistoryPolicy) -> [String: Any] {
        ["enabled": policy.enabled, "analytics_enabled": policy.analyticsEnabled,
         "keep_text": policy.keepText, "retention_days": policy.retentionDays]
    }

    func updatePolicy(_ newPolicy: ActivityHistoryPolicy) {
        lock.lock()
        let previous = policy
        guard previous != newPolicy else { lock.unlock(); return }
        let target = log
        // Enqueue a final coverage marker while recording is still enabled.
        if previous.enabled && !newPolicy.enabled, let target {
            target.append(EventEnvelope(type: .logPolicy, instance: instanceId, ts: Date(), payload: Self.policyPayload(newPolicy)))
        }
        target?.updatePolicy(newPolicy)
        policy = newPolicy
        enabled = newPolicy.enabled && target != nil
        if newPolicy.enabled, let target {
            target.append(EventEnvelope(type: .logPolicy, instance: instanceId, ts: Date(), payload: Self.policyPayload(newPolicy)))
        }
        let resume = newPolicy.enabled && newPolicy.analyticsEnabled && (!previous.enabled || !previous.analyticsEnabled)
        let active = appActive, locked = screenLocked, asleep = sleeping
        lock.unlock()
        if resume {
            if let active { emit(active ? .appActivated : .appDeactivated, payload: ["snapshot": true]) }
            if let locked { emit(locked ? .screenLocked : .screenUnlocked, payload: ["snapshot": true]) }
            if let asleep { emit(asleep ? .systemSleep : .systemWake, payload: ["snapshot": true]) }
        }
    }

    /// Notification callbacks already run on main. Cache the tiny state here;
    /// the watchdog reads it without querying AppKit while main is stalled.
    func observePresence(appActive: Bool? = nil, screenLocked: Bool? = nil, sleeping: Bool? = nil, snapshot: Bool = false) {
        lock.lock()
        var edges: [EventEnvelope.EventType] = []
        if let appActive, self.appActive != appActive {
            self.appActive = appActive
            edges.append(appActive ? .appActivated : .appDeactivated)
        }
        if let screenLocked, self.screenLocked != screenLocked {
            self.screenLocked = screenLocked
            edges.append(screenLocked ? .screenLocked : .screenUnlocked)
        }
        if let sleeping, self.sleeping != sleeping {
            self.sleeping = sleeping
            edges.append(sleeping ? .systemSleep : .systemWake)
        }
        let target = log
        lock.unlock()
        if let sleeping { target?.setSamplingAsleep(sleeping) }
        for edge in edges { emit(edge, payload: snapshot ? ["snapshot": true] : [:]) }
    }

    func emitWorkspaceCreated(workspace: UUID, title: String, rootDirectory: String?) {
        emit(.workspaceCreated, workspace: workspace, payload: ["title": title, "root_directory": rootDirectory ?? NSNull()])
    }

    func emitWorkspaceRenamed(workspace: UUID, title: String, prior: String) {
        guard title != prior else { return }
        emit(.workspaceRenamed, workspace: workspace, payload: ["title": title, "prior": prior])
    }

    /// One helper balances every remaining panel before the workspace edge.
    /// Callers clear their baseline first so repeated teardown is idempotent.
    func emitWorkspaceClosed(workspace: UUID, title: String, remainingPanels: Set<UUID>) {
        for panel in remainingPanels.sorted(by: { $0.uuidString < $1.uuidString }) {
            emitSurfaceClosed(workspace: workspace, surface: panel)
        }
        emit(.workspaceClosed, workspace: workspace, payload: ["title": title])
    }

    func shutdown() {
        currentLog()?.finishSampling { [weak self] in self?.sampleEnvelope(shutdown: true) }
    }

    private func sampleEnvelope(shutdown: Bool = false) -> EventEnvelope? {
        lock.lock()
        guard enabled, policy.analyticsEnabled else { lock.unlock(); return nil }
        let instance = instanceId
        lock.unlock()
        var payload = ActivityHistoryMetrics.sample()
        if shutdown { payload["shutdown"] = true }
        return EventEnvelope(type: .instanceSample, instance: instance, ts: Date(), payload: payload)
    }

    // MARK: - Emit helpers

    func emitSurfaceCreated(
        workspace: UUID,
        surface: UUID,
        kind: String,
        title: String? = nil
    ) {
        var payload: [String: Any] = ["kind": kind]
        if let title { payload["title"] = title }
        emit(.surfaceCreated, workspace: workspace, surface: surface, payload: payload)
    }

    func emitSurfaceClosed(workspace: UUID, surface: UUID) {
        emit(.surfaceClosed, workspace: workspace, surface: surface)
    }

    func emitWorkspaceReordered(windowId: UUID?, workspaceIds: [UUID]) {
        var payload: [String: Any] = ["final_workspace_ids": workspaceIds.map(\.uuidString)]
        if let windowId { payload["window_id"] = windowId.uuidString }
        emit(.workspaceReordered, payload: payload)
    }

    func emitWorkspaceSelected(previous: UUID?, selected: UUID, cause: String = "menu", method: String? = nil, callerPanelId: UUID? = nil) {
        var payload: [String: Any] = [:]
        if let previous { payload["previous"] = previous.uuidString }
        payload["cause"] = cause
        if let method {
            payload["method"] = method
            payload[EventEnvelope.PayloadKey.callerPanelId] = callerPanelId?.uuidString ?? NSNull()
        }
        emit(.workspaceSelected, workspace: selected, payload: payload)
    }

    func emitWorkspaceSwitchBlocked(target: UUID, method: String, callerPanelId: UUID?) {
        emit(.workspaceSwitchBlocked, workspace: target, payload: [
            "target": target.uuidString, "method": method,
            EventEnvelope.PayloadKey.callerPanelId: callerPanelId?.uuidString ?? NSNull()
        ])
    }

    /// `scope` is "surface" or "pane" (callers' v1 spelling); it is written as
    /// the v2 "panel" / "area". `source` is the `MetadataSource` raw
    /// value stringified by the caller (the pure envelope never names the enum).
    /// `prior` is optional — the surface store does not retain it for free.
    func emitMetadataChanged(
        scope: String,
        workspace: UUID,
        surface: UUID,
        key: String,
        value: Any?,
        prior: Any?,
        source: String
    ) {
        var payload: [String: Any] = [
            EventEnvelope.PayloadKey.scope: EventEnvelope.canonicalScope(scope),
            "key": key,
            "source": source,
        ]
        if let value, JSONSerialization.isValidJSONObject([value]) || value is String || value is NSNumber {
            payload["value"] = value
        }
        if let prior, JSONSerialization.isValidJSONObject([prior]) || prior is String || prior is NSNumber {
            payload["prior"] = prior
        }
        emit(.metadataChanged, workspace: workspace, surface: surface, payload: payload)
    }

    func emitWaiting(entered: Bool, workspace workspaceId: UUID, surface: UUID?) {
        emit(entered ? .waitingEntered : .waitingLeft, workspace: workspaceId, surface: surface)
    }

    /// The journal builds the payload with a `tab` key; v2 writes it as `panel`.
    func emitLifecycleChanged(workspace: UUID, panel: UUID, payload: [String: Any]) {
        var payload = payload
        if let legacy = payload.removeValue(forKey: EventEnvelope.PayloadKey.legacyTab),
           payload[EventEnvelope.PayloadKey.panel] == nil {
            payload[EventEnvelope.PayloadKey.panel] = legacy
        }
        emit(.lifecycleChanged, workspace: workspace, surface: panel, payload: payload)
    }

    func emitFlagRaised(
        workspace: UUID,
        surface: UUID,
        reason: String,
        callerPanelId: UUID?,
        by actor: PanelAttentionActor
    ) {
        emit(
            .flagRaised,
            workspace: workspace,
            surface: surface,
            payload: [
                "reason": reason,
                // C11-337: v2 writes only `caller_panel_id`; readers accept the
                // v1 `caller_tab_id` / `caller_surface_id` via `EventEnvelope.callerPanelId`.
                EventEnvelope.PayloadKey.callerPanelId: callerPanelId?.uuidString ?? NSNull(),
                "by": actor.rawValue,
            ]
        )
    }

    func emitFlagLowered(
        workspace: UUID,
        surface: UUID,
        by actor: PanelAttentionActor,
        answer: String? = nil
    ) {
        var payload: [String: Any] = ["by": actor.rawValue]
        if let answer { payload["answer"] = answer }
        emit(.flagLowered, workspace: workspace, surface: surface, payload: payload)
    }

    func emitFlagSuppressed(workspace: UUID, surface: UUID, by actor: PanelAttentionActor) {
        emit(.flagSuppressed, workspace: workspace, surface: surface, payload: ["by": actor.rawValue])
    }

    func emitFlagUnsuppressed(workspace: UUID, surface: UUID, by actor: PanelAttentionActor) {
        emit(.flagUnsuppressed, workspace: workspace, surface: surface, payload: ["by": actor.rawValue])
    }

    /// Structural ask open. The payload must not carry prompt text.
    @discardableResult
    func emitAskOpened(workspace: UUID?, surface: UUID, payload: [String: Any]) -> Bool {
        emit(.askOpened, workspace: workspace, surface: surface, payload: payload)
    }

    /// Structural ask close. `resolution` may be null. The payload must not carry prompt text.
    @discardableResult
    func emitAskClosed(workspace: UUID?, surface: UUID, payload: [String: Any]) -> Bool {
        emit(.askClosed, workspace: workspace, surface: surface, payload: payload)
    }

    /// C11-257 C1: build the stable payload for a successful socket send. This
    /// is intentionally pure so the truncation and null-attribution contract
    /// can be exercised without constructing a workspace or terminal.
    static func panelInputPayload(
        callerPanelId: UUID?,
        callerTitle: String?,
        targetTitle: String,
        kind: String,
        text: String,
        submitted: Bool,
        queued: Bool = false
    ) -> [String: Any] {
        let recorded = recordedText(text)
        var payload: [String: Any] = [
            EventEnvelope.PayloadKey.callerPanelId: callerPanelId?.uuidString ?? NSNull(),
            "caller_title": callerTitle ?? NSNull(),
            "target_title": targetTitle,
            "kind": kind,
            "text": recorded.value,
            "bytes": recorded.bytes,
            "submitted": submitted,
        ]
        if recorded.truncated {
            payload["truncated"] = true
        }
        if queued {
            payload["queued"] = true
        }
        return payload
    }

    @discardableResult
    func emitPanelInputSent(
        workspace: UUID,
        surface: UUID,
        callerPanelId: UUID?,
        callerTitle: String?,
        targetTitle: String,
        kind: String,
        text: String,
        submitted: Bool,
        queued: Bool = false
    ) -> Bool {
        emit(
            .panelInputSent,
            workspace: workspace,
            surface: surface,
            payload: Self.panelInputPayload(
                callerPanelId: callerPanelId,
                callerTitle: callerTitle,
                targetTitle: targetTitle,
                kind: kind,
                text: text,
                submitted: submitted,
                queued: queued
            )
        )
    }

    func emitMailboxAccepted(
        workspace: UUID,
        id: String,
        from: String,
        to: String?,
        body: String = "",
        bodyRef: String? = nil,
        topic: String?,
        replyTo: String? = nil,
        inReplyTo: String? = nil,
        urgent: Bool? = nil,
        textRecorded: Bool? = nil
    ) {
        let recordedBody = Self.recordedText(body)
        var payload: [String: Any] = ["id": id, "from": from, "body": recordedBody.value, "bytes": recordedBody.bytes]
        if let to { payload["to"] = to }
        if let bodyRef { payload["body_ref"] = bodyRef }
        if let topic { payload["topic"] = topic }
        if let replyTo { payload["reply_to"] = replyTo }
        if let inReplyTo { payload["in_reply_to"] = inReplyTo }
        if let urgent { payload["urgent"] = urgent }
        if recordedBody.truncated {
            payload["truncated"] = true
        }
        if let textRecorded { payload["text_recorded"] = textRecorded }
        emit(.mailboxAccepted, workspace: workspace, payload: payload)
    }

    func emitMailboxDelivered(
        workspace: UUID,
        id: String,
        recipient: String,
        surface: UUID?,
        via: String = "inbox"
    ) {
        emit(
            .mailboxDelivered,
            workspace: workspace,
            surface: surface,
            payload: ["id": id, "recipient": recipient, "via": via]
        )
    }

    /// TEL seam (C11-162): the derived working/idle activity state. If TEL's
    /// derived-liveness signal has not landed, this stays an unused stub call
    /// site that TEL wires later — the event type ships now so consumers can key
    /// on it. `state` is "working" or "idle".
    func emitDerivedLiveness(workspace: UUID, surface: UUID, state: String) {
        emit(
            .livenessDerived,
            workspace: workspace,
            surface: surface,
            payload: ["state": state]
        )
    }

    /// Records the recovery policy selected for this launch before any
    /// per-surface decisions are evaluated. Returns false when the event log
    /// has not started yet so AppDelegate can retry after launch setup.
    @discardableResult
    func emitConversationResumeMode(_ mode: ResumeRecoveryMode) -> Bool {
        emit(.conversationResumeMode, payload: ["mode": mode.rawValue])
    }

    /// One durable outcome for each restored agent candidate. The command
    /// itself is intentionally excluded: the kind + exact conversation id
    /// identify the target without duplicating shell text in diagnostics.
    @discardableResult
    func emitConversationResumeDecision(
        workspace: UUID,
        surface: UUID,
        kind: String,
        conversationId: String?,
        mode: ResumeRecoveryMode,
        decision: ResumeDecision
    ) -> Bool {
        var payload: [String: Any] = [
            "kind": kind,
            "conversation_id": conversationId ?? NSNull(),
            "mode": mode.rawValue,
        ]
        switch decision {
        case .command:
            payload["decision"] = "command"
            payload["skip_code"] = NSNull()
        case .skip(let code, let reason):
            payload["decision"] = "skip"
            payload["skip_code"] = code.rawValue
            payload["reason"] = reason
        }
        return emit(
            .conversationResumeDecision,
            workspace: workspace,
            surface: surface,
            payload: payload
        )
    }

    /// A run of same-fingerprint main-thread stalls the watchdog judged to be
    /// the leading edge of a wedge (C11-221). Process-level, so it carries no
    /// subject refs. Emitted from the watchdog thread; `emit` is any-thread.
    @discardableResult
    func emitHangPrecursor(
        cause: String,
        culprit: String?,
        count: Int,
        windowMs: Int,
        spanMs: Int,
        durationsMs: [Int],
        fingerprint: [String]
    ) -> Bool {
        lock.lock()
        let active: Any = appActive.map { $0 as Any } ?? NSNull()
        let locked: Any = screenLocked.map { $0 as Any } ?? NSNull()
        lock.unlock()
        return emit(
            .hangPrecursor,
            payload: [
                "app_active": active,
                "screen_locked": locked,
                "cause": cause,
                "culprit": culprit ?? NSNull(),
                "count": count,
                "window_ms": windowMs,
                "span_ms": spanMs,
                "durations_ms": durationsMs,
                "fingerprint": fingerprint,
            ]
        )
    }

    // MARK: - Core

    @discardableResult
    private func emit(
        _ type: EventEnvelope.EventType,
        workspace: UUID? = nil,
        surface: UUID? = nil,
        pane: UUID? = nil,
        payload: @autoclosure () -> [String: Any] = [:]
    ) -> Bool {
        // Capture ts + snapshot the log under the lock; build + append outside.
        lock.lock()
        guard enabled, let log, !Self.analyticsTypes.contains(type) || policy.analyticsEnabled else {
            lock.unlock()
            return false
        }
        let instance = instanceId
        let keepText = policy.keepText
        lock.unlock()
        var recordedPayload = payload()
        if !(recordedPayload["text_recorded"] as? Bool ?? keepText) {
            if type == .panelInputSent, let text = recordedPayload.removeValue(forKey: "text") as? String {
                if recordedPayload["bytes"] == nil { recordedPayload["bytes"] = text.utf8.count }
                recordedPayload["text_recorded"] = false
                recordedPayload.removeValue(forKey: "truncated")
            } else if type == .mailboxAccepted {
                let body = recordedPayload.removeValue(forKey: "body") as? String ?? ""
                if recordedPayload["bytes"] == nil { recordedPayload["bytes"] = body.utf8.count }
                recordedPayload["text_recorded"] = false
                recordedPayload.removeValue(forKey: "body_ref")
                recordedPayload.removeValue(forKey: "truncated")
            }
        }

        let envelope = EventEnvelope(
            type: type,
            instance: instance,
            ts: Date(),
            workspace: workspace?.uuidString,
            surface: surface?.uuidString,
            pane: pane?.uuidString,
            payload: recordedPayload
        )
        log.append(envelope)
        return true
    }

    private static let analyticsTypes: Set<EventEnvelope.EventType> = [
        .appActivated, .appDeactivated, .screenLocked, .screenUnlocked,
        .systemSleep, .systemWake, .workspaceCreated, .workspaceRenamed,
        .workspaceClosed, .instanceSample,
    ]

    private func currentLog() -> EventLog? {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    private static func recordedText(_ text: String) -> (value: String, bytes: Int, truncated: Bool) {
        let byteCount = text.utf8.count
        guard byteCount > maxRecordedTextBytes else {
            return (text, byteCount, false)
        }
        let utf8 = Array(text.utf8)

        var end = maxRecordedTextBytes
        while end > 0, end < utf8.count, (utf8[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return (
            String(decoding: utf8.prefix(end), as: UTF8.self),
            byteCount,
            true
        )
    }

    // MARK: - Test detection

    private static func isRunningUnderXCTest() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        return false
    }
}
