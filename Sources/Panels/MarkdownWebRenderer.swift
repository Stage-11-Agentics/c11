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
    private var pointerFocus = false
    private var retainedViewport: NSSize?

    /// SwiftUI zeroes a dismantled host. Keep a hidden reader at its last
    /// mounted size so later visible() capture uses the operator's geometry.
    func setViewportVisible(_ visible: Bool) {
        if visible { retainedViewport = nil }
        else if frame.width > 0, frame.height > 0 { retainedViewport = frame.size }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(retainedViewport ?? newSize)
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            var rect = newValue
            if let retainedViewport { rect.size = retainedViewport }
            super.frame = rect
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

@MainActor
final class MarkdownWebRenderer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// Shared process resources, separate controllers/handlers per document.
    private static let processPool = WKProcessPool()
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    let webView: MarkdownWKWebView
    @Published private(set) var state: [String: Any] = [:]
    @Published private(set) var failure: Bool = false {
        didSet { if failure { MarkdownRendererCache.shared.reconsider() } }
    }
    @Published private(set) var renderedRevision: Int?
    private weak var panel: MarkdownPanel?
    private var ready = false
    private var entryNavigationAdmitted = false
    private var closed = false
    private var loadedContent: String?
    private var loadedSettings: [String: String] = [:]
    private var revision = 0
    private var pendingRestorePosition: MarkdownReadingPosition?
    private var activeQueries = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime
    var hasQueriesInFlight: Bool { activeQueries > 0 }
    var canCaptureReadingPosition: Bool { ready || failure }
    private var recoveringAfterTermination = false

    init(panel: MarkdownPanel) {
        self.panel = panel
        pendingRestorePosition = panel.readingPosition
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
        webView = MarkdownWKWebView(frame: .zero, configuration: config)
        super.init()
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
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "c11md")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
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

    private func finishRender(_ revision: Int) {
        guard !closed, revision == self.revision else { return }
        renderedRevision = revision
#if DEBUG
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        dlog("markdown.renderer.ready panel=\(panel?.id.uuidString ?? "unknown") elapsedMs=\(String(format: "%.3f", elapsed))")
#endif
    }

    private func restoreReadingPosition(_ position: MarkdownReadingPosition, revision: Int) {
        call("setSourceMode", arguments: [position.sourceMode]) { [weak self] _ in
            guard let self, !self.closed else { return }
            let scroll = {
                self.call("scrollToLine", arguments: [position.line, position.offset]) { [weak self] result in
#if DEBUG
                    if case .success(let value) = result, let state = value as? [String: Any],
                       let actual = MarkdownReadingPosition(state: state), let self {
                        dlog("markdown.renderer.restored panel=\(self.panel?.id.uuidString ?? "unknown") line=\(actual.line) offset=\(actual.offset) width=\(self.webView.frame.width) height=\(self.webView.frame.height)")
                    }
#endif
                    self?.finishRender(revision)
                }
            }
            if position.findQuery.isEmpty { scroll() }
            else { self.call("find", arguments: [position.findQuery]) { _ in scroll() } }
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
                                             "strings": Self.localizedStrings]])
        }
        if loadedContent != panel.content {
            loadedContent = panel.content
            revision += 1
            call("load", arguments: [["markdown": panel.content, "documentPath": panel.filePath ?? "",
                                      "baseURL": panel.filePath.map { URL(fileURLWithPath: $0).absoluteString } ?? "",
                                      "revision": revision]])
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
            synchronize()
            MarkdownRendererCache.shared.reconsider()
        case "state":
            if let value = body["state"] as? [String: Any] { state = value }
        case "error":
            if body["code"] as? String == "render_failed" { failure = true }
        case "rendered":
            recoveringAfterTermination = false
            if let value = body["revision"] as? Int {
                if let position = pendingRestorePosition {
                    pendingRestorePosition = nil
                    restoreReadingPosition(position, revision: value)
                } else { finishRender(value) }
            }
        case "link":
            if let href = body["href"] as? String, href.utf8.count <= 16 * 1024 {
                routeLink(href, optionHeld: (body["modifiers"] as? [String: Bool])?["alt"] == true)
            }
        case "copy":
            guard let text = body["text"] as? String, text.utf8.count <= 1024 * 1024 else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default: break
        }
    }

    private func routeLink(_ href: String, optionHeld: Bool) {
        guard let panel, let filePath = panel.filePath else { return }
        switch MarkdownLinkTarget.resolve(href, documentPath: filePath) {
        case .anchor, .blocked: return
        case .markdown(let url):
            guard let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: panel.id, preferredWorkspaceId: panel.workspaceId)?.workspace,
                  let pane = workspace.paneId(forPanelId: panel.id) else { return }
            _ = workspace.newMarkdownPanel(inPane: pane, filePath: url.path, focus: true)
        case .web(let url):
            openC11WebLink(url, sourceWorkspaceId: panel.workspaceId, sourcePanelId: panel.id, optionHeld: optionHeld)
        }
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
        "frontmatter": String(localized: "markdown.reader.frontmatter", defaultValue: "Frontmatter")
    ] }
}
