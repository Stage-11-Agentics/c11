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
    case invalid, unavailable, destinationChanged, localOnly, activation, terminalActivation

    var text: String {
        switch self {
        case .invalid:
            return String(localized: "panelLink.notice.invalid", defaultValue: "That c11 link is invalid. Use a panel or workspace UUID.")
        case .unavailable:
            return String(localized: "panelLink.notice.unavailable", defaultValue: "That panel or workspace is no longer available.")
        case .destinationChanged:
            return String(localized: "panelLink.notice.destinationChanged", defaultValue: "That destination moved to another workspace. Click the link again to confirm it.")
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
        show(text: notice.text, in: host)
    }

    func show(text: String, in host: NSView) {
        noticeView?.removeFromSuperview()
        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        let label = NSTextField(wrappingLabelWithString: text)
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
            let title = PanelLinkFormat(kind: .panel, id: panelID,
                                       title: workspace.panelTitle(panelId: panelID) ?? "").title
            let panelLine = String(localized: "panelLink.preview.panel", defaultValue: "Panel: \(title)")
            return "\(panelLine)\n\(workspaceLine)\n\(PanelLinkFormat.url(kind: .panel, id: panelID))"
        }
        return "\(workspaceLine)\n\(PanelLinkFormat.url(kind: .workspace, id: workspace.id))"
    }
}

/// The identity shown to the operator, resolved from live native state only.
struct ExternalPanelLinkDestination: Equatable {
    let target: PanelLinkTarget
    let workspaceID: UUID
    let workspaceTitle: String
    let panelTitle: String?

    var url: String {
        switch target {
        case .panel(let id): return PanelLinkFormat.url(kind: .panel, id: id)
        case .workspace(let id): return PanelLinkFormat.url(kind: .workspace, id: id)
        }
    }
}

/// Cold startup holds one bounded URL until the initial graph exists. The
/// original deadline survives restore; no array or arbitrary payload is kept.
struct ExternalPanelLinkStartupHold {
    struct Held {
        let id = UUID()
        let href: String
        let expiresAt: TimeInterval
    }
    private(set) var pending: Held?

    mutating func capture(_ href: String, now: TimeInterval) -> Held? {
        guard pending == nil else { return nil }
        let held = Held(href: href.utf8.prefix(129).count <= 128 ? href : "c11:invalid", expiresAt: now + 60)
        pending = held
        return held
    }

    mutating func take(now: TimeInterval) -> Held? {
        defer { pending = nil }
        guard let pending, now < pending.expiresAt else { return nil }
        return pending
    }

    mutating func expire(id: UUID, now: TimeInterval) {
        guard pending?.id == id, let deadline = pending?.expiresAt, now >= deadline else { return }
        pending = nil
    }
}

/// One pending request, no queue. The UI and tests use this same admission and
/// decision path; a URL is data until an explicit confirmation consumes it.
@MainActor
final class ExternalPanelLinkRequest {
    struct Prompt {
        let id = UUID()
        let destination: ExternalPanelLinkDestination?
        let notice: PanelLinkNotice?
        let expiresAt: TimeInterval
        let armedAt: TimeInterval
    }

    private(set) var pending: Prompt?
    private var nextAdmission: TimeInterval = 0
    private let now: () -> TimeInterval
    private let armingDelay: TimeInterval
    private let resolve: (PanelLinkTarget) -> ExternalPanelLinkDestination?
    private let open: (PanelLinkTarget) -> Bool

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         armingDelay: TimeInterval = max(0.75, NSEvent.doubleClickInterval),
         resolve: @escaping (PanelLinkTarget) -> ExternalPanelLinkDestination?,
         open: @escaping (PanelLinkTarget) -> Bool) {
        self.now = now
        self.armingDelay = max(0.75, armingDelay)
        self.resolve = resolve
        self.open = open
    }

    @discardableResult
    func receive(_ href: String, expiresAt: TimeInterval? = nil) -> Prompt? {
        let receivedAt = now()
        guard pending == nil, receivedAt >= nextAdmission,
              expiresAt == nil || receivedAt < expiresAt! else { return nil }
        let destination: ExternalPanelLinkDestination?
        let notice: PanelLinkNotice?
        // Bound before trimming, URLComponents, display or logging. No rejected
        // payload is retained. In-app parsing and activation remain unchanged.
        if href.utf8.prefix(129).count <= 128, let target = PanelLinkTarget(href) {
            destination = resolve(target)
            notice = destination == nil ? .unavailable : nil
        } else {
            destination = nil
            notice = .invalid
        }
        let prompt = Prompt(destination: destination, notice: notice,
                            expiresAt: min(receivedAt + (destination == nil ? 5 : 60), expiresAt ?? .infinity),
                            armedAt: receivedAt + armingDelay)
        pending = prompt
        return prompt
    }

    func showNotice(_ notice: PanelLinkNotice) -> Prompt {
        let prompt = Prompt(destination: nil, notice: notice, expiresAt: now() + 5, armedAt: .infinity)
        pending = prompt
        return prompt
    }

    /// Consume once before resolving/opening, including on reentrant calls.
    /// A moved destination requires a new click; live title changes do not.
    @discardableResult
    func finish(id: UUID, confirm: Bool, isSocketCommand: Bool = false) -> String {
        guard let prompt = pending, prompt.id == id else { return "stale_confirmation" }
        if confirm, prompt.destination != nil, now() < prompt.armedAt { return "not_armed" }
        pending = nil
        nextAdmission = now() + 2
        guard confirm else { return "cancelled" }
        guard !isSocketCommand else { return "socket_command" }
        guard now() < prompt.expiresAt else { return "expired" }
        guard let destination = prompt.destination else { return "unavailable" }
        guard let live = resolve(destination.target) else { return "unavailable" }
        guard live.target == destination.target, live.workspaceID == destination.workspaceID else { return "destination_changed" }
        return open(destination.target) ? "opened" : "unavailable"
    }
}

/// Return, keypad Enter or Escape cancels on the key-up of a press that began
/// in the prompt. Acting on key-up keeps autorepeat of a held key from reaching
/// the window that regains focus; a repeat or key-up with no fresh key-down here
/// (a key already held when the prompt appeared) does nothing. No key confirms.
struct ExternalPanelLinkKeyGate {
    /// Return, keypad Enter, Escape.
    static let cancelKeyCodes: Set<UInt16> = [36, 76, 53]
    private var pressed: UInt16?

    static func isPlain(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option]).isEmpty
    }

    mutating func keyDown(keyCode: UInt16, isRepeat: Bool, plain: Bool) {
        guard !isRepeat else { return }
        pressed = plain && Self.cancelKeyCodes.contains(keyCode) ? keyCode : nil
    }

    /// True when this key-up ends a fresh cancel press.
    mutating func keyUp(keyCode: UInt16) -> Bool {
        guard let pressed, pressed == keyCode else { return false }
        self.pressed = nil
        return true
    }
}

/// A floating confirmation that takes key focus without activating c11 or
/// becoming main, so Return and Escape reach it from another app too. While it
/// is key it owns every key event: cancel keys go through the key gate, every
/// other key (Space, Tab, Command chords) is dropped, and nothing reaches
/// Confirm, the main menu or the window behind it.
final class ExternalPanelLinkWindow: NSPanel {
    var onCancelKey: (() -> Void)?
    private var keyGate = ExternalPanelLinkKeyGate()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            noteKeyDown(event)
        case .keyUp:
            if keyGate.keyUp(keyCode: event.keyCode) { onCancelKey?() }
        default:
            super.sendEvent(event)
        }
    }

    /// Never super: Cancel's Return default-button match would fire on key-down
    /// and hand autorepeat to the window behind. Not key, it claims nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow else { return false }
        if event.type == .keyDown { noteKeyDown(event) }
        return true
    }

    private func noteKeyDown(_ event: NSEvent) {
        keyGate.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat,
                        plain: ExternalPanelLinkKeyGate.isPlain(event.modifierFlags))
    }
}

/// A newly appeared control is not consent. Bind one fresh plain click to
/// this presentation, after a double-click interval and any required re-entry.
struct ExternalPanelLinkGesture {
    private let readyAt: TimeInterval
    private var mustReenter: Bool
    private var hasLeft: Bool
    private var downAt: TimeInterval?

    init(presentedAt: TimeInterval, doubleClickInterval: TimeInterval, pointerInside: Bool) {
        readyAt = presentedAt + max(0.75, doubleClickInterval)
        mustReenter = pointerInside
        hasLeft = !pointerInside
    }

    func isArmed(at now: TimeInterval) -> Bool { now >= readyAt && !mustReenter }

    mutating func pointer(inside: Bool) {
        if !inside { hasLeft = true; downAt = nil }
        else if hasLeft { mustReenter = false }
    }

    mutating func begin(at now: TimeInterval, plain: Bool, clickCount: Int, inside: Bool) -> Bool {
        downAt = nil
        guard isArmed(at: now), plain, clickCount == 1, inside else { return false }
        downAt = now
        return true
    }

    mutating func end(at now: TimeInterval, plain: Bool, clickCount: Int, inside: Bool) -> Bool {
        defer { downAt = nil }
        guard let downAt, now >= downAt, isArmed(at: now), plain, clickCount == 1, inside else { return false }
        return true
    }

    mutating func cancelPress() { downAt = nil }
}

final class ExternalPanelLinkButton: NSButton {
    let requestID: UUID
    private var gesture: ExternalPanelLinkGesture?
    private var confirmationTracking: NSTrackingArea?

    func armConfirmation() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        gesture = ExternalPanelLinkGesture(presentedAt: ProcessInfo.processInfo.systemUptime,
            doubleClickInterval: NSEvent.doubleClickInterval, pointerInside: bounds.contains(point))
        updateTrackingAreas()
        refreshArming()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.75, NSEvent.doubleClickInterval)) { [weak self] in
            self?.refreshArming()
        }
    }

    private func refreshArming() {
        if let gesture { isEnabled = gesture.isArmed(at: ProcessInfo.processInfo.systemUptime) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let confirmationTracking { removeTrackingArea(confirmationTracking) }
        guard gesture != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        confirmationTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        gesture?.pointer(inside: true)
        refreshArming()
    }

    override func mouseExited(with event: NSEvent) {
        gesture?.pointer(inside: false)
        refreshArming()
    }

    private func plain(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    private func inside(_ event: NSEvent) -> Bool {
        event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        refreshArming()
        if gesture != nil {
            let visible = window?.isVisible == true
            let socket = SocketCommandContext.current != nil
            let armed = gesture?.isArmed(at: event.timestamp) == true
            let unmodified = plain(event)
            let inBounds = inside(event)
            let accepted = visible && !socket &&
                gesture?.begin(at: event.timestamp, plain: unmodified,
                               clickCount: event.clickCount, inside: inBounds) == true
            let result = accepted ? "accepted" : !visible ? "hidden" : socket ? "socket_command" :
                !armed ? "not_armed_at_event" : !unmodified ? "modified" :
                event.clickCount != 1 ? "multiple_click" : !inBounds ? "outside_window_or_bounds" : "refused"
            PanelLinkActivation.log(target: "", origin: "external", activation: "native_down", result: result)
            guard accepted else { return }
        }
        super.mouseDown(with: event)
        gesture?.cancelPress()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if gesture != nil {
            let eventType = NSApp.currentEvent?.type.rawValue
            guard let event = NSApp.currentEvent, event.type == .leftMouseUp,
                  window?.isVisible == true, SocketCommandContext.current == nil,
                  gesture?.end(at: event.timestamp, plain: plain(event), clickCount: event.clickCount,
                               inside: inside(event)) == true else {
                let result = eventType == nil ? "missing_event" : eventType != NSEvent.EventType.leftMouseUp.rawValue ?
                    "unexpected_event_\(eventType!)" : "release_refused"
                PanelLinkActivation.log(target: "", origin: "external", activation: "native_action", result: result)
                gesture?.cancelPress()
                return false
            }
            PanelLinkActivation.log(target: "", origin: "external", activation: "native_action", result: "accepted")
        }
        return super.sendAction(action, to: target)
    }

    /// A click lands on the first press, as it did when the prompt could not
    /// become key; Confirm's gesture gate still decides whether it counts.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, requestID: UUID, target: AnyObject?, action: Selector) {
        self.requestID = requestID
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.bezelStyle = .rounded
        self.setButtonType(.momentaryPushIn)
        // No keyboard focus ring: Tab and Space never reach a button.
        self.refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { return nil }
}

@MainActor
final class ExternalPanelLinkPresenter: NSObject, NSWindowDelegate {
    private let request: ExternalPanelLinkRequest
    private var panel: ExternalPanelLinkWindow?
    /// The window that was key when the prompt took focus; it gets key back on
    /// every dismissal that does not navigate.
    private weak var restoreKeyWindow: NSWindow?
    private var expiry: DispatchWorkItem?

    var isPresenting: Bool { panel != nil }
    var presentedWindow: ExternalPanelLinkWindow? { panel }
    private var visibilityObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(resolve: @escaping (PanelLinkTarget) -> ExternalPanelLinkDestination?,
         open: @escaping (PanelLinkTarget) -> Bool) {
        request = ExternalPanelLinkRequest(resolve: resolve, open: open)
        super.init()
    }

    func receive(_ href: String, expiresAt: TimeInterval? = nil) {
        guard SocketCommandContext.current == nil,
              let prompt = request.receive(href, expiresAt: expiresAt) else { return }
        show(prompt)
        PanelLinkActivation.log(target: prompt.destination?.url ?? "", origin: "external",
                                activation: "request", result: prompt.destination == nil ? "notice" : "confirmation")
    }

    private func show(_ prompt: ExternalPanelLinkRequest.Prompt) {
        let window = ExternalPanelLinkWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = String(localized: "panelLink.external.title", defaultValue: "Outside c11 link")
        window.identifier = NSUserInterfaceItemIdentifier("c11.external-link.confirmation")
        window.setAccessibilityIdentifier("c11.external-link.confirmation")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        func label(_ text: String, identifier: String, wraps: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 13)
            // Trusted guidance must remain readable; destination titles are
            // untrusted display text and keep one bounded, truncated row.
            field.maximumNumberOfLines = wraps ? 0 : 1
            field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
            field.preferredMaxLayoutWidth = 480
            field.setAccessibilityIdentifier(identifier)
            rows.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 480).isActive = true
        }
        if let destination = prompt.destination {
            label(String(localized: "panelLink.external.explanation", defaultValue: "An outside link wants to select this destination. Confirm only if you intended to open it."), identifier: "c11.external-link.explanation", wraps: true)
            if let title = destination.panelTitle {
                label(String(localized: "panelLink.preview.panel", defaultValue: "Panel: \(title)"), identifier: "c11.external-link.panel")
            }
            let title = destination.workspaceTitle
            label(String(localized: "panelLink.preview.workspace", defaultValue: "Workspace: \(title)"), identifier: "c11.external-link.workspace")
            label(destination.url, identifier: "c11.external-link.url")
        } else {
            label((prompt.notice ?? .unavailable).text, identifier: "c11.external-link.notice", wraps: true)
        }
        let row = Self.makeButtonRow(requestID: prompt.id, hasDestination: prompt.destination != nil, target: self)
        window.defaultButtonCell = row.cancel.cell as? NSButtonCell
        let confirmationButton = row.confirm
        rows.addArrangedSubview(row.stack)
        let content = NSView()
        content.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 520, height: rows.fittingSize.height + 40))
        // The source app may be on a different display/Space from c11. The
        // pointer identifies the display for an outside click; no window rises.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // Place before assigning panel = window; otherwise windowDidMove cancels the prompt.
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.midY - window.frame.height / 2))
        }
        window.onCancelKey = { [weak self, id = prompt.id] in
            MainActor.assumeIsolated { self?.dismiss(id: id, confirm: false) }
        }
        if let key = NSApp.keyWindow, !(key is ExternalPanelLinkWindow) { restoreKeyWindow = key }
        panel = window
        // Key, not active: c11 is not activated and no other window rises.
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        confirmationButton?.armConfirmation()
        for (center, name) in [
            (NotificationCenter.default, NSApplication.didHideNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPending() }
            }
            visibilityObservers.append((center, token))
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss(id: prompt.id, confirm: false) }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, prompt.expiresAt - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    /// Confirm, when there is a destination, then Cancel. Cancel is the
    /// rightmost button, where a habitual "proceed" click lands, and the only
    /// one marked for Return; Confirm starts disabled until its gesture arms.
    /// The window's key gate, not the buttons, handles Return and Escape.
    static func makeButtonRow(requestID: UUID, hasDestination: Bool, target: ExternalPanelLinkPresenter?)
        -> (stack: NSStackView, confirm: ExternalPanelLinkButton?, cancel: ExternalPanelLinkButton) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        var confirm: ExternalPanelLinkButton?
        if hasDestination {
            let button = ExternalPanelLinkButton(title: String(localized: "panelLink.external.confirm", defaultValue: "Confirm"),
                                   requestID: requestID, target: target, action: #selector(ExternalPanelLinkPresenter.confirmClicked(_:)))
            button.bezelStyle = .rounded
            button.keyEquivalent = ""
            button.isEnabled = false
            button.setAccessibilityIdentifier("c11.external-link.confirm")
            stack.addArrangedSubview(button)
            confirm = button
        }
        let cancel = ExternalPanelLinkButton(title: String(localized: "common.cancel", defaultValue: "Cancel"),
                              requestID: requestID, target: target, action: #selector(ExternalPanelLinkPresenter.cancelClicked(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\r"
        cancel.setAccessibilityIdentifier("c11.external-link.cancel")
        stack.addArrangedSubview(cancel)
        return (stack, confirm, cancel)
    }

    private func restoreKeyFocus() {
        defer { restoreKeyWindow = nil }
        guard NSApp.isActive, let window = restoreKeyWindow, window.isVisible, !window.isMiniaturized,
              window.isOnActiveSpace, window.canBecomeKey, NSApp.keyWindow !== window else { return }
        window.makeKey()
    }

    @objc private func cancelClicked(_ sender: ExternalPanelLinkButton) {
        dismiss(id: sender.requestID, confirm: false)
    }

    @objc private func confirmClicked(_ sender: ExternalPanelLinkButton) {
        dismiss(id: sender.requestID, confirm: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel, let prompt = request.pending { dismiss(id: prompt.id, confirm: false) }
        return false
    }

    private func cancelPending() {
        if let prompt = request.pending { dismiss(id: prompt.id, confirm: false) }
    }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === panel else { return }
        cancelPending()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === panel else { return }
        if !changed.isVisible { cancelPending() }
    }

    private func dismiss(id: UUID, confirm: Bool) {
        guard let prompt = request.pending, prompt.id == id else { return }
        if confirm, ProcessInfo.processInfo.systemUptime < prompt.armedAt { return }
        expiry?.cancel()
        expiry = nil
        for (center, token) in visibilityObservers { center.removeObserver(token) }
        visibilityObservers.removeAll()
        panel?.delegate = nil
        panel?.onCancelKey = nil
        panel?.orderOut(nil)
        panel = nil
        let result = request.finish(id: id, confirm: confirm, isSocketCommand: SocketCommandContext.current != nil)
        PanelLinkActivation.log(target: prompt.destination?.url ?? "", origin: "external",
                                activation: confirm ? "confirm" : "cancel", result: result)
        // A confirmed open hands focus to its destination. Otherwise the window
        // that was key gets it back; with c11 inactive the OS returns key to
        // the active app, and c11 makes no window key.
        if result != "opened" { restoreKeyFocus() }
        if confirm && result != "opened" {
            // Keep the same admission occupied by a notice; never substitute a
            // different target or open another app after a stale confirmation.
            show(request.showNotice(result == "destination_changed" ? .destinationChanged : .unavailable))
        }
    }
}
