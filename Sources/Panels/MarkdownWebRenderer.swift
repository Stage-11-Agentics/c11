import AppKit
import Combine
import Bonsplit
import WebKit

@MainActor
final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    private let policy: MarkdownAssetPolicy
    private var active: [ObjectIdentifier: UUID] = [:]
    private let queue = DispatchQueue(label: "com.stage11.c11.markdown-assets", qos: .userInitiated)

    init(policy: MarkdownAssetPolicy) { self.policy = policy }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let token = UUID()
        active[key] = token
        let policy = self.policy
        let url = urlSchemeTask.request.url
        queue.async { [weak self] in
            let result = Result { () throws -> (Data, String) in
                guard let url else { throw URLError(.badURL) }
                let resource = try policy.resource(for: url)
                return (resource.data, resource.mime)
            }
            DispatchQueue.main.async {
                guard let self, self.active[key] == token else { return }
                self.active.removeValue(forKey: key)
                switch result {
                case .success(let (data, mime)):
                    guard let url else { return }
                    let headers = ["Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
                                   "Content-Security-Policy": MarkdownAssetPolicy.csp,
                                   "X-Content-Type-Options": "nosniff"]
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                        ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                case .failure(let error): urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }
}

/// Read-only content must not claim WebKit's page zoom shortcuts.
final class MarkdownWKWebView: WKWebView {
    var allowsPanelFocus = false
    weak var renderer: MarkdownWebRenderer?
    var onShowPanelDetails: (() -> Void)?
    var onViewportSizeChange: ((NSSize) -> Void)?
    private var pointerFocus = false
    private var retainedViewport: NSSize?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderer?.synchronize()
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        for item in Array(menu.items.reversed()) where Self.isBlockedContextMenuItem(item) {
            menu.removeItem(item)
        }

        guard !menu.items.contains(where: { $0.action == #selector(showPanelDetails(_:)) }) else { return }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let details = NSMenuItem(
            title: String(localized: "surfaceManifest.menuItem", defaultValue: "Panel Details"),
            action: #selector(showPanelDetails(_:)),
            keyEquivalent: ""
        )
        details.target = self
        menu.addItem(details)
    }

    private static func isBlockedContextMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = item.identifier?.rawValue ?? ""
        let title = item.title.lowercased()
        return identifier.hasPrefix("WKMenuItemIdentifier") && (
            identifier.contains("Open") || identifier.contains("Back") || identifier.contains("Forward") ||
                identifier.contains("Download") ||
                identifier.contains("Reload") || identifier.localizedCaseInsensitiveContains("CopyLink")
        ) || title.hasPrefix("open ") || title == "back" || title == "forward" ||
            title.contains("download") || title.contains("reload") || title == "copy link"
    }

    @objc private func showPanelDetails(_ sender: Any?) {
        _ = sender
        onShowPanelDetails?()
    }

    /// SwiftUI zeroes a dismantled host. Keep a hidden reader at its last
    /// mounted size so later visible() capture uses the operator's geometry.
    func setViewportVisible(_ visible: Bool) {
        if visible { retainedViewport = nil }
        else if frame.width > 0, frame.height > 0 { retainedViewport = frame.size }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let size = retainedViewport ?? newSize
        super.setFrameSize(size)
        if retainedViewport == nil { onViewportSizeChange?(size) }
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            var rect = newValue
            if let retainedViewport { rect.size = retainedViewport }
            super.frame = rect
            if retainedViewport == nil { onViewportSizeChange?(rect.size) }
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard allowsPanelFocus || pointerFocus else { return false }
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestPanelFocusIfAllowed()
    }

    func requestPanelFocusIfAllowed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.allowsPanelFocus else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pointerFocus = true
        defer { pointerFocus = false }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76 { return false }
        guard shouldRouteCommandEquivalentDirectlyToMainMenu(event) else {
            return super.performKeyEquivalent(with: event)
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        if AppDelegate.shared?.handleWebPanelKeyEquivalent(event) == true { return true }
        if ["=", "+", "-", "0"].contains(event.charactersIgnoringModifiers ?? "") {
            return false // Never let WebKit page zoom claim c11's scale shortcuts.
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           AppDelegate.shared?.handleWebPanelKeyEquivalent(event) == true { return }
        super.keyDown(with: event)
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        let filtered = DragOverlayRoutingPolicy.webViewDragTypes(newTypes)
        if !filtered.isEmpty { super.registerForDraggedTypes(filtered) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

struct MarkdownReaderReadout: Equatable {
    var headingPath: [String] = []
    var progress = 0.0
    var minutesLeft = 0
    var mode = "read"
}

struct MarkdownReaderFindSnapshot: Equatable {
    let isOpen: Bool
    let query: String
    let matches: Int
    let current: Int
}

struct MarkdownReaderThemeChoice: Equatable, Identifiable {
    let id: String
    let label: String
    let scheme: String
    let defaultTypeface: String
}

struct MarkdownReaderTypefaceChoice: Equatable, Identifiable {
    let id: String
    let label: String
    let family: String
    let measure: Double?
    let leading: Double?
}

struct MarkdownReaderOutlineSnapshot: Equatable {
    var revision = ""
    var isOpen = false
    var isDocked = false
    var choice: Bool? = nil
}

@MainActor
final class MarkdownReaderReadoutState: ObservableObject {
    @Published private(set) var value = MarkdownReaderReadout()
    func update(_ value: MarkdownReaderReadout) { if self.value != value { self.value = value } }
}

@MainActor
final class MarkdownReaderFindState: ObservableObject {
    @Published private(set) var value: MarkdownReaderFindSnapshot?
    func update(_ value: MarkdownReaderFindSnapshot?) { if self.value != value { self.value = value } }
}

@MainActor
final class MarkdownReaderOutlineState: ObservableObject {
    @Published private(set) var value = MarkdownReaderOutlineSnapshot()
    func update(_ value: MarkdownReaderOutlineSnapshot) { if self.value != value { self.value = value } }
}

@MainActor
final class MarkdownWebRenderer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// Shared process resources, separate controllers/handlers per document.
    private static let processPool = WKProcessPool()
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    let webView: MarkdownWKWebView
    private(set) var state: [String: Any] = [:]
    @Published private(set) var themeChoices: [MarkdownReaderThemeChoice] = []
    @Published private(set) var typefaceChoices: [MarkdownReaderTypefaceChoice] = []
    let readerReadout = MarkdownReaderReadoutState()
    let readerFind = MarkdownReaderFindState()
    let readerOutline = MarkdownReaderOutlineState()
    @Published private(set) var failure: Bool = false {
        didSet {
            if failure {
                resolveRenderWaiters(success: false)
                MarkdownRendererCache.shared.reconsider()
            }
        }
    }
    @Published private(set) var renderedRevision: Int?
    private weak var panel: MarkdownPanel?
    private var stateObservers: [UUID: ([String: Any]?) -> Void] = [:]
    private var renderWaiters: [UUID: (Bool) -> Void] = [:]
    private var ready = false
    private var entryNavigationAdmitted = false
    private var closed = false
    private var loadedContent: String?
    private var loadedSettings: [String: String] = [:]
    private var revision = 0
    private var pendingRestorePosition: MarkdownReadingPosition?
    private var pendingNavigationFragment: String?
    private var hasPendingNavigation = false
    private var pendingNavigationToken = 0
    private(set) var navigationToken = 0
    private var activePeekRequestID: Int?
    private var restoreContentBeforeReload: String?
    private var activeQueries = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime
    var hasQueriesInFlight: Bool { activeQueries > 0 }
    var canCaptureReadingPosition: Bool { ready || failure }
    var isReadyForQueries: Bool { ready && !closed }
    private var recoveringAfterTermination = false

    init(panel: MarkdownPanel) {
        self.panel = panel
        navigationToken = panel.currentNavigationToken
        let pendingNavigation = panel.takePendingNavigation()
        pendingRestorePosition = pendingNavigation.position ?? panel.readingPosition
        pendingNavigationFragment = pendingNavigation.fragment
        hasPendingNavigation = pendingNavigation.position != nil || pendingNavigation.fragment != nil
        pendingNavigationToken = navigationToken
        restoreContentBeforeReload = panel.readingContent
        let root = Bundle.main.resourceURL?.appendingPathComponent("markdown-viewer", isDirectory: true)
        let policy = MarkdownAssetPolicy(
            bundle: root.flatMap(MarkdownAssetRoot.init(directory:)),
            document: panel.filePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }.flatMap(MarkdownAssetRoot.init(directory:))
        )
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.websiteDataStore = Self.dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let scheme = MarkdownSchemeHandler(policy: policy)
        config.setURLSchemeHandler(scheme, forURLScheme: MarkdownAssetPolicy.viewerScheme)
        config.setURLSchemeHandler(scheme, forURLScheme: MarkdownAssetPolicy.imageScheme)
        webView = MarkdownWKWebView(frame: NSRect(origin: .zero, size: panel.lastKnownViewportSize), configuration: config)
        super.init()
        webView.renderer = self
        webView.onViewportSizeChange = { [weak panel] size in panel?.rememberViewportSize(size) }
        webView.onShowPanelDetails = { [weak panel] in
            guard let panel else { return }
            PanelManifestViewerWindowController.show(
                workspaceId: panel.workspaceId,
                surfaceId: panel.id,
                kind: .markdown
            )
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.pageZoom = 1
        webView.setValue(false, forKey: "drawsBackground")
        config.userContentController.add(self, name: "c11md")
        webView.load(URLRequest(url: MarkdownAssetPolicy.entryURL))
    }

    func close() {
        guard !closed else { return }
        closed = true
        resolveRenderWaiters(success: false)
        let observers = Array(stateObservers.values)
        stateObservers.removeAll()
        observers.forEach { $0(nil) }
        webView.stopLoading()
        webView.renderer = nil
        webView.onShowPanelDetails = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "c11md")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// State observers do not retain a hidden reader. The panel-level watch
    /// subscription survives cache eviction and attaches to a later renderer.
    func observeState(_ observer: @escaping ([String: Any]?) -> Void) -> (id: UUID, state: [String: Any])? {
        guard ready, !closed else { return nil }
        let id = UUID()
        stateObservers[id] = observer
        return (id, state)
    }

    func removeStateObserver(_ id: UUID) {
        stateObservers.removeValue(forKey: id)
    }

    /// Hold the retention entry while a socket query waits for readiness or
    /// runs JavaScript. Long-lived watches never keep this pin.
    func beginAgentQuery() {
        guard !closed else { return }
        activeQueries += 1
        if let panel { MarkdownRendererCache.shared.queryStarted(panel) }
    }

    func endAgentQuery() {
        guard activeQueries > 0 else { return }
        activeQueries -= 1
        if let panel { MarkdownRendererCache.shared.queryFinished(panel) }
    }

    /// Wait for both the page bridge and its first content revision. The token
    /// lets a timed-out socket request remove its callback from the renderer.
    @discardableResult
    func whenReadyAndRendered(_ completion: @escaping (Bool) -> Void) -> UUID? {
        guard !closed, !failure else {
            completion(false)
            return nil
        }
        if ready, renderedRevision != nil {
            completion(true)
            return nil
        }
        let id = UUID()
        renderWaiters[id] = completion
        return id
    }

    func cancelReadyAndRenderedWait(_ id: UUID) {
        renderWaiters.removeValue(forKey: id)
    }

    private func resolveRenderWaiters(success: Bool) {
        let waiters = Array(renderWaiters.values)
        renderWaiters.removeAll()
        waiters.forEach { $0(success) }
    }

    /// Updates the query cache and notifies watches from a native-initiated
    /// WebKit query. Hidden workspaces can throttle requestAnimationFrame, so
    /// command results must not depend on a later bridge state message.
    func publishObservedState(_ value: [String: Any]) {
        guard !closed else { return }
        state = value
        for observer in stateObservers.values { observer(value) }
        panel?.publishRendererState(value)
    }

    /// Native callers use JSON arguments, never interpolate document text into JS.
    func call(_ method: String, arguments: [Any] = [], completion: ((Result<Any, Error>) -> Void)? = nil) {
        guard ready, !closed else {
            completion?(.failure(URLError(.resourceUnavailable)))
            return
        }
        activeQueries += 1
        if let panel { MarkdownRendererCache.shared.queryStarted(panel) }
        webView.callAsyncJavaScript(
            "return await window.c11md[method](...args)",
            arguments: ["method": method, "args": arguments], in: nil, in: .page
        ) { [self] result in
            // Completion may issue the next step of a restore. Keep this pin
            // until that continuation has had the chance to add its own pin.
            completion?(result)
            activeQueries -= 1
            if let panel { MarkdownRendererCache.shared.queryFinished(panel) }
        }
    }

    func captureReadingPosition(completion: @escaping (MarkdownReadingPosition) -> Void) {
        let fallback = MarkdownReadingPosition(state: state) ?? panel?.readingPosition ?? MarkdownReadingPosition()
        guard ready, !closed else { completion(fallback); return }
        // The cache tracks this capture separately from agent/native queries;
        // a concurrent query increments its epoch and invalidates the capture.
        webView.callAsyncJavaScript("return window.c11md.visible()", arguments: [:], in: nil, in: .page) { result in
            let position: MarkdownReadingPosition?
            if case .success(let value) = result, let state = value as? [String: Any] {
                position = MarkdownReadingPosition(state: state)
            } else { position = nil }
            completion(position ?? fallback)
        }
    }

    func advanceNavigation(to token: Int) {
        guard token >= navigationToken else { return }
        navigationToken = token
        activePeekRequestID = nil
        guard pendingNavigationToken != token else { return }
        pendingRestorePosition = nil
        pendingNavigationFragment = nil
        hasPendingNavigation = false
        pendingNavigationToken = token
    }

    func prepareNavigation(position: MarkdownReadingPosition?, fragment: String?, navigationToken: Int) {
        guard navigationToken == self.navigationToken else { return }
        pendingRestorePosition = position
        pendingNavigationFragment = fragment
        hasPendingNavigation = true
        pendingNavigationToken = navigationToken
        panel?.clearPendingNavigation()
    }

    func navigateWithinDocument(position: MarkdownReadingPosition?, fragment: String?, navigationToken: Int) {
        guard navigationToken == self.navigationToken else { return }
        panel?.clearPendingNavigation()
        if let position {
            restoreReadingPosition(position, revision: revision, navigationToken: navigationToken, completion: {})
        } else if let fragment {
            call("navigateFragment", arguments: [fragment]) { [weak self] result in
                guard let self, self.navigationToken == navigationToken else { return }
                guard case .success(let value) = result,
                      (value as? [String: Any])?["ok"] as? Bool == false else { return }
                self.call("showBrokenAnchorSuggestions", arguments: [fragment])
            }
        }
    }

    private func finishRender(_ revision: Int) {
        guard !closed, revision == self.revision else { return }
        renderedRevision = revision
        resolveRenderWaiters(success: true)
#if DEBUG
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        dlog("markdown.renderer.ready panel=\(panel?.id.uuidString ?? "unknown") elapsedMs=\(String(format: "%.3f", elapsed))")
#endif
    }

    private func restoreReadingPosition(
        _ position: MarkdownReadingPosition,
        revision: Int,
        navigationToken: Int,
        completion: (() -> Void)? = nil
    ) {
        call("setSourceMode", arguments: [position.sourceMode]) { [weak self] _ in
            guard let self, !self.closed, self.navigationToken == navigationToken else { return }
            let scroll = {
                guard self.navigationToken == navigationToken else { return }
                self.call("scrollToLine", arguments: [position.line, position.offset]) { [weak self] result in
                    guard let self, !self.closed, self.navigationToken == navigationToken else { return }
#if DEBUG
                    if case .success(let value) = result, let state = value as? [String: Any],
                       let actual = MarkdownReadingPosition(state: state) {
                        dlog("markdown.renderer.restored panel=\(self.panel?.id.uuidString ?? "unknown") line=\(actual.line) offset=\(actual.offset) width=\(self.webView.frame.width) height=\(self.webView.frame.height)")
                    }
#endif
                    if let completion { completion() }
                    else { self.finishRender(revision) }
                }
            }
            let restoreFindPopover = {
                guard self.navigationToken == navigationToken else { return }
                guard position.findOpen else { scroll(); return }
                self.call("openFind", arguments: [self.webView.allowsPanelFocus]) { [weak self] _ in
                    guard self?.navigationToken == navigationToken else { return }
                    scroll()
                }
            }
            if position.findQuery.isEmpty { restoreFindPopover() }
            else { self.call("find", arguments: [position.findQuery]) { [weak self] _ in
                guard self?.navigationToken == navigationToken else { return }
                restoreFindPopover()
            } }
        }
    }

    func synchronize() {
        guard ready, !closed, let panel else { return }
        webView.pageZoom = 1
        let appearance = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        let settings = ["theme": panel.theme, "typeface": panel.typeface,
                        "scale": String(panel.fontScale), "outline": panel.outlineOpen.map(String.init) ?? "auto",
                        "appearance": appearance]
        if settings != loadedSettings {
            loadedSettings = settings
            call("setSettings", arguments: [["theme": panel.theme, "typeface": panel.typeface, "scale": panel.fontScale,
                                             "outlineOpen": panel.outlineOpen as Any? ?? "auto", "osAppearance": appearance,
                                             "strings": Self.localizedStrings]]) { [weak self] result in
                guard case .success(let value) = result,
                      let state = value as? [String: Any] else { return }
                self?.publishObservedState(state)
            }
        }
        let content = restoreContentBeforeReload ?? panel.content
        if loadedContent != content {
            loadedContent = content
            revision += 1
            call("load", arguments: [["markdown": content, "documentPath": panel.filePath ?? "",
                                      "baseURL": panel.filePath.map { URL(fileURLWithPath: $0).absoluteString } ?? "",
                                      "revision": revision]]) { [weak self] result in
                guard case .success(let value) = result,
                      let state = value as? [String: Any] else { return }
                self?.publishObservedState(state)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == MarkdownAssetPolicy.viewerScheme,
              message.frameInfo.request.url?.host == "bundle",
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard (body["version"] as? Int) == 1 else { failure = true; return }
            ready = true
            failure = false
            loadRegistryChoices()
            synchronize()
            MarkdownRendererCache.shared.reconsider()
        case "state":
            if let value = body["state"] as? [String: Any] {
                updateReaderState(value)
                publishObservedState(value)
            }
        case "error":
            if body["code"] as? String == "render_failed" { failure = true }
        case "rendered":
            recoveringAfterTermination = false
            if let value = body["revision"] as? Int {
                let finishNavigation: () -> Void = { [weak self] in
                    guard let self else { return }
                    let capturedContent = self.restoreContentBeforeReload
                    self.restoreContentBeforeReload = nil
                    if let capturedContent {
                        self.panel?.clearReadingContent(ifMatching: capturedContent)
                        guard let panel = self.panel else {
                            self.finishRender(value)
                            return
                        }
                        guard panel.content != capturedContent else {
                            self.finishRender(value)
                            return
                        }
                        // Keep the host hidden until the bridge has applied its
                        // same-document capture/restore to the latest content.
                        self.renderedRevision = nil
                        self.synchronize()
                    } else {
                        self.finishRender(value)
                    }
                }
                if let position = pendingRestorePosition {
                    guard pendingNavigationToken == navigationToken else {
                        pendingRestorePosition = nil
                        pendingNavigationFragment = nil
                        hasPendingNavigation = false
                        finishRender(value)
                        return
                    }
                    pendingRestorePosition = nil
                    hasPendingNavigation = false
                    pendingNavigationFragment = nil
                    restoreReadingPosition(
                        position,
                        revision: value,
                        navigationToken: pendingNavigationToken,
                        completion: finishNavigation
                    )
                } else if hasPendingNavigation {
                    guard pendingNavigationToken == navigationToken else {
                        hasPendingNavigation = false
                        pendingNavigationFragment = nil
                        finishRender(value)
                        return
                    }
                    hasPendingNavigation = false
                    let fragment = pendingNavigationFragment
                    let navigationToken = pendingNavigationToken
                    pendingNavigationFragment = nil
                    if let fragment {
                        call("navigateFragment", arguments: [fragment]) { [weak self] result in
                            guard let self, self.navigationToken == navigationToken else { return }
                            if case .success(let value) = result,
                               (value as? [String: Any])?["ok"] as? Bool == false {
                                self.call("showBrokenAnchorSuggestions", arguments: [fragment])
                            }
                            finishNavigation()
                        }
                    } else { finishNavigation() }
                } else { finishRender(value) }
            }
        case "link":
            if let href = body["href"] as? String, href.utf8.count <= 16 * 1024 {
                let modifiers = body["modifiers"] as? [String: Bool] ?? [:]
                let position = (body["position"] as? [String: Any]).flatMap { MarkdownReadingPosition(state: $0) }
                guard body["localOnly"] as? Bool != true else { break }
                _ = routeLink(href, modifiers: modifiers, position: position)
            }
        case "peek":
            guard let requestID = body["id"] as? Int, requestID >= 0 else { return }
            if body["action"] as? String == "hide" {
                activePeekRequestID = requestID
                call("hideLinkPeek", arguments: [requestID])
            } else if let href = body["href"] as? String, href.utf8.count <= 16 * 1024 {
                routePeek(href, requestID: requestID, rect: body["rect"] as? [String: Any] ?? [:])
            }
        case "copy":
            guard let text = body["text"] as? String, text.utf8.count <= 1024 * 1024 else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "outlineDismiss":
            panel?.setOutlineOpen(false)
        case "escapeUnhandled":
            _ = panel?.dismissReaderOverlay(pageConsumedEscape: false)
        default: break
        }
    }

    private func updateReaderState(_ value: [String: Any]) {
        state = value
        readerReadout.update(MarkdownReaderReadout(
            headingPath: value["heading_path"] as? [String] ?? [],
            progress: min(max(value["progress"] as? Double ?? 0, 0), 1),
            minutesLeft: max(0, value["minutes_left"] as? Int ?? 0),
            mode: value["mode"] as? String ?? "read"
        ))

        let find = value["find"] as? [String: Any]
        let query = find?["query"] as? String ?? ""
        let findOpen = find?["open"] as? Bool ?? !query.isEmpty
        readerFind.update((findOpen || !query.isEmpty) ? MarkdownReaderFindSnapshot(
            isOpen: findOpen,
            query: query,
            matches: max(0, find?["matches"] as? Int ?? 0),
            current: max(0, find?["current"] as? Int ?? 0)
        ) : nil)

        let outline = value["outline"] as? [String: Any] ?? [:]
        let revision = value["revision"].map { String(describing: $0) } ?? ""
        readerOutline.update(MarkdownReaderOutlineSnapshot(
            revision: revision,
            isOpen: outline["open"] as? Bool ?? false,
            isDocked: outline["docked"] as? Bool ?? false,
            choice: outline["choice"] as? Bool
        ))
    }

    private func loadRegistryChoices() {
        call("themes") { [weak self] result in
            guard case .success(let value) = result,
                  let entries = value as? [[String: Any]] else { return }
            self?.themeChoices = entries.compactMap { entry in
                guard let id = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
                return MarkdownReaderThemeChoice(
                    id: id,
                    label: label,
                    scheme: entry["scheme"] as? String ?? "system",
                    defaultTypeface: entry["defaultTypeface"] as? String ?? "serif"
                )
            }
        }
        call("typefaces") { [weak self] result in
            guard case .success(let value) = result,
                  let entries = value as? [[String: Any]] else { return }
            self?.typefaceChoices = entries.compactMap { entry in
                guard let id = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
                return MarkdownReaderTypefaceChoice(
                    id: id,
                    label: label,
                    family: entry["family"] as? String ?? "",
                    measure: entry["measure"] as? Double,
                    leading: entry["leading"] as? Double
                )
            }
        }
    }

    static func shouldOpenTargetInNewPanel(
        _ target: MarkdownLinkTarget,
        metaHeld: Bool,
        defaultIsNewPanel: Bool
    ) -> Bool {
        guard case .markdown = target else { return false }
        return metaHeld != defaultIsNewPanel
    }

    @discardableResult
    func routeLink(
        _ href: String,
        modifiers: [String: Bool],
        position: MarkdownReadingPosition?
    ) -> Task<Void, Never>? {
        guard let panel, let filePath = panel.filePath else { return nil }
        let linkTarget = MarkdownLinkTarget.resolve(href, documentPath: filePath)
        let opensNewPanel = Self.shouldOpenTargetInNewPanel(
            linkTarget,
            metaHeld: modifiers["meta"] == true,
            defaultIsNewPanel: UserDefaults.standard.bool(forKey: "markdown.links.openInNewPanel")
        )
        switch linkTarget {
        case .anchor:
            guard let encoded = href.hasPrefix("#") ? String(href.dropFirst()) : nil,
                  let fragment = encoded.removingPercentEncoding,
                  !fragment.isEmpty else { return nil }
            let navigationToken = panel.beginNavigationIntent()
            let targetURL = URL(fileURLWithPath: filePath)
            return Task { @MainActor [weak panel] in
                _ = await panel?.navigateFromDocumentLink(
                    to: targetURL,
                    fragment: fragment,
                    position: position,
                    pageAlreadyHandled: true,
                    navigationToken: navigationToken
                )
            }
        case .blocked: return nil
        case .markdown(let url):
            let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
            let navigationToken = panel.beginNavigationIntent()
            if opensNewPanel {
                return openMarkdownPanel(url, fragment: fragment, source: panel, navigationToken: navigationToken)
            } else {
                return Task { @MainActor [weak panel] in
                    _ = await panel?.navigateFromDocumentLink(
                        to: url,
                        fragment: fragment,
                        position: position,
                        pageAlreadyHandled: false,
                        navigationToken: navigationToken
                    )
                }
            }
        case .web(let url):
            openC11WebLink(
                url,
                sourceWorkspaceId: panel.workspaceId,
                sourcePanelId: panel.id,
                optionHeld: modifiers["alt"] == true
            )
        case .mailto(let url):
            _ = NSWorkspace.shared.open(url)
        }
        return nil
    }

    private func openMarkdownPanel(
        _ target: URL,
        fragment: String?,
        source panel: MarkdownPanel,
        navigationToken: Int
    ) -> Task<Void, Never> {
        Task { @MainActor [weak panel] in
            guard let panel,
                  case .ready(let path, _, _, let scopeRootPath) = await panel.prepareDocumentLink(target),
                  panel.isCurrentNavigation(navigationToken),
                  let workspace = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: panel.id,
                    preferredWorkspaceId: panel.workspaceId
                  )?.workspace,
                  let pane = workspace.paneId(forPanelId: panel.id) else { return }
            _ = workspace.newMarkdownPanel(
                inPane: pane,
                filePath: path,
                fragment: fragment,
                focus: true,
                initialNavigationOrigin: .documentLink,
                initialNavigationScopeRootPath: scopeRootPath
            )
        }
    }

    func routePeek(_ href: String, requestID: Int, rect: [String: Any]) {
        guard let panel, let filePath = panel.filePath else { return }
        let navigationToken = panel.currentNavigationToken
        let targetURL: URL
        let fragment: String?
        switch MarkdownLinkTarget.resolve(href, documentPath: filePath) {
        case .anchor:
            guard href.hasPrefix("#"), let decoded = String(href.dropFirst()).removingPercentEncoding,
                  !decoded.isEmpty else { return }
            targetURL = URL(fileURLWithPath: filePath)
            fragment = decoded
        case .markdown(let url):
            targetURL = url
            fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
        case .web, .mailto, .blocked:
            return
        }
        activePeekRequestID = requestID
        Task { @MainActor [weak self, weak panel] in
            guard let self, let panel,
                  case .ready(let path, let content, _, _) = await panel.prepareDocumentLink(
                    targetURL,
                    maximumContentBytes: MarkdownNavigationPolicy.maximumPeekContentBytes
                  ),
                  panel.isCurrentNavigation(navigationToken),
                  self.navigationToken == navigationToken,
                  self.activePeekRequestID == requestID,
                  let markdown = content ?? (Self.resolvedPath(path) == panel.filePath.map(Self.resolvedPath) ? panel.content : nil),
                  markdown.utf8.count <= MarkdownNavigationPolicy.maximumPeekContentBytes else { return }
            self.call("showLinkPeek", arguments: [requestID, path, fragment as Any? ?? NSNull(), markdown, rect])
        }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only our single initial top-level entry is allowed. Every document
        // navigation, download, redirect, target=_blank and frame is denied.
        let initial = !entryNavigationAdmitted && navigationAction.navigationType == .other
            && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url == MarkdownAssetPolicy.entryURL
        if initial { entryNavigationAdmitted = true }
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("typeof window.c11md === 'object'") { [weak self] value, error in
            if error != nil || value as? Bool != true { self?.failure = true }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        guard !recoveringAfterTermination else {
            failure = true
            return
        }
        recoveringAfterTermination = true
        pendingRestorePosition = MarkdownReadingPosition(state: state)
        pendingNavigationToken = navigationToken
        ready = false
        renderedRevision = nil
        entryNavigationAdmitted = false
        loadedContent = nil
        loadedSettings = [:]
        webView.load(URLRequest(url: MarkdownAssetPolicy.entryURL))
    }

    private static var localizedStrings: [String: String] { [
        "copy": String(localized: "markdown.reader.copy", defaultValue: "Copy"),
        "copied": String(localized: "markdown.reader.copied", defaultValue: "Copied"),
        "copyLink": String(localized: "markdown.reader.copyLink", defaultValue: "Copy link"),
        "expand": String(localized: "markdown.reader.expand", defaultValue: "Expand"),
        "close": String(localized: "markdown.reader.close", defaultValue: "Close"),
        "diagram": String(localized: "markdown.reader.diagram", defaultValue: "Diagram"),
        "diagramError": String(localized: "markdown.reader.diagramError", defaultValue: "Could not render diagram"),
        "imageBlocked": String(localized: "markdown.reader.imageBlocked", defaultValue: "Image blocked"),
        "notes": String(localized: "markdown.reader.notes", defaultValue: "Notes"),
        "back": String(localized: "markdown.reader.back", defaultValue: "Back"),
        "source": String(localized: "markdown.reader.source", defaultValue: "Source"),
        "frontmatter": String(localized: "markdown.reader.frontmatter", defaultValue: "Frontmatter"),
        "outlineTitle": String(localized: "markdown.reader.outline.title", defaultValue: "Outline"),
        "outlineFilter": String(localized: "markdown.reader.outline.filter", defaultValue: "Filter outline"),
        "outlineEmpty": String(localized: "markdown.reader.outline.empty", defaultValue: "No headings"),
        "outlineNoMatches": String(localized: "markdown.reader.outline.noMatches", defaultValue: "No headings match"),
        "outlineClearFilter": String(localized: "markdown.reader.outline.clearFilter", defaultValue: "Clear filter"),
        "outlineSummary": String(localized: "markdown.reader.outline.summary", defaultValue: "%d min · %d words · %d lines"),
        "outlineTaskCount": String(localized: "markdown.reader.outline.taskCount", defaultValue: "%d of %d tasks complete"),
        "findOpen": String(localized: "markdown.reader.find.open", defaultValue: "Find (⌘F)"),
        "findPlaceholder": String(localized: "markdown.reader.find.placeholder", defaultValue: "Find in document"),
        "findPrevious": String(localized: "markdown.reader.find.previous", defaultValue: "Previous match"),
        "findNext": String(localized: "markdown.reader.find.next", defaultValue: "Next match"),
        "findClose": String(localized: "markdown.reader.find.close", defaultValue: "Close find"),
        "findCount": String(localized: "markdown.reader.find.count", defaultValue: "%d / %d"),
        "brokenAnchorTitle": String(localized: "markdown.reader.navigation.brokenAnchor", defaultValue: "Heading “%s” not found. Closest headings:"),
        "linkPeekTitle": String(localized: "markdown.reader.navigation.preview", defaultValue: "Preview")
    ] }
}

extension MarkdownWebRenderer: MarkdownPanelReaderCommanding {
    var readerOutlineIsOpen: Bool { readerOutline.value.isOpen }

    func call(_ method: String) {
        call(method, arguments: [])
    }

    func openFind(focusAllowed: Bool) {
        call("openFind", arguments: [focusAllowed])
    }
}
