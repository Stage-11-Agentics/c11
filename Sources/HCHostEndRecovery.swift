import Foundation

/// C11H-196: what happened to one panel's terminal after a host end (a reboot,
/// or its hc core and holder dying), and what c11 is doing about it. One
/// value per ended terminal key; the panel publishes it, the banner shows it,
/// and `hc-diagnostics --json` reports it.
struct HCHostEndStatus: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// hc found the terminal gone after this Mac started again.
        case restart(at: Date)
        /// The terminal host stopped (holder lost, server stopped) while c11
        /// watched, or hc reported the end without a reboot behind it.
        case hostStopped(at: Date)
        /// C11H-232: a signal c11 did not send ended the terminal's root (a
        /// stray `pkill -f`, a `kill` aimed at the wrong pid). Offered, never
        /// resumed unasked: it may have been meant.
        case outsideSignal(at: Date, signal: Int32)
    }

    enum Phase: Equatable, Sendable {
        /// The saved conversation is being looked up.
        case deciding
        /// Waiting its turn in the staggered resume queue.
        case queued
        /// A fresh terminal is being started for it.
        case starting
        /// The fresh shell is up; the resume is typed when its prompt is idle.
        case resuming
        case resumed
        /// Not resumed automatically; the reason says why, in plain English.
        case notResumed(reason: String)
        /// A resume was planned but could not be carried out (no fresh
        /// terminal, a refusal, a stall).
        case failed(reason: String)
        /// Typing the resume was cut off midway. It is never sent again into
        /// that terminal, so no Resume is offered; the operator looks first.
        case interrupted(reason: String)
        /// An agent is running in the panel's terminal (it never stopped, or
        /// someone started one): nothing to resume there now.
        case kept(reason: String)
        /// The panel had no agent conversation to resume (a plain shell).
        case noConversation
    }

    let endedKey: HCTerminalKey
    let cause: Cause
    var phase: Phase
    /// The conversation a Resume conversation action brings back. Kept even
    /// after another session takes the panel, so it is never lost silently.
    var conversation: ConversationRef?

    var endedAt: Date {
        switch cause {
        case .restart(let at), .hostStopped(let at), .outsideSignal(let at, _): return at
        }
    }

    /// Stable token for `hc-diagnostics --json` and `c11 restore status`.
    var causeToken: String {
        switch cause {
        case .restart: return "restart"
        case .hostStopped: return "host_stopped"
        case .outsideSignal: return "outside_signal"
        }
    }

    /// The signal behind an `outside_signal` end, else nil.
    var signal: Int32? {
        if case .outsideSignal(_, let signal) = cause { return signal }
        return nil
    }

    /// `SIGTERM`, `SIGKILL`, …; `signal 23` for one without a common name.
    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGABRT: return "SIGABRT"
        case SIGKILL: return "SIGKILL"
        case SIGBUS: return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        case SIGUSR1: return "SIGUSR1"
        case SIGUSR2: return "SIGUSR2"
        default: return "signal \(signal)"
        }
    }

    /// Why an outside signal's conversation waits for the operator.
    static var outsideSignalReason: String {
        String(localized: "hc.hostEnd.outsideSignal",
               defaultValue: "something outside c11 ended it, so c11 waits for you.")
    }

    /// Whether this record waits on the operator: the strip counts exactly the
    /// rows its Details list shows.
    var needsOperator: Bool {
        guard conversation != nil else { return false }
        switch phase {
        case .notResumed, .failed, .interrupted: return true
        default: return false
        }
    }

    /// Whether the operator can still ask for this conversation.
    var offersResume: Bool {
        guard conversation != nil else { return false }
        switch phase {
        case .notResumed, .failed, .kept: return true
        default: return false
        }
    }

    /// The first banner line: what ended the session, and when (local time).
    var headline: String {
        // C11H-205: hc's end time can be days old; a bare time would read as today.
        let time = Self.displayTime(endedAt)
        switch cause {
        case .restart:
            return String(format: String(localized: "terminal.hostEnd.restart",
                defaultValue: "This session ended when the Mac restarted at %@."), time)
        case .hostStopped:
            return String(format: String(localized: "terminal.hostEnd.hostStopped",
                defaultValue: "The terminal host stopped at %@ and ended this session."), time)
        case .outsideSignal(_, let signal):
            return String(format: String(localized: "terminal.hostEnd.outsideSignal",
                defaultValue: "A %1$@ from outside c11 ended this session at %2$@."), Self.signalName(signal), time)
        }
    }

    /// The second banner line: what happens next, or why nothing will.
    var detail: String {
        switch phase {
        case .deciding:
            return String(localized: "terminal.hostEnd.deciding", defaultValue: "Looking for its saved conversation…")
        case .queued:
            return String(localized: "terminal.hostEnd.queued",
                defaultValue: "Its conversation will resume in a fresh terminal shortly.")
        case .starting, .resuming:
            return String(localized: "terminal.hostEnd.resuming",
                defaultValue: "Resuming its conversation in a fresh terminal…")
        case .resumed:
            return String(localized: "terminal.hostEnd.resumed",
                defaultValue: "Its conversation was resumed in a fresh terminal.")
        case .notResumed(let reason), .failed(let reason), .interrupted(let reason), .kept(let reason):
            return String(format: String(localized: "terminal.hostEnd.notResumed",
                defaultValue: "Its conversation was not resumed: %@"), reason)
        case .noConversation:
            return String(localized: "terminal.hostEnd.noConversation",
                defaultValue: "No agent conversation was saved for it. A fresh shell starts when you open it.")
        }
    }

    /// Stable token for `hc-diagnostics --json`.
    var stateToken: String {
        switch phase {
        case .deciding: return "deciding"
        case .queued: return "queued"
        case .starting: return "starting"
        case .resuming: return "resuming"
        case .resumed: return "resumed"
        case .notResumed: return "not_resumed"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        case .kept: return "kept"
        case .noConversation: return "no_conversation"
        }
    }

    /// The restore record's state (C11H-196 acceptance): pending, resuming,
    /// resumed, failed or skipped.
    var recordState: String {
        switch phase {
        case .deciding, .queued: return "pending"
        case .starting, .resuming: return "resuming"
        case .resumed: return "resumed"
        case .failed, .interrupted: return "failed"
        case .notResumed, .noConversation, .kept: return "skipped"
        }
    }

    var reasonToken: String? {
        switch phase {
        case .notResumed(let reason), .failed(let reason), .interrupted(let reason), .kept(let reason): return reason
        case .noConversation: return "no agent conversation was saved for this panel."
        default: return nil
        }
    }

    /// Local time, with the date when it is not today (C11H-205).
    static func displayTime(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? timeFormatter : dateTimeFormatter).string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// When the previous app session last saved its snapshot (set once at
    /// startup restore). Terminals were live then.
    @MainActor static var previousSessionSavedAt: Date?

    /// The outcome is final: nothing in this session will change it on its own.
    /// Only a settled record is saved for the next launch; one still deciding,
    /// queued or resuming is decided again there.
    var isSettled: Bool {
        switch phase {
        case .deciding, .queued, .starting, .resuming: return false
        case .resumed, .notResumed, .failed, .interrupted, .kept, .noConversation: return true
        }
    }

    /// A reboot ends a terminal as `stopped_by_restart` (or `host_shutdown`)
    /// when the Mac booted after the terminal was last known live. Without
    /// that proof the host is said to have stopped, at the time hc recorded
    /// the end (`endedAt`, its `finished_ms`). C11H-205: only an end hc did
    /// not time falls back to when c11 learned of it; a terminal that ended
    /// hours before this launch read as stopping at the launch.
    static func cause(hcReason: String?, observedAt: Date, bootedAt: Date?, lastKnownLive: Date?,
                      endedAt: Date? = nil) -> Cause {
        if hcReason == "stopped_by_restart" || hcReason == "host_shutdown", let bootedAt, let lastKnownLive,
           bootedAt > lastKnownLive, bootedAt <= observedAt {
            return .restart(at: bootedAt)
        }
        return .hostStopped(at: endedAt.map { min($0, observedAt) } ?? observedAt)
    }

    /// This Mac's boot time (`kern.boottime`), or nil.
    static func systemBootTime() -> Date? {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0, boottime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec) + TimeInterval(boottime.tv_usec) / 1_000_000)
    }
}

/// C11H-209: a settled record is saved with its panel, so a relaunch shows
/// the same outcome (and offers the same Resume) instead of deciding again.
/// Only settled phases decode; anything else fails and is dropped.
extension HCHostEndStatus: Codable {
    private enum CodingKeys: String, CodingKey { case endedKey, cause, endedAt, phase, reason, conversation, signal }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let endedKey = try values.decode(HCTerminalKey.self, forKey: .endedKey)
        let at = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .endedAt))
        let cause: Cause
        switch try values.decode(String.self, forKey: .cause) {
        case "restart": cause = .restart(at: at)
        case "host_stopped": cause = .hostStopped(at: at)
        case "outside_signal": cause = .outsideSignal(at: at, signal: try values.decode(Int32.self, forKey: .signal))
        default:
            throw DecodingError.dataCorruptedError(forKey: .cause, in: values, debugDescription: "unknown cause")
        }
        let reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? ""
        let phase: Phase
        switch try values.decode(String.self, forKey: .phase) {
        case "resumed": phase = .resumed
        case "not_resumed": phase = .notResumed(reason: reason)
        case "failed": phase = .failed(reason: reason)
        case "interrupted": phase = .interrupted(reason: reason)
        case "kept": phase = .kept(reason: reason)
        case "no_conversation": phase = .noConversation
        default:
            throw DecodingError.dataCorruptedError(forKey: .phase, in: values, debugDescription: "not a settled phase")
        }
        self.init(endedKey: endedKey, cause: cause, phase: phase,
                  conversation: try values.decodeIfPresent(ConversationRef.self, forKey: .conversation))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(endedKey, forKey: .endedKey)
        try values.encode(causeToken, forKey: .cause)
        try values.encodeIfPresent(signal, forKey: .signal)
        try values.encode(endedAt.timeIntervalSince1970, forKey: .endedAt)
        try values.encode(stateToken, forKey: .phase)
        switch phase {
        case .notResumed(let reason), .failed(let reason), .interrupted(let reason), .kept(let reason):
            try values.encode(reason, forKey: .reason)
        default: break
        }
        try values.encodeIfPresent(conversation, forKey: .conversation)
    }
}

/// C11H-209: what a relaunch keeps of one panel's host-end recovery, so each
/// end is decided once.
/// - `decidedKeys`: ends already decided (resumed, offered, kept, ended with
///   End All). The next launch never decides them again.
/// - `foundEndedKeys`: ends this session found ended and never planned a
///   resume for (agent restart off, a no-resume launch, an earlier build).
///   C11H-205 decision 2: the next launch offers them; it does not resume them
///   unasked.
/// - `record`: an offer still waiting on the operator, back with its cause,
///   reason and Resume. A resumed, kept, conversation-less or dismissed one is
///   not kept.
/// An end whose resume is still deciding, queued, starting or typing at quit
/// is in none of these, so the next launch resumes it (a reboot in the middle
/// of a restore). Decoding never fails the panel or its session.
struct HCSavedHostEnd: Codable, Sendable, Equatable {
    var decidedKeys: [HCTerminalKey]
    var foundEndedKeys: [HCTerminalKey]
    var record: HCHostEndStatus?

    init(decidedKeys: [HCTerminalKey], foundEndedKeys: [HCTerminalKey] = [], record: HCHostEndStatus?) {
        self.decidedKeys = decidedKeys
        self.foundEndedKeys = foundEndedKeys
        self.record = record
    }

    private enum CodingKeys: String, CodingKey { case decidedKeys, foundEndedKeys, record }

    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        decidedKeys = (try? values?.decode([HCTerminalKey].self, forKey: .decidedKeys)) ?? []
        foundEndedKeys = (try? values?.decode([HCTerminalKey].self, forKey: .foundEndedKeys)) ?? []
        record = (try? values?.decodeIfPresent(HCHostEndStatus.self, forKey: .record))
            .flatMap { $0.needsOperator ? $0 : nil }
    }

    /// What to save for a panel now.
    /// - `relevant`: the keys the panel can still resolve (its terminal's key
    ///   and the end a replacement answers), so the lists never grow.
    /// - `found`: ends found and left: the one the panel's terminal shows now,
    ///   and any found by an earlier session this one never resolved.
    /// - `unsettled`: ends whose resume is still being decided, queued,
    ///   started or typed; the next launch decides those itself.
    /// - `endedOnPurpose`: End All ended these: decided, never offered.
    /// Nil when there is nothing to keep.
    static func capture(decided: Set<HCTerminalKey>, record: HCHostEndStatus?, relevant: Set<HCTerminalKey>,
                        found: Set<HCTerminalKey>, unsettled: Set<HCTerminalKey>, dismissedKey: HCTerminalKey?,
                        endedOnPurpose: Set<HCTerminalKey> = []) -> HCSavedHostEnd? {
        var unsettled = unsettled
        if let record, !record.isSettled { unsettled.insert(record.endedKey) }
        var keys = decided.union(endedOnPurpose).intersection(relevant).subtracting(unsettled)
        if let record, !unsettled.contains(record.endedKey) { keys.insert(record.endedKey) }
        let foundKeys = found.intersection(relevant).subtracting(unsettled).subtracting(keys)
        let offer = record.flatMap { record in
            !unsettled.contains(record.endedKey) && record.needsOperator && dismissedKey != record.endedKey ? record : nil
        }
        guard !keys.isEmpty || !foundKeys.isEmpty else { return nil }
        let order: (HCTerminalKey, HCTerminalKey) -> Bool = {
            ($0.owningCoreID, $0.localAddress) < ($1.owningCoreID, $1.localAddress)
        }
        return HCSavedHostEnd(decidedKeys: keys.sorted(by: order), foundEndedKeys: foundKeys.sorted(by: order), record: offer)
    }
}

/// C11H-196: one app-wide queue for host-end resumes, so forty agents ending
/// together come back one after another instead of all at once. The operator's
/// own requests go first, then shown panels, then hidden panels most recently
/// active first (the conversation's last transcript write, else the panel's
/// last input), then in the order they were decided. A batch that starts from
/// idle waits `settle` so the decisions landing together are ordered together. One admission per `interval`, and at most `maxInFlight`
/// admitted panels whose resume has not been typed yet (or `slotTimeout`
/// passed). Admission starts the panel's fresh terminal (headless when it is
/// not shown); the resume itself is still typed only by the guarded submit
/// once that shell's prompt is idle.
@MainActor
final class HCHostEndResumeQueue {
    static let shared = HCHostEndResumeQueue()

    enum Priority: Int, Comparable, Sendable {
        case operatorRequest = 0
        case shown = 1
        case hidden = 2
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    struct Entry {
        let panelID: UUID
        let endedKey: HCTerminalKey
        var priority: Priority
        /// Most recent activity first within a priority; nil sorts last.
        var activity: Date?
        let sequence: UInt64
        /// Starts the fresh terminal. Throws when it cannot start now.
        let admit: @MainActor () async throws -> Void
        /// The entry gave up after its retries; the error is plain English.
        let abandon: @MainActor (String) -> Void
        var attempts = 0
        var notBefore: UInt64 = 0
    }

    var interval: TimeInterval
    /// How long a batch starting from idle waits before its first admission.
    var settle: TimeInterval = HCHostEndResumeQueue.defaultSettle
    var maxInFlight: Int
    var slotTimeout: TimeInterval
    var maxAttempts = 3
    /// Test seam: the clock and the sleep the pump uses.
    var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var sleep: (UInt64) async -> Void = { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) }

    private(set) var pending: [Entry] = []
    /// Admitted panels still booting: admission time by panel.
    private(set) var inFlight: [UUID: UInt64] = [:]
    /// The admitted entries, for a stalled slot's `abandon`.
    private var admitted: [UUID: Entry] = [:]
    /// What `abandon` receives when an admitted panel did not finish within
    /// `slotTimeout` (its slot is freed; a late resume still lands).
    static let stalledReason = "stalled"
    private var lastAdmission: UInt64?
    private var batchNotBefore: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pump: Task<Void, Never>?
    /// Every admission, oldest first, for tests and diagnostics (bounded).
    private(set) var admissionLog: [(panelID: UUID, at: UInt64)] = []

    init(interval: TimeInterval = HCHostEndResumeQueue.defaultInterval,
         maxInFlight: Int = HCHostEndResumeQueue.defaultMaxInFlight,
         slotTimeout: TimeInterval = 45) {
        self.interval = interval
        self.maxInFlight = max(1, maxInFlight)
        self.slotTimeout = slotTimeout
    }

    nonisolated static var defaultInterval: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["C11_HOST_END_RESUME_INTERVAL_MS"],
           let ms = Double(raw), ms >= 0 { return ms / 1000 }
        return 1.5
    }

    nonisolated static var defaultSettle: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["C11_HOST_END_RESUME_SETTLE_MS"],
           let ms = Double(raw), ms >= 0 { return ms / 1000 }
        return 1.0
    }

    nonisolated static var defaultMaxInFlight: Int {
        if let raw = ProcessInfo.processInfo.environment["C11_HOST_END_RESUME_MAX_IN_FLIGHT"],
           let value = Int(raw), value > 0 { return value }
        return 3
    }

    func isQueued(_ panelID: UUID) -> Bool { pending.contains { $0.panelID == panelID } }

    /// Add one panel's resume. A panel is queued once per ended key; a second
    /// enqueue for the same key only raises its priority.
    func enqueue(panelID: UUID, endedKey: HCTerminalKey, priority: Priority, activity: Date? = nil,
                 admit: @escaping @MainActor () async throws -> Void,
                 abandon: @escaping @MainActor (String) -> Void) {
        if let index = pending.firstIndex(where: { $0.panelID == panelID && $0.endedKey == endedKey }) {
            if priority < pending[index].priority { pending[index].priority = priority }
            return
        }
        pending.removeAll { $0.panelID == panelID }
        sequence &+= 1
        if pump == nil, pending.isEmpty, inFlight.isEmpty {
            batchNotBefore = now() &+ UInt64(settle * 1_000_000_000)
        }
        pending.append(Entry(panelID: panelID, endedKey: endedKey, priority: priority, activity: activity,
                             sequence: sequence, admit: admit, abandon: abandon))
        startPump()
    }

    /// Admission order: priority, then most recent activity, then decided order.
    nonisolated static func precedes(_ a: Entry, _ b: Entry) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        switch (a.activity, b.activity) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.sequence < b.sequence
        }
    }

    /// The panel's resume was typed, refused, or abandoned: its slot frees.
    func finished(panelID: UUID) {
        inFlight.removeValue(forKey: panelID)
        admitted.removeValue(forKey: panelID)
        startPump()
    }

    /// The panel closed or its recovery was cancelled.
    func cancel(panelID: UUID) {
        pending.removeAll { $0.panelID == panelID }
        inFlight.removeValue(forKey: panelID)
        admitted.removeValue(forKey: panelID)
    }

    /// Admitted panels that did not finish within `slotTimeout`: their slot is
    /// freed and they are told so (a hung start never holds the queue).
    private func expireStalledSlots(at clock: UInt64) {
        let timeout = UInt64(slotTimeout * 1_000_000_000)
        for (panelID, at) in inFlight where clock &- at >= timeout {
            inFlight.removeValue(forKey: panelID)
            admitted.removeValue(forKey: panelID)?.abandon(Self.stalledReason)
        }
    }

    /// An admission threw: try again after a backoff, or give up. Never re-decided.
    private func admissionFailed(_ entry: Entry, error: Error) {
        guard inFlight[entry.panelID] != nil || admitted[entry.panelID] != nil else { return }
        inFlight.removeValue(forKey: entry.panelID)
        admitted.removeValue(forKey: entry.panelID)
        var retry = entry
        if retry.attempts < maxAttempts {
            retry.notBefore = now() &+ UInt64(retry.attempts) * 2_000_000_000
            pending.append(retry)
            startPump()
        } else {
            retry.abandon(String(describing: error))
        }
    }

    private func startPump() {
        guard pump == nil, !pending.isEmpty else { return }
        pump = Task { @MainActor [weak self] in
            await self?.drain()
            self?.pump = nil
            // Something arrived while the last pass was finishing.
            if let self, !self.pending.isEmpty { self.startPump() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let clock = now()
            let timeout = UInt64(slotTimeout * 1_000_000_000)
            expireStalledSlots(at: clock)
            let spacing = UInt64(interval * 1_000_000_000)
            var wait: UInt64 = 0
            if let lastAdmission, clock &- lastAdmission < spacing { wait = spacing - (clock &- lastAdmission) }
            if inFlight.count >= maxInFlight {
                // Wake when the oldest slot times out, or sooner on `finished`.
                let oldest = inFlight.values.min() ?? clock
                wait = max(wait, min(timeout - min(timeout, clock &- oldest), 250_000_000))
            }
            if batchNotBefore > clock { wait = max(wait, batchNotBefore - clock) }
            let ready = pending.indices.filter { pending[$0].notBefore <= clock }
            if ready.isEmpty {
                let next = pending.map(\.notBefore).min() ?? clock
                wait = max(wait, next &- clock)
            }
            if wait > 0 {
                await sleep(min(wait, 250_000_000))
                continue
            }
            guard let index = ready.min(by: { Self.precedes(pending[$0], pending[$1]) }) else { continue }
            var entry = pending.remove(at: index)
            entry.attempts += 1
            lastAdmission = now()
            inFlight[entry.panelID] = lastAdmission
            admissionLog.append((entry.panelID, lastAdmission ?? 0))
            if admissionLog.count > 256 { admissionLog.removeFirst(admissionLog.count - 256) }
            admitted[entry.panelID] = entry
            // Not awaited: a start that hangs holds only its own slot, which
            // `slotTimeout` frees, never the queue.
            let admission = entry
            Task { @MainActor [weak self] in
                do { try await admission.admit() } catch { self?.admissionFailed(admission, error: error) }
            }
        }
        // Keep watching admitted slots until they finish or stall.
        while !inFlight.isEmpty, pending.isEmpty {
            expireStalledSlots(at: now())
            if inFlight.isEmpty { break }
            await sleep(250_000_000)
        }
    }
}

/// C11H-196: one restore record per panel ended by the host, gathered across
/// every window for the restore strip ("Restored 45 of 47. 2 need you.") and
/// `c11 restore status`. Panels publish their record; this decides nothing.
@MainActor
final class HCRestoreProgress: ObservableObject {
    static let shared = HCRestoreProgress()

    struct Record: Identifiable, Equatable {
        let id: UUID
        var workspaceID: UUID
        var status: HCHostEndStatus
        /// C11H-209: an offer carried over from an earlier launch. It is listed
        /// (Details, `restore status`) but never makes the strip appear.
        var carried = false
    }

    struct Summary: Equatable {
        var total = 0, pending = 0, resuming = 0, resumed = 0, failed = 0, skipped = 0, needYou = 0
        var isFinished: Bool { pending == 0 && resuming == 0 }
    }

    @Published private(set) var records: [UUID: Record] = [:]
    @Published private(set) var isDismissed = false
    /// C11H-320 PR 3: per live panel, the end last announced as needing the
    /// operator (`agent.restore_needs_operator`, once per seat and end per
    /// launch); dropped with the panel.
    private var announcedNeedsOperator: [UUID: HCTerminalKey] = [:]
    /// Seam for tests; the app writes the event log.
    var announce: (UUID, UUID, HCHostEndStatus, Bool) -> Void = { panel, workspace, status, carried in
        EventEmitter.shared.emitAgent(.agentRestoreNeedsOperator, workspace: workspace, panel: panel,
                                      payload: HCRestoreProgress.needsOperatorPayload(status, carried: carried))
    }
    private var autoDismiss: DispatchWorkItem?
    static let autoDismissAfter: TimeInterval = 20

    func update(panelID: UUID, workspaceID: UUID, status: HCHostEndStatus?, carried: Bool = false) {
        guard let status else { remove(panelID: panelID); return }
        // C11H-235: mass-end detection remembers a carried end the first time it
        // sees it, so later phase changes never count it.
        HCMassSignalEnd.shared.observe(panelID: panelID, old: records[panelID]?.status, new: status, carried: carried)
        let isNewEnd = records[panelID]?.status.endedKey != status.endedKey
        records[panelID] = Record(id: panelID, workspaceID: workspaceID, status: status, carried: carried)
        // C11H-320 PR 3: a seat whose agent needs the operator to come back is
        // announced once per end per launch, carried offers included.
        if status.needsOperator, announcedNeedsOperator[panelID] != status.endedKey {
            announcedNeedsOperator[panelID] = status.endedKey
            announce(panelID, workspaceID, status, carried)
        }
        if isNewEnd, !carried { isDismissed = false }
        scheduleAutoDismiss()
    }

    func remove(panelID: UUID) {
        announcedNeedsOperator.removeValue(forKey: panelID)
        guard let removed = records.removeValue(forKey: panelID) else { return }
        HCMassSignalEnd.shared.observe(panelID: panelID, old: removed.status, new: nil, carried: removed.carried)
        scheduleAutoDismiss()
    }

    func dismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        isDismissed = true
    }

    /// `agent.restore_needs_operator`'s payload: codes, times and kinds only.
    nonisolated static func needsOperatorPayload(_ status: HCHostEndStatus, carried: Bool) -> [String: Any] {
        [
            "agent": status.conversation?.kind as Any? ?? NSNull(),
            "state": status.recordState,
            "phase": status.stateToken,
            "cause": status.causeToken,
            "signal": status.signal.map { Int($0) } as Any? ?? NSNull(),
            "ended_at_ms": Int64((status.endedAt.timeIntervalSince1970 * 1000).rounded()),
            "offers_resume": status.offersResume,
            "carried": carried,
        ]
    }

    /// Agent panels only: a plain shell with nothing to resume is not counted.
    var summary: Summary { Self.summary(records.values.map(\.status)) }
    /// The strip counts this launch's records only (C11H-209): an offer carried
    /// over from an earlier launch is listed in Details, never counted.
    var stripSummary: Summary { Self.summary(records.values.filter { !$0.carried }.map(\.status)) }

    nonisolated static func summary(_ statuses: [HCHostEndStatus]) -> Summary {
        var summary = Summary()
        for status in statuses {
            if case .noConversation = status.phase { continue }
            summary.total += 1
            switch status.recordState {
            case "pending": summary.pending += 1
            case "resuming": summary.resuming += 1
            case "resumed": summary.resumed += 1
            case "failed": summary.failed += 1
            default: summary.skipped += 1
            }
            if status.needsOperator { summary.needYou += 1 }
        }
        return summary
    }

    /// The strip's one line, or nil when there is nothing to say.
    var headline: String? {
        guard !isDismissed else { return nil }
        return Self.headline(stripSummary)
    }

    nonisolated static func headline(_ summary: Summary) -> String? {
        guard summary.total > 0 else { return nil }
        if !summary.isFinished {
            return String(format: String(localized: "restore.strip.progress",
                defaultValue: "Restoring agents: %lld of %lld resumed…"), summary.resumed, summary.total)
        }
        if summary.needYou > 0 {
            return String(format: String(localized: "restore.strip.needYou",
                defaultValue: "Restored %lld of %lld agents. %lld need you."), summary.resumed, summary.total, summary.needYou)
        }
        return String(format: String(localized: "restore.strip.done",
            defaultValue: "Restored %lld of %lld agents."), summary.resumed, summary.total)
    }

    /// The rows that need the operator, oldest end first.
    var needingYou: [Record] {
        records.values.filter { $0.status.needsOperator }.sorted { $0.status.endedAt < $1.status.endedAt }
    }

    private final class WeakWorkspace { weak var value: Workspace?; init(_ value: Workspace) { self.value = value } }
    /// Workspaces that planned a host-end resume, so a queue turn finds its
    /// panel even outside the app's window list (a workspace being built).
    private var workspaces: [ObjectIdentifier: WeakWorkspace] = [:]

    func noteWorkspace(_ workspace: Workspace) {
        workspaces = workspaces.filter { $0.value.value != nil }
        workspaces[ObjectIdentifier(workspace)] = WeakWorkspace(workspace)
    }

    /// The panel's workspace now (it may have moved since it was queued).
    func locate(_ panelID: UUID) -> (workspace: Workspace, panel: TerminalPanel)? {
        var candidates = AppDelegate.shared?.allMainWindowWorkspaces() ?? []
        candidates += workspaces.values.compactMap(\.value)
        for workspace in candidates {
            if let panel = workspace.panels[panelID] as? TerminalPanel { return (workspace, panel) }
        }
        return nil
    }

    /// A row's Resume button: the same route as the panel banner and
    /// `c11 restore run`. Returns why it was refused, or nil.
    func resume(_ panelID: UUID) -> String? {
        guard let found = locate(panelID) else {
            return String(localized: "hc.hostEnd.notEnded", defaultValue: "This panel has no ended session to resume.")
        }
        return found.workspace.resumeHostEndedConversation(panelId: panelID)
    }

    private func scheduleAutoDismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        let summary = stripSummary
        guard summary.total > 0, summary.isFinished, summary.needYou == 0 else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismiss() } }
        autoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissAfter, execute: work)
    }
}
