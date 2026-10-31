import AppKit
import Bonsplit
import WebKit
import OSLog

enum PanelLinkTarget: Equatable {
    case panel(UUID)
    case workspace(UUID)

    static func isLink(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("c11://")
    }

    static func usesScheme(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "c11"
    }

    /// Consume malformed scheme URLs too: Foundation may reject their spelling,
    /// but they must never fall through to Ghostty's external opener.
    static func usesScheme(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), usesScheme(url) { return true }
        return text.prefix(4).lowercased() == "c11:"
    }

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case invalid, unavailable, localOnly, activation, terminalActivation

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
        case .terminalActivation:
            return String(localized: "panelLink.notice.terminalActivation", defaultValue: "Command-click a c11 link to open its panel or workspace.")
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
        refusalReason(kind: kind, point: point, now: now) == nil
    }

    func refusalReason(kind: Kind, point: CGPoint?, now: TimeInterval) -> String? {
        guard self.kind == kind else { return "input_kind_mismatch" }
        guard now >= uptime, now - uptime <= 1 else { return "input_expired" }
        if kind == .pointer {
            guard let expected = self.point, let point else { return "input_point_missing" }
            guard abs(expected.x - point.x) <= 2 && abs(expected.y - point.y) <= 2 else { return "input_point_mismatch" }
        }
        return nil
    }
}

struct PanelLinkActivationPolicy {
    var trusted: Bool
    var supported: Bool
    var isMainFrame: Bool
    var isSocketCommand: Bool
    var isKeyWindow: Bool
    var isVisible: Bool
    var sameDocument: Bool

    func refusalReason(kind: PanelLinkNativeIntent.Kind?, intent: PanelLinkNativeIntent?, point: CGPoint?, now: TimeInterval) -> String? {
        guard trusted else { return "untrusted_event" }
        guard isMainFrame else { return "subframe" }
        guard !isSocketCommand else { return "socket_command" }
        guard isKeyWindow else { return "window_not_key" }
        guard isVisible else { return "view_hidden" }
        guard sameDocument else { return "document_changed" }
        guard supported else { return "unsupported_activation" }
        guard let kind else { return "invalid_activation_kind" }
        guard let intent else { return "missing_native_input" }
        return intent.refusalReason(kind: kind, point: point, now: now)
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
    private let noticePresenter = PanelLinkNoticePresenter()
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
        guard event.type == .leftMouseUp ||
                (event.type == .keyDown && (event.keyCode == 36 || event.keyCode == 76)) else { return }
        guard let webView, SocketCommandContext.current == nil else { return }
        nativeDocumentURL = webView.url
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return }
        switch event.type {
        case .leftMouseUp:
            // Like cssViewportPoint, this assumes no content insets or pinch magnification.
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
        guard let webView, message.webView === webView,
              let body = message.body as? [String: Any],
              let href = body["href"] as? String, href.utf8.count <= 16 * 1024 else { return }
        let origin = message.frameInfo.securityOrigin
        let source = "\(origin.protocol)://\(origin.host):\(origin.port)"
        let policy = PanelLinkActivationPolicy(
            trusted: body["trusted"] as? Bool == true,
            supported: body["supported"] as? Bool == true,
            isMainFrame: message.frameInfo.isMainFrame,
            isSocketCommand: SocketCommandContext.current != nil,
            isKeyWindow: webView.window?.isKeyWindow == true,
            isVisible: !webView.isHiddenOrHasHiddenAncestor,
            sameDocument: nativeDocumentURL == webView.url && message.frameInfo.request.url == webView.url
        )
        let intent = nativeIntent
        // A page-world synthetic click must not consume a real input in flight.
        if policy.trusted { nativeIntent = nil }
        let kind = (body["kind"] as? String).flatMap(PanelLinkNativeIntent.Kind.init(rawValue:))
        let point = (body["x"] as? Double).flatMap { x in
            (body["y"] as? Double).map { CGPoint(x: x, y: $0) }
        }
        if let reason = policy.refusalReason(kind: kind, intent: intent, point: point, now: ProcessInfo.processInfo.systemUptime) {
            if policy.trusted { showNotice(.activation) }
            Self.log(target: href, origin: source, activation: "refused", result: reason)
            return
        }
        guard let kind else { return } // The policy above requires a recognized kind.
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
        noticePresenter.show(notice, in: webView)
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
        if (!/^\s*c11:\/\//i.test(href)) return;
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

/// One non-modal notice implementation for web and portal-hosted terminals.
@MainActor
final class PanelLinkNoticePresenter {
    private var noticeView: NSView?

    func show(_ notice: PanelLinkNotice, in host: NSView) {
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
        host.addSubview(card, positioned: .above, relativeTo: nil)
        card.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
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

}

struct TerminalPanelLinkPolicy {
    var isNativeCommandClick: Bool
    var isSocketCommand: Bool
    var isKeyWindow: Bool
    var isVisible: Bool

    var refusalReason: String? {
        if isSocketCommand { return "socket_command" }
        if !isNativeCommandClick { return "missing_native_input" }
        if !isKeyWindow { return "window_not_key" }
        if !isVisible { return "view_hidden" }
        return nil
    }
}

/// A portal-layer preview that never intercepts terminal mouse events. The OSC
/// 8 label is untrusted and intentionally absent: titles come from live state.
@MainActor
final class TerminalPanelLinkPreview {
    private final class Card: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private var card: NSView?
    private var displayedText: String?

    func clear() {
        card?.removeFromSuperview()
        card = nil
        displayedText = nil
    }

    func show(_ href: String, in host: NSView) {
        guard PanelLinkTarget.usesScheme(href) else { clear(); return }
        let text = destinationText(href)
        guard text != displayedText || card?.superview !== host else { return }
        clear()
        let card = Card()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        // Reserve one line for each destination component so a long panel
        // title cannot push the workspace or canonical URL out of the card.
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        for line in text.split(separator: "\n") {
            let label = NSTextField(labelWithString: String(line))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
            rows.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.staticText)
        card.setAccessibilityValue(text)
        card.setAccessibilityIdentifier("c11.panel-link.preview")
        card.addSubview(rows)
        host.addSubview(card, positioned: .above, relativeTo: nil)
        card.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 480)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
            preferredWidth,
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        self.card = card
        displayedText = text
    }

    private func destinationText(_ href: String) -> String {
        let wireText = PanelLinkFormat.sanitizedTitle(href)
        guard let target = PanelLinkTarget(href) else { return "\(PanelLinkNotice.invalid.text)\n\(wireText)" }
        let workspace: Workspace?
        let panelID: UUID?
        switch target {
        case .panel(let id):
            workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: id)?.workspace
            panelID = id
        case .workspace(let id):
            workspace = AppDelegate.shared?.workspaceManagerFor(workspaceId: id)?.workspaces.first { $0.id == id }
            panelID = nil
        }
        guard let workspace else { return "\(PanelLinkNotice.unavailable.text)\n\(wireText)" }
        let workspaceTitle = PanelLinkFormat.sanitizedTitle(workspace.customTitle ?? workspace.title)
        let workspaceLine = String(localized: "panelLink.preview.workspace", defaultValue: "Workspace: \(workspaceTitle)")
        if let panelID {
            let title = PanelLinkFormat.sanitizedTitle(workspace.panelTitle(panelId: panelID) ?? "")
            let panelLine = String(localized: "panelLink.preview.panel", defaultValue: "Panel: \(title)")
            return "\(panelLine)\n\(workspaceLine)\n\(PanelLinkFormat.url(kind: .panel, id: panelID))"
        }
        return "\(workspaceLine)\n\(PanelLinkFormat.url(kind: .workspace, id: workspace.id))"
    }
}
