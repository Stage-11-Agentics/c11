import Foundation

/// `show.open` and `show.close` (C11H-228). Worker methods: the file check
/// and the load wait run on this connection's worker thread; the panel work
/// is one short main hop. The caller is the request's verified caller panel;
/// the machine is c11's own unless the relay set the caller's verified
/// machine on the request context. Neither is ever read from params.
extension TerminalController {
    nonisolated static let showWorkerMethods: Set<String> = [ShowSpec.openMethod, ShowSpec.closeMethod]

    nonisolated func v2ShowCommand(_ method: String, params: [String: Any]) -> V2CallResult {
        guard let caller = SocketCommandContext.current?.callerPanelId else {
            return .err(code: ShowSpec.Code.noCaller,
                        message: String(localized: "show.error.noCaller", defaultValue: "run c11 show inside a c11 panel"),
                        data: nil)
        }
        let origin = Self.showOrigin(caller: caller, context: SocketCommandContext.current)
        switch method {
        case ShowSpec.closeMethod: return v2ShowClose(caller: caller, params: params)
        default: return v2ShowOpen(caller: caller, origin: origin, params: params)
        }
    }

    /// Where the caller's files live: its verified machine through the relay
    /// (and its Incus container, from hc's own foreground facts), else here.
    nonisolated static func showOrigin(caller: UUID, context: SocketCommandContext?) -> ShowOrigin {
        guard let machine = context?.relayMachine else { return .local }
        let wanted = caller.uuidString.lowercased()
        let record = context?.hcInventory?.records.values.first {
            $0.labels["c11.panel"]?.lowercased() == wanted && $0.machineName == machine
        }
        // C11H-359 (L3): through the link that verified the caller, never
        // another link to the same machine name.
        return .remote(machine: machine, container: ShowOrigin.container(foregroundName: record?.foreground?.name,
                                                                         argv: record?.foreground?.argv),
                       link: context?.relayLink)
    }

    nonisolated func v2ShowOpen(caller: UUID, origin: ShowOrigin, params: [String: Any]) -> V2CallResult {
        guard let source = ShowSourceSpec(params["source"]) else {
            return .err(code: ShowSpec.Code.badSource,
                        message: String(localized: "show.error.badSource", defaultValue: "show needs an absolute path or a URL"),
                        data: nil)
        }
        let waitSeconds = min(max((params["wait_seconds"] as? NSNumber)?.doubleValue ?? ShowSpec.defaultWaitSeconds,
                                  ShowSpec.waitSecondsRange.lowerBound), ShowSpec.waitSecondsRange.upperBound)
        if case .remote(_, _, let link) = origin, source.kind == .path, link.flatMap({ ShowHosts.shared.link(for: $0) }) == nil {
            return .err(code: ShowSpec.Code.unreachable,
                        message: String(localized: "show.error.noLink", defaultValue: "c11 has no link to that machine right now"),
                        data: nil)
        }
        let fetcher: (any ShowFetcher)? = source.kind == .path ? origin.fetcher() : nil
        let initialStat: ShowFileStat?
        do {
            switch try ShowBlocking.run(seconds: 12, { await ShowPreflight.check(source, origin: origin, fetcher: fetcher) }) {
            case .success(let stat): initialStat = stat
            case .failure(let refused): return .err(code: refused.code, message: refused.message, data: nil)
            }
        } catch {
            return .err(code: ShowSpec.Code.unreachable, message: ShowFetchError.unreachable("").message, data: nil)
        }
        let request = ShowOpenRequest(caller: caller, source: source, origin: origin, fetcher: fetcher, initialStat: initialStat)
        // The panel work runs under this request's own context and command
        // policy: no focus mutation, no workspace switch, agent attribution.
        guard let opened = ShowMainHop.run(seconds: 10, {
            self.withSocketCommandPolicy(commandKey: ShowSpec.openMethod, isV2: true) {
                MainActor.assumeIsolated { ShowViewerController.shared.open(request) }
            }
        }) else {
            return .err(code: "timeout", message: Self.showMainTimeoutMessage, data: nil)
        }
        switch opened {
        case .failure(.noCaller):
            return .err(code: ShowSpec.Code.noCaller,
                        message: String(localized: "show.error.callerGone", defaultValue: "the calling panel is not in this c11"),
                        data: nil)
        case .failure(.placement):
            return .err(code: "internal_error",
                        message: String(localized: "show.error.placement", defaultValue: "c11 could not place the viewer"), data: nil)
        case .failure(.refused(let reason)):
            return .err(code: ShowSpec.Code.refusedURL, message: reason, data: nil)
        case .success(let (outcome, check)):
            // A live show reached c11: its record entry is done, and a row
            // for the same source left from an earlier away show goes.
            if case .remote(let machine, _, let link) = origin {
                DispatchQueue.main.async { MainActor.assumeIsolated { ShowAwayShows.shared.drop(panel: caller, source: source) } }
                if let recordID = params["record_id"] as? String, UUID(uuidString: recordID) != nil,
                   let store = link.flatMap({ ShowHosts.shared.link(for: $0) })?.records {
                    Task.detached { await ShowRecordDrain.mark(store: store, machine: machine, panel: caller, id: recordID, state: .opened) }
                }
            }
            let load = check.wait(seconds: waitSeconds)
            var payload: [String: Any] = [
                "viewer_panel_id": outcome.panel.uuidString,
                "viewer_panel_ref": outcome.ref ?? NSNull(),
                "workspace_id": outcome.workspace.uuidString,
                "viewer_kind": outcome.kind,
                "action": outcome.action.rawValue,
                "address": outcome.address,
                "machine": origin.machineName,
                "load": load.dictionary,
            ]
            if let replaced = outcome.replaced { payload["replaced_panel_id"] = replaced.uuidString }
            return .ok(payload)
        }
    }

    nonisolated static var showMainTimeoutMessage: String {
        String(localized: "show.error.mainTimeout", defaultValue: "c11's main thread did not answer")
    }

    nonisolated func v2ShowClose(caller: UUID, params: [String: Any]) -> V2CallResult {
        let source: ShowSourceSpec?
        if params["source"] == nil || params["source"] is NSNull {
            source = nil
        } else if let parsed = ShowSourceSpec(params["source"]) {
            source = parsed
        } else {
            return .err(code: ShowSpec.Code.badSource,
                        message: String(localized: "show.error.closeSource", defaultValue: "show close takes the path or URL you showed"),
                        data: nil)
        }
        guard let closed = ShowMainHop.run(seconds: 10, { () -> [UUID] in
            self.withSocketCommandPolicy(commandKey: ShowSpec.closeMethod, isV2: true) {
                MainActor.assumeIsolated {
                    ShowAwayShows.shared.drop(panel: caller, source: source)
                    return ShowViewerController.shared.close(caller: caller, source: source)
                }
            }
        }) else {
            return .err(code: "timeout", message: Self.showMainTimeoutMessage, data: nil)
        }
        return .ok(["closed": closed.count, "closed_panel_ids": closed.map(\.uuidString)])
    }
}

extension TerminalController {
    /// Browser verbs that never touch a panel's page: listing, creating, profiles.
    nonisolated static let showViewerExemptBrowserMethods: Set<String> = [
        "browser.open_split", "browser.panel.list", "browser.panel.new", "browser.url.get",
        "browser.profiles.list", "browser.profiles.add", "browser.profiles.rename",
        "browser.profiles.clear", "browser.profiles.delete",
    ]

    /// A shown viewer is display only: no browser verb may drive it, from any
    /// caller (C11H-228). Checked on the explicit target before dispatch; the
    /// focused-panel fallbacks check the resolved panel themselves.
    nonisolated static func showViewerBrowserRefusal(method: String, params: [String: Any]) -> V2CallResult? {
        guard !showViewerExemptBrowserMethods.contains(method) else { return nil }
        for key in ["surface_id", "panel_id", "tab_id"] {
            if let raw = params[key] as? String, let id = UUID(uuidString: raw), ShowViewerIndex.shared.contains(id) {
                return showViewerDisplayOnly(id)
            }
        }
        return nil
    }

    nonisolated static func showViewerDisplayOnly(_ panel: UUID) -> V2CallResult {
        .err(code: ShowSpec.Code.displayOnly,
             message: String(localized: "show.error.displayOnly",
                             defaultValue: "This panel shows content for the operator and is display only. Use c11 show to refresh it, or open your own browser panel to test."),
             data: ["surface_id": panel.uuidString])
    }
}

/// The viewer panel ids, readable from any thread.
final class ShowViewerIndex: @unchecked Sendable {
    static let shared = ShowViewerIndex()
    private let lock = NSLock()
    private var ids: Set<UUID> = []
    func insert(_ id: UUID) { lock.lock(); ids.insert(id); lock.unlock() }
    func remove(_ id: UUID) { lock.lock(); ids.remove(id); lock.unlock() }
    func contains(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}

/// Runs async work from a socket worker thread and waits for it, bounded.
/// Never called on main.
enum ShowBlocking {
    struct Timeout: Error {}

    static func run<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) throws -> T {
        precondition(!Thread.isMainThread, "ShowBlocking.run must not block main")
        let semaphore = DispatchSemaphore(value: 0)
        let box = ShowResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success, let result = box.get() else { throw Timeout() }
        return try result.get()
    }
}

/// One asynchronous hop to main for the panel work, waited on from the worker
/// (never `DispatchQueue.main.sync`), bounded so a busy main cannot wedge the
/// connection.
enum ShowMainHop {
    static func run<T>(seconds: Double, _ body: @escaping @MainActor () -> T) -> T? {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ShowResultBox<T>()
        // The worker's request context (caller, method, focus policy) rides
        // along to main, as the socket's own main hops carry it.
        let context = SocketCommandContext.current
        DispatchQueue.main.async {
            box.set(.success(SocketCommandContext.withContext(context) { MainActor.assumeIsolated { body() } }))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return try? box.get()?.get()
    }
}

final class ShowResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}
