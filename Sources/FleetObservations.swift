import CryptoKit
import Foundation

// C11H-320: what `c11 fleet --json` needs to answer "who is stuck, why, since
// when, and what did each agent last say" without a screen read. Three
// process-local sources, each lock-guarded and read by the fleet worker:
//
// - `AgentReportStore`: what a Claude hook reported (`agent.report`): the
//   login it runs under, its final message, and why a failed turn failed.
// - `FleetScreenMonitor`: a budgeted look at idle agents' screens on the agent
//   detector's sweep, classified off-main (`input`, dialogs).
// - `FleetAgentState`: the pure rules that turn those, the journal and the
//   Supervisor's wait into a row's `blocked`, `input` and `last_turn_stop`.
//
// Nothing here is written to disk, the journal or the activity log.

/// The latest hook report per panel. Thread-safe; every method is a short
/// critical section. Text follows Settings → Data & Privacy → Keep message
/// and input text: off, the store keeps character counts and no text.
final class AgentReportStore: @unchecked Sendable {
    static let shared = AgentReportStore()

    /// More entries than this means reports for panels that do not exist.
    static let capacity = 512

    enum Event: String, Sendable {
        case sessionStart = "session_start"
        /// C11H-320 PR 3: Claude's UserPromptSubmit: a turn began, so work a
        /// Stop announced has been followed.
        case turnStart = "turn_start"
        case stop
        case stopFailure = "stop_failure"
    }

    struct Report: Equatable, Sendable {
        let panelId: UUID
        let event: Event
        var account: String? = nil
        var accountSource: String? = nil
        var lastMessage: String? = nil
        var failureCode: String? = nil
        var limit: String? = nil
        var resetsAt: Date? = nil
        var failureText: String? = nil
        /// How many background tasks were still in flight at Stop.
        var backgroundTasks: Int? = nil
        /// C11H-320 PR 3: the Stop announced work of its own
        /// (`background_tasks`, `next_step`); nil when it did not.
        var announcesWork: String? = nil
    }

    struct Message: Equatable, Sendable {
        let text: String?
        let chars: Int
        let at: Date
        var textRecorded: Bool { text != nil }
    }

    struct Failure: Equatable, Sendable {
        /// Claude's StopFailure `error` code (`rate_limit`, `server_error`, …).
        let code: String
        /// `five_hour`, `weekly`, `monthly_spend`, `other`; nil when not a limit.
        let limit: String?
        let resetsAt: Date?
        let text: String?
        let chars: Int
        let at: Date

        var isUsageLimit: Bool { code == "rate_limit" || limit != nil }
    }

    struct Background: Equatable, Sendable {
        let count: Int
        let at: Date
    }

    /// C11H-320 PR 3: when the last turn ended at Stop, and whether it
    /// announced work of its own (`background_tasks`, `next_step`).
    struct StopMark: Equatable, Sendable {
        let at: Date
        let announced: String?
    }

    struct Entry: Equatable, Sendable {
        var account: String?
        var accountSource: String?
        var lastMessage: Message?
        var failure: Failure?
        var background: Background? = nil
        var stop: StopMark? = nil
        var updatedAt: Date
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var retired = FleetRetiredPanels()

    /// Folds and keeps the report, unless its panel was closed: a late hook
    /// for a closed panel is folded for the caller and not kept.
    @discardableResult
    func record(_ report: Report, now: Date = Date(), keepText: Bool) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        let entry = Self.fold(entries[report.panelId], report, now: now, keepText: keepText)
        guard !retired.contains(report.panelId) else { return entry }
        entries[report.panelId] = entry
        if entries.count > Self.capacity,
           let oldest = entries.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        return entry
    }

    func entry(forPanel panelId: UUID) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[panelId]
    }

    func retain(livePanels: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { livePanels.contains($0.key) }
    }

    func remove(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: panelId)
    }

    /// The panel closed: forget it, and refuse its late reports.
    func retire(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: panelId)
        retired.insert(panelId)
    }

    /// The panel's terminal registered again (a move between workspaces).
    func restore(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        retired.remove(panelId)
    }

    /// Keep message and input text was switched off: drop every kept text,
    /// keeping the character counts.
    func scrubText() {
        lock.lock()
        defer { lock.unlock() }
        for (panel, var entry) in entries {
            if let message = entry.lastMessage {
                entry.lastMessage = Message(text: nil, chars: message.chars, at: message.at)
            }
            if let failure = entry.failure {
                entry.failure = Failure(code: failure.code, limit: failure.limit, resetsAt: failure.resetsAt,
                                        text: nil, chars: failure.chars, at: failure.at)
            }
            entries[panel] = entry
        }
    }

    /// Apply one report. Pure, so the rules are testable. A session start
    /// names the login and forgets the last failure (a new process); a Stop
    /// records the final message and ends the failure; a StopFailure records
    /// why the turn failed and keeps the last real message.
    static func fold(_ prior: Entry?, _ report: Report, now: Date, keepText: Bool) -> Entry {
        var entry = prior ?? Entry(updatedAt: now)
        entry.updatedAt = now
        switch report.event {
        case .sessionStart:
            entry.account = report.account
            entry.accountSource = report.account == nil ? nil : report.accountSource
            entry.failure = nil
            entry.stop = nil
        case .turnStart:
            // A new turn: the last Stop's announcement was followed, and the
            // last failed turn is over (a limit still in force fails again).
            entry.stop = nil
            entry.failure = nil
        case .stop:
            if report.account != nil {
                entry.account = report.account
                entry.accountSource = report.accountSource
            }
            if let text = report.lastMessage {
                entry.lastMessage = Message(text: keepText ? text : nil, chars: text.count, at: now)
            }
            // A Stop without the list (an older Claude) leaves no count rather than a stale one.
            entry.background = report.backgroundTasks.map { Background(count: $0, at: now) }
            entry.stop = StopMark(at: now, announced: report.announcesWork)
            entry.failure = nil
        case .stopFailure:
            if report.account != nil {
                entry.account = report.account
                entry.accountSource = report.accountSource
            }
            entry.failure = Failure(
                code: report.failureCode ?? "unknown",
                limit: report.limit,
                resetsAt: report.resetsAt,
                text: keepText ? report.failureText : nil,
                chars: report.failureText?.count ?? 0,
                at: now)
            // The failed turn ended; it announced nothing that can stall.
            entry.stop = nil
        }
        return entry
    }
}

/// Closed panels whose late reports and pending screen looks are refused.
/// Bounded: the oldest are forgotten first (a UUID is never reused).
struct FleetRetiredPanels {
    static let capacity = 1024
    private var order: [UUID] = []
    private var members: Set<UUID> = []

    func contains(_ id: UUID) -> Bool { members.contains(id) }

    mutating func insert(_ id: UUID) {
        guard members.insert(id).inserted else { return }
        order.append(id)
        if order.count > Self.capacity { members.remove(order.removeFirst()) }
    }

    mutating func remove(_ id: UUID) {
        guard members.remove(id) != nil else { return }
        order.removeAll { $0 == id }
    }
}

/// Validates `agent.report` params. Pure: no clocks or stores.
enum AgentReportParser {
    static let failureCodePattern = #"^[a-z][a-z0-9_]{0,39}$"#
    static let limits: Set<String> = ["five_hour", "weekly", "monthly_spend", "other"]
    static let accountSources: Set<String> = ["env", "claude_config_dir"]
    static let announcements: Set<String> = ["background_tasks", "next_step"]

    static func parse(_ params: [String: Any]) -> Result<AgentReportStore.Report, AgentReportParseError> {
        guard let raw = (params["surface_id"] as? String) ?? (params["panel_id"] as? String),
              let panelId = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.init("agent.report requires panel_id (a UUID)"))
        }
        guard let eventRaw = params["event"] as? String, let event = AgentReportStore.Event(rawValue: eventRaw) else {
            return .failure(.init("agent.report event must be session_start, turn_start, stop or stop_failure"))
        }
        var report = AgentReportStore.Report(panelId: panelId, event: event)
        if let value = params["account"], !(value is NSNull) {
            guard let name = ClaudeAgentReport.accountName(value as? String),
                  let source = params["account_source"] as? String, accountSources.contains(source) else {
                return .failure(.init("account must be printable text without slashes, at most 64 characters, with account_source env or claude_config_dir"))
            }
            report.account = name
            report.accountSource = source
        }
        if let value = params["last_message"], !(value is NSNull) {
            guard let text = value as? String else { return .failure(.init("last_message must be a string")) }
            report.lastMessage = ClaudeAgentReport.lastMessage(text)
        }
        if let value = params["background_tasks"], !(value is NSNull) {
            guard event == .stop, let count = FleetJSON.wholeNumber(value, in: 0...10_000) else {
                return .failure(.init("background_tasks is a whole count from 0 to 10000, on stop only"))
            }
            report.backgroundTasks = count
        }
        if let value = params["announces_work"], !(value is NSNull) {
            guard event == .stop, let code = value as? String, !FleetJSON.isBoolean(value),
                  announcements.contains(code) else {
                return .failure(.init("announces_work is background_tasks or next_step, on stop only"))
            }
            report.announcesWork = code
        }
        if event == .stopFailure {
            if let code = params["failure_code"] as? String {
                guard code.range(of: failureCodePattern, options: .regularExpression) != nil else {
                    return .failure(.init("failure_code must be a lowercase code"))
                }
                report.failureCode = code
            }
            if let limit = params["limit"] as? String {
                guard limits.contains(limit) else { return .failure(.init("limit must be five_hour, weekly, monthly_spend or other")) }
                report.limit = limit
            }
            if let value = params["resets_at_ms"], !(value is NSNull) {
                guard let ms = FleetJSON.wholeNumber(value, in: 1...FleetJSON.maxExactInteger) else {
                    return .failure(.init("resets_at_ms must be a positive epoch millisecond count"))
                }
                report.resetsAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }
            if let text = params["failure_text"] as? String {
                report.failureText = ClaudeAgentReport.lastMessage(text)
            }
        }
        return .success(report)
    }
}

struct AgentReportParseError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

extension TerminalController {
    /// `agent.report`: validate off-main and fold into the panel's entry. No
    /// main-thread work; `c11 fleet` reads the entry on its worker.
    nonisolated func v2AgentReport(params: [String: Any]) -> V2CallResult {
        Self.agentReportResult(params: params, store: .shared, now: Date(), keepText: EventEmitter.shared.keepText)
    }

    nonisolated static func agentReportResult(
        params: [String: Any], store: AgentReportStore, now: Date, keepText: Bool
    ) -> V2CallResult {
        switch AgentReportParser.parse(params) {
        case .failure(let failure):
            return .err(code: "invalid_params", message: failure.message, data: nil)
        case .success(let report):
            store.record(report, now: now, keepText: keepText)
            return .ok(["panel_id": report.panelId.uuidString, "event": report.event.rawValue, "text_recorded": keepText])
        }
    }
}

/// What the last look at an idle agent's screen showed.
struct FleetScreenLook: Equatable, Sendable {
    let state: PromptInputState
    let draftLength: Int?
    /// `permission`, `choice`, `trust`, `plan`, `resume`, `usage_limit`.
    let dialogKind: String?
    let observedAt: Date
    /// When this state (and dialog) was first seen without a break.
    let since: Date
    /// A usage-limit screen's printed reset time; nil otherwise.
    var resetsAt: Date? = nil

    static func fold(_ prior: FleetScreenLook?, observation: PromptInputObservation, resetsAt: Date? = nil,
                     at now: Date) -> FleetScreenLook {
        let classification = observation.classification
        let kind = classification.publicDialogKind(chooser: observation.chooser)
        let same = prior.map { $0.state == classification.state && $0.dialogKind == kind } ?? false
        return FleetScreenLook(state: classification.state, draftLength: classification.draftLength,
                               dialogKind: kind, observedAt: now, since: same ? prior!.since : now,
                               resetsAt: kind == "usage_limit" ? resetsAt : nil)
    }
}

/// Looks at idle agents' screens on the agent detector's sweep (every 10 s,
/// on its utility queue). Main copies bounded screen cells for as many panels
/// as fit in `hopBudgetNs`, in `order`, over up to three hops; classification and
/// bookkeeping run on this monitor's queue. A working agent is not looked at.
final class FleetScreenMonitor: @unchecked Sendable {
    static let shared = FleetScreenMonitor()

    struct Candidate: Equatable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let kind: String
    }

    /// Main's share per hop; a capture is one or two bounded native reads.
    /// A sweep takes up to `hopsPerSweep` hops, `hopSpacing` apart, so main
    /// never holds more than one short copy at a time.
    static let hopBudgetNs: UInt64 = 2_000_000
    static let hopsPerSweep = 3
    static let hopSpacing: TimeInterval = 1
    /// A look older than this is not shown.
    static let freshness: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.stage11.c11.fleet-screen", qos: .utility)
    private let lock = NSLock()
    private var looks: [UUID: FleetScreenLook] = [:]
    private var retired = FleetRetiredPanels()
    private var sampling = false
    /// The walk's position (monitor queue only): the last panel it looked at.
    private var walkCursor: UUID?
    private var sweepNumber = 0
    private var lastSweep: SweepStats?

    /// The last sweep's cost, for `fleet`'s `screen_sweep`.
    struct SweepStats: Equatable, Sendable {
        let at: Date
        /// Main time across the sweep's hops, and the longest single hop.
        let mainMs: Double
        let maxHopMs: Double
        let hops: Int
        let looked: Int
        let wanted: Int
        /// Panels with no surface read from hc's paint this sweep.
        var headlessLooked: Int = 0
    }

    var lastSweepStats: SweepStats? {
        lock.lock()
        defer { lock.unlock() }
        return lastSweep
    }

    func look(forPanel panelId: UUID) -> FleetScreenLook? {
        lock.lock()
        defer { lock.unlock() }
        return looks[panelId]
    }

    /// Keeps the look, unless the panel closed while its capture was pending.
    func record(_ observation: PromptInputObservation, panelId: UUID, resetsAt: Date? = nil, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard !retired.contains(panelId) else { return }
        looks[panelId] = FleetScreenLook.fold(looks[panelId], observation: observation, resetsAt: resetsAt, at: now)
    }

    func forget(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        looks.removeValue(forKey: panelId)
    }

    /// The panel closed: forget its look and refuse a capture still in flight.
    func retire(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        looks.removeValue(forKey: panelId)
        retired.insert(panelId)
    }

    func restore(panelId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        retired.remove(panelId)
    }

    func retain(livePanels: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        looks = looks.filter { livePanels.contains($0.key) }
    }

    /// Whether the panel is looked at: a kind whose prompt c11 can read,
    /// whose live journal does not say it is working.
    static func wantsLook(kind: String, journal: JournalSnapshot?) -> Bool {
        guard PromptInputClassifier.supportsComposer(harness: kind) else { return false }
        guard let journal, !journal.isHistorical else { return true }
        return journal.phase != .working
    }

    /// One sweep's look order. Priority panels (last seen on a dialog, then
    /// suspects; oldest look first) alternate with a walk over every wanted
    /// panel in a fixed order, which resumes after the last panel it looked
    /// at. Sweeps alternate which of the two goes first, so over any two
    /// sweeps the walk gets at least L looks, where L is the fewest looks a
    /// sweep makes: every panel is looked at within 2·⌈N/L⌉ sweeps however
    /// many dialogs persist, and a dialog that clears is seen at the next
    /// sweep while priority panels fit in half a sweep. Pure, so testable.
    static func plan(_ wanted: [Candidate], looks: [UUID: FleetScreenLook], suspects: Set<UUID> = [],
                     after cursor: UUID?, walkFirst: Bool) -> [(candidate: Candidate, walk: Bool)] {
        func rank(_ id: UUID) -> Int { looks[id]?.state == .dialog ? 0 : 1 }
        let priority = wanted
            .filter { looks[$0.panelId]?.state == .dialog || suspects.contains($0.panelId) }
            .sorted { a, b in
                if rank(a.panelId) != rank(b.panelId) { return rank(a.panelId) < rank(b.panelId) }
                let ta = looks[a.panelId]?.observedAt ?? .distantPast, tb = looks[b.panelId]?.observedAt ?? .distantPast
                if ta != tb { return ta < tb }
                return a.panelId.uuidString < b.panelId.uuidString
            }
        let ring = wanted.sorted { $0.panelId.uuidString < $1.panelId.uuidString }
        let start = cursor.flatMap { c in ring.firstIndex { $0.panelId.uuidString > c.uuidString } } ?? 0
        let walk = Array(ring[start...] + ring[..<start])
        var out: [(candidate: Candidate, walk: Bool)] = []
        var taken = Set<UUID>()
        var p = 0, w = 0
        func next(_ list: [Candidate], _ index: inout Int) -> Candidate? {
            while index < list.count {
                let candidate = list[index]; index += 1
                if !taken.contains(candidate.panelId) { return candidate }
            }
            return nil
        }
        var walkTurn = walkFirst
        while out.count < ring.count {
            if walkTurn, let candidate = next(walk, &w) { out.append((candidate, true)) }
            else if !walkTurn, let candidate = next(priority, &p) { out.append((candidate, false)) }
            else if let candidate = next(walk, &w) { out.append((candidate, true)) }
            else if let candidate = next(priority, &p) { out.append((candidate, false)) }
            else { break }
            taken.insert(out[out.count - 1].candidate.panelId)
            walkTurn.toggle()
        }
        return out
    }

    /// Where the walk resumes: after the last walked panel looked at, but
    /// never past a walked panel `waiting` for a headless read slot (the
    /// sweep's paint reads were spent), so the walk starts there next sweep.
    static func advance(_ cursor: UUID?, looked: [(candidate: Candidate, walk: Bool)],
                        waiting: Set<UUID> = []) -> UUID? {
        var last = cursor
        for entry in looked where entry.walk {
            if waiting.contains(entry.candidate.panelId) { break }
            last = entry.candidate.panelId
        }
        return last
    }

    /// A panel likely to sit on a dialog that holds it: no live journal owner
    /// (restored, not yet reporting) or a turn that failed.
    static func isSuspect(journal: JournalSnapshot?, failure: AgentReportStore.Failure?) -> Bool {
        if failure != nil { return true }
        guard let journal, !journal.isHistorical else { return true }
        return journal.phase == .error
    }

    /// The sweep runs only while `fleet` is in use: read in the last 45
    /// minutes (a 30-minute heartbeat keeps it on). The first read after a
    /// quiet spell starts a sweep at once, for the reads that follow.
    static let activeWindow: TimeInterval = 45 * 60
    /// hc paint reads per sweep for panels with no surface (each is a
    /// watch-only attach to hc, off main).
    static let headlessReadsPerSweep = 4

    private var lastFleetRead: Date?
    /// The detector's latest candidates (monitor queue only).
    private var lastCandidates: [Candidate] = []

    /// `system.fleet` was read. The first read after a quiet spell starts a
    /// sweep at once and returns true.
    @discardableResult
    func noteFleetRead(now: Date = Date()) -> Bool {
        lock.lock()
        let wasQuiet = !Self.isActive(lastRead: lastFleetRead, now: now)
        lastFleetRead = now
        lock.unlock()
        guard wasQuiet else { return false }
        queue.async { [self] in run(lastCandidates) }
        return true
    }

    /// Whether the detector's sweep at `now` looks at screens: only while
    /// `fleet` was read in the last `activeWindow`.
    func sweepIsActive(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isActive(lastRead: lastFleetRead, now: now)
    }

    static func isActive(lastRead: Date?, now: Date) -> Bool {
        guard let lastRead else { return false }
        return now.timeIntervalSince(lastRead) <= activeWindow
    }

    /// Called from the agent detector's sweep with every live agent panel.
    func sweep(_ candidates: [Candidate]) {
        queue.async { [self] in
            lastCandidates = candidates
            guard sweepIsActive() else { return }
            run(candidates)
        }
    }

    /// Sweeps started, kicked or from the detector (monitor queue only).
    private var sweepRuns = 0
    /// For tests: the sweeps started once the monitor queue has drained.
    var sweepRunsForTesting: Int { queue.sync { sweepRuns } }

    /// One sweep over `candidates` (monitor queue).
    private func run(_ candidates: [Candidate]) {
        sweepRuns += 1
        guard !sampling, !candidates.isEmpty, NSClassFromString("XCTestCase") == nil else { return }
        var wanted: [Candidate] = []
        var suspects = Set<UUID>()
        for candidate in candidates {
            let journal = JournalCoordinator.shared.snapshot(panelID: candidate.panelId)
            guard Self.wantsLook(kind: candidate.kind, journal: journal) else { continue }
            wanted.append(candidate)
            if Self.isSuspect(journal: journal, failure: AgentReportStore.shared.entry(forPanel: candidate.panelId)?.failure) {
                suspects.insert(candidate.panelId)
            }
        }
        lock.lock()
        let skipped = Set(candidates.map(\.panelId)).subtracting(wanted.map(\.panelId))
        for panel in skipped { looks.removeValue(forKey: panel) }
        let ordered = Self.plan(wanted, looks: looks, suspects: suspects, after: walkCursor,
                                walkFirst: sweepNumber % 2 == 1)
        lock.unlock()
        sweepNumber += 1
        guard !ordered.isEmpty else { return }
        sampling = true
        hop(ArraySlice(ordered), number: 1, progress: SweepProgress(wanted: ordered.count))
    }

    private struct SweepProgress {
        let wanted: Int
        var looked = 0
        var mainMs = 0.0
        var maxHopMs = 0.0
        var headless: [HeadlessRead] = []
        /// A walked headless panel found no read slot: the walk stays there.
        var walkHeld = false
    }

    /// A panel with no surface, read from hc's paint after the hops.
    private struct HeadlessRead: Sendable {
        let candidate: Candidate
        let reader: any HCComposerPaintReading
        let key: HCTerminalKey
    }

    /// One bounded main copy, then the bookkeeping here; another hop a second
    /// later while panels remain, up to `hopsPerSweep`. Headless panels cost
    /// main only a lookup: their reads run after the last hop, off main.
    private func hop(_ remaining: ArraySlice<(candidate: Candidate, walk: Bool)>, number: Int, progress: SweepProgress) {
        let headlessRoom = Self.headlessReadsPerSweep - progress.headless.count
        // Ghostty/AppKit ownership requires main for the copy only.
        DispatchQueue.main.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var captured: [((candidate: Candidate, walk: Bool), PromptRegionSnapshot?)] = []
            var headless: [HeadlessRead] = []
            var kept = Set<UUID>()
            var waiting = Set<UUID>()
            for planned in remaining {
                let candidate = planned.candidate
                if DispatchTime.now().uptimeNanoseconds - started >= Self.hopBudgetNs { break }
                guard let manager = AppDelegate.shared?.workspaceManagerFor(workspaceId: candidate.workspaceId),
                      let workspace = manager.workspaces.first(where: { $0.id == candidate.workspaceId }),
                      let terminal = workspace.terminalPanel(for: candidate.panelId) else {
                    captured.append((planned, nil)); continue
                }
                guard let surface = terminal.surface.surface else {
                    // C11H-306's paint read, for a panel that has never been shown. Past this
                    // sweep's share the panel keeps its last look and waits for a later sweep.
                    if terminal.surface.hcHeadlessBridge != nil {
                        if let reader = terminal.surface.hcSession?.session as? any HCComposerPaintReading,
                           let key = terminal.surface.hcLiveRecord?.key {
                            if headless.count < headlessRoom {
                                headless.append(HeadlessRead(candidate: candidate, reader: reader, key: key))
                            } else {
                                waiting.insert(candidate.panelId)
                            }
                        }
                        kept.insert(candidate.panelId)
                    }
                    captured.append((planned, nil)); continue
                }
                captured.append((planned, TerminalController.shared.capturePromptInputRegion(
                    surface: surface, harness: candidate.kind)))
            }
            let done = captured
            let reads = headless
            let keep = kept
            let wait = waiting
            let hopMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            queue.async { [self] in
                let now = Date()
                if !progress.walkHeld {
                    walkCursor = Self.advance(walkCursor, looked: done.map(\.0), waiting: wait)
                }
                var looked = 0
                for (planned, region) in done {
                    let candidate = planned.candidate
                    guard let region else {
                        if !keep.contains(candidate.panelId) { forget(panelId: candidate.panelId) }
                        continue
                    }
                    looked += 1
                    record(Self.observe(region, harness: candidate.kind, now: now), region: region,
                           panelId: candidate.panelId, now: now)
                }
                var next = progress
                next.looked += looked
                next.mainMs += hopMs
                next.maxHopMs = max(next.maxHopMs, hopMs)
                next.headless += reads
                next.walkHeld = progress.walkHeld || done.contains { $0.0.walk && wait.contains($0.0.candidate.panelId) }
                let rest = remaining.dropFirst(done.count)
                if !rest.isEmpty, !done.isEmpty, number < Self.hopsPerSweep {
                    queue.asyncAfter(deadline: .now() + Self.hopSpacing) { [self] in
                        hop(rest, number: number + 1, progress: next)
                    }
                    return
                }
                finish(next, hops: number)
            }
        }
    }

    private static func observe(_ region: PromptRegionSnapshot, harness: String, now: Date) -> PromptInputObservation {
        PromptInputObservation.activeScreen(region, harness: harness)
    }

    private func record(_ observation: PromptInputObservation, region: PromptRegionSnapshot, panelId: UUID, now: Date) {
        let resets = observation.classification.dialogKind == PromptChooserKind.usageLimit.rawValue
            ? region.screenBottom.flatMap { PromptInputClassifier.claudeLimitResetsAt($0, now: now) } : nil
        record(observation, panelId: panelId, resetsAt: resets, at: now)
    }

    /// The headless reads, one at a time, then the sweep's stats.
    private func finish(_ progress: SweepProgress, hops: Int) {
        let reads = progress.headless
        Task.detached(priority: .utility) { [self] in
            var headlessLooked = 0
            for read in reads {
                let result = await read.reader.readComposerPaint(read.key)
                guard case .success(let paint) = result,
                      let screen = HCPaintScreen.replay(paint.bytes, columns: Int(paint.grid.columns), rows: Int(paint.grid.rows)),
                      screen.isComplete, let region = screen.promptRegion(harness: read.candidate.kind) else { continue }
                headlessLooked += 1
                let now = Date()
                record(Self.observe(region, harness: read.candidate.kind, now: now), region: region,
                       panelId: read.candidate.panelId, now: now)
            }
            let looked = headlessLooked
            queue.async { [self] in
                lock.lock()
                lastSweep = SweepStats(at: Date(), mainMs: progress.mainMs, maxHopMs: progress.maxHopMs, hops: hops,
                                       looked: progress.looked + looked, wanted: progress.wanted, headlessLooked: looked)
                lock.unlock()
                sampling = false
                // PR 3: a dialog this sweep found is announced now, not at the next tick.
                AgentEdgeMonitor.shared.reevaluate()
            }
        }
    }
}

/// The pure rules behind a fleet row's `blocked`, `input` and
/// `last_turn_stop`. Inputs are value copies; nothing here reads a store.
enum FleetAgentState {
    struct Journal: Equatable {
        let phase: JournalPhase
        let reason: JournalReason?
        let sinceMs: Int64
        let live: Bool
        let usageLimit: JournalUsageLimitKind?
        let turnOutcome: String?

        init(_ snapshot: JournalSnapshot) {
            phase = snapshot.phase
            reason = snapshot.reason
            sinceMs = snapshot.sinceMs
            live = !snapshot.isHistorical
            usageLimit = snapshot.usageLimit?.kind
            turnOutcome = snapshot.turnOutcome
        }

        init(phase: JournalPhase, reason: JournalReason? = nil, sinceMs: Int64 = 0, live: Bool = true,
             usageLimit: JournalUsageLimitKind? = nil, turnOutcome: String? = nil) {
            self.phase = phase
            self.reason = reason
            self.sinceMs = sinceMs
            self.live = live
            self.usageLimit = usageLimit
            self.turnOutcome = turnOutcome
        }

        var isWorking: Bool { live && phase == .working }
    }

    struct Wait: Equatable {
        let kind: String
        let source: String?
        let sinceMs: Int64?

        /// From `SupervisorMonitor.readback`; nil when nothing waits.
        init?(readback: [String: Any]) {
            guard readback["waiting_on_permission"] as? Bool == true, let kind = readback["wait_kind"] as? String else { return nil }
            self.kind = kind
            source = readback["wait_source"] as? String
            sinceMs = (readback["wait_since_ms"] as? NSNumber)?.int64Value
        }

        init(kind: String, source: String? = nil, sinceMs: Int64? = nil) {
            self.kind = kind
            self.source = source
            self.sinceMs = sinceMs
        }
    }

    struct Blocked: Equatable {
        let reason: String
        let since: Date?
        let source: String
        let detail: String?
        let resetsAt: Date?
    }

    /// The look, when it is fresh and the agent is not working.
    static func currentLook(_ look: FleetScreenLook?, journal: Journal?, now: Date) -> FleetScreenLook? {
        guard let look, journal?.isWorking != true,
              now.timeIntervalSince(look.observedAt) <= FleetScreenMonitor.freshness else { return nil }
        return look
    }

    /// Why the agent cannot go on without someone, strongest evidence first:
    /// a live dialog on its screen, the Supervisor's wait (hook asks, screen
    /// confirmed), then a failed turn (hook report, then journal). Nil for an
    /// agent that is working, idle, or done.
    static func blocked(
        journal: Journal?, wait: Wait?, look: FleetScreenLook?, failure: AgentReportStore.Failure?, now: Date
    ) -> Blocked? {
        if journal?.isWorking == true { return nil }
        let limit = failure?.isUsageLimit == true ? failure : nil
        if let look = currentLook(look, journal: journal, now: now), look.state == .dialog, let kind = look.dialogKind {
            var found = dialog(kind, since: look.since, source: "screen", limit: limit)
            if found.reason == "usage_limit", found.resetsAt == nil, let printed = look.resetsAt {
                found = Blocked(reason: found.reason, since: found.since, source: found.source,
                                detail: found.detail, resetsAt: printed)
            }
            return found
        }
        if let wait {
            let since = wait.sinceMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            return dialog(wait.kind, since: since, source: wait.source == "active_screen" ? "screen" : "journal", limit: limit)
        }
        let journalFailed = journal.map { $0.live && $0.phase == .error } ?? false
        // A hook-reported failure counts while the journal agrees the turn
        // failed, or when the journal has no live owner to say otherwise.
        if let failure, journalFailed || journal?.live != true {
            return Blocked(reason: failure.isUsageLimit ? "usage_limit" : "api_error",
                           since: failure.at, source: "hook",
                           detail: failure.isUsageLimit ? failure.limit : failure.code,
                           resetsAt: failure.resetsAt)
        }
        if let journal, journalFailed {
            let since = Date(timeIntervalSince1970: Double(journal.sinceMs) / 1000)
            if journal.reason == .usageLimit || journal.usageLimit != nil {
                let detail: String? = journal.usageLimit.map { $0 == .monthlySpend ? "monthly_spend" : "five_hour" }
                return Blocked(reason: "usage_limit", since: since, source: "journal", detail: detail, resetsAt: nil)
            }
            return Blocked(reason: "api_error", since: since, source: "journal", detail: nil, resetsAt: nil)
        }
        return nil
    }

    /// A named dialog as a blocked reason. Every other dialog the classifier
    /// or the Supervisor names (`question`, `plan_review`, `choice`, `trust`,
    /// `plan`) is a question, with its kind as the detail.
    static func dialog(_ kind: String, since: Date?, source: String, limit: AgentReportStore.Failure?) -> Blocked {
        switch kind {
        case "resume":
            return Blocked(reason: "resume_dialog", since: since, source: source, detail: nil, resetsAt: nil)
        case "usage_limit":
            return Blocked(reason: "usage_limit", since: since, source: source, detail: limit?.limit, resetsAt: limit?.resetsAt)
        case "permission":
            return Blocked(reason: "permission_prompt", since: since, source: source, detail: nil, resetsAt: nil)
        default:
            return Blocked(reason: "question_dialog", since: since, source: source, detail: kind, resetsAt: nil)
        }
    }

    /// C11H-320 PR 3: the Supervisor's own no-progress stall, from its readback.
    struct SupervisorStall: Equatable {
        let sinceMs: Int64
        let lastProgressAtMs: Int64?

        /// Nil unless the readback says the agent is stalled.
        init?(readback: [String: Any]) {
            guard readback["stalled"] as? Bool == true,
                  let since = (readback["stall_since_ms"] as? NSNumber)?.int64Value else { return nil }
            sinceMs = since
            lastProgressAtMs = (readback["last_progress_at_ms"] as? NSNumber)?.int64Value
        }

        init(sinceMs: Int64, lastProgressAtMs: Int64? = nil) {
            self.sinceMs = sinceMs
            self.lastProgressAtMs = lastProgressAtMs
        }
    }

    /// Why an agent that nobody is holding has gone quiet.
    struct Stalled: Equatable {
        /// `no_progress` (working, no output) or `announced_work` (the turn
        /// ended announcing work of its own and nothing followed).
        let reason: String
        let since: Date
        /// For `announced_work`: `background_tasks` or `next_step`.
        let detail: String?
        let thresholdSeconds: Double
        let lastProgressAt: Date?
        let turnEndedAt: Date?
    }

    /// The stall threshold, the Supervisor's own setting (minutes, default 10).
    static func stallThreshold(_ defaults: UserDefaults = .standard) -> TimeInterval {
        SupervisorProjection.thresholdMinutes(defaults.double(forKey: "c11.supervisor.stallMinutes")) * 60
    }

    /// The agent's stall, or nil. A blocked agent is never also stalled (the
    /// block says more). The Supervisor's no-progress stall comes first; else
    /// a live, idle agent whose last Stop announced work, with no turn
    /// started since and `threshold` passed, has stalled on that work.
    static func stalled(
        journal: Journal?, supervisor: SupervisorStall?, stop: AgentReportStore.StopMark?,
        turnStartedMs: Int64?, blocked: Blocked?, now: Date, threshold: TimeInterval
    ) -> Stalled? {
        guard blocked == nil else { return nil }
        func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        if let supervisor, let since = date(supervisor.sinceMs) {
            return Stalled(reason: "no_progress", since: since, detail: nil, thresholdSeconds: threshold,
                           lastProgressAt: date(supervisor.lastProgressAtMs), turnEndedAt: nil)
        }
        // The hook's own marks say what followed (a turn start clears the
        // mark, a Stop replaces it); a live journal that says working or
        // failed overrides, and a turn it saw start after the Stop followed it.
        guard journal?.isWorking != true, !(journal.map { $0.live && $0.phase == .error } ?? false),
              let stop, let announced = stop.announced else { return nil }
        let stopMs = Int64((stop.at.timeIntervalSince1970 * 1000).rounded())
        if let turnStartedMs, turnStartedMs > stopMs { return nil }
        let due = stop.at.addingTimeInterval(threshold)
        guard now >= due else { return nil }
        return Stalled(reason: "announced_work", since: due, detail: announced, thresholdSeconds: threshold,
                       lastProgressAt: nil, turnEndedAt: stop.at)
    }

    /// How the agent's last turn ended: `done`, `interrupted`, `usage_limit`
    /// or `api_error`; nil while a turn runs or when nothing is known.
    static func lastTurnStop(journal: Journal?, failure: AgentReportStore.Failure?) -> (reason: String, text: String?)? {
        if journal?.isWorking == true { return nil }
        if let failure, journal.map({ !$0.live || $0.phase == .error }) ?? true {
            return (failure.isUsageLimit ? "usage_limit" : "api_error", failure.text)
        }
        guard let journal, journal.live else { return nil }
        if journal.phase == .error {
            return (journal.reason == .usageLimit || journal.usageLimit != nil ? "usage_limit" : "api_error", nil)
        }
        switch journal.turnOutcome {
        case "completed": return ("done", nil)
        case "interrupted": return ("interrupted", nil)
        default: return nil
        }
    }
}

// MARK: - PR 2: filters, deltas and shared date text

/// `system.fleet`'s optional filters (C11H-320 ask 5) and delta cursor
/// (ask 6). Refs are resolved to UUIDs in fleet's main copy, against the
/// same handles `tree` prints. Several filters AND together; they narrow
/// `panels` only.
struct FleetQuery: Equatable {
    enum Since: Equatable {
        case seq(Int)
        case time(Date)
    }

    var workspace: String? = nil
    var group: String? = nil
    var lifecycles: Set<String>? = nil
    var flagged: Bool? = nil
    var blocked: Bool? = nil
    /// C11H-320 PR 3: rows with (or without) a `stalled` verdict.
    var stalled: Bool? = nil
    var parent: String? = nil
    var since: Since? = nil

    /// Resolved in the main copy: the workspace and parent panel UUIDs.
    var workspaceId: UUID? = nil
    var parentId: UUID? = nil
    /// The groups `group` names (by id, ref or name), resolved in the main copy.
    var groupIds: Set<UUID>? = nil
    /// Why a ref matched nothing live; the worker answers `not_found` with it.
    var notFound: String? = nil

    static let lifecycleWords: Set<String> = ["working", "waiting", "idle", "cold"]

    static func parse(_ params: [String: Any]) -> Result<FleetQuery, FleetQueryError> {
        var query = FleetQuery()
        let known: Set<String> = ["workspace", "group", "lifecycle", "flagged", "blocked", "stalled", "parent", "since"]
        if let unknown = params.keys.first(where: { !known.contains($0) }) {
            return .failure(.init("system.fleet does not take \(unknown)"))
        }
        func text(_ key: String) -> Result<String?, FleetQueryError> {
            guard let value = params[key], !(value is NSNull) else { return .success(nil) }
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
                  string.count <= 128 else { return .failure(.init("\(key) must be a non-empty string")) }
            return .success(string)
        }
        func flag(_ key: String) -> Result<Bool?, FleetQueryError> {
            guard let value = params[key], !(value is NSNull) else { return .success(nil) }
            guard FleetJSON.isBoolean(value), let bool = value as? Bool else {
                return .failure(.init("\(key) must be true or false"))
            }
            return .success(bool)
        }
        switch (text("workspace"), text("group"), text("parent"), flag("flagged"), flag("blocked")) {
        case (.success(let w), .success(let g), .success(let p), .success(let f), .success(let b)):
            query.workspace = w; query.group = g; query.parent = p; query.flagged = f; query.blocked = b
        case (.failure(let e), _, _, _, _), (_, .failure(let e), _, _, _), (_, _, .failure(let e), _, _),
             (_, _, _, .failure(let e), _), (_, _, _, _, .failure(let e)):
            return .failure(e)
        }
        switch flag("stalled") {
        case .success(let value): query.stalled = value
        case .failure(let e): return .failure(e)
        }
        if let raw = params["lifecycle"], !(raw is NSNull) {
            let words = (raw as? [String]) ?? (raw as? String).map { $0.split(separator: ",").map(String.init) } ?? []
            let set = Set(words.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            guard !set.isEmpty, set.isSubset(of: lifecycleWords) else {
                return .failure(.init("lifecycle takes working, waiting, idle or cold"))
            }
            query.lifecycles = set
        }
        if let raw = params["since"], !(raw is NSNull) {
            if let seq = FleetJSON.wholeNumber(raw, in: 0...FleetJSON.maxExactInteger) {
                query.since = .seq(seq)
            } else if let string = raw as? String, let seq = Int(string), seq >= 0 {
                query.since = .seq(seq)
            } else if let string = raw as? String, let date = Self.isoDate(string) {
                query.since = .time(date)
            } else {
                return .failure(.init("since takes a fleet_seq number or an ISO 8601 time"))
            }
        }
        return .success(query)
    }

    /// ISO 8601, with or without fractional seconds.
    static func isoDate(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Whether any filter narrows the rows.
    var hasFilters: Bool {
        workspace != nil || workspaceId != nil || group != nil || groupIds != nil || lifecycles != nil
            || flagged != nil || blocked != nil || stalled != nil || parent != nil || parentId != nil
    }

    func admits(_ row: [String: Any]) -> Bool {
        if let workspaceId, (row["workspace_id"] as? String)?.uppercased() != workspaceId.uuidString { return false }
        if group != nil || groupIds != nil {
            guard let id = (row["workspace_group_id"] as? String).flatMap(UUID.init(uuidString:)),
                  groupIds?.contains(id) == true else { return false }
        }
        if let lifecycles, !lifecycles.contains(row["lifecycle"] as? String ?? "") { return false }
        if let flagged, (row["flag"] as? Bool ?? false) != flagged { return false }
        if let blocked, !(row["blocked"] is NSNull || row["blocked"] == nil) != blocked { return false }
        if let stalled, !(row["stalled"] is NSNull || row["stalled"] == nil) != stalled { return false }
        if let parentId, (row["parent_panel_id"] as? String)?.uppercased() != parentId.uuidString { return false }
        return true
    }
}

/// JSON values as `JSONSerialization` hands them over: every number and
/// Boolean is an `NSNumber`, and 0 and 1 also cast to `Bool`.
enum FleetJSON {
    /// The largest integer a JSON number carries exactly (2^53).
    static let maxExactInteger = 1 << 53

    /// A JSON `true`/`false`, told apart from 0 and 1 by its CF type.
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// A whole JSON number within `range`; nil for a Boolean, a fraction or text.
    static func wholeNumber(_ value: Any, in range: ClosedRange<Int>) -> Int? {
        guard !isBoolean(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(range.lowerBound), double <= Double(range.upperBound) else { return nil }
        return Int(double)
    }
}

struct FleetQueryError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// When each agent row last changed, for `fleet --since` (C11H-320 ask 6).
/// A change is seen at read time: a row's fingerprint is a SHA-256 of its
/// JSON without pure clocks, so it holds no row text. Process-local, so `fleet_seq` starts at this run's first read
/// in Unix milliseconds: every cursor an earlier run handed out lies below it.
final class FleetDeltaTracker: @unchecked Sendable {
    static let shared = FleetDeltaTracker()
    static let removedCapacity = 1024

    /// Row keys (and nested `object.key`s) that only tick with the clock.
    static let clockKeys: Set<String> = ["last_seen_at", "being_seen", "changed_seq", "changed_at"]
    static let nestedClockKeys: [String: Set<String>] = [
        "input": ["observed_at"],
        "mailbox_unread": ["oldest_age_seconds", "reason_text"],
    ]

    struct Change: Equatable {
        let seq: Int
        let at: Date
    }

    struct Removal: Equatable {
        let panelId: UUID
        let seq: Int
        let at: Date
    }

    /// One read folded: the current `fleet_seq`, each row's last change, the
    /// removals kept, and the floor below which a cursor gets no delta.
    struct Read: Equatable {
        let seq: Int
        let changes: [UUID: Change]
        let removed: [Removal]
        /// This run's base, raised to the newest removal dropped from the
        /// bounded list; `floorAt` is the first read's time, raised the same way.
        let floorSeq: Int
        let floorAt: Date
        /// This read's time: a time cursor after it is from the future.
        var at: Date = .distantFuture

        /// A cursor this run cannot answer exactly (from an earlier run, from
        /// the future, or older than the removals kept) gets every row.
        func isFull(_ since: FleetQuery.Since) -> Bool {
            switch since {
            case .seq(let cursor): return cursor < floorSeq || cursor > seq
            case .time(let cursor): return cursor < floorAt || cursor > at
            }
        }
    }

    private let lock = NSLock()
    private var seq: Int
    private var floorSeq: Int
    private var floorAt: Date?
    private var rows: [UUID: (fingerprint: Data, change: Change)] = [:]
    private var removed: [Removal] = []

    init(base: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        seq = base
        floorSeq = base
    }

    static func fingerprint(_ row: [String: Any]) -> Data {
        var stable = row
        for key in clockKeys { stable.removeValue(forKey: key) }
        // A title's status glyph (Claude's ✳ idle, ⠂/⠐ thinking, any spinner frame) is not a change.
        if let title = stable["panel_title"] as? String { stable["panel_title"] = titleText(title) }
        for (key, nested) in nestedClockKeys {
            if var object = stable[key] as? [String: Any] {
                for inner in nested { object.removeValue(forKey: inner) }
                stable[key] = object
            }
        }
        // A digest, so no row text (a last message, a flag reason) outlives its row here.
        // A value JSON cannot hold (a NaN) would trap in `data`; such a row degrades to its description.
        let json = JSONSerialization.isValidJSONObject(stable)
            ? (try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys])) ?? Data()
            : Data(stable.keys.sorted().map { "\($0)=\(String(describing: stable[$0]!))" }.joined(separator: "\u{1F}").utf8)
        return Data(SHA256.hash(data: json))
    }

    /// A title without its single-glyph status tokens: Braille cells and the
    /// spinner frames `TerminalTitleChurnFilter` already ignores.
    static func titleText(_ title: String) -> String {
        let tokens = title.split(whereSeparator: { $0.isWhitespace })
        return tokens.filter { token in
            guard token.count == 1, let scalar = token.unicodeScalars.first, token.unicodeScalars.count == 1 else { return true }
            return !(0x2800...0x28FF).contains(scalar.value) && !TerminalTitleChurnFilter.isSpinnerFrame(token.first!)
        }.joined(separator: " ")
    }

    /// Fold one read of every row.
    func observe(_ all: [UUID: [String: Any]], now: Date) -> Read {
        let prints = all.mapValues(Self.fingerprint)
        lock.lock()
        defer { lock.unlock() }
        if floorAt == nil { floorAt = now }
        let gone = Set(rows.keys).subtracting(prints.keys)
        let changed = prints.filter { rows[$0.key]?.fingerprint != $0.value }
        if !changed.isEmpty || !gone.isEmpty {
            seq += 1
            for (id, print) in changed { rows[id] = (print, Change(seq: seq, at: now)) }
            // A panel whose agent came back is a row again, not a removal.
            let back = Set(changed.keys)
            removed.removeAll { back.contains($0.panelId) }
            for id in gone {
                rows.removeValue(forKey: id)
                removed.append(Removal(panelId: id, seq: seq, at: now))
            }
            if removed.count > Self.removedCapacity {
                let dropped = removed.prefix(removed.count - Self.removedCapacity)
                if let newest = dropped.last {
                    floorSeq = max(floorSeq, newest.seq)
                    floorAt = max(floorAt ?? newest.at, newest.at)
                }
                removed.removeFirst(dropped.count)
            }
        }
        return Read(seq: seq, changes: rows.mapValues(\.change), removed: removed,
                    floorSeq: floorSeq, floorAt: floorAt ?? now, at: now)
    }
}

/// ISO 8601 text for the observation fields' dates (`blocked`, `input`,
/// `last_message`, `background_tasks`, `changed_at`), formatted once per
/// distinct instant in a document; looks taken in one sweep hop share theirs.
/// C11H-320 PR 3: a model's context window for `fleet`'s `context.limit`,
/// from the model catalog's raw records of the row's own harness only (a
/// codex row reads codex's list; a claude-code row reads Claude Code's,
/// which publishes no windows). An id names one route exactly; a bare id
/// counts every route the harness lists for it. Records with no window, or
/// windows that disagree, give nil: never another route's number, never a
/// guess. The maps are rebuilt only when the catalog changes. Thread-safe.
final class FleetContextLimits: @unchecked Sendable {
    static let shared = FleetContextLimits()

    private let lock = NSLock()
    private let records: () -> [RawCatalogRecord]
    private let stamp: () -> String
    private var built: String?
    /// harness → lowercased raw id → each record's window (nil: none published).
    private var exact: [String: [String: [Int?]]] = [:]
    /// harness → the raw id's last path component → each record's window.
    private var bare: [String: [String: [Int?]]] = [:]

    init(records: @escaping () -> [RawCatalogRecord] = { ModelCatalogStore.shared.records },
         stamp: @escaping () -> String = {
             let index = ModelCatalogStore.shared.index
             return "\(index.source.rawValue)|\(index.generatedAt?.timeIntervalSince1970 ?? 0)|\(index.providers.count)"
         }) {
        self.records = records
        self.stamp = stamp
    }

    func limit(forModel model: String, agent: String) -> Int? {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }
        let key = stamp()
        lock.lock()
        defer { lock.unlock() }
        if built != key {
            (exact, bare) = Self.maps(records())
            built = key
        }
        let found = exact[agent]?[id] ?? (id.contains("/") ? nil : bare[agent]?[id]) ?? []
        guard let first = found.first, let window = first, found.allSatisfy({ $0 == window }) else { return nil }
        return window
    }

    static func maps(_ records: [RawCatalogRecord]) -> (exact: [String: [String: [Int?]]], bare: [String: [String: [Int?]]]) {
        var exact: [String: [String: [Int?]]] = [:]
        var bare: [String: [String: [Int?]]] = [:]
        for record in records {
            let id = record.rawID.lowercased()
            let window = record.contextWindow.flatMap { $0 > 0 ? $0 : nil }
            exact[record.harness, default: [:]][id, default: []].append(window)
            let tail = id.split(separator: "/").last.map(String.init) ?? id
            bare[record.harness, default: [:]][tail, default: []].append(window)
        }
        return (exact, bare)
    }
}

final class FleetDateText {
    private let formatter: ISO8601DateFormatter
    private var cache: [Date: String] = [:]

    init(_ formatter: ISO8601DateFormatter = ISO8601DateFormatter()) { self.formatter = formatter }

    func string(_ date: Date) -> String {
        if let hit = cache[date] { return hit }
        let text = formatter.string(from: date)
        cache[date] = text
        return text
    }

    func value(_ date: Date?) -> Any { date.map(string) as Any? ?? NSNull() }
}

// MARK: - PR 3: agent edge events (ask 7)

/// What the edge monitor last announced for one agent panel.
struct AgentEdgeState {
    var workspaceId: UUID
    var agent: String
    var blocked: FleetAgentState.Blocked?
    /// The block came from a fresh look at a dialog on the screen.
    var blockedFromLook = false
    var stalled: FleetAgentState.Stalled?
}

/// The pure rules that turn one agent's verdicts into `agent.*` edges.
enum AgentEdges {
    struct Edge {
        let type: EventEnvelope.EventType
        let payload: [String: Any]
    }

    /// What the monitor saw beside the verdicts.
    struct Evidence: Equatable {
        /// The journal says a turn is running.
        var working = false
        /// A fresh look shows a composer (empty, suggestion or draft): the
        /// screen holds no dialog. Unknown or unavailable reads are not this.
        var composerSeen = false
        /// The block, if any, comes from a fresh look at a dialog.
        var blockedFromLook = false
    }

    static func ms(_ date: Date?) -> Any {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } as Any? ?? NSNull()
    }

    /// One evaluation. A block ends only on evidence: a block read from the
    /// screen whose look merely went stale (or read unknown) is held, since
    /// an unread screen is not an answered dialog.
    static func step(prior: AgentEdgeState?, workspaceId: UUID, agent: String,
                     blocked: FleetAgentState.Blocked?, stalled: FleetAgentState.Stalled?,
                     evidence: Evidence) -> (state: AgentEdgeState, edges: [Edge]) {
        var state = prior ?? AgentEdgeState(workspaceId: workspaceId, agent: agent)
        state.workspaceId = workspaceId
        state.agent = agent
        var edges: [Edge] = []
        switch (state.blocked, blocked) {
        case (nil, let now?):
            edges.append(blockedEdge(now, previous: nil, agent: agent))
            state.blocked = now; state.blockedFromLook = evidence.blockedFromLook
        case (let was?, let now?):
            if was.reason != now.reason { edges.append(blockedEdge(now, previous: was.reason, agent: agent)) }
            state.blocked = now; state.blockedFromLook = evidence.blockedFromLook
        case (let was?, nil):
            if state.blockedFromLook, !evidence.working, !evidence.composerSeen { break }
            let by = evidence.working ? "turn_started" : (evidence.composerSeen ? "screen_cleared" : "cleared")
            edges.append(unblockedEdge(was, by: by, agent: agent))
            state.blocked = nil; state.blockedFromLook = false
        case (nil, nil):
            break
        }
        // A held block keeps an agent from being called stalled.
        let effectiveStall = state.blocked == nil ? stalled : nil
        switch (state.stalled, effectiveStall) {
        case (nil, let now?):
            edges.append(stalledEdge(now, previous: nil, agent: agent))
            state.stalled = now
        case (let was?, let now?):
            if was.reason != now.reason { edges.append(stalledEdge(now, previous: was.reason, agent: agent)) }
            state.stalled = now
        case (let was?, nil):
            let by: String
            if state.blocked != nil { by = "blocked" }
            else if was.reason == "no_progress" { by = evidence.working ? "progress" : "turn_ended" }
            else { by = "turn_started" }
            edges.append(unstalledEdge(was, by: by, agent: agent))
            state.stalled = nil
        case (nil, nil):
            break
        }
        return (state, edges)
    }

    /// The panel closed or its agent left: end what was announced.
    static func gone(_ state: AgentEdgeState) -> [Edge] {
        var edges: [Edge] = []
        if let blocked = state.blocked { edges.append(unblockedEdge(blocked, by: "gone", agent: state.agent)) }
        if let stalled = state.stalled { edges.append(unstalledEdge(stalled, by: "gone", agent: state.agent)) }
        return edges
    }

    static func blockedEdge(_ value: FleetAgentState.Blocked, previous: String?, agent: String) -> Edge {
        Edge(type: .agentBlocked, payload: [
            "agent": agent, "reason": value.reason, "since_ms": ms(value.since), "source": value.source,
            "detail": value.detail as Any? ?? NSNull(), "resets_at_ms": ms(value.resetsAt),
            "previous_reason": previous as Any? ?? NSNull(),
        ])
    }

    static func unblockedEdge(_ value: FleetAgentState.Blocked, by: String, agent: String) -> Edge {
        Edge(type: .agentUnblocked, payload: [
            "agent": agent, "reason": value.reason, "since_ms": ms(value.since), "cleared_by": by,
        ])
    }

    static func stalledEdge(_ value: FleetAgentState.Stalled, previous: String?, agent: String) -> Edge {
        Edge(type: .agentStalled, payload: [
            "agent": agent, "reason": value.reason, "since_ms": ms(value.since),
            "detail": value.detail as Any? ?? NSNull(), "threshold_seconds": value.thresholdSeconds,
            "last_progress_at_ms": ms(value.lastProgressAt), "turn_ended_at_ms": ms(value.turnEndedAt),
            "previous_reason": previous as Any? ?? NSNull(),
        ])
    }

    static func unstalledEdge(_ value: FleetAgentState.Stalled, by: String, agent: String) -> Edge {
        Edge(type: .agentUnstalled, payload: [
            "agent": agent, "reason": value.reason, "since_ms": ms(value.since), "cleared_by": by,
        ])
    }
}

/// C11H-320 PR 3 (ask 7): announces each agent's `blocked` and `stalled`
/// verdicts as `agent.*` events, so a watcher wakes on a dead seat instead
/// of polling. The verdicts are `c11 fleet`'s own rules over the same
/// lock-guarded stores; this only finds their edges. It runs on the agent
/// detector's 10 s sweep and when a screen sweep finishes, on its own utility
/// queue, with no main hop, file or journal write. Its only state is the last
/// edge per live agent panel, forgotten when the panel goes and empty at
/// launch (current blocks are announced again once).
final class AgentEdgeMonitor: @unchecked Sendable {
    static let shared = AgentEdgeMonitor()

    /// The stores a verdict reads, behind seams for tests.
    struct Inputs {
        var journal: (UUID) -> FleetAgentState.Journal? = {
            JournalCoordinator.shared.snapshot(panelID: $0).map(FleetAgentState.Journal.init)
        }
        var readback: (UUID) -> [String: Any] = { SupervisorMonitor.shared.readback(panel: $0) }
        var look: (UUID) -> FleetScreenLook? = { FleetScreenMonitor.shared.look(forPanel: $0) }
        var report: (UUID) -> AgentReportStore.Entry? = { AgentReportStore.shared.entry(forPanel: $0) }
        var turnStartedMs: (UUID) -> Int64? = { JournalCoordinator.shared.cachedTurnStartedMs(panelID: $0) }
        var threshold: () -> TimeInterval = { FleetAgentState.stallThreshold() }
        /// The panel's declared `terminal_type`, read only when the detected
        /// foreground is neither a shell nor an agent (an editor the agent
        /// opened), as fleet resolves it.
        var declaredKind: (_ workspace: UUID, _ panel: UUID) -> String? = { workspace, panel in
            PanelMetadataStore.shared.metadataValue(workspaceId: workspace, surfaceId: panel,
                                                    key: MetadataKey.terminalType) as? String
        }
    }

    /// The candidate's agent kind as fleet resolves it (a detected shell is
    /// none; a detected agent is itself; anything else falls back to the
    /// declared type), or nil.
    func agentKind(_ candidate: FleetScreenMonitor.Candidate) -> String? {
        let detected = candidate.kind
        let declared = detected == "shell" || AreaSizePolicy.isAgentKind(detected)
            ? nil : inputs.declaredKind(candidate.workspaceId, candidate.panelId)
        let kind = PanelActivityTerminalKindResolver.resolve(detectedTerminalType: detected, declaredTerminalType: declared)
        return AreaSizePolicy.isAgentKind(kind) ? kind : nil
    }

    struct RunStats: Equatable, Sendable {
        let at: Date
        let agents: Int
        let ms: Double
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.agent-edges", qos: .utility)
    private let inputs: Inputs
    private let emitter: (EventEnvelope.EventType, UUID, UUID, [String: Any]) -> Void
    /// Monitor queue only.
    private var states: [UUID: AgentEdgeState] = [:]
    private var lastCandidates: [FleetScreenMonitor.Candidate] = []
    private let lock = NSLock()
    private var lastRun: RunStats?

    init(inputs: Inputs = Inputs(),
         emitter: @escaping (EventEnvelope.EventType, UUID, UUID, [String: Any]) -> Void = { type, workspace, panel, payload in
             EventEmitter.shared.emitAgent(type, workspace: workspace, panel: panel, payload: payload)
         }) {
        self.inputs = inputs
        self.emitter = emitter
    }

    /// The last evaluation's cost, for `fleet`'s `agent_edges`.
    var lastRunStats: RunStats? {
        lock.lock()
        defer { lock.unlock() }
        return lastRun
    }

    /// The detector's sweep: every live panel with a detected kind.
    func evaluate(_ candidates: [FleetScreenMonitor.Candidate], now: Date? = nil) {
        queue.async { [self] in
            lastCandidates = candidates
            run(candidates, now: now ?? Date())
        }
    }

    /// Again over the last candidates (a screen sweep finished).
    func reevaluate() {
        queue.async { [self] in run(lastCandidates, now: Date()) }
    }

    func drainForTesting() { queue.sync {} }

    private func run(_ candidates: [FleetScreenMonitor.Candidate], now: Date) {
        let started = DispatchTime.now().uptimeNanoseconds
        let threshold = inputs.threshold()
        var live = Set<UUID>()
        for candidate in candidates {
            let id = candidate.panelId
            guard let kind = agentKind(candidate) else {
                // A foreground neither shell nor agent (an editor or tool the
                // agent opened) with nothing declared: the agent has not left,
                // so what was announced is held, as its reports are.
                if candidate.kind != "shell", states[id] != nil { live.insert(id) }
                continue
            }
            live.insert(id)
            let journal = inputs.journal(id)
            let readback = inputs.readback(id)
            let report = inputs.report(id)
            let look = FleetAgentState.currentLook(inputs.look(id), journal: journal, now: now)
            let blocked = FleetAgentState.blocked(journal: journal, wait: FleetAgentState.Wait(readback: readback),
                                                  look: look, failure: report?.failure, now: now)
            let stalled = FleetAgentState.stalled(
                journal: journal, supervisor: FleetAgentState.SupervisorStall(readback: readback), stop: report?.stop,
                turnStartedMs: inputs.turnStartedMs(id), blocked: blocked, now: now, threshold: threshold)
            let evidence = AgentEdges.Evidence(
                working: journal?.isWorking == true,
                composerSeen: look.map { [.empty, .suggestion, .draft].contains($0.state) } ?? false,
                blockedFromLook: blocked != nil && look?.state == .dialog && look?.dialogKind != nil)
            let step = AgentEdges.step(prior: states[id], workspaceId: candidate.workspaceId, agent: kind,
                                       blocked: blocked, stalled: stalled, evidence: evidence)
            // The state is recorded before the edge goes out.
            states[id] = step.state
            for edge in step.edges { emitter(edge.type, candidate.workspaceId, id, edge.payload) }
        }
        for (id, state) in states where !live.contains(id) {
            states.removeValue(forKey: id)
            for edge in AgentEdges.gone(state) { emitter(edge.type, state.workspaceId, id, edge.payload) }
        }
        let stats = RunStats(at: now, agents: states.count,
                             ms: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        lock.lock(); lastRun = stats; lock.unlock()
    }
}
