import AppKit
import SwiftUI

/// Holds the resume of ended conversations while the operator chooses
/// (`ask`, or Option held at launch). It parks the one place a launch types a
/// resume (`Workspace.submitResume`); it gates nothing else, so restore and
/// socket readiness are never behind a question (C11H-39). Manual
/// `c11 conversation resume` is never parked.
@MainActor
final class LaunchResumeGate: ObservableObject {
    static let shared = LaunchResumeGate()

    struct Held: Identifiable {
        let id: UUID
        let workspaceTitle: String
        let panelTitle: String
        let run: () async -> Void
        /// C11H-196: told when the operator's choice leaves this resume out.
        var dropped: () -> Void = {}
        /// C11H-203: false for a resume that only joins the host-end queue,
        /// which spaces and orders its own admissions.
        var spaced: Bool = true
    }

    enum Phase: Equatable {
        /// Nothing is held: the default, or a launch that is not asking.
        case off
        /// Parking ended conversations until the operator answers.
        case asking
        /// Resume all was chosen: later arrivals resume as they come.
        case resumeAll
        /// Not now, or a subset was chosen: later arrivals are left alone.
        case declined
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var held: [Held] = []

    /// Spacing between the resumes released together, so N agents do not all
    /// boot in one turn (C11-156).
    var releaseStagger: TimeInterval = SessionPersistencePolicy.agentRestartStagger

    func begin(asking: Bool) {
        phase = asking ? .asking : .off
        held = []
    }

    /// The one entry a resume takes before it types. A launch-scoped resume is
    /// parked while the operator is choosing and dropped after Not now; it
    /// runs only on an affirmative choice. Anything else (a manual resume, a
    /// later recovery, a launch that is not asking) runs now.
    func submit(panelID: UUID, workspaceTitle: String, panelTitle: String, launchScoped: Bool,
                dropped: @escaping () -> Void = {},
                perform: @escaping () async -> Void) async {
        if launchScoped,
           intercept(panelID: panelID, workspaceTitle: workspaceTitle, panelTitle: panelTitle, run: perform,
                     dropped: dropped) {
            return
        }
        await perform()
    }

    /// `true` when the caller must not type now: the resume was parked, or
    /// the operator already declined it.
    func intercept(panelID: UUID, workspaceTitle: String, panelTitle: String,
                   run: @escaping () async -> Void, dropped: @escaping () -> Void = {},
                   spaced: Bool = true) -> Bool {
        switch phase {
        case .off, .resumeAll:
            return false
        case .declined:
            dropped()
            return true
        case .asking:
            held.removeAll { $0.id == panelID }
            held.append(Held(id: panelID, workspaceTitle: workspaceTitle,
                             panelTitle: panelTitle, run: run, dropped: dropped, spaced: spaced))
            held.sort { ($0.workspaceTitle, $0.panelTitle) < ($1.workspaceTitle, $1.panelTitle) }
            return true
        }
    }

    func resumeAll() {
        phase = .resumeAll
        release(held)
    }

    func resume(only ids: Set<UUID>) {
        phase = .declined
        let left = held.filter { !ids.contains($0.id) }
        release(held.filter { ids.contains($0.id) })
        for item in left { item.dropped() }
    }

    func decline() {
        phase = .declined
        let left = held
        held = []
        for item in left { item.dropped() }
    }

    /// C11H-203: a held resume that no longer stands leaves the question
    /// without being run or reported as dropped.
    func forget(_ panelID: UUID) {
        held.removeAll { $0.id == panelID }
    }

    private func release(_ items: [Held]) {
        held = []
        let stagger = releaseStagger
        Task { @MainActor in
            // Queue-bound resumes go first and together: the queue orders
            // and spaces them. The rest keep the gate's own spacing.
            for item in items where !item.spaced { await item.run() }
            for (index, item) in items.filter(\.spaced).enumerated() {
                if index > 0, stagger > 0 { try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000)) }
                await item.run()
            }
        }
    }
}

/// Which restored terminals still owe their startup recovery.
///
/// Where the launch's snapshot is restored, each persistent terminal is
/// marked. While a mark stands, the terminal's resolved lifecycle is the
/// startup resolution, however late the backend answers, and a recovery
/// planned from it is launch-scoped. The mark is spent only when the recovery
/// no longer needs to be retried: it was planned, it needed none (a survivor,
/// or nothing resumable), or the terminal is gone. A plan that is released to
/// be tried again (the replacement could not attach yet) puts the mark back.
/// An end that happens later in the session finds no mark and is ordinary
/// recovery. No clock is involved.
struct LaunchRestoreMarks {
    private var marked: Set<UUID> = []

    mutating func mark(_ panelID: UUID) { marked.insert(panelID) }

    /// Whether this resolved lifecycle is the terminal's startup resolution.
    /// Reading it spends nothing.
    func isStartupResolution(_ panelID: UUID, resolved: Bool) -> Bool {
        resolved && marked.contains(panelID)
    }

    mutating func consume(_ panelID: UUID) { marked.remove(panelID) }

    /// A plan was released to be made again. If it was this launch's startup
    /// recovery, the retry is too; a genuine later end stays ordinary.
    mutating func planReleased(_ panelID: UUID, wasStartup: Bool) {
        if wasStartup { marked.insert(panelID) }
    }
}

/// What this launch did with the previous session, for the operator (C11H-38).
///
/// c11 resumes by default and never gates on a question, so this reports:
/// how many ended conversations were resumed, how many were not and why, or
/// that the launch skipped resuming on purpose. It listens to the existing
/// per-workspace `launchResumeOutcomes` record; it decides nothing.
@MainActor
final class LaunchResumeReport: ObservableObject {
    static let shared = LaunchResumeReport()

    struct Skipped: Equatable, Identifiable {
        let id: UUID
        let workspaceTitle: String
        let panelTitle: String
        let reason: String
    }

    enum Outcome: Equatable {
        case resumed
        case skipped(workspaceTitle: String, panelTitle: String, reason: String)
        /// C11H-99: hc kept the terminal live with its agent running. Never a
        /// resume candidate, so never counted as resumed or as not resumed.
        case kept
    }

    enum Mode: Equatable {
        /// Nothing to say: before launch decides, a QA launch, a clean launch,
        /// or while the ask banner is up (the gate owns that).
        case idle
        /// Ended conversations resume; outcomes are being counted.
        case resumed
        /// "Start fresh": nothing restored; running terminals went to Recovered.
        case fresh
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var resumedCount = 0
    /// C11H-99: agents that never stopped (hc kept their terminals live).
    @Published private(set) var keptCount = 0
    @Published private(set) var skipped: [Skipped] = []
    @Published private(set) var isDismissed = false
    /// Running hc terminals the recovered-orphans path put in "Recovered".
    @Published private(set) var recoveredCount = 0
    private var recoveredPanels: Set<UUID> = []
    private var hadPreviousSession = true

    /// Outcomes arrive while startup recovery runs. A manual
    /// `c11 conversation resume` an hour later is not part of this launch.
    static let launchWindow: TimeInterval = 180
    /// A report with nothing skipped fades by itself; one with skips waits.
    static let autoDismissAfter: TimeInterval = 20

    private var resumedPanels: Set<UUID> = []
    private var keptPanels: Set<UUID> = []
    /// C11H-99: an Ask launch is idle until the operator chooses. Kept
    /// agents arrive before that and are held here, not dropped.
    private var asking = false
    private var keptWhileAsking: Set<UUID> = []
    private var skippedByPanel: [UUID: Skipped] = [:]
    private var acceptsUntil: Date = .distantPast
    private var autoDismiss: DispatchWorkItem?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Called once, where startup decides. Resets any earlier state.
    /// `hadPreviousSession` is false on a first launch or after a clean quit
    /// with nothing open: there is nothing to have skipped, so a start-fresh
    /// is not worth a banner.
    func begin(_ decision: LaunchResumeDecision, hadPreviousSession: Bool = true) {
        reset()
        switch decision {
        case .resume:
            startCounting()
        case .ask:
            mode = .idle
            asking = true
        case .startFresh(.qaLaunch):
            mode = .idle
        case .startFresh:
            self.hadPreviousSession = hadPreviousSession
            mode = .fresh
        }
    }

    /// The operator chose to resume: count what comes of it. Agents found
    /// still running while the ask strip waited are this launch's too
    /// (C11H-99): their keep is decided once, before the choice, and never
    /// repeated, so it carries into the count.
    func startCounting() {
        let carried = asking ? keptWhileAsking : []
        reset()
        mode = .resumed
        acceptsUntil = clock().addingTimeInterval(Self.launchWindow)
        guard !carried.isEmpty else { return }
        keptPanels = carried
        keptCount = carried.count
        scheduleAutoDismiss()
    }

    private func reset() {
        autoDismiss?.cancel()
        autoDismiss = nil
        resumedPanels = []
        keptPanels = []
        skippedByPanel = [:]
        resumedCount = 0
        keptCount = 0
        skipped = []
        isDismissed = false
        recoveredPanels = []
        recoveredCount = 0
        asking = false
        keptWhileAsking = []
        hadPreviousSession = true
        mode = .idle
    }

    /// A running terminal went to Recovered instead of being ended.
    func noteRecovered(panelID: UUID) {
        guard mode == .fresh else { return }
        recoveredPanels.insert(panelID)
        recoveredCount = recoveredPanels.count
    }

    func record(panelID: UUID, outcome: Outcome) {
        if case .kept = outcome, asking, mode == .idle {
            keptWhileAsking.insert(panelID)
            return
        }
        guard mode == .resumed, clock() <= acceptsUntil else { return }
        switch outcome {
        case .resumed:
            skippedByPanel[panelID] = nil
            keptPanels.remove(panelID)
            resumedPanels.insert(panelID)
        case .skipped(let workspaceTitle, let panelTitle, let reason):
            resumedPanels.remove(panelID)
            keptPanels.remove(panelID)
            skippedByPanel[panelID] = Skipped(id: panelID, workspaceTitle: workspaceTitle,
                                              panelTitle: panelTitle, reason: reason)
        case .kept:
            resumedPanels.remove(panelID)
            skippedByPanel[panelID] = nil
            keptPanels.insert(panelID)
        }
        resumedCount = resumedPanels.count
        keptCount = keptPanels.count
        skipped = skippedByPanel.values.sorted { ($0.workspaceTitle, $0.panelTitle) < ($1.workspaceTitle, $1.panelTitle) }
        scheduleAutoDismiss()
    }

    func dismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        isDismissed = true
    }

    private func scheduleAutoDismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        guard mode == .resumed, skipped.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        autoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissAfter, execute: work)
    }

    var showsSettingsButton: Bool {
        mode == .fresh
    }

    var headline: String? {
        isDismissed ? nil : Self.headline(mode: mode, resumed: resumedCount, skipped: skipped.count,
                                          kept: keptCount, recovered: recoveredCount,
                                          hadPreviousSession: hadPreviousSession)
    }

    /// The report's one line. `nil` means nothing appears.
    nonisolated static func headline(mode: Mode, resumed: Int, skipped: Int, kept: Int = 0,
                                     recovered: Int = 0, hadPreviousSession: Bool = true) -> String? {
        switch mode {
        case .idle:
            return nil
        case .fresh:
            if recovered == 1 {
                return String(localized: "launch.resume.banner.fresh.recovered.one",
                    defaultValue: "Started fresh. 1 running terminal is in the Recovered workspace.")
            }
            if recovered > 1 {
                return String(format: String(localized: "launch.resume.banner.fresh.recovered.other",
                    defaultValue: "Started fresh. %lld running terminals are in the Recovered workspace."), recovered)
            }
            return hadPreviousSession
                ? String(localized: "launch.resume.banner.fresh.none", defaultValue: "Started fresh.")
                : nil
        case .resumed:
            var parts: [String] = []
            if resumed == 1 {
                parts.append(String(localized: "launch.resume.banner.resumed.one", defaultValue: "Resumed 1 session."))
            } else if resumed > 1 {
                parts.append(String(format: String(localized: "launch.resume.banner.resumed.other",
                    defaultValue: "Resumed %lld sessions."), resumed))
            }
            if skipped == 1 {
                parts.append(String(localized: "launch.resume.banner.skipped.one", defaultValue: "1 session was not resumed."))
            } else if skipped > 1 {
                parts.append(String(format: String(localized: "launch.resume.banner.skipped.other",
                    defaultValue: "%lld sessions were not resumed."), skipped))
            }
            if kept == 1 {
                parts.append(String(localized: "launch.resume.banner.kept.one", defaultValue: "1 agent kept running."))
            } else if kept > 1 {
                parts.append(String(format: String(localized: "launch.resume.banner.kept.other",
                    defaultValue: "%lld agents kept running."), kept))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// The ask banner's line: how many ended sessions are waiting.
    nonisolated static func askHeadline(count: Int) -> String? {
        if count == 1 {
            return String(localized: "launch.resume.banner.ask.one",
                defaultValue: "1 session ended while c11 was closed.")
        }
        guard count > 1 else { return nil }
        return String(format: String(localized: "launch.resume.banner.ask.other",
            defaultValue: "%lld sessions ended while c11 was closed."), count)
    }
}

/// The inline strip at the bottom of the window. It takes layout space instead
/// of floating over the terminals, so it can never sit under the portal layer
/// and never covers a prompt.
struct LaunchResumeBannerView: View {
    @ObservedObject var report: LaunchResumeReport = .shared
    @ObservedObject var gate: LaunchResumeGate = .shared
    @ObservedObject var restore: HCRestoreProgress = .shared
    @ObservedObject var mass: HCMassSignalEnd = .shared
    @State private var showingRestoreDetails = false
    @State private var showingDetails = false
    @State private var showingChoices = false
    @State private var deselected: Set<UUID> = []

    var body: some View {
        if gate.phase == .asking, let text = LaunchResumeReport.askHeadline(count: gate.held.count) {
            strip {
                Text(text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "launch.resume.banner.resumeAll", defaultValue: "Resume all")) {
                    gate.resumeAll()
                    report.startCounting()
                }
                .keyboardShortcut(.defaultAction)
                Button(String(localized: "launch.resume.banner.choose", defaultValue: "Choose…")) {
                    showingChoices.toggle()
                }
                .popover(isPresented: $showingChoices, arrowEdge: .top) { choices }
                Button(String(localized: "launch.resume.banner.notNow", defaultValue: "Not now")) {
                    gate.decline()
                }
            }
        } else if let text = restore.headline {
            // C11H-196: the restore after a host end, one line, with the rows
            // that need the operator behind Details.
            // C11H-235: waiting mass outside-signal ends lead the strip, with one
            // Resume all for all their panels still waiting (background, staggered).
            let incident = mass.stripIncident
            strip {
                Text(incident?.headline ?? text)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let incident {
                    Button(String(localized: "launch.resume.banner.resumeAll", defaultValue: "Resume all")) {
                        mass.resumeAllWaiting()
                    }
                    .accessibilityIdentifier("hc-mass-end-resume-all")
                }
                if !restore.needingYou.isEmpty {
                    Button(String(localized: "launch.resume.banner.details", defaultValue: "Details")) {
                        showingRestoreDetails.toggle()
                    }
                    .popover(isPresented: $showingRestoreDetails, arrowEdge: .top) {
                        HCRestoreNeedsYouList(progress: restore)
                    }
                }
                Button {
                    restore.dismiss()
                    report.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(String(localized: "launch.resume.banner.dismiss", defaultValue: "Dismiss"))
                .accessibilityLabel(String(localized: "launch.resume.banner.dismiss", defaultValue: "Dismiss"))
            }
            // A container, so Resume all keeps its own identifier.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hc-restore-strip")
        } else if let text = report.headline {
            strip {
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !report.skipped.isEmpty {
                    Button(String(localized: "launch.resume.banner.details", defaultValue: "Details")) {
                        showingDetails.toggle()
                    }
                    .popover(isPresented: $showingDetails, arrowEdge: .top) {
                        LaunchResumeSkippedList(items: report.skipped)
                    }
                }
                if report.showsSettingsButton {
                    Button(String(localized: "launch.resume.banner.settings", defaultValue: "Settings")) {
                        AppDelegate.presentPreferencesWindow()
                    }
                }
                Button {
                    report.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(String(localized: "launch.resume.banner.dismiss", defaultValue: "Dismiss"))
                .accessibilityLabel(String(localized: "launch.resume.banner.dismiss", defaultValue: "Dismiss"))
            }
        }
    }

    private var choices: some View {
        let chosen = gate.held.filter { !deselected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(gate.held) { item in
                        Toggle(isOn: Binding(
                            get: { !deselected.contains(item.id) },
                            set: { on in
                                if on { deselected.remove(item.id) } else { deselected.insert(item.id) }
                            }
                        )) {
                            Text("\(item.workspaceTitle) · \(item.panelTitle)")
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Divider()
            HStack {
                Spacer()
                Button(String(format: String(localized: "launch.resume.banner.resumeChosen",
                                             defaultValue: "Resume %lld"), chosen.count)) {
                    let ids = Set(chosen.map(\.id))
                    showingChoices = false
                    gate.resume(only: ids)
                    if !ids.isEmpty { report.startCounting() }
                }
                .disabled(chosen.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 380)
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
    }
}

private struct LaunchResumeSkippedList: View {
    let items: [LaunchResumeReport.Skipped]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.workspaceTitle) · \(item.panelTitle)")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(item.reason)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .frame(maxHeight: 260)
    }
}

/// C11H-196: the restore rows that need the operator, each with Resume. A row
/// resumes in the background; nothing is shown and no workspace is switched.
private struct HCRestoreNeedsYouList: View {
    @ObservedObject var progress: HCRestoreProgress
    @State private var refusals: [UUID: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(progress.needingYou) { record in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(record))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(refusals[record.id] ?? record.status.detail)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if record.status.offersResume {
                            Button(String(localized: "terminal.hostEnd.resumeButton", defaultValue: "Resume conversation")) {
                                refusals[record.id] = progress.resume(record.id)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420)
        .frame(maxHeight: 300)
    }

    private func title(_ record: HCRestoreProgress.Record) -> String {
        guard let found = progress.locate(record.id) else { return record.id.uuidString }
        return "\(found.workspace.title) · \(found.panel.displayTitle)"
    }
}
