import AppKit
import WebKit
import os
import Bonsplit

/// What a URL a page asked to open should do.
enum BrowserExternalOpenKind: Equatable {
    /// Loaded inside the panel (http, https, file, about, data, blob, ...).
    case web
    /// Opened by macOS without asking: only `mailto:`, which composes a draft
    /// and sends nothing without the operator.
    case direct
    /// Hands the URL to another app: asks the operator first.
    case consent
}

func browserExternalOpenKind(_ url: URL) -> BrowserExternalOpenKind {
    guard browserShouldOpenURLExternally(url) else { return .web }
    return url.scheme?.lowercased() == "mailto" ? .direct : .consent
}

/// The page that asked. `allowKey` is `scheme://host[:port]`, or nil for an
/// origin with no host (local files, opaque origins), which always asks.
struct BrowserExternalOpenOrigin: Equatable {
    let allowKey: String?
    let host: String?

    init(scheme: String?, host: String?, port: Int?) {
        let scheme = (scheme ?? "").lowercased()
        let host = (host ?? "").lowercased()
        guard !scheme.isEmpty, !host.isEmpty else {
            allowKey = nil
            self.host = nil
            return
        }
        var hostPort = host
        if let port, port > 0,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            hostPort = "\(host):\(port)"
        }
        allowKey = "\(scheme)://\(hostPort)"
        self.host = hostPort
    }

    init(securityOrigin: WKSecurityOrigin) {
        self.init(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port)
    }

    init(pageURL: URL?) {
        self.init(scheme: pageURL?.scheme, host: pageURL?.host, port: pageURL?.port)
    }

    /// The frame that started the request; WebKit leaves `sourceFrame` nil
    /// for some loads, so fall back to the page the web view shows.
    init(navigationAction: WKNavigationAction, in webView: WKWebView) {
        let frame: WKFrameInfo? = navigationAction.sourceFrame
        if let origin = frame?.securityOrigin {
            self.init(securityOrigin: origin)
        } else {
            self.init(pageURL: webView.url)
        }
    }
}

/// Persisted "always allow" pairs: one `origin scheme` line each, edited (and
/// revoked) in Settings > Browser.
enum BrowserExternalSchemeSettings {
    static let allowlistKey = "browserExternalSchemeAllowlist"

    static func entries(rawValue: String?) -> [String] {
        var seen = Set<String>()
        return (rawValue ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard words.count == 2 else { return nil }
            let entry = "\(words[0]) \(words[1].hasSuffix(":") ? String(words[1].dropLast()) : words[1])"
            return seen.insert(entry).inserted ? entry : nil
        }
    }

    static func isAllowed(originKey: String, scheme: String, defaults: UserDefaults = .standard) -> Bool {
        entries(rawValue: defaults.string(forKey: allowlistKey)).contains("\(originKey) \(scheme.lowercased())")
    }

    static func allow(originKey: String, scheme: String, defaults: UserDefaults = .standard) {
        var current = entries(rawValue: defaults.string(forKey: allowlistKey))
        let entry = "\(originKey.lowercased()) \(scheme.lowercased())"
        guard !current.contains(entry) else { return }
        current.append(entry)
        defaults.set(current.joined(separator: "\n"), forKey: allowlistKey)
    }
}

/// Where a prompt for one request would appear. Production binds this to the
/// requesting web view; tests supply their own.
@MainActor
struct BrowserExternalOpenHost {
    /// The page is on screen, so the operator can see who is asking.
    var isVisible: () -> Bool
    /// Shows the prompt and calls back exactly once with the operator's answer.
    var present: (BrowserExternalOpenGate.Prompt, @escaping (BrowserExternalOpenGate.Answer) -> Void) -> Void
    /// Shows a short, non-blocking notice in the panel.
    var notice: (String) -> Void
    /// Records a dropped request where the operator can find it later.
    var log: (String) -> Void = { _ in }
}

/// The one door between page content and `NSWorkspace` for non-web schemes.
/// One gate per browser panel, shared with that panel's popups: one pending
/// prompt, no queue, a short cooldown, and no scripted re-asks after Cancel.
@MainActor
final class BrowserExternalOpenGate {
    struct Prompt: Equatable {
        let id = UUID()
        let url: URL
        let scheme: String
        let origin: BrowserExternalOpenOrigin
        let appName: String
    }

    enum Answer: Equatable {
        case open(alwaysAllow: Bool)
        case cancel
    }

    enum Outcome: String, Equatable {
        case notExternal = "not_external"
        case openedDirect = "opened_direct"
        case openedAllowed = "opened_allowed"
        case prompted
        case noHandler = "no_handler"
        case droppedPending = "dropped_pending"
        case droppedCooldown = "dropped_cooldown"
        case droppedDeclined = "dropped_declined"
        case droppedHidden = "dropped_hidden"
        case openFailed = "open_failed"
    }

    static let cooldown: TimeInterval = 2
    /// The single hand-off to macOS for browser app links. Host tests swap it
    /// to observe what would have opened.
    nonisolated(unsafe) static var systemOpen: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "browser_external_open")

    private(set) var pending: Prompt?
    private var nextAdmission: TimeInterval = 0
    private var declined = Set<String>()
    private var lastDropLog: [String: TimeInterval] = [:]
    static let dropLogInterval: TimeInterval = 30
    private let appName: (URL) -> String?
    private let open: (URL) -> Bool
    private let now: () -> TimeInterval
    private let defaults: UserDefaults

    init(
        appName: @escaping (URL) -> String? = BrowserExternalOpenGate.handlerAppName,
        open: @escaping (URL) -> Bool = { BrowserExternalOpenGate.systemOpen($0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        defaults: UserDefaults = .standard
    ) {
        self.appName = appName
        self.open = open
        self.now = now
        self.defaults = defaults
    }

    nonisolated static func handlerAppName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }

    /// A page asked to open `url`. `userClick` is true only for a link the
    /// operator activated; scripted requests are false.
    @discardableResult
    func request(
        _ url: URL,
        origin: BrowserExternalOpenOrigin,
        userClick: Bool,
        host: BrowserExternalOpenHost
    ) -> Outcome {
        let outcome = admit(url, origin: origin, userClick: userClick, host: host)
        Self.log(url: url, origin: origin, userClick: userClick, outcome: outcome.rawValue)
        recordDrop(outcome, scheme: url.scheme?.lowercased() ?? "", origin: origin, host: host)
        return outcome
    }

    private func admit(
        _ url: URL,
        origin: BrowserExternalOpenOrigin,
        userClick: Bool,
        host: BrowserExternalOpenHost
    ) -> Outcome {
        switch browserExternalOpenKind(url) {
        case .web:
            return .notExternal
        case .direct:
            return open(url) ? .openedDirect : .openFailed
        case .consent:
            break
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard let appName = appName(url) else {
            host.notice(String(
                localized: "browser.externalOpen.noHandler",
                defaultValue: "No app on this Mac opens \(scheme): links."
            ))
            return .noHandler
        }
        if let key = origin.allowKey,
           BrowserExternalSchemeSettings.isAllowed(originKey: key, scheme: scheme, defaults: defaults) {
            return open(url) ? .openedAllowed : .openFailed
        }
        if pending != nil { return .droppedPending }
        if now() < nextAdmission { return .droppedCooldown }
        let declineKey = "\(origin.allowKey ?? "opaque") \(scheme)"
        if userClick {
            declined.remove(declineKey)
        } else if declined.contains(declineKey) {
            return .droppedDeclined
        }
        guard host.isVisible() else { return .droppedHidden }
        let prompt = Prompt(url: url, scheme: scheme, origin: origin, appName: appName)
        pending = prompt
        host.present(prompt) { [weak self] answer in
            self?.finish(id: prompt.id, answer: answer)
        }
        return .prompted
    }

    /// Consumes the pending prompt once. A stale or repeated answer does nothing.
    @discardableResult
    func finish(id: UUID, answer: Answer) -> String {
        guard let prompt = pending, prompt.id == id else { return "stale" }
        pending = nil
        nextAdmission = now() + Self.cooldown
        let result: String
        switch answer {
        case .cancel:
            declined.insert("\(prompt.origin.allowKey ?? "opaque") \(prompt.scheme)")
            result = "cancelled"
        case .open(let alwaysAllow):
            if alwaysAllow, let key = prompt.origin.allowKey {
                BrowserExternalSchemeSettings.allow(originKey: key, scheme: prompt.scheme, defaults: defaults)
            }
            result = open(prompt.url) ? (alwaysAllow ? "opened_always" : "opened_once") : "open_failed"
        }
        Self.log(url: prompt.url, origin: prompt.origin, userClick: nil, outcome: result)
        return result
    }

    /// One operator-visible line per reason, site and scheme every 30 s, so a
    /// page cannot flush the log with a burst.
    private func recordDrop(
        _ outcome: Outcome,
        scheme: String,
        origin: BrowserExternalOpenOrigin,
        host: BrowserExternalOpenHost
    ) {
        let asker = origin.host ?? String(localized: "browser.externalOpen.thisPage", defaultValue: "This page")
        let line: String
        switch outcome {
        case .droppedHidden:
            line = String(localized: "browser.externalOpen.log.hidden",
                          defaultValue: "\(asker) tried to open a \(scheme): link while its panel was hidden. Nothing opened.")
        case .droppedPending:
            line = String(localized: "browser.externalOpen.log.pending",
                          defaultValue: "\(asker) asked again to open a \(scheme): link while a prompt was showing. Nothing opened.")
        case .droppedCooldown:
            line = String(localized: "browser.externalOpen.log.cooldown",
                          defaultValue: "\(asker) asked again to open a \(scheme): link right after a prompt closed. Nothing opened.")
        case .droppedDeclined:
            line = String(localized: "browser.externalOpen.log.declined",
                          defaultValue: "\(asker) asked again to open a \(scheme): link after Cancel. Nothing opened.")
        default:
            return
        }
        let key = "\(outcome.rawValue) \(origin.allowKey ?? "opaque") \(scheme)"
        let at = now()
        if let last = lastDropLog[key], at - last < Self.dropLogInterval { return }
        lastDropLog[key] = at
        host.log(line)
    }

    /// A new main-frame document: scripted requests may ask again.
    func pageDidNavigate() {
        declined.removeAll()
    }

    private static func log(url: URL, origin: BrowserExternalOpenOrigin, userClick: Bool?, outcome: String) {
        var fields: [String: Any] = [
            "scheme": url.scheme?.lowercased() ?? "",
            "origin": origin.allowKey ?? "opaque",
            "outcome": outcome,
        ]
        if let userClick { fields["user_click"] = userClick }
        // Scheme and origin only: the URL itself can carry credentials or paths.
        let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let line = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        logger.info("browser_external_open \(line, privacy: .public)")
        #if DEBUG
        dlog("browser_external_open \(line)")
        #endif
    }
}

extension BrowserExternalOpenHost {
    /// Binds prompts and notices to `webView`: a sheet on its own window,
    /// never `runModal`, and only while the page is on screen.
    static func webView(
        _ webView: WKWebView,
        noticePresenter: PanelLinkNoticePresenter,
        log: @escaping (String) -> Void
    ) -> BrowserExternalOpenHost {
        BrowserExternalOpenHost(
            isVisible: { [weak webView] in
                guard let webView, let window = webView.window else { return false }
                return window.isVisible && !webView.isHiddenOrHasHiddenAncestor
            },
            present: { [weak webView] prompt, completion in
                let alert = browserExternalOpenAlert(for: prompt)
                browserPresentModalAlert(
                    alert,
                    preferredWindow: webView?.window,
                    safeDefaultResponse: .alertSecondButtonReturn,
                    reasonForLog: "external \(prompt.scheme): open",
                    completion: { [weak alert] response in
                        if response == .alertFirstButtonReturn {
                            completion(.open(alwaysAllow: alert?.suppressionButton?.state == .on))
                        } else {
                            completion(.cancel)
                        }
                    }
                )
            },
            notice: { [weak webView] text in
                guard let webView else { return }
                noticePresenter.show(text: text, in: webView)
            },
            log: log
        )
    }
}

func browserExternalOpenAlert(for prompt: BrowserExternalOpenGate.Prompt) -> NSAlert {
    let appName = prompt.appName
    let scheme = prompt.scheme
    let asker = prompt.origin.host ?? String(
        localized: "browser.externalOpen.thisPage", defaultValue: "This page"
    )
    var shownURL = prompt.url.absoluteString
    if shownURL.count > 200 { shownURL = String(shownURL.prefix(200)) + "\u{2026}" }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(
        localized: "browser.externalOpen.title", defaultValue: "Open \u{201C}\(appName)\u{201D}?"
    )
    let message = String(
        localized: "browser.externalOpen.message",
        defaultValue: "\(asker) wants to open a \(scheme): link in \(appName)."
    )
    alert.informativeText = message + "\n\n" + shownURL
    let openButton = alert.addButton(withTitle: String(localized: "browser.externalOpen.open", defaultValue: "Open"))
    // Return never consents: a page could time the prompt under a keystroke.
    openButton.keyEquivalent = ""
    let cancelButton = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
    cancelButton.keyEquivalent = "\u{1b}"
    if let host = prompt.origin.host {
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(
            localized: "browser.externalOpen.alwaysAllow",
            defaultValue: "Always allow \(host) to open \(scheme): links"
        )
        alert.suppressionButton?.state = .off
    }
    alert.window.identifier = NSUserInterfaceItemIdentifier("c11.browser.external-open")
    return alert
}
