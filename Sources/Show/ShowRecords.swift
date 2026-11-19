import Foundation

/// The seam for `c11 show`'s durable record (C11H-228): where an agent on a
/// linked machine leaves "I showed this" while c11 is away. Today it is that
/// machine's hc document store; Constellation Bus may carry it later, by
/// replacing only this protocol's implementation.
protocol ShowRecordStore: Sendable {
    func load(machine: String, panel: UUID) async throws -> (record: ShowRecord?, version: UInt64)
    /// Compare-and-set; throws `C11RelayStoreError.conflict` when the version moved.
    func save(machine: String, record: ShowRecord, version: UInt64) async throws -> UInt64
}

/// The record in the agent machine's hc document store, over the relay's own
/// session host (`doc.get` / `doc.set` with `on`).
struct ShowHCRecordStore: ShowRecordStore {
    let host: any C11RelayHost

    func load(machine: String, panel: UUID) async throws -> (record: ShowRecord?, version: UInt64) {
        let (value, version) = try await host.relayDocGet(machine: machine, name: ShowRecord.name(panel: panel))
        return (value == nil ? nil : ShowRecord(panel: panel, value: value), version)
    }

    func save(machine: String, record: ShowRecord, version: UInt64) async throws -> UInt64 {
        try await host.relayDocSet(machine: machine, name: ShowRecord.name(panel: record.panel),
                                   value: record.dictionary, version: version)
    }
}

enum ShowRecordDrain {
    /// Reads one panel's record and returns the entries the operator should
    /// see in Feed: signed ones that are `waiting` (turned `noticed` in the
    /// document itself, so a restart rebuilds the same row and never a second)
    /// or already `noticed`. `live`, `opened`, `dismissed` and `closed`
    /// entries are left alone; unsigned entries are ignored. The answer is
    /// the panel's whole current set (empty when the record is gone or holds
    /// nothing to show), so Feed can drop what was closed or replaced; nil
    /// only when the record could not be read.
    static func drain(store: any ShowRecordStore, machine: String, panel: UUID, signer: ShowEntrySigner? = nil,
                      verified: (ShowRecord.Entry) -> Bool) async -> [ShowRecord.Entry]? {
        for _ in 0..<3 {
            guard let (loaded, version) = try? await store.load(machine: machine, panel: panel) else { return nil }
            guard var record = loaded else { return [] }
            let surfaced = record.entries.filter { ($0.state == .waiting || $0.state == .noticed) && verified($0) }
            guard surfaced.contains(where: { $0.state == .waiting }) else { return surfaced }
            for entry in surfaced where entry.state == .waiting { record.setState(.noticed, id: entry.id, signer: signer) }
            do {
                _ = try await store.save(machine: machine, record: record, version: version)
                let ids = Set(surfaced.map(\.id))
                return record.entries.filter { ids.contains($0.id) }
            } catch C11RelayStoreError.conflict {
                continue
            } catch {
                // The row still shows; the next drain tries the write again.
                return surfaced
            }
        }
        return nil
    }

    /// Sets entry `id` to `state` (opened, dismissed), compare-and-set, best effort.
    static func mark(store: any ShowRecordStore, machine: String, panel: UUID, id: String, state: ShowRecord.State,
                     signer: ShowEntrySigner? = nil) async {
        for _ in 0..<3 {
            guard let (loaded, version) = try? await store.load(machine: machine, panel: panel), var record = loaded,
                  record.setState(state, id: id, signer: signer) else { return }
            do {
                _ = try await store.save(machine: machine, record: record, version: version)
                return
            } catch C11RelayStoreError.conflict {
                continue
            } catch {
                return
            }
        }
    }
}

/// One show that landed while the operator was away, waiting in Feed.
struct ShowAwayEntry: Equatable, Sendable {
    var panel: UUID
    var machine: String
    var container: String?
    var entry: ShowRecord.Entry
    /// The terminal's key, so c11's own state changes stay signed.
    var signer: ShowEntrySigner? = nil
    /// C11H-359 (L3): the link whose secret signed the entry; its viewer reads
    /// through that link only.
    var link: C11RelayLinkRef? = nil

    var origin: ShowOrigin { .remote(machine: machine, container: container, link: link) }
}

/// Shows that landed while c11 was away (C11H-228): one Feed row per showing
/// panel with an open action. Opening the row (the operator's jump to that
/// agent) opens its viewers; nothing opens unasked.
@MainActor
final class ShowAwayShows {
    static let shared = ShowAwayShows()

    private(set) var pending: [UUID: [String: ShowAwayEntry]] = [:]
    /// C11H-359 (L3): where an entry's signing link is found, checked against
    /// its current secret each time it is used (tests replace it).
    var hosts: ShowHosts = .shared
    /// Where a panel lives now, for its Feed row (nil when it is not in this c11).
    var workspaceOf: (UUID) -> UUID? = { AppDelegate.shared?.workspaceContainingPanel(panelId: $0)?.workspace.id }
    var publish: (UUID, FeedShowFact?) -> Void = { panel, fact in FeedProjectionBridge.shared.noteShow(panelID: panel, fact: fact) }

    /// Opens one show the operator asked for from Feed and reports back:
    /// nil when its viewer opened, else why not. The default runs the shared
    /// preflight off main, then opens the viewer; tests replace it.
    var opener: (ShowOpenRequest, @escaping @MainActor (String?) -> Void) -> Void = { request, done in
        Task.detached(priority: .userInitiated) {
            let checked = await ShowPreflight.check(request.source, origin: request.origin, fetcher: request.fetcher)
            await MainActor.run {
                switch checked {
                case .failure(let refused):
                    done(refused.message)
                case .success(let stat):
                    var request = request
                    request.initialStat = stat
                    switch ShowViewerController.shared.open(request) {
                    case .success: done(nil)
                    case .failure(.refused(let reason)): done(reason)
                    case .failure: done(String(localized: "show.error.placement", defaultValue: "c11 could not place the viewer"))
                    }
                }
            }
        }
    }

    /// Why the last attempt to open each pending show failed, shown on its row.
    private(set) var failures: [String: String] = [:]
    private var opening: Set<String> = []

    /// The entries this c11 would show at all: a refused URL never becomes a
    /// row. Off main (the relay service calls it before handing rows over);
    /// it may resolve this Mac's host names.
    nonisolated static func admissible(_ items: [ShowAwayEntry]) -> [ShowAwayEntry] {
        items.filter { item in
            guard item.entry.source.kind == .url else { return true }
            return ShowPreflight.urlRefusal(item.entry.source.target, origin: item.origin) == nil
        }
    }

    /// One panel's pending shows, exactly as its record reads now (already
    /// passed through `admissible`): entries closed, replaced or opened
    /// elsewhere since the last read disappear.
    func reconcile(panel: UUID, items: [ShowAwayEntry]) {
        var next: [String: ShowAwayEntry] = [:]
        for item in items { next[item.entry.id] = item }
        let before = pending[panel] ?? [:]
        pending[panel] = next.isEmpty ? nil : next
        for id in Set(before.keys).subtracting(next.keys) { failures.removeValue(forKey: id) }
        if Set(before.keys) != Set(next.keys) { republish(panel) }
    }

    func fact(for panel: UUID) -> FeedShowFact? {
        guard let items = pending[panel], !items.isEmpty, let workspace = workspaceOf(panel) else { return nil }
        let sorted = items.values.sorted { $0.entry.at < $1.entry.at }
        let names = sorted.map { ($0.entry.source.target as NSString).lastPathComponent }
        return FeedShowFact(workspaceID: workspace, panelID: panel, names: names,
                            atMs: sorted.last?.entry.at ?? 0, count: sorted.count,
                            failure: sorted.compactMap { failures[$0.entry.id] }.last)
    }

    private func republish(_ panel: UUID) { publish(panel, fact(for: panel)) }

    /// The operator opened `panel` from Feed or a jump: open each waiting
    /// show beside it. A show leaves Feed (and its record turns `opened`)
    /// only once its viewer opened; one that could not (its file briefly
    /// gone, its machine away) stays, with the reason on the row, to retry.
    func operatorOpened(panel: UUID) {
        guard let items = pending[panel], !items.isEmpty else { return }
        for item in items.values.sorted(by: { $0.entry.at < $1.entry.at }) where !opening.contains(item.entry.id) {
            let origin = item.origin
            let request = ShowOpenRequest(caller: panel, source: item.entry.source, origin: origin,
                                          fetcher: item.entry.source.kind == .path ? origin.fetcher(hosts: hosts) : nil,
                                          initialStat: nil)
            let id = item.entry.id
            opening.insert(id)
            opener(request) { [weak self] failure in
                guard let self else { return }
                self.opening.remove(id)
                if let failure {
                    self.failures[id] = failure
                    self.republish(panel)
                    return
                }
                self.failures.removeValue(forKey: id)
                self.pending[panel]?.removeValue(forKey: id)
                if self.pending[panel]?.isEmpty == true { self.pending[panel] = nil }
                self.republish(panel)
                // Marked through the link that signed it, while its secret is
                // still the one it signed with; a link re-made since writes nothing.
                if let link = item.link, let store = self.hosts.link(for: link)?.records {
                    let machine = item.machine, signer = item.signer
                    Task.detached {
                        await ShowRecordDrain.mark(store: store, machine: machine, panel: panel, id: id, state: .opened, signer: signer)
                    }
                }
            }
        }
    }

    /// The agent closed a source (or showed it live): drop its waiting row,
    /// by the same rule `show close` uses everywhere. Nil drops them all.
    func drop(panel: UUID, source: ShowSourceSpec?) {
        guard var items = pending[panel] else { return }
        items = items.filter { !ShowSourceSpec.closes(source, $0.value.entry.source) }
        pending[panel] = items.isEmpty ? nil : items
        republish(panel)
    }
}
