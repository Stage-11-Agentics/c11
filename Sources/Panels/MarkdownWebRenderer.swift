import AppKit
import Combine
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
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                                         textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           ["=", "+", "-", "0"].contains(event.charactersIgnoringModifiers ?? "") {
            return false // AppDelegate's focused-markdown zoom path owns these keys.
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class MarkdownWebRenderer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// Shared process resources, separate controllers/handlers per document.
    private static let processPool = WKProcessPool()
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    let webView: MarkdownWKWebView
    @Published private(set) var state: [String: Any] = [:]
    @Published private(set) var failure: Bool = false
    private weak var panel: MarkdownPanel?
    private var ready = false
    private var entryNavigationAdmitted = false
    private var closed = false
    private var loadedContent: String?
    private var loadedSettings: [String: String] = [:]
    private var revision = 0

    init(panel: MarkdownPanel) {
        self.panel = panel
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
        webView.callAsyncJavaScript(
            "return await window.c11md[method](...args)",
            arguments: ["method": method, "args": arguments], in: nil, in: .page
        ) { result in completion?(result) }
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
        case "state":
            if let value = body["state"] as? [String: Any] { state = value }
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
            if optionHeld || !BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser()
                || BrowserLinkOpenSettings.shouldOpenExternally(url)
                || !BrowserLinkOpenSettings.hostMatchesWhitelist(url.host ?? "") {
                NSWorkspace.shared.open(url)
            } else if let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: panel.id, preferredWorkspaceId: panel.workspaceId)?.workspace,
                      let pane = workspace.preferredBrowserTargetPane(fromPanelId: panel.id) ?? workspace.paneId(forPanelId: panel.id) {
                _ = workspace.newBrowserSurface(inPane: pane, url: url, focus: true)
            }
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
        ready = false
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
