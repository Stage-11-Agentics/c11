import Foundation
import Combine

/// C11-397: live per-panel mail counts for the subtitle bar's mailbox cell.
///
/// No file watchers. The app already performs or records every change to a
/// panel's inbox: the dispatcher writes deliveries, the stdin push claims in
/// process, and turn-boundary drains leave receipts the app records. Each of
/// those reports `inboxChanged`, which recounts that panel with two directory
/// listings on a utility queue. A slow reconcile recounts the panels whose bar
/// is on screen, which catches hand-dropped files and lets the fresh
/// highlight go out on time.
///
/// Main-thread only, except `inboxChanged`, which any thread may call.
final class MailboxBadgeStore {
    static let shared = MailboxBadgeStore()

    static let reconcileInterval: TimeInterval = 60

    private struct Key: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.mailbox.badges", qos: .utility)
    private let mailboxesRoot: (UUID) -> URL?
    private let now: () -> Date

    private var summaries: [UUID: MailboxPanelMail.Summary] = [:]
    private var workspaceOfPanel: [UUID: UUID] = [:]
    private var models: [UUID: MailboxBadgeModel] = [:]
    private var owners: [UUID: WeakWorkspace] = [:]
    private var onScreen: [UUID: Int] = [:]
    private var pending: Set<Key> = []
    private var inFlight: Set<Key> = []
    private var reconcileTimer: Timer?

    private struct WeakWorkspace {
        weak var value: Workspace?
    }

    init(
        mailboxesRoot: @escaping (UUID) -> URL? = { workspaceId in
            (try? MailboxLayout.defaultStateURL()).map {
                MailboxLayout.mailboxesRoot(state: $0, workspaceId: workspaceId)
            }
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.mailboxesRoot = mailboxesRoot
        self.now = now
    }

    // MARK: - Reads (main thread)

    /// Cached counts; a miss schedules a count and reads empty until it lands.
    /// Sidebar-hot through `Workspace.panelTitleBarState`, so no I/O here.
    func summary(workspace: Workspace, panelId: UUID) -> MailboxPanelMail.Summary {
        owners[panelId] = WeakWorkspace(value: workspace)
        if workspaceOfPanel[panelId] != workspace.id {
            workspaceOfPanel[panelId] = workspace.id
            schedule(Key(workspaceId: workspace.id, panelId: panelId))
        }
        return summaries[panelId] ?? .empty
    }

    /// The observable counts one mailbox cell renders.
    func model(workspace: Workspace, panelId: UUID) -> MailboxBadgeModel {
        _ = summary(workspace: workspace, panelId: panelId)
        if let model = models[panelId] { return model }
        let model = MailboxBadgeModel(panelId: panelId)
        model.apply(summaries[panelId] ?? .empty, now: now())
        models[panelId] = model
        return model
    }

    func inboxURL(workspaceId: UUID, panelId: UUID) -> URL? {
        mailboxesRoot(workspaceId).map { MailboxPanelMail.inboxURL(mailboxesRoot: $0, panelId: panelId) }
    }

    // MARK: - Visibility (main thread)

    /// A mailbox cell is on screen; keep its counts reconciled.
    func cellAppeared(panelId: UUID) {
        onScreen[panelId, default: 0] += 1
        if let workspaceId = workspaceOfPanel[panelId] {
            schedule(Key(workspaceId: workspaceId, panelId: panelId))
        }
        startReconcileIfNeeded()
    }

    func cellDisappeared(panelId: UUID) {
        guard let count = onScreen[panelId] else { return }
        if count <= 1 { onScreen.removeValue(forKey: panelId) } else { onScreen[panelId] = count - 1 }
        if onScreen.isEmpty {
            reconcileTimer?.invalidate()
            reconcileTimer = nil
        }
    }

    /// A closed panel's counts and model go away with it.
    func forget(panelId: UUID) {
        summaries.removeValue(forKey: panelId)
        workspaceOfPanel.removeValue(forKey: panelId)
        models.removeValue(forKey: panelId)
        owners.removeValue(forKey: panelId)
        onScreen.removeValue(forKey: panelId)
    }

    // MARK: - Change reports (any thread)

    /// A panel's inbox changed. A nil panel means "some inbox in this
    /// workspace", for a drain that did not say whose mail it took.
    static func inboxChanged(workspaceId: UUID, panelId: UUID?) {
        let report = {
            let store = MailboxBadgeStore.shared
            if let panelId {
                store.workspaceOfPanel[panelId] = workspaceId
                store.schedule(Key(workspaceId: workspaceId, panelId: panelId))
            } else {
                for (panel, workspace) in store.workspaceOfPanel where workspace == workspaceId {
                    store.schedule(Key(workspaceId: workspace, panelId: panel))
                }
            }
        }
        if Thread.isMainThread { report() } else { DispatchQueue.main.async(execute: report) }
    }

    // MARK: - Counting

    private func schedule(_ key: Key) {
        guard !inFlight.contains(key) else {
            pending.insert(key)
            return
        }
        inFlight.insert(key)
        guard let inbox = inboxURL(workspaceId: key.workspaceId, panelId: key.panelId) else {
            inFlight.remove(key)
            return
        }
        queue.async { [weak self] in
            let summary = autoreleasepool { MailboxPanelMail.summary(inbox: inbox) }
            DispatchQueue.main.async {
                self?.landed(summary, for: key)
            }
        }
    }

    private func landed(_ summary: MailboxPanelMail.Summary, for key: Key) {
        inFlight.remove(key)
        // The panel moved to another workspace while this count ran.
        if workspaceOfPanel[key.panelId] == key.workspaceId {
            let previous = summaries[key.panelId] ?? .empty
            summaries[key.panelId] = summary
            models[key.panelId]?.apply(summary, now: now())
            if previous.hasMail != summary.hasMail {
                // Mail can be what gives a panel its bar; the bar's presence is
                // read from the workspace, so the workspace republishes.
                owners[key.panelId]?.value?.objectWillChange.send()
            }
        }
        if pending.remove(key) != nil { schedule(key) }
    }

    private func startReconcileIfNeeded() {
        guard reconcileTimer == nil, !onScreen.isEmpty else { return }
        let timer = Timer(timeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            for panelId in self.onScreen.keys {
                guard let workspaceId = self.workspaceOfPanel[panelId] else { continue }
                self.schedule(Key(workspaceId: workspaceId, panelId: panelId))
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }
}

/// One panel's counts as its mailbox cell and drawer observe them.
final class MailboxBadgeModel: ObservableObject {
    let panelId: UUID
    @Published private(set) var summary: MailboxPanelMail.Summary = .empty
    /// The newest unread message landed within the last three minutes.
    @Published private(set) var isFresh = false
    /// Bumps on every recount that changed something, so an open drawer reloads.
    @Published private(set) var revision = 0

    private var freshTimer: Timer?

    init(panelId: UUID) {
        self.panelId = panelId
    }

    deinit {
        freshTimer?.invalidate()
    }

    func apply(_ summary: MailboxPanelMail.Summary, now: Date) {
        if summary != self.summary {
            self.summary = summary
            revision &+= 1
        }
        let fresh = summary.isFresh(now: now)
        if fresh != isFresh { isFresh = fresh }
        freshTimer?.invalidate()
        freshTimer = nil
        if let until = summary.freshUntil(now: now) {
            let timer = Timer(fire: until.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.apply(self.summary, now: Date())
            }
            RunLoop.main.add(timer, forMode: .common)
            freshTimer = timer
        }
    }
}
