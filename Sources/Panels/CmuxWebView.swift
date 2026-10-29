import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

/// WKWebView tends to consume some Command-key equivalents (e.g. Cmd+N/Cmd+W),
/// preventing the app menu/SwiftUI Commands from receiving them. Route menu
/// key equivalents first so app-level shortcuts continue to work when WebKit is
/// the first responder.
final class CmuxWebView: WKWebView {
    // Some sites/WebKit paths report middle-click link activations as
    // WKNavigationAction.buttonNumber=4 instead of 2. Track a recent local
    // middle-click so navigation delegates can recover intent reliably.
    private struct MiddleClickIntent {
        let webViewID: ObjectIdentifier
        let uptime: TimeInterval
    }

    private static var lastMiddleClickIntent: MiddleClickIntent?
    private static let middleClickIntentMaxAge: TimeInterval = 0.8

    static func hasRecentMiddleClickIntent(for webView: WKWebView) -> Bool {
        guard let webView = webView as? CmuxWebView else { return false }
        guard let intent = lastMiddleClickIntent else { return false }

        let age = ProcessInfo.processInfo.systemUptime - intent.uptime
        if age > middleClickIntentMaxAge {
            lastMiddleClickIntent = nil
            return false
        }

        return intent.webViewID == ObjectIdentifier(webView)
    }

    private static func recordMiddleClickIntent(for webView: CmuxWebView) {
        lastMiddleClickIntent = MiddleClickIntent(
            webViewID: ObjectIdentifier(webView),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private final class ContextMenuFallbackBox: NSObject {
        weak var target: AnyObject?
        let action: Selector?

        init(target: AnyObject?, action: Selector?) {
            self.target = target
            self.action = action
        }
    }

    private static var contextMenuFallbackKey: UInt8 = 0

    var onContextMenuDownloadStateChanged: ((Bool) -> Void)?
    /// Called when "Open Link in New Tab" context menu is selected.
    /// Bypasses createWebViewWith so the link opens as a tab, not a popup.
    var onContextMenuOpenLinkInNewPanel: ((URL) -> Void)?
    var onShowSurfaceManifest: (() -> Void)?
    var contextMenuLinkURLProvider: ((CmuxWebView, NSPoint, @escaping (URL?) -> Void) -> Void)?
    var contextMenuDefaultBrowserOpener: ((URL) -> Bool)?
    /// Receives the http(s) downloads started from the context menu. The owning
    /// panel or popup sets it to the delegate its navigation downloads use.
    weak var contextMenuDownloadDelegate: WKDownloadDelegate?
    /// Picks where a data: or file: context-menu download is saved, calling
    /// back with nil on cancel. Tests replace the save panel with it.
    var contextMenuSaveDestinationProvider: ((_ suggestedName: String, _ completion: @escaping (URL?) -> Void) -> Void)?
    /// Guard against background panes stealing first responder (e.g. page autofocus).
    /// BrowserPanelView updates this as pane focus state changes.
    var allowsFirstResponderAcquisition: Bool = true
    private var pointerFocusAllowanceDepth: Int = 0
    var allowsFirstResponderAcquisitionEffective: Bool {
        allowsFirstResponderAcquisition || pointerFocusAllowanceDepth > 0
    }
    var debugPointerFocusAllowanceDepth: Int { pointerFocusAllowanceDepth }

    // MARK: - Load-issued tracking (C11-209)

    /// True once this web view instance has been asked to load *anything*.
    ///
    /// A `WKWebView` that has never been asked to load has no assigned web
    /// process, so `evaluateJavaScript`'s completion handler is never invoked
    /// at all — not late, never. Socket browser handlers run inside a
    /// `DispatchQueue.main.sync` drain (`v2BrowserWithPanel` → `v2MainSync`),
    /// so such an await burns its entire timeout holding the main queue, which
    /// freezes every other socket command and the UI with it. See
    /// `docs/c11-browser-await-main-wedge.md`.
    ///
    /// `webView.url == nil` is NOT a substitute predicate: a load issued to a
    /// dead port reports `url=nil, isLoading=false` and still evaluates
    /// JavaScript in ~50 ms, because a web process exists and JS runs against
    /// the current `about:blank` document. What matters is whether a load was
    /// ever *issued*, not whether one succeeded.
    ///
    /// Read it through `TerminalController`'s guard rather than directly; that
    /// guard treats a non-`CmuxWebView` as loaded, so the check can only ever
    /// avoid a wedge and never invent a failure.
    private(set) var hasIssuedLoad: Bool = false

    /// Marks a load as issued. Also called from `BrowserNavigationDelegate`'s
    /// `didStartProvisionalNavigation` so in-page and restored navigations that
    /// never pass through the `load*` overrides below are still covered.
    func markLoadIssued() {
        hasIssuedLoad = true
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        markLoadIssued()
        return super.load(request)
    }

    override func load(
        _ data: Data,
        mimeType MIMEType: String,
        characterEncodingName: String,
        baseURL: URL
    ) -> WKNavigation? {
        markLoadIssued()
        return super.load(data, mimeType: MIMEType, characterEncodingName: characterEncodingName, baseURL: baseURL)
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        markLoadIssued()
        // WebKit routes this through load(_:mimeType:characterEncodingName:baseURL:).
        // That Swift override has a nonoptional URL, so a nil HTML base traps
        // while bridging WebKit's Objective-C call. Use its blank-document base.
        return super.loadHTMLString(string, baseURL: baseURL ?? URL(string: "about:blank")!)
    }

    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        markLoadIssued()
        return super.loadFileURL(URL, allowingReadAccessTo: readAccessURL)
    }

    override func go(to item: WKBackForwardListItem) -> WKNavigation? {
        markLoadIssued()
        return super.go(to: item)
    }

    override func goBack() -> WKNavigation? {
        markLoadIssued()
        return super.goBack()
    }

    override func goForward() -> WKNavigation? {
        markLoadIssued()
        return super.goForward()
    }

    override func reload() -> WKNavigation? {
        markLoadIssued()
        return super.reload()
    }

    override func reloadFromOrigin() -> WKNavigation? {
        markLoadIssued()
        return super.reloadFromOrigin()
    }

    override func becomeFirstResponder() -> Bool {
        guard allowsFirstResponderAcquisitionEffective else {
#if DEBUG
            let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
            dlog(
                "browser.focus.blockedBecome web=\(ObjectIdentifier(self)) " +
                "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
            )
#endif
            return false
        }
        let result = super.becomeFirstResponder()
        if result {
            NotificationCenter.default.post(name: .browserDidBecomeFirstResponderWebView, object: self)
        }
#if DEBUG
        let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        dlog(
            "browser.focus.become web=\(ObjectIdentifier(self)) result=\(result ? 1 : 0) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
        )
#endif
        return result
    }

    /// Temporarily permits focus acquisition for explicit pointer-driven interactions
    /// (mouse click into this webview) while keeping background autofocus blocked.
    func withPointerFocusAllowance<T>(_ body: () -> T) -> T {
        pointerFocusAllowanceDepth += 1
#if DEBUG
        dlog(
            "browser.focus.pointerAllowance.enter web=\(ObjectIdentifier(self)) " +
            "depth=\(pointerFocusAllowanceDepth)"
        )
#endif
        defer {
            pointerFocusAllowanceDepth = max(0, pointerFocusAllowanceDepth - 1)
#if DEBUG
            dlog(
                "browser.focus.pointerAllowance.exit web=\(ObjectIdentifier(self)) " +
                "depth=\(pointerFocusAllowanceDepth)"
            )
#endif
        }
        return body()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.web.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
#endif
        if event.keyCode == 36 || event.keyCode == 76 {
            // Always bypass app/menu key-equivalent routing for Return/Enter so WebKit
            // receives the keyDown path used by form submission handlers.
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Menu/app shortcut routing is only needed for Command equivalents
        // (New Tab, Close Tab, tab switching, split commands, etc).
        guard flags.contains(.command) else {
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            handled = result
#endif
            return result
        }

        if !shouldRouteCommandEquivalentDirectlyToMainMenu(event) {
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            handled = result
#endif
            return result
        }

        // Let the app menu handle key equivalents first (New Tab, Close Tab, tab switching, etc).
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
#if DEBUG
            handled = true
#endif
            return true
        }

        // Handle app-level shortcuts that are not menu-backed (for example split commands).
        // Without this, WebKit can consume Cmd-based shortcuts before the app monitor sees them.
        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            handled = true
#endif
            return true
        }

        let result = super.performKeyEquivalent(with: event)
#if DEBUG
        handled = result
#endif
        return result
    }

    /// Set by the owning `BrowserPanel`: stamps the tab sheet's "touched" clock.
    /// A plain closure call that stores a `Date`; nothing is published.
    var onOperatorInput: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        onOperatorInput?()
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var route = "super"
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.web.keyDown",
                startedAt: typingTimingStart,
                event: event,
                extra: "route=\(route)"
            )
        }
#endif
        // Some Cmd-based key paths in WebKit don't consistently invoke performKeyEquivalent.
        // Route them through the same app-level shortcut handler as a fallback.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            route = "appShortcut"
#endif
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Focus on click

    // The SwiftUI Color.clear overlay (.onTapGesture) that focuses panes can't receive
    // clicks when a WKWebView is underneath — AppKit delivers the click to the deepest
    // NSView (WKWebView), not to sibling SwiftUI overlays. Notify the panel system so
    // bonsplit focus tracks which pane the user clicked in.
    override func mouseDown(with event: NSEvent) {
        onOperatorInput?()
#if DEBUG
        let windowNumber = window?.windowNumber ?? -1
        let firstResponderType = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "browser.focus.mouseDown web=\(ObjectIdentifier(self)) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) win=\(windowNumber) fr=\(firstResponderType)"
        )
#endif
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: self)
        withPointerFocusAllowance {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Mouse back/forward buttons

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            Self.recordMiddleClickIntent(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        dlog(
            "browser.mouse.otherDown web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        // Button 3 = back, button 4 = forward (multi-button mice like Logitech).
        // Consume the event so WebKit doesn't handle it.
        switch event.buttonNumber {
        case 3:
#if DEBUG
            dlog("browser.mouse.otherDown.action web=\(ObjectIdentifier(self)) kind=goBack canGoBack=\(canGoBack ? 1 : 0)")
#endif
            goBack()
            return
        case 4:
#if DEBUG
            dlog("browser.mouse.otherDown.action web=\(ObjectIdentifier(self)) kind=goForward canGoForward=\(canGoForward ? 1 : 0)")
#endif
            goForward()
            return
        default:
            break
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            Self.recordMiddleClickIntent(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        dlog(
            "browser.mouse.otherUp web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        super.otherMouseUp(with: event)
    }

    /// Converts a point in this view's coordinates to the CSS viewport point
    /// that `elementFromPoint` expects: origin at the top left, in CSS pixels.
    /// WKWebView is flipped, so its y already runs downward; page zoom scales
    /// CSS pixels to points. Assumes what browser panels set up today: no
    /// pinch magnification and no content insets.
    private func cssViewportPoint(forViewPoint point: NSPoint) -> CGPoint {
        let top = isFlipped ? point.y : bounds.height - point.y
        let zoom = pageZoom > 0 ? pageZoom : 1
        return CGPoint(x: point.x / zoom, y: top / zoom)
    }

    /// Finds the nearest anchor element at a given view-local point.
    /// Used as a context-menu download fallback.
    private func findLinkAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let cssPoint = cssViewportPoint(forViewPoint: point)
        let js = """
        (() => {
            let el = document.elementFromPoint(\(cssPoint.x), \(cssPoint.y));
            while (el) {
                if (el.tagName === 'A' && el.href) return el.href;
                el = el.parentElement;
            }
            return '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    // MARK: - Context menu download support

    /// The last context-menu point in view coordinates.
    private var lastContextMenuPoint: NSPoint = .zero
    /// The page the context menu opened on, when it was settled. `url` alone
    /// would already report a pending navigation while the previous document
    /// still answers the menu's JavaScript.
    private(set) var contextMenuPageURL: URL?
    /// Saved native WebKit action for "Download Image".
    private var fallbackDownloadImageTarget: AnyObject?
    private var fallbackDownloadImageAction: Selector?
    /// Saved native WebKit action for "Download Linked File".
    private var fallbackDownloadLinkedFileTarget: AnyObject?
    private var fallbackDownloadLinkedFileAction: Selector?

    private static func makeContextDownloadTraceID(prefix: String) -> String {
#if DEBUG
        return "\(prefix)-\(UUID().uuidString.prefix(8))"
#else
        return prefix
#endif
    }

    private func debugContextDownload(_ message: @autoclosure () -> String) {
#if DEBUG
        dlog(message())
#endif
    }

    private static func selectorName(_ selector: Selector?) -> String {
        guard let selector else { return "nil" }
        return NSStringFromSelector(selector)
    }

    private func debugLogContextMenuDownloadCandidate(_ item: NSMenuItem, index: Int) {
        let identifier = item.identifier?.rawValue ?? "nil"
        let title = item.title
        let actionName = Self.selectorName(item.action)
        let idToken = Self.normalizedContextMenuToken(identifier)
        let titleToken = Self.normalizedContextMenuToken(title)
        let actionToken = Self.normalizedContextMenuToken(actionName)
        guard idToken.contains("download")
            || titleToken.contains("download")
            || actionToken.contains("download") else {
            return
        }
        debugContextDownload(
            "browser.ctxdl.menu item index=\(index) id=\(identifier) title=\(title) action=\(actionName)"
        )
    }

    private struct ParsedDataURL {
        let data: Data
        let mimeType: String?
    }

    private static func parseDataURL(_ url: URL) -> ParsedDataURL? {
        let absolute = url.absoluteString
        guard absolute.hasPrefix("data:"),
              let commaIndex = absolute.firstIndex(of: ",") else {
            return nil
        }

        let headerStart = absolute.index(absolute.startIndex, offsetBy: 5)
        let header = String(absolute[headerStart..<commaIndex])
        let payloadStart = absolute.index(after: commaIndex)
        let payload = String(absolute[payloadStart...])

        let segments = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let mimeType = segments.first.flatMap { $0.isEmpty ? nil : $0 }
        let isBase64 = segments.dropFirst().contains { $0.caseInsensitiveCompare("base64") == .orderedSame }

        if isBase64 {
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            return ParsedDataURL(data: data, mimeType: mimeType)
        }

        guard let decoded = payload.removingPercentEncoding else { return nil }
        return ParsedDataURL(data: Data(decoded.utf8), mimeType: mimeType)
    }

    private static func filenameExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        if #available(macOS 11.0, *) {
            if let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension, !preferred.isEmpty {
                return preferred
            }
        }
        switch mimeType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "text/html":
            return "html"
        case "text/plain":
            return "txt"
        default:
            return nil
        }
    }

    private static func suggestedFilenameForDataURL(
        mimeType: String?,
        suggestedFilename: String?
    ) -> String {
        if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return suggested
        }
        let ext = filenameExtension(forMIMEType: mimeType) ?? "bin"
        let base = (mimeType?.lowercased().hasPrefix("image/") ?? false) ? "image" : "download"
        return "\(base).\(ext)"
    }

    private static func normalizedContextMenuToken(_ value: String?) -> String {
        guard let value else { return "" }
        let lowered = value.lowercased()
        let alphanumerics = CharacterSet.alphanumerics
        let scalars = lowered.unicodeScalars.filter { alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func isDownloadImageMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = Self.normalizedContextMenuToken(item.identifier?.rawValue)
        if identifier.contains("downloadimage") {
            return true
        }

        let title = Self.normalizedContextMenuToken(item.title)
        if title.contains("downloadimage") {
            return true
        }

        if let action = item.action {
            let actionName = Self.normalizedContextMenuToken(NSStringFromSelector(action))
            if actionName.contains("downloadimage") {
                return true
            }
        }

        return false
    }

    private func isDownloadLinkedFileMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = Self.normalizedContextMenuToken(item.identifier?.rawValue)
        if identifier.contains("downloadlinkedfile")
            || identifier.contains("downloadlinktodisk") {
            return true
        }

        let title = Self.normalizedContextMenuToken(item.title)
        if title.contains("downloadlinkedfile")
            || title.contains("downloadlinktodisk") {
            return true
        }

        if let action = item.action {
            let actionName = Self.normalizedContextMenuToken(NSStringFromSelector(action))
            if actionName.contains("downloadlinkedfile")
                || actionName.contains("downloadlinktodisk") {
                return true
            }
        }

        return false
    }

    private func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private func isDataURLScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data"
    }

    private func isDownloadSupportedScheme(_ url: URL) -> Bool {
        return isDownloadableScheme(url) || isDataURLScheme(url)
    }

    private func isOurDownloadMenuAction(target: AnyObject?, action: Selector?) -> Bool {
        guard target === self else { return false }
        return action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:))
    }

    private func resolveGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else { return nil }
        let map = Dictionary(
            queryItems.map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let decoded = raw.removingPercentEncoding ?? raw as String?,
                  let candidate = URL(string: decoded),
                  isDownloadableScheme(candidate) else {
                continue
            }
            return candidate
        }
        // Some links are wrapped as /url?...
        if comps.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key], let candidate = URL(string: raw), isDownloadableScheme(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    func normalizedLinkedDownloadURL(_ url: URL) -> URL {
        resolveGoogleRedirectURL(url) ?? url
    }

    private func isLikelyFaviconURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if lower.contains("favicon") { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("favicon")
    }

    private func isLikelyImageURL(_ url: URL) -> Bool {
        if isDataURLScheme(url) {
            guard let parsed = Self.parseDataURL(url),
                  let mime = parsed.mimeType?.lowercased() else {
                return false
            }
            return mime.hasPrefix("image/")
        }
        guard isDownloadableScheme(url) else { return false }
        let ext = url.pathExtension.lowercased()
        if [
            "jpg", "jpeg", "png", "webp", "gif", "bmp",
            "svg", "avif", "heic", "heif", "tif", "tiff", "ico"
        ].contains(ext) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        if lower.contains("imgurl=")
            || lower.contains("mediaurl=")
            || lower.contains("encrypted-tbn")
            || lower.contains("format=jpg")
            || lower.contains("format=jpeg")
            || lower.contains("format=png")
            || lower.contains("format=webp")
            || lower.contains("format=gif") {
            return true
        }
        return false
    }

    private func captureFallbackForMenuItemIfNeeded(_ item: NSMenuItem) {
        let target = item.target as AnyObject?
        let action = item.action
        if isOurDownloadMenuAction(target: target, action: action) {
            return
        }
        let box = ContextMenuFallbackBox(target: target, action: action)
        objc_setAssociatedObject(
            item,
            &Self.contextMenuFallbackKey,
            box,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func fallbackFromSender(
        _ sender: Any?,
        defaultAction: Selector?,
        defaultTarget: AnyObject?
    ) -> (action: Selector?, target: AnyObject?) {
        if let item = sender as? NSMenuItem,
           let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
            return (box.action, box.target)
        }
        return (defaultAction, defaultTarget)
    }

    /// JavaScript the context-menu resolvers share; it expects `x` and `y`,
    /// the CSS viewport point, in scope. A nested search only counts visible
    /// descendants under the point, topmost first, and never runs from
    /// <body> or <html>, whose children under the point are already in the
    /// hit stack. A frame's content is not in this document, so frame-like
    /// elements give no candidate and a frame on top ends the search;
    /// WebKit's own menu action hit-tests into frames (C11-504).
    private static let contextMenuHitTestPrelude = """
        const containsPoint = (node) => {
            if (!node || !node.getBoundingClientRect) return false;
            const r = node.getBoundingClientRect();
            return x >= r.left && x < r.right && y >= r.top && y < r.bottom;
        };
        const nestedUnderPoint = (el, selector) => {
            if (!el || !el.querySelectorAll || el === document.body || el === document.documentElement) return [];
            return Array.from(el.querySelectorAll(selector)).filter((n) => {
                if (!containsPoint(n)) return false;
                try { return window.getComputedStyle(n).visibility !== 'hidden'; } catch (_) { return true; }
            }).reverse();
        };
        const isFrameLike = (el) => !!el && ['IFRAME', 'FRAME', 'OBJECT', 'EMBED'].includes((el.tagName || '').toUpperCase());
        const examined = new Set();
        """

    /// Resolve the topmost image URL near a point, accounting for overlay layers.
    private func findImageURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let cssPoint = cssViewportPoint(forViewPoint: point)
        let js = """
        (() => {
            const x = \(cssPoint.x);
            const y = \(cssPoint.y);
            const normalize = (raw) => {
                if (!raw || typeof raw !== 'string') return '';
                const trimmed = raw.trim();
                if (!trimmed) return '';
                if (trimmed.startsWith('//')) return window.location.protocol + trimmed;
                return trimmed;
            };
            const firstSrcsetURL = (srcset) => {
                if (!srcset || typeof srcset !== 'string') return '';
                const first = srcset.split(',').map((part) => part.trim()).find(Boolean);
                if (!first) return '';
                const urlPart = first.split(/\\s+/)[0];
                return normalize(urlPart);
            };
            const firstBackgroundURL = (value) => {
                if (!value || value === 'none') return '';
                const match = /url\\((['"]?)(.*?)\\1\\)/.exec(value);
                if (!match || !match[2]) return '';
                return normalize(match[2]);
            };
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                const pushParents = (node) => {
                    while (node && !seen.has(node)) {
                        seen.add(node);
                        out.push(node);
                        node = node.parentElement;
                    }
                };
                pushParents(start);
                if (start && start.tagName === 'PICTURE' && start.querySelector) {
                    const img = start.querySelector('img');
                    if (img) pushParents(img);
                }
                return out;
            };
            \(Self.contextMenuHitTestPrelude)
            const candidateFromElement = (el) => {
                if (!el || isFrameLike(el)) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.tagName === 'IMG') {
                    const imageCandidates = [
                        normalize(el.currentSrc || ''),
                        attr('src'),
                        firstSrcsetURL(attr('srcset')),
                        attr('data-src'),
                        attr('data-iurl'),
                        attr('data-lazy-src'),
                        attr('data-original'),
                    ];
                    const foundImage = imageCandidates.find(Boolean);
                    if (foundImage) return foundImage;
                }
                const genericAttrs = [
                    'src', 'data-src', 'data-iurl', 'data-lazy-src',
                    'data-original', 'data-image', 'data-image-url',
                    'data-thumb', 'data-thumbnail-url', 'content'
                ];
                for (const name of genericAttrs) {
                    const v = attr(name);
                    if (v) return v;
                }
                const inlineBg = firstBackgroundURL(el.style && el.style.backgroundImage ? el.style.backgroundImage : '');
                if (inlineBg) return inlineBg;
                try {
                    const computed = window.getComputedStyle(el);
                    const computedBg = firstBackgroundURL(computed ? computed.backgroundImage : '');
                    if (computedBg) return computedBg;
                } catch (_) {}
                if (el.querySelectorAll) {
                    for (const nestedImg of nestedUnderPoint(el, 'img[src],img[srcset],img[data-src],img[data-iurl]')) {
                        const nestedCandidates = [
                            normalize(nestedImg.currentSrc || ''),
                            normalize(nestedImg.getAttribute ? nestedImg.getAttribute('src') : ''),
                            firstSrcsetURL(nestedImg.getAttribute ? nestedImg.getAttribute('srcset') : ''),
                            normalize(nestedImg.getAttribute ? (nestedImg.getAttribute('data-src') || nestedImg.getAttribute('data-iurl') || '') : '')
                        ];
                        const foundNested = nestedCandidates.find(Boolean);
                        if (foundNested) return foundNested;
                    }
                    for (const nestedBg of nestedUnderPoint(el, '[style*="background-image"]')) {
                        const styleValue = nestedBg.getAttribute ? nestedBg.getAttribute('style') : '';
                        const bgURL = firstBackgroundURL(styleValue || '');
                        if (bgURL) return bgURL;
                    }
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const el of collectChain(start)) {
                        if (examined.has(el)) continue;
                        examined.add(el);
                        const found = candidateFromElement(el);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const el of collectChain(inner)) {
                                const found = candidateFromElement(el);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const all = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            if (all.length && isFrameLike(all[0])) return '';
            const foundFromAll = tryNodes(all);
            if (foundFromAll) return foundFromAll;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return candidateFromElement(single) || '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let src = result as? String, !src.isEmpty,
                  let url = URL(string: src) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    /// Resolve the topmost link URL near a point, accounting for overlay layers.
    private func findLinkURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let cssPoint = cssViewportPoint(forViewPoint: point)
        let js = """
        (() => {
            const x = \(cssPoint.x);
            const y = \(cssPoint.y);
            const normalize = (raw) => {
                if (!raw || typeof raw !== 'string') return '';
                const trimmed = raw.trim();
                if (!trimmed) return '';
                if (trimmed.startsWith('//')) return window.location.protocol + trimmed;
                return trimmed;
            };
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                while (start && !seen.has(start)) {
                    seen.add(start);
                    out.push(start);
                    start = start.parentElement;
                }
                return out;
            };
            \(Self.contextMenuHitTestPrelude)
            const linkFromElement = (el) => {
                if (!el || isFrameLike(el)) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.closest) {
                    const closestLink = el.closest('a[href],area[href]');
                    if (closestLink && closestLink.href) return normalize(closestLink.href);
                }
                if ((el.tagName === 'A' || el.tagName === 'AREA') && el.href) {
                    return normalize(el.href);
                }
                const attrCandidates = ['href', 'data-href', 'data-url', 'data-link', 'data-link-url'];
                for (const name of attrCandidates) {
                    const v = attr(name);
                    if (v) return v;
                }
                for (const nestedLink of nestedUnderPoint(el, 'a[href]')) {
                    if (nestedLink.href) return normalize(nestedLink.href);
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const node of collectChain(start)) {
                        if (examined.has(node)) continue;
                        examined.add(node);
                        const found = linkFromElement(node);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const node of collectChain(inner)) {
                                const found = linkFromElement(node);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            if (nodes.length && isFrameLike(nodes[0])) return '';
            const found = tryNodes(nodes);
            if (found) return found;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return linkFromElement(single) || '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    private func debugInspectElementsAtPoint(_ point: NSPoint, traceID: String, kind: String) {
#if DEBUG
        let cssPoint = cssViewportPoint(forViewPoint: point)
        let js = """
        (() => {
            const clip = (value, max = 180) => {
                if (value == null) return '';
                const s = String(value);
                return s.length > max ? s.slice(0, max) + '…' : s;
            };
            const x = \(cssPoint.x);
            const y = \(cssPoint.y);
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const entries = [];
            const limit = Math.min(nodes.length, 8);
            for (let i = 0; i < limit; i++) {
                const el = nodes[i];
                if (!el) continue;
                entries.push({
                    tag: clip((el.tagName || '').toLowerCase()),
                    id: clip(el.id || ''),
                    cls: clip(typeof el.className === 'string' ? el.className : ''),
                    href: clip(el.href || ''),
                    src: clip(el.src || ''),
                    currentSrc: clip(el.currentSrc || ''),
                    dataHref: clip(el.getAttribute ? el.getAttribute('data-href') : ''),
                    dataSrc: clip(el.getAttribute ? el.getAttribute('data-src') : '')
                });
            }
            return JSON.stringify({count: nodes.length, entries});
        })();
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let payload = result as? String,
                  !payload.isEmpty else { return }
            self.debugContextDownload(
                "browser.ctxdl.inspect trace=\(traceID) kind=\(kind) payload=\(payload)"
            )
        }
#endif
    }

    private func resolveContextMenuLinkURL(at point: NSPoint, completion: @escaping (URL?) -> Void) {
        if let contextMenuLinkURLProvider {
            contextMenuLinkURLProvider(self, point, completion)
            return
        }
        findLinkURLAtPoint(point, completion: completion)
    }

    private func canOpenInDefaultBrowser(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    private func openContextMenuLinkInDefaultBrowser(_ url: URL) {
        if let contextMenuDefaultBrowserOpener {
            _ = contextMenuDefaultBrowserOpener(url)
            return
        }
        _ = NSWorkspace.shared.open(url)
    }

    private func runContextMenuFallback(
        action: Selector?,
        target: AnyObject?,
        sender: Any?,
        traceID: String? = nil,
        reason: String? = nil
    ) {
        let trace = traceID ?? "unknown"
        guard let action else {
            debugContextDownload(
                "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") action=nil target=\(String(describing: target))"
            )
            return
        }
        // Guard against accidental self-recursion if fallback gets overwritten.
        if target === self,
           action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:)) {
            debugContextDownload(
                "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") skipped=recursive action=\(Self.selectorName(action))"
            )
            return
        }
        let dispatched = NSApp.sendAction(action, to: target, from: sender)
        debugContextDownload(
            "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") dispatched=\(dispatched ? 1 : 0) action=\(Self.selectorName(action)) target=\(String(describing: target))"
        )
    }

    private func notifyContextMenuDownloadState(_ downloading: Bool) {
        if Thread.isMainThread {
            onContextMenuDownloadStateChanged?(downloading)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onContextMenuDownloadStateChanged?(downloading)
            }
        }
    }

    private func downloadContextMenuURL(
        _ url: URL,
        suggestedFilename: String?,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String,
        menuPageURL: URL?
    ) {
        guard isDownloadSupportedScheme(url) else {
            debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=rejectUnsupportedScheme url=\(url.absoluteString)"
            )
            runContextMenuFallback(
                action: fallbackAction,
                target: fallbackTarget,
                sender: sender,
                traceID: traceID,
                reason: "unsupported_scheme"
            )
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        debugContextDownload(
            "browser.ctxdl.request trace=\(traceID) stage=start scheme=\(scheme) url=\(url.absoluteString)"
        )

        if scheme == "http" || scheme == "https" {
            startWebKitContextMenuDownload(
                url,
                sender: sender,
                fallbackAction: fallbackAction,
                fallbackTarget: fallbackTarget,
                traceID: traceID
            )
            return
        }

        notifyContextMenuDownloadState(true)
        debugContextDownload("browser.ctxdl.state trace=\(traceID) downloading=1")

        if scheme == "data" {
            DispatchQueue.main.async {
                guard let parsed = Self.parseDataURL(url) else {
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.data trace=\(traceID) stage=parseFailure urlLength=\(url.absoluteString.count)"
                    )
                    self.runContextMenuFallback(
                        action: fallbackAction,
                        target: fallbackTarget,
                        sender: sender,
                        traceID: traceID,
                        reason: "data_url_parse_error"
                    )
                    return
                }

                let saveName = Self.suggestedFilenameForDataURL(
                    mimeType: parsed.mimeType,
                    suggestedFilename: suggestedFilename
                )
                self.debugContextDownload(
                    "browser.ctxdl.data trace=\(traceID) stage=parseSuccess mime=\(parsed.mimeType ?? "nil") bytes=\(parsed.data.count)"
                )

                self.notifyContextMenuDownloadState(false)
                self.debugContextDownload(
                    "browser.ctxdl.data trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                )
                self.chooseContextMenuSaveDestination(suggestedName: saveName) { destURL in
                    guard let destURL else {
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=savePrompt result=cancel"
                        )
                        return
                    }
                    do {
                        try parsed.data.write(to: destURL, options: .atomic)
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                        )
                    } catch {
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                        )
                        self.runContextMenuFallback(
                            action: fallbackAction,
                            target: fallbackTarget,
                            sender: sender,
                            traceID: traceID,
                            reason: "data_save_write_error"
                        )
                    }
                }
            }
            return
        }

        if scheme == "file" {
            // The page's own JavaScript resolved this URL, and WebKit never
            // lets a web page load a file: URL. Only a local page that was
            // settled when the menu opened may save a file, and only one
            // inside the folder WebKit lets that page read (C11-495).
            let indicator = onContextMenuDownloadStateChanged
            guard let pageURL = menuPageURL, pageURL.isFileURL,
                  !isLoading, self.url == pageURL else {
                indicator?(false)
                debugContextDownload(
                    "browser.ctxdl.file trace=\(traceID) stage=rejectPage menuPage=\(menuPageURL?.scheme ?? "nil") loading=\(isLoading ? 1 : 0)"
                )
                return
            }
            let filename = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let saveName = filename?.isEmpty == false
                ? filename!
                : (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
            // Path resolution, stat and copy stay off main: an automount, a
            // slow volume or a FIFO must not block the app.
            DispatchQueue.global(qos: .userInitiated).async {
                // realpath fails on a missing component instead of collapsing
                // `..` as text, so `missing/../link/x` cannot pass the folder
                // check while the kernel follows `link` elsewhere.
                let root = browserReadAccessURL(forLocalFileURL: pageURL).flatMap { Self.realPath($0.path) }
                let sourcePath = Self.realPath(url.path)
                let allowed = root != nil && sourcePath != nil
                    && Self.isPath(sourcePath!, inside: root!)
                    && Self.isRegularFile(atPath: sourcePath!)
                DispatchQueue.main.async {
                    indicator?(false)
                    guard allowed, let root, let sourcePath else {
                        self.debugContextDownload(
                            "browser.ctxdl.file trace=\(traceID) stage=rejectSource path=\(url.path)"
                        )
                        return
                    }
                    self.debugContextDownload(
                        "browser.ctxdl.file trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                    )
                    self.chooseContextMenuSaveDestination(suggestedName: saveName) { destURL in
                        guard let destURL else {
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=savePrompt result=cancel"
                            )
                            return
                        }
                        indicator?(true)
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome = Result {
                                try Self.copyRegularFile(atPath: sourcePath, inside: root, to: destURL)
                            }
                            DispatchQueue.main.async {
                                indicator?(false)
                                switch outcome {
                                case .success:
                                    self.debugContextDownload(
                                        "browser.ctxdl.file trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                                    )
                                case .failure(let error):
                                    NSLog("BrowserPanel context-menu save failed: %@", error.localizedDescription)
                                }
                            }
                        }
                    }
                }
            }
            return
        }
    }

    private func chooseContextMenuSaveDestination(
        suggestedName: String,
        completion: @escaping (URL?) -> Void
    ) {
        if let contextMenuSaveDestinationProvider {
            contextMenuSaveDestinationProvider(suggestedName, completion)
            return
        }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = suggestedName
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        savePanel.begin { result in
            completion(result == .OK ? savePanel.url : nil)
        }
    }

    /// Records the page the context menu opened on, for `file:` saves.
    func noteContextMenuOpened() {
        contextMenuPageURL = isLoading ? nil : url
    }

    /// The canonical path with every symlink resolved, or nil when any
    /// component is missing.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when canonical `path` lies inside canonical folder `root`, the
    /// folder WebKit lets the page read (`browserLoadRequest` grants it).
    private static func isPath(_ path: String, inside root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Checks the file type without opening it, so a FIFO or device is never
    /// opened.
    private static func isRegularFile(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Copies a regular file's bytes to the destination the operator chose,
    /// replacing a file there as the save panel already confirmed. The file
    /// is checked again through the descriptor that is copied, its type and
    /// the path it really opened, so a file swapped for a FIFO or a symlink
    /// out of `root` after the first check is refused.
    private static func copyRegularFile(atPath sourcePath: String, inside root: String, to destination: URL) throws {
        func posixError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard isRegularFile(atPath: sourcePath) else { throw POSIXError(.EFTYPE) }
        let source = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw posixError() }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EFTYPE) }
        var openedPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(source, F_GETPATH, &openedPath) != -1 else { throw posixError() }
        guard isPath(String(cString: openedPath), inside: root) else { throw POSIXError(.EPERM) }

        // A fixed-length name, so a long destination name stays under the
        // 255-byte limit. The copy keeps the source's permission bits.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".c11-\(UUID().uuidString).partial", isDirectory: false)
        let target = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, info.st_mode & 0o666)
        guard target >= 0 else { throw posixError() }
        var placed = false
        defer {
            if !placed { unlink(staged.path) }
        }
        let copied = fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_DATA))
        let copyError = posixError()
        // Network volumes can report a failed write only at close.
        let closed = close(target)
        let closeError = posixError()
        guard copied == 0 else { throw copyError }
        guard closed == 0 else { throw closeError }
        guard rename(staged.path, destination.path) == 0 else { throw posixError() }
        placed = true
    }

    /// Hands an http(s) context-menu download to WebKit. The page chose this
    /// URL, so the request must carry only the cookies WebKit itself would
    /// send to it: matched by domain, path, Secure and expiry, with the page
    /// as first party, and matched again on every redirect. Copying the jar
    /// into the request sent every site's cookies to the page's host (C11-487).
    private func startWebKitContextMenuDownload(
        _ url: URL,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        guard let downloadDelegate = contextMenuDownloadDelegate else {
            debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=noDownloadDelegate"
            )
            runContextMenuFallback(
                action: fallbackAction,
                target: fallbackTarget,
                sender: sender,
                traceID: traceID,
                reason: "no_download_delegate"
            )
            return
        }
        var request = URLRequest(url: url)
        if let referer = self.url?.absoluteString, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let ua = customUserAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        debugContextDownload(
            "browser.ctxdl.request trace=\(traceID) stage=dispatch via=webkit referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)"
        )
        // WKDownload holds its delegate weakly; the panel or popup owns it.
        // The delegate reports start, save and failure like any other
        // download in this panel.
        startDownload(using: request) { [weak self] download in
            download.delegate = downloadDelegate
            self?.debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=handedToWebKit"
            )
        }
    }

    /// `menuPageURL` is the page the menu opened on (`contextMenuPageURL` when
    /// the item was chosen); only a `file:` save reads it.
    func startContextMenuDownload(
        _ url: URL,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?,
        traceID: String,
        menuPageURL: URL? = nil
    ) {
        debugContextDownload("browser.ctxdl.start trace=\(traceID) url=\(url.absoluteString)")
        downloadContextMenuURL(
            url,
            suggestedFilename: nil,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget,
            traceID: traceID,
            menuPageURL: menuPageURL
        )
    }

    // MARK: - Drag-and-drop passthrough

    // WKWebView inherently calls registerForDraggedTypes with public.text (and others).
    // Bonsplit tab drags use NSString (public.utf8-plain-text) which conforms to public.text,
    // so AppKit's view-hierarchy-based drag routing delivers the session to WKWebView instead
    // of SwiftUI's sibling .onDrop overlays. Rejecting in draggingEntered doesn't help because
    // AppKit only bubbles up through superviews, not siblings.
    //
    // Fix: filter out text-based types that conflict with bonsplit tab drags, but keep
    // file URL types so Finder file drops and HTML drag-and-drop work.
    static func shouldRejectInternalPaneDrag(_ pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            || DragOverlayRoutingPolicy.hasSidebarWorkspaceReorder(pasteboardTypes)
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        let filtered = DragOverlayRoutingPolicy.webViewDragTypes(newTypes)
        if !filtered.isEmpty {
            super.registerForDraggedTypes(filtered)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return [] }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !Self.shouldRejectInternalPaneDrag(sender.draggingPasteboard.types) else { return false }
        return super.performDragOperation(sender)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        lastContextMenuPoint = convert(event.locationInWindow, from: nil)
        noteContextMenuOpened()
        debugContextDownload(
            "browser.ctxdl.menu open itemCount=\(menu.items.count) point=(\(Int(lastContextMenuPoint.x)),\(Int(lastContextMenuPoint.y)))"
        )
        var openLinkInsertionIndex: Int?
        var hasDefaultBrowserOpenLinkItem = false

        for (index, item) in menu.items.enumerated() {
            debugLogContextMenuDownloadCandidate(item, index: index)
            if !hasDefaultBrowserOpenLinkItem,
               (item.action == #selector(contextMenuOpenLinkInDefaultBrowser(_:))
                || item.title == String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser")) {
                hasDefaultBrowserOpenLinkItem = true
            }

            if openLinkInsertionIndex == nil,
               (item.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
                || item.title == "Open Link") {
                openLinkInsertionIndex = index + 1
            }

            // Retarget "Open Link in New Window" to open as a tab, not a popup.
            // Without this, WebKit's default action calls createWebViewWith with
            // navigationType .other, which our classifier would treat as a scripted
            // popup request.
            if item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                || item.title.contains("Open Link in New Window") {
                item.title = String(localized: "browser.contextMenu.openLinkInNewTab", defaultValue: "Open Link in New Panel")
                item.target = self
                item.action = #selector(contextMenuOpenLinkInNewPanel(_:))
            }

            if isDownloadImageMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=image index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadImageTarget = box.target
                    fallbackDownloadImageAction = box.action
                } else if !isOurDownloadMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadImageTarget = item.target as AnyObject?
                    fallbackDownloadImageAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadImage(_:))
            }

            if isDownloadLinkedFileMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=linked index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadLinkedFileTarget = box.target
                    fallbackDownloadLinkedFileAction = box.action
                } else if !isOurDownloadMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadLinkedFileTarget = item.target as AnyObject?
                    fallbackDownloadLinkedFileAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadLinkedFile(_:))
            }
        }

        if let openLinkInsertionIndex, !hasDefaultBrowserOpenLinkItem {
            let item = NSMenuItem(
                title: String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser"),
                action: #selector(contextMenuOpenLinkInDefaultBrowser(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.insertItem(item, at: min(openLinkInsertionIndex, menu.items.count))
        }

        if onShowSurfaceManifest != nil {
            menu.addItem(.separator())
            let manifestItem = NSMenuItem(
                title: String(
                    localized: "surfaceManifest.menuItem",
                    defaultValue: "Panel Details"
                ),
                action: #selector(contextMenuShowSurfaceManifest(_:)),
                keyEquivalent: ""
            )
            manifestItem.target = self
            menu.addItem(manifestItem)
        }
    }

    @objc private func contextMenuShowSurfaceManifest(_ sender: Any?) {
        _ = sender
        onShowSurfaceManifest?()
    }

    @objc private func contextMenuOpenLinkInDefaultBrowser(_ sender: Any?) {
        _ = sender
        let point = lastContextMenuPoint
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self, let url, self.canOpenInDefaultBrowser(url) else { return }
            self.openContextMenuLinkInDefaultBrowser(url)
        }
    }

    @objc private func contextMenuOpenLinkInNewPanel(_ sender: Any?) {
        let point = lastContextMenuPoint
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self, let url else { return }
            self.onContextMenuOpenLinkInNewPanel?(url)
        }
    }

    @objc private func contextMenuDownloadImage(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "img")
        // The page this menu opened on, read now: a later menu replaces it.
        let menuPageURL = contextMenuPageURL
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=image point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadImageAction,
            defaultTarget: fallbackDownloadImageTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findImageURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=image imageURL=\(url?.absoluteString ?? "nil")"
            )
            var dataImageURL: URL?
            var weakImageURL: URL?
            if let url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "data" {
                    dataImageURL = url
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image dataURLDetected length=\(url.absoluteString.count)"
                    )
                } else if scheme == "http" || scheme == "https" || scheme == "file" {
                    let normalized = self.normalizedLinkedDownloadURL(url)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                    )
                    if self.isLikelyImageURL(normalized) {
                        if !self.isLikelyFaviconURL(normalized) {
                            self.startContextMenuDownload(
                                normalized,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID,
                                menuPageURL: menuPageURL
                            )
                            return
                        }
                        weakImageURL = normalized
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=favicon_or_low_confidence"
                        )
                    } else if self.isDownloadableScheme(normalized), !self.isLikelyFaviconURL(normalized) {
                        // Some image CDNs use extensionless URLs; keep as last-resort candidate.
                        weakImageURL = normalized
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=unclassified_direct_image_src"
                        )
                    }
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                    )
                }
            }

            // Google Images and similar sites often expose blob:/data: image URLs.
            // If image URL is not directly downloadable, fall back to the nearby link URL.
            self.findLinkURLAtPoint(point) { linkURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackLinkURL=\(linkURL?.absoluteString ?? "nil")"
                )
                if let linkURL {
                    let normalizedLink = self.normalizedLinkedDownloadURL(linkURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedFallbackLinkURL=\(normalizedLink.absoluteString)"
                    )
                    if self.isDownloadableScheme(normalizedLink),
                       self.isLikelyImageURL(normalizedLink),
                       !self.isLikelyFaviconURL(normalizedLink) {
                        self.startContextMenuDownload(
                            normalizedLink,
                            sender: sender,
                            fallbackAction: fallback.action,
                            fallbackTarget: fallback.target,
                            traceID: traceID,
                            menuPageURL: menuPageURL
                        )
                        return
                    }
                }

                if let dataImageURL {
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToDataURL=1"
                    )
                    self.startContextMenuDownload(
                        dataImageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID,
                        menuPageURL: menuPageURL
                    )
                    return
                }

                if let weakImageURL {
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToWeakCandidate=1"
                    )
                    self.startContextMenuDownload(
                        weakImageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID,
                        menuPageURL: menuPageURL
                    )
                    return
                }

                if let linkURL {
                    self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender,
                        traceID: traceID,
                        reason: "fallback_link_not_image"
                    )
                    return
                }

                self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "no_image_or_link_url"
                )
            }
        }
    }

    @objc private func contextMenuDownloadLinkedFile(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "lnk")
        // The page this menu opened on, read now: a later menu replaces it.
        let menuPageURL = contextMenuPageURL
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=linked point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadLinkedFileAction,
            defaultTarget: fallbackDownloadLinkedFileTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findLinkURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=linked linkURL=\(url?.absoluteString ?? "nil")"
            )
            if let url {
                let normalized = self.normalizedLinkedDownloadURL(url)
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedLinkURL=\(normalized.absoluteString)"
                )
                if self.isDownloadSupportedScheme(normalized) {
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID,
                        menuPageURL: menuPageURL
                    )
                    return
                }
            }

            // Fallback 1: image URL under cursor (useful on image-heavy result pages).
            self.findImageURLAtPoint(point) { imageURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackImageURL=\(imageURL?.absoluteString ?? "nil")"
                )
                var dataImageURL: URL?
                if let imageURL, self.isDownloadableScheme(imageURL) {
                    self.startContextMenuDownload(
                        imageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID,
                        menuPageURL: menuPageURL
                    )
                    return
                }
                if let imageURL, self.isDataURLScheme(imageURL) {
                    dataImageURL = imageURL
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackDataURLDetected length=\(imageURL.absoluteString.count)"
                    )
                }

                // Fallback 2: simpler nearest-anchor lookup.
                self.findLinkAtPoint(point) { fallbackURL in
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked nearestAnchorURL=\(fallbackURL?.absoluteString ?? "nil")"
                    )
                    guard let fallbackURL else {
                        if let dataImageURL {
                            self.debugContextDownload(
                                "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                            )
                            self.startContextMenuDownload(
                                dataImageURL,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID,
                                menuPageURL: menuPageURL
                            )
                            return
                        }
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: "no_link_or_image_url"
                        )
                        return
                    }
                    let normalized = self.normalizedLinkedDownloadURL(fallbackURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedNearestAnchorURL=\(normalized.absoluteString)"
                    )
                    guard self.isDownloadSupportedScheme(normalized) else {
                        if let dataImageURL {
                            self.debugContextDownload(
                                "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                            )
                            self.startContextMenuDownload(
                                dataImageURL,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID,
                                menuPageURL: menuPageURL
                            )
                            return
                        }
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: "nearest_anchor_unsupported_scheme"
                        )
                        return
                    }
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID,
                        menuPageURL: menuPageURL
                    )
                }
            }
        }
    }
}
