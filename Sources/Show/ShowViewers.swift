import AppKit
import Combine
import Foundation
import WebKit

/// One viewer's state (C11H-228): what it shows, from where, and its own
/// non-persistent website data store and scheme handler. A browser viewer
/// keeps the store for its life, so a page's localStorage survives a reload
/// but is never shared with an ordinary browser panel or another viewer.
@MainActor
final class ShowViewerSession {
    let caller: UUID
    let source: ShowSourceSpec
    /// Where it reads from. C11H-359 (L3): a re-show may give it the request's
    /// verified link (`relink`); the machine and container never change.
    private(set) var origin: ShowOrigin
    /// What it reads through: its scheme handler, its reload poller and its
    /// markdown loads all hold this one slot, so a new link reaches them together.
    let fetcher: (any ShowFetcher)?
    private let slot: ShowFetcherSlot?
    /// What the viewer loads: the `c11-show://` address, or the shown URL.
    let address: URL
    let dataStore: WKWebsiteDataStore
    let schemeHandler: ShowSchemeHandler?
    /// C11H-353: what a page shown from a linked machine may do; nil for a
    /// show from this Mac.
    let pageGuard: ShowPageGuard?
    var callerTitle: String
    fileprivate(set) var panelID: UUID?
    fileprivate(set) var workspaceID: UUID?
    fileprivate weak var browser: BrowserPanel?
    fileprivate weak var markdown: MarkdownPanel?
    fileprivate var poller: ShowReloadPoller?
    fileprivate var check: ShowLoadCheck?
    fileprivate var pendingScroll: (Double, Double)?
    /// Rewrites the bar when the caller's terminal ends or comes back.
    fileprivate var callerWatch: AnyCancellable?
    fileprivate weak var watchedCaller: TerminalPanel?
    fileprivate(set) var updatedAt = Date()
    /// When the caller last showed this through a show request (open or
    /// re-show): proof it was alive then. A restored session has none.
    private(set) var lastShownAt: Date?
    /// The main-frame document the viewer displays: one generation per
    /// main-frame commit, so a History API change of path or query (no
    /// commit) is still the same document.
    private(set) var documentGeneration = 0
    /// The address (without fragment) the current document committed at.
    private var committedDocument: String?
    /// WebKit reported a subframe in the current document.
    private var documentFramed = false
    /// The current document came back through back/forward: it may be a
    /// cached earlier document whose frames will not report again.
    private var documentRestored = false
    /// Any document this viewer showed had embedded content.
    private var everFramed = false

    /// A verified show request from the caller reached this viewer.
    func noteShown(at date: Date = Date()) { lastShownAt = date }

    /// The main-frame facts that decide whether a page has embedded content.
    func noteNavigation(_ event: ShowNavigationEvent, currentURL: String?) {
        switch event {
        case .committed(let url, let freshLoad):
            documentGeneration += 1
            committedDocument = ShowPointAndSay.documentKey(url)
            documentFramed = false
            documentRestored = !freshLoad
        case .subframe:
            documentFramed = true
            everFramed = true
        case .response, .finished, .failed:
            break
        }
    }

    /// Whether the document the viewer displays now (at `currentURL`) may
    /// hold embedded content. The mark belongs to the document, not its
    /// address. Where c11 cannot tell this document from an earlier framed
    /// one (no commit seen, a back/forward restore, an address that moved
    /// without a commit), it fails closed once any document had frames.
    func hasEmbeddedContent(_ currentURL: String?) -> Bool {
        guard documentGeneration > 0, let key = ShowPointAndSay.documentKey(currentURL) else { return true }
        if documentFramed { return true }
        return everFramed && (documentRestored || key != committedDocument)
    }

    init(caller: UUID, source: ShowSourceSpec, origin: ShowOrigin, fetcher: (any ShowFetcher)?, callerTitle: String) {
        self.caller = caller
        self.source = source
        self.origin = origin
        let slot = fetcher.map(ShowFetcherSlot.init)
        self.slot = slot
        self.fetcher = slot
        self.callerTitle = callerTitle
        self.dataStore = WKWebsiteDataStore.nonPersistent()
        var pageGuard = ShowPageGuard.applies(to: origin) ? ShowPageGuard() : nil
        pageGuard?.allowsServedScript = ShowPageGuard.canTurnOffPeerConnections
        self.pageGuard = pageGuard
        if source.kind == .path {
            address = ShowAddress.url(machine: origin.machineName, path: source.target, home: source.home)
                ?? URL(string: "\(ShowSpec.scheme)://\(ShowAddress.host(forMachine: origin.machineName))/")!
            schemeHandler = (slot != nil && !source.isMarkdown)
                ? ShowSchemeHandler(scope: ShowServeScope(source: source), fetcher: slot!,
                                    contentSecurityPolicy: pageGuard == nil ? nil : ShowPageGuard.contentSecurityPolicy)
                : nil
        } else {
            address = URL(string: source.target) ?? URL(string: "about:blank")!
            schemeHandler = nil
        }
    }

    var isMarkdown: Bool { source.isMarkdown }

    /// C11H-353: whether this viewer may hand anything to the default browser.
    /// A linked machine's viewer never does: its page would run outside the
    /// viewer's fence, and its paths name files on that machine, not here.
    var handsOutDefaultBrowser: Bool { pageGuard == nil }

    /// C11H-395: the file a `c11-show:` page of this viewer is, as its scheme
    /// handler serves it, for the default browser (or the file's default app):
    /// a path its handler serves (which, like the handler, ignores the host)
    /// whose name passes the hand-off type rule. C11H-399: nil for a linked
    /// machine's viewer, whoever asks, so no caller can map that machine's
    /// address to a same-path file on this Mac. No disk access:
    /// `defaultBrowserFile` checks the file.
    func servedPathForDefaultBrowser(_ page: URL) -> (path: String, root: String?)? {
        guard handsOutDefaultBrowser, let scope = schemeHandler?.scope, ShowPageGuard.isShowScheme(page),
              let components = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let served = scope.servedPath(percentEncodedPath: components.percentEncodedPath),
              ShowServeScope.handsOff(name: served.path) else { return nil }
        return served
    }

    /// C11H-395: the file `servedPathForDefaultBrowser` names, checked on disk
    /// the way `ShowLocalFetcher` reads it; nil when it would refuse it.
    func defaultBrowserFile(_ page: URL) -> URL? {
        guard let served = servedPathForDefaultBrowser(page) else { return nil }
        return ShowServeScope.localFile(served.path, root: served.root)
    }

    /// C11H-359 (L3): from now on it reads through `origin`'s link, on the
    /// same machine and container (so its address is unchanged).
    func relink(to origin: ShowOrigin, fetcher: any ShowFetcher) {
        self.origin = origin
        slot?.set(fetcher)
    }

    /// The value of the viewer's `show.source` metadata.
    var metadataValue: [String: Any] {
        var value = source.dictionary
        switch origin {
        case .local: value["machine"] = ShowSpec.localMachine
        case .remote(let machine, let container, let link):
            value["machine"] = machine
            if let container { value["container"] = container }
            // C11H-359 (L3): the link it reads through, so a restored viewer
            // reads through that link only.
            if let link {
                value["session"] = link.session
                value["link_id"] = link.linkID
            }
        }
        value["caller"] = caller.uuidString
        value["address"] = address.absoluteString
        return value
    }

    /// A session rebuilt from a restored panel's `show.source` metadata.
    static func restored(from value: Any?) -> ShowViewerSession? {
        guard let object = value as? [String: Any], let source = ShowSourceSpec(object),
              let caller = (object["caller"] as? String).flatMap(UUID.init(uuidString:)),
              let machine = object["machine"] as? String, !machine.isEmpty else { return nil }
        // A viewer saved without its link (an older save) reads nothing until reopened.
        let link = (object["session"] as? String).flatMap { session in
            (object["link_id"] as? String).map { C11RelayLinkRef(session: session, machine: machine, linkID: $0) }
        }
        let origin: ShowOrigin = machine == ShowSpec.localMachine ? .local
            : .remote(machine: machine, container: object["container"] as? String, link: link)
        return ShowViewerSession(caller: caller, source: source, origin: origin,
                                 fetcher: source.kind == .path ? origin.fetcher() : nil,
                                 callerTitle: String(localized: "show.callerFallback", defaultValue: "an agent"))
    }
}

/// C11H-359 (L3): the fetcher one viewer reads through, swapped in one place.
final class ShowFetcherSlot: ShowFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any ShowFetcher

    init(_ fetcher: any ShowFetcher) { current = fetcher }

    func set(_ fetcher: any ShowFetcher) { lock.lock(); current = fetcher; lock.unlock() }

    private var fetcher: any ShowFetcher { lock.lock(); defer { lock.unlock() }; return current }

    func stat(_ path: String) async throws -> ShowFileStat { try await fetcher.stat(path) }

    func read(_ path: String, root: String?, maxBytes: Int) async throws -> Data {
        try await fetcher.read(path, root: root, maxBytes: maxBytes)
    }
}

extension ShowPageGuard {
    private static let peerConnectionSetter = NSSelectorFromString("_setPeerConnectionEnabled:")

    /// Whether this WebKit has its peer-connection switch (C11H-353).
    @MainActor static var canTurnOffPeerConnections: Bool { WKPreferences().responds(to: peerConnectionSetter) }

    /// Turns WebRTC off for a guarded viewer: a CSP does not govern ICE, which
    /// sends STUN and TURN to any address, this Mac's loopback included.
    /// True when the preference now reads off.
    @MainActor @discardableResult
    static func turnOffPeerConnections(in preferences: WKPreferences) -> Bool {
        guard preferences.responds(to: peerConnectionSetter) else { return false }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
        return (preferences.value(forKey: "peerConnectionEnabled") as? Bool) == false
    }
}

/// What `show.open` asks the controller, after the worker resolved the origin
/// and checked the file.
struct ShowOpenRequest {
    var caller: UUID
    var source: ShowSourceSpec
    var origin: ShowOrigin
    var fetcher: (any ShowFetcher)?
    var initialStat: ShowFileStat?
}

struct ShowOpenOutcome {
    enum Action: String { case opened, refreshed, reopened }
    var panel: UUID
    var workspace: UUID
    var kind: String
    var action: Action
    var replaced: UUID?
    var address: String
    var ref: String?
}

/// Opens, refreshes and closes viewers beside their callers. Main actor;
/// every fetch and poll runs in detached tasks.
@MainActor
final class ShowViewerController {
    static let shared = ShowViewerController()

    private(set) var registry = ShowRegistry()
    private var sessions: [UUID: ShowViewerSession] = [:]
    /// Panels the controller (or an agent's socket call) is closing, not the operator.
    private var closingByAgent: Set<UUID> = []
    private var installedCloseObserver = false
    var reloadInterval: TimeInterval = 1.5

    func session(panel: UUID) -> ShowViewerSession? { sessions[panel] }

    /// The viewer panel whose browser shows in `webView`, if any.
    func panelID(for webView: WKWebView) -> UUID? {
        sessions.first { $0.value.browser?.webView === webView }?.key
    }

    func isViewer(_ panel: UUID) -> Bool { sessions[panel] != nil }

    func installCloseObserver() {
        guard !installedCloseObserver else { return }
        installedCloseObserver = true
        PanelLineage.shared.addPanelClosedForGoodObserver { [weak self] ids in
            MainActor.assumeIsolated { self?.panelsClosedForGood(ids) }
        }
    }

    /// Socket-driven closes carry a request context; the operator's do not.
    func panelsClosedForGood(_ ids: Set<UUID>) {
        let socketDriven = SocketCommandContext.current != nil
        for id in ids {
            guard let session = sessions.removeValue(forKey: id) else { continue }
            ShowViewerIndex.shared.remove(id)
            session.poller?.stop()
            session.check?.finish(ShowLoadResult(status: .failed, reason: Reason.closed))
            ShowPointAndSayController.shared.viewerClosed(id)
            let byAgent = closingByAgent.remove(id) != nil || socketDriven
            registry.closed(panel: id, byOperator: !byAgent)
        }
        // A showing panel that closed: its viewers say their agent is gone.
        let orphaned = sessions.values.filter { ids.contains($0.caller) }
        guard !orphaned.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { orphaned.forEach { self?.callerChanged($0) } }
        }
    }

    // MARK: The showing agent

    /// Whether the panel that showed this can still hear from the operator.
    enum CallerState: Equatable {
        /// Live in `workspace` (where its mail goes), known by `title`.
        case live(workspace: UUID, title: String)
        /// Closed, or its terminal ended: nothing is offered to send.
        case gone
    }

    /// Read on main from c11's own state; no hc call.
    func callerState(_ session: ShowViewerSession) -> CallerState {
        guard let ws = AppDelegate.shared?.workspaceContainingPanel(panelId: session.caller)?.workspace else { return .gone }
        if let terminal = ws.panels[session.caller] as? TerminalPanel {
            var sessionLive = false
            if let runtime = terminal.hcSession, case .live = runtime.lifecycle { sessionLive = true }
            if Self.callerEnded(hostEnd: terminal.hcHostEnd, sessionLive: sessionLive, lastShownAt: session.lastShownAt) {
                return .gone
            }
        }
        return .live(workspace: ws.id, title: Self.agentTitle(ws, panel: session.caller))
    }

    /// Whether the showing terminal's agent has ended for now. A host end is
    /// a record that outlives the end itself: once resumed (or an agent was
    /// kept running there) the caller is live again, as it is when a plain
    /// shell's fresh session is live, or when it showed this after the end.
    /// A lost link or reconnecting terminal is never an end.
    nonisolated static func callerEnded(hostEnd: HCHostEndStatus?, sessionLive: Bool, lastShownAt: Date?) -> Bool {
        guard let hostEnd else { return false }
        if let lastShownAt, lastShownAt > hostEnd.endedAt { return false }
        switch hostEnd.phase {
        case .resumed, .kept: return false
        case .noConversation: return !sessionLive
        case .deciding, .queued, .starting, .resuming, .notResumed, .failed, .interrupted: return true
        }
    }

    /// The caller's machine as the operator names it (the roster, as the chip).
    static func machineLabel(_ origin: ShowOrigin) -> String {
        switch origin {
        case .local: return WhatsDifferentPlaces.look(WhatsDifferentPlaces.localID).name
        case .remote(let machine, _, _): return WhatsDifferentPlaces.look(machine).name
        }
    }

    /// The caller closed, ended, or came back: rewatch it and rewrite the bar.
    func callerChanged(_ session: ShowViewerSession) {
        guard session.panelID.map({ sessions[$0] === session }) == true else { return }
        watchCaller(session)
        if case .live(_, let title) = callerState(session) { session.callerTitle = title }
        writeMetadata(session)
    }

    private func watchCaller(_ session: ShowViewerSession) {
        let terminal = AppDelegate.shared?.workspaceContainingPanel(panelId: session.caller)?
            .workspace.panels[session.caller] as? TerminalPanel
        guard terminal !== session.watchedCaller || session.callerWatch == nil else { return }
        session.watchedCaller = terminal
        // Every change of the record counts: an end, each recovery phase, a resume.
        session.callerWatch = terminal?.$hcHostEnd.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.writeMetadata(session)
                }
            }
    }

    /// The operator pressed Return on the viewer's own address: reload the
    /// shown page as a re-show does (in place when on it, else back to it).
    @discardableResult
    func operatorReload(panel: UUID) -> Bool {
        guard let session = sessions[panel], session.browser != nil else { return false }
        let check: ShowLoadCheck
        if let current = session.check, !current.isFinished {
            check = current
        } else {
            check = ShowLoadCheck()
            Self.prepare(check, for: session)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundLoadSeconds) { [weak check] in
                check?.finish(ShowLoadResult(status: .timeout))
            }
        }
        refresh(session, check: check, stat: nil)
        return true
    }

    // MARK: Open

    /// Opens or refreshes the viewer for `request`; returns the outcome and
    /// a load check the caller may wait on (off main).
    func open(_ request: ShowOpenRequest) -> Result<(ShowOpenOutcome, ShowLoadCheck), ShowOpenError> {
        installCloseObserver()
        // Every way in (live show, Feed row, restore) has already run
        // `ShowPreflight` off main; this is the last line, cheap and local.
        if request.source.kind == .url,
           let reason = ShowPreflight.urlRefusal(request.source.target, origin: request.origin, resolvingNames: false) {
            return .failure(.refused(reason))
        }
        guard let located = AppDelegate.shared?.workspaceContainingPanel(panelId: request.caller) else {
            return .failure(.noCaller)
        }
        let ws = located.workspace
        let callerTitle = Self.agentTitle(ws, panel: request.caller)
        switch registry.decide(caller: request.caller, sourceKey: request.source.key) {
        case .refresh(let panel):
            if let session = sessions[panel] {
                guard Self.takeReshow(request, into: session) else {
                    // The source now lives on another machine or container: a
                    // viewer of its own, as for a new show.
                    close(panels: [panel])
                    if sessions[panel] != nil { return .failure(.placement) }
                    return open(request)
                }
                session.callerTitle = callerTitle
                session.noteShown()
                watchCaller(session)
                let check = ShowLoadCheck()
                Self.prepare(check, for: session)
                refresh(session, check: check, stat: request.initialStat)
                return .success((ShowOpenOutcome(panel: panel, workspace: session.workspaceID ?? ws.id,
                                                 kind: session.isMarkdown ? "markdown" : "browser", action: .refreshed,
                                                 replaced: nil, address: session.address.absoluteString,
                                                 ref: Self.ref(panel)), check))
            }
            registry.closed(panel: panel, byOperator: false)
            return open(request)
        case .open(let replacing, let reopening):
            if let replacing { close(panels: [replacing]) }
            let session = ShowViewerSession(caller: request.caller, source: request.source, origin: request.origin,
                                            fetcher: request.fetcher, callerTitle: callerTitle)
            session.noteShown()
            let check = ShowLoadCheck()
            Self.prepare(check, for: session)
            session.check = check
            guard let panel = place(session, in: ws) else { return .failure(.placement) }
            sessions[panel] = session
            ShowViewerIndex.shared.insert(panel)
            registry.opened(panel: panel, caller: request.caller, sourceKey: request.source.key, at: Date())
            watchCaller(session)
            writeMetadata(session)
            startLoad(session)
            startPolling(session, initial: request.initialStat)
            return .success((ShowOpenOutcome(panel: panel, workspace: ws.id, kind: session.isMarkdown ? "markdown" : "browser",
                                             action: reopening ? .reopened : .opened, replaced: replacing,
                                             address: session.address.absoluteString, ref: Self.ref(panel)), check))
        }
    }

    /// C11H-359 (L3): a re-show keeps the viewer as it is only when the viewer
    /// already reads through the request's link (a viewer from this Mac always does).
    nonisolated static func keepsSession(existing: ShowOrigin, requested: ShowOrigin) -> Bool {
        existing == requested
    }

    /// A re-show of what `session` shows. A viewer whose link is missing (an
    /// older save) or was re-made takes the request's verified link where it
    /// stands, so nothing on the operator's screen moves. False when the
    /// source is now on another machine or container: that needs its own viewer.
    static func takeReshow(_ request: ShowOpenRequest, into session: ShowViewerSession) -> Bool {
        if keepsSession(existing: session.origin, requested: request.origin) { return true }
        guard session.origin.isRemote, request.origin.isRemote,
              session.origin.machineName == request.origin.machineName else { return false }
        session.relink(to: request.origin, fetcher: request.fetcher ?? request.origin.fetcher())
        return true
    }

    /// A failed or timed-out load marks the viewer stale, so the next answered
    /// stat loads it again (a viewer restored before its machine's link was back).
    static func prepare(_ check: ShowLoadCheck, for session: ShowViewerSession) {
        check.onResult = { [weak session] result in
            MainActor.assumeIsolated {
                if result.status == .failed || result.status == .timeout { session?.poller?.markStale() }
            }
        }
    }

    /// How a restored viewer gets its page back.
    enum RestoredLoad: Equatable {
        /// It was hibernated: it stays so until the operator wakes it.
        case hibernated
        /// The browser panel loads its own saved URL (hash and all).
        case savedURL
        /// A URL from a linked machine: check it again before loading it.
        case preflight(URL)
        /// Load the shown source (markdown, or a viewer with no saved URL).
        case source
    }

    /// The restore decision for a viewer, from what the session saved.
    static func restoredLoad(session: ShowViewerSession, savedURL: URL?, hibernated: Bool) -> RestoredLoad {
        if hibernated { return .hibernated }
        if session.isMarkdown { return .source }
        if session.source.kind == .url, session.origin.isRemote { return .preflight(savedURL ?? session.address) }
        return savedURL == nil ? .source : .savedURL
    }

    /// A viewer panel the session restore just rebuilt: register it with its
    /// original age, wire its load signals and polling, and give it its page
    /// back as `load` says. Opens nothing new.
    func adoptRestored(_ session: ShowViewerSession, panel: any Panel, workspace: Workspace,
                       openedAt: Date?, load: RestoredLoad) {
        installCloseObserver()
        session.panelID = panel.id
        session.workspaceID = workspace.id
        if let browser = panel as? BrowserPanel {
            session.browser = browser
            browser.showNavigationObserver = { [weak session, weak browser] event in
                MainActor.assumeIsolated {
                    session?.noteNavigation(event, currentURL: browser?.webView.url?.absoluteString)
                    session?.check?.navigation(event)
                }
            }
            session.schemeHandler?.onRequest = { [weak session] isEntry, status in
                MainActor.assumeIsolated { session?.check?.request(isEntry: isEntry, status: status) }
            }
        } else if let markdown = panel as? MarkdownPanel {
            session.markdown = markdown
        }
        session.callerTitle = Self.agentTitle(workspace, panel: session.caller)
        sessions[panel.id] = session
        ShowViewerIndex.shared.insert(panel.id)
        registry.opened(panel: panel.id, caller: session.caller, sourceKey: session.source.key, at: openedAt ?? Date())
        if load != .hibernated {
            let check = ShowLoadCheck()
            Self.prepare(check, for: session)
            session.check = check
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundLoadSeconds) { [weak check] in
                check?.finish(ShowLoadResult(status: .timeout))
            }
        }
        switch load {
        case .hibernated, .savedURL:
            break
        case .source:
            startLoad(session)
        case .preflight(let url):
            let origin = session.origin
            Task.detached(priority: .userInitiated) { [weak session] in
                let refusal = ShowPreflight.urlRefusal(url.absoluteString, origin: origin)
                await MainActor.run {
                    guard let session, let browser = session.browser else { return }
                    if let refusal {
                        session.check?.finish(ShowLoadResult(status: .failed, reason: refusal))
                    } else {
                        _ = browser.navigate(to: url)
                    }
                }
            }
        }
        startPolling(session, initial: nil)
        // The caller may be restored after its viewer: settle the bar once
        // the restore pass has run.
        DispatchQueue.main.async { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.callerChanged(session)
            }
        }
    }

    /// The name the operator knows the showing agent by: the title it set,
    /// else the panel's custom title, else its live title.
    static func agentTitle(_ ws: Workspace, panel: UUID) -> String {
        let metadata = PanelMetadataStore.shared.getMetadata(workspaceId: ws.id, surfaceId: panel).metadata
        for candidate in [metadata[MetadataKey.title] as? String, ws.panelCustomTitles[panel], ws.panelTitle(panelId: panel)] {
            if let title = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        }
        return String(localized: "show.callerFallback", defaultValue: "an agent")
    }

    static func ref(_ panel: UUID) -> String? {
        TerminalController.shared.v2Ref(kind: .surface, uuid: panel) as? String
    }

    /// Beside the caller: join a viewer/browser area anchored on it, else
    /// split to its right when there is room, else a panel in its area.
    /// Never takes focus and never selects a workspace.
    private func place(_ session: ShowViewerSession, in ws: Workspace) -> UUID? {
        let caller = session.caller
        return PanelLineage.shared.withCreator(caller) { () -> UUID? in
            if session.isMarkdown {
                let key = session.origin.isRemote ? session.address.absoluteString : nil
                let path = session.origin.isRemote ? nil : session.source.target
                let panel: MarkdownPanel?
                if let pane = ws.preferredMarkdownTargetPane(fromPanelId: caller) {
                    panel = ws.newMarkdownPanel(inPane: pane, filePath: path, focus: false, remoteShowKey: key)
                } else if case .split(let direction, _, _) = TerminalController.shared.planSizeAwareSplit(
                    ws: ws, sourcePanelId: caller, requested: .right, newIsTerminal: false, force: false) {
                    panel = ws.newMarkdownSplit(from: caller, orientation: direction.orientation, insertFirst: direction.insertFirst,
                                                filePath: path, focus: false, remoteShowKey: key)
                } else if let pane = ws.paneId(forPanelId: caller) {
                    panel = ws.newMarkdownPanel(inPane: pane, filePath: path, focus: false, remoteShowKey: key)
                } else {
                    panel = nil
                }
                guard let panel else { return nil }
                ws.markdownDocAnchors[panel.id] = caller
                session.markdown = panel
                session.panelID = panel.id
                session.workspaceID = ws.id
                return panel.id
            }
            let panel: BrowserPanel?
            if let pane = ws.preferredBrowserOpenPane(fromPanelId: caller) {
                panel = ws.newBrowserSurface(inPane: pane, url: nil, focus: false, sticksAsPreferred: false, showViewer: session)
            } else if case .split(let direction, _, _) = TerminalController.shared.planSizeAwareSplit(
                ws: ws, sourcePanelId: caller, requested: .right, newIsTerminal: false, force: false) {
                panel = ws.newBrowserSplit(from: caller, orientation: direction.orientation, insertFirst: direction.insertFirst,
                                           url: nil, sticksAsPreferred: false, focus: false, showViewer: session)
            } else if let pane = ws.bonsplitController.allPaneIds.first(where: { ws.isBrowserOnlyPane($0) })
                        ?? ws.paneId(forPanelId: caller) {
                panel = ws.newBrowserSurface(inPane: pane, url: nil, focus: false, sticksAsPreferred: false, showViewer: session)
            } else {
                panel = nil
            }
            guard let panel else { return nil }
            ws.browserPanelAnchors = ws.browserPanelAnchors.filter { ws.panels[$0.key] != nil }
            ws.browserPanelAnchors[panel.id] = caller
            session.browser = panel
            session.panelID = panel.id
            session.workspaceID = ws.id
            panel.showNavigationObserver = { [weak session, weak panel] event in
                MainActor.assumeIsolated {
                    session?.noteNavigation(event, currentURL: panel?.webView.url?.absoluteString)
                    session?.check?.navigation(event)
                }
            }
            session.schemeHandler?.onRequest = { [weak session] isEntry, status in
                MainActor.assumeIsolated { session?.check?.request(isEntry: isEntry, status: status) }
            }
            return panel.id
        }
    }

    private func writeMetadata(_ session: ShowViewerSession) {
        guard let panel = session.panelID, let workspace = session.workspaceID else { return }
        let gone = callerState(session) == .gone
        let description = Self.barLine(callerTitle: session.callerTitle, updatedAt: session.updatedAt, address: session.address,
                                       callerGone: gone)
        _ = try? PanelMetadataStore.shared.setMetadata(workspaceId: workspace, surfaceId: panel,
            partial: [ShowSpec.metadataKey: session.metadataValue, MetadataKey.description: description],
            mode: .merge, source: .explicit)
        if let ws = AppDelegate.shared?.workspaceContainingPanel(panelId: panel)?.workspace { ws.objectWillChange.send() }
    }

    static func barLine(callerTitle: String, updatedAt: Date, address: URL, callerGone: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        if callerGone {
            return String(format: String(localized: "show.bar.lineGone",
                                         defaultValue: "Shown by %@, updated %@ · %@ · The agent that showed this has closed"),
                          callerTitle, formatter.string(from: updatedAt), address.absoluteString)
        }
        return String(format: String(localized: "show.bar.line",
                                     defaultValue: "Shown by %@, updated %@ · %@ · Option-click an element to tell the agent"),
                      callerTitle, formatter.string(from: updatedAt), address.absoluteString)
    }

    // MARK: Load, refresh, reload

    enum Reason {
        static var closed: String { String(localized: "show.load.closed", defaultValue: "the viewer was closed") }
        static var superseded: String { String(localized: "show.load.superseded", defaultValue: "superseded by a newer show") }
        static var panelLink: String { String(localized: "show.load.panelLink", defaultValue: "a panel link cannot be shown") }
        static var externalScheme: String {
            String(localized: "show.load.externalScheme", defaultValue: "that address opens another app, not a page")
        }
        static var markdownRender: String {
            String(localized: "show.load.markdownRender", defaultValue: "the markdown viewer could not render it")
        }
        /// C11H-386: a guarded viewer whose own-address block could not be built loads nothing.
        static var ownAddressBlock: String {
            String(localized: "show.load.ownAddressBlock",
                   defaultValue: "the viewer could not block this Mac's own addresses, so it did not load the page")
        }
        static func insecureHTTP(_ host: String) -> String {
            String(format: String(localized: "show.load.insecureHTTP",
                defaultValue: "plain HTTP to %@ needs the operator's consent in the viewer; use https or ask the operator"), host)
        }
    }

    /// How long a load the agent is not waiting on (a live reload) may take
    /// before it counts as failed and is retried.
    static let backgroundLoadSeconds: TimeInterval = 30

    /// Loads the shown source in the viewer and settles `session.check`.
    private func startLoad(_ session: ShowViewerSession) {
        if let browser = session.browser {
            withCheckKeepLive(session, browser: browser) { navigate(session, browser: browser) }
        } else if session.markdown != nil {
            loadMarkdown(session, check: session.check)
        }
    }

    private func navigate(_ session: ShowViewerSession, browser: BrowserPanel) {
        switch browser.navigate(to: session.address) {
        case .proceeded: break
        case .prompting(let host), .blocked(let host, _):
            // Plain HTTP to a host the operator has not allowed: only the
            // operator can answer, so the agent hears it now.
            session.check?.finish(ShowLoadResult(status: .failed, reason: Reason.insecureHTTP(host)))
        case .internalLinkRefused:
            session.check?.finish(ShowLoadResult(status: .failed,
                reason: browserShouldOpenURLExternally(session.address) ? Reason.externalScheme : Reason.panelLink))
        }
    }

    /// An explicit re-show: load the source again. A viewer still on the
    /// shown page reloads in place (hash and scroll kept); one the operator
    /// moved to another page goes back to the source.
    private func refresh(_ session: ShowViewerSession, check: ShowLoadCheck, stat: ShowFileStat?) {
        if session.check !== check { session.check?.finish(ShowLoadResult(status: .failed, reason: Reason.superseded)) }
        session.check = check
        if let browser = session.browser {
            withCheckKeepLive(session, browser: browser) {
                if ShowRefresh.decide(currentURL: browser.webView.url, address: session.address) == .reloadInPlace {
                    reloadBrowser(session, browser: browser)
                } else {
                    navigate(session, browser: browser)
                }
            }
        } else if session.markdown != nil {
            loadMarkdown(session, check: check)
        } else {
            check.finish(ShowLoadResult(status: .loaded))
        }
        session.updatedAt = Date()
        writeMetadata(session)
        if let stat { session.poller?.prime(stat) }
    }

    /// A viewer hidden from the operator is kept live only while its check runs,
    /// so WebKit paints and finishes it.
    private func withCheckKeepLive(_ session: ShowViewerSession, browser: BrowserPanel, _ body: () -> Void) {
        guard let check = session.check else { body(); return }
        let wasKeepLive = browser.keepLive
        if !wasKeepLive { browser.setKeepLive(true) }
        check.onFinish = { [weak browser] _ in
            MainActor.assumeIsolated { if !wasKeepLive { browser?.setKeepLive(false) } }
        }
        check.evaluatePage = { [weak browser] completion in
            MainActor.assumeIsolated {
                guard let webView = browser?.webView else { completion(nil); return }
                webView.evaluateJavaScript(ShowLoadJudge.pageScript, in: nil, in: .defaultClient) { result in
                    let page = try? result.get()
                    webView.evaluateJavaScript(ShowLoadJudge.errorCountScript, in: nil, in: .page) { errors in
                        completion(ShowLoadJudge.page(from: page, errors: try? errors.get()))
                    }
                }
            }
        }
        body()
    }

    /// Reload without touching the page: same address (hash kept), scroll read
    /// and restored from c11's own content world after the load.
    private func reloadBrowser(_ session: ShowViewerSession, browser: BrowserPanel) {
        let webView = browser.webView
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, in: .defaultClient) { [weak session] result in
            MainActor.assumeIsolated {
                if let pair = try? result.get() as? [NSNumber], pair.count == 2 {
                    session?.pendingScroll = (pair[0].doubleValue, pair[1].doubleValue)
                }
                webView.reload()
            }
        }
    }

    func restoreScrollIfNeeded(_ session: ShowViewerSession) {
        guard let (x, y) = session.pendingScroll, let webView = session.browser?.webView else { return }
        session.pendingScroll = nil
        webView.evaluateJavaScript("window.scrollTo(\(x), \(y))", in: nil, in: .defaultClient) { _ in }
    }

    /// A markdown viewer: a remote file is fetched and fed to the reader; a
    /// local one is already read by the panel. Either way the check settles
    /// only on the reader's own render result (pinned for the check, so a
    /// viewer in a hidden workspace renders too), and empty text is blank.
    private func loadMarkdown(_ session: ShowViewerSession, check: ShowLoadCheck?) {
        guard let markdown = session.markdown else { check?.finish(ShowLoadResult(status: .loaded)); return }
        guard let key = markdown.remoteShowKey, let fetcher = session.fetcher else {
            awaitMarkdownRender(session, text: markdown.content, check: check)
            return
        }
        let path = session.source.target
        Task.detached(priority: .userInitiated) { [weak session] in
            let outcome: Result<String, ShowFetchError>
            do {
                let data = try await fetcher.read(path, root: nil, maxBytes: ShowSpec.maxBytes)
                outcome = .success(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
            } catch let error as ShowFetchError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.unreachable("\(error)"))
            }
            await MainActor.run {
                guard let session, let markdown = session.markdown else { return }
                switch outcome {
                case .success(let text):
                    markdown.applyExternalContent(text, forPath: key)
                    ShowViewerController.shared.awaitMarkdownRender(session, text: text, check: check)
                case .failure(let error):
                    // Keep what the reader shows; the check (and live reload) hear the failure.
                    check?.finish(ShowLoadResult(status: .failed, reason: error.message))
                }
            }
        }
    }

    func awaitMarkdownRender(_ session: ShowViewerSession, text: String, check: ShowLoadCheck?) {
        guard let check else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            check.finish(ShowLoadResult(status: .blank, textLength: 0))
            return
        }
        guard let markdown = session.markdown else { check.finish(ShowLoadResult(status: .loaded)); return }
        let renderer = markdown.ensureRenderer()
        renderer.beginAgentQuery()
        var ended = false
        let end: @MainActor () -> Void = { if !ended { ended = true; renderer.endAgentQuery() } }
        let waiter = renderer.whenCurrentContentRendered { ready in
            MainActor.assumeIsolated {
                end()
                check.finish(ready ? ShowLoadResult(status: .loaded, textLength: text.count)
                                   : ShowLoadResult(status: .failed, reason: Reason.markdownRender))
            }
        }
        let previous = check.onFinish
        check.onFinish = { result in
            MainActor.assumeIsolated {
                if let waiter { renderer.cancelReadyAndRenderedWait(waiter) }
                end()
                previous?(result)
            }
        }
    }

    private func startPolling(_ session: ShowViewerSession, initial: ShowFileStat?) {
        guard session.source.kind == .path, let fetcher = session.fetcher, session.poller == nil else { return }
        // A local markdown viewer already has c11's own file watcher.
        if session.isMarkdown && !session.origin.isRemote { return }
        let poller = ShowReloadPoller(fetcher: fetcher, path: session.source.target, interval: reloadInterval,
            isVisible: { [weak session] in session.map(ShowViewerController.isVisible) ?? false },
            onChange: { [weak self, weak session] stat in
                guard let self, let session, let panel = session.panelID, self.registry.mayRefresh(panel: panel) else {
                    session?.poller?.loaded(stat)
                    return
                }
                self.liveReload(session, stat: stat)
            })
        session.poller = poller
        poller.start(initial: initial)
    }

    /// The file changed (or was never loaded, or the last load failed): load
    /// it again. The new stat counts only once this load succeeds; a failure
    /// or no answer in time leaves the viewer stale, to retry on the next stat.
    private func liveReload(_ session: ShowViewerSession, stat: ShowFileStat) {
        if let browser = session.browser,
           ShowRefresh.decide(currentURL: browser.webView.url, address: session.address) == .returnToSource,
           browser.webView.url != nil {
            // The operator is on another page; leave it, and remember the file as seen.
            session.poller?.loaded(stat)
            return
        }
        let check: ShowLoadCheck
        if let current = session.check, !current.isFinished {
            check = current
        } else {
            check = ShowLoadCheck()
            Self.prepare(check, for: session)
            session.check = check
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundLoadSeconds) { [weak check] in
                check?.finish(ShowLoadResult(status: .timeout))
            }
        }
        let previous = check.onResult
        check.onResult = { [weak session] result in
            MainActor.assumeIsolated {
                previous?(result)
                if result.status == .loaded || result.status == .blank { session?.poller?.loaded(stat) }
                else { session?.poller?.failed() }
            }
        }
        session.updatedAt = Date()
        writeMetadata(session)
        if let browser = session.browser {
            if browser.webView.url == nil { navigate(session, browser: browser) } else { reloadBrowser(session, browser: browser) }
        } else if session.markdown != nil {
            loadMarkdown(session, check: check)
        }
    }

    /// Visible to the operator: on screen in a visible window, not hidden.
    static func isVisible(_ session: ShowViewerSession) -> Bool {
        let view: NSView? = session.browser?.webView ?? session.markdown?.renderer?.webView
        guard let view, let window = view.window, window.isVisible,
              window.occlusionState.contains(.visible), !view.isHiddenOrHasHiddenAncestor else { return false }
        return !view.visibleRect.isEmpty
    }

    // MARK: Close

    /// Closes `caller`'s viewers of `source` (all of them when nil). A path
    /// matches on kind and target, and on its `--dir` only when one is given.
    @discardableResult
    func close(caller: UUID, source: ShowSourceSpec?) -> [UUID] {
        let panels = registry.viewers(of: caller).filter { viewer in
            guard let source else { return true }
            guard let shown = sessions[viewer.panel]?.source else { return viewer.sourceKey == source.key }
            return ShowSourceSpec.closes(source, shown)
        }.map(\.panel)
        close(panels: panels)
        return panels
    }

    private func close(panels: [UUID]) {
        for panel in panels {
            closingByAgent.insert(panel)
            if let ws = AppDelegate.shared?.workspaceContainingPanel(panelId: panel)?.workspace {
                _ = ws.closePanel(panel, force: true)
            }
            // A panel that was already gone never reaches the observer.
            if sessions[panel] != nil, AppDelegate.shared?.workspaceContainingPanel(panelId: panel) == nil {
                panelsClosedForGood([panel])
            }
        }
    }
}

enum ShowOpenError: Error, Equatable {
    case noCaller
    case placement
    case refused(String)
}

/// Where a link a viewer asks to open in a new panel goes.
enum ShowViewerNavigation: Equatable {
    case sameViewer
    case newPanel

    static func newPanelLink(isViewer: Bool) -> ShowViewerNavigation { isViewer ? .sameViewer : .newPanel }

    /// The one-time consent host to keep when a new-panel link loads in the
    /// viewer instead: only a grant for that link's own plain-HTTP host.
    static func carriedConsent(_ granted: String?, for url: URL) -> String? {
        guard let granted, url.scheme?.lowercased() == "http",
              let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? ""),
              BrowserInsecureHTTPSettings.normalizeHost(granted) == host else { return nil }
        return host
    }
}

/// What the address bar does with `c11-show:` input (C11H-247). It is
/// never sent to a search engine: in a viewer its own shown address reloads
/// the shown page, and every other `c11-show:` input is refused.
enum ShowAddressInput: Equatable {
    case notShow
    case reloadShown
    case refused

    static func isShowInput(_ input: String) -> Bool {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ShowSpec.acceptedSchemes.contains { typed.hasPrefix($0 + ":") }
    }

    static func decide(_ input: String, viewerAddress: URL?) -> ShowAddressInput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShowInput(trimmed) else { return .notShow }
        guard let viewerAddress, ShowLoadJudge.isShownPage(trimmed, address: viewerAddress) else { return .refused }
        return .reloadShown
    }
}

/// What an explicit re-show does to a browser viewer.
enum ShowRefresh: Equatable {
    case reloadInPlace
    case returnToSource

    static func decide(currentURL: URL?, address: URL) -> ShowRefresh {
        ShowLoadJudge.isShownPage(currentURL?.absoluteString, address: address) ? .reloadInPlace : .returnToSource
    }
}

/// The load check for one show: settles once, from the main actor, with the
/// first terminal fact (a failure, a finished page, or the timeout).
final class ShowLoadCheck: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: ShowLoadResult?
    private var entryStatus: Int?
    private var refusedAssets = 0
    @MainActor var onFinish: ((ShowLoadResult) -> Void)?
    @MainActor var onResult: ((ShowLoadResult) -> Void)?
    @MainActor var evaluatePage: ((@escaping (ShowLoadJudge.Page?) -> Void) -> Void)?

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    @MainActor
    func navigation(_ event: ShowNavigationEvent) {
        // The initial blank document is not the load; a redirect's final page is.
        if case .finished(let url) = event, !ShowLoadJudge.countsAsLoad(url) { return }
        guard !isFinished else {
            if case .finished = event, let session = ShowViewerController.shared.sessionOwning(self) {
                ShowViewerController.shared.restoreScrollIfNeeded(session)
            }
            return
        }
        switch event {
        case .committed, .subframe:
            break
        case .response(let status):
            lock.lock(); if entryStatus == nil { entryStatus = status }; lock.unlock()
        case .failed(let reason):
            finish(ShowLoadJudge.judge(failure: reason, entryStatus: currentEntryStatus, page: nil, refusedAssets: currentRefused))
        case .finished:
            if let session = ShowViewerController.shared.sessionOwning(self) {
                ShowViewerController.shared.restoreScrollIfNeeded(session)
            }
            guard let evaluate = evaluatePage else {
                finish(ShowLoadJudge.judge(failure: nil, entryStatus: currentEntryStatus, page: nil, refusedAssets: currentRefused))
                return
            }
            evaluate { [weak self] page in
                guard let self else { return }
                self.finish(ShowLoadJudge.judge(failure: nil, entryStatus: self.currentEntryStatus, page: page,
                                                refusedAssets: self.currentRefused))
            }
        }
    }

    @MainActor
    func request(isEntry: Bool, status: Int) {
        lock.lock(); defer { lock.unlock() }
        if isEntry { entryStatus = status }
        else if !(200..<300).contains(status) { refusedAssets += 1 }
    }

    private var currentEntryStatus: Int? { lock.lock(); defer { lock.unlock() }; return entryStatus }
    private var currentRefused: Int { lock.lock(); defer { lock.unlock() }; return refusedAssets }

    /// Settles the check once; later calls are ignored.
    func finish(_ value: ShowLoadResult) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        lock.unlock()
        semaphore.signal()
        let notify: @Sendable () -> Void = { MainActor.assumeIsolated { _ = self.onFinish?(value); _ = self.onResult?(value) } }
        if Thread.isMainThread { notify() } else { DispatchQueue.main.async(execute: notify) }
    }

    /// Waits (never on main) for the result, at most `seconds`.
    func wait(seconds: Double) -> ShowLoadResult {
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            finish(ShowLoadResult(status: .timeout, reason: String(format: String(localized: "show.load.timeout",
                defaultValue: "not loaded within %lld s"), Int64(seconds))))
        }
        lock.lock(); defer { lock.unlock() }
        return result ?? ShowLoadResult(status: .timeout)
    }
}

extension ShowViewerController {
    func sessionOwning(_ check: ShowLoadCheck) -> ShowViewerSession? {
        sessions.values.first { $0.check === check }
    }
}

/// Live reload: while the viewer is visible, one `stat` per interval through
/// its fetcher (off main); a fetch only when size or mtime changed; while
/// hidden, nothing reaches the machine. Never injects anything into the page.
final class ShowReloadPoller: @unchecked Sendable {
    private let fetcher: any ShowFetcher
    private let path: String
    private let interval: TimeInterval
    private let isVisible: @MainActor () -> Bool
    private let onChange: @MainActor (ShowFileStat) -> Void
    private let lock = NSLock()
    private var rule = ShowReloadRule()
    private var task: Task<Void, Never>?
    /// Test seam: called off main with whether the stat ran on the main thread.
    var onStat: ((Bool) -> Void)?

    init(fetcher: any ShowFetcher, path: String, interval: TimeInterval,
         isVisible: @escaping @MainActor () -> Bool, onChange: @escaping @MainActor (ShowFileStat) -> Void) {
        self.fetcher = fetcher; self.path = path; self.interval = interval
        self.isVisible = isVisible; self.onChange = onChange
    }

    /// What the viewer has loaded (the stat `show` checked before loading).
    func prime(_ stat: ShowFileStat) {
        lock.lock(); rule = ShowReloadRule(last: stat); lock.unlock()
    }

    func markStale() { lock.lock(); rule.markStale(); lock.unlock() }
    /// The load `onChange` started succeeded with these bytes.
    func loaded(_ stat: ShowFileStat?) { lock.lock(); rule.loaded(stat); lock.unlock() }
    /// It failed: retry on the next answered stat.
    func failed() { lock.lock(); rule.failed(); lock.unlock() }

    var state: ShowReloadRule { lock.lock(); defer { lock.unlock() }; return rule }

    func start(initial: ShowFileStat?) {
        if let initial { prime(initial) }
        task?.cancel()
        let nanoseconds = UInt64(max(0.01, interval) * 1_000_000_000)
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One tick: no hc call unless visible and idle; a change runs `onChange` on main.
    func tick() async {
        let visible = await MainActor.run { isVisible() }
        lock.lock(); let step = rule.step(visible: visible); lock.unlock()
        guard step == .stat else { return }
        onStat?(Thread.isMainThread)
        guard let stat = try? await fetcher.stat(path) else { return }
        lock.lock(); let outcome = rule.observe(stat); lock.unlock()
        if outcome == .changed { await MainActor.run { onChange(stat) } }
    }
}

/// C11H-247: c11's own probe for frames that never navigate (`about:blank`,
/// `srcdoc`). A user script in c11's own content world posts from every
/// frame but the top one; WebKit's `frameInfo` on the message, not anything
/// the script says, decides that it came from a subframe. Page scripts can
/// neither see the script nor reach its handler, and the handler only marks
/// the viewer's current document as having embedded content.
final class ShowSubframeProbe: NSObject, WKScriptMessageHandler {
    static let handlerName = "c11ShowFrame"
    static let world = WKContentWorld.world(name: "c11-show")
    static let script = "if (window !== window.top) { window.webkit.messageHandlers.c11ShowFrame.postMessage(0); }"

    private weak var session: ShowViewerSession?

    private init(session: ShowViewerSession) { self.session = session }

    @MainActor
    static func install(in config: WKWebViewConfiguration, session: ShowViewerSession) {
        let controller = config.userContentController
        controller.add(ShowSubframeProbe(session: session), contentWorld: world, name: handlerName)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame else { return }
        let url = message.webView?.url?.absoluteString
        MainActor.assumeIsolated { session?.noteNavigation(.subframe, currentURL: url) }
    }
}
