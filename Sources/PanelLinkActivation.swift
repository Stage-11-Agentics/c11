import AppKit
import Bonsplit
import WebKit
import OSLog

enum PanelLinkTarget: Equatable {
    case panel(UUID)
    case workspace(UUID)

    static func isLink(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("c11:")
    }

    init?(_ text: String) {
        // Parse the wire spelling, not a normalized URL path: escaped path
        // components, shorthand refs, extra segments and authority decorations
        // are not aliases for a native target.
        guard text.utf8.count <= 128,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "c11",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased(),
              components.percentEncodedPath == components.path,
              components.path.count == 37, components.path.first == "/",
              let id = UUID(uuidString: String(components.path.dropFirst())),
              text.lowercased() == "c11://\(host)/\(id.uuidString.lowercased())" else { return nil }
        switch host {
        case "panel": self = .panel(id)
        case "workspace": self = .workspace(id)
        default: return nil
        }
    }
}

enum PanelLinkNotice {
    case invalid, unavailable, localOnly, activation

    var text: String {
        switch self {
        case .invalid:
            return String(localized: "panelLink.notice.invalid", defaultValue: "That c11 link is invalid. Use a panel or workspace UUID.")
        case .unavailable:
            return String(localized: "panelLink.notice.unavailable", defaultValue: "That panel or workspace is no longer available.")
        case .localOnly:
            return String(localized: "panelLink.notice.localOnly", defaultValue: "Panel links work only from local files and localhost pages.")
        case .activation:
            return String(localized: "panelLink.notice.activation", defaultValue: "Open c11 links by clicking them or pressing Return in a local page.")
        }
    }
}

enum PanelLinkOriginPolicy {
    static func allows(scheme: String, host: String, isMainFrame: Bool) -> Bool {
        guard isMainFrame else { return false }
        switch scheme.lowercased() {
        case "file": return true
        case "http", "https":
            return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        default: return false
        }
    }
}

/// One native input can match one trusted link event in this web view. The
/// isolated-world listener supplies the exact link; a recent input alone is
/// never authority to navigate.
struct PanelLinkNativeIntent {
    enum Kind: String { case pointer, keyboard }
    let kind: Kind
    let uptime: TimeInterval
    let point: CGPoint?

    func matches(kind: Kind, point: CGPoint?, now: TimeInterval) -> Bool {
        guard self.kind == kind, now >= uptime, now - uptime <= 1 else { return false }
        if kind == .pointer {
            guard let expected = self.point, let point else { return false }
            return abs(expected.x - point.x) <= 2 && abs(expected.y - point.y) <= 2
        }
        return true
    }
}

/// This handler exists only in its own content world. Browser automation runs
/// in .page and cannot invoke it or replace its Event/Element prototypes.
@MainActor
final class PanelLinkActivation: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "c11.panel-links")
    static let handlerName = "c11PanelLink"
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "panel_link")
    private weak var webView: WKWebView?
    private var nativeIntent: PanelLinkNativeIntent?
    private var nativeDocumentURL: URL?
    private var noticeView: NSView?
    /// Only the bundled markdown renderer sets this, never browser content.
    private let isMarkdownRenderer: Bool

    static func installScript(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: world
        ))
    }

    init(webView: WKWebView, isMarkdownRenderer: Bool = false) {
        self.webView = webView
        self.isMarkdownRenderer = isMarkdownRenderer
        super.init()
        webView.configuration.userContentController.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func record(_ event: NSEvent) {
        nativeIntent = nil
        guard let webView, !webView.isLoading, SocketCommandContext.current == nil else { return }
        nativeDocumentURL = webView.url
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return }
        switch event.type {
        case .leftMouseUp:
            let p = webView.convert(event.locationInWindow, from: nil)
            let zoom = webView.pageZoom > 0 ? webView.pageZoom : 1
            let point = CGPoint(x: p.x / zoom, y: (webView.isFlipped ? p.y : webView.bounds.height - p.y) / zoom)
            nativeIntent = PanelLinkNativeIntent(kind: .pointer, uptime: ProcessInfo.processInfo.systemUptime, point: point)
        case .keyDown where event.keyCode == 36 || event.keyCode == 76:
            nativeIntent = PanelLinkNativeIntent(kind: .keyboard, uptime: ProcessInfo.processInfo.systemUptime, point: nil)
        default: break
        }
    }

    func invalidate() {
        nativeIntent = nil
        nativeDocumentURL = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let intent = nativeIntent
        nativeIntent = nil
        guard let webView, message.webView === webView,
              let body = message.body as? [String: Any],
              let href = body["href"] as? String, href.utf8.count <= 16 * 1024 else { return }
        let origin = message.frameInfo.securityOrigin
        let source = "\(origin.protocol)://\(origin.host):\(origin.port)"
        guard message.frameInfo.isMainFrame,
              SocketCommandContext.current == nil,
              webView.window?.isKeyWindow == true, !webView.isHiddenOrHasHiddenAncestor,
              nativeDocumentURL == webView.url, message.frameInfo.request.url == webView.url,
              body["trusted"] as? Bool == true,
              body["supported"] as? Bool == true,
              let kindValue = body["kind"] as? String,
              let kind = PanelLinkNativeIntent.Kind(rawValue: kindValue),
              let intent,
              intent.matches(kind: kind, point: (body["x"] as? Double).flatMap { x in
                  (body["y"] as? Double).map { CGPoint(x: x, y: $0) }
              }, now: ProcessInfo.processInfo.systemUptime) else {
            Self.log(target: href, origin: source, activation: "refused", result: "unpaired")
            return
        }
        let activation = "native_\(kind.rawValue)"
        let allowed = isMarkdownRenderer
            ? webView.url == MarkdownAssetPolicy.entryURL
            : PanelLinkOriginPolicy.allows(scheme: origin.protocol, host: origin.host, isMainFrame: true)
        guard allowed else {
            showNotice(.localOnly)
            Self.log(target: href, origin: source, activation: activation, result: "origin_refused")
            return
        }
        guard let target = PanelLinkTarget(href) else {
            showNotice(.invalid)
            Self.log(target: href, origin: source, activation: activation, result: "invalid_target")
            return
        }
        let opened = AppDelegate.shared?.openPanelLink(target) == true
        if !opened { showNotice(.unavailable) }
        Self.log(target: href, origin: source, activation: activation, result: opened ? "opened" : "unavailable")
    }

    func showNotice(_ notice: PanelLinkNotice) {
        guard let webView else { return }
        noticeView?.removeFromSuperview()
        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        let label = NSTextField(wrappingLabelWithString: notice.text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.setAccessibilityIdentifier("c11.panel-link.notice")
        card.addSubview(label)
        webView.addSubview(card, positioned: .above, relativeTo: nil)
        card.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: webView.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: webView.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: webView.topAnchor, constant: 12),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        noticeView = card
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak card] in
            guard let self, let card, self.noticeView === card else { return }
            card.removeFromSuperview()
            self.noticeView = nil
        }
    }

    static func log(target: String, origin: String, activation: String, result: String) {
        // JSON string encoding keeps hostile URLs on one structured log line.
        let data = try? JSONSerialization.data(withJSONObject: [
            "target": String(target.prefix(1024)), "origin": origin,
            "activation": activation, "result": result
        ], options: [.sortedKeys])
        let line = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        logger.info("panel_link \(line, privacy: .public)")
        #if DEBUG
        dlog("panel_link \(line)")
        #endif
    }

    private static let script = #"""
    (() => {
      const activate = event => {
        const keyboard = event.type === 'keydown';
        if (keyboard && (event.key !== 'Enter' || event.repeat)) return;
        const anchor = event.composedPath().find(node => node instanceof Element && node.matches('a[href]'));
        if (!anchor) return;
        const href = anchor.getAttribute('href') || '';
        if (!/^\s*c11:/i.test(href)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        // This value is read from the isolated world's native Event prototype,
        // never a page-world property or an assertion supplied by page code.
        const target = (anchor.getAttribute('target') || '').toLowerCase();
        window.webkit.messageHandlers.c11PanelLink.postMessage({
          href, trusted: event.isTrusted, kind: keyboard || event.detail === 0 ? 'keyboard' : 'pointer',
          x: event.clientX, y: event.clientY,
          supported: (keyboard || event.button === 0) && !event.metaKey && !event.ctrlKey &&
            !event.altKey && !event.shiftKey && (!target || target === '_self')
        });
      };
      window.addEventListener('click', activate, true);
      window.addEventListener('auxclick', activate, true);
      window.addEventListener('keydown', activate, true);
    })();
    """#
}
