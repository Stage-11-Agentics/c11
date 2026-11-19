import Foundation

/// C11H-235: groups kept outside-signal ends into mass ends. Pure, so the
/// window and threshold are testable without an app.
///
/// A mass end is `threshold` or more kept ends (a local terminal whose root a
/// signal c11 did not send ended while its panel held a live agent
/// conversation) whose hc end times fall within `window` of the earliest of
/// them. hc's end time, not the moment c11 learned of it, so ends found at
/// launch group exactly as ends seen live. Three ends spread wider than the
/// window form no mass end: the span is anchored on the earliest member, never
/// chained end to end. An end that falls inside an existing mass end's span
/// joins it.
struct HCMassSignalEndDetector {
    struct End: Equatable {
        let panelID: UUID
        let endedKey: HCTerminalKey
        let signal: Int32
        let endedAt: Date
    }

    struct Mass: Equatable {
        let id: UUID
        var members: [End]
        var start: Date { members.map(\.endedAt).min() ?? .distantPast }
        var end: Date { members.map(\.endedAt).max() ?? .distantPast }
    }

    enum Outcome: Equatable {
        /// Already seen, or alone so far.
        case none
        /// It completed a new mass end.
        case formed(UUID)
        /// It joined a mass end that already existed.
        case joined(UUID)
    }

    var window: TimeInterval
    var threshold: Int
    private(set) var masses: [Mass] = []
    /// Kept ends in no mass end yet (bounded).
    private(set) var pool: [End] = []
    private var seen = Set<String>()
    static let poolLimit = 512

    init(window: TimeInterval = 5, threshold: Int = 3) {
        self.window = window
        self.threshold = max(2, threshold)
    }

    static func identity(panelID: UUID, endedKey: HCTerminalKey) -> String {
        "\(panelID.uuidString)|\(endedKey.owningCoreID)|\(endedKey.localAddress)"
    }

    mutating func add(_ end: End) -> Outcome {
        guard seen.insert(Self.identity(panelID: end.panelID, endedKey: end.endedKey)).inserted else { return .none }
        // Joining keeps the span within `window` of the (possibly earlier) start.
        if let index = masses.firstIndex(where: {
            let start = min($0.start, end.endedAt), last = max($0.end, end.endedAt)
            return last.timeIntervalSince(start) <= window
        }) {
            masses[index].members.append(end)
            return .joined(masses[index].id)
        }
        pool.append(end)
        // The densest span of `window` that holds the new end.
        var best: [End] = []
        for anchor in pool where anchor.endedAt <= end.endedAt && end.endedAt.timeIntervalSince(anchor.endedAt) <= window {
            let span = pool.filter { $0.endedAt >= anchor.endedAt && $0.endedAt.timeIntervalSince(anchor.endedAt) <= window }
            if span.count > best.count { best = span }
        }
        if best.count >= threshold {
            let members = best.sorted { $0.endedAt < $1.endedAt }
            let ids = Set(members.map { Self.identity(panelID: $0.panelID, endedKey: $0.endedKey) })
            pool.removeAll { ids.contains(Self.identity(panelID: $0.panelID, endedKey: $0.endedKey)) }
            let mass = Mass(id: UUID(), members: members)
            masses.append(mass)
            return .formed(mass.id)
        }
        if pool.count > Self.poolLimit { pool.removeFirst(pool.count - Self.poolLimit) }
        return .none
    }

    func mass(_ id: UUID) -> Mass? { masses.first { $0.id == id } }

    /// An end an earlier launch already found: never counted, now or later.
    mutating func markSeen(panelID: UUID, endedKey: HCTerminalKey) {
        seen.insert(Self.identity(panelID: panelID, endedKey: endedKey))
    }
}

/// C11H-235: the app side of a mass outside-signal end. It is fed every
/// restore record (`HCRestoreProgress.update`) and decides nothing about a
/// single panel: each kept end still waits for the operator exactly as
/// C11H-232 left it.
///
/// - One announcement per mass end, `settle` seconds after it forms (so a
///   dozen ends decided a moment apart are announced once, with their full
///   count): one `terminal.mass_signal_end` event and one `mass_signal_end`
///   diagnostics line. It raises no flag and posts no notification.
/// - The restore strip shows every announced mass end with a waiting member,
///   counted together, with one Resume all.
/// - With the setting on (`autoResumeKey`, off by default) every kept panel of
///   the mass end resumes by itself through the restore route.
/// - Only this launch's records feed it: a record carried from an earlier
///   launch is never announced again.
@MainActor
final class HCMassSignalEnd: ObservableObject {
    static let shared = HCMassSignalEnd()

    /// "Resume agents after a mass outside-signal end". Off by default.
    static let autoResumeKey = "c11.massSignalEnd.autoResume"

    struct Incident: Identifiable, Equatable {
        let id: UUID
        /// Each member's panel and the ended terminal it answers to.
        var members: [(panelID: UUID, endedKey: HCTerminalKey)]
        var signals: [Int32]
        var startedAt: Date
        var announced = false

        static func == (a: Incident, b: Incident) -> Bool {
            a.id == b.id && a.announced == b.announced && a.signals == b.signals && a.startedAt == b.startedAt
                && a.members.map(\.panelID) == b.members.map(\.panelID)
                && a.members.map(\.endedKey) == b.members.map(\.endedKey)
        }

        var count: Int { members.count }

        /// `SIGTERM`, or a plain phrase when the members ended by different signals.
        var signalText: String {
            signals.count == 1 ? HCHostEndStatus.signalName(signals[0])
                : String(localized: "hc.massEnd.mixedSignals", defaultValue: "outside signals")
        }

        /// The strip's line.
        var headline: String {
            String(format: String(localized: "hc.massEnd.headline", defaultValue: "%1$lld agents ended by %2$@ at %3$@."),
                   count, signalText, HCHostEndStatus.displayTime(startedAt))
        }
    }

    @Published private(set) var incidents: [Incident] = []
    private(set) var detector: HCMassSignalEndDetector
    /// Seconds between a mass end forming and its announcement.
    var settle: TimeInterval

    // Seams, so tests drive the whole decision without a window.
    var autoResumeEnabled: @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: HCMassSignalEnd.autoResumeKey) }
    /// The restore record a panel holds now (nil when it holds none).
    var record: @MainActor (UUID) -> HCRestoreProgress.Record? = { HCRestoreProgress.shared.records[$0] }
    /// The restore route (banner, strip row, `restore run`). Returns a refusal or nil.
    var resume: @MainActor (UUID) -> String? = { HCRestoreProgress.shared.resume($0) }
    /// The announcement's event and diagnostics line (auto-resume).
    var report: @MainActor (Incident, Bool) -> Void = HCMassSignalEnd.reportMassEnd
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    init(window: TimeInterval = HCMassSignalEnd.defaultWindow, threshold: Int = 3,
         settle: TimeInterval = HCMassSignalEnd.defaultSettle) {
        detector = HCMassSignalEndDetector(window: window, threshold: threshold)
        self.settle = settle
    }

    nonisolated static var defaultWindow: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["C11_MASS_SIGNAL_END_WINDOW_MS"],
           let ms = Double(raw), ms > 0 { return ms / 1000 }
        return 5
    }

    nonisolated static var defaultSettle: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["C11_MASS_SIGNAL_END_SETTLE_MS"],
           let ms = Double(raw), ms >= 0 { return ms / 1000 }
        return 2
    }

    /// One restore record changed (`new` nil: it went away).
    func observe(panelID: UUID, old: HCHostEndStatus?, new: HCHostEndStatus?, carried: Bool) {
        // An earlier launch's end is never counted, even when its phase changes later.
        if carried, let new {
            detector.markSeen(panelID: panelID, endedKey: new.endedKey)
            return
        }
        // Feed: a kept outside-signal end of this launch, once it offers Resume
        // (its transcript check is done, so a resume runs in its own folder).
        guard let new, let signal = new.signal, new.offersResume, new.conversation != nil else { return }
        let end = HCMassSignalEndDetector.End(panelID: panelID, endedKey: new.endedKey, signal: signal, endedAt: new.endedAt)
        switch detector.add(end) {
        case .none:
            return
        case .formed(let id):
            guard let mass = detector.mass(id) else { return }
            incidents.append(Incident(id: id, members: mass.members.map { ($0.panelID, $0.endedKey) },
                                      signals: Self.signals(mass), startedAt: mass.start))
            scheduleAnnouncement(id)
        case .joined(let id):
            guard let mass = detector.mass(id), let index = incidents.firstIndex(where: { $0.id == id }) else { return }
            incidents[index].members = mass.members.map { ($0.panelID, $0.endedKey) }
            incidents[index].signals = Self.signals(mass)
            incidents[index].startedAt = mass.start
            // Joined after the announcement: never announced again. The
            // setting still applies, after this record update has finished.
            if incidents[index].announced, autoResumeEnabled() {
                let key = new.endedKey
                Task { @MainActor [weak self] in _ = self?.resumeMember(panelID, endedKey: key) }
            }
        }
    }

    private static func signals(_ mass: HCMassSignalEndDetector.Mass) -> [Int32] {
        Array(Set(mass.members.map(\.signal))).sorted()
    }

    private func scheduleAnnouncement(_ id: UUID) {
        let wait = settle
        Task { @MainActor [weak self] in
            await self?.sleep(wait)
            self?.announce(id)
        }
    }

    /// The one announcement of a mass end: the strip shows it, its event and
    /// log line are written, and the setting applies.
    func announce(_ id: UUID) {
        guard let index = incidents.firstIndex(where: { $0.id == id }), !incidents[index].announced else { return }
        incidents[index].announced = true
        let autoResume = autoResumeEnabled()
        report(incidents[index], autoResume)
        if autoResume { _ = resumeAll(id) }
    }

    private static func reportMassEnd(_ incident: Incident, autoResume: Bool) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        EventEmitter.shared.emitTerminalMassSignalEnd(payload: [
            "mass_end_id": incident.id.uuidString,
            "count": incident.count,
            "signals": incident.signals.map { Int($0) },
            "signal_names": incident.signals.map(HCHostEndStatus.signalName),
            "panels": incident.members.map(\.panelID.uuidString),
            "started_at": formatter.string(from: incident.startedAt),
            "auto_resume": autoResume,
        ])
        HCDiagnosticRecorder.shared.record(.massSignalEnd(id: incident.id, count: incident.count,
            signals: incident.signals, autoResume: autoResume))
    }

    /// Resume all: every member of this mass end whose record still offers
    /// Resume, once each, through the restore route (background, about 1.5 s
    /// apart, no workspace switch). A member already queued, resuming or
    /// resumed (its banner, a second click, `restore run`) no longer offers
    /// Resume and is skipped, so nothing resumes twice. Returns each member
    /// tried and its refusal, nil when it was scheduled.
    @discardableResult
    func resumeAll(_ id: UUID) -> [(panelID: UUID, refusal: String?)] {
        guard let incident = incidents.first(where: { $0.id == id }) else { return [] }
        var tried: [(UUID, String?)] = []
        for member in incident.members {
            guard let outcome = resumeMember(member.panelID, endedKey: member.endedKey) else { continue }
            tried.append((member.panelID, outcome.refusal))
        }
        return tried
    }

    struct MemberResume { let refusal: String? }

    /// Nil when the member has nothing to resume now.
    private func resumeMember(_ panelID: UUID, endedKey: HCTerminalKey) -> MemberResume? {
        guard let current = record(panelID), current.status.endedKey == endedKey,
              current.status.signal != nil, current.status.offersResume else { return nil }
        return MemberResume(refusal: resume(panelID))
    }

    /// Members of this mass end still offering Resume.
    func waiting(_ id: UUID) -> Int {
        guard let incident = incidents.first(where: { $0.id == id }) else { return 0 }
        return incident.members.filter { member in
            record(member.panelID).map { $0.status.endedKey == member.endedKey && $0.status.offersResume } ?? false
        }.count
    }

    /// The announced mass ends with a member still offering Resume.
    var waitingIncidents: [Incident] {
        incidents.filter { $0.announced && waiting($0.id) > 0 }
    }

    /// What the restore strip shows: every waiting announced mass end counted
    /// together (members, signals, the earliest start), or nil.
    var stripIncident: Incident? {
        let waiting = waitingIncidents
        guard let newest = waiting.last else { return nil }
        guard waiting.count > 1 else { return newest }
        return Incident(id: newest.id, members: waiting.flatMap(\.members),
                        signals: Array(Set(waiting.flatMap(\.signals))).sorted(),
                        startedAt: waiting.map(\.startedAt).min() ?? newest.startedAt, announced: true)
    }

    /// The strip's Resume all: every waiting member of every announced mass end,
    /// once each.
    @discardableResult
    func resumeAllWaiting() -> [(panelID: UUID, refusal: String?)] {
        waitingIncidents.flatMap { resumeAll($0.id) }
    }

    #if DEBUG
    func resetForTesting(window: TimeInterval = 5, threshold: Int = 3, settle: TimeInterval = 0) {
        detector = HCMassSignalEndDetector(window: window, threshold: threshold)
        self.settle = settle
        incidents = []
    }
    #endif
}

/// C11H-235: the one record of each outside-signal end: the
/// `outside_signal_end` diagnostics line and one `terminal.ended_by_signal`
/// event per ended terminal and panel, whichever path found it (`live`: its
/// attachment saw the end; `hidden`: a panel whose terminal was not attached;
/// `launch`: found ended at startup). A second report of the same end (a
/// republished snapshot, the other path) writes nothing.
@MainActor
enum HCOutsideSignalEndLog {
    private static var recorded = Set<String>()

    @discardableResult
    static func note(workspaceID: UUID, panelID: UUID, endedKey: HCTerminalKey, signal: Int32, kept: Bool,
                     agent: String?, endedAt: Date?, found: String) -> Bool {
        let identity = HCMassSignalEndDetector.identity(panelID: panelID, endedKey: endedKey)
        guard recorded.insert(identity).inserted else { return false }
        if recorded.count > 4096 { recorded = [identity] }
        HCDiagnosticRecorder.shared.record(.outsideSignalEnd(panelID: panelID, terminal: endedKey.localAddress,
                                                             signal: signal, kept: kept, agent: agent))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        EventEmitter.shared.emitTerminalEndedBySignal(workspace: workspaceID, panel: panelID, payload: [
            "terminal": endedKey.localAddress,
            "core_id": endedKey.owningCoreID,
            "signal": Int(signal),
            "signal_name": HCHostEndStatus.signalName(signal),
            "outcome": kept ? "kept" : "closed",
            "agent_kind": agent as Any? ?? NSNull(),
            "found": found,
            "ended_at": endedAt.map { formatter.string(from: $0) } as Any? ?? NSNull(),
        ])
        return true
    }

    #if DEBUG
    static func resetForTesting() { recorded = [] }
    #endif
}
